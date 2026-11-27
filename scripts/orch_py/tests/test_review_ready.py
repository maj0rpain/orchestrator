"""The review noun's ready verb, `review ready`, run in-process through
review.run in a FakeGit checkout under tmp_path - or, for the side-checkout
pointer, in real repositories - with tmp_path flow state and the gh fake on
its store: the cases of the bash review ready, finish-pointer (#727),
autopilot-flow (#1457) and failed-phase-write (#1931) sections. The CI gate
runs first, the PR is marked ready on GitHub before state records done, and
the finish is orch/phase.py's, called in process. Cases run again in an
autopilot session print what the plain one prints."""
from __future__ import annotations

import json
import os

import pytest

from conftest import (AUTOPILOT, CLAUDE, GITHUB_ORIGIN, SESSIONS, answered, archive_main,
                      hold_flow, is_draft, labels_of, mark_side, orch_review, run_git, side_checkout,
                      snapshot, state_json, worktree_add)
from orch.git import Git

HINT = " - the flow stays in review"


def phase_of(root):
    return json.loads(state_json(root).read_text())["phase"]


def ready(seed, root, env=None, git=None):
    return orch_review(seed, root, "ready", env=env, git=git)


@pytest.fixture
def flow(root, seed):
    """A flow at review on issue #3 with draft PR #7 recorded, the issue
    carrying orch:review and orch:running with its claim held, as an
    autopilot flow's is."""
    hold_flow(root, slug="reviewready", phase="review", issue=3, pr=7)
    seed.pr(7, "open", "orch/3-reviewready", "main")
    seed.pr_draft(7)
    seed.issue(3, "open", "ready-for-agent", "orch:review", "orch:running")
    seed.claim(3)
    return root


# --- the CI gate ------------------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("answer, err", [
    ("failing", "orch: PR #7 has failed checks: build" + HINT + "\n"),
    ("tworuns", "orch: PR #7 has failed checks: build, test" + HINT + "\n"),
    ("boom", "orch: PR #7 checks cannot be read: dial tcp: lookup api.github.com: no such host"
             + HINT + "\n"),
], ids=["failing", "two-failing", "unreachable"])
def test_a_refusing_gate_exits_1_leaving_the_pr_a_draft_and_the_phase_review(flow, seed, capsys,
                                                                             env, answer, err):
    seed.checks(7, "required", answer)
    before = snapshot(seed.store)

    assert answered(capsys, ready(seed, flow, env=env)) == (1, "", err)
    assert (phase_of(flow), is_draft(seed, 7)) == ("review", True)
    assert {k: v for k, v in snapshot(seed.store).items() if "checks" not in k} == {
        k: v for k, v in before.items() if "checks" not in k}


@SESSIONS
@pytest.mark.parametrize("required, every, err", [
    ("green", None, ""),
    ("pending", None, "orch: PR #7 checks are still pending\n"),
    (None, None, ""),
    (None, "pending", "orch: PR #7 checks are still pending\n"),
], ids=["green", "pending", "no-checks", "every-check-pending"])
def test_a_passing_gate_marks_the_pr_ready_and_records_done_printing_its_number(
        flow, seed, capsys, env, required, every, err):
    for scope, answer in (("required", required), ("all", every)):
        if answer is not None:
            seed.checks(7, scope, answer)

    assert answered(capsys, ready(seed, flow, env=env)) == (0, "7\n", err)
    assert (phase_of(flow), is_draft(seed, 7)) == ("done", False)


# --- GitHub before state ----------------------------------------------------------


@SESSIONS
@pytest.mark.parametrize("stderr, reason", [("HTTP 502: Bad Gateway\nsecond", "HTTP 502: Bad Gateway"),
                                            ("", "gh gave no reason")],
                         ids=["gh-s-first-line", "silent"])
def test_a_failed_mark_ready_exits_1_with_the_hint_writing_no_phase(flow, seed, capsys, env,
                                                                    stderr, reason):
    seed.fail("adapter_pr_ready", stderr)
    before = state_json(flow).read_text()

    assert answered(capsys, ready(seed, flow, env=env)) == (
        1, "", "orch: gh could not mark PR #7 ready: %s%s\n" % (reason, HINT))
    assert state_json(flow).read_text() == before
    assert is_draft(seed, 7)
    assert labels_of(seed.store, 3) == ["ready-for-agent", "orch:review", "orch:running"]
    assert seed.claim_held(3) is True


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_failed_phase_write_leaves_the_pr_ready_and_the_phase_review_and_a_re_run_finishes(
        flow, seed, capsys):
    """#1931: the PR is marked ready first; a finish that then cannot write
    stops review ready with no PR number, and the re-run records done."""
    directory = state_json(flow).parent
    os.chmod(str(directory), 0o555)
    try:
        assert answered(capsys, ready(seed, flow)) == (
            1, "", "orch: could not record phase in %s - the flow is unchanged\n"
                   % state_json(flow))
    finally:
        os.chmod(str(directory), 0o755)
    assert (phase_of(flow), is_draft(seed, 7)) == ("review", False)

    assert answered(capsys, ready(seed, flow)) == (0, "7\n", "")
    assert phase_of(flow) == "done"


