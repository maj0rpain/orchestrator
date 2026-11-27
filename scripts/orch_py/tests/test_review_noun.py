"""The review noun's entry, review.run, in-process in a FakeGit checkout
under tmp_path with tmp_path flow state and review records - or, for resume,
in a real repository - the cases of the bash review begin, path, terminal,
resume and retire sections, the unknown-op refusal and every usage line, the
no-repo exit, and the one state read each verb makes. Each verb has a case
run again in an autopilot session, printing what the plain one prints."""
from __future__ import annotations

import json
import os
import shutil
from pathlib import Path

import pytest

from conftest import (AUTOPILOT, SESSIONS, TICKET_PARENT, FakeClock, Opens, answered, committed,
                      died_of, hold_flow, orch_review, rebasing, run_git, state_json,
                      worktree_add)
from orch import review
from orch.common import exclude_orch_dirs
from orch.git import FakeGit, Git

OPS = "begin|path|file|known-items|standards|ci|ci-log|rerun|ready|terminal|resume|retire"


# A clock reading 2026-01-02T03:04:05Z, the time a state write stamps.
CLOCK = 1767323045.0


# --- the dispatch -------------------------------------------------------------


@pytest.mark.parametrize("argv, op", [((), "<none>"), (("loop-next",), "loop-next"),
                                      (("",), "<none>")], ids=["none", "unknown", "empty"])
@SESSIONS
def test_an_op_review_does_not_have_is_refused_naming_every_op(root, capsys, argv, op, env, seed):
    assert answered(capsys, orch_review(seed, root, *argv, env=env)) == (
        1, "", "orch: unknown review op: %s (want %s)\n" % (op, OPS))


OUTSIDE = ("orch: not inside a git repository (%s) - cd into the repo's checkout (its root or a"
           " worktree) and run orch.sh there; a mktemp path is for files, not the working"
           " directory\n")


@pytest.mark.parametrize("argv", [("begin",), ("terminal", "extra"), ("bogus",), ()],
                         ids=["begin", "usage", "unknown-op", "no-op"])
def test_outside_a_checkout_every_op_dies_as_orch_sh_does_before_its_own_guards(capsys, argv):
    assert died_of(capsys, lambda: review.run(list(argv), git=FakeGit(), env={})) == (
        1, "", OUTSIDE % os.getcwd())


FILE_USAGE = ("usage: orch.sh review file <major|nit> <title> --axis <spec|standards> --finding-file"
              " <f> --severity-reason <r> --location <<file>:<line>> --why <reason>"
              " [--spec-question <q>]")


@pytest.mark.parametrize("argv, code, usage", [
    (("path", "1", "2"), 1, "usage: orch.sh review path [iteration]"),
    (("terminal", "extra"), 1, "usage: orch.sh review terminal"),
    (("resume", "extra"), 1, "usage: orch.sh review resume"),
    (("retire",), 1, "usage: orch.sh review retire <n>"),
    (("retire", "1", "2"), 1, "usage: orch.sh review retire <n>"),
    (("file", "major"), 1, FILE_USAGE),
    (("known-items", "a"), 1, "usage: orch.sh review known-items <path> <loop boundary>"),
    (("standards", "extra"), 1, "usage: orch.sh review standards"),
    (("ci", "1", "2"), 2, "usage: orch.sh review ci [--no-wait] [<pr>]"),
    (("ci-log",), 1, "usage: orch.sh review ci-log <pr>"),
    (("rerun", "1", "2"), 2, "usage: orch.sh review rerun <pr>"),
], ids=["path", "terminal", "resume", "retire-none", "retire-two", "file", "known-items",
        "standards", "ci", "ci-log", "rerun"])
def test_each_verb_given_the_wrong_arguments_dies_with_its_usage_line(root, capsys, argv, code,
                                                                       usage, seed):
    hold_flow(root, slug="x", phase="review", issue=7, pr=9, iteration=1)

    assert answered(capsys, orch_review(seed, root, *argv)) == (code, "", "orch: %s\n" % usage)


