"""The pr noun's entry, run in-process in a FakeGit checkout under tmp_path
against the gh fake on a tmp_path store - the cases of the bash pr sections
for the verbs that need no flow state: the verb dispatch and its unknown-op
refusal, `pr release`, `pr comment`, `pr comments`, `pr fetch`, `pr update`
and `pr read`, each usage line, fork PRs (#1977) and no repo (#3050) across
the verbs that list the branch's PRs, and one case of each verb run once
more under ORCH_AUTOPILOT=1 (release's cases in full)."""
from __future__ import annotations

import os
import shutil
import tempfile

import pytest

from conftest import CLAUDE, GH_502, SESSIONS, comments_of, read, snapshot
from orch import pr
from orch.gh import Unparsed
from orch.gh_fake import FakeGh
from orch.git import FakeGit
from orch.repo import REPO_REMEDY, RepoPin

OPS = "open|publish|release|comment|comments|fetch|read|update|draft|ready"
ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
BRANCH = "orch/12-foo"
# The opening of every PR-body refusal.
BODY_REFUSED = "orch: the PR body does not meet the PR-writing standard - no PR was opened: "


def checkout_git(root, branch=BRANCH, base=None, origin=True):
    """The checkout's git adapter: its toplevel <root>, on <branch> (a
    detached HEAD when None), with <base> as its orchestrator.base setting
    when given, main a branch name, and origin pointing at acme/widgets
    unless <origin> is False."""
    git = FakeGit(ORIGIN if origin else {}, toplevel=str(root),
                  local_config={"orchestrator.base": base} if base else None)
    if branch is not None:
        git.seed("current_branch", answer=branch)
    git.seed("is_branch_name", "main", answer=True)
    return git


def orch_pr(seed, git, *argv, env=None, gh=None):
    """`orch.sh pr <argv>` in-process in the checkout of <git>, under <env>
    (Claude Code's plain session when None), with <gh> - the gh fake on
    <seed>'s store, pinned to <git>'s origin, when None: its exit code, a
    SystemExit's included."""
    env = CLAUDE if env is None else env
    if gh is None:
        gh = FakeGh(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None)
    try:
        return pr.run(list(argv), gh=gh, git=git, env=env)
    except SystemExit as died:
        return died.code


# --- the dispatch ------------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("argv, shown", [((), "<none>"), (("bogus",), "bogus"), (("",), "<none>")])
def test_an_unknown_op_is_refused_naming_every_op(root, seed, capsys, env, argv, shown):
    seed.offline()

    assert orch_pr(seed, checkout_git(root), *argv, env=env) == 1
    assert capsys.readouterr() == ("", "orch: unknown pr op: %s (want %s)\n" % (shown, OPS))


# --- pr release --------------------------------------------------------------------


@pytest.fixture
def release_body(tmp_path):
    """A release PR body meeting its standard: a ## Summary and some
    detail."""
    path = tmp_path / "release.md"
    path.write_text("## Summary\n\nShips the uat project.\n\nSome detail.\n")
    return str(path)


