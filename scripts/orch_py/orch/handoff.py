"""The handoff concept's module (scripts/orch/handoff.sh), kept to what the
review-pass noun reads a record's text with - the lines under a heading, and
how many times a heading stands outside any code fence - to `handoff path`,
which the spec-review noun's prompt takes the plan handoff from, and to
handoff validation (handoff_required, host_fallbacks_required,
handoff_report, handoff_check), the Python copy of the bash validator the
handoff noun keeps, pinned to it by tests/test_handoff_report.py's golden
handoffs, and to what the phase noun's advance reads a handoff with: the
dying read (handoff_read) and the invalid-handoff refusal (handoff_invalid),
each with its file and comment adapter, their messages as bash's;
handoff_invalid and phase_next have no bash copy left, their one bash caller
the phase module, gone at the phase noun's cutover. And what the redo noun
sets the stale handoffs aside with: the handoffs a step back to a phase
makes stale (handoffs_written_from), and the retire (handoff_retire), whose
file adapter moves them into a labelled folder and whose comment adapter
reads the issue's comments once, then posts a retired marked comment per
live handoff, dying with the names already posted, as bash's did; neither
has a bash copy left, their one bash caller the redo module, gone at the
redo noun's cutover. And the plan comment's post `autopilot start` makes
(handoff_comment_post_url), its URL answered.

A line inside a code fence (orch.common.fenced), its delimiters included, is
never a heading: it neither opens nor closes a section, and inside an open
one it is part of the body.

The phase table is the one Python copy of the bash side's (PHASE_TABLE),
which Python does not read, pinned to it by tests/test_handoff.py's drift
test; PHASES is its first column, and phase_writer and
phase_next read it as bash's phase_cell writer did and its phase_next did,
and phases_from reads it as bash's phases_from did. Python doctor's handoff
check reads through each adapter: handoff_ready, handoff_fetch_due,
handoff_fetched and handoff_doctor_missing, each with its file and comment
form; phases_from and these have no bash copy left, their one bash caller
the doctor module, gone at the doctor noun's cutover. `handoff
path` resolves through the Handoff store's adapter handoff_store chooses per
call: the file adapter, the handoff directory's files, and in an autopilot
session the comment adapter, marked comments on the recorded issue, read
once and copied to the scratch directory to be read as files.
"""
from __future__ import annotations

import os
from typing import List, Mapping, NoReturn, Optional, Sequence, Tuple

from orch.autopilot import autopilot_active, autopilot_block_report
from orch.common import (ORCH_DIR_NAME, die, fenced, file_write_atomic, lines_of,
                         move_files_aside, read_raw, rm_f, stdout_write, temp_text_file, trim,
                         warn)
from orch.flow_state import flow_state_file, flow_state_get_many, require_issue
from orch.gh import GhFailed, gh_reason
from orch.issue_timeline import Entry, timeline_body, timeline_die, timeline_handoff, timeline_read
from orch.marked_comment import marked_comment_write

# The text under the marker of the comment that retires a handoff.
RETIRED_TEXT = "Retired by an orchestrator redo: this handoff described work the redo sets aside.\n"

# The phase table, row by row: the phase, the handoff it consumes, the writer
# (the phase that wrote that handoff) and that handoff's required sections. done
# consumes nothing, so its cells are empty.
PHASE_TABLE = (
    ("spec", "01-plan.md", "plan", ("Decisions", "Rejected alternatives", "Constraints",
                                    "Open assumptions")),
    ("implement", "02-spec.md", "spec", ("Spec issue",)),
    ("review", "03-implement.md", "implement", ("PR", "Spec issue", "Base SHA", "Deviations",
                                                "Verification")),
    ("done", "", "", ()),
)
# The flow's phases in order, the table's first column.
PHASES = tuple(row[0] for row in PHASE_TABLE)


