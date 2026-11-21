"""The git adapter's operations, each run against a real repository in
tmp_path and against the fake, giving the same answers."""
from __future__ import annotations

import os
import subprocess

import pytest

from conftest import committed, git_repo, run_git, write_staged
from orch.git import FakeGit, Git

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
    wt = tmp_path / "wt"
    run_git(worked, "worktree", "add", "-q", str(wt), "-b", "side")

    assert alike(Git(cwd=str(wt)), "main_checkout") == str(worked.resolve())
    assert fails_alike(Git(cwd=str(tmp_path)), "main_checkout") is None


# --- the exclude writer's operation -------------------------------------------


def test_the_common_dir_reads_the_same_from_a_real_repo_and_the_fake(worked, where):
    expected = ".git" if where == "top" else "../.git"

    assert alike(adapter(worked, where), "git_common_dir") == expected


def test_a_worktree_s_common_dir_is_its_main_checkout_s_git_directory(worked, tmp_path):
    wt = tmp_path / "wt"
    run_git(worked, "worktree", "add", "-q", str(wt), "-b", "common")

    assert alike(Git(cwd=str(wt)), "git_common_dir") == str((worked / ".git").resolve())


def test_outside_a_repository_there_is_no_common_dir(tmp_path):
    assert fails_alike(Git(cwd=str(tmp_path)), "git_common_dir") is None