@SESSIONS
def test_release_refuses_when_the_base_branch_is_the_default_branch(root, seed, capsys, env,
                                                                    release_body):
    seed.default_branch("main")

    assert orch_pr(seed, checkout_git(root), "release", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == ("", "orch: the base branch is the default branch (main) - "
                                       "there is nothing to release; set another with base set\n")


@SESSIONS
def test_release_reads_the_default_branch_once_with_no_base_set(root, seed, capsys, env,
                                                                release_body):
    reads = []

    class Counted(FakeGh):
        def repo_default_branch(self, repo):
            reads.append(repo)
            return super().repo_default_branch(repo)

    seed.default_branch("main")
    git = checkout_git(root)
    gh = Counted(seed.store, env, pin=RepoPin(env, git), sleep=lambda _: None)

    assert orch_pr(seed, git, "release", "Release", release_body, env=env, gh=gh) == 1
    assert reads == ["acme/widgets"]


def prs_of(store):
    """The numbers of the PRs the store holds, in order."""
    directory = os.path.join(str(store), "prs")
    return sorted(int(n) for n in os.listdir(directory)) if os.path.isdir(directory) else []


@pytest.fixture
def summaryless(tmp_path):
    """A body with no ## Summary heading, though it has an ## Evidence."""
    path = tmp_path / "summaryless.md"
    path.write_text("Ships the uat project.\n\n## Evidence\n\nmake test - pass\n")
    return str(path)


@pytest.fixture
def released(root, seed, store, tmp_path, monkeypatch):
    """A checkout whose base setting is uat, main its default branch; issues
    #5, #6, #7 and #9 open, #3 and #8 closed, #62 an open pull request; and
    the temporary directory a temp file lands in, tmp_path/tmp, empty: the
    checkout's git adapter."""
    seed.default_branch("main")
    for n in (5, 6, 7, 9):
        seed.issue(n, "open")
    for n in (3, 8):
        seed.issue(n, "closed")
    seed.issue(62, "open")
    with open(os.path.join(str(store), "issues", "62", "pull"), "w"):
        pass
    (tmp_path / "tmp").mkdir()
    monkeypatch.setattr(tempfile, "tempdir", str(tmp_path / "tmp"))
    return checkout_git(root, base="uat")


def merged(seed, n, body, base="uat"):
    """PR #n merged from topic into <base>, its body <body>."""
    seed.pr(n, "merged", "topic", base)
    seed.pr_body(n, body)


@SESSIONS
@pytest.mark.parametrize("body", ["release_body", "summaryless"])
def test_release_refuses_an_open_release_pr_before_the_body_s_standard(
        seed, store, capsys, env, released, request, body):
    seed.pr(55, "open", "uat", "staging")
    seed.pr(56, "open", "topic", "main")
    seed.pr(57, "open", "uat", "main")

    assert orch_pr(seed, released, "release", "Release", request.getfixturevalue(body),
                   env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: a release PR from uat into main is already open: #57\n")
    assert prs_of(store) == [55, 56, 57]


@SESSIONS
def test_release_checks_the_base_branch_before_the_body_s_standard(root, seed, capsys, env,
                                                                  summaryless):
    seed.default_branch("main")

    assert orch_pr(seed, checkout_git(root), "release", "Release", summaryless, env=env) == 1
    assert capsys.readouterr() == ("", "orch: the base branch is the default branch (main) - "
                                       "there is nothing to release; set another with base set\n")


@SESSIONS
@pytest.mark.parametrize("operation, message", [
    ("adapter_prs_open", "gh could not list the open PRs from uat into main"),
    ("adapter_prs_merged_bodies", "gh could not list the PRs merged into uat"),
])
def test_release_dies_on_a_failed_pr_listing(seed, capsys, env, released, release_body,
                                             operation, message):
    seed.pr(57, "closed", "uat", "main")
    seed.fail(operation, GH_502)

    assert orch_pr(seed, released, "release", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == ("", "orch: %s: HTTP 502: Bad Gateway\n" % message)


NOTHING_TO_CLOSE = ("orch: nothing to close: no PR merged into uat refers to a still-open issue"
                    " - pass --force to release anyway\n")


@SESSIONS
@pytest.mark.parametrize("body", ["release_body", "summaryless"])
def test_release_with_no_still_open_issue_referred_to_has_nothing_to_close(
        seed, store, capsys, env, released, request, body):
    # #3 is closed, #61 refers to nothing, and #66 merged into main, not uat.
    merged(seed, 60, "Refs #3")
    merged(seed, 61, "No references here.")
    merged(seed, 66, "Closes #5", base="main")

    assert orch_pr(seed, released, "release", "Release", request.getfixturevalue(body),
                   env=env) == 1
    assert capsys.readouterr() == ("", NOTHING_TO_CLOSE)
    assert prs_of(store) == [60, 61, 66]


@SESSIONS
def test_release_force_opens_with_nothing_to_close_and_the_caller_s_body_alone(
        seed, store, capsys, env, released, release_body):
    merged(seed, 60, "Refs #3")
    seed.next_pr(70)

    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 0
    assert capsys.readouterr() == ("70\n", "")
    assert read(store, "prs", 70, "body") == read(os.path.dirname(release_body), "release.md")


@pytest.fixture
def referring(seed):
    """PRs merged into uat referring to issues every way: every keyword, in
    any case, anywhere in the body; #5 twice, #8 already closed; other
    closing forms (fix, closed) are prose, and #62 is a PR, not an issue."""
    merged(seed, 62, "Refs #5\n\nImplements it.")
    merged(seed, 63, "Summary first.\n\nThis closes #6 and FIXES #7.")
    merged(seed, 64, "resolves #9\nAlso Refs #5, and Closes #8.\nIt prefixes #4 with nothing.")
    merged(seed, 65, "A quick fix #12, closed #13. Refs #62, an open PR.")


@SESSIONS
def test_release_closes_every_still_open_issue_referred_to_above_the_caller_s_body(
        seed, store, tmp_path, capsys, env, released, release_body, referring):
    seed.next_pr(71)
    # No per-reference state read happens: every state read failing changes
    # nothing.
    seed.fail("adapter_issue_state", GH_502)

    assert orch_pr(seed, released, "release", "Release uat", release_body, env=env) == 0
    assert capsys.readouterr() == ("71\n", "")
    assert read(store, "prs", 71, "body") == (
        "Closes #5\nCloses #6\nCloses #7\nCloses #9\n\n"
        "## Summary\n\nShips the uat project.\n\nSome detail.\n")
    assert [read(store, "prs", 71, name) for name in ("head", "base", "title", "draft")] == [
        "uat\n", "main\n", "Release uat\n", None]
    assert os.listdir(str(tmp_path / "tmp")) == []


@SESSIONS
def test_a_failed_release_pr_open_dies_naming_both_branches_its_temp_body_removed(
        seed, store, tmp_path, capsys, env, released, release_body, referring):
    seed.fail("adapter_pr_create", GH_502)

    assert orch_pr(seed, released, "release", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not open the release PR from uat into main: HTTP 502: Bad Gateway\n")
    assert prs_of(store) == [62, 63, 64, 65]
    assert os.listdir(str(tmp_path / "tmp")) == []


@SESSIONS
def test_release_force_still_lists_the_open_issues_before_any_pr_opens(
        seed, store, capsys, env, released, release_body, referring):
    seed.fail("adapter_issues_open_titles", GH_502)

    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: gh could not list the open issues: HTTP 502: Bad Gateway\n")
    assert prs_of(store) == [62, 63, 64, 65]


@SESSIONS
@pytest.mark.parametrize("force", [(), ("--force",)], ids=["plain", "force"])
def test_release_refuses_a_body_without_a_summary(seed, store, capsys, env, released,
                                                  summaryless, referring, force):
    assert orch_pr(seed, released, "release", *force, "Release", summaryless, env=env) == 1
    assert capsys.readouterr() == ("", BODY_REFUSED + "no ## Summary heading\n")
    assert prs_of(store) == [62, 63, 64, 65]


@SESSIONS
def test_release_needs_a_summary_alone(seed, tmp_path, capsys, env, released, referring):
    body = tmp_path / "summary-only.md"
    body.write_text("## Summary\n\nShips the uat project.\n")
    seed.next_pr(72)

    assert orch_pr(seed, released, "release", "Release", str(body), env=env) == 0
    assert capsys.readouterr() == ("72\n", "")


@SESSIONS
def test_release_drops_a_reference_to_a_number_the_repo_has_no_issue_for(
        seed, store, capsys, env, released, release_body):
    merged(seed, 80, "Refs #99\nCloses #5")
    seed.next_pr(74)

    assert orch_pr(seed, released, "release", "Release", release_body, env=env) == 0
    assert read(store, "prs", 74, "body").startswith("Closes #5\n\n## Summary")
    seed.pr(74, "closed", "uat", "main")
    seed.pr_body(80, "Refs #99")
    capsys.readouterr()

    assert orch_pr(seed, released, "release", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == ("", NOTHING_TO_CLOSE)


@SESSIONS
def test_release_with_no_reference_never_lists_the_open_issues(seed, capsys, env, released,
                                                               release_body):
    merged(seed, 80, "No references here.")
    seed.fail("adapter_issues_open_titles", GH_502)
    seed.next_pr(75)

    assert orch_pr(seed, released, "release", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == ("", NOTHING_TO_CLOSE)
    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 0
    assert capsys.readouterr() == ("75\n", "")


@SESSIONS
@pytest.mark.parametrize("argv, message", [
    (("Release",), "usage: orch.sh pr release [--force] <title> <body-file>"),
    (("--force",), "usage: orch.sh pr release [--force] <title> <body-file>"),
    (("a", "b", "c"), "usage: orch.sh pr release [--force] <title> <body-file>"),
    (("Release", "/nonexistent/body.md"), "body file not found: /nonexistent/body.md"),
])
def test_release_refuses_bad_arguments_before_any_read(seed, capsys, env, released, argv,
                                                       message):
    seed.offline()

    assert orch_pr(seed, released, "release", *argv, env=env) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % message)


@SESSIONS
def test_release_refuses_an_empty_title(seed, capsys, env, released, release_body):
    seed.offline()

    assert orch_pr(seed, released, "release", "", release_body, env=env) == 1
    assert capsys.readouterr() == ("", "orch: the title is empty\n")


@SESSIONS
def test_release_past_a_fork_s_release_pr_saying_it_was_ignored(seed, store, capsys, env,
                                                                released, release_body):
    seed.pr(57, "open", "uat", "main")
    seed.pr_cross(57, "maybe")

    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: the open PRs from uat into main could not be read\n")
    seed.pr_cross(57)
    seed.next_pr(70)

    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 0
    assert capsys.readouterr() == ("70\n", "orch: ignored 1 PR(s) from forks for uat\n")
    # #57 afresh, same-repo: no fork PR is left to ignore.
    seed.pr(57, "open", "uat", "main")

    assert orch_pr(seed, released, "release", "--force", "Release", release_body, env=env) == 1
    assert capsys.readouterr() == (
        "", "orch: a release PR from uat into main is already open: #70\n")
    assert prs_of(store) == [57, 70]


# --- pr comment and pr comments ------------------------------------------------------

QUICK = "quick/12-foo"


@pytest.fixture
def note(tmp_path):
    """A comment body to post: a review pass's declines."""
    path = tmp_path / "note.md"
    path.write_text("## Review\n\n- `a.sh:3` - declined: out of scope.\n")
    return str(path)


@pytest.fixture
def others(seed):
    """Open PRs that are not quick/12-foo's: one from another branch, and a
    closed one from quick/12-foo."""
    seed.pr(50, "open", "quick/99-other", "main")
    seed.pr(51, "closed", QUICK, "main")


@SESSIONS
def test_comment_with_no_open_pr_exits_1_posting_nothing(root, seed, store, capsys, env, note,
                                                        others):
    assert orch_pr(seed, checkout_git(root, QUICK), "comment", note, env=env) == 1
    assert capsys.readouterr() == ("", "")
    assert comments_of(store, 50, "prs") + comments_of(store, 51, "prs") == []


@SESSIONS
def test_comment_posts_the_file_on_the_branch_s_open_pr_printing_its_number(
        root, seed, store, capsys, env, note, others):
    seed.pr(57, "open", QUICK, "main")

    assert orch_pr(seed, checkout_git(root, QUICK), "comment", note, env=env) == 0
    assert capsys.readouterr() == ("57\n", "")
    assert comments_of(store, 57, "prs") == [read(os.path.dirname(note), "note.md")]


@pytest.mark.parametrize("operation, stderr, line", [
    ("adapter_prs_open", None,
     "gh could not list the open PRs from quick/12-foo: fake gh: adapter_prs_open failed"),
    ("adapter_prs_open", GH_502,
     "gh could not list the open PRs from quick/12-foo: HTTP 502: Bad Gateway"),
    ("adapter_pr_comment", None, "gh could not comment on PR #57: fake gh: adapter_pr_comment failed"),
    ("adapter_pr_comment", GH_502, "gh could not comment on PR #57: HTTP 502: Bad Gateway"),
    ("adapter_pr_comment", "", "gh could not comment on PR #57: gh gave no reason"),
])
def test_comment_exits_2_when_github_cannot_be_read_or_the_post_fails(
        root, seed, store, capsys, note, operation, stderr, line):
    seed.pr(57, "open", QUICK, "main")
    seed.fail(operation, stderr)

    assert orch_pr(seed, checkout_git(root, QUICK), "comment", note) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % line)
    assert comments_of(store, 57, "prs") == []


@pytest.mark.parametrize("verb", ["comment", "comments"])
@pytest.mark.parametrize("origin", [True, False], ids=["repo", "no-repo"])
@pytest.mark.parametrize("argv, branch, line", [
    ((), QUICK, "usage: orch.sh pr {verb} <file>"),
    (("a", "b"), QUICK, "usage: orch.sh pr {verb} <file>"),
    (("{file}",), None, "not on a branch (detached HEAD)"),
])
def test_comment_and_comments_refusals_exit_2_and_win_over_a_missing_repo(
        root, seed, tmp_path, capsys, verb, origin, argv, branch, line):
    seed.offline()
    path = tmp_path / "f.md"
    path.write_text("seeded\n")
    args = [arg.format(file=str(path)) for arg in argv]

    assert orch_pr(seed, checkout_git(root, branch, origin=origin), verb, *args) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % line.format(verb=verb))
    assert path.read_text() == "seeded\n"


@pytest.mark.parametrize("origin", [True, False], ids=["repo", "no-repo"])
def test_comment_refuses_a_missing_body_file_with_2(root, seed, capsys, origin):
    seed.offline()

    assert orch_pr(seed, checkout_git(root, QUICK, origin=origin), "comment",
                   "/nonexistent/body.md") == 2
    assert capsys.readouterr() == ("", "orch: body file not found: /nonexistent/body.md\n")


@pytest.fixture
def pr_comments(tmp_path):
    """The file pr comments writes, seeded with known content."""
    path = tmp_path / "out" / "comments.md"
    path.parent.mkdir()
    path.write_text("known content\n")
    return path


@SESSIONS
def test_comments_with_no_open_pr_exits_1_writing_nothing(root, seed, capsys, env, pr_comments):
    seed.pr(56, "open", "quick/99-other", "main")
    seed.pr_comment(56, "pat", "2026-10-01T09:00:00Z", "Not this one.")

    assert orch_pr(seed, checkout_git(root, QUICK), "comments", str(pr_comments), env=env) == 1
    assert capsys.readouterr() == ("", "")
    assert pr_comments.read_text() == "known content\n"


def test_comments_of_a_pr_with_none_leaves_an_empty_file(root, seed, capsys, pr_comments):
    seed.pr(57, "open", QUICK, "main")

    assert orch_pr(seed, checkout_git(root, QUICK), "comments", str(pr_comments)) == 0
    assert capsys.readouterr() == ("", "")
    assert pr_comments.read_text() == ""


@SESSIONS
def test_comments_writes_the_trusted_comments_in_issue_comments_format(
        root, seed, capsys, env, pr_comments):
    seed.pr(57, "open", QUICK, "main")
    seed.pr_comment(57, "pat", "2026-10-01T09:00:00Z",
                    "## Review\n\n- `a.sh:3` - unused helper - declined: out of scope.\n\n"
                    "## Host fallbacks\n\nNone.")
    seed.pr_comment(57, "bot", "2026-10-02T10:00:00Z", "LGTM")
    seed.pr_comment(57, "rando", "2026-10-03T09:00:00Z", "Stranger note.", "NONE")

    assert orch_pr(seed, checkout_git(root, QUICK), "comments", str(pr_comments), env=env) == 0
    assert capsys.readouterr() == (
        "", "orch: ignored 1 comment(s) from untrusted authors on #57\n")
    assert pr_comments.read_text() == (
        "<!-- comment @pat 2026-10-01T09:00:00Z -->\n## Review\n\n"
        "- `a.sh:3` - unused helper - declined: out of scope.\n\n## Host fallbacks\n\nNone.\n\n"
        "<!-- comment @bot 2026-10-02T10:00:00Z -->\nLGTM\n")


class UnparsedComments(FakeGh):
    """The gh fake, but a PR's comments answer with something that is no
    comment list."""

    def pr_comments(self, n):
        raise Unparsed("no comment list")


@pytest.mark.parametrize("fail, gh_class, line", [
    (("adapter_prs_open", GH_502), FakeGh,
     "gh could not list the open PRs from quick/12-foo: HTTP 502: Bad Gateway"),
    (("adapter_pr_comments", GH_502), FakeGh,
     "gh could not read the comments of PR #57: HTTP 502: Bad Gateway"),
    (("adapter_pr_comments", ""), FakeGh,
     "gh could not read the comments of PR #57: gh gave no reason"),
    (None, UnparsedComments, "could not read the comments of PR #57: its comments did not parse"),
])
def test_comments_exits_2_when_github_cannot_be_read_leaving_the_file(
        root, seed, capsys, pr_comments, fail, gh_class, line):
    seed.pr(57, "open", QUICK, "main")
    if fail:
        seed.fail(*fail)
    git = checkout_git(root, QUICK)
    gh = gh_class(seed.store, CLAUDE, pin=RepoPin(CLAUDE, git), sleep=lambda _: None)

    assert orch_pr(seed, git, "comments", str(pr_comments), gh=gh) == 2
    assert capsys.readouterr() == ("", "orch: %s\n" % line)
    assert pr_comments.read_text() == "known content\n"


def test_comments_exits_2_when_its_file_cannot_be_written(root, seed, tmp_path, capsys):
    seed.pr(57, "open", QUICK, "main")
    (tmp_path / "plain").write_text("a file, not a directory\n")
    path = str(tmp_path / "plain" / "comments.md")

    assert orch_pr(seed, checkout_git(root, QUICK), "comments", path) == 2
    assert capsys.readouterr() == ("", "orch: could not write %s\n" % path)


# --- pr fetch and pr update ----------------------------------------------------------


@pytest.fixture
def fetched(tmp_path):
    """The path pr fetch writes, in a directory of its own, not there yet."""
    (tmp_path / "fetched").mkdir()
    return tmp_path / "fetched" / "body.md"


@pytest.fixture
def new_body(tmp_path):
    """A corrected body opening with #12's Closes line."""
    path = tmp_path / "new.md"
    path.write_text("Closes #12\n\nAdds nothing new.\n")
    return path


@pytest.fixture
def mine(seed):
    """#57, orch/12-foo's open PR, opening with Closes #12, beside #56, the
    open PR of another branch."""
    seed.pr(56, "open", "orch/99-other", "main")
    seed.pr_body(56, "Closes #99")
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_body(57, "Closes #12\n\nAdds `quote_meta`, needed for meta#ts.\n")


@SESSIONS
@pytest.mark.parametrize("verb, path", [("fetch", "fetched"), ("update", "new_body")])
def test_fetch_and_update_with_no_open_pr_exit_1_saying_so(root, seed, capsys, env, request,
                                                          verb, path):
    seed.pr(56, "open", "orch/99-other", "main")

    assert orch_pr(seed, checkout_git(root), verb, str(request.getfixturevalue(path)),
                   env=env) == 1
    assert capsys.readouterr() == ("", "orch: no open PR for branch orch/12-foo\n")


@SESSIONS
def test_fetch_writes_the_branch_s_open_pr_s_body(root, seed, capsys, env, mine, fetched):
    assert orch_pr(seed, checkout_git(root), "fetch", str(fetched), env=env) == 0
    assert capsys.readouterr() == ("", "")
    assert fetched.read_text() == "Closes #12\n\nAdds `quote_meta`, needed for meta#ts.\n\n"


@pytest.mark.parametrize("body, text", [
    ("Closes #12\r\n\r\nAlpha line.\r\nBeta line.\r\n", "Closes #12\n\nAlpha line.\nBeta line.\n\n"),
    ("Closes #12\r\nBeta line.", "Closes #12\nBeta line.\n"),
])
def test_fetch_writes_a_crlf_body_with_lf_line_endings(root, seed, capsys, mine, fetched, body,
                                                      text):
    seed.pr_body(57, body)

    assert orch_pr(seed, checkout_git(root), "fetch", str(fetched)) == 0
    assert fetched.read_bytes() == text.encode()


@pytest.mark.parametrize("stderr, reason", [(GH_502, "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")])
def test_a_failed_fetch_read_leaves_the_target_untouched_and_no_temp_file(
        root, seed, capsys, mine, fetched, stderr, reason):
    fetched.write_text("Closes #12\nBeta line.\n")
    seed.fail("adapter_pr_body", stderr)

    assert orch_pr(seed, checkout_git(root), "fetch", str(fetched)) == 1
    assert capsys.readouterr() == ("", "orch: gh could not read the body of PR #57: %s\n" % reason)
    assert fetched.read_text() == "Closes #12\nBeta line.\n"
    assert os.listdir(str(fetched.parent)) == ["body.md"]


def test_fetch_into_a_place_no_file_can_be_made_dies_before_reading(root, seed, tmp_path,
                                                                     capsys, mine):
    (tmp_path / "plain").write_text("a file, not a directory\n")
    path = str(tmp_path / "plain" / "body.md")
    seed.fail("adapter_pr_body", GH_502)

    assert orch_pr(seed, checkout_git(root), "fetch", path) == 1
    assert capsys.readouterr() == ("", "orch: could not create a temp file beside %s\n" % path)


@SESSIONS
def test_update_replaces_the_branch_s_open_pr_s_body_and_no_other(root, seed, store, capsys, env,
                                                                 mine, new_body, fetched):
    assert orch_pr(seed, checkout_git(root), "update", str(new_body), env=env) == 0
    assert capsys.readouterr() == ("", "")
    assert read(store, "prs", 57, "body") == new_body.read_text()
    assert read(store, "prs", 56, "body") == "Closes #99"
    assert orch_pr(seed, checkout_git(root), "fetch", str(fetched)) == 0
    assert fetched.read_text() == new_body.read_text() + "\n"


def test_update_keeps_a_refs_line_too(root, seed, store, mine, new_body):
    seed.pr_body(57, "Refs #12\n\nInto uat.\n")
    new_body.write_text("Refs #12\r\n\nInto uat, corrected.\n")

    assert orch_pr(seed, checkout_git(root), "update", str(new_body)) == 0
    with open(os.path.join(str(store), "prs", "57", "body"), "rb") as body:
        assert body.read() == b"Refs #12\r\n\nInto uat, corrected.\n"


@pytest.mark.parametrize("first", ["Adds nothing new.", "Closes #13", "Refs #12", ""])
def test_update_refuses_a_file_not_opening_with_the_pr_s_issue_line(root, seed, store, capsys,
                                                                    mine, new_body, first):
    new_body.write_text(first + "\n\nCorrected body.\n")
    before = read(store, "prs", 57, "body")

    assert orch_pr(seed, checkout_git(root), "update", str(new_body)) == 1
    assert capsys.readouterr() == (
        "", "orch: %s must open with PR #57's issue line, 'Closes #12' - refusing to replace the"
            " body\n" % new_body)
    assert read(store, "prs", 57, "body") == before


@pytest.mark.parametrize("body", ["Hand-edited, no issue line.\n", "", "Closes #12 and more\n"])
def test_update_refuses_a_pr_body_with_no_issue_line_to_keep(root, seed, store, capsys, mine,
                                                             new_body, body):
    seed.pr_body(57, body)

    assert orch_pr(seed, checkout_git(root), "update", str(new_body)) == 1
    assert capsys.readouterr() == (
        "", "orch: PR #57's body does not open with a Closes/Refs #<issue> line, so there is no"
            " issue line to keep - refusing to replace it\n")
    assert read(store, "prs", 57, "body") == body


@pytest.mark.parametrize("operation, stderr, line", [
    ("adapter_pr_body_edit", None,
     "gh could not replace the body of PR #57: fake gh: adapter_pr_body_edit failed"),
    ("adapter_pr_body_edit", GH_502, "gh could not replace the body of PR #57: HTTP 502: Bad Gateway"),
    ("adapter_pr_body", GH_502, "gh could not read the body of PR #57: HTTP 502: Bad Gateway"),
    ("adapter_pr_body", "", "gh could not read the body of PR #57: gh gave no reason"),
])
def test_a_failed_update_read_or_write_exits_1_leaving_the_body(root, seed, store, capsys, mine,
                                                               new_body, operation, stderr, line):
    seed.fail(operation, stderr)

    assert orch_pr(seed, checkout_git(root), "update", str(new_body)) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % line)
    assert read(store, "prs", 57, "body") == "Closes #12\n\nAdds `quote_meta`, needed for meta#ts.\n"


@pytest.mark.parametrize("origin", [True, False], ids=["repo", "no-repo"])
@pytest.mark.parametrize("argv, line", [
    (("fetch",), "usage: orch.sh pr fetch <file>"),
    (("fetch", "a", "b"), "usage: orch.sh pr fetch <file>"),
    (("update",), "usage: orch.sh pr update <file>"),
    (("update", "a", "b"), "usage: orch.sh pr update <file>"),
    (("update", "/nonexistent/body.md"), "body file not found: /nonexistent/body.md"),
])
def test_fetch_and_update_refusals_exit_1_and_win_over_a_missing_repo(root, seed, capsys, origin,
                                                                      argv, line):
    seed.offline()

    assert orch_pr(seed, checkout_git(root, origin=origin), *argv) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % line)


# --- no repo (#3050) -----------------------------------------------------------------


@pytest.mark.parametrize("verb, path, code", [
    ("comment", "note", 2),
    ("comments", "pr_comments", 2),
    ("fetch", "pr_comments", 1),
    ("update", "note", 1),
])
def test_with_no_repo_the_branch_s_pr_verbs_die_with_the_remedy_alone_writing_nothing(
        root, seed, capsys, request, verb, path, code):
    # Offline: a gh call would die with another message.
    seed.offline()
    target = request.getfixturevalue(path)
    before = open(str(target)).read()

    assert orch_pr(seed, checkout_git(root, QUICK, origin=False), verb, str(target)) == code
    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)
    assert open(str(target)).read() == before


