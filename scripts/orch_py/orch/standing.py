"""The Standing module, the one copy since the bash standing.sh went with the
bash autopilot noun: where an autopilot flow's issue stands. It owns the label
set (the phase labels, orch:running, needs-human, orch:limited and orch:sync)
and the label entries a tick ensures, the phase-label helpers, the label
verdict against a recorded phase and the phase-redo rule (REDO_PAIRS), the
host id, the read of an issue's Standing (standing_read, and
standing_read_or_die, the read that dies on failure) with the sync-request
and Pickup reads on it, the claims on origin (claims_read, one read;
standing_claim, the create), and every write to an issue's Standing - each a
transition: begin, sync request, resume, start, ask, reenter, stop, sync
finish, sync dropped, limit stop, claim release, the pause a spec review round
makes and a finished phase's close (standing_finish, with its label move),
which the phase noun's finish runs for phase advance and for review ready.
Each keeps the writes, order and messages of the bash standing_ function it
was ported from; label_verdict, standing_pause, standing_finish and
standing_move_label had no bash copy left before standing.sh went.

A phase label, `orch:<phase>`, records an autopilot flow's phase on its
issue. PHASES is the flow's phases in order, read from the handoff module
(orch/handoff.py's PHASES, its phase table's first column). Labels are
matched as GitHub matches them, in any casing (label_listed), so a label
the repo holds in its own casing is found and removed.

Begin, sync request and resume are single writes; every other transition
is a chain (Chain): its writes run in order, and one that fails dies naming
the writes that landed before it, the claim held. A chain a session makes
under its claim ends in the release - orch:running removed, then, last, the
claim ref deleted. The resumable chain (#2695): a session wrapper hands a
chain its landed record, a state file of one TSV line per event - `landed
<write>` for a write whose call succeeded, `tried <write>` before a
comment's call (it may have landed though the call failed), `plan <value>`
for what a limit stop's first successful comments read fixed, and `stop
<kind> <first line>` for the wrapper's backstop line. A chain started on it
skips the writes earlier attempts landed, and a comment tried before is
looked for before it is posted again. A skill's orch.sh run hands none.
"""
from __future__ import annotations

import contextlib
import os
import socket
import sys
import tempfile
import time
from typing import (Callable, List, Mapping, NamedTuple, NoReturn, Optional, Sequence, Tuple)

from orch.common import die, plain_number, read_raw, stdout_write, temp_text_file
from orch.flow_state import now, phase_write_try
from orch.gh import ClaimRow, GhFailed, gh_die, gh_reason, label_listed
from orch.handoff import PHASES, handoff_check, handoff_comment_post_url
from orch.issue_timeline import (timeline_has_body, timeline_limit_count, timeline_read,
                                 timeline_reentry_count)
from orch.marked_comment import marked_comment_write

# The label an autopilot flow's issue carries while a session holds its claim.
STANDING_RUNNING_LABEL = "orch:running"
# The labels of an issue waiting on the human, of a session stopped on a
# limit, and of a sync request - not a phase label: an issue carrying it
# keeps orch:done.
STANDING_HUMAN_LABEL = "needs-human"
STANDING_LIMITED_LABEL = "orch:limited"
STANDING_SYNC_LABEL = "orch:sync"
# The phase word of a sync request: where a transition takes a phase for a
# sync, it takes this.
STANDING_SYNC_PHASE = "sync"


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


def label_entries() -> List[Tuple[str, str, str]]:
    """The labels a tick ensures, each (name, colour, description): a label
    per phase of the table, then the running, human, limited and sync
    labels - bash standing_label_entries."""
    colours = {"spec": "1d76db", "implement": "0e8a16", "review": "5319e7"}
    entries = [(phase_label(p), colours.get(p, "c2e0c6"),
                "Autopilot flow: " + (p + " phase next" if p in colours else p)) for p in PHASES]
    return entries + [
        (STANDING_RUNNING_LABEL, "fbca04", "Autopilot session running"),
        (STANDING_HUMAN_LABEL, "d93f0b", "Waiting on the human"),
        (STANDING_LIMITED_LABEL, "c5def5", "Autopilot session stopped on a usage or GitHub API"
                                           " rate limit; retried after the reset"),
        (STANDING_SYNC_LABEL, "0075ca", "Autopilot: base sync requested on a done flow"),
    ]


