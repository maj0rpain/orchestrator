"""The redo noun, run in-process in a FakeGit checkout under tmp_path against
the gh fake on a tmp_path store, with tmp_path flow state, handoffs and review
records - the cases of the deleted bash redo sections. `redo review`: each
refusal in its guard order, a clean redo and a second one numbering on, the
retry after a failed PR close, a loop stopped short of its budget, the
taken-destination refusal, the rerun after `review retire` (#2569) and the
ticket reopen. `redo spec`: each refusal in its guard order, a clean redo and
--new-issue, the markers moved aside, the breakdown retire (#334) and the
implement-attempt retire (#1910). Both redos per handoff mode (#1820), the
single closing write and its failure, the single state read, and a resumed
rerun after a death at each step."""
from __future__ import annotations

import json
import os
from contextlib import contextmanager

import pytest

from conftest import (AUTOPILOT, CLAUDE, GH_502, Opens, comments_of, died_of, fake, files_under,
                      hold_flow, read, snapshot, state_json)
from orch import redo
from orch.git import FakeGit, Worktree

# A clock reading 2026-01-02T03:04:05Z, so redo spec's folder is known.
CLOCK = 1767323045.0
STAMP = "20260102-030405"

ISSUE, SLUG, PR = 21, "redotest", 30
BRANCH = "orch/21-redotest"


def redone(n):
    """The flow branch's -redo-<n> name."""
    return "%s-redo-%s" % (BRANCH, n)


def checkout(root, *branches, tracked=True, pushes=True):
    """The FakeGit of the checkout at <root>: its one worktree the main
    checkout on BRANCH, each of <branches> a local branch, tracking its
    origin copy when <tracked>, and, when <pushes>, origin taking the
    -redo-1 to -redo-3 pushes and the deletes of BRANCH."""
    git = FakeGit(toplevel=str(root), branches={
        name: "refs/remotes/origin/" + name if tracked else None for name in branches})
    git.seed("worktree_list", answer=[Worktree(str(root), BRANCH)])
    if pushes:
        for n in (1, 2, 3):
            git.seed("push_set_upstream", "origin",
                     "refs/heads/%s:refs/heads/%s" % (redone(n), redone(n)), answer=None)
        git.seed("remote_delete", "origin", "refs/heads/" + BRANCH, answer=None)
    return git


def orch_redo(root, seed, git, *argv, env=None):
    """`orch.sh redo <argv>` in-process in the checkout at <root>, on
    <seed>'s store, under <env> (Claude Code's plain session when None): its
    exit code."""
    return redo.run(list(argv), gh=fake(seed), git=git, env=CLAUDE if env is None else env,
                    clock=lambda: CLOCK)


def state_of(root):
    """<root>'s state.json, read."""
    return json.loads(state_json(root).read_text())


def orch(root, *parts):
    """The path of <parts> under <root>'s .orchestrator/, a Path."""
    return root.joinpath(".orchestrator", *parts)


def write(path, text):
    """<text> written to <path>, its directories made: <path>."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def record(root, i, terminal="stop\nCI failed twice."):
    """Iteration <i>'s review record, its Terminal state section
    <terminal>: its path."""
    return write(orch(root, "review", "iteration-%02d.md" % i),
                 "## Terminal state\n%s\n" % terminal)


def reviewing(root, seed, iteration=5, budget=5, **state):
    """A flow at phase review on issue #21, on BRANCH with PR #30 open from
    it, at <iteration> of <budget>, with <state>'s further keys."""
    keys = dict(slug=SLUG, phase="review", issue=ISSUE, base="main", branch=BRANCH, pr=PR,
                base_sha="deadbeefcafe", iteration=iteration, budget=budget,
                flake_rerun_used=False, redo_count=0)
    keys.update(state)
    hold_flow(root, **keys)
    seed.issue(ISSUE, "open")
    seed.pr(PR, "open", BRANCH, "main")


def pr_closed_note(n):
    """The comment redo closes a PR with, naming the -redo-<n> branch."""
    return ("This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\n"
            "A new PR will follow once the redone implement phase reaches pr open again."
            % redone(n))


# --- redo review --------------------------------------------------------------


def test_a_stopped_loop_redoes_back_to_implement_retiring_the_attempt(root, seed, store, capsys):
    reviewing(root, seed, flake_rerun_used=True)
    record(root, 5)
    write(orch(root, "handoff", "01-plan.md"), "# plan\n")
    write(orch(root, "handoff", "03-implement.md"), "# implement\n")
    git = checkout(root, BRANCH)

    assert orch_redo(root, seed, git, "review") == 0

    assert capsys.readouterr() == ("1\n", "")
    state = state_of(root)
    assert {key: state[key] for key in ("phase", "iteration", "redo_count", "branch", "pr",
                                        "base_sha", "flake_rerun_used", "base")} == {
        "phase": "implement", "iteration": 0, "redo_count": 1, "branch": None, "pr": None,
        "base_sha": None, "flake_rerun_used": True, "base": "main"}
    assert (git.branch_exists(BRANCH), git.branch_exists(redone(1))) == (False, True)
    assert git.config_regexp("local", "orchestrator-retired$") == {
        "branch.%s.orchestrator-retired" % redone(1): "true"}
    assert read(store, "prs", PR, "state") == "CLOSED\n"
    assert comments_of(store, PR, "prs") == [pr_closed_note(1)]
    assert sorted(p.relative_to(orch(root)).as_posix() for p in orch(root).rglob("*.md")) == [
        "handoff/01-plan.md", "handoff/pre-redo-1/03-implement.md",
        "review/pre-redo-1/iteration-05.md"]


