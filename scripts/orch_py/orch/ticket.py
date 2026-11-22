"""The ticket concept's Python copies, kept to what the spec-review noun
reaches so far: a breakdown's sub-issue listing (ticket_sub_issues) and the
state of one ticket in it, and the reads of a body's markdown - the numbers a
ticket's `## Blocked by` section lists, and the `## Ticket` heading a
collapsed breakdown sits under (ADR-0012), detected and cut. Each is copied
from the bash ticket module under its bash name, with its messages; the bash
copies stay while a bash caller remains (ADR-0067).

The body reads take the body as awk reads it, one line per newline, a last
line with no newline included, and each line's trailing CR ignored, so a
body edited on the web reads as its LF twin. A heading inside a code fence
(orch.common's fenced) is text, never a heading.
"""
from __future__ import annotations

import re
from typing import List, Sequence

from orch.common import die, fenced, lines_of, plain_number
from orch.gh import SubIssue, gh_or_die

# The fixed heading line a collapsed ticket breakdown sits under (ADR-0012).
TICKET_HEADING = "## Ticket"

# The heading of a ticket body's section listing its blockers.
BLOCKED_BY_HEADING = "## Blocked by"

# A line that is a `#` or `##` heading: what ends a section.
_SECTION_END = re.compile(r"##?([ \t]|$)")


def ticket_sub_issues(gh, parent: str, code: int = 1) -> List[SubIssue]:
    """<parent>'s sub-issues, open or closed, in the order GitHub published
    them - the listing the ticket commands read (#394). A <parent> that is no
    plain number is refused before asking GitHub, always exit 1; a GitHub
    that cannot list them dies in the gh failure contract's grammar, exit
    <code>."""
    if not plain_number(parent):
        die("parent must be a plain issue number, got: " + parent)
    return gh_or_die("list sub-issues of #" + parent, gh.sub_issues, int(parent), code=code)


def ticket_listing_state(listing: Sequence[SubIssue], n: str) -> str:
    """The state, OPEN or CLOSED, of the sub-issue in <listing> numbered
    <n>, compared as text, as bash compares it; "" when none is."""
    for row in listing:
        if str(row.number) == n:
            return row.state
    return ""


def _read(body: str):
    """<body>'s lines with their trailing CR dropped, and the fence state of
    each."""
    lines = [line[:-1] if line.endswith("\r") else line for line in lines_of(body)]
    return lines, fenced(lines)


def has_ticket_heading(body: str) -> bool:
    """Whether <body> has a line that is exactly TICKET_HEADING outside a
    code fence - the test `ticket exists` uses, and the line
    strip_ticket_sections cuts from."""
    lines, fences = _read(body)
    return any(not f and line == TICKET_HEADING for line, f in zip(lines, fences))


def strip_ticket_sections(body: str) -> str:
    """<body> with every `## Ticket` section removed - the heading line
    outside a code fence, through the line before the next `#` or `##`
    heading outside a code fence, or the end of the body - and the blank
    lines a section at the end leaves behind trimmed. Every other line is
    kept byte for byte, CRLF ends and trailing blank lines included, each
    ending in a newline, as awk prints it."""
    out = []
    held = ""
    skip = False
    raw = lines_of(body)
    lines, fences = _read(body)
    for original, line, f in zip(raw, lines, fences):
        if skip and not f and _SECTION_END.match(line) and line != TICKET_HEADING:
            skip = False
        if not f and line == TICKET_HEADING:
            skip = True
            continue
        if skip:
            continue
        if line == "":
            held += original + "\n"
            continue
        out.append(held + original + "\n")
        held = ""
    if not skip:
        out.append(held)
    return "".join(out)


def blocked_by_section_numbers(body: str) -> List[str]:
    """The blocker numbers the first `## Blocked by` section outside a code
    fence lists in <body>, as written: its `- #<n>` lines, the section
    running to the next `#` or `##` heading outside a code fence, or the end
    of the body. A body with no section, or one reading `None (can start
    immediately)`, lists none."""
    numbers = []
    in_section = done = False
    lines, fences = _read(body)
    for line, f in zip(lines, fences):
        if in_section and not f and _SECTION_END.match(line):
            in_section = False
        if not done and not f and line == BLOCKED_BY_HEADING:
            in_section = done = True
            continue
        match = re.match(r"- #([0-9]+)", line) if in_section else None
        if match:
            numbers.append(match.group(1))
    return numbers
