"""The pr noun's `open` and `publish`, run in-process through pr.run in a
FakeGit checkout under tmp_path against the gh fake on a tmp_path store - the
cases of the bash `pr open` and `pr publish` sections: each guard in order,
the Closes/Refs issue line, the push failure before any create, the create
failure, the branch record and its warning, the state record failing after
the create, the labels read back, the update path (#1609) with its refusals,
base warning and "already written" hints, publish's plain-issue-number
refusal, --draft and --label values, the PR-writing standard's body check
(#1387), the open-tickets refusal (#1734) as a direct call, and every usage
line - each case that prints run in a plain and an autopilot session."""
from __future__ import annotations

import json
import os
import subprocess

import pytest

from conftest import (CLAUDE, GH_502, SESSIONS, CountingGh, died_of, fake, hold_flow, lines, prs_of,
                      read, state_json)
from orch import pr
from orch.git import FakeGit

ORIGIN = "https://github.com/acme/widgets.git"
FLOW_BRANCH = "orch/16-propen"
QUICK_BRANCH = "quick/16-widgets"
# pr_body_complete's body, as the bash suite writes it.
COMPLETE_BODY = ("## Summary\n\nImplements the thing.\n\nSome detail.\n\n"
                 "## Evidence\n\nmake test - pass\n\n"
                 "## Merge Danger\n\n**Door:** two-way\n**Blast Radius:** the widget module\n")
OPEN_USAGE = "usage: orch.sh pr open <title> <body-file> [--label <name>]..."
PUBLISH_USAGE = ("usage: orch.sh pr publish <issue> <title> <body-file> [--draft]"
                 " [--label <name>]...")
REFUSED = "orch: the PR body does not meet the PR-writing standard - no PR was opened: "
REJECTED = "! [remote rejected] %s -> %s (pre-receive hook declined)"


def refspec(branch):
    return "refs/heads/%s:refs/heads/%s" % (branch, branch)


def checkout_git(root, branch, rejected=False, **config):
    """A FakeGit checkout at <root> with origin on acme/widgets, on <branch>
    (None for a detached HEAD), main and uat valid branch names, whose push
    of <branch> lands - or is rejected under <rejected> with git's reason.
    <config> goes to FakeGit as is."""
    git = FakeGit(toplevel=str(root), remotes={"origin": ORIGIN}, **config)
    git.seed("current_branch", answer=branch)
    for name in ("main", "uat"):
        git.seed("is_branch_name", name, answer=True)
    if branch is not None:
        git.seed("push_set_upstream", "origin", refspec(branch),
                 answer=REJECTED % (branch, branch) if rejected else None)
    return git


def orch_pr(root, seed, git, *argv, env=None, gh=None):
    """`orch.sh pr <argv>` in-process in the checkout <git>, on <seed>'s
    store unless <gh> is given, under <env> (Claude Code's plain session
    when None): its exit code."""
    return pr.run(list(argv), gh=fake(seed) if gh is None else gh, git=git,
                  env=CLAUDE if env is None else env)


def body_file(tmp_path, text=COMPLETE_BODY, name="body.md"):
    path = tmp_path / name
    path.write_text(text)
    return str(path)


def pr_file(store, n, name):
    return read(store, "prs", n, name)


@pytest.fixture
def github(seed):
    """The repo's default branch main, issues #16 to #25 open, and the next
    PR #23."""
    seed.default_branch("main\n")
    for n in range(16, 26):
        seed.issue(n, "open")
    seed.next_pr(23)
    return seed


# --- pr publish ---------------------------------------------------------------------


@SESSIONS
def test_publish_opens_a_ready_pr_from_the_current_branch_into_the_default_branch(
        tmp_path, root, github, store, capsys, env):
    git = checkout_git(root, QUICK_BRANCH)
    gh = CountingGh(github.store, {}, sleep=lambda _: None)

    assert orch_pr(root, github, git, "publish", "16", "Title", body_file(tmp_path), env=env,
                   gh=gh) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert len(gh.default_asks) == 1
    assert not state_json(root).exists()
    assert (pr_file(store, 23, "base"), pr_file(store, 23, "head"), pr_file(store, 23, "title")) \
        == ("main\n", QUICK_BRANCH + "\n", "Title\n")
    assert pr_file(store, 23, "draft") is None
    assert pr_file(store, 23, "body") == "Closes #16\n\n" + COMPLETE_BODY
    assert git.config_value("branch.%s.orchestrator-pr" % QUICK_BRANCH) == "23"


# --- the body check (#1387) ---------------------------------------------------------