def untouched(root, store):
    """What a refused or failed redo must leave as it was: the state file,
    the files under .orchestrator/ and the store."""
    return state_json(root).read_text() if state_json(root).exists() else None, \
        files_under(orch(root)), snapshot(store)


NO_FLOW = ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " first.\n")
UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"
STRANDED = ("orch: ticket worktrees are left under {root} - a redo would strand their unmerged"
            " ticket work:\n       {root}/.orchestrator/worktrees/t4 (orch.sh ticket-worktree"
            " remove 4)\n     Remove each with orch.sh ticket-worktree remove <n> first.\n")


def test_redo_review_takes_no_arguments_even_with_no_flow(root, seed, capsys):
    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "review", "x")) == (
        1, "", "orch: usage: orch.sh redo review\n")


def test_redo_review_refuses_no_flow_then_an_unreadable_state(root, seed, capsys):
    git = checkout(root)
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review")) == (1, "", NO_FLOW)
    write(state_json(root), '{"phase": ')
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review")) == (1, "", UNREADABLE)


@pytest.mark.parametrize("phase", ["spec", "implement", "done"])
def test_redo_review_refuses_outside_the_review_phase(root, seed, store, capsys, phase):
    reviewing(root, seed, phase=phase)
    record(root, 5)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review")) == (
        1, "", "orch: flow is not at the review phase - nothing to redo back from\n")
    assert untouched(root, store) == before


NEXT = {"claude": "/orchestrator:next",
        "junie": "/orchestrator:next (or orch-flow's Next phase section)"}


@pytest.mark.parametrize("host", ["claude", "junie"])
@pytest.mark.parametrize("iteration, budget, records, message", [
    (0, 5, (), "no review loop has run yet - nothing to redo back from; run {next} to start"
               " one."),
    (2, 5, (), "the review loop hasn't reached its budget yet (iteration 2 of budget 5) - that's"
               " what {next} is for; redo is for after a loop ends."),
    (5, 5, (), "the review loop's last iteration (5) has no recorded terminal state - the session"
               " looks interrupted, not stopped. Resume it with {next}; redo only runs once a"
               " loop actually ends."),
    (5, 5, ("",), "the review loop's last iteration (5) has no recorded terminal state - the"
                  " session looks interrupted, not stopped. Resume it with {next}; redo only"
                  " runs once a loop actually ends."),
    (1, 1, ("ready",), "review_terminal_state answered something redo does not know: ready"),
], ids=["none", "pending", "interrupted", "empty-section", "ready"])
def test_redo_review_refuses_every_terminal_state_but_stop_touching_nothing(
        root, seed, store, capsys, host, iteration, budget, records, message):
    reviewing(root, seed, iteration=iteration, budget=budget)
    for terminal in records:
        record(root, iteration, terminal)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review",
                                             env={"ORCHESTRATOR_HOST": host})) == (
        1, "", "orch: %s\n" % message.format(next=NEXT[host]))
    assert untouched(root, store) == before


def test_redo_review_refuses_a_malformed_record_quoting_the_rewrite_to_make(
        root, seed, store, capsys):
    reviewing(root, seed)
    path = record(root, 5, "Stop\nCI failed twice.")
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review")) == (
        1, "", "orch: the review loop's last iteration (5) has a malformed terminal state -"
               " rewrite the first line of %s in the shape below; redo only runs once a loop"
               " actually ends.\nexpected: first line 'ready', or 'stop' with its reason after a"
               " separator (-, –, —, :) or on the lines below\n" % path)
    assert untouched(root, store) == before


def test_redo_review_names_a_review_directory_it_cannot_make(root, seed, store, capsys):
    """#1334: never read as interrupted."""
    reviewing(root, seed)
    write(orch(root, "review"), "")
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review")) == (
        1, "", "orch: cannot read the review loop's terminal state: cannot create the review"
               " directory %s\n" % orch(root, "review"))
    assert untouched(root, store) == before


def test_redo_review_refuses_while_a_ticket_worktree_is_left(root, seed, store, capsys):
    reviewing(root, seed)
    record(root, 5)
    write(orch(root, "handoff", "03-implement.md"), "# implement\n")
    git = checkout(root, BRANCH)
    git.seed("worktree_list", answer=[Worktree(str(root), BRANCH),
                                      Worktree(str(orch(root, "worktrees", "t4")), BRANCH + "--t4")])
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review")) == (
        1, "", STRANDED.format(root=root))
    assert untouched(root, store) == before
    assert git.branch_exists(BRANCH)


