"""The triage-label mapping, as the bash side's triage-labels.sh reads it:
the table in the repo's docs/agents/triage-labels.md mapping each canonical
triage role to the repo's local label name.

Only the role table is read: the first table of three or more columns that
holds a row whose left cell is a canonical triage role, and only its rows that
name a role. A table of under three columns is never read, a table before the
role table whose left column names no role is skipped, and nothing after the
role table ends is read. A role the doc does not name - or every role, where
there is no doc - is its own label (ADR-0028: setup is optional).
"""
from __future__ import annotations

import os
import re
from typing import Callable, Dict, List, Optional, Tuple

from orch.common import read_raw

LABELS_DOC = os.path.join("docs", "agents", "triage-labels.md")

# The five canonical triage roles, in the bash TRIAGE_ROLES order.
TRIAGE_ROLES = ("needs-triage", "needs-info", "ready-for-agent", "ready-for-human", "wontfix")

SEPARATOR_CELL = re.compile(r"^:?-+:?$")
TABLE_ROW = re.compile(r"^\s*\|")
# The markdown escape for a literal pipe, masked before a row is split.
MASK = "\x01"


def _clean(cell: str) -> str:
    """A cell as the table means it: masked pipes restored, backticks
    dropped, the padding trimmed."""
    return cell.replace(MASK, "|").replace("`", "").strip()


def table_rows(text: str) -> List[Tuple[str, str]]:
    """The (role, label) rows of the doc's role table, in order; a blank
    label kept as "", for the lookup to skip."""
    rows = []
    cols = 0
    in_role = False
    for line in text.split("\n"):
        if not TABLE_ROW.match(line):
            cols = 0
            if in_role:
                break
            continue
        fields = line.replace("\\|", MASK).split("|")
        left = _clean(fields[1]) if len(fields) > 1 else ""
        right = _clean(fields[2]) if len(fields) > 2 else ""
        # The separator row settles the width for the whole table, and only
        # it can: an empty last field there is the trailing pipe's.
        if SEPARATOR_CELL.match(right):
            cols = len(fields) - 1
            if fields[-1].strip() == "":
                cols -= 1
            continue
        if cols < 3 or left not in TRIAGE_ROLES:
            continue
        in_role = True
        rows.append((left, right))
    return rows


def expected_labels(root: str) -> List[str]:
    """The label names the checkout at <root> is expected to carry, in
    order: the doc's labels, every role-table row with one, when the doc is
    present - none when it parses to none, which doctor's labels doc check
    reports - else the canonical role names (ADR-0028)."""
    path = os.path.join(root, LABELS_DOC)
    if not os.path.isfile(path):
        return list(TRIAGE_ROLES)
    return [label for _, label in table_rows(read_raw(path) or "") if label]


class TriageLabels:
    """The mapping of the checkout whose root <root> answers - None for no
    checkout, where every role is its own label - read on the first lookup
    and kept, so a command that looks no label up reads nothing."""

    def __init__(self, root: Callable[[], Optional[str]]) -> None:
        self.root = root
        self._table: Optional[Dict[str, str]] = None

    def _rows(self) -> Dict[str, str]:
        if self._table is None:
            self._table = {}
            text = None
            root = self.root()
            if root is not None:
                try:
                    with open(os.path.join(root, LABELS_DOC), encoding="utf-8",
                              errors="surrogateescape") as f:
                        text = f.read()
                except OSError:
                    text = None
            for role, label in table_rows(text or ""):
                if label and role not in self._table:
                    self._table[role] = label
        return self._table

    def label(self, role: str) -> str:
        """The repo's label for <role>: the first role-table row naming it
        with a label, else the role name itself."""
        return self._rows().get(role, role)