def section_body(text: str, heading: str) -> List[str]:
    """The lines of <text> under the line exactly <heading>, up to the next
    `## ` heading - every such section, in order, when the heading stands
    more than once."""
    lines = lines_of(text)
    body = []
    inside = False
    for line, fence in zip(lines, fenced(lines)):
        if not fence and line == heading:
            inside = True
            continue
        if not fence and line.startswith("## "):
            inside = False
        if inside:
            body.append(line)
    return body


def section_count(text: str, heading: str) -> int:
    """The number of lines of <text> exactly equal to <heading> outside any
    code fence."""
    lines = lines_of(text)
    return sum(1 for line, fence in zip(lines, fenced(lines)) if not fence and line == heading)


def handoff_dir(root: str) -> str:
    """The handoff directory of the checkout at <root>."""
    return "%s/%s/handoff" % (root, ORCH_DIR_NAME)


def handoff_scratch_dir(root: str) -> str:
    """Where an autopilot flow fetches a handoff comment to read it as a
    file."""
    return "%s/%s/scratch" % (root, ORCH_DIR_NAME)


def phase_handoff(phase: str) -> Optional[str]:
    """phase_cell handoff <phase>: the handoff <phase> consumes; None when
    it consumes none or the table does not hold it."""
    for row_phase, handoff, _, _ in PHASE_TABLE:
        if row_phase == phase:
            return handoff or None
    return None


def phase_writer(phase: str) -> Optional[str]:
    """phase_cell writer <phase>: the phase that wrote the handoff <phase>
    consumes; None when it consumes none or the table does not hold it."""
    for row_phase, _, writer, _ in PHASE_TABLE:
        if row_phase == phase:
            return writer or None
    return None


def phase_next(phase: str) -> Optional[str]:
    """The phase after <phase> in the table, as bash phase_next was; None for the
    last phase and for one the table does not hold."""
    if phase not in PHASES[:-1]:
        return None
    return PHASES[PHASES.index(phase) + 1]


def handoffs_due(phase: str) -> List[str]:
    """The handoffs consumed by every row up to and including <phase> -
    every handoff a flow at <phase> has written; none for a phase the table
    does not hold."""
    due = []
    for row_phase, handoff, _, _ in PHASE_TABLE:
        if handoff:
            due.append(handoff)
        if row_phase == phase:
            return due
    return []


def phases_from(phase: str) -> Optional[List[str]]:
    """<phase> and every phase after it, in table order, as bash's
    phases_from was, its bash copy gone; None for a phase the table does not
    hold."""
    if phase not in PHASES:
        return None
    return list(PHASES[PHASES.index(phase):])


def handoffs_written_from(phase: str) -> List[str]:
    """The handoffs whose writer is <phase> or a phase after it, in table
    order - the ones a step back to <phase> makes stale, as bash's
    handoffs_written_from was. plan, a writer though no row, gives every
    handoff; none for a name the writer column does not hold."""
    stale = []
    found = False
    for _, handoff, writer, _ in PHASE_TABLE:
        if not handoff:
            continue
        found = found or writer == phase
        if found:
            stale.append(handoff)
    return stale


def handoff_file_for(phase: str) -> str:
    """The handoff <phase> consumes; dies on a phase with none."""
    handoff = phase_handoff(phase)
    if handoff is None:
        die("no handoff defined for phase: " + phase)
    return handoff


def host_fallbacks_required(state_file: str) -> bool:
    """Whether a handoff must carry `## Host fallbacks`: with no state file
    at <state_file> there is no older flow to spare, and a flow started
    before 1.0.0, its state with no host_fallbacks true, keeps validating
    without it, as bash host_fallbacks_required."""
    if not os.path.isfile(state_file):
        return True
    state = flow_state_get_many(state_file, ("host_fallbacks",))
    return state is not None and state["host_fallbacks"] == "true"


