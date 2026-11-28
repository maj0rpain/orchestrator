"""The Flow state module's Python side, pinned to the bash Flow state module
(scripts/flow-state.sh) by the golden state.json files in flow_state/: each
file under read/ reads, key for key, as its .expected file says - the same
files and expected values the bash state section reads through
flow_state_get_many - each under refused/ is a failed read, and each under
seed/, which only these tests read, is the state.json bash init wrote, which
Python's seed, create and phase write reproduce byte for byte. Its key table
is checked against the bash state key table's keys, defaults and seed
column, read through a bash child process."""
from __future__ import annotations

from pathlib import Path

import pytest

from orch.flow_state import (STATE_KEYS, flow_state_create, flow_state_get_many,
                             flow_state_seed, phase_write, phase_write_try, require_value,
                             state_write_many)
from conftest import bash_sourced, died_of

GOLDEN = Path(__file__).resolve().parent / "flow_state"
BASH_MODULE = Path(__file__).resolve().parents[2] / "flow-state.sh"
KEYS = [key for key, _, _, _ in STATE_KEYS]


def expected_values(path):
    """The <key><TAB><value> lines of a golden .expected file, as a dict in
    file order."""
    return dict(line.split("\t", 1) for line in path.read_text(encoding="utf-8").splitlines())


@pytest.mark.parametrize("name", ["every-key", "missing-or-null"])
def test_a_golden_state_file_reads_every_key_as_its_expected_file_says(name):
    expected = expected_values(GOLDEN / "read" / (name + ".expected"))

    assert list(expected) == KEYS
    assert flow_state_get_many(str(GOLDEN / "read" / (name + ".json")), KEYS) == expected


@pytest.mark.parametrize(
    "name", ["not-an-object", "null", "truncated", "trailing-text", "second-value"])
def test_a_refused_golden_state_file_is_a_failed_read(name):
    assert flow_state_get_many(str(GOLDEN / "refused" / (name + ".json")), KEYS) is None


def test_a_missing_state_file_is_a_failed_read(tmp_path):
    assert flow_state_get_many(str(tmp_path / "state.json"), ["slug"]) is None


def test_a_key_outside_the_table_is_a_programming_error_not_a_failed_read(tmp_path):
    state = tmp_path / "state.json"
    state.write_text('{"slug":"s"}')

    with pytest.raises(ValueError, match="bogus"):
        flow_state_get_many(str(state), ["slug", "bogus"])


def test_a_key_outside_the_table_raises_even_when_the_file_is_missing(tmp_path):
    with pytest.raises(ValueError):
        flow_state_get_many(str(tmp_path / "state.json"), ["bogus"])


def test_a_nul_inside_a_value_is_dropped(tmp_path):
    state = tmp_path / "state.json"
    state.write_text('{"slug":"x\\u0000y","issue":"z"}')

    assert flow_state_get_many(str(state), ["slug", "issue"]) == {"slug": "xy", "issue": "z"}


def bash_state_rows():
    """The data rows of the bash state key table, STATE_KEYS in
    scripts/flow-state.sh, as its one reader state_rows prints them in a bash
    child process: (key, default, seed) each, in table order."""
    return [tuple(line.split("|", 2))
            for line in bash_sourced(BASH_MODULE, "state_rows").splitlines()]


@pytest.mark.skipif(not BASH_MODULE.exists(), reason="the bash Flow state module is gone")
def test_the_key_table_s_keys_and_defaults_equal_the_bash_state_key_table_s():
    assert [(key, default) for key, default, _, _ in STATE_KEYS] == \
        [row[:2] for row in bash_state_rows()]


@pytest.mark.skipif(not BASH_MODULE.exists(), reason="the bash Flow state module is gone")
def test_the_key_table_s_seed_column_equals_the_bash_state_key_table_s():
    assert [(key, seed) for key, _, seed, _ in STATE_KEYS] == \
        [(row[0], row[2]) for row in bash_state_rows()]


# The clock the seed golden files were made with: 2026-01-02T03:04:05Z.
SEED_CLOCK = 1767323045.0


