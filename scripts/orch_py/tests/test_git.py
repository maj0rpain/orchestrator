"""The git adapter's operations, each run against a real repository in
tmp_path and against the fake, giving the same answers."""
from __future__ import annotations

import os
import subprocess

import pytest

from conftest import (GLOBAL_CONFIG, committed, exclude_orchestrator, git_identity, git_repo,
                      origin_clone, run_git, tip, worktree_add, write_staged)
from orch.git import FakeGit, Git, GitFailure, Worktree, git_push_reason

ORIGIN = "https://github.com/fork/widgets.git"


@pytest.mark.parametrize("origin", [ORIGIN, None], ids=["origin", "no-origin"])
def test_origin_url_reads_the_same_from_a_real_repo_and_the_fake(tmp_path, origin):
    real = git_repo(tmp_path, origin)
    fake = FakeGit(remotes={} if origin is None else {"origin": origin})

    assert real.origin_url() == origin
    assert fake.origin_url() == origin


def test_a_repo_with_other_remotes_but_no_origin_has_no_origin_url(tmp_path):
    real = git_repo(tmp_path)
    subprocess.run(
        ["git", "-C", str(tmp_path), "remote", "add", "upstream", ORIGIN],
        check=True,
        stdin=subprocess.DEVNULL,
    )
    fake = FakeGit(remotes={"upstream": ORIGIN})

    assert real.origin_url() is None
    assert fake.origin_url() is None


def test_outside_a_repository_there_is_no_origin_url(tmp_path):
    assert Git(cwd=str(tmp_path)).origin_url() is None


def test_toplevel_reads_the_same_from_a_real_repo_and_the_fake(tmp_path):
    root = tmp_path / "checkout"
    git_repo(root)
    (root / "sub").mkdir()
    fake = FakeGit(toplevel=str(root.resolve()))

    assert Git(cwd=str(root / "sub")).toplevel() == str(root.resolve())
    assert fake.toplevel() == str(root.resolve())


def test_outside_a_repository_there_is_no_toplevel(tmp_path):
    assert Git(cwd=str(tmp_path)).toplevel() is None
    assert FakeGit().toplevel() is None


def test_toplevel_at_reads_another_directory_s_checkout_the_same_from_both(tmp_path):
    root = tmp_path / "checkout"
    git_repo(root)
    (root / "sub").mkdir()
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    sub, top = str(root / "sub"), str(root.resolve())
    fake = FakeGit(checkouts={sub: top})

    assert Git(cwd=str(elsewhere)).toplevel_at(sub) == top
    assert fake.toplevel_at(sub) == top


@pytest.mark.parametrize("name", ["plain", "missing"])
def test_a_directory_in_no_repository_has_no_toplevel_at(tmp_path, name):
    path = tmp_path / name
    if name == "plain":
        path.mkdir()

    assert Git(cwd=str(tmp_path)).toplevel_at(str(path)) is None
    assert FakeGit().toplevel_at(str(path)) is None


# --- the drift line's operations ---------------------------------------------


@pytest.fixture
def audited(tmp_path):
    """A repository whose first commit holds a.md, b.md, sub/d.md and
    -opt.md, then one changing a.md, -opt.md and sub/d.md and renaming b.md;
    its root, the first commit's SHA, and the fake holding the same two
    trees."""
    root = tmp_path / "repo"
    git_repo(root)
    base_files = {"a.md": "a\n", "b.md": "b\n", "sub/d.md": "d\n", "-opt.md": "x\n"}
    base = committed(root, base_files, "files")
    (root / "b.md").rename(root / "moved.md")
    head = committed(root, {"a.md": "changed\n", "-opt.md": "y\n", "sub/d.md": None}, "changes")
    head_files = {"a.md": "changed\n", "moved.md": "b\n", "-opt.md": "y\n"}
    return root, base, FakeGit(commits={base: base_files, head: head_files}, head=head)


CITED = ["a.md", "b.md", "sub/d.md", "-opt.md", "*.md", ":(glob)**", "missing.md"]


def test_changed_paths_reads_the_same_from_a_real_repo_and_the_fake(audited):
    root, base, fake = audited
    want = {"a.md", "b.md", "sub/d.md", "-opt.md"}

    assert Git(cwd=str(root)).changed_paths(base, CITED) == want
    assert fake.changed_paths(base, CITED) == want


def test_changed_paths_are_from_the_top_whatever_the_directory_and_diff_relative(audited):
    root, base, _ = audited
    run_git(root, "config", "diff.relative", "true")

    assert Git(cwd=str(root / "sub")).changed_paths(base, ["a.md", "sub/d.md"]) \
        == {"a.md", "sub/d.md"}


def test_an_uncommitted_change_is_not_a_changed_path(audited):
    root, _, _ = audited
    (root / "moved.md").write_text("uncommitted\n")
    head = run_git(root, "rev-parse", "HEAD")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "nothing")

    assert Git(cwd=str(root)).changed_paths(head, ["moved.md"]) == set()


def test_changed_paths_fail_for_a_commit_the_clone_lacks_or_an_unborn_head(audited, tmp_path):
    root, _, fake = audited
    unborn = tmp_path / "unborn"
    git_repo(unborn)
    missing = "deadbeef" * 5

    assert Git(cwd=str(root)).changed_paths(missing, ["a.md"]) is None
    assert fake.changed_paths(missing, ["a.md"]) is None
    assert Git(cwd=str(unborn)).changed_paths(missing, ["a.md"]) is None
    assert FakeGit(commits={missing: {}}).changed_paths(missing, ["a.md"]) is None


def test_head_and_commit_presence_read_the_same_from_a_real_repo_and_the_fake(audited, tmp_path):
    root, base, fake = audited
    unborn = tmp_path / "unborn"
    git_repo(unborn)
    missing = "deadbeef" * 5
    real = Git(cwd=str(root))

    assert (real.has_head_commit(), Git(cwd=str(unborn)).has_head_commit()) == (True, False)
    assert (fake.has_head_commit(), FakeGit().has_head_commit()) == (True, False)
    assert (real.has_commit(base), real.has_commit(missing)) == (True, False)
    assert (fake.has_commit(base), fake.has_commit(missing)) == (True, False)


# --- review ci's push-time and no-CI-evidence reads ----------------------------


@pytest.fixture
def tracked(tmp_path):
    """A repository whose commit one holds two workflows, one of them named
    outside ASCII, a nested one and a file in sub/; commit two adds a README. origin/topic's remote-tracking
    ref was updated to one at unix second 1700000060, then to two at
    1700000120, then back to one at 1700000180. Its root and the two SHAs."""
    root = tmp_path / "repo"
    git_repo(root)
    one = committed(root, {".github/workflows/ci.yml": "on: push\n",
                           ".github/workflows/ci-\u00fc.yml": "on: push\n",
                           ".github/workflows/nested/x.yaml": "x\n",
                           ".github/README.md": "r\n", "sub/keep.txt": "k\n"}, "one")
    two = committed(root, {"README.md": "r\n"}, "two")
    for when, sha in ((60, one), (120, two), (180, one)):
        stamp = "@%d +0000" % (1700000000 + when)
        run_git(root, "update-ref", "-m", "update by push", "refs/remotes/origin/topic", sha,
                env=dict(os.environ, GIT_COMMITTER_DATE=stamp))
    return root, one, two


TOPIC = "refs/remotes/origin/topic"


def test_a_ref_s_verify_reads_the_same_from_a_real_repo_and_the_fake(tracked, where):
    root, _, _ = tracked
    git = adapter(root, where)

    assert alike(git, "ref_exists", TOPIC) is True
    assert fails_alike(git, "ref_exists", "refs/remotes/origin/gone") is False


def test_a_remote_tracking_reflog_reads_newest_first_with_unix_dates_from_both(tracked, where):
    root, one, two = tracked
    git = adapter(root, where)

    assert alike(git, "reflog_dates", TOPIC) == [
        (one, 1700000180), (two, 1700000120), (one, 1700000060)]
    assert fails_alike(git, "reflog_dates", "refs/remotes/origin/gone") is None


