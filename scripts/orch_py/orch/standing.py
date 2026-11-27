"""The Standing module (scripts/orch/standing.sh), kept to what the Python
nouns use: the Phase label test, and what Python doctor reads an autopilot
flow's issue with - the phase labels' text, the live phase, the label
verdict against a recorded phase and the phase-redo rule (REDO_PAIRS), the
read of an issue's Standing (standing_read), the host id and the claims
read (claims_read) - each as bash's of the same name; the claim release a spec review round's
pause makes in an autopilot flow, and a finished phase's close under its
claim (standing_finish, with its label move, standing_move_label), which the
phase noun's finish runs for phase advance and for review ready.
standing_pause, standing_finish and standing_move_label have no bash copy
left: their bash callers, the spec and phase modules, went at those nouns'
cutovers, while standing_release and standing_chain_start stay in bash for
the other transitions.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order, read from the handoff module
(orch/handoff.py's PHASES, its phase table's first column), the one Python
copy of the bash side's.

The release is a chain, as bash's is: orch:running removed, then, last, the
claim ref deleted, so a chain that fails partway leaves the claim held and
dies naming the writes that landed; a finish moves the phase label and
records the phase ahead of it, on the same landed list. Not ported: the
resumable chain. Its state file (STANDING_STATE_FILE) is set only inside
autopilot.sh's own session wrapper, never for a skill's orch.sh run, so the
copy keeps only the landed list, seeded with the caller's reason, and the
writes.
"""
from __future__ import annotations

import socket
import time
from typing import Callable, List, Mapping, NamedTuple, NoReturn, Optional, Sequence, Tuple

from orch.common import die
from orch.flow_state import phase_write_try
from orch.gh import ClaimRow, GhFailed, gh_reason, label_listed
from orch.handoff import PHASES

# The label an autopilot flow's issue carries while a session holds its claim.
STANDING_RUNNING_LABEL = "orch:running"
# The labels of an issue waiting on the human, of a session stopped on a
# limit, and of a sync request - not a phase label: an issue carrying it
# keeps orch:done.
STANDING_HUMAN_LABEL = "needs-human"
STANDING_LIMITED_LABEL = "orch:limited"
STANDING_SYNC_LABEL = "orch:sync"


def phase_label(phase: str) -> str:
    return "orch:" + phase


def phase_labels_in(labels: Sequence[str]) -> List[str]:
    """The phases, in table order, whose labels are among <labels>."""
    return [p for p in PHASES if label_listed(labels, phase_label(p))]


def phase_labels_text(labels: Sequence[str]) -> str:
    """The phase labels among <labels>, each spelled `orch:<phase>`, joined
    by single spaces in table order; "" when there are none - bash
    standing_phase_labels_text."""
    return " ".join(phase_label(p) for p in phase_labels_in(labels))


def live_phase(labels: Sequence[str]) -> str:
    """The first phase other than done whose label is among <labels>, in
    table order; "" when there is none - bash standing_live_phase."""
    return next((p for p in phase_labels_in(labels) if p != "done"), "")


def label_verdict(labels: Sequence[str], phase: str) -> Tuple[str, str]:
    """Whether the phase labels among <labels> agree with the recorded
    <phase> - bash standing_label_verdict: ("none", "") with no phase label;
    ("agrees", <text>) when the one carried is <phase>'s; else ("disagrees",
    <text>), <text> the phase labels' phase_labels_text."""
    text = phase_labels_text(labels)
    if not text:
        return "none", ""
    return ("agrees" if text == phase_label(phase) else "disagrees"), text


# The one source of the phase-redo rule: (labelled, recorded, redo) rows, the
# redo being the `orch.sh redo` argument for a flow labelled <labelled> whose
# checkout last moved to <recorded> - bash STANDING_REDO_PAIRS.
REDO_PAIRS = (("implement", "review", "review"), ("spec", "implement", "spec"))


def redo_phase(labelled: str, recorded: str) -> Optional[str]:
    """The phase-redo rule, bash standing_redo_phase: the `orch.sh redo`
    argument that steps a flow labelled <labelled> back to that phase from
    the <recorded> phase its checkout last moved to; None for any other
    pair, which is no redo."""
    return next((redo for pair_labelled, pair_recorded, redo in REDO_PAIRS
                 if (pair_labelled, pair_recorded) == (labelled, recorded)), None)


