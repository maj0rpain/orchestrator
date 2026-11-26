"""The pr noun's draft and ready verbs, run in-process against FakeGit and the
gh fake, with the checkout and its state.json under tmp_path, each checked by
its stdout, its `orch:` message, its exit code and the PR's draft flag in the
store - as the bash pr draft and pr ready answered. pr ready's CI gate is
orch/review.py's ci_ready_gate."""
from __future__ import annotations

import os

import pytest

from orch.flow_state import STATE_UNREADABLE_MSG
from orch.git import FakeGit
from orch.repo import REPO_REMEDY
from conftest import GH_502, SESSIONS, hold_flow, orch_pr, snapshot, state_json

ORIGIN = {"origin": "https://github.com/acme/widgets.git"}
BRANCH = "quick/12-foo"
# Both verbs, each case of their shared front run through each; every one of
# them also runs under ORCH_AUTOPILOT=1 (SESSIONS), answering as the plain run.
VERBS = pytest.mark.parametrize("verb", ["draft", "ready"])
ACTIVE = pytest.mark.parametrize("phase", ["spec", "implement", "review"])
FORK_LINE = "orch: ignored 1 PR(s) from forks for %s\n" % BRANCH


@pytest.fixture
def git(root):
    """The checkout's git adapter: its toplevel <root>, on BRANCH, with a
    GitHub origin."""
    adapter = FakeGit(ORIGIN, toplevel=str(root))
    adapter.seed("current_branch", answer=BRANCH)
    return adapter


@pytest.fixture
def mine(seed):
    """PR #57, open from BRANCH into main, ready, beside another branch's
    open PR #50 and the branch's closed #51 and merged #52, every one of
    them a draft."""
    seed.pr(50, "open", "quick/99-other", "main")
    seed.pr(51, "closed", BRANCH, "main")
    seed.pr(52, "merged", BRANCH, "main")
    for n in (50, 51, 52):
        seed.pr_draft(n)
    seed.pr(57, "open", BRANCH, "main")
    return 57


def is_draft(seed, n):
    return os.path.isfile(os.path.join(seed.store, "prs", str(n), "draft"))


def starting(seed, verb, n):
    """PR #n in the state <verb> changes: ready for draft, a draft for
    ready."""
    if verb == "ready":
        seed.pr_draft(n)


def checks_reads(seed, n):
    """How many times the PR's checks were read."""
    path = os.path.join(seed.store, "checks", str(n), "reads")
    if not os.path.isfile(path):
        return 0
    with open(path) as f:
        return len(f.read().splitlines())


# --- pr draft ----------------------------------------------------------------


@SESSIONS
def test_draft_turns_the_branch_s_open_pr_into_a_draft(seed, git, mine, capsys, env):
    assert orch_pr(seed, git, "draft", env=env) == 0

    assert capsys.readouterr() == ("PR #57 is now a draft\n", "")
    assert is_draft(seed, 57)


def test_draft_leaves_a_pr_already_a_draft_as_it_is(seed, git, mine, capsys):
    seed.pr_draft(57)

    assert orch_pr(seed, git, "draft") == 0

    assert capsys.readouterr() == ("PR #57 is already a draft\n", "")
    assert is_draft(seed, 57)


def test_a_failed_conversion_exits_2_with_gh_s_reason(seed, git, mine, capsys):
    seed.fail("adapter_pr_draft",
              "HTTP 422: Draft pull requests are not supported in this repository.\nsecond line")

    assert orch_pr(seed, git, "draft") == 2

    assert capsys.readouterr() == ("", "orch: gh could not turn PR #57 into a draft: HTTP 422:"
                                   " Draft pull requests are not supported in this repository.\n")
    assert not is_draft(seed, 57)


# --- pr ready ----------------------------------------------------------------


@SESSIONS
def test_ready_marks_the_branch_s_open_draft_pr_ready(seed, git, mine, capsys, env):
    seed.pr_draft(57)

    assert orch_pr(seed, git, "ready", env=env) == 0

    assert capsys.readouterr() == ("PR #57 is now ready\n", "")
    assert not is_draft(seed, 57)
    assert is_draft(seed, 50)


@SESSIONS
def test_ready_leaves_a_pr_already_ready_reading_no_checks(seed, git, mine, capsys, env):
    seed.checks(57, "required", "failing")

    assert orch_pr(seed, git, "ready", env=env) == 0

    assert capsys.readouterr() == ("PR #57 is already ready\n", "")
    assert checks_reads(seed, 57) == 0