def _required_sections(name: str, state_file: str) -> Optional[List[str]]:
    """The headings the handoff file <name> must hold - its phase table
    row's sections, then `## Host fallbacks` where host_fallbacks_required -
    or None when no row consumes <name>."""
    for _, handoff, _, sections in PHASE_TABLE:
        if handoff and handoff == name:
            required = ["## " + section for section in sections]
            if host_fallbacks_required(state_file):
                required.append("## Host fallbacks")
            return required
    return None


def handoff_required(name: str, state_file: str) -> List[str]:
    """The headings the handoff file <name> must hold, in order, as bash
    handoff_required prints them; dies on a name no phase table row
    consumes."""
    required = _required_sections(name, state_file)
    if required is None:
        die("unknown handoff file: " + name)
    return required


def handoff_report(path: str, state_file: str, env: Mapping[str, str], name: str = "",
                   autopilot: str = "") -> Tuple[List[str], int]:
    """The single statement of what a valid handoff is, bash handoff_report:
    one line per required section of the handoff at <path>, each `ok
    <heading>` or `FAIL <problem>`, and status 1 when any failed, else 0.
    <name> is the handoff file name the sections are looked up by, the
    file's own basename unless given: an autopilot scratch file is not named
    as its handoff. The plan's `## Autopilot` block (autopilot_block_report)
    is checked, and required, in an autopilot session or when <autopilot> is
    `autopilot`. A name no row consumes is no lines and status 1, after bash's
    `orch: unknown handoff file` line on stderr - never a death. The file is
    read once; one that cannot be read reads as empty."""
    base = name or os.path.basename(path)
    required = _required_sections(base, state_file)
    if required is None:
        warn("unknown handoff file: " + base)
        return [], 1
    text = read_raw(path) or ""
    lines = []
    for heading in required:
        if section_count(text, heading) == 0:
            lines.append("FAIL missing section: " + heading)
        elif not trim("".join(section_body(text, heading))):
            lines.append("FAIL empty section: " + heading)
        else:
            lines.append("ok " + heading)
    failed = any(line.startswith("FAIL ") for line in lines)
    if base == "01-plan.md" and (autopilot_active(env) or autopilot == "autopilot"):
        block, block_failed = autopilot_block_report(text)
        lines += block
        failed = failed or block_failed == 1
    return lines, 1 if failed else 0


def handoff_check(path: str, state_file: str, env: Mapping[str, str], show_ok: str = "",
                  name: str = "", autopilot: str = "") -> int:
    """Checks the handoff at <path> and relays the verdict on stdout in the
    aligned `ok    ` / `FAIL  ` form, bash handoff_check: every FAIL line,
    and the ok lines too when <show_ok> is `ok`. A missing file is one FAIL
    line and status 2, an invalid one status 1, a valid one 0. It never dies
    - the status is the verdict. <name> and <autopilot> are
    handoff_report's."""
    if not os.path.isfile(path):
        stdout_write("FAIL  handoff not found: %s\n" % path)
        return 2
    lines, status = handoff_report(path, state_file, env, name, autopilot)
    for line in lines:
        if line.startswith("ok ") and show_ok == "ok":
            stdout_write("ok    %s\n" % line[3:])
        elif line.startswith("FAIL "):
            stdout_write("FAIL  %s\n" % line[5:])
    return status


def handoff_store(env: Mapping[str, str]) -> str:
    """The adapter this session's handoffs live in: `comment` in an
    autopilot session and `file` otherwise."""
    return "comment" if autopilot_active(env) else "file"


# handoff_ready's three answers: ready; not ready, its finding given; ready if
# gh is, which is for the caller to gate.
READY, NOT_READY, READY_IF_GH = 0, 1, 2


def handoff_ready(env: Mapping[str, str], issue: str) -> Tuple[int, str]:
    """Doctor's readiness check, the adapter's: (READY, "") for the file
    adapter, which needs nothing; the comment adapter, for the flow's
    recorded <issue>, is (NOT_READY, its finding) with none recorded, else
    (READY_IF_GH, "")."""
    if handoff_store(env) == "file":
        return READY, ""
    if not issue:
        return NOT_READY, ("autopilot session, but no issue is recorded - the handoff comments"
                           " cannot be read.")
    return READY_IF_GH, ""


