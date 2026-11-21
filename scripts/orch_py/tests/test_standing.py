"""The Phase label test, and its phases against the bash phase table."""
from __future__ import annotations

import re
from pathlib import Path

from orch.standing import PHASES, phase_labels_in

HANDOFF_SH = Path(__file__).resolve().parents[2] / "orch" / "handoff.sh"


def test_the_phases_are_the_bash_phase_table_s_rows_in_order():
    table = re.search(r"^readonly PHASE_TABLE='(.*?)'$", HANDOFF_SH.read_text(), re.M | re.S)

    assert table is not None
    assert PHASES == tuple(row.split("|", 1)[0] for row in table.group(1).split("\n"))


def test_the_phase_labels_among_labels_are_named_in_table_order_in_any_case():
    assert phase_labels_in(["orch:done", "bug", "ORCH:Spec", "orch:plan", "orch:running"]) \
        == ["spec", "done"]