@SESSIONS
def test_a_failed_promotion_exits_2_with_gh_s_reason(seed, git, mine, capsys, env):
    seed.pr_draft(57)
    seed.fail("adapter_pr_ready", "HTTP 403: Resource not accessible by integration\nsecond line")

    assert orch_pr(seed, git, "ready", env=env) == 2

    assert capsys.readouterr() == (
        "", "orch: gh could not mark PR #57 ready: HTTP 403: Resource not accessible by"
        " integration\n")
    assert is_draft(seed, 57)


# --- pr ready's CI gate: one look at the counted checks ----------------------

GATE = [
    # (required answer, every check's answer, exit, stderr, reads)
    pytest.param("failing", None, 2, "orch: PR #57 has failed checks: build\n", 1,
                 id="a failed required check"),
    pytest.param("cancel", None, 2, "orch: PR #57 has failed checks: build\n", 1,
                 id="a cancelled required check"),
    pytest.param("tworuns", None, 2, "orch: PR #57 has failed checks: build, test\n", 1,
                 id="two failed checks"),
    pytest.param("comma", None, 2, "orch: PR #57 has failed checks: build (linux, x64)\n", 1,
                 id="a failed check named with a comma"),
    pytest.param("boom", None, 2, "orch: PR #57 checks cannot be read: dial tcp: lookup"
                 " api.github.com: no such host\n", 1, id="unreachable required checks"),
    pytest.param("pending", None, 0, "orch: PR #57 checks are still pending\n", 1,
                 id="a pending check"),
    pytest.param("green", None, 0, "", 1, id="green checks"),
    pytest.param(None, None, 0, "", 2, id="no checks at all"),
    pytest.param("none", "failing", 2, "orch: PR #57 has failed checks: build\n", 2,
                 id="no required checks and every check failing"),
    pytest.param("none", "boom", 2, "orch: PR #57 checks cannot be read: dial tcp: lookup"
                 " api.github.com: no such host\n", 2,
                 id="no required checks and every check unreachable"),
    pytest.param("none", "pending", 0, "orch: PR #57 checks are still pending\n", 2,
                 id="no required checks and every check pending"),
    pytest.param("green", "failing", 0, "", 1,
                 id="green required checks beside a failing other check"),
]


@SESSIONS
@pytest.mark.parametrize("required, every, code, err, reads", GATE)
def test_the_ci_gate(seed, git, mine, capsys, env, required, every, code, err, reads):
    for scope, answer in (("required", required), ("all", every)):
        if answer is not None:
            seed.checks(57, scope, answer)
    seed.pr_draft(57)

    assert orch_pr(seed, git, "ready", env=env) == code

    assert capsys.readouterr() == ("" if code else "PR #57 is now ready\n", err)
    assert is_draft(seed, 57) == bool(code)
    assert checks_reads(seed, 57) == reads


@SESSIONS
def test_a_done_flow_s_branch_gets_past_the_guard_to_the_gate(seed, git, root, mine, capsys,
                                                              env):
    hold_flow(root, slug="x", phase="done", issue=30, branch=BRANCH)
    seed.checks(57, "required", "failing")
    seed.pr_draft(57)

    assert orch_pr(seed, git, "ready", env=env) == 2

    assert capsys.readouterr() == ("", "orch: PR #57 has failed checks: build\n")
    assert is_draft(seed, 57)


# --- both verbs' shared front ------------------------------------------------


@SESSIONS
@VERBS
def test_no_open_pr_exits_1_touching_no_closed_or_merged_pr(seed, git, verb, env, capsys):
    seed.pr(50, "open", "quick/99-other", "main")
    seed.pr(51, "closed", BRANCH, "main")
    seed.pr(52, "merged", BRANCH, "main")
    starting(seed, verb, 51)
    before = snapshot(seed.store)

    assert orch_pr(seed, git, verb, env=env) == 1

    assert capsys.readouterr() == ("", "")
    assert snapshot(seed.store) == before


@SESSIONS
@VERBS
def test_an_unreadable_pr_exits_2(seed, git, mine, verb, env, capsys):
    starting(seed, verb, 57)
    seed.fail("adapter_pr_state_draft", GH_502)

    assert orch_pr(seed, git, verb, env=env) == 2

    assert capsys.readouterr() == ("", "orch: gh could not read PR #57: HTTP 502: Bad Gateway\n")


@SESSIONS
@VERBS
def test_an_unreadable_pr_list_exits_2(seed, git, mine, verb, env, capsys):
    seed.fail("adapter_prs_open", GH_502)

    assert orch_pr(seed, git, verb, env=env) == 2

    assert capsys.readouterr() == (
        "", "orch: gh could not list the open PRs from %s: HTTP 502: Bad Gateway\n" % BRANCH)