def phase_text(phase: str) -> str:
    """How a stop comment names what stopped - "the <phase> phase", or "the
    sync" for a sync request, which is no phase."""
    return "the sync" if phase == STANDING_SYNC_PHASE else "the %s phase" % phase


def label_verdict(labels: Sequence[str], phase: str) -> Tuple[str, str]:
    """Whether the phase labels among <labels> agree with the recorded
    <phase>, as bash's standing_label_verdict was, its bash copy gone:
    ("none", "") with no phase label;
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
    the <recorded> phase its checkout last moved to, per REDO_PAIRS; None for
    any other pair, which is no redo."""
    return next((redo for pair_labelled, pair_recorded, redo in REDO_PAIRS
                 if (pair_labelled, pair_recorded) == (labelled, recorded)), None)


def redo_rule() -> str:
    """The phase-redo rule as one clause, from REDO_PAIRS, each pair reading
    "from <recorded> to <labelled>" - bash standing_redo_rule."""
    return "a step back " + " or ".join(
        "from %s to %s" % (recorded, labelled) for labelled, recorded, _ in REDO_PAIRS)


def host_id(env: Mapping[str, str]) -> str:
    """The identity a claim records as its host - bash standing_host_id:
    ORCH_HOST_ID when set and non-empty (the container entrypoint sets it,
    kept in the repo volume across recreates), else the hostname."""
    return env.get("ORCH_HOST_ID", "") or socket.gethostname()


# --- the read -------------------------------------------------------------------


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

    def is_done(self) -> bool:
        """Whether the issue carries orch:done."""
        return label_listed(self.labels, phase_label("done"))

    def is_sync(self) -> bool:
        """Whether it is a sync request - orch:sync on an issue at orch:done
        with no live phase: an issue with a live phase label is its
        phase's, and one with orch:sync but no orch:done is no sync
        request."""
        return self.sync and not self.phase and self.is_done()

    def session_phase(self) -> str:
        """The phase word of the session it starts: sync for a sync request,
        else the live phase."""
        return STANDING_SYNC_PHASE if self.is_sync() else self.phase

    def pickable(self) -> bool:
        """The label half of the Pickup rule: open, with a live phase or a
        sync request, and neither running nor waiting on the human. The
        limit pause is the tick's own check."""
        return (self.state == "OPEN" and bool(self.phase or self.is_sync())
                and not self.running and not self.human)


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


def standing_read_or_die(gh, issue: str) -> Standing:
    """standing_read of issue #<issue>, dying "gh could not read issue
    #<issue>: <reason>" where the read fails."""
    standing, reason = standing_read(gh, int(issue))
    if standing is None:
        gh_die("read issue #" + issue, reason)
    return standing


def standing_human_guard(gh, issue: str) -> Standing:
    """Issue #<issue>'s Standing, read once; dies unless it is open and
    carries needs-human - bash standing_human_guard."""
    standing = standing_read_or_die(gh, issue)
    if standing.state != "OPEN":
        die("issue #%s is closed" % issue)
    if not standing.human:
        die("issue #%s does not carry %s" % (issue, STANDING_HUMAN_LABEL))
    return standing


# --- the claims -----------------------------------------------------------------


def claims_read(gh) -> Tuple[Optional[List[ClaimRow]], str]:
    """The claims on origin, read once through the gh adapter <gh>, by
    issue number, and "" - bash standing_claims_read; (None, the reason)
    where origin cannot be read, saying nothing, for a caller that stays
    silent, as bash's --quiet read does."""
    try:
        return gh.claim_list(), ""
    except GhFailed as failed:
        return None, gh_reason(failed.stderr)


