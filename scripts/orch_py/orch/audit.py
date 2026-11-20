"""The audit module (scripts/orch/audit.sh), kept to what the issue noun
uses: an audit-filed body's drift line.

An audit-filed body has exactly one **Audited at:** line, its value
hexadecimal, and at least one well-formed **Location:** line. Its drift line
says which of the cited files changed since the audited commit: compared
tree to tree with HEAD, so no ancestry is needed, uncommitted changes are not
counted, and a renamed file is listed as the path the body cites. The body is
untrusted: only a hexadecimal value reaches git as the commit, and every path
reaches it as a literal one (orch.git).
"""
from __future__ import annotations

import re
from typing import List, Optional, Tuple

MARKER = "**Audited at:**"
LOCATION = "**Location:**"
_LOCATION_LINE = re.compile(r"\*\*Location:\*\* `([^`]*)`")
_HEX = re.compile(r"[0-9a-fA-F]+")
_LINES = re.compile(r"[0-9]+(-[0-9]+)?")
_SPACE = " \t\n\r\f\v"


def body_parse(body: str) -> Tuple[List[str], List[str]]:
    """Every **Location:** line's backticked location, in order ("" for a
    line carrying none), and every **Audited at:** line's trimmed value."""
    locations, shas = [], []
    for line in body.split("\n"):
        if line.startswith(LOCATION):
            match = _LOCATION_LINE.fullmatch(line)
            locations.append(match.group(1) if match else "")
        elif line.startswith(MARKER):
            shas.append(line[len(MARKER):].strip(_SPACE))
    return locations, shas


def location_ok(location: str) -> bool:
    """Whether <location> is <file>:<line> or <file>:<start>-<end>, split at
    its last colon."""
    file, colon, lines = location.rpartition(":")
    return bool(colon and file) and _LINES.fullmatch(lines) is not None


def drift_line(body: str, git) -> Optional[str]:
    """The drift line of an audit-filed body - `cited files changed since
    <sha>: ` then none, the changed files joined by ", " in body order, each
    once, or unknown (<reason>) - read through the git adapter <git>; None
    for any other body."""
    locations, shas = body_parse(body)
    if len(shas) != 1 or not _HEX.fullmatch(shas[0]):
        return None
    sha = shas[0]
    cited: List[str] = []
    for location in locations:
        if location_ok(location):
            file = location.rpartition(":")[0]
            if file not in cited:
                cited.append(file)
    if not cited:
        return None
    prefix = "cited files changed since %s:" % sha
    changed = git.changed_paths(sha, cited)
    if changed is None:
        if not git.has_head_commit():
            reason = "no commit on HEAD"
        elif not git.has_commit(sha):
            reason = "commit not in this clone"
        else:
            reason = "git comparison failed"
        return "%s unknown (%s)" % (prefix, reason)
    listed = [file for file in cited if file in changed]
    return "%s %s" % (prefix, ", ".join(listed) if listed else "none")