# Each line COMPLETE_BODY holds that pr open and pr publish require, and the
# pieces the refusal names without it.
BODY_PIECES = [
    ("## Summary", "no ## Summary heading"),
    ("## Evidence", "no ## Evidence heading"),
    # Its Door and Blast Radius lines then sit under ## Evidence.
    ("## Merge Danger", "no ## Merge Danger heading; no **Door:** line under ## Merge Danger;"
     " no **Blast Radius:** line under ## Merge Danger"),
    ("**Door:** two-way", "no **Door:** line under ## Merge Danger"),
    ("**Blast Radius:** the widget module", "no **Blast Radius:** line under ## Merge Danger"),
]


def body_without(line):
    """COMPLETE_BODY with every line that is exactly <line> dropped."""
    return "".join(kept + "\n" for kept in COMPLETE_BODY.split("\n")[:-1] if kept != line)


def publish_refused(tmp_path, root, seed, capsys, text):
    """`pr publish 24 Title <a body holding text>` on quick/24-standard,
    whose push origin rejects - so a refusal before the push is told apart -
    which must die: (exit code, stdout, stderr)."""
    git = checkout_git(root, "quick/24-standard", rejected=True)
    return died_of(capsys, lambda: orch_pr(root, seed, git, "publish", "24", "Title",
                                           body_file(tmp_path, text)))


@pytest.mark.parametrize("piece, named", BODY_PIECES)
def test_a_body_without_a_piece_is_refused_naming_it_before_any_push(
        tmp_path, root, github, store, capsys, piece, named):
    assert publish_refused(tmp_path, root, github, capsys, body_without(piece)) == (
        1, "", REFUSED + named + "\n")
    assert prs_of(store) == []


def test_a_body_with_no_piece_at_all_names_every_missing_piece_in_one_message(
        tmp_path, root, github, capsys):
    assert publish_refused(tmp_path, root, github, capsys, "Implements the thing.\n") == (
        1, "", REFUSED + "no ## Summary heading; no ## Evidence heading; no ## Merge Danger"
        " heading; no **Door:** line under ## Merge Danger; no **Blast Radius:** line under"
        " ## Merge Danger\n")


@pytest.mark.parametrize("text, named", [
    (lines("## Summary", "", "Did it.", "", "## Evidence", "", "make test - pass", "",
           "## Merge Danger", "", "**Door:** maybe", "**Blast Radius:** the widget module"),
     "**Door:** value 'maybe' is not one-way or two-way"),
    (lines("## Summary", "## Evidence", "## Merge Danger", "**Door:**  ",
           "**Blast Radius:** x"),
     "an empty **Door:** value"),
    (lines("## Summary", "", "Did it.", "", "## Evidence", "", "make test - pass", "",
           "## Merge Danger", "", "**Door:** one-way", "**Door:** two-way", "**Blast Radius:**"),
     "a second **Door:** line under ## Merge Danger; an empty **Blast Radius:** value"),
    (lines("## Summary", "", "```markdown", "## Evidence", "```", "",
           "**Door:** two-way", "**Blast Radius:** the widget module", "",
           "## Merge Danger", "", "~~~~", "**Door:** two-way", "~~~~"),
     "no ## Evidence heading; no **Door:** line under ## Merge Danger;"
     " no **Blast Radius:** line under ## Merge Danger"),
    (lines("## Summary", "", "   ~~~", "## Evidence", "~~~", "", "## Merge Danger", "",
           "**Door:** two-way", "**Blast Radius:** the widget module"),
     "no ## Evidence heading"),
], ids=["door-value", "empty-door", "second-door-empty-blast", "fenced-or-outside",
        "indented-fence"])
def test_a_wrong_or_misplaced_piece_is_refused_naming_it(tmp_path, root, github, capsys, text,
                                                         named):
    assert publish_refused(tmp_path, root, github, capsys, text) == (1, "", REFUSED + named + "\n")


def test_a_body_with_every_piece_in_any_order_and_a_fence_holding_a_longer_run_opens_the_pr(
        tmp_path, root, github, capsys):
    text = lines("## Merge Danger", "", "**Blast Radius:** the widget module",
                 "**Door:** one-way\r", "", "## Evidence", "", "```", "not a fence end: ````",
                 "```", "", "## Summary  ", "", "Did it.")
    github.next_pr(37)

    assert orch_pr(root, github, checkout_git(root, "quick/24-standard"), "publish", "24",
                   "Title", body_file(tmp_path, text)) == 0

    assert capsys.readouterr() == ("37\n", "")


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
def test_an_unreadable_body_file_is_refused_naming_it(tmp_path, root, github, store, capsys):
    path = body_file(tmp_path)
    os.chmod(path, 0)
    try:
        assert died_of(capsys, lambda: orch_pr(root, github, checkout_git(root, QUICK_BRANCH),
                                               "publish", "16", "Title", path)) == (
            1, "", "orch: could not read the PR body from %s - no PR was opened\n" % path)
    finally:
        os.chmod(path, 0o644)
    assert prs_of(store) == []