def claims_read_or_die(gh) -> List[ClaimRow]:
    """claims_read, dying "could not list the claims on origin: <reason>"
    where origin cannot be read."""
    claims, reason = claims_read(gh)
    if claims is None:
        die("could not list the claims on origin: " + reason)
    return claims


def claim_of(claims: Sequence[ClaimRow], issue) -> Optional[ClaimRow]:
    """The claim <claims> hold on issue <issue>; None when none is held -
    bash standing_claim_fields."""
    return next((claim for claim in claims if claim.issue == str(issue)), None)


def standing_claim(gh, issue, phase: str, pid: int, env: Mapping[str, str],
                   clock: Callable[[], float] = time.time) -> Tuple[int, str]:
    """Creates the claim on issue <issue> at <phase> for <pid>, recording
    this host's id and the time <clock> reads - bash standing_claim: (0,
    "") taken, (2, "") a lost race, (1, the reason) any other failure."""
    try:
        taken = gh.claim_create(int(issue), phase, pid, host_id(env), now(clock))
    except GhFailed as failed:
        return 1, gh_reason(failed.stderr)
    return (0, "") if taken else (2, "")


# --- single writes --------------------------------------------------------------


def standing_relabel_one(gh, issue, add: Sequence[str] = (), remove: Sequence[str] = ()) -> str:
    """One label write on issue <issue>: "" when it landed, else the reason,
    printing nothing - each caller words its own death or warning. A single
    write, not a chain."""
    try:
        gh.issue_relabel(int(issue), add=add, remove=remove)
    except GhFailed as failed:
        return gh_reason(failed.stderr)
    return ""


def standing_resume(gh, issue) -> str:
    """Removes needs-human from issue <issue>, one write: "" or the
    reason."""
    return standing_relabel_one(gh, issue, remove=[STANDING_HUMAN_LABEL])


def standing_sync_request(gh, issue) -> str:
    """The sync request transition - adds orch:sync to issue <issue>, one
    write: "" or the reason."""
    return standing_relabel_one(gh, issue, add=[STANDING_SYNC_LABEL])


def standing_begin(gh, issue, limited: bool = False) -> str:
    """Pickup's last step - removes orch:limited from issue <issue> when
    <limited>, then adds orch:running. It never dies and does not stop the
    issue: "" when both landed, else the failed write's step wording, "step
    removing orch:limited failed: <reason>" or "step adding orch:running
    failed: <reason>"."""
    if limited:
        reason = standing_relabel_one(gh, issue, remove=[STANDING_LIMITED_LABEL])
        if reason:
            return "step removing %s failed: %s" % (STANDING_LIMITED_LABEL, reason)
    reason = standing_relabel_one(gh, issue, add=[STANDING_RUNNING_LABEL])
    if reason:
        return "step adding %s failed: %s" % (STANDING_RUNNING_LABEL, reason)
    return ""


# --- the chain ------------------------------------------------------------------


