"""The phase noun, run in-process in a FakeGit checkout under tmp_path
against the gh fake on a tmp_path store, with tmp_path flow state and
handoffs. `phase advance`: every refusal in its guard order, each per-phase
field check, the open-tickets refusal, a clean advance per phase, and the
autopilot advance - the label moved, the phase recorded, the claim released
and the note printed. `phase boundary`: the block in each host's own words.
And finish, the finished phase's close review ready calls in process: in a
plain session the next phase recorded and nothing else, in an autopilot one
the issue checked, then the label moved, the phase recorded and the claim
released."""
from __future__ import annotations

import json
import os

import pytest

from conftest import CLAUDE, died_of, fake, flow_state, hold_flow, labels_of, snapshot, state_json
from orch import phase
from orch.git import FakeGit
from orch.handoff import PHASE_TABLE

AUTOPILOT = {"ORCH_AUTOPILOT": "1"}
# A clock reading 2026-01-02T03:04:05Z.
CLOCK = 1767323045.0


def finish(root, seed, next_phase, reason, issue, env=None):
    """finish(<next_phase>, <reason>, <issue>) on the state file of the
    checkout at <root> under <env> (a plain session's when None), on <seed>'s
    store."""
    return phase.finish(next_phase, reason, issue, str(state_json(root)), lambda: fake(seed),
                        {} if env is None else env, lambda: CLOCK)


def state_of(root, key="phase"):
    """The value <root>'s state.json records for <key>."""
    return json.loads(state_json(root).read_text())[key]


@pytest.fixture
def reviewing(root, seed):
    """A flow at phase review on issue #7, which carries orch:review and
    orch:running and whose claim is held."""
    flow_state(root, "review", 7)
    seed.issue(7, "open", "ready-for-agent", "orch:review", "orch:running")
    seed.claim(7)


def test_a_plain_session_records_the_next_phase_and_touches_nothing_on_github(
        root, seed, store, capsys, reviewing):
    before = snapshot(store)

    assert finish(root, seed, "done", "marked PR #9 ready", "7") is None
    assert capsys.readouterr() == ("", "")
    assert state_of(root) == "done"
    assert snapshot(store) == before


def test_a_plain_session_s_failed_phase_write_dies_leaving_the_flow_unchanged(
        root, seed, capsys, reviewing):
    state_json(root).write_text("not json")

    assert died_of(capsys, lambda: finish(root, seed, "done", "r", "7")) == (
        1, "", "orch: could not record phase in %s - the flow is unchanged\n" % state_json(root))
    assert state_json(root).read_text() == "not json"


def test_an_autopilot_session_moves_the_label_records_the_phase_and_releases_the_claim(
        root, seed, store, capsys, reviewing):
    assert finish(root, seed, "done", "marked PR #9 ready", "7", env=AUTOPILOT) is None
    assert capsys.readouterr() == ("", "")
    assert labels_of(store, 7) == ["ready-for-agent", "orch:done"]
    assert state_of(root) == "done"
    assert seed.claim_held(7) is False


def test_an_autopilot_session_s_failure_dies_with_the_reason_seeding_the_writes_that_landed(
        root, seed, store, capsys, reviewing):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert died_of(capsys, lambda: finish(
        root, seed, "done", "marked PR #9 ready", "7", env=AUTOPILOT)) == (
        1, "", "orch: could not delete the claim ref on issue #7: HTTP 500 - writes that landed:"
               " marked PR #9 ready, moved the phase label to orch:done, recorded phase done,"
               " removed orch:running; the claim stays held\n")
    assert seed.claim_held(7) is True


