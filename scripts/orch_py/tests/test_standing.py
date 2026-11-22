"""The Phase label test."""
from __future__ import annotations

from orch.standing import phase_labels_in


def test_the_phase_labels_among_labels_are_named_in_table_order_in_any_case():
    assert phase_labels_in(["orch:done", "bug", "ORCH:Spec", "orch:plan", "orch:running"]) \
        == ["spec", "done"]