class Chain:
    """One chain transition's writes on issue <issue>, through the gh
    adapter <gh>: the writes that landed, seeded with <landed>, and the
    landed record at <state_file> ("" for none), whose landed writes the
    chain takes up and skips. <mkstemp> makes a comment's temp body file.
    Every failure dies naming the writes that landed and that the claim
    stays held."""

    def __init__(self, gh, issue: str, landed: Sequence[str] = (), state_file: str = "",
                 mkstemp: Callable[[], Tuple[int, str]] = tempfile.mkstemp) -> None:
        self.gh = gh
        self.issue = issue
        self.landed = list(landed)
        self.done: List[str] = []
        self.state_file = state_file
        self.mkstemp = mkstemp
        for key, value in self._record():
            if key == "landed":
                self.done.append(value)
                self.landed.append(value)

    def _record(self) -> List[Tuple[str, str]]:
        """The landed record's lines, each (key, value); none without one."""
        text = read_raw(self.state_file) if self.state_file else None
        rows = []
        for line in (text or "").split("\n"):
            if line:
                key, _, value = line.partition("\t")
                rows.append((key, value))
        return rows

    def put(self, key: str, value: str) -> None:
        """Records the line in the landed record; nothing without one."""
        if not self.state_file:
            return
        with contextlib.suppress(OSError), open(self.state_file, "a") as record:
            record.write("%s\t%s\n" % (key, value))

    def get(self, key: str) -> Optional[str]:
        """The value of the record's newest <key> line; None when there is
        none."""
        values = [value for have, value in self._record() if have == key]
        return values[-1] if values else None

    def landed_suffix(self) -> str:
        """What a death's clause ends with: the writes that landed and that
        the claim stays held."""
        return " - writes that landed: %s; the claim stays held" % (
            ", ".join(self.landed) or "none")

    def die(self, clause: str) -> NoReturn:
        """Dies with <clause>, the writes that landed and that the claim
        stays held."""
        die(clause + self.landed_suffix())

    def add(self, write: str) -> None:
        """Notes <write> as landed."""
        self.landed.append(write)
        self.done.append(write)
        self.put("landed", write)

    def stop_note(self, kind: str, text: str) -> None:
        """Records the stop's <kind> and the first line of <text> that is
        neither blank nor its hidden marker, for the wrapper's backstop
        line."""
        first = next((line for line in text.split("\n")
                      if line and not line.startswith("<!--")), "")
        self.put("stop", "%s\t%s" % (kind, first))

    def step(self, name: str, what: str, write: Callable[[], None]) -> None:
        """One adapter write: skipped when an earlier attempt landed <name>;
        else <write> run, a gh failure dying "could not <what> on issue
        #<issue>: <reason>", a success noting <name> as landed."""
        if name in self.done:
            return
        try:
            write()
        except GhFailed as failed:
            self.die("could not %s on issue #%s: %s"
                     % (what, self.issue, gh_reason(failed.stderr)))
        self.add(name)

    def relabel(self, add: Sequence[str] = (), remove: Sequence[str] = ()) -> None:
        """One label edit adding <add> and removing <remove>, noted "added
        <label>, removed <label>" and failing "could not add <label>, remove
        <label>", the added ones first."""
        pairs = [("add", "added", label) for label in add] + [
            ("remove", "removed", label) for label in remove]
        self.step(", ".join("%s %s" % (past, label) for _, past, label in pairs),
                  ", ".join("%s %s" % (verb, label) for verb, _, label in pairs),
                  lambda: self.gh.issue_relabel(int(self.issue), add=add, remove=remove))

    def timeline(self, purpose: str, note: Optional[Tuple[str, str]] = None):
        """The issue's comments, read once; dies naming <purpose> and why
        the read failed, the stop <note>'s kind and text, when given,
        recorded first by stop_note."""
        entries, reason = timeline_read(self.gh, self.issue)
        if entries is None:
            if note is not None:
                self.stop_note(*note)
            self.die("could not read issue #%s's comments to %s: %s"
                     % (self.issue, purpose, reason or "the comments could not be read"))
        return entries

    def comment(self, name: str, what: str, text: str) -> None:
        """Posts <text> as a comment, once only: skipped when an earlier
        attempt landed <name>. Where the record says an earlier attempt
        tried it, the comments are read first: a body that is <text>,
        trailing whitespace aside, counts as landed with no post, and a
        failed read dies posting nothing. Otherwise the temp body file is
        made and written, the try recorded, and the post made; the file is
        removed, a death included."""
        if name in self.done:
            return
        if ("tried", name) in self._record():
            entries = self.timeline("check for this stop's comment")
            if timeline_has_body(entries, text):
                self.add(name)
                return
        landed = self.landed_suffix()
        with temp_text_file(text, "could not create a temp file to " + what + landed,
                            "could not write the temp file to " + what + landed,
                            self.mkstemp) as body:
            self.put("tried", name)
            self.step(name, what, lambda: self.gh.issue_comment(int(self.issue), body))

    def release(self) -> None:
        """Removes orch:running, then deletes the claim ref, last."""
        self.relabel(remove=[STANDING_RUNNING_LABEL])
        self.step("deleted the claim ref", "delete the claim ref",
                  lambda: self.gh.claim_delete(int(self.issue)))