def no_flow():
    """The no-active-flow refusal, in Claude Code."""
    return ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
            " first.\n")


@pytest.mark.parametrize("argv", [("path", "1", "2"), ("terminal", "extra"), ("retire",),
                                  ("file", "major"), ("known-items", "a")],
                         ids=["path", "terminal", "retire", "file", "known-items"])
def test_a_verb_that_needs_a_flow_refuses_its_absence_before_its_usage(root, capsys, argv, seed):
    assert answered(capsys, orch_review(seed, root, *argv)) == (1, "", no_flow())


@pytest.mark.parametrize("argv, code", [(("resume", "extra"), 1), (("standards", "x"), 1),
                                        (("ci", "1", "2"), 2), (("ci-log",), 1),
                                        (("rerun",), 2)],
                         ids=["resume", "standards", "ci", "ci-log", "rerun"])
def test_a_verb_that_checks_its_arguments_first_gives_its_usage_with_no_flow(root, capsys, argv,
                                                                             code, seed):
    code_seen, out, err = answered(capsys, orch_review(seed, root, *argv))

    assert (code_seen, out, err.startswith("orch: usage: orch.sh review ")) == (code, "", True)


# --- review begin -------------------------------------------------------------


def flow(root, **state):
    """A flow at phase review on issue #7 in the checkout at <root>, with
    <state>'s keys, a phase among them overriding review: its state.json."""
    return hold_flow(root, **dict(dict(slug="x", phase="review", issue=7), **state))


def state_of(root):
    """<root>'s state.json, read."""
    return json.loads(state_json(root).read_text())


def record(root, i, text):
    """Iteration <i>'s review record in <root>, holding <text>: its path."""
    path = root / ".orchestrator" / "review" / ("iteration-%02d.md" % i)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


SPENT = ("orch: budget of %s iterations spent - stop the loop and report, do not start"
         " another\n")


def test_begin_past_the_budget_refuses_leaving_the_flow_as_it_was(root, capsys, seed):
    state = flow(root, iteration=5, budget=5)
    before = state.read_text()

    assert answered(capsys, orch_review(seed, root, "begin")) == (1, "", SPENT % 5)
    assert state.read_text() == before


@pytest.mark.parametrize("budget", [{"budget": ""}, {}, {"budget": "lots"}, {"budget": None}],
                         ids=["empty", "missing", "non-numeric", "null"])
def test_begin_reads_a_budget_nobody_counted_as_the_default_of_5(root, capsys, budget, seed):
    flow(root, iteration=4, **budget)

    assert orch_review(seed, root, "begin") == 0
    assert capsys.readouterr() == ("5\n", "")
    assert answered(capsys, orch_review(seed, root, "begin")) == (1, "", SPENT % 5)


@SESSIONS
def test_begin_prints_the_next_iteration_and_records_it(root, capsys, env, seed):
    flow(root, iteration=2, budget=5, flake_rerun_used=True)

    assert orch_review(seed, root, "begin", env=env, clock=FakeClock(CLOCK)) == 0
    assert capsys.readouterr() == ("3\n", "")
    assert {k: state_of(root)[k] for k in ("iteration", "flake_rerun_used", "updated")} == {
        "iteration": 3, "flake_rerun_used": True, "updated": "2026-01-02T03:04:05Z"}


def test_a_loop_s_first_iteration_renews_its_flake_rerun_in_the_same_write(root, capsys, seed):
    flow(root, iteration=0, budget=5, flake_rerun_used=True)

    assert orch_review(seed, root, "begin") == 0
    assert capsys.readouterr() == ("1\n", "")
    assert (state_of(root)["iteration"], state_of(root)["flake_rerun_used"]) == (1, False)


def test_the_iteration_after_a_recorded_terminal_state_starts_a_loop_renewing_the_rerun(
        root, capsys, seed):
    flow(root, iteration=2, budget=5, flake_rerun_used=True)
    record(root, 2, "## Terminal state\nstop - CI failing.\n")

    assert orch_review(seed, root, "begin") == 0
    assert capsys.readouterr() == ("3\n", "")
    assert (state_of(root)["iteration"], state_of(root)["flake_rerun_used"]) == (3, False)