# --- fork PRs (#1977) ----------------------------------------------------------------

FORK_LINE = "orch: ignored 1 PR(s) from forks for orch/12-foo\n"


@pytest.fixture
def fork(seed):
    """#60, a fork's open PR from orch/12-foo, opening with Closes #12."""
    seed.pr(60, "open", BRANCH, "main")
    seed.pr_cross(60)
    seed.pr_body(60, "Closes #12\n\nStranger.")


@pytest.mark.parametrize("argv, line", [
    (("update", "new_body"), "orch: no open PR for branch orch/12-foo\n"),
    (("fetch", "fetched"), "orch: no open PR for branch orch/12-foo\n"),
    (("comment", "note"), ""),
    (("comments", "pr_comments"), ""),
])
def test_only_a_fork_pr_is_no_open_pr_leaving_it_untouched(root, seed, store, capsys, request,
                                                           fork, argv, line):
    verb, path = argv
    before = snapshot(store)

    assert orch_pr(seed, checkout_git(root), verb, str(request.getfixturevalue(path))) == 1
    assert capsys.readouterr() == ("", FORK_LINE + line)
    assert snapshot(store) == before


@pytest.fixture
def beside_fork(seed, fork):
    """#57, orch/12-foo's own open PR, older than the fork's #60, each with
    a comment."""
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_body(57, "Closes #12\n\nMine.")
    seed.pr_comment(57, "pat", "2026-10-01T09:00:00Z", "Mine too.")
    seed.pr_comment(60, "pat", "2026-10-02T09:00:00Z", "Stranger comment.")