@pytest.mark.parametrize("key, message", [
    ("issue", "no issue recorded in state - the spec phase must publish one first"),
    ("branch", "no branch recorded in state"),
    ("pr", "no PR recorded in state - the implement phase opens it"),
])
def test_redo_review_requires_the_issue_then_the_branch_then_the_pr(
        root, seed, store, capsys, key, message):
    order = ("issue", "branch", "pr")
    reviewing(root, seed, **{k: None for k in order[order.index(key):]})
    record(root, 5)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review")) == (
        1, "", "orch: %s\n" % message)
    assert untouched(root, store) == before


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")])
def test_an_unknown_op_is_refused_naming_the_ops_it_wants(root, seed, capsys, argv, named):
    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), *argv)) == (
        1, "", "orch: unknown redo op: %s (want review|spec)\n" % named)


def test_a_second_redo_numbers_on_beside_the_first_s_records(root, seed, store, capsys):
    reviewing(root, seed, redo_count=1, pr=31)
    seed.pr(31, "open", BRANCH, "main")
    write(orch(root, "review", "pre-redo-1", "iteration-05.md"), "the first loop's\n")
    record(root, 5)
    git = checkout(root, BRANCH, redone(1))

    assert orch_redo(root, seed, git, "review") == 0

    assert capsys.readouterr().out == "2\n"
    assert git.branch_exists(redone(2))
    assert comments_of(store, 31, "prs") == [pr_closed_note(2)]
    assert orch(root, "review", "pre-redo-1", "iteration-05.md").read_text() == "the first loop's\n"
    assert orch(root, "review", "pre-redo-2", "iteration-05.md").exists()


def test_a_pr_that_will_not_close_fails_the_redo_and_leaves_the_flow_as_it_was(
        root, seed, store, capsys):
    # The retry that finishes it is the pr-close case of
    # test_redo_review_resumed_after_a_death_at_any_step_finishes_once.
    reviewing(root, seed, iteration=1, budget=1)
    flat = record(root, 1)
    git = checkout(root, BRANCH)
    seed.fail("adapter_pr_close", GH_502)
    state_before = state_json(root).read_text()

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review")) == (
        1, "", "orch: gh could not close PR #30: HTTP 502: Bad Gateway\n")
    assert read(store, "prs", PR, "state") == "OPEN\n"
    assert state_json(root).read_text() == state_before
    assert (git.branch_exists(BRANCH), git.branch_exists(redone(1)), flat.exists()) == (
        True, False, True)


@pytest.mark.parametrize("terminal", ["stop - base sync failed.", "stop"])
def test_a_loop_stopped_short_of_its_budget_redoes(root, seed, store, capsys, terminal):
    reviewing(root, seed, iteration=2, budget=5)
    record(root, 2, terminal)

    assert orch_redo(root, seed, checkout(root, BRANCH), "review") == 0
    assert capsys.readouterr().out == "1\n"
    assert read(store, "prs", PR, "state") == "CLOSED\n"


def test_redo_review_refuses_a_taken_handoff_destination_never_suffixing_it(
        root, seed, store, capsys):
    """#304: the implement handoff retires into exactly the pre-redo-<n>/
    that pairs with review/pre-redo-<n>/."""
    reviewing(root, seed, iteration=1, budget=1)
    record(root, 1)
    write(orch(root, "handoff", "pre-redo-1", "03-implement.md"), "# older implement\n")
    write(orch(root, "handoff", "03-implement.md"), "# implement\n")
    git = checkout(root, BRANCH)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review")) == (
        1, "", "orch: %s already holds a retired handoff - refusing to overwrite it\n"
               % orch(root, "handoff", "pre-redo-1"))
    assert untouched(root, store) == before
    assert git.branch_exists(BRANCH)
    assert not orch(root, "handoff", "pre-redo-1-2").exists()


def test_a_rerun_after_review_retire_finds_the_stopped_record_and_completes(
        root, seed, store, capsys):
    """#2569: a redo that died after moving the loop's records is
    half-finished: redo_count 1 and the branch its -redo-1 name."""
    reviewing(root, seed, iteration=1, budget=1, branch=redone(1), redo_count=1)
    seed.pr(PR, "closed", BRANCH, "main")
    write(orch(root, "review", "pre-redo-1", "iteration-01.md"),
          "## Terminal state\nstop\nCI failed twice.\n")
    git = checkout(root, redone(1), pushes=False)

    assert orch_redo(root, seed, git, "review") == 0

    assert capsys.readouterr() == ("1\n", "")
    state = state_of(root)
    assert [state[k] for k in ("phase", "iteration", "branch", "pr", "redo_count")] == [
        "implement", 0, None, None, 1]
    assert sorted(p.relative_to(orch(root)).as_posix() for p in orch(root).rglob("*.md")) == [
        "review/pre-redo-1/iteration-01.md"]
    assert comments_of(store, PR, "prs") == []


