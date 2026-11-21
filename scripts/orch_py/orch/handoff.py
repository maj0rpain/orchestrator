"""The handoff concept's module (scripts/orch/handoff.sh), kept to what the
review-pass noun reads a record's text with: the lines under a heading, and
how many times a heading stands outside any code fence.

A line inside a code fence (orch.common.fenced), its delimiters included, is
never a heading: it neither opens nor closes a section, and inside an open
one it is part of the body.
"""
from __future__ import annotations

from typing import List

from orch.common import fenced, lines_of


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