def test_a_full_tree_listing_under_a_path_reads_the_same_from_both_from_any_directory(
        tracked, where):
    root, one, two = tracked
    git = adapter(root, where)

    assert alike(git, "tree_names", one, ".github/workflows/") == [
        ".github/workflows/ci-\u00fc.yml", ".github/workflows/ci.yml", ".github/workflows/nested"]
    assert alike(git, "tree_names", two, "docs/") == []
    assert fails_alike(git, "tree_names", "deadbeef" * 5, ".github/workflows/") is None


# --- the scan's, Lines fate's and the default-branch lookup's operations -----
#
# One history, built once for this file, its commits dated a minute apart so
# git's date order is fixed. main: c1 (f.txt "1".."5", old.txt, sub/keep.txt),
# c2 (line 2 to "20"), c3 (line 4 deleted, old.txt deleted), c4 (sub/keep.txt
# only), then m, a --no-ff merge of topic: t1, off c3, line 1 to "10". side,
# off c2, is never merged: s1, line 5 to "50". The PR head p1, off c1, is on
# origin's refs/pull/7/head alone. The checkout is a clone of origin, so it
# holds every branch but not p1.


def dated(root, when, *args):
    """A git run in <root> committing as of minute <when>."""
    stamp = "@%d +0000" % (1700000000 + when * 60)
    run_git(root, *args, env=dict(os.environ, GIT_AUTHOR_DATE=stamp, GIT_COMMITTER_DATE=stamp))
    return run_git(root, "rev-parse", "HEAD")


@pytest.fixture(scope="module")
def history(tmp_path_factory):
    """The history above: its origin's path, the clone's root, and each
    commit's full SHA by name."""
    base = tmp_path_factory.mktemp("history")
    origin, author = base / "origin.git", base / "author"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(origin)], check=True,
                   stdin=subprocess.DEVNULL)
    subprocess.run(["git", "init", "-q", "-b", "main", str(author)], check=True,
                   stdin=subprocess.DEVNULL)
    sha = {}
    write_staged(author, {"f.txt": "1\n2\n3\n4\n5\n", "old.txt": "x\n", "sub/keep.txt": "k\n"})
    sha["c1"] = dated(author, 1, "commit", "-qm", "c1")
    write_staged(author, {"f.txt": "1\n20\n3\n4\n5\n"})
    sha["c2"] = dated(author, 2, "commit", "-qm", "c2")
    run_git(author, "checkout", "-qb", "side")
    write_staged(author, {"f.txt": "1\n20\n3\n4\n50\n"})
    sha["s1"] = dated(author, 3, "commit", "-qm", "s1")
    run_git(author, "checkout", "-q", "main")
    write_staged(author, {"f.txt": "1\n20\n3\n5\n", "old.txt": None})
    sha["c3"] = dated(author, 4, "commit", "-qm", "c3")
    run_git(author, "checkout", "-qb", "topic")
    write_staged(author, {"f.txt": "10\n20\n3\n5\n"})
    sha["t1"] = dated(author, 5, "commit", "-qm", "t1")
    run_git(author, "checkout", "-q", "main")
    write_staged(author, {"sub/keep.txt": "kk\n"})
    sha["c4"] = dated(author, 6, "commit", "-qm", "c4")
    sha["m"] = dated(author, 7, "merge", "-q", "--no-ff", "topic", "-m", "m")
    run_git(author, "checkout", "-q", "--detach", sha["c1"])
    write_staged(author, {"f.txt": "1\n2\n3\n4\n5 pr\n"})
    sha["p1"] = dated(author, 8, "commit", "-qm", "p1")
    run_git(author, "push", "-q", str(origin), "main", "side", "topic",
            "%s:refs/pull/7/head" % sha["p1"])
    return origin, clone(origin, base / "clone"), sha


def clone(origin, root):
    """A clone of <origin> at <root>, copying none of its objects but those
    its branches reach: its root."""
    subprocess.run(["git", "clone", "-q", "--no-local", str(origin), str(root)], check=True,
                   stdin=subprocess.DEVNULL)
    return root


@pytest.fixture(params=["top", "sub"])
def where(request):
    """Which directory of a checkout the adapter runs from: its top, or its
    sub directory."""
    return request.param


def adapter(root, where):
    return Git(cwd=str(root if where == "top" else root / "sub"))


def alike(git, name, *args):
    """<name>(*args) on the real adapter <git>, and on a FakeGit seeded with
    that answer, asserted the same: the answer."""
    answer = getattr(git, name)(*args)
    fake = FakeGit()
    fake.seed(name, *args, answer=answer)
    assert getattr(fake, name)(*args) == answer
    return answer


def fails_alike(git, name, *args):
    """<name>(*args) on the real adapter <git>, a call it cannot make, and on
    a FakeGit nothing was seeded for, asserted the same: the answer."""
    answer = getattr(git, name)(*args)
    assert getattr(FakeGit(), name)(*args) == answer
    return answer


MAIN = "refs/remotes/origin/main"
MISSING = "deadbeef" * 5


def test_commit_resolution_reads_the_same_from_a_real_repo_and_the_fake(history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "resolve_commit", sha["c2"][:7]) == sha["c2"]
    assert alike(git, "resolve_commit", MAIN) == sha["m"]
    assert fails_alike(git, "resolve_commit", MISSING) is None
    assert fails_alike(git, "resolve_commit", sha["c1"] + "^{tree}") is None
    assert fails_alike(git, "resolve_commit", sha["p1"]) is None


def test_the_pr_head_fetch_brings_in_its_commit_the_same_from_a_real_repo_and_the_fake(
        history, where, tmp_path):
    origin, _, sha = history
    git = adapter(clone(origin, tmp_path / "clone"), where)

    assert alike(git, "fetch_pr_head", "7") is True
    assert git.resolve_commit(sha["p1"]) == sha["p1"]
    assert fails_alike(git, "fetch_pr_head", "8") is False


def test_the_default_branch_fetch_writes_its_remote_ref_the_same_from_a_real_repo_and_the_fake(
        history, where, tmp_path):
    origin, _, sha = history
    root = clone(origin, tmp_path / "clone")
    run_git(root, "update-ref", "-d", "refs/remotes/origin/side")
    git = adapter(root, where)

    assert alike(git, "fetch_default_branch", "side") is True
    assert git.resolve_commit("refs/remotes/origin/side") == sha["s1"]
    assert fails_alike(git, "fetch_default_branch", "nowhere") is False


def test_path_exists_at_reads_the_same_from_a_real_repo_and_the_fake(history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "path_exists_at", MAIN, "sub/keep.txt") is True
    assert alike(git, "path_exists_at", sha["c1"], "old.txt") is True
    assert fails_alike(git, "path_exists_at", MAIN, "old.txt") is False
    assert fails_alike(git, "path_exists_at", MISSING, "f.txt") is False


def hunk_headers(diff):
    return [line for line in diff.text.splitlines() if line.startswith("@@")]


def test_a_file_s_diff_reads_the_same_from_a_real_repo_and_the_fake(history, where):
    _, root, sha = history
    git = adapter(root, where)

    changed = alike(git, "file_diff", sha["c1"], MAIN, "f.txt")
    assert (changed.differs, hunk_headers(changed)) == (True, ["@@ -1,2 +1,2 @@", "@@ -4 +3,0 @@"])
    assert alike(git, "file_diff", sha["c2"], sha["s1"], "sub/keep.txt") == (False, "")
    assert fails_alike(git, "file_diff", MISSING, MAIN, "f.txt") is None


def test_merge_bases_read_the_same_from_a_real_repo_and_the_fake(history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "merge_base", sha["s1"], MAIN) == sha["c2"]
    assert fails_alike(git, "merge_base", MISSING, MAIN) is None
    assert alike(git, "is_ancestor", sha["t1"], MAIN) is True
    assert fails_alike(git, "is_ancestor", sha["s1"], MAIN) is False
    assert fails_alike(git, "is_ancestor", MISSING, MAIN) is False