def test_a_refused_rerun_on_a_flow_redone_once_reads_its_flat_record(root, seed, capsys):
    reviewing(root, seed, iteration=1, budget=1, redo_count=1)
    write(orch(root, "review", "pre-redo-1", "iteration-01.md"), "## Terminal state\nstop\n")
    write(orch(root, "review", "iteration-01.md"), "# Review iteration 1\n")

    assert "has no recorded terminal state" in died_of(
        capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review"))[2]


def test_redo_review_reopens_exactly_the_tickets_the_implement_phase_closed(
        root, seed, store, capsys):
    """#88: else the redone implement phase's frontier finds nothing."""
    reviewing(root, seed, iteration=1, budget=1)
    record(root, 1)
    for n, state in ((40, "closed"), (41, "closed"), (42, "open")):
        seed.issue(n, state)
        seed.sub_issue(ISSUE, n)
    write(orch(root, "reports", "40.md"), "landed\n")
    write(orch(root, "reports", "21.md"), "landed\n")

    assert orch_redo(root, seed, checkout(root, BRANCH), "review") == 0

    assert [read(store, "issues", n, "state") for n in (40, 41, 42)] == ["OPEN\n"] * 3
    assert not orch(root, "reports", "40.md").exists()
    assert not orch(root, "reports", "21.md").exists()


# --- redo spec ----------------------------------------------------------------

SPEC_FOLDER = "pre-redo-spec-" + STAMP


def implementing(root, seed, issue=40, **state):
    """A flow at phase implement on issue <issue>, open, with <state>'s
    further keys - no branch unless given."""
    keys = dict(slug=SLUG, phase="implement", issue=issue, base="main", branch=None, pr=None,
                base_sha=None, iteration=0, redo_count=0)
    keys.update(state)
    hold_flow(root, **keys)
    if issue is not None:
        seed.issue(issue, "open")


def handoffs(root, **texts):
    """Each handoff or marker of <texts>, by its name with - for _ and . for
    __, written into <root>'s handoff directory holding its text."""
    for name, text in texts.items():
        write(orch(root, "handoff", name.replace("__", ".").replace("_", "-")), text)


def spec_handoffs(root):
    """The plan, spec and implement handoffs, and both spec markers."""
    handoffs(root, **{"01_plan__md": "# plan\n", "02_spec__md": "# spec\n",
                      "03_implement__md": "# implement\n", "spec_paused": "40\n",
                      "spec_round": "40 2 3\n"})


def test_redo_spec_steps_back_keeping_the_issue_and_moving_the_stale_files_aside(
        root, seed, store, capsys):
    implementing(root, seed, redo_count=2)
    spec_handoffs(root)
    before = snapshot(store)

    assert orch_redo(root, seed, checkout(root), "spec") == 0

    assert capsys.readouterr() == ("", "")
    state = state_of(root)
    assert [state[k] for k in ("phase", "issue", "redo_count", "branch", "pr", "base_sha")] == [
        "spec", 40, 2, None, None, None]
    assert snapshot(store) == before
    assert files_under(orch(root, "handoff")) == ["01-plan.md"] + [
        "%s/%s" % (SPEC_FOLDER, name)
        for name in ("02-spec.md", "03-implement.md", "spec-paused", "spec-round")]
    assert orch(root, "handoff", SPEC_FOLDER, "spec-round").read_text() == "40 2 3\n"


def test_redo_spec_with_no_marker_still_retires_the_spec_handoff(root, seed, capsys):
    implementing(root, seed)
    handoffs(root, **{"02_spec__md": "# spec\n"})

    assert orch_redo(root, seed, checkout(root), "spec") == 0
    assert files_under(orch(root, "handoff")) == [SPEC_FOLDER + "/02-spec.md"]


def test_new_issue_closes_the_old_issue_with_its_note_and_clears_it(root, seed, store, capsys):
    implementing(root, seed, issue=41)
    handoffs(root, **{"02_spec__md": "# spec again\n", "spec_paused": "41\n"})

    assert orch_redo(root, seed, checkout(root), "spec", "--new-issue") == 0

    assert capsys.readouterr() == ("", "")
    assert [state_of(root)[k] for k in ("phase", "issue")] == ["spec", None]
    assert read(store, "issues", 41, "state") == "CLOSED\n"
    assert comments_of(store, 41) == [ISSUE_CLOSED]
    assert files_under(orch(root, "handoff")) == [SPEC_FOLDER + "/02-spec.md",
                                            SPEC_FOLDER + "/spec-paused"]


ISSUE_CLOSED = ("This issue was closed by an orchestrator redo because the spec itself needed"
                " to change.\n\nA fresh issue will follow from orch-to-spec in this same flow.")


def test_an_issue_that_will_not_close_fails_new_issue_at_implement(root, seed, capsys):
    implementing(root, seed, issue=42)
    seed.fail("adapter_issue_close", GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec",
                                             "--new-issue")) == (
        1, "", "orch: gh could not close issue #42: HTTP 502: Bad Gateway\n")
    assert [state_of(root)[k] for k in ("phase", "issue")] == ["implement", 42]


