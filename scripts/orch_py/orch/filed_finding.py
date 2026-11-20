"""The Filed finding test, as the bash side's filed-finding.sh holds it: an
issue a review loop filed carries a review:<severity> label until finding
triage gives it one of its own labels (ADR-0031).
"""
from __future__ import annotations

import re
from typing import List, Sequence

from orch.gh import label_listed
from orch.triage_labels import TriageLabels

# A review label: review: in any casing, followed by at least one character.
REVIEW_LABEL = re.compile(r"^review:.", re.IGNORECASE)

# The roles finding triage itself applies, so their labels show it ran.
FINDING_TRIAGE_ROLES = ("ready-for-agent", "ready-for-human", "wontfix")


def review_labels(labels: Sequence[str]) -> List[str]:
    """Each of <labels> that marks a review finding, at any severity, in
    order."""
    return [label for label in labels if REVIEW_LABEL.match(label)]


def finding_untriaged(labels: Sequence[str], triage: TriageLabels) -> bool:
    """Whether the issue is a filed finding finding triage has not yet
    triaged: it carries a review label and none of the repo's labels for
    ready-for-agent, ready-for-human or wontfix."""
    if not review_labels(labels):
        return False
    return not any(label_listed(labels, triage.label(role)) for role in FINDING_TRIAGE_ROLES)
