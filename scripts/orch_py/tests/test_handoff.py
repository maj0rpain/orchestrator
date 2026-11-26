"""The handoff module's phase table against the bash phase table it copies,
and the handoffs a phase has due."""
from __future__ import annotations

import re
from pathlib import Path

from orch.handoff import PHASE_TABLE, handoffs_due, handoffs_written_from

HANDOFF_SH = Path(__file__).resolve().parents[2] / "orch" / "handoff.sh"


def test_the_phase_table_is_the_bash_phase_table_row_for_row():
    table = re.search(r"^readonly PHASE_TABLE='(.*?)'$", HANDOFF_SH.read_text(), re.M | re.S)

    assert table is not None
    rows = [row.split("|") for row in table.group(1).split("\n")]
    assert [(phase, handoff, writer, tuple(sections.split(";")) if sections else ())
            for phase, handoff, writer, sections in rows] == list(PHASE_TABLE)


def test_the_handoffs_due_at_a_phase_are_those_of_every_row_up_to_it():
    assert handoffs_due("spec") == ["01-plan.md"]
    assert handoffs_due("review") == ["01-plan.md", "02-spec.md", "03-implement.md"]
    assert handoffs_due("plan") == []


def test_the_handoffs_a_step_back_makes_stale_are_those_its_phase_or_a_later_one_wrote():
    assert handoffs_written_from("plan") == ["01-plan.md", "02-spec.md", "03-implement.md"]
    assert handoffs_written_from("spec") == ["02-spec.md", "03-implement.md"]
    assert handoffs_written_from("implement") == ["03-implement.md"]
    assert handoffs_written_from("review") == []
    assert handoffs_written_from("done") == []
