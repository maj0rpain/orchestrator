"""`orch.sh state get [<key>]` and `orch.sh state set <key> <value>`, called
in-process through the state module's run in a FakeGit checkout under
tmp_path with a tmp_path state.json - the cases of the deleted bash state
sections, each message and exit code as the bash state noun had it: get with
and without a key, each key's default, the missing and unreadable state file;
set on each settable key with its coercion, the refusal of an owned and an
unknown key, the usage line, a failed write and an unreadable file; the
unknown-op refusal. On an unreadable state.json `state get <key>` and `state
set` die with STATE_UNREADABLE_MSG, where bash passed jq's parse error
through: the conversion's one departure from parity. `state get` with no key
on one that cannot be opened prints cat's error, as bash did."""
from __future__ import annotations

import json
import os

import pytest

from conftest import CLAUDE, hold_flow, outcome, state_json, write
from orch import state
from orch.git import FakeGit

# A clock reading 2026-01-02T03:04:05Z, the updated stamp a set writes.
CLOCK = 1767323045.0
STAMP = "2026-01-02T03:04:05Z"

NO_FLOW = ("orch: no active flow (.orchestrator/state.json not found). Run /orchestrator:start"
           " first.\n")
UNREADABLE = "orch: state.json cannot be read - run orch.sh doctor --flow\n"


def orch_state(capsys, root, *argv):
    """`orch.sh state <argv>` in-process in the checkout at <root>, in Claude
    Code's plain session: (exit code, stdout, stderr)."""
    return outcome(capsys, lambda: state.run(
        list(argv), git=FakeGit(toplevel=str(root)), env=CLAUDE, clock=lambda: CLOCK))


def a_flow(root, **state):
    """<root>'s state.json, a flow named state at review with <state> over
    it: its path."""
    return hold_flow(root, **dict({"slug": "state", "phase": "review", "issue": None}, **state))


def state_of(root):
    """<root>'s state.json, read."""
    return json.loads(state_json(root).read_text())


# --- state get -------------------------------------------------------------------------


def test_get_prints_a_key_s_value(root, capsys):
    a_flow(root, budget="unbounded")

    assert orch_state(capsys, root, "get", "budget") == (0, "unbounded\n", "")


def test_get_prints_a_number_and_a_boolean_as_json_prints_them(root, capsys):
    a_flow(root, issue=42, flake_rerun_used=True)

    assert [orch_state(capsys, root, "get", key)[1] for key in ("issue", "flake_rerun_used")] \
        == ["42\n", "true\n"]


def test_get_reads_a_stored_false_back_as_false_not_the_key_s_default(root, capsys):
    a_flow(root, budget=False)

    assert orch_state(capsys, root, "get", "budget") == (0, "false\n", "")


@pytest.mark.parametrize("key, default", [
    ("iteration", "0"), ("redo_count", "0"), ("host_fallbacks", "false"),
    ("flake_rerun_used", "false"), ("budget", ""), ("slug", ""), ("phase", ""), ("issue", ""),
    ("base", ""), ("branch", ""), ("pr", ""), ("base_sha", ""), ("created", ""),
    ("updated", "")])
def test_an_absent_key_reads_as_its_default(root, capsys, key, default):
    """A state file written by an older flow lacks keys a fresh one seeds;
    each key still reads back as what an absent value has always meant."""
    hold_flow(root, other=1)

    assert orch_state(capsys, root, "get", key) == (0, default + "\n", "")


def test_get_of_a_key_outside_the_table_is_refused_as_an_unknown_state_key(root, capsys):
    a_flow(root)

    assert orch_state(capsys, root, "get", "nonsense") == (
        1, "", "orch: unknown state key: nonsense\n")


@pytest.mark.parametrize("argv", [("get",), ()], ids=["get", "bare"])
def test_get_with_no_key_prints_the_whole_file_as_it_stands(root, capsys, argv):
    write(root, ".orchestrator/state.json", raw='{"slug": "s",\n  "phase":"spec"}\n')

    assert orch_state(capsys, root, *argv) == (0, '{"slug": "s",\n  "phase":"spec"}\n', "")


def test_get_with_no_key_prints_an_unreadable_file_too(root, capsys):
    write(root, ".orchestrator/state.json", raw="not json\n")

    assert orch_state(capsys, root, "get") == (0, "not json\n", "")


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads any file")
def test_get_with_no_key_of_a_file_that_cannot_be_opened_prints_cat_s_error(root, capsys):
    """Bash's `cat "$STATE"`: cat's own message and its status, no `orch: `
    line."""
    a_flow(root)
    os.chmod(str(state_json(root)), 0)
    try:
        assert orch_state(capsys, root, "get") == (
            1, "", "cat: %s: Permission denied\n" % state_json(root))
    finally:
        os.chmod(str(state_json(root)), 0o644)


@pytest.mark.parametrize("argv", [("get", "phase"), ("get",), ("set", "budget", "3"), ("set",)],
                         ids=["get-key", "get", "set", "set-usage"])
def test_a_missing_state_file_is_refused_as_no_active_flow(root, capsys, argv):
    assert orch_state(capsys, root, *argv) == (1, "", NO_FLOW)