# --- chain transitions ----------------------------------------------------------


def standing_claim_release(chain: Chain) -> None:
    """Only releases the claim - orch:running removed, then the claim ref
    deleted - with no comment, no other label and nothing counted."""
    chain.stop_note("claim release", "could not release the claim")
    chain.release()


def standing_pause(gh, issue: str, reason: str) -> None:
    """Ends a session's turn with the phase unchanged - the claim on issue
    #<issue> released, nothing else. <reason> seeds the writes that
    landed."""
    Chain(gh, issue, [reason] if reason else []).release()


def standing_move_label(chain: Chain, phase: str) -> None:
    """Makes the issue's phase label the one for <phase> - every other phase
    label it carries removed - in one edit, noted as "moved the phase label
    to <label>". A failed read of its labels dies with the writes that
    landed."""
    n = int(chain.issue)
    try:
        _, labels = chain.gh.issue_state_labels(n)
    except GhFailed as failed:
        chain.die("could not read the labels on issue #%s: %s"
                  % (chain.issue, gh_reason(failed.stderr)))
    label = phase_label(phase)
    remove = [phase_label(p) for p in phase_labels_in(labels) if p != phase]
    chain.step("moved the phase label to " + label, "move the phase label to " + label,
               lambda: chain.gh.issue_relabel(n, add=[label], remove=remove))


def standing_finish(gh, issue: str, phase: str, reason: str, state_file: str,
                    clock: Callable[[], float] = time.time) -> None:
    """A finished phase's close under its claim on issue #<issue>: the phase
    label moved to <phase>, then <phase> recorded in the state file at
    <state_file> (updated stamped with the time <clock> reads), then the
    claim released. <reason> names what was done, and seeds the writes that
    landed. The label moves before the phase is recorded, so a failure
    between the two leaves the label one step ahead, never behind."""
    chain = Chain(gh, issue, [reason] if reason else [])
    standing_move_label(chain, phase)
    if not phase_write_try(state_file, phase, clock):
        chain.die("could not record phase %s in %s" % (phase, state_file))
    chain.landed.append("recorded phase " + phase)
    chain.release()


def standing_ask(chain: Chain, phase: str, text: str, handle: str) -> None:
    """Posts <text> as <phase>'s question comment - the hidden marker line,
    <handle> @mentioned, <text>, then the reply instructions - adds
    needs-human, then releases the claim. The marker is written first, so a
    phase it refuses dies before any write."""
    marker = marked_comment_write("question", phase)
    body = ("%s@%s\n\n%s\nReply in one comment like `1: A, 2: recommended, 3: <free text>`"
            " (`all: recommended` accepts everything).\n" % (marker, handle, text))
    chain.comment("posted the %s question comment" % phase,
                  "post the %s question comment" % phase, body)
    chain.relabel(add=[STANDING_HUMAN_LABEL])
    chain.release()


def standing_reenter(chain: Chain, phase: str, text: str, handle: Callable[[], str]) -> None:
    """The automatic re-entry, under the claim. With fewer than two re-entry
    comments of <phase> in a row it posts <text> as a re-entry comment - no
    @mention, no label change - then releases the claim; with two or more
    it asks instead, @mentioning the handle <handle> answers, noting that.
    A timeline that cannot be read dies with the claim held and no write."""
    entries = chain.timeline("count the automatic re-entries in a row")
    if timeline_reentry_count(entries, phase) >= 2:
        standing_ask(chain, phase, text + "\n\nThis follows two automatic re-entries of the %s"
                     " loop, so it asks instead of starting another.\n" % phase, handle())
        return
    marker = marked_comment_write("reentry", phase)
    chain.comment("posted the %s re-entry comment" % phase, "post the re-entry comment",
                  "%s%s\n\nThe watcher starts another %s loop.\n" % (marker, text, phase))
    chain.release()