def test_each_verb_acts_on_the_same_repo_pr_beside_a_newer_fork_pr(
        root, seed, store, capsys, beside_fork, fetched, new_body, note, pr_comments):
    git = checkout_git(root)

    assert orch_pr(seed, git, "fetch", str(fetched)) == 0
    assert fetched.read_text() == "Closes #12\n\nMine.\n"
    assert orch_pr(seed, git, "update", str(new_body)) == 0
    assert orch_pr(seed, git, "comments", str(pr_comments)) == 0
    assert orch_pr(seed, git, "comment", note) == 0
    assert capsys.readouterr() == ("57\n", FORK_LINE * 4)
    assert read(store, "prs", 57, "body") == new_body.read_text()
    assert read(store, "prs", 60, "body") == "Closes #12\n\nStranger."
    assert comments_of(store, 60, "prs") == ["Stranger comment."]
    assert pr_comments.read_text() == "<!-- comment @pat 2026-10-01T09:00:00Z -->\nMine too.\n"


def test_the_newest_same_repo_pr_wins_beside_a_newer_fork_pr(root, seed, capsys, beside_fork,
                                                             fetched):
    seed.pr(58, "open", BRANCH, "main")
    seed.pr_body(58, "Closes #12\n\nNewer mine.")
    seed.pr(61, "open", BRANCH, "main")
    seed.pr_cross(61)

    assert orch_pr(seed, checkout_git(root), "fetch", str(fetched)) == 0
    assert fetched.read_text() == "Closes #12\n\nNewer mine.\n"