def test_an_autopilot_session_with_no_issue_dies_before_any_write(
        root, seed, store, capsys, reviewing):
    before = snapshot(store)

    assert died_of(capsys, lambda: finish(root, seed, "done", "r", "", env=AUTOPILOT)) == (
        1, "", "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert state_of(root) == "review"
    assert snapshot(store) == before


# --- the noun: phase advance and phase boundary --------------------------

CLAUDE_AUTOPILOT = {"ORCHESTRATOR_HOST": "claude", "ORCH_AUTOPILOT": "1"}


def orch_phase(root, seed, *argv, env=None):
    """`orch.sh phase <argv>` in-process in the checkout at <root>, on
    <seed>'s store, under <env> (Claude Code's plain session when None): its
    exit code."""
    return phase.run(list(argv), gh=fake(seed), git=FakeGit(toplevel=str(root)),
                     env=CLAUDE if env is None else env, clock=lambda: CLOCK)


def flow(root, phase_name, issue=7, **state):
    """<root>'s state.json: a flow at <phase_name> on <issue>, started as
    init starts one - host fallbacks required - with <state>'s further
    keys."""
    return hold_flow(root, slug="advancing", phase=phase_name, issue=issue,
                     host_fallbacks=True, **state)


def handoff(root, name):
    """The path of the handoff file <name> in <root>'s handoff directory."""
    return root / ".orchestrator" / "handoff" / name


def complete(path):
    """Writes a valid handoff to <path>: every section its phase table row
    requires, then `## Host fallbacks`, each with a placeholder body. Its
    path."""
    sections = next(row[3] for row in PHASE_TABLE if row[1] == path.name)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join("## %s\nPlaceholder for %s.\n\n" % (s, s)
                            for s in sections + ("Host fallbacks",)))
    return path


@pytest.mark.parametrize("phase_name, writer, name", [
    ("spec", "plan", "01-plan.md"),
    ("review", "implement", "03-implement.md"),
])
def test_boundary_names_the_finished_phase_and_its_handoff_with_the_claude_code_next_line(
        root, seed, capsys, phase_name, writer, name):
    flow(root, phase_name)

    assert orch_phase(root, seed, "boundary") == 0
    assert capsys.readouterr() == (
        "Phase %s complete. Handoff written to %s.\n\n  Next: /clear, then /orchestrator:next\n"
        % (writer, handoff(root, name)), "")


@pytest.mark.parametrize("host, next_line", [
    ("junie", "/new, then ask for the next phase with /orch-flow"),
    ("antigravity", "/clear, then ask for the next phase with /orch-flow"),
    ("other", "a fresh session, then /orchestrator:next (or orch-flow's Next phase section)"),
])
def test_boundary_names_the_next_session_in_each_host_s_own_words(
        root, seed, capsys, host, next_line):
    flow(root, "review")

    assert orch_phase(root, seed, "boundary", env={"ORCHESTRATOR_HOST": host}) == 0
    assert capsys.readouterr() == (
        "Phase implement complete. Handoff written to %s.\n\n  Next: %s\n"
        % (handoff(root, "03-implement.md"), next_line), "")


@pytest.mark.parametrize("phase_name", ["done", "bogus"])
def test_boundary_refuses_a_phase_with_no_finished_phase_before_it(
        root, seed, capsys, phase_name):
    flow(root, phase_name)

    assert died_of(capsys, lambda: orch_phase(root, seed, "boundary")) == (
        1, "", "orch: no phase boundary at phase: %s - the flow is not between phases\n"
               % phase_name)


@pytest.mark.parametrize("op", ["advance", "boundary"])
def test_each_op_takes_no_arguments(root, seed, capsys, op):
    flow(root, "spec")

    assert died_of(capsys, lambda: orch_phase(root, seed, op, "extra")) == (
        1, "", "orch: usage: orch.sh phase %s\n" % op)


@pytest.mark.parametrize("argv, named", [(("bogus",), "bogus"), ((), "<none>")])
def test_an_unknown_op_is_refused_naming_the_ops_it_wants(root, seed, capsys, argv, named):
    assert died_of(capsys, lambda: orch_phase(root, seed, *argv)) == (
        1, "", "orch: unknown phase op: %s (want advance|boundary)\n" % named)


