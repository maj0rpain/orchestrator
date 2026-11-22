"""The Standing module (scripts/orch/standing.sh), kept to what the issue
noun uses: the Phase label test.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order: the first column of the handoff
module's phase table (orch/handoff.py's PHASE_TABLE), the one Python copy of
the bash side's.
"""
from __future__ import annotations

from typing import List, Sequence

from orch.gh import label_listed
from orch.handoff import PHASE_TABLE

PHASES = tuple(row[0] for row in PHASE_TABLE)


def phase_label(phase: str) -> str:
    return "orch:" + phase


def phase_labels_in(labels: Sequence[str]) -> List[str]:
    """The phases, in table order, whose labels are among <labels>."""
    return [p for p in PHASES if label_listed(labels, phase_label(p))]