def test_comments_with_an_unreadable_fork_flag_exits_2_writing_nothing(root, seed, capsys,
                                                                       pr_comments):
    seed.pr(58, "open", BRANCH, "main")
    seed.pr_cross(58, "maybe")

    assert orch_pr(seed, checkout_git(root), "comments", str(pr_comments)) == 2
    assert capsys.readouterr() == ("", "orch: the open PRs from orch/12-foo could not be read\n")
    assert pr_comments.read_text() == "known content\n"


# --- pr read -------------------------------------------------------------------------


@pytest.fixture
def pr_md(tmp_path):
    """The path pr read writes, in a directory of its own, not there yet."""
    (tmp_path / "read").mkdir()
    return tmp_path / "read" / "pr.md"


@pytest.fixture
def widget(seed):
    """#57, orch/12-foo's open PR referring to #12, with a diff, beside #56
    closing #99 and #58 closing #120."""
    seed.pr(56, "open", "orch/99-other", "main")
    seed.pr_body(56, "Closes #99\n\nNot this one.\n")
    seed.pr(57, "open", BRANCH, "main")
    seed.pr_body(57, "Refs #12\n\nAdds the widget.\n")
    seed.pr_diff(57, "diff --git a/w b/w\n+widget\n")
    seed.pr(58, "open", "orch/120-bar", "main")
    seed.pr_body(58, "Closes #120\n")