def test_get_of_a_key_on_an_unreadable_file_dies_as_unreadable(root, capsys):
    """The departure from parity: bash passed jq's parse error and status
    through."""
    write(root, ".orchestrator/state.json", raw="not json\n")

    assert orch_state(capsys, root, "get", "budget") == (1, "", UNREADABLE)


def test_get_of_an_unknown_key_on_an_unreadable_file_still_dies_as_an_unknown_state_key(
        root, capsys):
    write(root, ".orchestrator/state.json", raw="not json\n")

    assert orch_state(capsys, root, "get", "nonsense") == (
        1, "", "orch: unknown state key: nonsense\n")


# --- state set -------------------------------------------------------------------------


@pytest.mark.parametrize("key, value, stored", [
    ("budget", "3", 3), ("issue", "42", 42), ("issue", "null", None), ("budget", "null", None),
    ("flake_rerun_used", "true", True), ("flake_rerun_used", "false", False),
    ("budget", "unbounded", "unbounded"), ("budget", "false", False),
    ("budget", "12\n", "12\n")],
    ids=["number", "issue-number", "issue-null", "null", "true", "false", "string",
         "budget-false", "digits-and-newline"])
def test_set_stores_a_value_with_the_bash_coercion(root, capsys, key, value, stored):
    """null, true and false as JSON literals, all digits a number, anything
    else a string - digits with a trailing newline included (#711)."""
    a_flow(root)

    assert orch_state(capsys, root, "set", key, value) == (0, "", "")
    assert state_of(root)[key] == stored


def test_set_stamps_updated_and_leaves_the_rest_of_state_json_intact(root, capsys):
    a_flow(root, updated="2020-01-01T00:00:00Z", iteration=2)

    orch_state(capsys, root, "set", "budget", "3")

    assert state_of(root) == {"slug": "state", "phase": "review", "issue": None,
                              "updated": STAMP, "iteration": 2, "budget": 3}


def test_set_refuses_phase_naming_phase_advance_as_its_owner_in_full(root, capsys):
    a_flow(root)
    before = state_json(root).read_text()

    assert orch_state(capsys, root, "set", "phase", "review") == (1, "", (
        "orch: state set refuses phase: use phase advance (review ready and redo also move it)"
        "\n"))
    assert state_json(root).read_text() == before


# Each refusal is pinned as its whole line, so a change to any wording fails.
@pytest.mark.parametrize("key, owner", [
    ("branch", "branch create records it"), ("base_sha", "branch create records it"),
    ("pr", "pr open records it"), ("iteration", "review begin counts it"),
    ("redo_count", "a redo that retires a branch counts it"), ("slug", "init seeds it"),
    ("base", "init seeds it"), ("created", "init seeds it"),
    ("host_fallbacks", "init seeds it"), ("updated", "every state change stamps it"),
    ("bogus", "settable keys are issue, budget, flake_rerun_used")])
def test_set_refuses_a_key_naming_what_owns_it(root, capsys, key, owner):
    a_flow(root)
    before = state_json(root).read_text()

    assert orch_state(capsys, root, "set", key, "1") == (
        1, "", "orch: state set refuses %s: %s\n" % (key, owner))
    assert state_json(root).read_text() == before


@pytest.mark.parametrize("argv", [("budget",), ("budget", "3", "4"), ()],
                         ids=["one", "three", "none"])
def test_set_without_exactly_a_key_and_a_value_prints_its_usage(root, capsys, argv):
    a_flow(root)

    assert orch_state(capsys, root, "set", *argv) == (
        1, "", "orch: usage: orch.sh state set <key> <value>\n")


def test_set_on_an_unreadable_file_dies_as_unreadable_leaving_it_as_it_was(root, capsys):
    """A write that cannot apply leaves the file byte-identical, with
    nothing new beside it; the message is the departure from parity, where
    bash passed jq's parse error through."""
    write(root, ".orchestrator/state.json", raw="not json\n")

    assert orch_state(capsys, root, "set", "budget", "3") == (1, "", UNREADABLE)
    assert state_json(root).read_text() == "not json\n"
    assert os.listdir(str(state_json(root).parent)) == ["state.json"]


def test_set_of_an_unknown_key_on_an_unreadable_file_is_still_refused_as_unknown(root, capsys):
    write(root, ".orchestrator/state.json", raw="not json\n")

    assert orch_state(capsys, root, "set", "bogus", "1") == (
        1, "", "orch: state set refuses bogus: settable keys are issue, budget,"
        " flake_rerun_used\n")


@pytest.mark.skipif(os.geteuid() == 0, reason="root writes into a read-only directory")
def test_set_with_a_failed_write_dies_naming_the_key_and_the_state_file(root, capsys):
    """#1931: a write that cannot land stops state set with an orch: message
    and leaves the flow as it was."""
    a_flow(root)
    before = state_json(root).read_text()
    directory = state_json(root).parent
    os.chmod(str(directory), 0o555)
    try:
        assert orch_state(capsys, root, "set", "budget", "3") == (1, "", (
            "orch: could not record budget in %s - the flow is unchanged\n" % state_json(root)))
    finally:
        os.chmod(str(directory), 0o755)
    assert state_json(root).read_text() == before


# --- the dispatch ----------------------------------------------------------------------


def test_an_unknown_op_is_refused_naming_get_and_set(root, capsys):
    a_flow(root)

    assert orch_state(capsys, root, "bogus") == (
        1, "", "orch: unknown state op: bogus (want get|set)\n")