@pytest.mark.parametrize("text", ["## Findings\nNone\n", "## Terminal state\n\n  \n"],
                         ids=["no-section", "empty-section"])
def test_a_record_with_no_terminal_state_leaves_the_flake_rerun_spent(root, capsys, text, seed):
    flow(root, iteration=2, budget=5, flake_rerun_used=True)
    record(root, 2, text)

    assert orch_review(seed, root, "begin") == 0
    assert capsys.readouterr() == ("3\n", "")
    assert state_of(root)["flake_rerun_used"] is True


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
@pytest.mark.parametrize("iteration, keys", [(0, "iteration, flake_rerun_used"), (2, "iteration")],
                         ids=["first", "later"])
def test_a_failed_state_write_dies_printing_no_iteration(root, capsys, iteration, keys, seed):
    state = flow(root, iteration=iteration, budget=5)
    (root / ".orchestrator" / "review").mkdir()
    before = state.read_text()
    os.chmod(str(state.parent), 0o555)
    try:
        assert answered(capsys, orch_review(seed, root, "begin")) == (
            1, "", "orch: could not record %s in %s - the flow is unchanged\n" % (keys, state))
    finally:
        os.chmod(str(state.parent), 0o755)
    assert state.read_text() == before


def test_begin_on_an_iteration_that_is_no_number_dies_recording_nothing(root, capsys, seed):
    state = flow(root, iteration="abc", budget=5)
    before = state.read_text()

    assert answered(capsys, orch_review(seed, root, "begin")) == (
        1, "", "orch: not an iteration number: abc\n")
    assert state.read_text() == before


# --- review path --------------------------------------------------------------


def review_dir(root):
    return root / ".orchestrator" / "review"


@pytest.mark.parametrize("argv, name", [((), "iteration-05.md"), (("",), "iteration-05.md"),
                                        (("2",), "iteration-02.md"), (("08",), "iteration-08.md"),
                                        (("123",), "iteration-123.md")],
                         ids=["recorded", "empty", "padded", "base-10", "wide"])
def test_path_prints_the_iteration_s_flat_record_making_the_review_directory(root, capsys, argv,
                                                                            name, seed):
    flow(root, iteration=5)

    assert orch_review(seed, root, "path", *argv) == 0
    assert capsys.readouterr() == ("%s/%s\n" % (review_dir(root), name), "")
    assert review_dir(root).is_dir()


@pytest.mark.parametrize("n", ["nope", "-1", " 2", "1.0"])
def test_path_refuses_what_is_not_an_iteration_number_printing_no_path(root, capsys, n, seed):
    flow(root, iteration=5)

    assert answered(capsys, orch_review(seed, root, "path", n)) == (
        1, "", "orch: not an iteration number: %s\n" % n)


@SESSIONS
def test_a_review_directory_that_cannot_be_made_is_no_path(root, capsys, env, seed):
    flow(root, iteration=1)
    review_dir(root).write_text("a file\n")

    assert answered(capsys, orch_review(seed, root, "path", env=env)) == (
        1, "", "orch: cannot create the review directory %s\n" % review_dir(root))


# --- review terminal ----------------------------------------------------------

GOLDEN = Path(__file__).resolve().parent / "review_terminal"
# Every golden record whose state.json the entry read can read: the one left
# holds a truncated one, which only the fallback's own read meets.
VERB_CASES = sorted(path.name for path in GOLDEN.iterdir()
                    if path.is_dir() and path.name != "fallback-state-unread")


