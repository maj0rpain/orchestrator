"""The handoff concept's module (scripts/orch/handoff.sh), kept to what the
review-pass noun reads a record's text with - the lines under a heading, and
how many times a heading stands outside any code fence - and to `handoff
path`, which the spec-review noun's prompt takes the plan handoff from.

A line inside a code fence (orch.common.fenced), its delimiters included, is
never a heading: it neither opens nor closes a section, and inside an open
one it is part of the body.

The phase table is a copy of the bash side's (PHASE_TABLE), which Python
does not read, pinned to it by tests/test_handoff.py's drift test. `handoff
path` resolves through the Handoff store's adapter handoff_store chooses per
call: the file adapter, the handoff directory's files, and in an autopilot
session the comment adapter, marked comments on the recorded issue, read
once and copied to the scratch directory to be read as files.
"""
from __future__ import annotations

import os
from typing import List, Mapping, Optional, Tuple

from orch.autopilot import autopilot_active
from orch.common import ORCH_DIR_NAME, die, fenced, file_write_atomic, lines_of, rm_f, warn
from orch.flow_state import flow_state_file, require_issue
from orch.issue_timeline import Entry, timeline_body, timeline_die, timeline_handoff, timeline_read

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


def handoff_file_for(phase: str) -> str:
    """The handoff <phase> consumes; dies on a phase with none."""
    handoff = phase_handoff(phase)
    if handoff is None:
        die("no handoff defined for phase: " + phase)
    return handoff


def handoff_store(env: Mapping[str, str]) -> str:
    """The adapter this session's handoffs live in: `comment` in an
    autopilot session and `file` otherwise."""
    return "comment" if autopilot_active(env) else "file"


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
    <issue>'s comments once and writes each live one to <scratch>: (0, "");
    (1, gh's reason, "" for an answer that is no comment list) when the
    comments cannot be read, leaving no copy; (2, "") when a copy cannot be
    written, its line on stderr, after the others are written."""
    due = handoffs_due(phase)
    for handoff in due:
        rm_f("%s/%s" % (scratch, handoff))
    entries, reason = timeline_read(gh, issue)
    if entries is None:
        return 1, reason
    status = 0
    for handoff in due:
        if handoff_comment_write(entries, handoff[:-3], "%s/%s" % (scratch, handoff)) == 2:
            status = 2
    return status, ""


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
    if status == 1:
        timeline_die(issue, reason)
    if status != 0:
        raise SystemExit(1)
    path = "%s/%s" % (scratch, handoff)
    if not os.path.isfile(path):
        die("issue #%s has no %s handoff comment" % (issue, handoff[:-3]))
    return path, True