@pytest.mark.parametrize("name, issue", [("no-issue", ""), ("issue", "42")])
def test_the_seed_and_its_spec_phase_write_reproduce_bash_init_s_state_file_byte_for_byte(
        tmp_path, name, issue):
    r"""The golden files in seed/ are the state.json bash init left for slug
    seed-golden, base rélease/2.0 and the clock above, an empty and a
    numeric issue, made once from the bash path by this script, run in a
    fresh git repository with ORCH the bash orch.sh and G the seed/ directory:

        source "$ORCH"
        now() { printf "%s\n" 2026-01-02T03:04:05Z; }
        for issue in "" 42; do
          mkdir -p "$ORCH_DIR_NAME"
          flow_state_create "$STATE" "$(flow_state_seed seed-golden "$issue" "rélease/2.0")"
          phase_write spec
          cp "$STATE" "$G/$([ -n "$issue" ] && echo issue || echo no-issue).json"
        done
    """
    state = tmp_path / "state.json"

    assert flow_state_create(
        str(state), flow_state_seed("seed-golden", issue, "rélease/2.0", lambda: SEED_CLOCK))
    phase_write(str(state), "spec", lambda: SEED_CLOCK)

    assert state.read_bytes() == (GOLDEN / "seed" / (name + ".json")).read_bytes()


@pytest.mark.parametrize("write", [phase_write, phase_write_try])
def test_the_phase_writers_refuse_a_phase_outside_the_phase_table(tmp_path, capsys, write):
    state = tmp_path / "state.json"
    state.write_text('{"phase":"spec"}')

    assert died_of(capsys, lambda: write(str(state), "plan")) == (
        1, "", "orch: not a flow phase: plan (want one of: spec implement review done)\n")
    assert state.read_text() == '{"phase":"spec"}'


@pytest.mark.parametrize("text", [None, "not json", "[1]"])
def test_the_phase_write_dies_leaving_the_file_as_it_was_when_it_is_absent_or_not_an_object(
        tmp_path, capsys, text):
    state = tmp_path / "state.json"
    if text is not None:
        state.write_text(text)

    assert died_of(capsys, lambda: phase_write(str(state), "spec")) == (
        1, "", "orch: could not record phase in %s - the flow is unchanged\n" % state)
    assert (state.read_text() if text is not None else state.exists()) == (text or False)
    assert sorted(p.name for p in tmp_path.iterdir()) == ([] if text is None else ["state.json"])


@pytest.mark.parametrize("text", [None, "not json", "[1]"])
def test_the_phase_write_try_fails_printing_nothing_leaving_the_file_as_it_was(
        tmp_path, capsys, text):
    state = tmp_path / "state.json"
    if text is not None:
        state.write_text(text)

    assert phase_write_try(str(state), "spec") is False
    assert capsys.readouterr() == ("", "")
    assert (state.read_text() if text is not None else state.exists()) == (text or False)


def test_the_phase_write_try_records_the_phase_and_succeeds(tmp_path):
    state = tmp_path / "state.json"
    state.write_text('{"phase":"spec","updated":"x"}')

    assert phase_write_try(str(state), "implement", lambda: SEED_CLOCK) is True
    assert state.read_text() == (
        '{\n  "phase": "implement",\n  "updated": "2026-01-02T03:04:05Z"\n}\n')


@pytest.mark.parametrize("key, message", [
    ("issue", "no issue recorded in state - the spec phase must publish one first"),
    ("branch", "no branch recorded in state"),
    ("pr", "no PR recorded in state - the implement phase opens it"),
    ("base_sha", "no base SHA recorded in state - branch create records it"),
])
def test_a_required_value_left_empty_dies_with_its_key_s_message(capsys, key, message):
    assert died_of(capsys, lambda: require_value(key, "")) == (1, "", "orch: %s\n" % message)
    assert require_value(key, "7") is None


def test_a_required_value_dies_through_the_code_it_is_given(capsys):
    assert died_of(capsys, lambda: require_value("pr", "", 2)) == (
        2, "", "orch: no PR recorded in state - the implement phase opens it\n")