def test_redo_spec_refuses_no_flow_then_an_unreadable_state(root, seed, capsys):
    git = checkout(root)
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "spec", "--bogus")) == (
        1, "", NO_FLOW)
    write(state_json(root), "not json")
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "spec")) == (1, "", UNREADABLE)


@pytest.mark.parametrize("phase", ["spec", "review", "done"])
def test_redo_spec_refuses_outside_the_implement_phase_before_its_usage(
        root, seed, store, capsys, phase):
    implementing(root, seed, phase=phase)
    spec_handoffs(root)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec", "--bogus")) == (
        1, "", "orch: flow is not at the implement phase - nothing to redo back from\n")
    assert untouched(root, store) == before


@pytest.mark.parametrize("args", [("--bogus",), ("",), ("--new-issue", "x"), ("x", "y")])
def test_redo_spec_takes_only_new_issue(root, seed, store, capsys, args):
    implementing(root, seed)
    spec_handoffs(root)
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec", *args)) == (
        1, "", "orch: usage: orch.sh redo spec [--new-issue]\n")
    assert untouched(root, store) == before


def test_redo_spec_refuses_while_a_ticket_worktree_is_left_then_with_no_issue(
        root, seed, store, capsys):
    implementing(root, seed, issue=None)
    spec_handoffs(root)
    git = checkout(root)
    git.seed("worktree_list", answer=[Worktree(str(root), BRANCH),
                                      Worktree(str(orch(root, "worktrees", "t4")), None)])
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "spec")) == (
        1, "", STRANDED.format(root=root))
    git.seed("worktree_list", answer=[Worktree(str(root), BRANCH)])
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "spec")) == (
        1, "", "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert untouched(root, store) == before


# --- redo spec retires the ticket breakdown (#334) ----------------------------

RETIRED = ("This ticket was retired: its spec, #50, changed and will be broken down into"
           " tickets again.")


def test_redo_spec_retires_a_sub_issue_breakdown_closing_each_ticket(root, seed, store, capsys):
    implementing(root, seed, issue=50)
    seed.body(50, "The spec of #50.")
    for n, state in ((900, "open"), (901, "closed"), (902, "open")):
        seed.issue(n, state)
        seed.sub_issue(50, n)
    handoffs(root, **{"02_spec__md": "# spec\n", "03_implement__md": "# implement\n"})

    assert orch_redo(root, seed, checkout(root), "spec") == 0

    assert read(store, "subs", 50) in (None, "")
    assert [read(store, "issues", n, "state") for n in (900, 901, 902)] == ["CLOSED\n"] * 3
    # A closed ticket's comment is posted from a file, so it ends in a newline.
    assert [comments_of(store, n) for n in (900, 901, 902)] == [
        [RETIRED], [RETIRED + "\n"], [RETIRED]]
    assert read(store, "issues", 900, "reason") == "not planned\n"
    assert [state_of(root)[k] for k in ("phase", "issue")] == ["spec", 50]


def test_redo_spec_cuts_a_collapsed_breakdown_s_ticket_section(root, seed, store, capsys):
    implementing(root, seed, issue=51)
    seed.body(51, "Intro\n\n## Ticket\n\n### What to build\nBuild.\n\n## After\nTail.\n")

    assert orch_redo(root, seed, checkout(root), "spec") == 0
    # The cut itself is pinned in test_ticket.py.
    assert fake(seed).issue_body(51).startswith("Intro\n\n## After\nTail.\n")


def test_a_failed_breakdown_retire_leaves_implement_and_a_rerun_finishes_it(
        root, seed, store, capsys):
    implementing(root, seed, issue=53)
    seed.issue(904, "open")
    seed.sub_issue(53, 904)
    handoffs(root, **{"02_spec__md": "# spec\n", "03_implement__md": "# implement\n",
                      "spec_paused": "53\n"})
    seed.fail("adapter_sub_issue_unlink", GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec")) == (
        1, "", "orch: gh could not unlink ticket #904 from #53: HTTP 502: Bad Gateway\n")
    assert state_of(root)["phase"] == "implement"
    assert files_under(orch(root, "handoff")) == [SPEC_FOLDER + "/02-spec.md",
                                            SPEC_FOLDER + "/03-implement.md", "spec-paused"]

    seed.unfail()
    assert orch_redo(root, seed, checkout(root), "spec") == 0
    assert read(store, "subs", 53) in (None, "")
    assert comments_of(store, 904) == [RETIRED.replace("#50", "#53")]
    assert state_of(root)["phase"] == "spec"


@pytest.mark.parametrize("operation", ["adapter_sub_issues", "adapter_issue_body_edit"])
def test_a_breakdown_retire_gh_cannot_do_leaves_the_phase_at_implement(
        root, seed, capsys, operation):
    implementing(root, seed, issue=54)
    seed.body(54, "Spec.\n\n## Ticket\nBuild.\n")
    seed.fail(operation, GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec"))[0] == 1
    assert state_of(root)["phase"] == "implement"


def test_new_issue_leaves_the_closed_issue_s_tickets_as_they_are(root, seed, store, capsys):
    implementing(root, seed, issue=55)
    seed.issue(905, "open")
    seed.sub_issue(55, 905)

    assert orch_redo(root, seed, checkout(root), "spec", "--new-issue") == 0
    assert (read(store, "subs", 55), read(store, "issues", 905, "state")) == ("905\n", "OPEN\n")


# --- redo spec retires the implement attempt (#1910) --------------------------


def test_redo_spec_retires_the_branch_and_closes_the_pr_as_redo_review_does(
        root, seed, store, capsys):
    implementing(root, seed, issue=ISSUE, branch=BRANCH, pr=PR, base_sha="deadbeefcafe")
    seed.pr(PR, "open", BRANCH, "main")
    git = checkout(root, BRANCH)

    assert orch_redo(root, seed, git, "spec") == 0

    assert (git.branch_exists(BRANCH), git.branch_exists(redone(1))) == (False, True)
    assert comments_of(store, PR, "prs") == [pr_closed_note(1)]
    state = state_of(root)
    assert [state[k] for k in ("branch", "pr", "base_sha", "redo_count")] == [
        None, None, None, 1]


def test_new_issue_retires_a_branch_with_no_pr_under_the_old_issue_s_name(
        root, seed, store, capsys):
    implementing(root, seed, issue=ISSUE, branch=BRANCH)
    git = checkout(root, BRANCH)

    assert orch_redo(root, seed, git, "spec", "--new-issue") == 0

    assert git.branch_exists(redone(1))
    assert read(store, "issues", ISSUE, "state") == "CLOSED\n"
    assert [state_of(root)[k] for k in ("issue", "redo_count")] == [None, 1]


def test_redo_spec_with_no_branch_retires_nothing(root, seed, store, capsys):
    implementing(root, seed, issue=8)
    before = snapshot(store)

    assert orch_redo(root, seed, checkout(root), "spec") == 0
    assert snapshot(store) == before
    assert [state_of(root)[k] for k in ("redo_count", "base_sha")] == [0, None]


def test_a_rejected_push_after_the_pr_close_is_finished_by_a_rerun_with_one_note(
        root, seed, store, capsys):
    implementing(root, seed, issue=ISSUE, branch=BRANCH, pr=PR)
    seed.pr(PR, "open", BRANCH, "main")
    git = checkout(root, BRANCH, pushes=False)
    git.seed("push_set_upstream", "origin",
             "refs/heads/%s:refs/heads/%s" % (redone(1), redone(1)),
             answer="! [remote rejected] (pre-receive hook declined)")
    git.seed("remote_delete", "origin", "refs/heads/" + BRANCH, answer=None)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "spec")) == (
        1, "", "orch: could not push %s to origin: ! [remote rejected] (pre-receive hook"
               " declined)\n" % redone(1))
    assert read(store, "prs", PR, "state") == "CLOSED\n"
    assert [state_of(root)[k] for k in ("branch", "redo_count")] == [BRANCH, 0]
    assert (git.branch_exists(BRANCH), git.branch_exists(redone(1))) == (True, False)

    git.seed("push_set_upstream", "origin",
             "refs/heads/%s:refs/heads/%s" % (redone(1), redone(1)), answer=None)
    assert orch_redo(root, seed, git, "spec") == 0
    assert git.branch_exists(redone(1)) and not git.branch_exists(redone(2))
    assert state_of(root)["redo_count"] == 1
    assert comments_of(store, PR, "prs") == [pr_closed_note(1)]


