"""The Known items concept's module (scripts/orch/known-items.sh): splitting
a record's text into entries, appending them as tagged bullets, and writing
the known-items file a review pass's reviewers read.

An entry is a top-level `- ` bullet joined with its indented continuation
lines by single spaces, its leading `- ` stripped, or a non-blank line at the
margin that is no bullet. A line inside a code fence (orch.common.fenced),
its delimiters included, is a continuation of the open bullet whatever its
column, and with no bullet open an entry of its own: it never ends an entry
or opens one. An entry reading None, None. or None declined. is a source
saying it has nothing, and is dropped.

The appenders return the bullet lines bash's appenders append to a variable;
the Python caller concatenates them.
"""
from __future__ import annotations

import re
from typing import Iterable, List

from orch.common import die, fenced, file_write_atomic, lines_of
from orch.handoff import section_body

# The blanks awk's [[:space:]] matches.
BLANKS = " \t\n\v\f\r"
_NOTHING = re.compile(r"None( declined)?\.?")


def text_entries(lines: Iterable[str]) -> List[str]:
    """The entries of <lines>, in order."""
    trimmed = [line.rstrip(BLANKS) for line in lines]
    entries: List[str] = []
    entry = ""
    bullet = False

    def flush() -> None:
        nonlocal entry, bullet
        if entry and not _NOTHING.fullmatch(entry):
            entries.append(entry)
        entry = ""
        bullet = False

    for line, fence in zip(trimmed, fenced(trimmed)):
        if not line:
            continue
        if fence or line[0] in BLANKS:
            if bullet:
                entry += " " + line.lstrip(BLANKS)
            else:
                flush()
                entry = line.lstrip(BLANKS)
                flush()
        elif line.startswith("- "):
            flush()
            entry = line[2:].lstrip(BLANKS)
            bullet = True
        else:
            flush()
            entry = line
            flush()
    flush()
    return entries


def section_entries(text: str, heading: str) -> List[str]:
    """The entries under <heading> in <text>, as section_body reads them and
    text_entries splits them."""
    return text_entries(section_body(text, heading))


def entries_append_from(entries: Iterable[str], tag: str) -> str:
    """The appenders' one loop: one `- ` bullet line per entry, each ending
    ` - <tag>` when <tag> is non-empty."""
    suffix = " - " + tag if tag else ""
    return "".join("- %s%s\n" % (entry, suffix) for entry in entries)


def section_entries_append(text: str, heading: str, tag: str = "") -> str:
    """entries_append_from for the entries under <heading> in <text>."""
    return entries_append_from(section_entries(text, heading), tag)


def text_entries_append(text: str, tag: str = "") -> str:
    """entries_append_from for every entry of the whole of <text>."""
    return entries_append_from(text_entries(lines_of(text)), tag)


def known_items_write(path: str, deviations: str, known: str) -> None:
    """Writes a known-items file to <path>, overwriting it - `## Deviations`
    then `## Known items`, each heading's bullet lines, or None. when it has
    none - built beside <path> and moved into place, so a failed write leaves
    <path> as it was; dies when it cannot write."""
    text = "## Deviations\n%s## Known items\n%s" % (deviations or "None.\n", known or "None.\n")
    if not file_write_atomic(path, text.rstrip("\n") + "\n"):
        die("could not write the known items to %s" % path)
