"""The Standing module (scripts/orch/standing.sh), kept to what the issue
noun uses: the Phase label test.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order, the first column of the bash
side's phase table (scripts/orch/handoff.sh's PHASE_TABLE), which stays the
one statement of the table while both languages read it.
"""
from __future__ import annotations

from typing import List, Sequence

from orch.gh import label_listed

PHASES = ("spec", "implement", "review", "done")


def phase_label(phase: str) -> str:
    return "orch:" + phase


def phase_labels_in(labels: Sequence[str]) -> List[str]:
    """The phases, in table order, whose labels are among <labels>."""
    return [p for p in PHASES if label_listed(labels, phase_label(p))]