@pytest.mark.parametrize("argv", [("spec",), ("spec", "--new-issue")])
def test_a_rerun_after_a_death_past_the_attempt_retire_retires_nothing_twice(
        root, seed, store, capsys, argv):
    implementing(root, seed, issue=ISSUE, branch=BRANCH, pr=PR)
    seed.pr(PR, "open", BRANCH, "main")
    seed.issue(906, "open")
    seed.sub_issue(ISSUE, 906)
    git = checkout(root, BRANCH)
    seed.fail("adapter_issue_close", GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, *argv))[0] == 1
    assert read(store, "prs", PR, "state") == "CLOSED\n"
    seed.unfail()
    # A resumed rerun closes no PR: a failing close would kill it.
    seed.fail("adapter_pr_close", GH_502)

    assert orch_redo(root, seed, git, *argv) == 0
    assert state_of(root)["redo_count"] == 1
    assert not git.branch_exists(redone(2))
    assert comments_of(store, PR, "prs") == [pr_closed_note(1)]
    closed = 906 if argv == ("spec",) else ISSUE
    assert read(store, "issues", closed, "state") == "CLOSED\n"


# --- both redos per handoff mode (#1820) --------------------------------------
# The handoffs are files moved into a pre-redo folder (a plain session) or
# comments retired by a newer marked one (autopilot). A failure at the retire
# itself moves no state; a failure after it leaves the phase, and a rerun
# finishes retiring each handoff exactly once.