def golden_flow(case, root):
    """<case>'s review/ tree copied into <root>'s .orchestrator/, and its
    state.json with its args' iteration and budget recorded in it: its
    expected stdout and exit code, `<root>` read as <root>."""
    orch_dir = root / ".orchestrator"
    orch_dir.mkdir()
    source = GOLDEN / case / "review"
    if source.is_dir():
        shutil.copytree(str(source), str(orch_dir / "review"))
    elif source.exists():
        shutil.copy(str(source), str(orch_dir / "review"))
    held = GOLDEN / case / "state.json"
    state = json.loads(held.read_text()) if held.exists() else {"slug": "x", "phase": "review"}
    iteration, budget = (GOLDEN / case / "args").read_text().split()
    hold_flow(root, **dict(state, iteration=int(iteration), budget=int(budget)))
    expected = (GOLDEN / case / "expected").read_text().replace("<root>", str(root))
    lines, _, status = expected.rstrip("\n").rpartition("\n")
    return (lines + "\n" if lines else ""), int(status.split()[1])


@pytest.mark.parametrize("case", VERB_CASES)
def test_terminal_prints_each_golden_record_s_classification_and_exits_its_status(case, root,
                                                                                 capsys, seed):
    out, status = golden_flow(case, root)

    assert orch_review(seed, root, "terminal") == status
    assert capsys.readouterr() == (out, "")


MALFORMED = ("malformed\nexpected: first line 'ready', or 'stop' with its reason after a"
             " separator (-, –, —, :) or on the lines below\n")


def midway(root, branch="orch/21-rtmid-redo-1"):
    """A flow at review on issue #21, slug rtmid, whose redo review has
    retired iteration 1 of budget 1 into pre-redo-1/ and, on <branch>,
    not yet made its closing write: the retired record's path."""
    flow_state = dict(slug="rtmid", phase="review", issue=21, branch=branch, redo_count=1,
                      iteration=1, budget=1)
    hold_flow(root, **flow_state)
    retired = review_dir(root) / "pre-redo-1" / "iteration-01.md"
    retired.parent.mkdir(parents=True)
    return retired


@pytest.mark.parametrize("text, out, status", [
    ("## Terminal state\nstop\nCI failed twice.\n", "stop\nCI failed twice.\n", 0),
    (None, "interrupted\n", 1),
    ("## Terminal state\nstopped here\n", MALFORMED, 1),
], ids=["stop", "no-record", "malformed"])
@SESSIONS
def test_terminal_mid_redo_reads_the_retired_record(root, capsys, text, out, status, env, seed):
    retired = midway(root)
    if text is None:
        shutil.rmtree(str(retired.parent))
    else:
        retired.write_text(text)

    assert orch_review(seed, root, "terminal", env=env) == status
    assert capsys.readouterr() == (out, "")


def test_after_a_completed_redo_the_flow_branch_reads_its_flat_record_alone(root, capsys, seed):
    midway(root, branch="orch/21-rtmid").write_text("## Terminal state\nstop\nold.\n")

    assert orch_review(seed, root, "terminal") == 1
    assert capsys.readouterr() == ("interrupted\n", "")


def test_terminal_reads_its_state_once_even_through_the_fallback(root, capsys, monkeypatch, seed):
    midway(root).write_text("## Terminal state\nstop\n")
    opens = Opens(monkeypatch, state_json(root))

    assert orch_review(seed, root, "terminal") == 0
    assert (capsys.readouterr(), opens.count) == (("stop\n", ""), 1)


def test_the_fallback_on_its_own_reads_its_state_in_one_read(root, monkeypatch):
    retired = midway(root)
    retired.write_text("## Terminal state\nstop\n")
    opens = Opens(monkeypatch, state_json(root))

    assert review.review_terminal_record(str(root), "1") == str(retired)
    assert opens.count == 1


# --- review retire ------------------------------------------------------------


def records(root, *names):
    """Each of <names> written empty under <root>'s review directory."""
    for name in names:
        path = review_dir(root) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("")


def review_files(root):
    """Every file under <root>'s review directory, by its path there."""
    return sorted(p.relative_to(review_dir(root)).as_posix()
                  for p in review_dir(root).rglob("*") if p.is_file())