def test_an_ancestry_that_cannot_be_judged_reads_apart_from_none_from_both(history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "ancestry", sha["t1"], MAIN) is True
    assert alike(git, "ancestry", sha["s1"], MAIN) is False
    assert fails_alike(git, "ancestry", MISSING, MAIN) is None


# The commit-list logs: (operation, commits of main since c1 touching f.txt,
# by name). The merge m touches f.txt against its first parent alone.
FILE_LOGS = [
    ("file_commits", ["t1", "c3", "c2"]),
    ("first_parent_file_commits", ["m", "c3", "c2"]),
    ("file_commits_oldest_first", ["c2", "c3", "t1"]),
    ("newest_file_commit", ["t1"]),
]


@pytest.mark.parametrize("name, commits", FILE_LOGS, ids=[name for name, _ in FILE_LOGS])
def test_a_file_s_commit_list_reads_the_same_from_a_real_repo_and_the_fake(
        history, where, name, commits):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, name, MAIN, sha["c1"], "f.txt") == [sha[c] for c in commits]
    assert alike(git, name, MAIN, sha["c4"], "old.txt") == []
    assert fails_alike(git, name, MAIN, MISSING, "f.txt") is None


def test_the_newest_commit_touching_lines_reads_the_same_from_a_real_repo_and_the_fake(
        history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "newest_lines_commit", MAIN, sha["c1"], "f.txt", [(1, 1)]) == [sha["t1"]]
    assert alike(git, "newest_lines_commit", MAIN, sha["c1"], "f.txt", [(3, 3), (2, 2)]) \
        == [sha["c2"]]
    assert alike(git, "newest_lines_commit", MAIN, sha["c1"], "f.txt", [(3, 3)]) == []
    assert fails_alike(git, "newest_lines_commit", MAIN, sha["c1"], "f.txt", [(9, 9)]) is None


def test_a_reverse_blame_s_last_seen_commits_read_the_same_from_a_real_repo_and_the_fake(
        history, where):
    _, root, sha = history
    git = adapter(root, where)

    assert alike(git, "blame_last_seen", sha["c1"], MAIN, "f.txt", 4, 4) == [sha["c2"]]
    assert alike(git, "blame_last_seen", sha["c1"], MAIN, "f.txt", 3, 4) \
        == sorted([sha["c2"], sha["m"]])
    assert fails_alike(git, "blame_last_seen", sha["c1"], MAIN, "f.txt", 9, 9) is None
    assert fails_alike(git, "blame_last_seen", MISSING, MAIN, "f.txt", 1, 1) is None


def test_origin_head_s_branch_reads_the_same_from_a_real_repo_and_the_fake(
        history, where, tmp_path):
    _, root, _ = history
    plain = tmp_path / "plain"
    git_repo(plain, ORIGIN)
    (plain / "sub").mkdir()

    assert alike(adapter(root, where), "origin_head_branch") == "main"
    assert fails_alike(adapter(plain, where), "origin_head_branch") is None


@pytest.mark.parametrize("name, valid", [
    ("main", True), ("feature/x-1", True), ("", False), ("a..b", False), ("-x", False),
    ("refs/heads/@{-1}", False),
])
def test_the_branch_name_check_reads_the_same_from_a_real_repo_and_the_fake(
        history, where, name, valid):
    _, root, _ = history
    git = adapter(root, where)
    check = alike if valid else fails_alike

    assert check(git, "is_branch_name", name) is valid


def test_the_fake_refuses_to_seed_an_operation_it_does_not_have():
    with pytest.raises(ValueError, match="no seeded operation 'run'"):
        FakeGit().seed("run", "status", answer="")


# --- the verification noun's operations --------------------------------------

# The working-tree state the bash verification noun hashed before its
# conversion, verbatim but for ROOT and ORCH_DIR_NAME: the source of truth the
# adapter's tree_state answers as, so a record a bash runner left matches when
# its tree does.
BASH_TREE_STATE = r'''
ROOT="$1" ORCH_DIR_NAME=.orchestrator
{
  printf 'head %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)"
  git -C "$ROOT" diff HEAD --binary 2>/dev/null || git -C "$ROOT" diff --binary 2>/dev/null || true
  git -C "$ROOT" ls-files --others --exclude-standard -z -- ":!$ORCH_DIR_NAME" 2>/dev/null | (
    cd "$ROOT" && while IFS= read -r -d '' f; do
      printf 'untracked %s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
    done
  )
} | git hash-object --stdin
'''


def bash_tree_state(root):
    return subprocess.run(
        ["bash", "-c", BASH_TREE_STATE, "_", str(root)], check=True, cwd=str(root),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
    ).stdout.decode().strip()


@pytest.fixture
def worked(tmp_path):
    """A repository with one commit, then a staged edit, an unstaged edit, a
    binary file, an untracked file in a sub directory, an ignored file and a
    file under .orchestrator: its root."""
    root = tmp_path / "worked"
    git_repo(root)
    committed(root, {".gitignore": "ig.log\n", "a.txt": "a\n", "b.txt": "b\n",
                     "sub/keep.txt": "k\n"}, "first")
    write_staged(root, {"a.txt": "a2\n"})
    (root / "b.txt").write_text("b2\n")
    (root / "bin.dat").write_bytes(b"\0\1\2")
    (root / "sub" / "new.txt").write_text("new\n")
    (root / "ig.log").write_text("ignored\n")
    (root / ".orchestrator").mkdir()
    (root / ".orchestrator" / "x").write_text("x\n")
    return root


def test_the_tree_state_reads_as_the_bash_noun_s_and_the_same_from_the_fake(worked, where):
    assert alike(adapter(worked, where), "tree_state") == bash_tree_state(worked)


def test_an_unborn_branch_s_tree_state_reads_as_the_bash_noun_s(tmp_path):
    root = tmp_path / "unborn"
    git_repo(root)
    (root / "new.txt").write_text("new\n")

    assert Git(cwd=str(root)).tree_state() == bash_tree_state(root)


def test_the_tree_state_follows_tracked_and_untracked_content_but_no_ignored_file(worked):
    git = Git(cwd=str(worked))
    before = git.tree_state()
    (worked / "ig.log").write_text("ignored again\n")
    (worked / ".orchestrator" / "x").write_text("x again\n")
    unmoved = git.tree_state()
    (worked / "sub" / "new.txt").write_text("newer\n")

    assert (unmoved, git.tree_state() != before) == (before, True)


def test_outside_a_repository_there_is_no_tree_state(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "tree_state") is None


def test_a_text_s_hash_reads_as_git_s_object_name_and_the_same_from_the_fake(worked):
    # The blob name of "root /r\n", as `git hash-object --stdin` gives it.
    assert alike(Git(cwd=str(worked)), "text_hash", "root /r\n") == \
        "2768d62fb131c996f9397aaddaab1f0600ac4382"


def test_a_config_value_reads_the_same_from_a_real_repo_and_the_fake(worked):
    run_git(worked, "config", "orchestrator.verification.timeout", "1.5")
    git = Git(cwd=str(worked))

    assert alike(git, "config_value", "orchestrator.verification.timeout") == "1.5"
    assert fails_alike(git, "config_value", "orchestrator.unset") is None


def test_the_main_checkout_reads_the_same_from_a_worktree_and_the_fake(worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "side")

    assert alike(Git(cwd=str(wt)), "main_checkout") == str(worked.resolve())
    assert fails_alike(Git(cwd=str(tmp_path)), "main_checkout") is None


# --- the planning allowlist's dirty-path scan's operation -----------------------


def test_the_dirty_paths_read_the_same_from_a_real_repo_and_the_fake(worked, where):
    assert alike(adapter(worked, where), "dirty_paths") == [
        "a.txt", "b.txt", ".orchestrator/x", "bin.dat", "sub/new.txt",
    ]