# --- pr publish: guards, options and failures --------------------------------------


def publish(tmp_path, root, seed, git, *extra, env=None, issue="16", text=COMPLETE_BODY):
    """`pr publish <issue> Title <a body holding text> <extra>` in <git>:
    its exit code."""
    return orch_pr(root, seed, git, "publish", issue, "Title", body_file(tmp_path, text), *extra,
                   env=env)


def publish_died(tmp_path, root, seed, git, capsys, *extra, env=None, issue="16",
                 text=COMPLETE_BODY):
    return died_of(capsys, lambda: publish(tmp_path, root, seed, git, *extra, env=env,
                                           issue=issue, text=text))


def marker_of(git, branch):
    return git.config_value("branch.%s.orchestrator-pr" % branch)


@SESSIONS
@pytest.mark.parametrize("argv", [(), ("16",), ("16", "Title")])
def test_publish_with_too_few_arguments_dies_with_its_usage(root, github, capsys, argv, env):
    git = checkout_git(root, QUICK_BRANCH)

    assert died_of(capsys, lambda: orch_pr(root, github, git, "publish", *argv, env=env)) == (
        1, "", "orch: %s\n" % PUBLISH_USAGE)


@SESSIONS
def test_publish_refuses_an_issue_that_is_no_plain_number_before_the_body_standard(
        tmp_path, root, github, capsys, env):
    git = checkout_git(root, QUICK_BRANCH)

    assert publish_died(tmp_path, root, github, git, capsys, env=env, issue="abc",
                        text=body_without("## Summary")) == (
        1, "", "orch: issue must be a plain issue number, got: abc\n")


def test_publish_refuses_a_body_file_that_does_not_exist(root, github, capsys):
    git = checkout_git(root, QUICK_BRANCH)

    assert died_of(capsys, lambda: orch_pr(root, github, git, "publish", "16", "Title",
                                           "/nonexistent/body.md")) == (
        1, "", "orch: body file not found: /nonexistent/body.md\n")


def test_publish_checks_the_current_branch_before_the_body_standard(tmp_path, root, github,
                                                                    capsys):
    assert publish_died(tmp_path, root, github, checkout_git(root, None), capsys,
                        text=body_without("## Summary")) == (
        1, "", "orch: not on a branch (detached HEAD)\n")


def test_publish_opens_into_the_base_recorded_for_its_branch_with_a_refs_line(
        tmp_path, root, github, store, capsys):
    git = checkout_git(root, QUICK_BRANCH,
                       local_config={"branch.%s.orchestrator-base" % QUICK_BRANCH: "uat"})

    assert publish(tmp_path, root, github, git) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert pr_file(store, 23, "base") == "uat\n"
    assert pr_file(store, 23, "body") == "Refs #16\n\n" + COMPLETE_BODY


@SESSIONS
def test_publish_draft_opens_a_draft_recorded_on_the_branch(tmp_path, root, github, store,
                                                            capsys, env):
    git = checkout_git(root, QUICK_BRANCH)

    assert publish(tmp_path, root, github, git, "--draft", env=env) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert pr_file(store, 23, "draft") == ""
    assert pr_file(store, 23, "body").startswith("Closes #16\n\n")
    assert marker_of(git, QUICK_BRANCH) == "23"


@SESSIONS
@pytest.mark.parametrize("extra", [(), ("--draft",)])
def test_a_gh_that_will_not_open_the_pr_fails_it_relaying_its_first_line(
        tmp_path, root, github, store, capsys, extra, env):
    git = checkout_git(root, QUICK_BRANCH)
    github.fail("adapter_pr_create",
                "HTTP 422: Draft pull requests are not supported in this repository.\nsecond line")

    assert publish_died(tmp_path, root, github, git, capsys, *extra, env=env) == (
        1, "", "orch: gh could not open the PR for branch %s (issue #16): HTTP 422: Draft pull"
        " requests are not supported in this repository.\n" % QUICK_BRANCH)
    assert prs_of(store) == []
    assert marker_of(git, QUICK_BRANCH) is None


def test_publish_refuses_an_unknown_option_naming_it(tmp_path, root, github, store, capsys):
    git = checkout_git(root, QUICK_BRANCH)

    assert publish_died(tmp_path, root, github, git, capsys, "--ready") == (
        1, "", "orch: unknown option: --ready - %s\n" % PUBLISH_USAGE)
    assert prs_of(store) == []


def test_publish_with_no_label_reads_no_labels_back(tmp_path, root, github, capsys):
    github.fail("adapter_pr_labels")

    assert publish(tmp_path, root, github, checkout_git(root, QUICK_BRANCH)) == 0

    assert capsys.readouterr() == ("23\n", "")