@pytest.mark.parametrize("op", ["advance", "boundary"])
def test_each_op_refuses_with_no_flow_or_an_unreadable_state(root, seed, capsys, op):
    assert died_of(capsys, lambda: orch_phase(root, seed, op)) == (
        1, "", "orch: no active flow (.orchestrator/state.json not found)."
               " Run /orchestrator:start first.\n")
    flow(root, "spec")
    state_json(root).write_text('{"phase": ')

    assert died_of(capsys, lambda: orch_phase(root, seed, op)) == (
        1, "", "orch: state.json cannot be read - run orch.sh doctor --flow\n")


def test_advance_leaves_spec_for_implement_on_a_valid_spec_handoff(root, seed, capsys):
    flow(root, "spec")
    complete(handoff(root, "02-spec.md"))

    assert orch_phase(root, seed, "advance") == 0
    assert capsys.readouterr() == (
        "Phase spec complete. Handoff written to %s.\n\n  Next: /clear, then /orchestrator:next\n"
        % handoff(root, "02-spec.md"), "")
    assert state_of(root) == "implement"


def test_advance_refuses_at_spec_with_no_spec_handoff_leaving_the_phase(root, seed, capsys):
    flow(root, "spec")

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: handoff not found: %s - write it before leaving the spec phase\n"
               % handoff(root, "02-spec.md"))
    assert state_of(root) == "spec"


def test_advance_refuses_an_invalid_handoff_printing_its_fail_lines(root, seed, capsys):
    flow(root, "spec")
    path = handoff(root, "02-spec.md")
    path.parent.mkdir(parents=True)
    path.write_text("## Spec issue\n\n\n## Host fallbacks\nNone.\n")

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "FAIL  empty section: ## Spec issue\n",
        "orch: %s is not valid - fix it, then run phase advance again; the flow stays at spec\n"
        % path)
    assert state_of(root) == "spec"
    path.write_text("## Host fallbacks\nNone.\n")

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance"))[1] == \
        "FAIL  missing section: ## Spec issue\n"
    assert state_of(root) == "spec"


@pytest.mark.parametrize("seams, changelog", [("", "Not reviewed."), ("At handoff validate.", "")],
                         ids=["empty-seams", "empty-changelog"])
def test_advance_passes_a_spec_handoff_still_carrying_the_sections_before_1601(
        root, seed, capsys, seams, changelog):
    """Seams and a Spec review changelog are no longer required, so a spec
    handoff written before #1601 advances, filled or empty."""
    flow(root, "spec")
    path = handoff(root, "02-spec.md")
    path.parent.mkdir(parents=True)
    path.write_text("## Spec issue\n#7.\n\n## Seams\n%s\n\n## Spec review changelog\n%s\n\n"
                    "## Host fallbacks\nNone.\n" % (seams, changelog))

    assert orch_phase(root, seed, "advance") == 0
    assert state_of(root) == "implement"


def test_advance_refuses_to_leave_spec_with_no_issue_recorded(root, seed, capsys):
    flow(root, "spec", issue=None)
    complete(handoff(root, "02-spec.md"))

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: no issue recorded in state - the spec phase must publish one first\n")
    assert state_of(root) == "spec"


@pytest.fixture
def implementing(root, seed):
    """A flow at implement on issue #7, its branch, base SHA and PR recorded,
    the implement handoff valid; #7 open with no sub-issue."""
    flow(root, "implement", branch="orch/7-advancing", base_sha="abc1234", pr=3)
    complete(handoff(root, "03-implement.md"))
    seed.issue(7, "open")


def test_advance_refuses_at_implement_with_no_implement_handoff(root, seed, capsys):
    flow(root, "implement", branch="orch/7-advancing", base_sha="abc1234", pr=3)

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: handoff not found: %s - write it before leaving the implement phase\n"
               % handoff(root, "03-implement.md"))
    assert state_of(root) == "implement"


@pytest.mark.parametrize("key, message", [
    ("branch", "no branch recorded in state"),
    ("base_sha", "no base SHA recorded in state - branch create records it"),
    ("pr", "no PR recorded in state - the implement phase opens it"),
    ("issue", "no issue recorded in state - the spec phase must publish one first"),
])
def test_advance_refuses_to_leave_implement_without_each_field_review_needs(
        root, seed, store, capsys, implementing, key, message):
    hold_flow(root, **dict(json.loads(state_json(root).read_text()), **{key: None}))
    before = snapshot(store)

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: %s\n" % message)
    assert state_of(root) == "implement"
    assert snapshot(store) == before