@SESSIONS
def test_retire_moves_every_record_and_its_reports_into_the_redo_s_folder(root, capsys, env, seed):
    flow(root)
    records(root, "iteration-01.md", "iteration-03.md", "iteration-03-spec.md", "notes.md")

    assert orch_review(seed, root, "retire", "2", env=env) == 0
    assert capsys.readouterr() == ("%s/pre-redo-2\n" % review_dir(root), "")
    assert review_files(root) == ["notes.md", "pre-redo-2/iteration-01.md",
                                  "pre-redo-2/iteration-03-spec.md", "pre-redo-2/iteration-03.md"]


def test_retire_with_nothing_to_move_prints_the_folder_and_makes_none(root, capsys, seed):
    flow(root)

    assert orch_review(seed, root, "retire", "1") == 0
    assert capsys.readouterr() == ("%s/pre-redo-1\n" % review_dir(root), "")
    assert list(review_dir(root).iterdir()) == []


def test_retire_resumes_into_the_folder_a_died_run_of_the_same_redo_made(root, capsys, seed):
    flow(root)
    records(root, "pre-redo-1/iteration-01.md", "iteration-02.md")

    assert orch_review(seed, root, "retire", "1") == 0
    assert capsys.readouterr() == ("%s/pre-redo-1\n" % review_dir(root), "")
    assert review_files(root) == ["pre-redo-1/iteration-01.md", "pre-redo-1/iteration-02.md"]


def test_retire_refuses_to_overwrite_a_record_moving_nothing(root, capsys, seed):
    flow(root)
    records(root, "pre-redo-1/iteration-02.md", "iteration-01.md", "iteration-02.md")

    assert answered(capsys, orch_review(seed, root, "retire", "1")) == (
        1, "", "orch: %s/pre-redo-1 already holds a review record - redo_count should only"
        " increase - refusing to overwrite it\n" % review_dir(root))
    assert review_files(root) == ["iteration-01.md", "iteration-02.md",
                                  "pre-redo-1/iteration-02.md"]


def test_retire_refuses_what_is_not_a_redo_number(root, capsys, seed):
    flow(root)
    records(root, "iteration-01.md")

    assert answered(capsys, orch_review(seed, root, "retire", "nope")) == (
        1, "", "orch: not a redo number: nope\n")
    assert review_files(root) == ["iteration-01.md"]


# --- review resume (ADR-0054) -------------------------------------------------


@pytest.fixture
def resuming(ticket_repo):
    """ticket_repo, the working directory, with .orchestrator/ git-excluded
    as a real flow's is, holding a flow on TICKET_PARENT at iteration 2 of
    budget 5, iteration 1's record and iteration 2's two reviewer reports
    left by a dead run: its root."""
    exclude_orch_dirs(Git())
    flow(ticket_repo, branch=TICKET_PARENT, iteration=2, budget=5)
    record(ticket_repo, 1, "## Findings\nNone\n")
    records(ticket_repo, "iteration-02-spec.md", "iteration-02-standards.md")
    return ticket_repo


def orch_resume(seed, root, env=None):
    """`orch.sh review resume` in the real checkout at <root>: its exit
    code."""
    return orch_review(seed, root, "resume", env=env, git=Git())


def facts(root):
    """What a refused resume leaves as it was: the state file, the review
    directory and the tree's status."""
    return state_json(root).read_text(), review_files(root), run_git(root, "status",
                                                                     "--porcelain")


@SESSIONS
def test_resume_with_no_record_clears_the_dead_run_s_reports_and_reruns_it(resuming, capsys,
                                                                            env, seed):
    before = state_json(resuming).read_text()

    assert orch_resume(seed, resuming, env) == 0
    assert capsys.readouterr() == ("rerun 2\n", "")
    assert review_files(resuming) == ["iteration-01.md"]
    assert state_json(resuming).read_text() == before


def test_resume_with_a_record_short_of_the_budget_goes_on_to_the_next(resuming, capsys, seed):
    record(resuming, 2, "## Findings\nNone\n")
    before = state_json(resuming).read_text()

    assert orch_resume(seed, resuming) == 0
    assert capsys.readouterr() == ("next\n", "")
    assert "iteration-02-spec.md" in review_files(resuming)
    assert state_json(resuming).read_text() == before