WIDGET = "Refs #12\n\nAdds the widget.\n\n---\ndiff --git a/w b/w\n+widget\n"


@SESSIONS
def test_read_writes_the_body_a_rule_and_the_diff_of_the_pr_naming_the_issue(
        root, seed, capsys, env, widget, pr_md):
    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md), env=env) == 0
    assert capsys.readouterr() == ("", "")
    assert pr_md.read_text() == WIDGET


def test_read_takes_every_body_from_one_listing(root, seed, capsys, widget, pr_md):
    seed.fail("adapter_pr_body", "HTTP 500")
    seed.fail_after("adapter_prs_open_bodies", 1)

    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md)) == 0
    assert pr_md.read_text() == WIDGET


@SESSIONS
def test_read_with_no_pr_naming_the_issue_fails_saying_so(root, seed, capsys, env, widget, pr_md):
    assert orch_pr(seed, checkout_git(root), "read", "13", str(pr_md), env=env) == 1
    assert capsys.readouterr() == ("", "orch: no open PR closes or refers to issue #13\n")
    assert not pr_md.exists()


@pytest.mark.parametrize("argv, line", [
    (("12",), "usage: orch.sh pr read <issue> <file>"),
    (("12", "a", "b"), "usage: orch.sh pr read <issue> <file>"),
    (("abc", "f"), "not an issue number: abc"),
    (("0", "f"), "not an issue number: 0"),
    (("", "f"), "not an issue number: "),
])
def test_read_refuses_bad_arguments_before_any_read(root, seed, capsys, argv, line):
    seed.offline()

    assert orch_pr(seed, checkout_git(root), "read", *argv) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % line)


