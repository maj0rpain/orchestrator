"""Handoff validation's Python copy pinned to the bash one it copies, through
the golden handoffs of tests/handoff_report/: each case directory holds one
handoff, named as the handoff it is, an optional state.json (none means no
flow, so `## Host fallbacks` is required) and an `expected` file - the
report's lines, then `status <n>`. Both the bash handoff_report, sourced in
a bash child process, and the Python one must print exactly that: ADR-0067's
golden files both languages are tested against. A case named autopilot-* is
a plan checked for its `## Autopilot` block, run both in an autopilot session
and with the autopilot switch; every other case is run plainly."""
from __future__ import annotations

from functools import lru_cache
from pathlib import Path

import pytest

from conftest import bash_sourced, died_of
from orch.handoff import handoff_check, handoff_report, handoff_required

GOLDEN = Path(__file__).resolve().parent / "handoff_report"
SCRIPTS = Path(__file__).resolve().parents[2]
CASES = sorted(path.name for path in GOLDEN.iterdir() if path.is_dir())
AUTOPILOT_CASES = [case for case in CASES if case.startswith("autopilot-")]
PLAIN_CASES = [case for case in CASES if not case.startswith("autopilot-")]
# How an autopilot case is run: in an autopilot session, or with the switch.
AUTOPILOT_MODES = {"session": ("1", ""), "switch": ("", "autopilot")}

# Each case run through the bash handoff_report and handoff_check, the modules
# loaded as orch.sh loads them with STATE the case's state.json: per case, its
# report, `status <n>`, then a `--` line and handoff_check's relay of it, the ok
# lines shown, and its `status <n>`.
BASH_RUN = r'''
set -euo pipefail
source "$1"
source "$2"
STATE="$3"
orch_load handoff
orch_load autopilot
orch_load state
ORCH_AUTOPILOT="$4"
st=0
handoff_report "$5" "" "$6" || st=$?
printf 'status %s\n--\n' "$st"
st=0
handoff_check "$5" ok "" "$6" || st=$?
printf 'status %s\n' "$st"
'''


def case_handoff(case):
    """The one handoff file of the case directory <case>."""
    (handoff,) = (GOLDEN / case).glob("*.md")
    return handoff


def expected(case):
    """The lines of <case>'s expected file."""
    return (GOLDEN / case / "expected").read_text(encoding="utf-8").splitlines()


@lru_cache(maxsize=None)
def bash_run(case, autopilot_env, switch):
    """(report lines and status, check lines and status) of <case> run
    through the bash validator in a bash child process, ORCH_AUTOPILOT set to
    <autopilot_env> and <switch> its autopilot switch; one child per case and
    mode, however many tests read it."""
    out = bash_sourced(
        SCRIPTS / "flow-state.sh", BASH_RUN, SCRIPTS / "orch" / "common.sh",
        SCRIPTS / "orch" / "loader.sh", GOLDEN / case / "state.json", autopilot_env,
        case_handoff(case), switch).splitlines()
    split = out.index("--")
    return out[:split], out[split + 1:]


def python_report(case, autopilot_env, switch):
    """The Python handoff_report's lines of <case>, then `status <n>`."""
    lines, status = handoff_report(
        str(case_handoff(case)), str(GOLDEN / case / "state.json"),
        {"ORCH_AUTOPILOT": autopilot_env}, autopilot=switch)
    return lines + ["status %d" % status]


def python_check(case, autopilot_env, switch, capsys):
    """The Python handoff_check's stdout lines of <case>, the ok lines shown,
    then `status <n>`."""
    status = handoff_check(
        str(case_handoff(case)), str(GOLDEN / case / "state.json"),
        {"ORCH_AUTOPILOT": autopilot_env}, show_ok="ok", autopilot=switch)
    return capsys.readouterr().out.splitlines() + ["status %d" % status]


@pytest.mark.parametrize("case", PLAIN_CASES)
def test_a_plain_golden_handoff_reports_its_expected_lines_and_status_in_both_languages(case):
    assert python_report(case, "", "") == expected(case)
    assert bash_run(case, "", "")[0] == expected(case)


@pytest.mark.parametrize("mode", sorted(AUTOPILOT_MODES))
@pytest.mark.parametrize("case", AUTOPILOT_CASES)
def test_an_autopilot_plan_reports_its_autopilot_block_in_both_languages(case, mode):
    autopilot_env, switch = AUTOPILOT_MODES[mode]

    assert python_report(case, autopilot_env, switch) == expected(case)
    assert bash_run(case, autopilot_env, switch)[0] == expected(case)


@pytest.mark.parametrize("case", PLAIN_CASES + AUTOPILOT_CASES)
def test_handoff_check_relays_a_golden_report_as_the_bash_check_does(case, capsys):
    autopilot_env, switch = AUTOPILOT_MODES["switch"] if case in AUTOPILOT_CASES else ("", "")

    assert python_check(case, autopilot_env, switch, capsys) == \
        bash_run(case, autopilot_env, switch)[1]


def test_handoff_check_relays_an_invalid_report_as_its_fail_lines_aligned(capsys):
    status = handoff_check(str(case_handoff("fenced-heading")),
                           str(GOLDEN / "fenced-heading" / "state.json"), {})

    assert (capsys.readouterr().out, status) == (
        "FAIL  missing section: ## Host fallbacks\n", 1)


def test_handoff_check_shows_the_ok_lines_aligned_when_asked(capsys):
    status = handoff_check(str(case_handoff("host-fallbacks-not-required")),
                           str(GOLDEN / "host-fallbacks-not-required" / "state.json"), {},
                           show_ok="ok")

    assert (capsys.readouterr().out, status) == ("ok    ## Spec issue\n", 0)


def test_handoff_check_of_a_missing_file_is_one_fail_line_and_status_2(tmp_path, capsys):
    missing = tmp_path / "02-spec.md"

    status = handoff_check(str(missing), str(tmp_path / "state.json"), {})

    assert (capsys.readouterr(), status) == (
        ("FAIL  handoff not found: %s\n" % missing, ""), 2)


def test_handoff_check_of_an_unknown_handoff_name_fails_without_dying(capsys):
    status = handoff_check(str(case_handoff("valid")), str(GOLDEN / "valid" / "state.json"),
                           {}, name="notes.md")

    assert (capsys.readouterr(), status) == (
        ("", "orch: unknown handoff file: notes.md\n"), 1)


def test_a_scratch_file_is_checked_as_the_handoff_it_is_named_for(tmp_path):
    scratch = tmp_path / "plan-draft"
    scratch.write_text(case_handoff("autopilot-good").read_text())

    assert handoff_report(str(scratch), str(tmp_path / "state.json"), {},
                          name="01-plan.md", autopilot="autopilot") == (expected(
                              "autopilot-good")[:-1], 0)


def test_the_required_sections_are_the_phase_table_s_then_host_fallbacks(tmp_path):
    assert handoff_required("02-spec.md", str(tmp_path / "state.json")) == [
        "## Spec issue", "## Host fallbacks"]


def test_an_unknown_handoff_file_has_no_required_sections(tmp_path, capsys):
    assert died_of(capsys, lambda: handoff_required("notes.md", str(tmp_path / "s.json"))) == (
        1, "", "orch: unknown handoff file: notes.md\n")
