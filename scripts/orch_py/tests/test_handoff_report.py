"""Handoff validation, through the golden handoffs of tests/handoff_report/:
each case directory holds one handoff, named as the handoff it is, an
optional state.json (none means no flow, so `## Host fallbacks` is required)
and an `expected` file - the report's lines, then `status <n>`, as the
deleted bash handoff_report printed them (ADR-0067's golden files).
handoff_report must print exactly that. A case named autopilot-* is a plan
checked for its `## Autopilot` block, run both in an autopilot session and
with the autopilot switch; every other case is run plainly."""
from __future__ import annotations

from pathlib import Path

import pytest

from conftest import died_of
from orch.handoff import handoff_check, handoff_report, handoff_required

GOLDEN = Path(__file__).resolve().parent / "handoff_report"
CASES = sorted(path.name for path in GOLDEN.iterdir() if path.is_dir())
AUTOPILOT_CASES = [case for case in CASES if case.startswith("autopilot-")]
PLAIN_CASES = [case for case in CASES if not case.startswith("autopilot-")]
# How an autopilot case is run: in an autopilot session, or with the switch.
AUTOPILOT_MODES = {"session": ("1", ""), "switch": ("", "autopilot")}


def case_handoff(case):
    """The one handoff file of the case directory <case>."""
    (handoff,) = (GOLDEN / case).glob("*.md")
    return handoff


def expected(case):
    """The lines of <case>'s expected file."""
    return (GOLDEN / case / "expected").read_text(encoding="utf-8").splitlines()


def python_report(case, autopilot_env, switch):
    """The Python handoff_report's lines of <case>, then `status <n>`."""
    lines, status = handoff_report(
        str(case_handoff(case)), str(GOLDEN / case / "state.json"),
        {"ORCH_AUTOPILOT": autopilot_env}, autopilot=switch)
    return lines + ["status %d" % status]


@pytest.mark.parametrize("case", PLAIN_CASES)
def test_a_plain_golden_handoff_reports_its_expected_lines_and_status(case):
    assert python_report(case, "", "") == expected(case)


@pytest.mark.parametrize("mode", sorted(AUTOPILOT_MODES))
@pytest.mark.parametrize("case", AUTOPILOT_CASES)
def test_an_autopilot_plan_reports_its_autopilot_block(case, mode):
    autopilot_env, switch = AUTOPILOT_MODES[mode]

    assert python_report(case, autopilot_env, switch) == expected(case)


def test_handoff_check_relays_an_invalid_report_as_its_fail_lines_aligned(capsys):
    status = handoff_check(str(case_handoff("fenced-heading")),
                           str(GOLDEN / "fenced-heading" / "state.json"), {})

    assert (capsys.readouterr().out, status) == (
        "FAIL  missing section: ## Host fallbacks\n", 1)


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