# handoff_comment_fetch_due's three answers, handoff_fetch_due's too: every
# due copy fetched; the comments unread, gh's reason given; a copy unwritten,
# its line on stderr.
FETCHED, COMMENTS_UNREAD, COPY_UNWRITTEN = 0, 1, 2


def handoff_fetch_due(gh_of, env: Mapping[str, str], root: str, phase: str,
                      issue: str) -> Tuple[int, str]:
    """Fetches every handoff due at <phase> where the adapter keeps them
    elsewhere than the handoff directory of the checkout at <root>: the file
    adapter has nothing to fetch, (FETCHED, ""); the comment adapter reads the
    recorded <issue>'s comments once, through the gh adapter <gh_of> makes,
    as handoff_comment_fetch_due answers. Never dies."""
    if handoff_store(env) == "file":
        return FETCHED, ""
    return handoff_comment_fetch_due(gh_of(), issue, phase, handoff_scratch_dir(root))


def handoff_doctor_missing(env: Mapping[str, str], name: str, issue: str) -> str:
    """Doctor's finding for the handoff file <name> missing, the adapter's:
    the file adapter names the file; the comment adapter names its comment
    missing on issue #<issue>, the flow's recorded issue."""
    if handoff_store(env) == "file":
        return "handoff %s is missing - the phase that writes it has already run." % name
    return ("handoff %s comment is missing on issue #%s - the phase that writes it has already"
            " run." % (_stem(name), issue))


def handoff_fetched(env: Mapping[str, str], root: str, name: str) -> Tuple[str, bool]:
    """The lookup that does not fetch: the readable path of the handoff file
    <name> in the checkout at <root> as of the last handoff_fetch_due, and
    whether it is there - the handoff directory's file for the file adapter,
    the scratch copy for the comment adapter. It never dies."""
    directory = handoff_dir(root) if handoff_store(env) == "file" else handoff_scratch_dir(root)
    path = "%s/%s" % (directory, name)
    return path, os.path.isfile(path)


def handoff_comment_write(entries: List[Entry], name: str, path: str) -> int:
    """Writes the body of the newest comment tagged for <name> in the
    timeline <entries>, marker stripped, to <path>: 0; 1, <path> untouched,
    when there is none or the newest is retired; 2, <path> untouched, after
    one `orch: could not write <path>` line on stderr, when the write fails.
    Never dies."""
    index = timeline_handoff(entries, name)
    if index is None:
        return 1
    raw = timeline_body(entries, index).rstrip("\n")
    if not file_write_atomic(path, raw + "\n" if raw else ""):
        warn("could not write " + path)
        return 2
    return 0


def handoff_comment_fetch_due(gh, issue: str, phase: str, scratch: str) -> Tuple[int, str]:
    """Clears the scratch copy of every handoff due at <phase>, reads
    <issue>'s comments once and writes each live one to <scratch>:
    (FETCHED, ""); (COMMENTS_UNREAD, gh's reason, "" for an answer that is
    no comment list) when the comments cannot be read, leaving no copy;
    (COPY_UNWRITTEN, "") when a copy cannot be written, its line on stderr,
    after the others are written."""
    due = handoffs_due(phase)
    for handoff in due:
        rm_f("%s/%s" % (scratch, handoff))
    entries, reason = timeline_read(gh, issue)
    if entries is None:
        return COMMENTS_UNREAD, reason
    status = FETCHED
    for handoff in due:
        if handoff_comment_write(entries, _stem(handoff), "%s/%s" % (scratch, handoff)) == 2:
            status = COPY_UNWRITTEN
    return status, ""


