"""The Standing module (scripts/orch/standing.sh), kept to what the Python
nouns use: the Phase label test, and the claim release a spec review round's
pause makes in an autopilot flow.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order: the first column of the handoff
module's phase table (orch/handoff.py's PHASE_TABLE), the one Python copy of
the bash side's.

The release is a chain, as bash's is: orch:running removed, then, last, the
claim ref deleted, so a chain that fails partway leaves the claim held and
dies naming the writes that landed. Not ported: the resumable chain. Its
state file (STANDING_STATE_FILE) is set only inside autopilot.sh's own
session wrapper, never for a skill's orch.sh run, so the copy keeps only the
landed list, seeded with the caller's reason, and the two writes.
"""
from __future__ import annotations

from typing import Callable, List, NoReturn, Sequence

from orch.common import die
from orch.gh import GhFailed, gh_reason, label_listed
from orch.handoff import PHASE_TABLE

PHASES = tuple(row[0] for row in PHASE_TABLE)
# The label an autopilot flow's issue carries while a session holds its claim.
RUNNING_LABEL = "orch:running"


def phase_label(phase: str) -> str:
    return "orch:" + phase


def phase_labels_in(labels: Sequence[str]) -> List[str]:
    """The phases, in table order, whose labels are among <labels>."""
    return [p for p in PHASES if label_listed(labels, phase_label(p))]


def standing_landed_die(clause: str, landed: Sequence[str]) -> NoReturn:
    """Dies with <clause>, the writes that <landed> and that the claim stays
    held."""
    die("%s - writes that landed: %s; the claim stays held"
        % (clause, ", ".join(landed) or "none"))


def standing_chain_step(landed: List[str], name: str, what: str, issue: str,
                        write: Callable[[], None]) -> None:
    """One adapter write of a chain: <write> run, a gh failure dying "could
    not <what> on issue #<issue>: <reason>" with the writes that landed, a
    success noting <name> on <landed>."""
    try:
        write()
    except GhFailed as failed:
        standing_landed_die("could not %s on issue #%s: %s"
                            % (what, issue, gh_reason(failed.stderr)), landed)
    landed.append(name)


def standing_release(gh, issue: str, landed: List[str]) -> None:
    """Removes orch:running from issue #<issue>, then deletes its claim ref,
    last, each a step of the chain whose writes <landed> holds."""
    n = int(issue)
    standing_chain_step(landed, "removed " + RUNNING_LABEL, "remove " + RUNNING_LABEL, issue,
                        lambda: gh.issue_relabel(n, remove=[RUNNING_LABEL]))
    standing_chain_step(landed, "deleted the claim ref", "delete the claim ref", issue,
                        lambda: gh.claim_delete(n))


def standing_pause(gh, issue: str, reason: str) -> None:
    """Ends a session's turn with the phase unchanged - the claim on issue
    #<issue> released, nothing else. <reason> seeds the writes that
    landed."""
    standing_release(gh, issue, [reason] if reason else [])