def test_outside_a_repository_the_dirty_paths_are_git_s_error_line(tmp_path):
    answer = Git(cwd=str(tmp_path)).dirty_paths()

    assert answer.startswith("fatal: not a git repository")


def test_an_unseeded_fake_answers_the_dirty_paths_with_no_reason():
    assert FakeGit().dirty_paths() == "git gave no reason"


# --- the checkout scan's operations ---------------------------------------------


def test_the_worktree_list_reads_the_same_from_a_worktree_and_the_fake(worked, tmp_path):
    run_git(worked, "checkout", "-qb", "trunk")
    wt = worktree_add(worked, tmp_path / "wt", "-b", "side")
    detached = worktree_add(worked, tmp_path / "detached", "--detach")

    assert alike(Git(cwd=str(wt)), "worktree_list") == [
        Worktree(str(worked.resolve()), "trunk"),
        Worktree(str(detached.resolve()), None),
        Worktree(str(wt.resolve()), "side"),
    ]


def test_outside_a_repository_there_is_no_worktree_list(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "worktree_list") is None


def test_a_branch_at_another_checkout_reads_the_same_from_a_real_repo_and_the_fake(
        worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "quick/7-bar")

    assert alike(Git(cwd=str(worked)), "branch_at", str(wt)) == "quick/7-bar"


def test_a_detached_or_missing_checkout_has_no_branch_at(worked, tmp_path):
    run_git(worked, "checkout", "-q", "--detach")
    git = Git(cwd=str(tmp_path))

    assert fails_alike(git, "branch_at", str(worked)) is None
    assert fails_alike(git, "branch_at", str(tmp_path / "gone")) is None


def test_the_absolute_git_dir_at_a_worktree_reads_the_same_from_a_real_repo_and_the_fake(
        worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "side")

    assert alike(Git(cwd=str(tmp_path)), "absolute_git_dir_at", str(wt)) == \
        str((worked / ".git" / "worktrees" / "wt").resolve())
    assert fails_alike(Git(cwd=str(tmp_path)), "absolute_git_dir_at", str(tmp_path)) is None


# --- the exclude writer's operation -------------------------------------------


def test_the_common_dir_reads_the_same_from_a_real_repo_and_the_fake(worked, where):
    expected = ".git" if where == "top" else "../.git"

    assert alike(adapter(worked, where), "git_common_dir") == expected


def test_a_worktree_s_common_dir_is_its_main_checkout_s_git_directory(worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "common")

    assert alike(Git(cwd=str(wt)), "git_common_dir") == str((worked / ".git").resolve())


def test_outside_a_repository_there_is_no_common_dir(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "git_common_dir") is None


# --- the review pass's operation ------------------------------------------------


def test_the_current_branch_reads_the_same_from_a_real_repo_and_the_fake(worked, where):
    run_git(worked, "checkout", "-qb", "quick/12-foo")

    assert alike(adapter(worked, where), "current_branch") == "quick/12-foo"


def test_an_unborn_branch_is_the_current_branch(tmp_path):
    git_repo(tmp_path / "fresh")
    run_git(tmp_path / "fresh", "symbolic-ref", "HEAD", "refs/heads/first")

    assert alike(Git(cwd=str(tmp_path / "fresh")), "current_branch") == "first"


def test_a_detached_head_has_no_current_branch(worked):
    run_git(worked, "checkout", "-q", "--detach")

    assert fails_alike(Git(cwd=str(worked)), "current_branch") is None


def test_outside_a_repository_there_is_no_current_branch(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "current_branch") is None


# --- the side checkout's worktree removal ------------------------------------------


def test_a_clean_worktree_is_removed_the_same_from_a_real_repo_and_the_fake(worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "side")

    assert alike(Git(cwd=str(tmp_path)), "worktree_remove", str(worked), str(wt)) is None
    assert not wt.exists()


def test_a_dirty_worktree_is_kept_with_git_s_first_error_line(worked, tmp_path):
    wt = worktree_add(worked, tmp_path / "wt", "-b", "side")
    (wt / "wip.txt").write_text("wip\n")

    assert alike(Git(cwd=str(tmp_path)), "worktree_remove", str(worked), str(wt)) == (
        "fatal: '%s' contains modified or untracked files, use --force to delete it" % wt)
    assert (wt / "wip.txt").exists()


def test_an_unseeded_worktree_removal_on_the_fake_fails_with_no_reason():
    assert FakeGit().worktree_remove("/main", "/main/wt") == "git gave no reason"


# --- the claim delete's push ------------------------------------------------------