def handoff_comment_post_url(gh, issue: str, name: str, path: str) -> Optional[str]:
    """Posts the handoff file at <path>, already validated, as a new comment
    on issue #<issue> under <name>'s marker, as bash's
    handoff_comment_post_url does, `autopilot start` its one caller: the
    posted comment's URL, "" where gh printed none. None, after `orch: gh
    could not post the <name> handoff on issue #<issue>: <reason>` on
    stderr, when the post fails. The temp body is removed on every path."""
    unmade = "could not create a temp file for the handoff comment"
    with temp_text_file(marked_comment_write("handoff", name) + (read_raw(path) or ""),
                        unmade, unmade) as body:
        try:
            return gh.issue_comment_url(int(issue), body)
        except GhFailed as failed:
            warn("gh could not post the %s handoff on issue #%s: %s"
                 % (name, issue, gh_reason(failed.stderr)))
            return None


def _stem(name: str) -> str:
    """The handoff file <name> without its `.md`, as bash's ${name%.md}."""
    return name[:-3] if name.endswith(".md") else name


def handoff_comment_missing(issue: str, stem: str, hint: str = "") -> NoReturn:
    """Dies naming the handoff <stem> (its file name without the `.md`)
    missing from issue #<issue>'s comments, bash handoff_comment_missing; a
    <hint> follows ` - post it with handoff post `."""
    die("issue #%s has no %s handoff comment%s"
        % (issue, stem, " - post it with handoff post " + hint if hint else ""))


def _comment_copy_or_die(status: int, path: str, issue: str, stem: str, hint: str = "") -> None:
    """Reacts to a handoff comment's copy to <path>: exits 1 for <status>
    COPY_UNWRITTEN, a copy not written (its line already on stderr), and with no file at
    <path> dies naming issue #<issue>'s missing <stem> handoff comment, as
    bash handoff_comment_status does."""
    if status == COPY_UNWRITTEN:
        raise SystemExit(1)
    if not os.path.isfile(path):
        handoff_comment_missing(issue, stem, hint)


def _handoff_file_read(name: str, hint: str, root: str) -> str:
    path = "%s/%s" % (handoff_dir(root), name)
    if not os.path.isfile(path):
        die("handoff not found: %s/%s.md%s"
            % (handoff_dir(root), _stem(name), " - write it " + hint if hint else ""))
    return path


def _handoff_comment_read(name: str, hint: str, gh_of, env: Mapping[str, str], root: str) -> str:
    issue = require_issue(flow_state_file(root), env)["issue"]
    path = "%s/%s" % (handoff_scratch_dir(root), name)
    rm_f(path)
    entries, reason = timeline_read(gh_of(), issue)
    if entries is None:
        timeline_die(issue, reason)
    _comment_copy_or_die(handoff_comment_write(entries, _stem(name), path),
                         path, issue, _stem(name), hint)
    return path


def handoff_read(name: str, hint: str, gh_of, env: Mapping[str, str], root: str) -> str:
    """The dying read, as bash's handoff_read was, its bash copy gone: the
    readable path of the handoff file <name> in the checkout at <root>, as
    this session's adapter (handoff_store) finds it, <hint> naming the
    caller's situation in the missing message. The file adapter dies `handoff not found: <path> -
    write it <hint>` on a missing file. The comment adapter requires the
    recorded issue, reads its comments once through the gh adapter <gh_of>
    makes and copies the live one to the scratch directory: a failed read
    dies with gh's reason, a copy not written exits 1 after its line, and
    no live comment dies `issue #<n> has no <stem> handoff comment - post it
    with handoff post <hint>`."""
    if handoff_store(env) == "file":
        return _handoff_file_read(name, hint, root)
    return _handoff_comment_read(name, hint, gh_of, env, root)


def handoff_invalid(name: str, hint: str, env: Mapping[str, str], root: str,
                    issue: str) -> NoReturn:
    """Dies saying the handoff <name> is not valid, the adapter's message,
    as bash handoff_invalid was: the file adapter's names the file in the checkout
    at <root>, with a fix to make; the comment adapter's names the comment
    on issue #<issue>, the flow's issue the caller holds, with a fix to
    post. Either ends `, <hint>`."""
    tail = ", " + hint if hint else ""
    if handoff_store(env) == "file":
        die("%s/%s is not valid - fix it%s" % (handoff_dir(root), name, tail))
    die("the %s comment on issue #%s is not valid - post a fixed one%s" % (_stem(name), issue, tail))