def test_advance_checks_the_fields_in_order_branch_first(root, seed, capsys, implementing):
    flow(root, "implement", issue=None)

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance"))[2] == \
        "orch: no branch recorded in state\n"


def test_advance_refuses_to_leave_implement_while_a_ticket_is_open(
        root, seed, capsys, implementing):
    """#1733: blocked tickets count too; each is named, in order, until it
    is closed."""
    for n in (701, 702):
        seed.issue(n, "open")
        seed.sub_issue(7, n)
    seed.blocked_by(702, 701)

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: #7 still has open tickets: #701 #702 - run the driver loop"
               " (orch.sh ticket next 7) or close them, then run phase advance again\n")
    assert state_of(root) == "implement"
    seed.issue(701, "closed")

    assert "open tickets: #702 - run" in died_of(capsys, lambda: orch_phase(root, seed, "advance"))[2]


def test_advance_refuses_to_leave_implement_when_github_cannot_list_the_tickets(
        root, seed, capsys, implementing):
    seed.fail("adapter_sub_issues", "HTTP 502")

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: gh could not list sub-issues of #7: HTTP 502\n")
    assert state_of(root) == "implement"


@pytest.mark.parametrize("body", ["## Ticket\n\nx\n", "Just a spec.\n"],
                         ids=["collapsed", "no-breakdown"])
def test_advance_leaves_implement_for_review_with_no_sub_issue(
        root, seed, capsys, implementing, body):
    seed.body(7, body)

    assert orch_phase(root, seed, "advance") == 0
    assert capsys.readouterr() == (
        "Phase implement complete. Handoff written to %s.\n\n"
        "  Next: /clear, then /orchestrator:next\n" % handoff(root, "03-implement.md"), "")
    assert state_of(root) == "review"


def test_advance_leaves_implement_once_every_ticket_is_closed(root, seed, capsys, implementing):
    seed.issue(701, "closed")
    seed.sub_issue(7, 701)

    assert orch_phase(root, seed, "advance") == 0
    assert state_of(root) == "review"


@pytest.mark.parametrize("phase_name, message", [
    ("review", "the review phase ends through review ready, once the PR is ready"
               " - phase advance does not leave it"),
    ("done", "the flow is done - there is no phase to advance to"),
    ("bogus", "not a flow phase: 'bogus' - run orch.sh doctor --flow"),
    ("", "not a flow phase: '' - run orch.sh doctor --flow"),
])
def test_advance_refuses_a_phase_it_does_not_leave_before_reading_any_handoff(
        root, seed, capsys, phase_name, message):
    flow(root, phase_name or None)

    assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
        1, "", "orch: %s\n" % message)
    assert state_of(root) == (phase_name or None)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_advance_with_a_failed_phase_write_prints_no_boundary_then_re_runs(root, seed, capsys):
    """#1931: the phase as it was and a non-zero exit; the command re-run
    finishes the move."""
    flow(root, "spec")
    complete(handoff(root, "02-spec.md"))
    directory = state_json(root).parent
    os.chmod(directory, 0o555)
    try:
        assert died_of(capsys, lambda: orch_phase(root, seed, "advance")) == (
            1, "", "orch: could not record phase in %s - the flow is unchanged\n"
                   % state_json(root))
    finally:
        os.chmod(directory, 0o755)
    assert state_of(root) == "spec"

    assert orch_phase(root, seed, "advance") == 0
    assert state_of(root) == "implement"


# --- phase advance in an autopilot flow (#1457) ----------------------------


def spec_comment(seed, body):
    """The 02-spec handoff comment on issue #7, its marker then <body>."""
    seed.comment(7, "someone", "2026-01-01T00:00:00Z", "<!-- orch:handoff 02-spec -->\n" + body)