def listing(seed, *lines):
    """The gh fake on <seed>'s store, answering the open PRs with their
    bodies as <lines>, as gh would print them."""

    class Listed(FakeGh):
        def prs_open_bodies(self):
            return list(lines)

    return Listed(seed.store, CLAUDE, sleep=lambda _: None)


@pytest.mark.parametrize("lines", [
    ('57\t"Refs #12"\ttrue', '58\t"x"\t'),
    ('57\tnot json\tfalse',),
    ('a[$(touch marker)]\t"Refs #12"\tfalse',),
    ('x\t"Closes #99"\tfalse', '57\t"Refs #12"\tfalse'),
    ('0\t"Refs #12"\tfalse',),
    ('57\t"Refs #12"\tfalse\textra',),
], ids=["flag", "json", "injected", "other-issue", "zero", "extra-field"])
@pytest.mark.parametrize("issue", ["12", "012"])
def test_read_fails_on_any_listed_line_that_does_not_read(root, seed, capsys, pr_md, lines, issue):
    pr_md.write_text("known content\n")

    assert orch_pr(seed, checkout_git(root), "read", issue, str(pr_md),
                   gh=listing(seed, *lines)) == 1
    assert capsys.readouterr() == ("", "orch: the open PRs for issue #12 could not be read\n")
    assert pr_md.read_text() == "known content\n"


