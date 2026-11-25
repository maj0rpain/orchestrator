"""orch.sh's glossary noun (ADR-0067): the root GLOSSARY.md, read an entry at
a time, and the one parser of its entry grammar, which docs_lint's
glossary_entry reads a fixture file through too (show_file).

A reader needs only the entries for the terms in front of it, not the whole
glossary, so the entry grammar lives here, tested, rather than re-derived in
each skill. An entry starts at a **<Term>**: line, optionally after a "- " or
"* " bullet, with nothing after it or the definition on the same line;
numbered lists and an unbolded Term: are no entries. It runs up to the next
entry start, the next line starting with #, or end of file, its trailing blank
lines trimmed. An entry's _Avoid_: line, leading whitespace allowed, lists its
aliases, split at commas outside parentheses, a trailing period dropped; an
alias ends at its first (, and one with a parenthetical note is scoped.

Every file is read as UTF-8 with surrogateescape, so bytes that are not UTF-8
never raise, and one that cannot be opened reads as empty, as bash's awk read
it. Case-folding, whitespace and word characters are Python's Unicode defaults
(str.lower, \\s, \\w), as gawk's are in a UTF-8 locale.

Every verb keeps the bash noun's arguments, usage lines, stdout, exit codes and
`orch:` messages. Every op reads GLOSSARY.md at the repo root only; one that
gives no entries is an error, never "no terms", so no caller mistakes an
unreadable glossary for an empty one. Exit 2 is an error, so show keeps exit 1
for "no entry for a term".
"""
from __future__ import annotations

import os
import re
import sys
from typing import List, Mapping, NamedTuple, Optional, Tuple

from orch.common import die, lines_of, read_raw, stderr_write, stdout_write, warn
from orch.git import Git
from orch.root import checkout_root

# The verbs, in the unknown-op message's order. docs_lint.sh reads this line
# as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "terms|show|match"

NO_ENTRIES = ("GLOSSARY.md has no entries orch.sh can read (an entry starts at a"
              " **Term**: line, optionally bulleted)")

_ENTRY_START = re.compile(r"(?:[-*] )?\*\*([^*]+)\*\*:(?:\s.*)?")
_AVOID = re.compile(r"\s*_Avoid_:")
_AVOID_LABEL = len("_Avoid_:")
_SPACE_RUN = re.compile(r"\s+")
_WORD_CHAR = re.compile(r"\w")


class Alias(NamedTuple):
    """One _Avoid_: alias: its name, and whether it had a parenthetical note."""

    name: str
    scoped: bool


class Entry(NamedTuple):
    """One entry: its term, its lines as written (the start line first, its
    trailing blank lines trimmed) and its aliases in order."""

    term: str
    lines: List[str]
    aliases: List[Alias]

    def text(self) -> str:
        """The entry as show prints it: each line ending in a newline."""
        return "".join(line + "\n" for line in self.lines)


def _blank(line: str) -> bool:
    return line.strip() == ""


def _alias_of(piece: str) -> Optional[Alias]:
    """The alias one comma-separated piece names - cut at its first (, and
    scoped when it had one - or None for an empty one."""
    cut = piece.find("(")
    name = (piece if cut < 0 else piece[:cut]).strip()
    return Alias(name, cut >= 0) if name else None


def _aliases_of(line: str) -> List[Alias]:
    """The aliases an _Avoid_: <line> lists: split at commas at parenthesis
    depth 0, a trailing . dropped first."""
    rest = line.strip()[_AVOID_LABEL:].strip()
    if rest.endswith("."):
        rest = rest[:-1]
    pieces = []
    depth = 0
    piece = ""
    for char in rest:
        if char == "(":
            depth += 1
        elif char == ")" and depth > 0:
            depth -= 1
        if char == "," and depth == 0:
            pieces.append(piece)
            piece = ""
        else:
            piece += char
    pieces.append(piece)
    return [alias for alias in map(_alias_of, pieces) if alias is not None]


def parse(text: str) -> List[Entry]:
    """The entries of glossary <text>, in glossary order; none when it gives
    none."""
    entries: List[Entry] = []
    current: Optional[Entry] = None
    for line in lines_of(text):
        start = _ENTRY_START.fullmatch(line)
        if start is not None:
            current = Entry(start.group(1), [line], [])
            entries.append(current)
        elif line.startswith("#"):
            current = None
        elif current is not None:
            current.lines.append(line)
            if _AVOID.match(line):
                current.aliases.extend(_aliases_of(line))
    for entry in entries:
        while _blank(entry.lines[-1]):
            entry.lines.pop()
    return entries