@pytest.mark.parametrize("extra, labels, draft", [
    (("--label", "no-version-bump"), "no-version-bump\n", None),
    (("--label", "no-version-bump", "--draft", "--label", "needs review"),
     "no-version-bump\nneeds review\n", ""),
    (("--draft", "--label", "no-version-bump"), "no-version-bump\n", ""),
], ids=["once", "twice-around-draft", "draft-first"])
def test_publish_label_opens_the_pr_carrying_each_label(tmp_path, root, github, store, capsys,
                                                        extra, labels, draft):
    assert publish(tmp_path, root, github, checkout_git(root, QUICK_BRANCH), *extra) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert (pr_file(store, 23, "labels"), pr_file(store, 23, "draft")) == (labels, draft)


@pytest.mark.parametrize("extra", [("--label",), ("--label", "--draft"), ("--label", "")])
def test_publish_label_needs_a_label_name(tmp_path, root, github, store, capsys, extra):
    git = checkout_git(root, QUICK_BRANCH)

    assert publish_died(tmp_path, root, github, git, capsys, *extra) == (
        1, "", "orch: --label needs a label name - %s\n" % PUBLISH_USAGE)
    assert prs_of(store) == []


@SESSIONS
def test_a_label_that_did_not_land_fails_publish_the_pr_still_recorded(
        tmp_path, root, github, store, capsys, env):
    git = checkout_git(root, QUICK_BRANCH)
    (store / "pr_label_drops").write_text("needs review\n")

    assert publish_died(tmp_path, root, github, git, capsys, "--label", "no-version-bump",
                        "--label", "needs review", env=env) == (
        1, "", "orch: PR #23 is open but lacks the label 'needs review' - add it by hand\n")
    assert marker_of(git, QUICK_BRANCH) == "23"


def test_a_failed_label_read_fails_publish_relaying_gh(tmp_path, root, github, capsys):
    git = checkout_git(root, QUICK_BRANCH)
    github.fail("adapter_pr_labels", GH_502)

    assert publish_died(tmp_path, root, github, git, capsys, "--label", "ci") == (
        1, "", "orch: gh could not read the labels of PR #23, open and recorded on its branch:"
        " HTTP 502: Bad Gateway\n")
    assert marker_of(git, QUICK_BRANCH) == "23"


@SESSIONS
def test_a_rejected_push_fails_publish_before_any_create(tmp_path, root, github, store, capsys,
                                                         env):
    git = checkout_git(root, QUICK_BRANCH, rejected=True)

    assert publish_died(tmp_path, root, github, git, capsys, env=env) == (
        1, "", "orch: could not push branch %s to origin - no PR was opened: %s\n"
        % (QUICK_BRANCH, REJECTED % (QUICK_BRANCH, QUICK_BRANCH)))
    assert prs_of(store) == []
    assert marker_of(git, QUICK_BRANCH) is None


def test_a_failed_branch_record_warns_and_publish_still_succeeds(tmp_path, root, github,
                                                                 capsys):
    key = "branch.%s.orchestrator-pr" % QUICK_BRANCH
    git = checkout_git(root, QUICK_BRANCH, config_write_fails=[("local", key)])

    assert publish(tmp_path, root, github, git) == 0

    assert capsys.readouterr() == (
        "23\n", "error: could not lock config file .git/config: File exists\n"
        "orch: could not record PR #23 on branch %s - it counts as busy until you switch off"
        " it\n" % QUICK_BRANCH)


@pytest.fixture
def spec_with_ticket(github):
    """Issue #61 with an open sub-issue, #810."""
    github.issue(61, "open")
    github.issue(810, "open")
    github.sub_issue(61, 810)
    return github


def processes_refused(monkeypatch):
    """Every process start fails the test: the refusal is reached with no
    bridge process."""
    def refused(*args, **kwargs):
        raise AssertionError("a process was started: %r" % (args,))

    monkeypatch.setattr(subprocess, "Popen", refused)


@SESSIONS
def test_publish_refuses_while_the_issue_has_open_tickets_starting_no_process(
        tmp_path, root, spec_with_ticket, store, capsys, monkeypatch, env):
    git = checkout_git(root, "quick/61-widgets")
    processes_refused(monkeypatch)

    assert publish_died(tmp_path, root, spec_with_ticket, git, capsys, env=env, issue="61") == (
        1, "", "orch: #61 still has open tickets: #810 - run the driver loop (orch.sh ticket"
        " next 61) or close them, then run pr publish again\n")
    assert prs_of(store) == []


