"""The Flow state reader, read-only, pinned to the bash Flow state module
(scripts/flow-state.sh) by the golden state.json files in flow_state/: each
file under read/ reads, key for key, as its .expected file says - the same
files and expected values the bash state section reads through
flow_state_get_many - and each under refused/ is a failed read. Its key table
is checked against the bash state key table's keys and defaults."""
from __future__ import annotations

from pathlib import Path

import pytest

from orch.flow_state import STATE_KEYS, flow_state_get_many

GOLDEN = Path(__file__).resolve().parent / "flow_state"
BASH_MODULE = Path(__file__).resolve().parents[2] / "flow-state.sh"
KEYS = [key for key, _ in STATE_KEYS]


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


def bash_state_keys():
    """The key and default columns of the bash state key table, STATE_KEYS in
    scripts/flow-state.sh, its comment and blank lines skipped as state_rows
    skips them."""
    text = BASH_MODULE.read_text(encoding="utf-8")
    table = text.split("\nSTATE_KEYS='", 1)[1].split("'\n", 1)[0]
    rows = []
    for line in table.split("\n"):
        if not line or line.startswith("#"):
            continue
        key, default = line.split("|")[:2]
        rows.append((key, default))
    return rows


@pytest.mark.skipif(not BASH_MODULE.exists(), reason="the bash Flow state module is gone")
def test_the_key_table_s_keys_and_defaults_equal_the_bash_state_key_table_s():
    assert list(STATE_KEYS) == bash_state_keys()