@pytest.mark.parametrize("lines, issue, text", [
    (('09\t"Refs #14"\tfalse',), "14", "Refs #14\n\n---\ndiff --git a/i b/i\n+nine\n"),
    (('08\t"Refs #14"\tfalse',), "14", "Refs #14\n\n---\ndiff --git a/e b/e\n+eight\n"),
    (('010\t"Refs #14\\n\\nTen."\tfalse', '8\t"Refs #14\\n\\nEight."\tfalse'), "14",
     "Refs #14\n\nTen.\n\n---\ndiff --git a/t b/t\n+ten\n"),
    (('60\t"Closes #12\\n\\nTwelve."\tfalse',), "012",
     "Closes #12\n\nTwelve.\n\n---\ndiff --git a/z b/z\n+twelve\n"),
], ids=["09", "08", "010-beside-8", "issue-012"])
def test_read_takes_leading_zeros_as_the_number_without_them(root, seed, capsys, pr_md, lines,
                                                             issue, text):
    for n, diff in ((8, "e b/e\n+eight"), (9, "i b/i\n+nine"), (10, "t b/t\n+ten"),
                    (60, "z b/z\n+twelve")):
        seed.pr(n, "open", "orch/%d-lz" % n, "main")
        seed.pr_diff(n, "diff --git a/%s\n" % diff)

    assert orch_pr(seed, checkout_git(root), "read", issue, str(pr_md),
                   gh=listing(seed, *lines)) == 0
    assert capsys.readouterr() == ("", "")
    assert pr_md.read_text() == text


def test_read_of_012_with_no_pr_naming_issue_12_names_issue_12(root, seed, capsys, pr_md):
    assert orch_pr(seed, checkout_git(root), "read", "012", str(pr_md),
                   gh=listing(seed, '56\t"Closes #99"\tfalse', "", "\t")) == 1
    assert capsys.readouterr() == ("", "orch: no open PR closes or refers to issue #12\n")


@pytest.mark.parametrize("operation, line", [
    ("adapter_prs_open_bodies", "gh could not list the open PRs: HTTP 502: Bad Gateway"),
    ("adapter_pr_diff", "gh could not read the diff of PR #57: HTTP 502: Bad Gateway"),
])
def test_a_failed_read_fails_never_as_no_pr(root, seed, capsys, widget, pr_md, operation, line):
    seed.fail(operation, GH_502)

    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md)) == 1
    assert capsys.readouterr() == ("", "orch: %s\n" % line)
    assert not pr_md.exists()


def test_read_matches_a_crlf_first_line_writing_the_newer_pr_s_body_byte_for_byte(
        root, seed, capsys, pr_md):
    seed.pr(70, "open", "orch/13-a", "main")
    seed.pr_body(70, "Closes #13\r\n\r\nOlder.\n")
    seed.pr(71, "open", "orch/13-b", "main")
    seed.pr_body(71, 'Closes #13\r\n\tTab \\ "q" café ✓\n')
    seed.pr_diff(71, "diff --git a/n b/n\n+newer\n")

    assert orch_pr(seed, checkout_git(root), "read", "13", str(pr_md)) == 0
    assert pr_md.read_bytes() == (
        'Closes #13\r\n\tTab \\ "q" café ✓\n\n---\ndiff --git a/n b/n\n+newer\n'
        .encode())


def test_read_into_a_place_no_file_can_be_written_says_so(root, seed, tmp_path, capsys, widget):
    (tmp_path / "plain").write_text("a file, not a directory\n")
    path = str(tmp_path / "plain" / "pr.md")

    assert orch_pr(seed, checkout_git(root), "read", "12", path) == 1
    assert capsys.readouterr() == ("", "orch: could not write %s\n" % path)


@pytest.fixture
def read_beside_fork(seed):
    """#70, orch/12-foo's open PR closing #12, and #71, a fork's newer one
    closing #12 too."""
    seed.pr(70, "open", BRANCH, "main")
    seed.pr_body(70, "Closes #12\n\nMine.")
    seed.pr_diff(70, "mine diff\n")
    seed.pr(71, "open", "stranger/main", "main")
    seed.pr_cross(71)
    seed.pr_body(71, "Closes #12\n\nStranger.")


def test_read_ignores_a_fork_pr_naming_the_issue_saying_so(root, seed, store, capsys, pr_md,
                                                           read_beside_fork):
    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md)) == 0
    assert capsys.readouterr() == ("", "orch: ignored 1 PR(s) from forks for #12\n")
    assert pr_md.read_text() == "Closes #12\n\nMine.\n\n---\nmine diff\n"


def test_read_with_only_a_fork_pr_naming_the_issue_fails(root, seed, store, capsys, pr_md,
                                                         read_beside_fork):
    shutil.rmtree(os.path.join(str(store), "prs", "70"))

    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md)) == 1
    assert capsys.readouterr() == ("", "orch: ignored 1 PR(s) from forks for #12\n"
                                       "orch: no open PR closes or refers to issue #12\n")
    seed.pr_body(71, "Closes #99\n\nStranger.")

    assert orch_pr(seed, checkout_git(root), "read", "12", str(pr_md)) == 1
    assert capsys.readouterr() == ("", "orch: no open PR closes or refers to issue #12\n")