def test_publish_refuses_when_github_cannot_list_the_tickets(tmp_path, root, spec_with_ticket,
                                                             store, capsys):
    spec_with_ticket.fail("adapter_sub_issues", GH_502)

    assert publish_died(tmp_path, root, spec_with_ticket, checkout_git(root, "quick/61-widgets"),
                        capsys, issue="61") == (
        1, "", "orch: gh could not list sub-issues of #61: HTTP 502: Bad Gateway\n")
    assert prs_of(store) == []


def test_publish_passes_once_the_tickets_are_closed(tmp_path, root, spec_with_ticket, capsys):
    spec_with_ticket.issue(810, "closed")

    assert publish(tmp_path, root, spec_with_ticket, checkout_git(root, "quick/61-widgets"),
                   issue="61") == 0

    assert capsys.readouterr() == ("23\n", "")


# --- pr open: the create path -------------------------------------------------------


def flow(root, **state):
    """A flow at implement on #16 and FLOW_BRANCH into main with no PR, its
    keys overridden by <state> (None for a key dropped): its state file."""
    keys = dict(slug="propen", phase="implement", issue=16, branch=FLOW_BRANCH, base="main",
                pr=None)
    keys.update(state)
    return hold_flow(root, **{k: v for k, v in keys.items() if v is not None or k == "pr"})


def pr_open(tmp_path, root, seed, git, *extra, env=None, gh=None, text=COMPLETE_BODY,
            title="Title"):
    """`pr open <title> <a body holding text> <extra>` in <git>: its exit
    code."""
    return orch_pr(root, seed, git, "open", title, body_file(tmp_path, text), *extra, env=env,
                   gh=gh)


def open_died(tmp_path, root, seed, git, capsys, *extra, env=None, text=COMPLETE_BODY,
              title="Title"):
    return died_of(capsys, lambda: pr_open(tmp_path, root, seed, git, *extra, env=env,
                                           text=text, title=title))


def recorded_pr(root):
    """The PR the flow's state records, None for none."""
    return json.loads(state_json(root).read_text())["pr"]


@SESSIONS
def test_open_pushes_opens_a_draft_and_records_it_in_state_and_on_the_branch(
        tmp_path, root, github, store, capsys, env):
    flow(root, base=None)
    git = checkout_git(root, FLOW_BRANCH)
    gh = CountingGh(github.store, {}, sleep=lambda _: None)

    assert pr_open(tmp_path, root, github, git, env=env, gh=gh) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert len(gh.default_asks) == 1
    assert recorded_pr(root) == 23
    assert marker_of(git, FLOW_BRANCH) == "23"
    assert pr_file(store, 23, "draft") == ""
    assert (pr_file(store, 23, "base"), pr_file(store, 23, "head"), pr_file(store, 23, "title")) \
        == ("main\n", FLOW_BRANCH + "\n", "Title\n")
    assert pr_file(store, 23, "body") == "Closes #16\n\n" + COMPLETE_BODY


def test_open_into_a_base_other_than_the_default_refers_to_its_issue(tmp_path, root, github,
                                                                      store, capsys):
    flow(root, base="uat")

    assert pr_open(tmp_path, root, github, checkout_git(root, FLOW_BRANCH)) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert pr_file(store, 23, "base") == "uat\n"
    assert pr_file(store, 23, "body") == "Refs #16\n\n" + COMPLETE_BODY


def test_open_with_no_flow_dies_before_its_usage(root, github, capsys):
    code, out, err = died_of(capsys, lambda: orch_pr(root, github,
                                                     checkout_git(root, FLOW_BRANCH), "open"))

    assert (code, out) == (1, "")
    assert err.startswith("orch: no active flow (.orchestrator/state.json not found). Run ")


def test_open_with_an_unreadable_state_dies_before_its_usage(root, github, capsys):
    state_json(root).parent.mkdir()
    state_json(root).write_text('{"issue": 16')

    assert died_of(capsys, lambda: orch_pr(root, github, checkout_git(root, FLOW_BRANCH),
                                           "open")) == (
        1, "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")


@SESSIONS
@pytest.mark.parametrize("argv", [(), ("Title",)])
def test_open_with_too_few_arguments_dies_with_its_usage(root, github, capsys, argv, env):
    flow(root)

    assert died_of(capsys, lambda: orch_pr(root, github, checkout_git(root, FLOW_BRANCH), "open",
                                           *argv, env=env)) == (1, "", "orch: %s\n" % OPEN_USAGE)


@pytest.mark.parametrize("missing, message", [
    ("issue", "no issue recorded in state - the spec phase must publish one first"),
    ("branch", "no branch recorded in state"),
])
def test_open_checks_the_recorded_issue_and_branch_before_the_body_standard(
        tmp_path, root, github, capsys, missing, message):
    flow(root, **{missing: ""})

    assert open_died(tmp_path, root, github, checkout_git(root, FLOW_BRANCH), capsys,
                     text=body_without("## Summary")) == (1, "", "orch: %s\n" % message)