@pytest.fixture
def pushed(tmp_path):
    """A clone of a bare origin under tmp_path whose main and b, both pushed,
    were then rewritten in the clone, so pushing either is rejected: the
    clone's root."""
    origin, root = tmp_path / "origin.git", tmp_path / "pushing"
    origin_clone(origin, root, "main")
    run_git(root, "checkout", "-qb", "main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "one")
    run_git(root, "branch", "b")
    run_git(root, "push", "-q", "origin", "main", "b")
    run_git(root, "commit", "-q", "--amend", "--allow-empty", "-m", "two")
    run_git(root, "checkout", "-q", "b")
    run_git(root, "commit", "-q", "--amend", "--allow-empty", "-m", "three")
    return root


def test_a_push_that_lands_answers_none_from_a_real_repo_and_the_fake(pushed):
    run_git(pushed, "checkout", "-q", "main")

    assert alike(Git(cwd=str(pushed)), "push", "origin", "+main:refs/heads/new") is None
    assert run_git(pushed, "ls-remote", "origin", "refs/heads/new") != ""


def test_a_rejected_push_gives_its_ref_lines_trimmed_and_joined(pushed):
    assert alike(Git(cwd=str(pushed)), "push", "origin", "refs/heads/*:refs/heads/*") == (
        "! [rejected]        b -> b (non-fast-forward); "
        "! [rejected]        main -> main (non-fast-forward)")


def test_a_push_to_no_repository_gives_its_first_fatal_line(pushed):
    assert alike(Git(cwd=str(pushed)), "push", "nope", ":refs/heads/b") == (
        "fatal: 'nope' does not appear to be a git repository")


def test_a_push_with_no_ref_or_fatal_line_gives_its_first_non_empty_line(pushed):
    assert alike(Git(cwd=str(pushed)), "push", "origin", "nosuch:refs/heads/x") == (
        "error: src refspec nosuch does not match any")


@pytest.mark.parametrize("stderr", ["", "\n  \n\t\n"], ids=["empty", "blank-lines"])
def test_a_push_that_printed_nothing_gives_git_gave_no_reason(stderr):
    assert git_push_reason(stderr) == "git gave no reason"


def test_an_unseeded_push_on_the_fake_fails_with_no_reason():
    assert FakeGit().push("origin", ":refs/orch/claims/5") == "git gave no reason"


def test_a_lease_push_lands_once_and_then_is_refused_while_origin_holds_the_ref(pushed):
    git = Git(cwd=str(pushed))
    git_identity(pushed)
    commit = git.empty_commit("orch claim 5", "host: h")

    assert alike(git, "push_new_ref", "origin", commit, "refs/orch/claims/5") is None
    other = git.empty_commit("orch claim 5", "host: other")
    assert "stale info" in alike(git, "push_new_ref", "origin", other, "refs/orch/claims/5")
    assert run_git(pushed.parent / "origin.git", "log", "-1", "--format=%s%n%b",
                   "refs/orch/claims/5") == (
        "orch claim 5\nhost: h")


def test_an_unseeded_claim_commit_and_lease_push_on_the_fake_fail():
    assert FakeGit().empty_commit("s", "b") is None
    assert FakeGit().push_new_ref("origin", "c", "refs/orch/claims/5") == "git gave no reason"


# --- branch retire's operations ----------------------------------------------------


@pytest.fixture
def retiring(tmp_path):
    """A clone of a bare origin under tmp_path holding main, pushed and
    tracking origin/main, and gone, never pushed: the clone's root."""
    origin, root = tmp_path / "origin.git", tmp_path / "retiring"
    origin_clone(origin, root, "main")
    run_git(root, "checkout", "-qb", "main")
    run_git(root, "commit", "-q", "--allow-empty", "-m", "one")
    run_git(root, "push", "-q", "-u", "origin", "main")
    run_git(root, "branch", "gone")
    return root


def retiring_fake():
    """The FakeGit holding the local branches the retiring fixture holds."""
    return FakeGit(branches={"main": "refs/remotes/origin/main", "gone": None})


def test_a_local_branch_exists_the_same_from_a_real_repo_and_the_fake(retiring):
    git, fake = Git(cwd=str(retiring)), retiring_fake()

    for name, exists in (("main", True), ("gone", True), ("nope", False)):
        assert (git.branch_exists(name), fake.branch_exists(name)) == (exists, exists)


def test_a_branch_s_upstream_reads_the_same_from_a_real_repo_and_the_fake(retiring):
    git, fake = Git(cwd=str(retiring)), retiring_fake()

    for name, upstream in (("main", "refs/remotes/origin/main"), ("gone", None),
                           ("nope", None)):
        assert (git.branch_upstream(name), fake.branch_upstream(name)) == (upstream, upstream)


def test_a_rename_moves_the_branch_and_its_upstream_the_same_from_a_real_repo_and_the_fake(
        retiring):
    git, fake = Git(cwd=str(retiring)), retiring_fake()

    for adapter_ in (git, fake):
        assert adapter_.branch_rename("main", "kept") is None
        assert (adapter_.branch_exists("main"), adapter_.branch_exists("kept"),
                adapter_.branch_upstream("kept")) == (False, True, "refs/remotes/origin/main")


@pytest.mark.parametrize("old, new, stderr", [
    ("nope", "kept", "fatal: no branch named 'nope'\n"),
    ("main", "gone", "fatal: a branch named 'gone' already exists\n"),
], ids=["missing", "taken"])
def test_a_rename_git_refuses_gives_its_status_and_stderr_the_same_from_both(
        retiring, old, new, stderr):
    git, fake = Git(cwd=str(retiring)), retiring_fake()
    real = git.branch_rename(old, new)

    # git's own wording moves between versions ("No branch named 'nope'." on
    # older ones), so the real run is held to its status and the branch its
    # refusal names; the fake gives today's wording exactly.
    assert fake.branch_rename(old, new) == GitFailure(128, stderr)
    assert real.code == 128
    assert real.stderr.startswith("fatal: ") and "'%s'" % stderr.split("'")[1] in real.stderr
    assert fake.branch_exists(old) is (old == "main")


def test_origin_s_answer_for_a_branch_reads_the_same_from_a_real_repo_and_the_fake(
        retiring, tmp_path):
    git = Git(cwd=str(retiring))

    assert alike(git, "origin_has_branch", "main") is True
    assert alike(git, "origin_has_branch", "gone") is False
    run_git(retiring, "remote", "set-url", "origin", str(tmp_path / "nowhere"))
    assert fails_alike(git, "origin_has_branch", "main") is None


def test_a_tracking_push_lands_and_sets_the_upstream(retiring):
    git = Git(cwd=str(retiring))

    assert alike(git, "push_set_upstream", "origin", "refs/heads/gone:refs/heads/gone") is None
    assert (git.origin_has_branch("gone"), git.branch_upstream("gone")) == (
        True, "refs/remotes/origin/gone")


def test_a_remote_delete_removes_origin_s_branch_and_a_refused_one_gives_its_reason(
        retiring):
    git = Git(cwd=str(retiring))
    run_git(retiring, "push", "-q", "origin", "gone")

    assert alike(git, "remote_delete", "origin", "refs/heads/gone") is None
    assert git.origin_has_branch("gone") is False
    assert alike(git, "remote_delete", "origin", "refs/heads/main") == (
        "! [remote rejected] main (deletion of the current branch prohibited)")


def test_an_unseeded_tracking_push_or_remote_delete_on_the_fake_fails_with_no_reason():
    fake = FakeGit()

    assert (fake.push_set_upstream("origin", "refs/heads/a:refs/heads/a"),
            fake.remote_delete("origin", "refs/heads/a")) == (
        "git gave no reason", "git gave no reason")


# --- scoped git config -------------------------------------------------------


@pytest.fixture
def config_env(tmp_path, monkeypatch):
    """A fresh repo and an isolated throwaway HOME for scoped git config
    parity tests: (repo_root, home_dir, real_git)."""
    root = tmp_path / "cfg-repo"
    home = tmp_path / "cfg-home"
    home.mkdir()
    monkeypatch.setenv("HOME", str(home))
    for name in GLOBAL_CONFIG:
        monkeypatch.delenv(name, raising=False)
    real = git_repo(root)
    return root, home, real


@pytest.mark.parametrize("scope", ["local", "global"])
def test_config_regexp_returns_empty_mapping_when_no_keys_match(config_env, scope):
    _, _, real = config_env
    fake = FakeGit()

    assert real.config_regexp(scope, r"^orchestrator\.") == {}
    assert fake.config_regexp(scope, r"^orchestrator\.") == {}


def test_config_regexp_isolates_local_and_global_scopes(config_env):
    root, _, real = config_env
    run_git(root, "config", "--local", "orchestrator.model.implementer", "opus")
    run_git(root, "config", "--global", "orchestrator.model.implementer", "sonnet")
    run_git(root, "config", "--global", "orchestrator.effort.lens", "high")
    fake = FakeGit(
        local_config={"orchestrator.model.implementer": "opus"},
        global_config={
            "orchestrator.model.implementer": "sonnet",
            "orchestrator.effort.lens": "high",
        },
    )

    assert real.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "opus",
    }
    assert fake.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "opus",
    }
    assert real.config_regexp("global", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "sonnet",
        "orchestrator.effort.lens": "high",
    }
    assert fake.config_regexp("global", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "sonnet",
        "orchestrator.effort.lens": "high",
    }


def test_config_regexp_matches_bash_cache_semantics_for_spaces_valueless_multiline_dups_and_newlines(
    config_env,
):
    root, _, real = config_env
    with (root / ".git" / "config").open("a", encoding="utf-8") as f:
        f.write('[orchestrator "model"]\n\tvalueless\n')
    run_git(root, "config", "--local", "orchestrator.model.spaces", "  opus  ")
    run_git(root, "config", "--local", "orchestrator.model.multi", "line1\nline2\n\n")
    run_git(root, "config", "--local", "orchestrator.model.onlynl", "\n\n")
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "first")
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "second")
    run_git(root, "config", "--local", "other.section.key", "ignored")
    fake = FakeGit(
        local_config=[
            ("orchestrator.model.valueless", None),
            ("orchestrator.model.spaces", "  opus  "),
            ("orchestrator.model.multi", "line1\nline2\n\n"),
            ("orchestrator.model.onlynl", "\n\n"),
            ("orchestrator.model.dup", "first"),
            ("orchestrator.model.dup", "second"),
            ("other.section.key", "ignored"),
        ]
    )

    want = {
        "orchestrator.model.valueless": "",
        "orchestrator.model.spaces": "  opus  ",
        "orchestrator.model.multi": "line1\nline2",
        "orchestrator.model.onlynl": "",
        "orchestrator.model.dup": "second",
    }
    assert real.config_regexp("local", r"^orchestrator\.") == want
    assert fake.config_regexp("local", r"^orchestrator\.") == want


def test_config_regexp_rejects_invalid_scope():
    real = Git()
    fake = FakeGit()

    with pytest.raises(ValueError, match="scope"):
        real.config_regexp("system", r"^orchestrator\.")
    with pytest.raises(ValueError, match="scope"):
        fake.config_regexp("system", r"^orchestrator\.")