# --- an autopilot flow (#1457) ------------------------------------------------------


def test_an_autopilot_flow_moves_the_label_to_done_and_releases_the_claim(flow, seed, capsys):
    assert answered(capsys, ready(seed, flow, env=AUTOPILOT)) == (0, "7\n", "")
    assert labels_of(seed.store, 3) == ["ready-for-agent", "orch:done"]
    assert seed.claim_held(3) is False
    assert phase_of(flow) == "done"


def test_a_plain_flow_touches_neither_label_nor_claim(flow, seed, capsys):
    assert answered(capsys, ready(seed, flow)) == (0, "7\n", "")
    assert labels_of(seed.store, 3) == ["ready-for-agent", "orch:review", "orch:running"]
    assert seed.claim_held(3) is True


def test_an_autopilot_finish_failing_partway_dies_with_the_writes_that_landed(flow, seed,
                                                                              capsys):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert answered(capsys, ready(seed, flow, env=AUTOPILOT)) == (
        1, "", "orch: could not delete the claim ref on issue #3: HTTP 500 - writes that landed:"
               " marked PR #7 ready, moved the phase label to orch:done, recorded phase done,"
               " removed orch:running; the claim stays held\n")
    assert seed.claim_held(3) is True


# --- refusals before the gate -------------------------------------------------------


@SESSIONS
def test_no_pr_recorded_is_refused_before_any_github_call(root, seed, capsys, env):
    hold_flow(root, slug="x", phase="review", issue=3, pr=None)
    before = snapshot(seed.store)

    assert answered(capsys, ready(seed, root, env=env)) == (
        1, "", "orch: no PR recorded in state - the implement phase opens it\n")
    assert snapshot(seed.store) == before


# gh's answer to a PR given as a name it resolves as a branch.
NO_BRANCH_PR = 'no pull requests found for branch "seven"'


def test_a_recorded_pr_that_is_no_number_goes_to_gh_as_it_is_and_dies_with_gh_s_reason(
        root, seed, capsys):
    hold_flow(root, slug="x", phase="review", issue=3, pr="seven")
    seed.fail("adapter_pr_checks", NO_BRANCH_PR)

    assert answered(capsys, ready(seed, root)) == (
        1, "", "orch: PR #seven checks cannot be read: %s%s\n" % (NO_BRANCH_PR, HINT))
    assert phase_of(root) == "review"


def test_no_flow_is_refused(root, seed, capsys):
    assert answered(capsys, ready(seed, root)) == (
        1, "", "orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
               " first.\n")


# --- the side-checkout pointer (#727) -----------------------------------------------

POINTER = ("orch: this is a side checkout - once PR #%d merges, run /orchestrator:finish to"
           " archive its flow and remove it\n")


@pytest.fixture
def main(tmp_path):
    """A repository with one commit and its origin on GitHub: its root."""
    path = archive_main(tmp_path)
    run_git(path, "remote", "add", "origin", GITHUB_ORIGIN["origin"])
    return path


def reviewing_at(path, seed, n):
    """A flow at review in the checkout at <path> with draft PR #<n>
    recorded."""
    hold_flow(path, slug="rr", phase="review", issue=3, pr=n)
    seed.pr(n, "open", "rr", "main")
    seed.pr_draft(n)


@SESSIONS
def test_in_a_side_checkout_stdout_stays_the_pr_number_and_stderr_points_at_finish(
        main, seed, capsys, env):
    sc = side_checkout(main, "rr")
    reviewing_at(sc, seed, 70)
    seed.issue(3, "open", "orch:review")
    seed.claim(3)

    assert answered(capsys, ready(seed, sc, env=env, git=Git(str(sc)))) == (
        0, "70\n", POINTER % 70)


def test_a_ticket_worktree_carrying_a_copied_marker_gets_no_pointer(main, seed, capsys):
    marked = worktree_add(main, main / ".orchestrator" / "worktrees" / "t43", "-b", "main--t43")
    mark_side(marked)
    reviewing_at(marked, seed, 72)

    assert answered(capsys, ready(seed, marked, git=Git(str(marked)))) == (0, "72\n", "")


def test_the_main_checkout_gets_no_pointer(main, seed, capsys):
    reviewing_at(main, seed, 71)

    assert answered(capsys, ready(seed, main, git=Git(str(main)))) == (0, "71\n", "")


def test_the_pointer_names_the_finish_command_in_the_host_s_own_words(main, seed, capsys):
    sc = side_checkout(main, "rr")
    reviewing_at(sc, seed, 70)

    code = ready(seed, sc, env=dict(CLAUDE, ORCHESTRATOR_HOST="codex"), git=Git(str(sc)))

    assert answered(capsys, code) == (
        0, "70\n", "orch: this is a side checkout - once PR #70 merges, run /orchestrator:finish"
                   " (or orch-flow's Finish section) to archive its flow and remove it\n")