def handoff_comment(seed, issue, stem, text):
    """The live handoff <stem>, a marked comment holding <text>, on issue
    <issue>."""
    seed.comment(issue, "someone", "2030-01-01T00:00:00Z",
                 "<!-- orch:handoff %s -->\n%s" % (stem, text))


def retired_count(store, issue, stem):
    """How many retired comments issue <issue> carries for handoff <stem>."""
    marker = "<!-- orch:handoff %s retired -->" % stem
    return sum(body.startswith(marker) for body in comments_of(store, issue))


def test_redo_spec_in_an_autopilot_session_retires_each_handoff_comment_once(
        root, seed, store, capsys):
    implementing(root, seed, issue=60)
    handoff_comment(seed, 60, "02-spec", "spec text")
    handoff_comment(seed, 60, "03-implement", "implement text")
    state_before = state_json(root).read_text()
    seed.fail_after("adapter_issue_comment", 1, GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec", "--new-issue",
                                             env=AUTOPILOT)) == (
        1, "", "orch: could not retire the 03-implement handoff on issue #60: HTTP 502: Bad"
               " Gateway - comments posted: 02-spec; the recorded phase is unchanged, so a"
               " re-run retires the rest\n")
    assert state_json(root).read_text() == state_before
    seed.unfail()
    seed.fail("adapter_issue_close", GH_502)
    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec", "--new-issue",
                                             env=AUTOPILOT))[0] == 1
    assert state_of(root)["phase"] == "implement"
    seed.unfail()

    assert orch_redo(root, seed, checkout(root), "spec", "--new-issue", env=AUTOPILOT) == 0
    assert state_of(root)["phase"] == "spec"
    assert [retired_count(store, 60, stem) for stem in ("02-spec", "03-implement")] == [1, 1]
    assert not orch(root, "handoff").exists()


def test_redo_spec_in_a_plain_session_refuses_a_taken_folder_then_a_rerun_finishes(
        root, seed, store, capsys):
    implementing(root, seed, issue=60)
    handoffs(root, **{"02_spec__md": "spec text\n", "03_implement__md": "implement text\n"})
    write(orch(root, "handoff", SPEC_FOLDER, "02-spec.md"), "# older\n")
    before = untouched(root, store)

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec",
                                             "--new-issue")) == (
        1, "", "orch: %s already holds a retired handoff - refusing to overwrite it\n"
               % orch(root, "handoff", SPEC_FOLDER))
    assert untouched(root, store) == before
    orch(root, "handoff", SPEC_FOLDER, "02-spec.md").unlink()
    seed.fail("adapter_issue_close", GH_502)
    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec",
                                             "--new-issue"))[0] == 1
    assert state_of(root)["phase"] == "implement"
    seed.unfail()

    assert orch_redo(root, seed, checkout(root), "spec", "--new-issue") == 0
    assert state_of(root)["phase"] == "spec"
    assert files_under(orch(root, "handoff")) == [SPEC_FOLDER + "/02-spec.md",
                                            SPEC_FOLDER + "/03-implement.md"]


def test_redo_review_in_an_autopilot_session_retires_the_implement_comment_once(
        root, seed, store, capsys):
    reviewing(root, seed, iteration=1, budget=1)
    handoff_comment(seed, ISSUE, "03-implement", "implement text")
    record(root, 1)
    git = checkout(root, BRANCH)
    seed.fail("adapter_issue_comment", GH_502)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review", env=AUTOPILOT))[0] == 1
    assert [state_of(root)[k] for k in ("phase", "branch", "redo_count")] == [
        "review", BRANCH, 0]
    seed.unfail()
    seed.fail("adapter_pr_close", GH_502)
    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review", env=AUTOPILOT))[0] == 1
    assert state_of(root)["phase"] == "review"
    seed.unfail()

    assert orch_redo(root, seed, git, "review", env=AUTOPILOT) == 0
    assert state_of(root)["phase"] == "implement"
    assert retired_count(store, ISSUE, "03-implement") == 1
    assert orch(root, "review", "pre-redo-1", "iteration-01.md").exists()


# --- the one closing state write ----------------------------------------------
# Each redo moves its phase and clears its attempt keys in one write, taken
# last: a death at it leaves the flow at its old phase with the keys its
# guards need.

@contextmanager
def state_unwritable(root):
    """The state file's directory read-only for the block: no state write
    lands, and nothing else is changed."""
    directory = str(orch(root))
    os.chmod(directory, 0o555)
    try:
        yield
    finally:
        os.chmod(directory, 0o755)