def test_open_refuses_a_body_file_that_does_not_exist(root, github, capsys):
    flow(root)

    assert died_of(capsys, lambda: orch_pr(root, github, checkout_git(root, FLOW_BRANCH), "open",
                                           "Title", "/nonexistent/body.md")) == (
        1, "", "orch: body file not found: /nonexistent/body.md\n")


def test_a_refused_body_pushes_creates_and_records_nothing(tmp_path, root, github, store,
                                                           capsys):
    state = flow(root)
    before = state.read_text()
    git = checkout_git(root, FLOW_BRANCH, rejected=True)

    assert open_died(tmp_path, root, github, git, capsys, text="Implements the thing.\n")[2] \
        .startswith(REFUSED)
    assert prs_of(store) == []
    assert marker_of(git, FLOW_BRANCH) is None
    assert state.read_text() == before


@pytest.mark.parametrize("extra, message", [
    (("--label",), "--label needs a label name - " + OPEN_USAGE),
    (("--label", "--label"), "--label needs a label name - " + OPEN_USAGE),
    (("--draft",), "unknown option: --draft - " + OPEN_USAGE),
])
def test_open_refuses_a_bad_option(tmp_path, root, github, store, capsys, extra, message):
    flow(root)

    assert open_died(tmp_path, root, github, checkout_git(root, FLOW_BRANCH), capsys,
                     *extra) == (1, "", "orch: %s\n" % message)
    assert prs_of(store) == []


@SESSIONS
def test_open_label_opens_the_draft_carrying_each_label(tmp_path, root, github, store, capsys,
                                                        env):
    flow(root)

    assert pr_open(tmp_path, root, github, checkout_git(root, FLOW_BRANCH), "--label",
                   "no-version-bump", "--label", "needs review", env=env) == 0

    assert capsys.readouterr() == ("23\n", "")
    assert pr_file(store, 23, "labels") == "no-version-bump\nneeds review\n"
    assert pr_file(store, 23, "draft") == ""


@SESSIONS
def test_labels_that_did_not_land_fail_open_the_pr_still_recorded(tmp_path, root, github, store,
                                                                  capsys, env):
    flow(root)
    git = checkout_git(root, FLOW_BRANCH)
    (store / "pr_label_drops").write_text("no-version-bump\nneeds review\n")

    assert open_died(tmp_path, root, github, git, capsys, "--label", "no-version-bump",
                     "--label", "needs review", env=env) == (
        1, "", "orch: PR #23 is open but lacks the labels 'no-version-bump', 'needs review'"
        " - add them by hand\n")
    assert recorded_pr(root) == 23
    assert marker_of(git, FLOW_BRANCH) == "23"


def test_a_label_landed_in_the_repo_s_casing_is_not_missing(tmp_path, root, github, store,
                                                            capsys):
    flow(root)
    (store / "labels").write_text("No-Version-Bump\tffffff\tours\n")

    assert pr_open(tmp_path, root, github, checkout_git(root, FLOW_BRANCH), "--label",
                   "no-version-bump") == 0

    assert capsys.readouterr() == ("23\n", "")
    assert pr_file(store, 23, "labels") == "No-Version-Bump\n"


def test_a_failed_label_read_fails_open_the_pr_still_recorded(tmp_path, root, github, capsys):
    flow(root)
    git = checkout_git(root, FLOW_BRANCH)
    github.fail("adapter_pr_labels", GH_502)

    assert open_died(tmp_path, root, github, git, capsys, "--label", "ci") == (
        1, "", "orch: gh could not read the labels of PR #23, open and recorded on its branch:"
        " HTTP 502: Bad Gateway\n")
    assert recorded_pr(root) == 23
    assert marker_of(git, FLOW_BRANCH) == "23"


@SESSIONS
@pytest.mark.parametrize("stderr, reason", [
    (GH_502, "HTTP 502: Bad Gateway"),
    ("could not add label: 'nope' not found", "could not add label: 'nope' not found"),
])
def test_a_failed_create_records_no_pr(tmp_path, root, github, store, capsys, stderr, reason,
                                       env):
    flow(root)
    git = checkout_git(root, FLOW_BRANCH)
    github.fail("adapter_pr_create", stderr)

    assert open_died(tmp_path, root, github, git, capsys, "--label", "nope", env=env) == (
        1, "", "orch: gh could not open the PR for branch %s (issue #16): %s\n"
        % (FLOW_BRANCH, reason))
    assert prs_of(store) == []
    assert recorded_pr(root) is None
    assert marker_of(git, FLOW_BRANCH) is None