def test_config_set_writes_overwrites_and_isolates_scopes_the_same(config_env):
    _, _, real = config_env
    fake = FakeGit()

    for git in (real, fake):
        assert git.config_set("local", "orchestrator.model.implementer", "opus") is None
        assert git.config_set("local", "orchestrator.model.implementer", "  sonnet  ") is None
        assert git.config_set("global", "orchestrator.model.implementer", "-custom") is None
        assert git.config_regexp("local", r"^orchestrator\.") == {
            "orchestrator.model.implementer": "  sonnet  ",
        }
        assert git.config_regexp("global", r"^orchestrator\.") == {
            "orchestrator.model.implementer": "-custom",
        }


def test_config_set_fails_on_duplicate_keys_the_same(config_env):
    root, _, real = config_env
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "first")
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "second")
    fake = FakeGit(
        local_config=[
            ("orchestrator.model.dup", "first"),
            ("orchestrator.model.dup", "second"),
        ]
    )

    for git in (real, fake):
        assert git.config_set("local", "orchestrator.model.dup", "third").code == 5
        assert git.config_regexp("local", r"^orchestrator\.") == {
            "orchestrator.model.dup": "second",
        }


def test_config_unset_removes_present_and_duplicate_keys_and_accepts_absent_keys(config_env):
    root, _, real = config_env
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "first")
    run_git(root, "config", "--local", "--add", "orchestrator.model.dup", "second")
    run_git(root, "config", "--global", "orchestrator.model.dup", "global-val")
    fake = FakeGit(
        local_config=[
            ("orchestrator.model.dup", "first"),
            ("orchestrator.model.dup", "second"),
        ],
        global_config={"orchestrator.model.dup": "global-val"},
    )

    for git in (real, fake):
        assert git.config_unset("local", "orchestrator.model.absent") is True
        assert git.config_unset("global", "orchestrator.model.absent") is True
        assert git.config_unset("local", "orchestrator.model.dup") is True
        assert git.config_regexp("local", r"^orchestrator\.") == {}
        assert git.config_regexp("global", r"^orchestrator\.") == {
            "orchestrator.model.dup": "global-val",
        }
        assert git.config_unset("global", "orchestrator.model.dup") is True
        assert git.config_regexp("global", r"^orchestrator\.") == {}


@pytest.mark.parametrize("scope", ["local", "global"])
def test_config_set_and_unset_fail_on_lock_errors_even_for_absent_keys(config_env, scope):
    root, home, real = config_env
    assert real.config_set(scope, "orchestrator.model.closer", "haiku") is None
    lock = (root / ".git" / "config.lock") if scope == "local" else (home / ".gitconfig.lock")
    lock.write_text("")
    fake = FakeGit(
        local_config={"orchestrator.model.closer": "haiku"} if scope == "local" else None,
        global_config={"orchestrator.model.closer": "haiku"} if scope == "global" else None,
        config_write_fails={scope},
    )

    try:
        for git in (real, fake):
            failed = git.config_set(scope, "orchestrator.model.closer", "opus")
            assert (failed.code, failed.stderr.startswith("error: could not lock config file ")) \
                == (255, True)
            assert git.config_unset(scope, "orchestrator.model.closer") is False
            assert git.config_unset(scope, "orchestrator.model.absent") is False
            assert git.config_regexp(scope, r"^orchestrator\.") == {
                "orchestrator.model.closer": "haiku",
            }
    finally:
        lock.unlink()


def test_fake_git_can_fail_a_single_scoped_key_write():
    fake = FakeGit(
        local_config={"orchestrator.effort.implementer": "low"},
        config_write_fails={("local", "orchestrator.effort.implementer")},
    )

    assert fake.config_set("local", "orchestrator.model.implementer", "opus") is None
    assert fake.config_set("local", "orchestrator.effort.implementer", "high") is not None
    assert fake.config_unset("local", "orchestrator.effort.implementer") is False
    assert fake.config_regexp("local", r"^orchestrator\.") == {
        "orchestrator.model.implementer": "opus",
        "orchestrator.effort.implementer": "low",
    }


def test_config_set_and_unset_reject_invalid_scope():
    real = Git()
    fake = FakeGit()

    for git in (real, fake):
        with pytest.raises(ValueError, match="scope"):
            git.config_set("system", "orchestrator.model.implementer", "opus")
        with pytest.raises(ValueError, match="scope"):
            git.config_unset("system", "orchestrator.model.implementer")


# --- the ticket nouns' operations: a ticket branch's life, from its fork to its
# --- fast-forward, in its ticket worktree --------------------------------------

PARENT = "orch/4-feature"
TICKET = PARENT + "--t5"
FORKED_KEY = "branch.%s.orchestrator-ticket-parent" % TICKET


@pytest.fixture
def forking(tmp_path):
    """A clone of a bare origin under tmp_path on PARENT, one commit pushed
    and tracking origin's PARENT, with branch.autoSetupMerge always, so only
    an explicit --no-track keeps a new branch from tracking: its root,
    resolved."""
    origin, root = tmp_path / "origin.git", tmp_path.resolve() / "forking"
    origin_clone(origin, root, PARENT)
    run_git(root, "checkout", "-qb", PARENT)
    committed(root, {"a.txt": "a\n"}, "one")
    run_git(root, "push", "-q", "-u", "origin", PARENT)
    run_git(root, "config", "branch.autoSetupMerge", "always")
    return root


def test_a_branch_is_created_at_its_start_tracking_nothing_the_same_from_both(forking):
    git, fake = Git(cwd=str(forking)), FakeGit(branches={PARENT: "refs/remotes/origin/" + PARENT})

    for adapter_ in (git, fake):
        assert adapter_.branch_create(TICKET, "HEAD") is None
        assert (adapter_.branch_exists(TICKET), adapter_.branch_upstream(TICKET)) == (True, None)
    assert run_git(forking, "rev-parse", TICKET) == run_git(forking, "rev-parse", PARENT)


def test_a_branch_git_refuses_to_create_gives_its_status_and_stderr_the_same_from_both(forking):
    git, fake = Git(cwd=str(forking)), FakeGit(branches={PARENT: None})
    real = git.branch_create(PARENT, "HEAD")

    # As for a refused rename: the real run is held to its status and the
    # branch its refusal names, the fake to today's wording exactly.
    assert fake.branch_create(PARENT, "HEAD") == GitFailure(
        128, "fatal: a branch named '%s' already exists\n" % PARENT)
    assert real.code == 128
    assert real.stderr.startswith("fatal: ") and "'%s'" % PARENT in real.stderr


def test_a_deleted_branch_takes_its_config_section_with_it_merged_or_not_the_same_from_both(
        forking):
    run_git(forking, "checkout", "-qb", TICKET)
    committed(forking, {"b.txt": "b\n"}, "unmerged")
    run_git(forking, "checkout", "-q", PARENT)
    run_git(forking, "config", FORKED_KEY, PARENT)
    git = Git(cwd=str(forking))
    fake = FakeGit(branches={PARENT: None, TICKET: None}, local_config={FORKED_KEY: PARENT})

    for adapter_ in (git, fake):
        assert adapter_.config_value(FORKED_KEY) == PARENT
        assert adapter_.branch_delete(TICKET) is None
        assert (adapter_.branch_exists(TICKET), adapter_.config_value(FORKED_KEY)) == (False, None)


def test_a_branch_git_cannot_delete_gives_its_status_and_stderr_the_same_from_both(forking):
    real = Git(cwd=str(forking)).branch_delete("nope")

    assert FakeGit().branch_delete("nope") == GitFailure(1, "error: branch 'nope' not found\n")
    assert real.code == 1
    assert real.stderr.startswith("error: ") and "'nope'" in real.stderr


# --- a new branch checked out, as branch off and branch create fork one ----------


@pytest.mark.parametrize("start", ["refs/remotes/origin/" + PARENT, "refs/heads/" + PARENT],
                         ids=["origin-s-ref", "local-base"])