def standing_stop_write(chain: Chain, kind: str, text: str, label: str,
                        remove: str = "") -> None:
    """The write chain of a stop: adds <label> (removing <remove> when
    given) in one edit, posts <text> as the <kind> comment, then releases
    the claim, last."""
    chain.stop_note(kind, text)
    chain.relabel(add=[label], remove=[remove] if remove else [])
    chain.comment("posted the %s comment" % kind, "post the %s comment" % kind, text)
    chain.release()


def standing_stop(chain: Chain, kind: str, phase: str, detail: str) -> None:
    """Ends a phase that will not run (<kind> refusal) or did not finish
    (failure): adds needs-human and removes orch:limited, comments - the
    hidden marker line, then the phase and <detail> - then releases the
    claim. The marker is written first: a refusal of the writer dies before
    any write."""
    marker = marked_comment_write(kind, phase)
    what = phase_text(phase)
    if kind == "refusal":
        text = ("%sAutopilot refused to run %s: %s\n\nThe issue is labelled %s. Remove the label"
                " once this is settled and the watcher picks %s up again.\n"
                % (marker, what, detail, STANDING_HUMAN_LABEL, what))
    else:
        text = ("%sAutopilot failed in %s: %s\n\nThe issue is labelled %s; nothing is retried"
                " automatically except a usage-limit stop labelled `%s`. Remove the label to"
                " have the watcher start %s again.\n"
                % (marker, what, detail, STANDING_HUMAN_LABEL, STANDING_LIMITED_LABEL, what))
    standing_stop_write(chain, kind, text, STANDING_HUMAN_LABEL, STANDING_LIMITED_LABEL)


def standing_sync_finish(chain: Chain) -> None:
    """A finished sync's close under its claim - orch:sync removed, then the
    claim released. orch:done stays and no phase is recorded."""
    chain.relabel(remove=[STANDING_SYNC_LABEL])
    chain.release()


def standing_sync_dropped(chain: Chain, intents: str, auto_sync: bool) -> None:
    """The dropped-intent stop of a sync whose merge was pushed: orch:sync
    removed and needs-human added in one edit, a failure-kind stop comment
    marked with the phase word sync listing <intents>, then the claim
    released. It asks nothing; <auto_sync> picks what the comment says
    follows."""
    marker = marked_comment_write("failure", STANDING_SYNC_PHASE)
    sync_now = "orch.sh autopilot sync %s" % chain.issue
    if auto_sync:
        following = ("Once the label is gone, the watcher files a new sync request by itself"
                     " whenever the PR conflicts with its base; or run `%s` to sync now."
                     % sync_now)
    else:
        following = "To sync again, run `%s`." % sync_now
    text = ("%sThe sync pushed its merge, but its resolver dropped these intents:\n\n%s\n\nNo"
            " reply is needed. Review the dropped intents; if you accept them, remove %s. To"
            " reject one, restore it on the branch first, then remove the label. The issue no"
            " longer carries %s. %s\n" % (marker, intents, STANDING_HUMAN_LABEL,
                                         STANDING_SYNC_LABEL, following))
    standing_stop_write(chain, "failure", text, STANDING_HUMAN_LABEL, STANDING_SYNC_LABEL)