def test_resume_with_a_record_at_the_budget_terminates(resuming, capsys, seed):
    flow(resuming, branch=TICKET_PARENT, iteration=2, budget=2)
    record(resuming, 2, "## Findings\nNone\n")
    before = state_json(resuming).read_text()

    assert orch_resume(seed, resuming) == 0
    assert capsys.readouterr() == ("terminate\n", "")
    assert state_json(resuming).read_text() == before


@pytest.mark.parametrize("iteration, text, word", [
    (0, None, "none"),
    (2, "## Terminal state\nready\n", "ready"),
    (2, "## Terminal state\nstop - CI failed.\n", "stop"),
    (2, "## Terminal state\nstopped\n", "malformed"),
], ids=["none", "ready", "stop", "malformed"])
def test_resume_refuses_a_loop_that_is_not_pending_or_interrupted_touching_nothing(
        resuming, capsys, iteration, text, word, seed):
    flow(resuming, branch=TICKET_PARENT, iteration=iteration, budget=5)
    if text is not None:
        record(resuming, 2, text)
    (resuming / "README.md").write_text("hand edit\n")
    before = facts(resuming)

    assert answered(capsys, orch_resume(seed, resuming)) == (
        1, "", "orch: nothing to resume: review terminal says %s\n" % word)
    assert facts(resuming) == before


def test_resume_refuses_an_unreadable_record_touching_nothing(resuming, capsys, seed):
    shutil.rmtree(str(review_dir(resuming)))
    review_dir(resuming).write_text("a file\n")
    before = state_json(resuming).read_text()

    assert answered(capsys, orch_resume(seed, resuming)) == (
        1, "", "orch: nothing to resume: review terminal says unreadable\n")
    assert state_json(resuming).read_text() == before


def test_a_failed_clear_dies_naming_the_report_leaving_the_flow(resuming, capsys, seed):
    spec_report = review_dir(resuming) / "iteration-02-spec.md"
    spec_report.unlink()
    (spec_report / "sub").mkdir(parents=True)
    before = state_json(resuming).read_text()

    assert answered(capsys, orch_resume(seed, resuming)) == (
        1, "", "orch: could not clear the dead iteration's reviewer report %s\n" % spec_report)
    assert state_json(resuming).read_text() == before


def test_a_dirty_tree_in_an_interactive_main_checkout_is_refused_touching_nothing(resuming,
                                                                                  capsys, seed):
    (resuming / "README.md").write_text("hand edit\n")
    before = facts(resuming)

    assert answered(capsys, orch_resume(seed, resuming)) == (
        1, "", "orch: uncommitted or in-progress work on the flow's branch in the main checkout -"
        " discard it yourself (README.md): git -C \"%s\" reset --hard && git -C \"%s\" clean -fd\n"
        % (resuming, resuming))
    assert facts(resuming) == before


def test_on_the_flow_s_branch_under_autopilot_resume_discards_then_reruns(resuming, capsys, seed):
    (resuming / "README.md").write_text("hand edit\n")
    (resuming / "stray.txt").write_text("junk\n")

    assert orch_resume(seed, resuming, AUTOPILOT) == 0
    assert capsys.readouterr() == ("rerun 2\n", "")
    assert run_git(resuming, "status", "--porcelain") == ""


def test_a_rebase_in_progress_on_the_flow_s_branch_is_its_branch_and_discarded(resuming,
                                                                               capsys, seed):
    run_git(resuming, "checkout", "-qb", "side", TICKET_PARENT + "~1")
    committed(resuming, {"feature.txt": "from-side\n"}, "side")
    run_git(resuming, "checkout", "-q", TICKET_PARENT)
    with pytest.raises(Exception):  # noqa: B017 - the conflict is the point
        run_git(resuming, "rebase", "-q", "side")

    assert orch_resume(seed, resuming, AUTOPILOT) == 0
    assert capsys.readouterr() == ("rerun 2\n", "")
    assert not rebasing(str(resuming))
    assert run_git(resuming, "branch", "--show-current") == TICKET_PARENT