def read_entries(path: str) -> List[Entry]:
    """The entries of the glossary file at <path>; none when it cannot be
    opened."""
    return parse(read_raw(path) or "")


def find(entries: List[Entry], want: str) -> Tuple[Optional[Entry], bool]:
    """The entry <want> names, case ignored - by its term, else by one of its
    aliases, scoped ones included - and whether it was found by an alias;
    (None, False) when it names none."""
    want = want.lower()
    for entry in entries:
        if entry.term.lower() == want:
            return entry, False
    for entry in entries:
        for alias in entry.aliases:
            if alias.name.lower() == want:
                return entry, True
    return None, False


def _squash(text: str) -> str:
    return _SPACE_RUN.sub(" ", text.lower())


def _mentions(text: str, word: str) -> bool:
    """Whether the squashed <text> mentions the squashed <word>: an occurrence
    not preceded by a word character, whatever follows it."""
    if not word:
        return False
    at = text.find(word)
    while at >= 0:
        if at == 0 or not _WORD_CHAR.match(text[at - 1]):
            return True
        at = text.find(word, at + 1)
    return False


def matches(entries: List[Entry], texts: List[str]) -> List[Entry]:
    """The entries <texts> mention, in glossary order: by term or by an
    unscoped alias, over every text's lines joined with a space, lower-cased
    and whitespace-squashed."""
    text = _squash("".join(" " + line for each in texts for line in lines_of(each)))
    return [
        entry for entry in entries
        if _mentions(text, _squash(entry.term))
        or any(_mentions(text, _squash(alias.name))
               for alias in entry.aliases if not alias.scoped)
    ]


def show_file(path: str, term: str) -> str:
    """The entry <term> finds, by name and then by alias, in the glossary file
    at <path>, read as the CLI reads GLOSSARY.md, as show prints it; empty
    when the file gives no entries or the term finds none. Needs no git
    repo."""
    entry, _ = find(read_entries(path), term)
    return entry.text() if entry is not None else ""


def _entries_or_die(path: str) -> List[Entry]:
    entries = read_entries(path)
    if not entries:
        die(NO_ENTRIES, 2)
    return entries


def _terms(args: List[str], glossary: str) -> int:
    if args:
        die("usage: orch.sh glossary terms", 2)
    if not os.path.isfile(glossary):
        return 0
    stdout_write("".join(entry.term + "\n" for entry in _entries_or_die(glossary)))
    return 0


def _show(args: List[str], glossary: str, root: str) -> int:
    """Each found entry once, in the order asked, one blank line between;
    then one warn per term with no entry, in argument order, and exit 1."""
    if not args:
        die("usage: orch.sh glossary show <term>...", 2)
    if not os.path.isfile(glossary):
        die("no GLOSSARY.md at %s" % root, 2)
    entries = _entries_or_die(glossary)
    shown: List[Entry] = []
    missing: List[str] = []
    for want in args:
        entry, by_alias = find(entries, want)
        if entry is None:
            missing.append(want)
            continue
        if by_alias:
            sys.stdout.flush()
            stderr_write("# alias of %s\n" % entry.term)
        if not any(entry is seen for seen in shown):
            stdout_write(("\n" if shown else "") + entry.text())
            shown.append(entry)
    for want in missing:
        warn("no glossary entry for '%s'" % want)
    return 1 if missing else 0


def _match(args: List[str], glossary: str) -> int:
    if not args:
        die("usage: orch.sh glossary match <file>...", 2)
    for path in args:
        if not (os.path.isfile(path) and os.access(path, os.R_OK)):
            die("no such file '%s'" % path, 2)
    if not os.path.isfile(glossary):
        return 0
    entries = _entries_or_die(glossary)
    found = matches(entries, [read_raw(path) or "" for path in args])
    stdout_write("\n".join(entry.text() for entry in found))
    return 0


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> int:
    """`orch.sh glossary <op> ...`: the real git adapter and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown glossary op: %s (want %s)" % (op or "<none>", OPS), 2)
    glossary = root + "/GLOSSARY.md"
    if op == "terms":
        return _terms(argv[1:], glossary)
    if op == "show":
        return _show(argv[1:], glossary, root)
    return _match(argv[1:], glossary)