@SESSIONS
def test_a_rejected_push_fails_open_before_any_create_leaving_the_state(
        tmp_path, root, github, store, capsys, env):
    state = flow(root)
    before = state.read_text()
    git = checkout_git(root, FLOW_BRANCH, rejected=True)

    assert open_died(tmp_path, root, github, git, capsys, env=env) == (
        1, "", "orch: could not push branch %s to origin - no PR was opened: %s\n"
        % (FLOW_BRANCH, REJECTED % (FLOW_BRANCH, FLOW_BRANCH)))
    assert prs_of(store) == []
    assert marker_of(git, FLOW_BRANCH) is None
    assert state.read_text() == before


def test_a_failed_branch_record_warns_and_open_still_records_the_pr(tmp_path, root, github,
                                                                    capsys):
    flow(root)
    key = "branch.%s.orchestrator-pr" % FLOW_BRANCH
    git = checkout_git(root, FLOW_BRANCH, config_write_fails=[("local", key)])

    assert pr_open(tmp_path, root, github, git) == 0

    assert capsys.readouterr() == (
        "23\n", "error: could not lock config file .git/config: File exists\n"
        "orch: could not record PR #23 on branch %s - it counts as busy until you switch off"
        " it\n" % FLOW_BRANCH)
    assert recorded_pr(root) == 23


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_failed_state_record_after_the_create_dies_with_state_write_s_message(
        tmp_path, root, github, store, capsys):
    state = flow(root)
    git = checkout_git(root, FLOW_BRANCH)
    os.chmod(str(state.parent), 0o555)
    try:
        assert open_died(tmp_path, root, github, git, capsys) == (
            1, "", "orch: could not record pr in %s - the flow is unchanged\n" % state)
    finally:
        os.chmod(str(state.parent), 0o755)
    assert prs_of(store) == [23]
    assert marker_of(git, FLOW_BRANCH) == "23"
    assert recorded_pr(root) is None


# --- pr open: the open-tickets refusal (#1734) --------------------------------------


@pytest.fixture
def open_ticket(github):
    """#16 with an open sub-issue, #800."""
    github.issue(800, "open")
    github.sub_issue(16, 800)
    return github


@SESSIONS
@pytest.mark.parametrize("state_pr", [None, 50], ids=["create", "update"])
def test_open_refuses_while_the_spec_has_open_tickets_starting_no_process(
        tmp_path, root, open_ticket, store, capsys, monkeypatch, state_pr, env):
    flow(root, pr=state_pr)
    open_ticket.pr(50, "open", FLOW_BRANCH, "main")
    open_ticket.pr_body(50, "old body")
    processes_refused(monkeypatch)

    assert open_died(tmp_path, root, open_ticket, checkout_git(root, FLOW_BRANCH), capsys,
                     env=env) == (
        1, "", "orch: #16 still has open tickets: #800 - run the driver loop (orch.sh ticket"
        " next 16) or close them, then run pr open again\n")
    assert prs_of(store) == [50]
    assert pr_file(store, 50, "body") == "old body"


def test_open_refuses_when_github_cannot_list_the_tickets(tmp_path, root, open_ticket, store,
                                                          capsys):
    flow(root)
    open_ticket.fail("adapter_sub_issues", GH_502)

    assert open_died(tmp_path, root, open_ticket, checkout_git(root, FLOW_BRANCH), capsys) == (
        1, "", "orch: gh could not list sub-issues of #16: HTTP 502: Bad Gateway\n")
    assert prs_of(store) == []


# --- pr open: the update path (#1609) -----------------------------------------------


@pytest.fixture
def recorded(root, github, store):
    """PR #50, open from FLOW_BRANCH into main, titled `old title` with body
    `old body` and the label keep-me, recorded in the flow's state."""
    flow(root, pr=50)
    github.pr(50, "open", FLOW_BRANCH, "main")
    github.pr_body(50, "old body")
    github.pr_labels(50, "keep-me")
    (store / "prs" / "50" / "title").write_text("old title\n")
    return github


@SESSIONS
def test_a_restart_updates_the_recorded_pr_creating_none(tmp_path, root, recorded, store, capsys,
                                                         env):
    assert pr_open(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), "--label", "ci",
                   env=env, title="New title") == 0

    assert capsys.readouterr() == ("50\n", "")
    assert prs_of(store) == [50]
    assert pr_file(store, 50, "title") == "New title\n"
    assert pr_file(store, 50, "body") == "Closes #16\n\n" + COMPLETE_BODY
    assert pr_file(store, 50, "labels") == "keep-me\nci\n"


@pytest.mark.parametrize("extra", [("--label", "ci", "--label", "keep-me"),
                                   ("--label", "CI", "--label", "Keep-Me")],
                         ids=["same-casing", "other-casing"])