def test_a_new_branch_is_checked_out_at_its_start_tracking_nothing_the_same_from_both(
        forking, start):
    # The local base moves on past origin's, so each start forks elsewhere.
    committed(forking, {"b.txt": "b\n"}, "local only")
    commit = run_git(forking, "rev-parse", start)
    git = Git(cwd=str(forking))
    fake = FakeGit(branches={PARENT: "refs/remotes/origin/" + PARENT})
    fake.seed("resolve_commit", start, answer=commit)

    for adapter_ in (git, fake):
        assert adapter_.checkout_new_branch(TICKET, start) is None
        assert (adapter_.current_branch(), adapter_.branch_upstream(TICKET),
                adapter_.resolve_commit("HEAD")) == (TICKET, None, commit)


@pytest.mark.parametrize("name, start, stderr", [
    (PARENT, "HEAD", "fatal: a branch named '%s' already exists\n" % PARENT),
    (TICKET, "refs/heads/nope",
     "fatal: 'refs/heads/nope' is not a commit and a branch '%s' cannot be created from it\n"
     % TICKET),
], ids=["taken", "no-such-start"])
def test_a_new_branch_git_refuses_to_check_out_gives_its_status_and_stderr_the_same_from_both(
        forking, name, start, stderr):
    git, fake = Git(cwd=str(forking)), FakeGit(branches={PARENT: None})
    fake.seed("resolve_commit", "HEAD", answer=run_git(forking, "rev-parse", "HEAD"))
    real = git.checkout_new_branch(name, start)

    # As for a refused rename: the real run is held to its status and the
    # names its refusal quotes, the fake to today's wording exactly.
    assert fake.checkout_new_branch(name, start) == GitFailure(128, stderr)
    assert real.code == 128
    assert real.stderr.startswith("fatal: ") and "'%s'" % name in real.stderr
    assert (git.current_branch(), fake.current_branch()) == (PARENT, None)


# --- an existing branch checked out, as branch create's restart does -------------


def test_an_existing_branch_is_checked_out_beside_a_same_named_tag_the_same_from_both(forking):
    # The tag sits on the newer commit: the branch, never the tag, is taken.
    branched = run_git(forking, "rev-parse", "HEAD")
    run_git(forking, "branch", TICKET)
    committed(forking, {"b.txt": "b\n"}, "two")
    run_git(forking, "tag", TICKET, "HEAD")
    git, fake = Git(cwd=str(forking)), FakeGit(branches={PARENT: None, TICKET: None})

    for adapter_ in (git, fake):
        assert adapter_.checkout_existing_branch(TICKET) is None
        assert adapter_.current_branch() == TICKET
    assert run_git(forking, "rev-parse", "HEAD") == branched


def test_a_branch_that_does_not_exist_is_refused_with_git_s_status_and_stderr_from_both(forking):
    git, fake = Git(cwd=str(forking)), FakeGit(branches={PARENT: None})
    fake.seed("current_branch", answer=PARENT)
    real = git.checkout_existing_branch("nope")

    assert fake.checkout_existing_branch("nope") == GitFailure(
        1, "error: pathspec 'nope' did not match any file(s) known to git\n")
    assert real.code == 1 and "'nope'" in real.stderr
    assert (git.current_branch(), fake.current_branch()) == (PARENT, PARENT)


def test_a_worktree_is_added_on_an_existing_branch_the_same_from_a_real_repo_and_the_fake(
        forking):
    run_git(forking, "branch", TICKET)
    path = forking / ".orchestrator" / "worktrees" / "t5"

    assert alike(Git(cwd=str(forking)), "worktree_add", str(path), TICKET) is None
    assert run_git(path, "symbolic-ref", "HEAD") == "refs/heads/" + TICKET


def test_a_worktree_git_refuses_to_add_gives_its_status_and_stderr(forking):
    path = forking / ".orchestrator" / "worktrees" / "t5"
    failed = Git(cwd=str(forking)).worktree_add(str(path), "nope")

    assert failed.code == 128 and failed.stderr.startswith("fatal: ")
    assert not path.exists()


def test_an_unseeded_worktree_add_on_the_fake_fails_with_no_stderr():
    assert FakeGit().worktree_add("/main/.orchestrator/worktrees/t5", TICKET) == GitFailure(1, "")


def test_a_ticket_worktree_is_deleted_the_same_from_a_real_repo_and_the_fake(forking):
    path = worktree_add(forking, forking / ".orchestrator" / "worktrees" / "t5", "-b", TICKET)

    assert alike(Git(cwd=str(forking)), "worktree_delete", str(path)) is None
    assert not path.exists()
    assert run_git(forking, "rev-parse", "--verify", "refs/heads/" + TICKET)


def test_a_locked_worktree_git_refuses_to_delete_gives_its_status_and_whole_stderr(forking):
    path = worktree_add(forking, forking / ".orchestrator" / "worktrees" / "t5", "-b", TICKET)
    run_git(forking, "worktree", "lock", str(path))

    failed = Git(cwd=str(forking)).worktree_delete(str(path))

    assert failed.code == 128 and failed.stderr.startswith("fatal: ")
    assert failed.stderr.endswith("\n") and path.exists()


def test_an_unseeded_worktree_delete_on_the_fake_fails_with_no_stderr():
    assert FakeGit().worktree_delete("/main/.orchestrator/worktrees/t5") == GitFailure(1, "")


# --- side-checkout add's operations, run in the main checkout they name ----------


def test_the_base_fetch_in_a_named_checkout_moves_its_remote_ref_the_same_from_both(
        forking, tmp_path):
    run_git(forking, "update-ref", "-d", "refs/remotes/origin/" + PARENT)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()

    assert alike(Git(cwd=str(elsewhere)), "fetch_branch_at", str(forking), PARENT) is True
    assert run_git(forking, "rev-parse", "refs/remotes/origin/" + PARENT) == \
        run_git(forking, "rev-parse", PARENT)
    assert fails_alike(Git(cwd=str(elsewhere)), "fetch_branch_at", str(forking), "nowhere") \
        is False


def test_a_detached_worktree_is_added_at_a_ref_the_same_from_a_real_repo_and_the_fake(
        forking, tmp_path):
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    path = forking / ".orchestrator" / "checkouts" / "alpha"

    assert alike(Git(cwd=str(elsewhere)), "worktree_add_detached_at", str(forking), str(path),
                 "refs/remotes/origin/" + PARENT) is None
    assert run_git(path, "branch", "--show-current") == ""
    assert run_git(path, "rev-parse", "HEAD") == run_git(forking, "rev-parse", PARENT)


def test_a_detached_worktree_git_refuses_to_add_gives_its_status_and_stderr(forking):
    path = forking / ".orchestrator" / "checkouts" / "alpha"
    failed = Git().worktree_add_detached_at(str(forking), str(path), "refs/remotes/origin/nope")

    assert failed.code == 128 and failed.stderr.startswith("fatal: ")
    assert not path.exists()
    assert FakeGit().worktree_add_detached_at(str(forking), str(path), "x") == GitFailure(1, "")


@pytest.fixture
def landing(forking):
    """<forking> with TICKET forked from PARENT and checked out in its ticket
    worktree, one commit on each since, an identity a rebase commits with,
    and .orchestrator/ kept out of git status as the plugin keeps it: (the
    main checkout, the ticket worktree)."""
    git_identity(forking)
    exclude_orchestrator(forking)
    wt = worktree_add(forking, forking / ".orchestrator" / "worktrees" / "t5", "-b", TICKET)
    committed(wt, {"b.txt": "b\n"}, "ticket")
    committed(forking, {"c.txt": "c\n"}, "parent")
    return forking, wt


def conflicted(landing):
    """<landing>'s two branches, each with its own edit of a.txt since the
    fork: the ticket branch's tip."""
    main, wt = landing
    committed(wt, {"a.txt": "ticket\n"}, "ticket edit")
    committed(main, {"a.txt": "parent\n"}, "parent edit")
    return tip(main, TICKET)