def handoff_path(phase: str, gh, env: Mapping[str, str], root: str) -> Tuple[str, bool]:
    """`handoff path <phase>`: the path of the handoff <phase> consumes, as
    the adapter resolves it, and whether it is there. The file adapter
    answers False for a missing file; the comment adapter, which requires the
    recorded issue, dies instead - on a failed comments read with gh's
    reason, exit 1 alone after a copy not written, and naming the issue's
    missing handoff comment."""
    handoff = handoff_file_for(phase)
    if handoff_store(env) == "file":
        path = "%s/%s" % (handoff_dir(root), handoff)
        return path, os.path.isfile(path)
    state_file = flow_state_file(root)
    issue = require_issue(state_file, env)["issue"]
    scratch = handoff_scratch_dir(root)
    status, reason = handoff_comment_fetch_due(gh, issue, phase, scratch)
    if status == COMMENTS_UNREAD:
        timeline_die(issue, reason)
    path = "%s/%s" % (scratch, handoff)
    _comment_copy_or_die(status, path, issue, _stem(handoff))
    return path, True


def handoff_file_retire(label: str, names: Sequence[str], root: str) -> None:
    """Moves each of the handoffs <names> that exists into the handoff
    directory's <label> folder, made only when there is something to move;
    a folder already holding one of them is refused before any move, one
    that merely exists is fine - as bash's handoff_file_retire was. The redo
    spec's late move of the spec markers goes through it too."""
    directory = handoff_dir(root)
    move_files_aside(directory, "%s/%s" % (directory, label), "a retired handoff", names)


def handoff_retire(label: str, names: Sequence[str], gh_of, env: Mapping[str, str],
                   root: str) -> None:
    """Sets the handoffs <names> of the checkout at <root> aside, as a redo
    does, through this session's adapter (handoff_store), as bash's
    handoff_retire was. The file adapter moves each existing one into the
    handoff directory's <label> folder. The comment adapter ignores the
    label: it requires the recorded issue - with no handoff named too - then
    retires each handoff on it, through the gh adapter <gh_of> makes only
    when one is named (_handoff_comment_retire)."""
    if handoff_store(env) == "file":
        handoff_file_retire(label, names, root)
        return
    issue = require_issue(flow_state_file(root), env)["issue"]
    if names:
        _handoff_comment_retire(gh_of(), issue, names)


def _handoff_comment_retire(gh, issue: str, names: Sequence[str]) -> None:
    """Retires each of the handoffs <names> by posting a newer comment
    tagged retired on issue #<issue>, as bash's handoff_comment_retire was. The
    comments are read once, before any post - a failed read dies with gh's
    reason - and every handoff is decided from that read: one with no
    comment, or whose newest is already retired, posts nothing, so a redo
    that died partway is finished by the next. A post that fails dies naming
    the comments already posted."""
    entries, reason = timeline_read(gh, issue)
    if entries is None:
        timeline_die(issue, reason)
    posted: List[str] = []
    for name in names:
        stem = _stem(name)
        if timeline_handoff(entries, stem) is None:
            continue
        unmade = "could not create a temp file for the retired comment"
        with temp_text_file(marked_comment_write("handoff", stem, "retired") + RETIRED_TEXT,
                            unmade, unmade) as path:
            try:
                gh.issue_comment(int(issue), path)
            except GhFailed as failed:
                die("could not retire the %s handoff on issue #%s: %s - comments posted: %s;"
                    " the recorded phase is unchanged, so a re-run retires the rest"
                    % (stem, issue, gh_reason(failed.stderr), ", ".join(posted) or "none"))
        posted.append(stem)
