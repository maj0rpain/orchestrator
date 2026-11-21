"""The Standing module (scripts/orch/standing.sh), kept to what the issue
noun uses: the Phase label test.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order: a copy of the first column of
the bash side's phase table (scripts/orch/handoff.sh's PHASE_TABLE), which
Python does not read, pinned to it by tests/test_standing.py's drift test.
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