def test_a_ticket_branch_rebases_onto_its_parent_in_its_worktree_the_same_from_both(landing):
    main, wt = landing

    assert alike(Git(cwd=str(main)), "rebase_at", str(wt), "refs/heads/" + PARENT) is None
    assert run_git(wt, "rev-parse", "HEAD~1") == tip(main, PARENT)


def test_a_conflicting_rebase_stops_on_its_unmerged_paths_and_its_abort_restores_the_tip(
        landing):
    main, wt = landing
    before = conflicted(landing)
    git = Git(cwd=str(main))
    stopped = git.rebase_at(str(wt), "refs/heads/" + PARENT)

    assert stopped.code == 1 and stopped.stderr.startswith("error: could not apply ")
    assert alike(git, "unmerged_paths_at", str(wt)) == ["a.txt"]
    assert alike(git, "rebase_abort_at", str(wt)) is None
    assert (tip(main, TICKET), git.unmerged_paths_at(str(wt))) == (before, [])


def test_an_unmerged_path_listing_that_cannot_run_reads_as_none_the_same_from_both(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "unmerged_paths_at", str(tmp_path)) == []


def test_aborting_no_rebase_gives_git_s_status_and_stderr(landing):
    failed = Git().rebase_abort_at(str(landing[1]))

    assert failed.code == 128 and failed.stderr.startswith("fatal: ")
    assert FakeGit().rebase_abort_at(str(landing[1])) == GitFailure(1, "")


def test_the_parent_fast_forwards_to_its_rebased_ticket_branch_in_its_checkout(landing):
    main, wt = landing
    git = Git(cwd=str(wt))
    git.rebase_at(str(wt), "refs/heads/" + PARENT)

    assert alike(git, "merge_ff_only_at", str(main), "refs/heads/" + TICKET) is None
    assert (tip(main, PARENT), run_git(main, "rev-parse", "HEAD")) == (tip(main, TICKET),) * 2


def test_a_parent_that_cannot_fast_forward_is_left_at_its_tip(landing):
    main, _ = landing
    before = tip(main, PARENT)
    failed = Git().merge_ff_only_at(str(main), "refs/heads/" + TICKET)

    # git's hint lines ahead of its fatal: line come and go between versions.
    assert failed.code == 128 and "\nfatal: " in "\n" + failed.stderr
    assert tip(main, PARENT) == before
    assert FakeGit().merge_ff_only_at(str(main), "refs/heads/" + TICKET) == GitFailure(1, "")


def test_a_branch_is_resolved_as_a_branch_never_as_a_tag_of_its_name(landing):
    # #2337: a tag named as each branch, at the fork point, which is an
    # ancestor of both - only refs/heads/ keeps the branches apart from it.
    main, wt = landing
    fork = run_git(main, "rev-parse", "HEAD~1")
    for name in (PARENT, TICKET, "tag-only"):
        run_git(main, "tag", name, fork)
    git = Git(cwd=str(main))

    assert alike(git, "is_ancestor", "refs/heads/" + TICKET, "refs/heads/" + PARENT) is False
    assert git.branch_exists("tag-only") is False
    assert git.rebase_at(str(wt), "refs/heads/" + PARENT) is None
    assert run_git(wt, "rev-parse", "HEAD~1") == tip(main, PARENT)
    assert git.merge_ff_only_at(str(main), "refs/heads/" + TICKET) is None
    assert alike(git, "is_ancestor", "refs/heads/" + TICKET, "refs/heads/" + PARENT) is True


# --- the clean-tree check's and the discard sequence's operations ---------------


def test_a_checkout_s_status_reads_the_same_from_a_real_repo_and_the_fake(landing, tmp_path):
    main, wt = landing
    (wt / "b.txt").write_text("edited\n")
    (wt / "new.txt").write_text("new\n")
    git = Git(cwd=str(tmp_path))

    assert alike(git, "status_at", str(main)) == ""
    assert alike(git, "status_at", str(wt)) == " M b.txt\n?? new.txt\n"


def test_a_status_that_cannot_run_gives_git_s_status_and_stderr(tmp_path):
    failed = Git().status_at(str(tmp_path))

    assert failed.code == 128 and failed.stderr.startswith("fatal: not a git repository")
    assert FakeGit().status_at(str(tmp_path)) == GitFailure(1, "")


def test_a_merge_in_progress_is_seen_and_aborted_the_same_from_a_real_repo_and_the_fake(
        landing):
    main, _ = landing
    conflicted(landing)
    subprocess.run(["git", "-C", str(main), "merge", "-q", TICKET], stdin=subprocess.DEVNULL,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    git = Git()

    assert alike(git, "merge_in_progress_at", str(main)) is True
    assert alike(git, "merge_abort_at", str(main)) is True
    assert fails_alike(git, "merge_in_progress_at", str(main)) is False
    assert fails_alike(git, "merge_abort_at", str(main)) is False


def test_a_hard_reset_and_a_clean_discard_tracked_then_untracked_work_the_same_from_both(
        landing):
    _, wt = landing
    (wt / "b.txt").write_text("edited\n")
    (wt / "sub").mkdir()
    (wt / "sub" / "new.txt").write_text("new\n")
    git = Git()

    assert alike(git, "reset_hard_at", str(wt)) is True
    assert git.status_at(str(wt)) == "?? sub/\n"
    assert alike(git, "clean_at", str(wt)) is True
    assert git.status_at(str(wt)) == ""


def test_a_reset_or_clean_that_cannot_run_fails_the_same_from_both(tmp_path):
    git = Git()

    assert fails_alike(git, "reset_hard_at", str(tmp_path)) is False
    assert fails_alike(git, "clean_at", str(tmp_path)) is False


# --- branch sync's operations ----------------------------------------------------------


def test_a_plain_merge_makes_a_merge_commit_with_git_s_own_message_the_same_from_both(
        landing):
    main, _ = landing
    before = tip(main, PARENT)

    assert alike(Git(cwd=str(main)), "merge_no_edit_at", str(main), "refs/heads/" + TICKET) is None
    assert (run_git(main, "rev-parse", "HEAD^1"), run_git(main, "rev-parse", "HEAD^2")) == (
        before, tip(main, TICKET))
    assert run_git(main, "log", "-1", "--format=%s") == (
        "Merge branch 'refs/heads/%s' into %s" % (TICKET, PARENT))


def test_a_conflicting_merge_fails_leaving_the_merge_in_progress(landing):
    main, _ = landing
    conflicted(landing)
    before = tip(main, PARENT)
    git = Git(cwd=str(main))
    failed = git.merge_no_edit_at(str(main), "refs/heads/" + TICKET)

    assert failed.code == 1 and git.merge_in_progress_at(str(main)) is True
    assert tip(main, PARENT) == before
    assert FakeGit().merge_no_edit_at(str(main), "refs/heads/" + TICKET) == GitFailure(1, "")


def test_the_newest_merge_on_the_first_parent_chain_is_found_under_fix_commits(landing):
    main, _ = landing
    git = Git(cwd=str(main))
    unmerged = alike(git, "newest_merge_commit", "HEAD")
    run_git(main, "merge", "-q", "--no-edit", "refs/heads/" + TICKET)
    merge = run_git(main, "rev-parse", "HEAD")
    committed(main, {"fix.txt": "fix\n"}, "a fix above the merge")

    assert (unmerged, alike(git, "newest_merge_commit", "HEAD")) == (None, merge)


def test_a_commit_s_second_parent_reads_the_same_from_both(landing):
    main, _ = landing
    git = Git(cwd=str(main))
    run_git(main, "merge", "-q", "--no-edit", "refs/heads/" + TICKET)

    assert alike(git, "second_parent", run_git(main, "rev-parse", "HEAD")) == tip(main, TICKET)
    assert fails_alike(git, "second_parent", run_git(main, "rev-parse", "HEAD^1")) is None
    assert fails_alike(git, "second_parent", "nosuch") is None


def test_there_is_no_newest_merge_where_git_cannot_read_the_chain(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "newest_merge_commit", "HEAD") is None