@SESSIONS
@VERBS
@ACTIVE
def test_a_branch_an_active_flow_holds_is_refused(seed, git, root, mine, verb, env, phase, capsys):
    starting(seed, verb, 57)
    hold_flow(root, slug="x", phase=phase, issue=30, branch=BRANCH)
    before = snapshot(seed.store)

    assert orch_pr(seed, git, verb, env=env) == 2

    assert capsys.readouterr() == (
        "", "orch: the active flow holds %s at phase %s - its PR changes state only through"
        " the review loop\n" % (BRANCH, phase))
    assert snapshot(seed.store) == before


@pytest.mark.parametrize("state", [
    {"slug": "x", "phase": "done", "issue": 30, "branch": BRANCH},
    {"slug": "x", "phase": "review", "issue": 12, "branch": "orch/12-x"},
], ids=["a done flow on the branch", "an active flow on another branch"])
@SESSIONS
@VERBS
def test_a_flow_that_does_not_hold_the_branch_lets_it_through(seed, git, root, mine, verb, env,
                                                              state, capsys):
    starting(seed, verb, 57)
    hold_flow(root, **state)

    assert orch_pr(seed, git, verb, env=env) == 0

    assert capsys.readouterr() == ("PR #57 is now %s\n" % ("a draft" if verb == "draft"
                                                          else "ready"), "")


@SESSIONS
@VERBS
def test_a_state_json_that_cannot_be_read_exits_2(seed, git, root, mine, verb, env, capsys):
    starting(seed, verb, 57)
    state_json(root).parent.mkdir(parents=True)
    state_json(root).write_text("{\n")
    before = snapshot(seed.store)

    assert orch_pr(seed, git, verb, env=env) == 2

    assert capsys.readouterr() == ("", "orch: %s\n" % STATE_UNREADABLE_MSG)
    assert snapshot(seed.store) == before


@SESSIONS
@VERBS
def test_an_argument_exits_2_with_the_usage(seed, git, mine, verb, env, capsys):
    assert orch_pr(seed, git, verb, "extra", env=env) == 2

    assert capsys.readouterr() == ("", "orch: usage: orch.sh pr %s\n" % verb)


@SESSIONS
@VERBS
def test_a_detached_head_exits_2(seed, root, mine, verb, env, capsys):
    detached = FakeGit(ORIGIN, toplevel=str(root))

    assert orch_pr(seed, detached, verb, env=env) == 2

    assert capsys.readouterr() == ("", "orch: not on a branch (detached HEAD)\n")


@SESSIONS
@VERBS
def test_no_repo_exits_2_with_the_remedy_calling_no_gh(seed, root, mine, verb, env, capsys):
    unpinned = FakeGit(toplevel=str(root))
    unpinned.seed("current_branch", answer=BRANCH)
    seed.offline()

    assert orch_pr(seed, unpinned, verb, env=env) == 2

    assert capsys.readouterr() == ("", "orch: %s\n" % REPO_REMEDY)


@SESSIONS
@VERBS
def test_with_no_repo_a_flow_held_branch_is_still_refused_first(seed, root, verb, env, capsys):
    unpinned = FakeGit(toplevel=str(root))
    unpinned.seed("current_branch", answer=BRANCH)
    hold_flow(root, slug="x", phase="review", issue=30, branch=BRANCH)

    assert orch_pr(seed, unpinned, verb, env=env) == 2

    assert "the active flow holds %s at phase review" % BRANCH in capsys.readouterr().err


# --- fork PRs (#1977) --------------------------------------------------------


@SESSIONS
@VERBS
def test_only_a_fork_pr_exits_1_leaving_it_untouched(seed, git, verb, env, capsys):
    seed.pr(60, "open", BRANCH, "main")
    seed.pr_cross(60)
    starting(seed, verb, 60)
    before = snapshot(seed.store)

    assert orch_pr(seed, git, verb, env=env) == 1

    assert capsys.readouterr() == ("", FORK_LINE)
    assert snapshot(seed.store) == before


@SESSIONS
@VERBS
def test_beside_a_newer_fork_pr_the_same_repo_pr_is_acted_on(seed, git, mine, verb, env, capsys):
    seed.pr(60, "open", BRANCH, "main")
    seed.pr_cross(60)
    starting(seed, verb, 57)
    starting(seed, verb, 60)

    assert orch_pr(seed, git, verb, env=env) == 0

    assert capsys.readouterr()[1] == FORK_LINE
    assert is_draft(seed, 57) == (verb == "draft")
    assert is_draft(seed, 60) == (verb == "ready")