def standing_limit_stop(chain: Chain, phase: str, reset: str, pause: str, rc: int, log: str,
                        cause: str = "") -> None:
    """Ends a phase whose session stopped on a limit - a usage limit, or
    with <cause> github a GitHub API rate limit. With fewer than two limit
    stops of the phase before it, whatever their causes, a usage-limit stop
    adds orch:limited, comments, then releases the claim; a GitHub limit
    stop adds no label: it comments, then releases the claim. The third in a
    row takes the failure path, naming the cause. The first comments read
    that succeeds fixes the stop's kind and count in the landed record for
    every later attempt; a read that fails fixes nothing, and dies. <reset>
    is "" when the session named none; <pause> is the time the limit file
    holds."""
    what = "the GitHub API rate limit" if cause else "a usage limit"
    when = " (resets %s)" % reset if reset else " (the session gave no reset time)"
    stopped = "the session stopped on %s%s and exited with code %s" % (what, when, rc)
    plan = chain.get("plan")
    if plan is None:
        entries = chain.timeline("count the stops in a row", note=("limit stop", stopped))
        count = timeline_limit_count(entries, phase)
        plan = "third" if count >= 2 else "count:%d" % count
        chain.put("plan", plan)
    if plan == "third":
        standing_stop(chain, "failure", phase, "%s, the third in a row in %s; log: %s"
                      % (stopped, phase_text(phase), log))
        return
    retry = int(plan[len("count:"):]) + 1
    marker = marked_comment_write("limited", phase, cause)
    if cause:
        text = ("%sThe session stopped on the GitHub API rate limit in %s, which resets %s.\n\n"
                "Retry %d of 2: the issue is picked up again by the next tick, no label is"
                " added.\n\nLog: %s\n" % (marker, phase_text(phase), reset or pause, retry, log))
        chain.stop_note("limit stop", text)
        chain.comment("posted the limit stop comment", "post the limit stop comment", text)
        chain.release()
        return
    at = (", which resets " + reset if reset else
          "; it gave no reset time, so the watcher falls back to a one-hour limit pause, until "
          + pause)
    text = ("%sThe session stopped on a usage limit in %s%s.\n\nThe issue is labelled %s; retry"
            " %d of 2, started once the limit pause has passed.\n\nLog: %s\n"
            % (marker, phase_text(phase), at, STANDING_LIMITED_LABEL, retry, log))
    standing_stop_write(chain, "limit stop", text, STANDING_LIMITED_LABEL)


# --- start ----------------------------------------------------------------------


def standing_start(gh, issue: str, plan_file: str, ready: str, state_file: str,
                   env: Mapping[str, str]) -> None:
    """`autopilot start <issue> <plan-file>`, bash standing_start: the
    planning close's last step. Refuses an issue that is not a plain number,
    a missing plan file, an issue whose read fails, one without the repo's
    <ready> label (its ready-for-agent) and one already carrying a phase
    label; then checks the plan as the 01-plan handoff with its `##
    Autopilot` block required, its FAIL lines on stderr, refusing an invalid
    one. Past them it posts the plan comment, then adds the first phase's
    label - last, so an issue a failed post leaves unlabelled is never
    picked up - and prints the two lines saying so. <state_file> is the
    flow state the plan's check reads."""
    if not plain_number(issue):
        die("issue must be a plain issue number, got: " + issue)
    if not os.path.isfile(plan_file):
        die("plan file not found: " + plan_file)
    standing = standing_read_or_die(gh, issue)
    if not label_listed(standing.labels, ready):
        die("issue #%s does not carry the '%s' label - an autopilot flow starts from a ready"
            " issue" % (issue, ready))
    if standing.phase_labels:
        die("issue #%s already carries the phase label %s - it is already an autopilot flow"
            % (issue, standing.phase_labels.split(" ", 1)[0]))
    with contextlib.redirect_stdout(sys.stderr):
        status = handoff_check(plan_file, state_file, env, "", "01-plan.md", "autopilot")
    if status != 0:
        die("plan %s is not valid - nothing posted" % plan_file)
    url = handoff_comment_post_url(gh, issue, "01-plan", plan_file)
    if url is None:
        raise SystemExit(1)
    first = phase_label(PHASES[0])
    try:
        gh.issue_relabel(int(issue), add=[first])
    except GhFailed as failed:
        die("posted the 01-plan comment on issue #%s but adding %s failed: %s - the issue is"
            " unlabelled, so no watcher picks it up; re-run autopilot start"
            % (issue, first, gh_reason(failed.stderr)))
    stdout_write("posted the plan comment on issue #%s%s\n" % (issue, ": " + url if url else ""))
    stdout_write("added %s to issue #%s\n" % (first, issue))