def test_a_required_value_whose_key_has_no_message_exits_2_whatever_its_value(capsys):
    assert died_of(capsys, lambda: require_value("slug", "x")) == (
        2, "", "orch: no required-field message for state key: slug\n")


def test_the_create_fails_making_nothing_when_the_state_directory_is_gone(tmp_path):
    state = tmp_path / ".orchestrator" / "state.json"

    assert not flow_state_create(str(state), flow_state_seed("s", "", "main"))
    assert not state.parent.exists()


MANY_STATE = '{"phase":"implement","branch":"orch/7-x","pr":12,"redo_count":0,"updated":"x"}'


def test_a_multi_key_write_records_every_key_in_one_write_as_bash_s_does(tmp_path):
    """Python's write and bash flow_state_write_many, on the same state and
    the same pairs - a null, an integer, a word, and a number marked a
    string - leave the same bytes."""
    python, bash = tmp_path / "python.json", tmp_path / "bash.json"
    python.write_text(MANY_STATE)
    bash.write_text(MANY_STATE)

    state_write_many(str(python), [("pr", "null"), ("redo_count", "2"), ("budget", "7"),
                                   ("branch", "123", True), ("slug", "word")],
                     lambda: SEED_CLOCK)
    bash_sourced(BASH_MODULE, 'now() { printf "%s\\n" 2026-01-02T03:04:05Z; }\n'
                 'flow_state_write_many "$1" pr null redo_count 2 budget 7 --string branch 123 '
                 'slug word', bash)

    assert python.read_bytes() == bash.read_bytes()
    assert python.read_text() == (
        '{\n  "phase": "implement",\n  "branch": "123",\n  "pr": null,\n  "redo_count": 2,\n'
        '  "updated": "2026-01-02T03:04:05Z",\n  "budget": 7,\n  "slug": "word"\n}\n')


@pytest.mark.parametrize("text", [None, "not json"])
def test_a_failed_multi_key_write_dies_naming_each_key_once_leaving_the_file(
        tmp_path, capsys, text):
    state = tmp_path / "state.json"
    if text is not None:
        state.write_text(text)

    assert died_of(capsys, lambda: state_write_many(
        str(state), [("branch", "b", True), ("redo_count", "1"), ("branch", "c", True)])) == (
        1, "", "orch: could not record branch, redo_count in %s - the flow is unchanged\n" % state)
    assert (state.read_text() if text is not None else state.exists()) == (text or False)


def test_a_phase_write_records_its_keys_with_the_phase_in_one_write(tmp_path):
    state = tmp_path / "state.json"
    state.write_text(MANY_STATE)

    phase_write(str(state), "spec", lambda: SEED_CLOCK,
                [("issue", "null"), ("branch", "null"), ("iteration", "0")])

    assert state.read_text() == (
        '{\n  "phase": "spec",\n  "branch": null,\n  "pr": 12,\n  "redo_count": 0,\n'
        '  "updated": "2026-01-02T03:04:05Z",\n  "issue": null,\n  "iteration": 0\n}\n')


def test_a_failed_phase_write_with_keys_records_neither_the_phase_nor_any_key(tmp_path, capsys):
    state = tmp_path / "state.json"
    state.write_text("[1]")

    assert died_of(capsys, lambda: phase_write(
        str(state), "spec", pairs=[("issue", "null"), ("branch", "null")])) == (
        1, "", "orch: could not record phase, issue, branch in %s - the flow is unchanged\n"
        % state)
    assert phase_write_try(str(state), "spec", pairs=[("issue", "null")]) is False
    assert state.read_text() == "[1]"


def test_a_phase_write_outside_the_phase_table_writes_none_of_its_keys(tmp_path, capsys):
    state = tmp_path / "state.json"
    state.write_text(MANY_STATE)

    assert died_of(capsys, lambda: phase_write(str(state), "plan", pairs=[("pr", "null")]))[0] == 1
    assert state.read_text() == MANY_STATE