@pytest.mark.parametrize("how, recorded, message", [
    ("other", TICKET_PARENT, "the current branch stray is not the flow's branch %s" % TICKET_PARENT),
    ("detached", TICKET_PARENT, "the current checkout is on no branch"),
    ("other", None, "on stray, the active flow records no branch yet"),
], ids=["another-branch", "detached", "no-branch-recorded"])
def test_resume_off_the_flow_s_branch_is_refused_discarding_nothing(resuming, capsys, how,
                                                                     recorded, message, seed):
    flow(resuming, branch=recorded, iteration=2, budget=5)
    run_git(resuming, "checkout", "-qb", "stray")
    if how == "detached":
        run_git(resuming, "checkout", "-q", "--detach")
    (resuming / "README.md").write_text("hand edit\n")
    before = facts(resuming)

    assert answered(capsys, orch_resume(seed, resuming, AUTOPILOT)) == (
        1, "", "orch: review resume: %s - nothing was discarded\n" % message)
    assert facts(resuming) == before


def test_with_the_flow_done_only_a_quick_branch_is_resumed_onto(resuming, capsys, seed):
    flow(resuming, branch=TICKET_PARENT, iteration=2, budget=5, phase="done")
    run_git(resuming, "checkout", "-qb", "stray")
    before = facts(resuming)

    assert answered(capsys, orch_resume(seed, resuming, AUTOPILOT)) == (
        1, "", "orch: review resume: no active flow, and stray is not a quick implementation's"
        " branch - nothing was discarded\n")
    assert facts(resuming) == before


def test_a_dirty_tree_in_a_side_checkout_is_discarded_in_a_plain_session(resuming, tmp_path,
                                                                         capsys, monkeypatch, seed):
    side = worktree_add(resuming, tmp_path / "side", "-b", "sideflow")
    monkeypatch.chdir(side)
    flow(side, branch="sideflow", iteration=1, budget=3)
    (side / "README.md").write_text("hand edit\n")

    assert orch_resume(seed, side) == 0
    assert capsys.readouterr() == ("rerun 1\n", "")
    assert run_git(side, "status", "--porcelain") == ""


# --- one state read -----------------------------------------------------------


@pytest.mark.parametrize("argv, code, out, err", [
    (("begin",), 1, "", SPENT % 1),
    (("path",), 0, "<review>/iteration-01.md\n", ""),
    (("path", "3"), 0, "<review>/iteration-03.md\n", ""),
    (("terminal",), 0, "stop\nCI failed twice.\n", ""),
    (("resume",), 1, "", "orch: nothing to resume: review terminal says stop\n"),
    (("retire", "1"), 0, "<review>/pre-redo-1\n", ""),
], ids=["begin", "path", "path-given", "terminal", "resume", "retire"])
def test_each_verb_reads_its_flow_state_once(root, capsys, monkeypatch, argv, code, out, err, seed):
    flow(root, iteration=1, budget=1)
    record(root, 1, "## Terminal state\nstop\nCI failed twice.\n")
    opens = Opens(monkeypatch, state_json(root))

    assert orch_review(seed, root, *argv) == code
    assert capsys.readouterr() == (out.replace("<review>", str(review_dir(root))), err)
    assert opens.count == 1


UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"


@pytest.mark.parametrize("argv", [("begin",), ("path",), ("path", "2"), ("terminal",),
                                  ("resume",), ("retire", "1"), ("file", "major", "t"),
                                  ("known-items", "a", "1")],
                         ids=["begin", "path", "path-given", "terminal", "resume", "retire",
                              "file", "known-items"])
def test_each_verb_that_needs_a_flow_refuses_an_unreadable_state_file(root, capsys, argv, seed):
    flow(root, iteration=1)
    state_json(root).write_text('{"slug": "x"')

    assert answered(capsys, orch_review(seed, root, *argv)) == (1, "", UNREADABLE)