def host_id(env: Mapping[str, str]) -> str:
    """The identity a claim records as its host - bash standing_host_id:
    ORCH_HOST_ID when set and non-empty (the container entrypoint sets it,
    kept in the repo volume across recreates), else the hostname."""
    return env.get("ORCH_HOST_ID", "") or socket.gethostname()


class Standing(NamedTuple):
    """The label half of an issue's Standing, as bash standing_set fills
    it: its state (OPEN or CLOSED), every label, the live phase
    (live_phase), the text of every phase label (phase_labels_text), and
    whether it carries orch:running, needs-human, orch:limited and
    orch:sync."""

    state: str
    labels: List[str]
    phase: str
    phase_labels: str
    running: bool
    human: bool
    limited: bool
    sync: bool


def standing_of(state: str, labels: Sequence[str]) -> Standing:
    """The label half of Standing from a <state> and <labels>, with no
    GitHub call - bash standing_set."""
    return Standing(state, list(labels), live_phase(labels), phase_labels_text(labels),
                    label_listed(labels, STANDING_RUNNING_LABEL),
                    label_listed(labels, STANDING_HUMAN_LABEL),
                    label_listed(labels, STANDING_LIMITED_LABEL),
                    label_listed(labels, STANDING_SYNC_LABEL))


def standing_read(gh, issue) -> Tuple[Optional[Standing], str]:
    """Issue <issue>'s state and labels, read once through the gh adapter
    <gh>, as its Standing and "" - bash standing_read; (None, gh's reason)
    where the read fails, printing nothing, for a caller that words its own
    death."""
    try:
        state, labels = gh.issue_state_labels(issue)
    except GhFailed as failed:
        return None, gh_reason(failed.stderr)
    return standing_of(state, labels), ""


def claims_read(gh) -> Tuple[Optional[List[ClaimRow]], str]:
    """The claims on origin, read once through the gh adapter <gh>, by
    issue number, and "" - bash standing_claims_read; (None, the reason)
    where origin cannot be read, saying nothing, for a caller that words
    its own death or stays silent, as bash's --quiet read does."""
    try:
        return gh.claim_list(), ""
    except GhFailed as failed:
        return None, gh_reason(failed.stderr)


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
    standing_chain_step(landed, "removed " + STANDING_RUNNING_LABEL,
                        "remove " + STANDING_RUNNING_LABEL, issue,
                        lambda: gh.issue_relabel(n, remove=[STANDING_RUNNING_LABEL]))
    standing_chain_step(landed, "deleted the claim ref", "delete the claim ref", issue,
                        lambda: gh.claim_delete(n))


def standing_pause(gh, issue: str, reason: str) -> None:
    """Ends a session's turn with the phase unchanged - the claim on issue
    #<issue> released, nothing else. <reason> seeds the writes that
    landed."""
    standing_release(gh, issue, [reason] if reason else [])


def standing_move_label(gh, issue: str, phase: str, landed: List[str]) -> None:
    """Makes issue #<issue>'s phase label the one for <phase> - every other
    phase label it carries removed - in one edit, a step of the chain whose
    writes <landed> holds, noted as "moved the phase label to <label>". A
    failed read of its labels dies with the writes that landed."""
    n = int(issue)
    try:
        _, labels = gh.issue_state_labels(n)
    except GhFailed as failed:
        standing_landed_die("could not read the labels on issue #%s: %s"
                            % (issue, gh_reason(failed.stderr)), landed)
    label = phase_label(phase)
    remove = [phase_label(p) for p in phase_labels_in(labels) if p != phase]
    standing_chain_step(landed, "moved the phase label to " + label,
                        "move the phase label to " + label, issue,
                        lambda: gh.issue_relabel(n, add=[label], remove=remove))


def standing_finish(gh, issue: str, phase: str, reason: str, state_file: str,
                    clock: Callable[[], float] = time.time) -> None:
    """A finished phase's close under its claim on issue #<issue>: the phase
    label moved to <phase>, then <phase> recorded in the state file at
    <state_file> (updated stamped with the time <clock> reads), then the
    claim released. <reason> names what was done, and seeds the writes that
    landed. The label moves before the phase is recorded, so a failure
    between the two leaves the label one step ahead, never behind."""
    landed = [reason] if reason else []
    standing_move_label(gh, issue, phase, landed)
    if not phase_write_try(state_file, phase, clock):
        standing_landed_die("could not record phase %s in %s" % (phase, state_file), landed)
    landed.append("recorded phase " + phase)
    standing_release(gh, issue, landed)
