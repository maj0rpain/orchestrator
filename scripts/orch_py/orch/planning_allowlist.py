"""The planning allowlist concept's module: the Python copy of the bash
module scripts/planning-allowlist.sh, which stays the one definition the edit
guard (hook-guard.sh) and the grilling hook source, since hooks stay bash
(ADR-0067).

The allowlist holds the files a planning session may write; the exclusions
are paths under an allowlisted prefix that stay guarded, other checkouts'
source; the planning records - the glossary and ADRs - are decisions planning
never changes in place. The flow-start check refuses to start when changes
fall outside the allowlist (ADR-0013), choosing its redirect by the records.
tests/test_planning_allowlist.py pins the lists, texts and matcher to the bash
module's, so the check and the guard never disagree.

Every entry is relative to the repo root: one ending in "/" is a directory
prefix, any other an exact path.
"""
from __future__ import annotations

from typing import List, Sequence

from orch.common import die

PLANNING_ALLOWLIST = ("docs/agents/", ".scratch/", ".orchestrator/")
PLANNING_EXCLUSIONS = (".orchestrator/checkouts/", ".orchestrator/worktrees/")
PLANNING_RECORDS = ("GLOSSARY.md", "GLOSSARY-MAP.md", "CONTEXT.md", "CONTEXT-MAP.md", "docs/adr/")

# The sentences that say where a planning record's intended wording goes
# instead, shared by the guard and the flow-start check.
PLANNING_RECORD_REDIRECT = (
    "Write the exact wording you intended - the new or replaced text, and where it goes"
    " - into the plan, so the spec carries it verbatim as an Implementation Decision"
    " and it lands with the change it describes. For a quick implementation, put it"
    " in the linked issue's body."
)


def planning_allowlist_text() -> str:
    """The allowlist as one comma-separated line, for messages that say what
    planning may still edit."""
    return ", ".join(PLANNING_ALLOWLIST)


def planning_records_text() -> str:
    """The records the same way, for messages that say what planning never
    edits in place."""
    return ", ".join(PLANNING_RECORDS)


def planning_list_match(path: str, entries: Sequence[str]) -> bool:
    """Whether <path> matches one of <entries>: lies under a directory
    prefix, or equals an exact path."""
    return any(
        path.startswith(entry) if entry.endswith("/") else path == entry for entry in entries
    )


def planning_excluded(path: str) -> bool:
    """Whether the repo-relative <path> matches one of the exclusions."""
    return planning_list_match(path, PLANNING_EXCLUSIONS)


def planning_allowlisted(path: str) -> bool:
    """Whether the repo-relative <path> is inside the planning allowlist: on
    it and not excluded."""
    return not planning_excluded(path) and planning_list_match(path, PLANNING_ALLOWLIST)


def planning_record(path: str) -> bool:
    """Whether the repo-relative <path> is a planning record: the glossary or
    an ADR."""
    return planning_list_match(path, PLANNING_RECORDS)


def dirty_outside_allowlist(git) -> List[str]:
    """Every path the git adapter <git> finds dirty in this working tree that
    falls outside the planning allowlist, in git status's order, both sides of
    a rename or copy counted. Dies, exit 1, naming git's own error line when
    git status cannot run: that must refuse, never read as a clean tree."""
    paths = git.dirty_paths()
    if isinstance(paths, str):
        die("git status failed - cannot check the working tree: " + paths)
    return [path for path in paths if not planning_allowlisted(path)]