def test_a_rerun_repeats_every_write_adding_no_label_twice(tmp_path, root, recorded, store,
                                                           capsys, extra):
    recorded.pr_labels(50, "keep-me", "ci")

    assert pr_open(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), *extra) == 0

    assert capsys.readouterr() == ("50\n", "")
    assert pr_file(store, 50, "labels") == "keep-me\nci\n"


@pytest.mark.parametrize("pr_base, flow_base, line, warned", [
    ("uat", "main", "Refs #16", "uat, not the flow's base main"),
    ("", "main", "Closes #16", None),
    ("main", "uat", "Closes #16", "main, not the flow's base uat"),
], ids=["retargeted", "empty-base", "converse"])
def test_the_restart_s_issue_line_follows_the_recorded_pr_s_base(
        tmp_path, root, recorded, store, capsys, pr_base, flow_base, line, warned):
    flow(root, pr=50, base=flow_base)
    recorded.pr(50, "open", FLOW_BRANCH, pr_base)

    assert pr_open(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH)) == 0

    warning = "" if warned is None else (
        "orch: PR #50 targets %s - its issue line follows the PR's base\n" % warned)
    assert capsys.readouterr() == ("50\n", warning)
    assert pr_file(store, 50, "body") == line + "\n\n" + COMPLETE_BODY


@SESSIONS
@pytest.mark.parametrize("state", ["closed", "merged"])
def test_a_recorded_pr_that_is_not_open_is_refused_untouched(tmp_path, root, recorded, store,
                                                             capsys, state, env):
    recorded.pr(50, state, FLOW_BRANCH, "uat")
    recorded.pr_body(50, "untouched")

    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), capsys,
                     env=env) == (
        1, "", "orch: PR #50, recorded in state, is %s, not open - no PR was opened or"
        " updated\n" % state.upper())
    assert prs_of(store) == [50]
    assert pr_file(store, 50, "body") == "untouched"


def test_a_recorded_pr_on_another_branch_is_refused(tmp_path, root, recorded, store, capsys):
    recorded.pr(50, "open", "some-other-branch", "main")

    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), capsys) == (
        1, "", "orch: PR #50, recorded in state, is on branch some-other-branch, not the flow's"
        " branch %s - no PR was opened or updated\n" % FLOW_BRANCH)
    assert prs_of(store) == [50]


@pytest.mark.parametrize("operation, what", [
    ("adapter_pr_state_draft", "read the state of PR #50, recorded in state"),
    ("adapter_pr_refs", "read the branch of PR #50, recorded in state"),
])
def test_a_recorded_pr_github_cannot_read_dies_relaying_gh(tmp_path, root, recorded, capsys,
                                                           operation, what):
    recorded.fail(operation, GH_502)

    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), capsys) == (
        1, "", "orch: gh could not %s: HTTP 502: Bad Gateway\n" % what)


def test_a_rejected_push_on_restart_leaves_the_pr_unwritten(tmp_path, root, recorded, store,
                                                            capsys):
    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH, rejected=True),
                     capsys, "--label", "other", title="Rejected title") == (
        1, "", "orch: could not push branch %s to origin - PR #50 was not updated: %s\n"
        % (FLOW_BRANCH, REJECTED % (FLOW_BRANCH, FLOW_BRANCH)))
    assert (pr_file(store, 50, "title"), pr_file(store, 50, "body"),
            pr_file(store, 50, "labels")) == ("old title\n", "old body", "keep-me\n")


@SESSIONS
@pytest.mark.parametrize("operation, message", [
    ("adapter_pr_title_edit", "gh could not write the title of PR #50: HTTP 502: Bad Gateway"),
    ("adapter_pr_body_edit", "gh could not write the body of PR #50: HTTP 502: Bad Gateway"
     " - already written: the title"),
    ("adapter_pr_labels", "gh could not read the labels of PR #50: HTTP 502: Bad Gateway"
     " - already written: the title, the body"),
    ("adapter_pr_label_add", "gh could not add the label 'other' to PR #50: HTTP 502: Bad"
     " Gateway - already written: the title, the body"),
], ids=["title", "body", "labels-read", "label-add"])
def test_a_failed_write_on_restart_names_it_and_the_writes_that_landed(
        tmp_path, root, recorded, store, capsys, operation, message, env):
    recorded.fail(operation, GH_502)

    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), capsys,
                     "--label", "other", env=env, title="Third title") == (
        1, "", "orch: %s\n" % message)


def test_a_second_failed_label_names_the_label_that_landed(tmp_path, root, recorded, capsys):
    recorded.fail_after("adapter_pr_label_add", 1, GH_502)

    assert open_died(tmp_path, root, recorded, checkout_git(root, FLOW_BRANCH), capsys,
                     "--label", "one", "--label", "two") == (
        1, "", "orch: gh could not add the label 'two' to PR #50: HTTP 502: Bad Gateway"
        " - already written: the title, the body, the label 'one'\n")