@pytest.fixture
def autopilot_spec(root, seed):
    """An autopilot flow at spec on issue #7, which carries its phase label
    and orch:running and whose claim is held."""
    flow(root, "spec")
    seed.issue(7, "open", "ready-for-agent", "orch:spec", "orch:running")
    seed.claim(7)


@pytest.fixture
def posted_spec(root, seed, autopilot_spec):
    """autopilot_spec, with a valid 02-spec handoff posted on issue #7."""
    spec_comment(seed, complete(handoff(root, "02-spec.md")).read_text())


def autopilot_advance(root, seed):
    return orch_phase(root, seed, "advance", env=CLAUDE_AUTOPILOT)


def test_autopilot_advance_moves_the_label_records_the_phase_releases_the_claim_and_notes(
        root, seed, store, capsys, posted_spec):
    assert autopilot_advance(root, seed) == 0
    assert capsys.readouterr() == (
        "Phase spec complete. Handoff posted on issue #7; the watcher starts the implement"
        " phase.\n", "")
    assert labels_of(store, 7) == ["ready-for-agent", "orch:implement"]
    assert state_of(root) == "implement"
    assert seed.claim_held(7) is False


def assert_unmoved(root, seed, store):
    assert state_of(root) == "spec"
    assert labels_of(store, 7) == ["ready-for-agent", "orch:spec", "orch:running"]
    assert seed.claim_held(7) is True


def test_autopilot_advance_with_no_posted_handoff_dies_naming_the_comment(
        root, seed, store, capsys, autopilot_spec):
    assert died_of(capsys, lambda: autopilot_advance(root, seed)) == (
        1, "", "orch: issue #7 has no 02-spec handoff comment - post it with handoff post"
               " before leaving the spec phase\n")
    assert_unmoved(root, seed, store)


def test_autopilot_advance_with_an_invalid_posted_handoff_dies_naming_the_comment(
        root, seed, store, capsys, autopilot_spec):
    spec_comment(seed, "## Decisions\n")

    assert died_of(capsys, lambda: autopilot_advance(root, seed))[2] == (
        "orch: the 02-spec comment on issue #7 is not valid - post a fixed one, then run phase"
        " advance again; the flow stays at spec\n")
    assert_unmoved(root, seed, store)


def test_autopilot_advance_with_a_failed_comments_read_dies_with_gh_s_reason(
        root, seed, store, capsys, posted_spec):
    """#2538: a failed read is a read failure, never a missing handoff."""
    seed.fail("adapter_issue_comments", "HTTP 503 read")

    assert died_of(capsys, lambda: autopilot_advance(root, seed)) == (
        1, "", "orch: gh could not read the comments of issue #7: HTTP 503 read\n")
    assert_unmoved(root, seed, store)


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_autopilot_advance_with_an_unwritable_scratch_copy_dies_saying_so(
        root, seed, store, capsys, posted_spec):
    scratch = root / ".orchestrator" / "scratch"
    scratch.mkdir()
    os.chmod(str(scratch), 0o555)
    try:
        assert died_of(capsys, lambda: autopilot_advance(root, seed)) == (
            1, "", "orch: could not write %s\n" % (scratch / "02-spec.md"))
    finally:
        os.chmod(str(scratch), 0o755)
    assert_unmoved(root, seed, store)


def test_autopilot_advance_failing_partway_dies_with_the_writes_that_landed(
        root, seed, capsys, posted_spec):
    seed.fail("adapter_claim_delete", "HTTP 500")

    assert died_of(capsys, lambda: autopilot_advance(root, seed)) == (
        1, "", "orch: could not delete the claim ref on issue #7: HTTP 500 - writes that landed:"
               " moved the phase label to orch:implement, recorded phase implement, removed"
               " orch:running; the claim stays held\n")
    assert seed.claim_held(7) is True


def test_a_plain_advance_touches_no_label_and_no_claim(root, seed, store, capsys, autopilot_spec):
    complete(handoff(root, "02-spec.md"))
    before = snapshot(store)

    assert orch_phase(root, seed, "advance") == 0
    assert state_of(root) == "implement"
    assert snapshot(store) == before