def unrecorded(root, *keys):
    """The death of a closing write recording phase, then <keys>, then the
    trio."""
    return ("orch: could not record %s in %s - the flow is unchanged\n"
            % (", ".join(("phase",) + keys + ("branch", "pr", "base_sha")), state_json(root)))


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_new_issue_whose_closing_write_fails_keeps_the_issue_and_a_rerun_finishes(
        root, seed, store, capsys):
    implementing(root, seed, issue=70)
    handoffs(root, **{"02_spec__md": "# spec\n"})
    state_before = state_json(root).read_text()

    with state_unwritable(root):
        assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec",
                                                 "--new-issue")) == (
            1, "", unrecorded(root, "issue"))
    assert read(store, "issues", 70, "state") == "CLOSED\n"
    assert state_json(root).read_text() == state_before

    assert orch_redo(root, seed, checkout(root), "spec", "--new-issue") == 0
    assert [state_of(root)[k] for k in ("phase", "issue")] == ["spec", None]
    assert comments_of(store, 70) == [ISSUE_CLOSED]


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_resumed_redo_spec_whose_closing_write_fails_changes_no_state(root, seed, capsys):
    implementing(root, seed, issue=71, branch=redone(1).replace("21", "71"), redo_count=1,
                 pr=90, base_sha="deadbeefcafe")
    state_before = state_json(root).read_text()

    with state_unwritable(root):
        assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec")) == (
            1, "", unrecorded(root))
    assert state_json(root).read_text() == state_before


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_a_resumed_redo_review_whose_closing_write_fails_changes_no_state(root, seed, capsys):
    reviewing(root, seed, branch=redone(1), redo_count=1)
    record(root, 5)
    state_before = state_json(root).read_text()

    with state_unwritable(root):
        assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, redone(1)),
                                                 "review")) == (
            1, "", unrecorded(root, "iteration"))
    assert state_json(root).read_text() == state_before


# --- one state read before the first write ------------------------------------


def test_redo_review_opens_the_state_file_once_before_its_last_refusal(
        root, seed, capsys, monkeypatch):
    reviewing(root, seed, iteration=1, budget=1, pr=None)
    record(root, 1)
    opens = Opens(monkeypatch, state_json(root))

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root, BRANCH), "review"))[2] \
        == "orch: no PR recorded in state - the implement phase opens it\n"
    assert opens.count == 1


def test_redo_spec_opens_the_state_file_once_before_its_last_refusal(
        root, seed, capsys, monkeypatch):
    implementing(root, seed, issue=None)
    opens = Opens(monkeypatch, state_json(root))

    assert died_of(capsys, lambda: orch_redo(root, seed, checkout(root), "spec"))[2] == (
        "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert opens.count == 1


# --- a resumed rerun after a death at each step -------------------------------
# redo review's steps in order - the handoff retire, the PR close, the branch
# retire's push, the ticket reopen, the review records' move - each made to
# die once; the rerun then finishes the redo as a clean one would.

def _taken_review_folder(root, seed, git):
    write(orch(root, "review", "pre-redo-1", "iteration-05.md"), "taken\n")
    return lambda: orch(root, "review", "pre-redo-1", "iteration-05.md").unlink()


def _failing(operation):
    def make(root, seed, git):
        seed.fail(operation, GH_502)
        return seed.unfail
    return make


def _rejected_push(root, seed, git):
    refspec = ("origin", "refs/heads/%s:refs/heads/%s" % (redone(1), redone(1)))
    git.seed("push_set_upstream", *refspec, answer="rejected")
    return lambda: git.seed("push_set_upstream", *refspec, answer=None)


@pytest.mark.parametrize("death", [
    _failing("adapter_pr_close"), _rejected_push, _failing("adapter_issue_reopen"),
    _taken_review_folder,
], ids=["pr-close", "branch-push", "ticket-reopen", "review-retire"])
def test_redo_review_resumed_after_a_death_at_any_step_finishes_once(
        root, seed, store, capsys, death):
    reviewing(root, seed)
    record(root, 5)
    handoffs(root, **{"03_implement__md": "# implement\n"})
    seed.issue(40, "closed")
    seed.sub_issue(ISSUE, 40)
    git = checkout(root, BRANCH)
    revive = death(root, seed, git)

    assert died_of(capsys, lambda: orch_redo(root, seed, git, "review"))[0] == 1
    assert state_of(root)["phase"] == "review"
    revive()

    assert orch_redo(root, seed, git, "review") == 0
    assert capsys.readouterr() == ("1\n", "")
    state = state_of(root)
    assert [state[k] for k in ("phase", "iteration", "redo_count", "branch", "pr")] == [
        "implement", 0, 1, None, None]
    assert (git.branch_exists(redone(1)), git.branch_exists(redone(2))) == (True, False)
    assert comments_of(store, PR, "prs") == [pr_closed_note(1)]
    assert read(store, "issues", 40, "state") == "OPEN\n"
    assert files_under(orch(root, "handoff")) == ["pre-redo-1/03-implement.md"]
    assert files_under(orch(root, "review")) == ["pre-redo-1/iteration-05.md"]
