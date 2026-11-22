"""A spec-review round's batch file, <dir>/batch.md, and the lens findings
files it cites, <dir>/lens-<lens>.md: their parse and the validation check
and apply share, copied from the bash spec-review module, gone since the
noun's cutover, with its messages and its order of checks.

The batch's grammar is the `@@` lines: the `@@ lens` lines first, then one
entry per item - its findings, comments and quotes, its summary and why, its
options, and each edit's anchor -> replace -> end block, read by the shared
@@ block reader (BlockReader), which the ticket parser reads its blocks with
too. Each line has one trailing CR stripped before it is read (#2547).

Two kinds of violation: a structure violation, or a malformed lens file,
stops the run; a content violation is collected under check, so one run
reports every one it can stand behind (#3456), and dies at once under apply.
Violations holds them, and every stop reports what was collected first.

validate() is the one validation: the batch, the lens files of the lenses
that ran, the citations, the answer's dispositions, and every anchor visited
in batch order - applied to the body when the answer accepts it, else checked
on its own against the body as read - each problem naming its `@@ anchor`
line. check takes the all answer; apply takes the batch question's answer
(answer_dispositions), and the decline reasons the human gave
(reasons_read), which the ticket items' answer reads with the same rule.

An autopilot round's apply runs twice (the spec module's hold): the first,
the hold run, takes every fundamental item as recommended and holds it back;
the second, the resumed run, takes an answer naming the fundamental items
alone, the rest as recommended.
"""
from __future__ import annotations

import os
import re
from typing import Dict, List, NoReturn, Optional, Tuple

from orch.autopilot import autopilot_active
from orch.common import (AT_LINE_ESCAPE_HINT, die, lines_of, plain_number, plain_positive_number,
                         read_raw, trim, warn)

# The lenses, in the lens table's order - the changelog's section order.
SPEC_REVIEW_LENSES = ("fidelity", "consistency", "testability", "implementability")

# The changelog's and the views' heading for a section: Consolidation or a
# lens.
TITLES = {"consolidation": "Consolidation", "fidelity": "Fidelity",
          "consistency": "Consistency", "testability": "Testability",
          "implementability": "Implementability"}

# The most words a @@ summary may hold (#1352), so each line of the compact
# view stays short.
SUMMARY_WORDS = 30

# bash's default IFS, the characters `read` splits words on.
_IFS = " \t\n"


def lens_known(name: str) -> bool:
    """Whether <name> is one of the four lenses, matched whole."""
    return name in SPEC_REVIEW_LENSES


def read_words(text: str, count: int) -> List[str]:
    """<text> split as bash's `read -r` splits a line into <count> names:
    a word each, separated by runs of spaces, tabs or newlines, the last name
    taking the rest, its trailing ones dropped. A name past the words is
    empty."""
    rest = text.strip(_IFS)
    words = []
    for _ in range(count - 1):
        word = re.match(r"[^ \t\n]*", rest).group()
        words.append(word)
        rest = rest[len(word):].lstrip(_IFS)
    words.append(rest)
    return words


def one_line(text: str) -> str:
    """<text> on one line - every line trimmed, the empty ones dropped, the
    rest joined by one space - so a finding or quote copied word for word
    stays one changelog line."""
    return " ".join(line for line in (trim(line) for line in text.split("\n")) if line)


def answer_tokens(answer: str) -> List[str]:
    """An Other-list answer split on its commas, each token trimmed - a
    trailing comma giving an empty last token."""
    tokens = []
    rest = answer + ","
    while rest:
        token, _, rest = rest.partition(",")
        tokens.append(trim(token))
    return tokens


def at_line(line: str) -> Tuple[str, str]:
    """An `@@` line split into its keyword and the rest of the line after
    one space - empty when there is none."""
    rest = line[2:]
    if rest.startswith(" "):
        rest = rest[1:]
    keyword, space, args = rest.partition(" ")
    return keyword, args if space else ""


def is_at_line(line: str) -> bool:
    """Whether <line> is an @@ line: `@@`, or `@@ ` and more."""
    return line == "@@" or line.startswith("@@ ")


def without_cr(line: str) -> str:
    return line[:-1] if line.endswith("\r") else line


def capital_letter(text: str) -> bool:
    return re.fullmatch(r"[A-Z]", text) is not None


class Violations:
    """The violations of one run. Under check (<collect>) a content
    violation is recorded and the run goes on; under apply it dies. stop()
    reports the recorded ones, oldest first, then dies with its own."""

    def __init__(self, collect: bool):
        self.collect = collect
        self.recorded: List[str] = []

    def content(self, message: str) -> None:
        if not self.collect:
            die(message)
        self.recorded.append(message)

    def flush(self) -> None:
        for message in self.recorded:
            warn(message)
        self.recorded = []

    def stop(self, message: str) -> NoReturn:
        self.flush()
        die(message)


# --- the @@ block reader (#2568) ------------------------------------------------


class Block:
    """A finished block: an edit (its anchor, its @@ anchor line and its
    replacement) or a quote."""

    def __init__(self, kind: str, text: str, anchor: str = "", anchor_line: int = 0):
        self.kind = kind
        self.text = text
        self.anchor = anchor
        self.anchor_line = anchor_line


class Malformed(Exception):
    """A block refused: the line to name and the message, without the
    file's prefix; the parser stops with it."""

    def __init__(self, line: int, message: str):
        super().__init__(message)
        self.line = line
        self.message = message


def block_line(line: str) -> str:
    """A block line, with one leading backslash removed when the line is
    backslashes then `@@` (#1945)."""
    stripped = line.lstrip("\\")
    if stripped != line and stripped.startswith("@@"):
        return line[1:]
    return line


class BlockReader:
    """The anchor -> replace -> end machine and the quote block, for the
    batch parser and the ticket parser. A parser opens a block with open(),
    feeds the reader every line of its file, with no CR, and calls finish()
    at end of file. feed() answers "consumed" for a line inside a block,
    "outside" when no block is open, a Block when one finished - a quote
    ended by an @@ line the parser still dispatches - and raises Malformed
    for a block refused."""

    def __init__(self) -> None:
        self.mode = ""
        self.lines: List[str] = []
        self.line = 0
        self.anchor = ""
        self.anchor_line = 0

    def open(self, mode: str, line: int) -> None:
        self.mode, self.lines, self.line = mode, [], line

    def _quote_end(self) -> Block:
        text = "\n".join(self.lines)
        if not trim(text):
            raise Malformed(self.line, "the quote is empty")
        self.mode = ""
        return Block("quote", text)

    def feed(self, line: str, lineno: int):
        if not self.mode:
            return "outside"
        if not is_at_line(line):
            self.lines.append(block_line(line))
            return "consumed"
        keyword, args = at_line(line)
        text = "\n".join(self.lines)
        if self.mode == "anchor":
            if keyword != "replace" or args:
                raise Malformed(lineno, "expected @@ replace to end the anchor begun on line %d,"
                                " got '%s'%s" % (self.line, line, AT_LINE_ESCAPE_HINT))
            if not trim(text):
                raise Malformed(self.line, "the anchor is empty")
            self.anchor, self.anchor_line = text, self.line
            self.open("replace", lineno)
            return "consumed"
        if self.mode == "replace":
            if keyword != "end" or args:
                raise Malformed(lineno, "expected @@ end to end the replacement begun on line %d,"
                                " got '%s'%s" % (self.line, line, AT_LINE_ESCAPE_HINT))
            self.mode = ""
            return Block("edit", text, self.anchor, self.anchor_line)
        return self._quote_end()

    def finish(self) -> Optional[Block]:
        if self.mode in ("anchor", "replace"):
            raise Malformed(self.line, "the @@ %s block is never ended" % self.mode)
        if self.mode == "quote":
            return self._quote_end()
        return None


# --- the batch ------------------------------------------------------------------


class Lens:
    def __init__(self, name: str, state: str, reason: str):
        self.name, self.state, self.reason = name, state, reason


class Edit:
    """An item's or an option's edit: its anchor, the anchor's @@ anchor
    line and its replacement."""

    def __init__(self, anchor: str, line: int, replace: str):
        self.anchor, self.line, self.replace = anchor, line, replace


class Option:
    def __init__(self, letter: str, label: str, line: int):
        self.letter, self.label, self.line = letter, label, line
        self.summary: Optional[str] = None
        self.edit: Optional[Edit] = None


class Finding:
    """An item's `@@ finding <lens> <k>` citation and its line."""

    def __init__(self, lens: str, k: str, line: int):
        self.lens, self.k, self.line = lens, k, line


class Comment:
    def __init__(self, login: str, created: str):
        self.login, self.created = login, created
        self.quote = ""


class Item:
    def __init__(self, n: str, group: str, rec: str, arg: str, mark: str, line: int,
                 fundamental: bool):
        self.n, self.group, self.rec, self.arg = n, group, rec, arg
        self.mark, self.line, self.fundamental = mark, line, fundamental
        self.summary: Optional[str] = None
        self.why: Optional[str] = None
        self.edit: Optional[Edit] = None
        self.resolved: Optional[str] = None
        self.findings: List[Finding] = []
        self.comments: List[Comment] = []
        self.options: List[Option] = []

    def option(self, letter: str) -> Optional[Option]:
        for option in self.options:
            if option.letter == letter:
                return option
        return None


class Batch:
    """A parsed batch: its lens lines in batch order, its items in batch
    order, and, once validate() has read them, the lens files' findings."""

    def __init__(self) -> None:
        self.lenses: List[Lens] = []
        self.items: List[Item] = []
        self.lens_findings: List[Tuple[str, int, str]] = []

    def lens(self, name: str) -> Optional[Lens]:
        for lens in self.lenses:
            if lens.name == name:
                return lens
        return None

    def item(self, n: str) -> Optional[Item]:
        for item in self.items:
            if item.n == n:
                return item
        return None

    def finding_text(self, lens: str, k: str) -> str:
        for name, number, text in self.lens_findings:
            if name == lens and str(number) == k:
                return text
        return ""


def item_check(item: Item, violations: Violations) -> None:
    """Reports, naming the item's header line, each part the item lacks
    that its recommendation needs - each a content violation, so every
    missing part is named."""
    def content(line: int, message: str) -> None:
        violations.content("batch.md line %d: %s" % (line, message))

    n = item.n
    for option in item.options:
        if option.summary is None:
            content(option.line, "item %s option %s has no @@ summary" % (n, option.letter))
        hint = "" if option.letter == item.arg else (
            " - an option not recommended still carries the edit it would make")
        if option.edit is None:
            content(option.line, "item %s option %s has no @@ anchor/@@ replace/@@ end block%s"
                    % (n, option.letter, hint))
    if item.rec in ("apply", "decline"):
        if item.summary is None:
            content(item.line, "item %s has no @@ summary" % n)
        hint = ""
        if item.rec == "decline":
            hint = " - a decline item still carries the edit it declines"
        if item.edit is None:
            content(item.line, "item %s has no @@ anchor/@@ replace/@@ end block%s" % (n, hint))
    elif item.rec == "decision":
        if len(item.options) < 2:
            content(item.line, "decision item %s needs at least two @@ option blocks" % n)
        if item.option(item.arg) is None:
            content(item.line, "decision item %s recommends option %s, which it does not have"
                    % (n, item.arg))
    elif item.rec == "resolved" and item.resolved is None:
        content(item.line, "resolved item %s has no @@ resolved-by line" % n)
    if item.group == "consolidation":
        if not item.comments:
            content(item.line, "consolidation item %s cites no @@ comment" % n)
    elif not item.findings:
        content(item.line, "item %s cites no @@ finding" % n)
    if item.mark == "material" and item.why is None:
        content(item.line, "item %s has no @@ why" % n)


class _BatchParser:
    """batch_parse's state while it reads the file."""

    def __init__(self, violations: Violations, autopilot: bool):
        self.violations = violations
        self.autopilot = autopilot
        self.batch = Batch()
        self.item: Optional[Item] = None
        self.option: Optional[Option] = None
        self.comment: Optional[Comment] = None
        self.quote_wanted = False
        self.reader = BlockReader()

    def stop(self, line: int, message: str) -> NoReturn:
        self.violations.stop("batch.md line %d: %s" % (line, message))

    def content(self, line: int, message: str) -> None:
        self.violations.content("batch.md line %d: %s" % (line, message))

    def mark_check(self, line: int, n: str, rec: str, mark: str) -> None:
        if mark in ("material", "minor"):
            return
        if mark == "fundamental":
            if not self.autopilot:
                self.stop(line, "item %s's mark must be material or minor, got 'fundamental' -"
                          " the mark is accepted only in an autopilot flow" % n)
            return
        if not mark:
            self.stop(line, "@@ item %s ... %s needs its mark, material or minor" % (n, rec))
        self.stop(line, "item %s's mark must be material or minor, got '%s'" % (n, mark))

    def summary_cap(self, line: int, what: str, summary: str) -> None:
        words = [word for word in re.split("[" + _IFS + "]+", summary) if word]
        if len(words) > SUMMARY_WORDS:
            self.content(line, "%s's @@ summary has %d words, more than %d"
                         % (what, len(words), SUMMARY_WORDS))

    def block(self, block: Block) -> None:
        if block.kind == "quote":
            self.comment.quote = block.text
            return
        edit = Edit(block.anchor, block.anchor_line, block.text)
        if self.option is not None:
            self.option.edit = edit
        else:
            self.item.edit = edit

    def line(self, line: str, lineno: int) -> None:
        try:
            outcome = self.reader.feed(line, lineno)
        except Malformed as bad:
            self.stop(bad.line, bad.message)
        if outcome == "consumed":
            return
        if isinstance(outcome, Block):
            self.block(outcome)
            if outcome.kind == "edit":
                return
        if not is_at_line(line):
            if not trim(line):
                return
            self.stop(lineno, "text outside an @@ anchor, @@ replace or @@ quote block")
        keyword, args = at_line(line)
        if self.quote_wanted and keyword != "quote":
            self.stop(lineno, "@@ comment must be followed by @@ quote")
        if keyword not in ("lens", "item") and self.item is None:
            self.stop(lineno, "@@ %s outside an item" % keyword)
        if keyword in ("replace", "end"):
            if self.item.rec == "resolved":
                self.stop(lineno, "a resolved item takes no @@ anchor, @@ replace or @@ end")
            self.stop(lineno, "@@ %s with no @@ anchor open" % keyword)
        handler = self.KEYWORDS.get(keyword)
        if handler is None:
            self.stop(lineno, "unknown line '@@ %s'" % keyword)
        handler(self, args, lineno)

    def kw_lens(self, args: str, lineno: int) -> None:
        if self.item is not None:
            self.stop(lineno, "the @@ lens lines come first, before any item")
        name, state, reason = read_words(args, 3)
        if not lens_known(name):
            self.stop(lineno, "unknown lens '%s' (want one of: %s)"
                      % (name, " ".join(SPEC_REVIEW_LENSES)))
        if self.batch.lens(name) is not None:
            self.stop(lineno, "a second @@ lens line for %s" % name)
        if state in ("ran", "standalone"):
            if reason:
                self.stop(lineno, "@@ lens %s %s takes nothing after it" % (name, state))
            if state != "ran" and name != "fidelity":
                self.stop(lineno, "only fidelity can be standalone")
        elif state == "not-run":
            if not reason:
                self.stop(lineno, "@@ lens %s not-run needs a reason" % name)
        else:
            self.stop(lineno, "@@ lens %s wants ran, not-run <reason> or standalone" % name)
        self.batch.lenses.append(Lens(name, state, reason))

    def kw_item(self, args: str, lineno: int) -> None:
        if self.item is not None:
            item_check(self.item, self.violations)
        n, group, rec, rec_tail = read_words(args, 4)
        if not plain_positive_number(n):
            self.stop(lineno, "item number must be a positive number, got '%s'" % n)
        if self.batch.item(n) is not None:
            self.stop(lineno, "a second item %s" % n)
        if group not in ("consolidation", "contradicts-the-plan") and not lens_known(group):
            self.stop(lineno, "unknown group '%s' (want consolidation, a lens, or"
                      " contradicts-the-plan)" % group)
        mark = arg = ""
        if rec == "apply":
            mark, extra = read_words(rec_tail, 2)
            self.mark_check(lineno, n, rec, mark)
            if extra:
                self.stop(lineno, "@@ item %s ... apply takes nothing after its mark" % n)
        elif rec == "resolved":
            if re.match(r"(material|minor|fundamental)( |$)", rec_tail):
                self.stop(lineno, "@@ item %s ... a resolved item carries no mark" % n)
            if rec_tail:
                self.stop(lineno, "@@ item %s ... resolved takes nothing after it" % n)
        elif rec == "decline":
            mark, arg = read_words(rec_tail, 2)
            self.mark_check(lineno, n, rec, mark)
            if not arg:
                self.stop(lineno, "@@ item %s ... decline needs a reason after its mark" % n)
        elif rec == "decision":
            arg, mark, extra = read_words(rec_tail, 3)
            if not capital_letter(arg):
                self.stop(lineno, "@@ item %s ... decision needs the recommended option's letter,"
                          " A to Z" % n)
            self.mark_check(lineno, n, rec, mark)
            if extra:
                self.stop(lineno, "@@ item %s ... decision takes nothing after its mark" % n)
        else:
            self.stop(lineno, "item %s's recommendation must be apply <mark>, decline <mark>"
                      " <reason>, decision <letter> <mark> or resolved" % n)
        fundamental = mark == "fundamental"
        if fundamental:
            mark = "material"
        if mark == "minor" and rec == "decision":
            self.stop(lineno, "decision item %s is always material, never minor" % n)
        if mark == "minor" and group == "contradicts-the-plan":
            self.stop(lineno, "contradicts-the-plan item %s is always material, never minor" % n)
        self.item = Item(n, group, rec, arg, mark, lineno, fundamental)
        self.option = None
        self.batch.items.append(self.item)

    def kw_summary(self, args: str, lineno: int) -> None:
        item = self.item
        if not args:
            self.stop(lineno, "@@ summary needs its line")
        if item.rec == "resolved":
            self.stop(lineno, "a resolved item carries no @@ summary")
        if self.option is not None:
            self.summary_cap(lineno, "item %s option %s" % (item.n, self.option.letter), args)
            if self.option.summary is not None:
                self.stop(lineno, "a second @@ summary for this option")
            self.option.summary = args
            return
        if item.rec == "decision":
            self.stop(lineno, "a decision item's summaries go under its options")
        self.summary_cap(lineno, "item %s" % item.n, args)
        if item.summary is not None:
            self.stop(lineno, "a second @@ summary for this item")
        item.summary = args

    def kw_why(self, args: str, lineno: int) -> None:
        item = self.item
        if not args:
            self.stop(lineno, "@@ why needs its line")
        if item.rec == "resolved":
            self.stop(lineno, "a resolved item carries no @@ why")
        if item.mark != "material":
            self.stop(lineno, "a minor item carries no @@ why")
        if self.option is not None:
            self.stop(lineno, "@@ why belongs to the item, never under an @@ option")
        if item.why is not None:
            self.stop(lineno, "a second @@ why for this item")
        item.why = args

    def kw_finding(self, args: str, lineno: int) -> None:
        lens, k, extra = read_words(args, 3)
        if not lens or extra:
            self.stop(lineno, "@@ finding wants <lens> <k>")
        if not plain_positive_number(k):
            self.stop(lineno, "@@ finding wants <lens> <k>, k a positive number")
        self.item.findings.append(Finding(lens, k, lineno))

    def kw_comment(self, args: str, lineno: int) -> None:
        login, created, extra = read_words(args, 3)
        if not (login.startswith("@") and len(login) > 1):
            self.stop(lineno, "@@ comment wants @<login> <createdAt>")
        if not created or extra:
            self.stop(lineno, "@@ comment wants @<login> <createdAt>")
        self.comment = Comment(login, created)
        self.item.comments.append(self.comment)
        self.quote_wanted = True

    def kw_quote(self, args: str, lineno: int) -> None:
        if not self.quote_wanted:
            self.stop(lineno, "@@ quote must follow @@ comment")
        if args:
            self.stop(lineno, "@@ quote takes nothing after it; the quote is the lines below it")
        self.quote_wanted = False
        self.reader.open("quote", lineno)

    def kw_resolved_by(self, args: str, lineno: int) -> None:
        item = self.item
        if item.rec != "resolved":
            self.stop(lineno, "@@ resolved-by belongs to a resolved item")
        if item.resolved is not None:
            self.stop(lineno, "a second @@ resolved-by")
        target = self.batch.item(args) if args else None
        if target is None or target is item:
            self.stop(lineno, "@@ resolved-by names '%s', which is no earlier item" % args)
        item.resolved = args

    def kw_option(self, args: str, lineno: int) -> None:
        item = self.item
        if item.rec != "decision":
            self.stop(lineno, "@@ option belongs to a decision item")
        letter, label = read_words(args, 2)
        if not capital_letter(letter):
            self.stop(lineno, "@@ option wants <letter> <label>, the letter A to Z")
        if not label:
            self.stop(lineno, "@@ option %s needs a label" % letter)
        if item.option(letter) is not None:
            self.stop(lineno, "a second option %s" % letter)
        self.option = Option(letter, label, lineno)
        item.options.append(self.option)

    def kw_anchor(self, args: str, lineno: int) -> None:
        item = self.item
        if args:
            self.stop(lineno, "@@ anchor takes nothing after it; the anchor is the lines below it")
        if item.rec == "resolved":
            self.stop(lineno, "a resolved item takes no @@ anchor, @@ replace or @@ end")
        if item.rec == "decision":
            if self.option is None:
                self.stop(lineno, "a decision item's anchors go under its options")
            if self.option.edit is not None:
                self.stop(lineno, "a second @@ anchor for this option")
        elif item.edit is not None:
            self.stop(lineno, "a second @@ anchor for this item")
        self.reader.open("anchor", lineno)

    def finish(self, lineno: int) -> Batch:
        try:
            block = self.reader.finish()
        except Malformed as bad:
            self.stop(bad.line, bad.message)
        if block is not None:
            self.block(block)
        if self.quote_wanted:
            self.stop(lineno, "@@ comment must be followed by @@ quote")
        if self.item is not None:
            item_check(self.item, self.violations)
        for name in SPEC_REVIEW_LENSES:
            if self.batch.lens(name) is None:
                self.violations.stop("batch.md: no @@ lens line for %s - every lens in the table"
                                     " has one" % name)
        return self.batch

    # Each @@ keyword's reader; @@ replace and @@ end are the block
    # reader's, refused here when no anchor is open.
    KEYWORDS = {
        "lens": kw_lens, "item": kw_item, "summary": kw_summary, "why": kw_why,
        "finding": kw_finding, "comment": kw_comment, "quote": kw_quote,
        "resolved-by": kw_resolved_by, "option": kw_option, "anchor": kw_anchor,
    }


def batch_parse(text: str, violations: Violations, autopilot: bool) -> Batch:
    """The batch file's <text> parsed: a structure violation stops, named by
    its line number, after the content violations collected before it; a
    content violation goes to <violations>. The fundamental mark is accepted
    only when <autopilot>, read as material. The citations' ranges are
    checked later, against the lens files."""
    parser = _BatchParser(violations, autopilot)
    lines = lines_of(text)
    for lineno, line in enumerate(lines, 1):
        parser.line(without_cr(line), lineno)
    return parser.finish(len(lines))


def lens_parse(directory: str, lens: str, violations: Violations) -> List[Tuple[str, int, str]]:
    """<directory>/lens-<lens>.md's `@@ finding <k>` blocks, numbered from 1
    in order, as (lens, k, text), or none for the single line `@@ none`;
    stops on a missing file or a malformed line."""
    name = "lens-%s.md" % lens
    text = read_raw("%s/%s" % (directory, name))
    if text is None:
        violations.stop("%s not found in %s - lens %s is marked ran in batch.md"
                        % (name, directory, lens))
    findings: List[List] = []
    none = False
    lines = lines_of(text)
    lineno = 0
    for raw in lines:
        lineno += 1
        line = without_cr(raw)
        if line == "@@ none":
            if findings or none:
                violations.stop("%s line %d: @@ none stands alone in its file" % (name, lineno))
            none = True
        elif line.startswith("@@ finding "):
            if none:
                violations.stop("%s line %d: @@ none stands alone in its file" % (name, lineno))
            if findings and not trim(findings[-1][2]):
                violations.stop("%s line %d: finding %d is empty" % (name, lineno, len(findings)))
            if line[len("@@ finding "):] != str(len(findings) + 1):
                violations.stop("%s line %d: expected @@ finding %d, got '%s'"
                                % (name, lineno, len(findings) + 1, line))
            findings.append([lens, len(findings) + 1, ""])
        elif is_at_line(line):
            violations.stop("%s line %d: unknown line '%s' (want @@ finding <k> or @@ none)"
                            % (name, lineno, line))
        elif findings:
            finding = findings[-1]
            finding[2] = finding[2] + ("\n" if finding[2] else "") + line
        elif trim(line):
            violations.stop("%s line %d: text before the first @@ finding" % (name, lineno))
    if findings and not trim(findings[-1][2]):
        violations.stop("%s line %d: finding %d is empty" % (name, lineno, len(findings)))
    if not findings and not none:
        violations.stop("%s holds no @@ finding and no @@ none" % name)
    return [tuple(finding) for finding in findings]


def findings_check(batch: Batch, violations: Violations) -> None:
    """Reports, naming the batch line, a citation of a lens that did not run
    or past its file's count of findings, and an item in a lens's group when
    that lens did not run; then a finding of a lens that ran which no item
    cites, naming every one at once (#1914)."""
    for item in batch.items:
        for finding in item.findings:
            where = "batch.md line %d: " % finding.line
            if not lens_known(finding.lens):
                violations.content(where + "unknown lens '%s'" % finding.lens)
                continue
            if batch.lens(finding.lens).state != "ran":
                violations.content(where + "cites lens %s, which did not run" % finding.lens)
                continue
            count = sum(1 for lens, _, _ in batch.lens_findings if lens == finding.lens)
            if int(finding.k) > count:
                violations.content(where + "cites finding %s of lens %s, but lens-%s.md holds %d"
                                   % (finding.k, finding.lens, finding.lens, count))
    for item in batch.items:
        if lens_known(item.group) and batch.lens(item.group).state != "ran":
            violations.content("batch.md line %d: item %s is in group %s, which did not run"
                               % (item.line, item.n, item.group))
    cited = {(f.lens, f.k) for item in batch.items for f in item.findings}
    uncited = ["%s %d" % (lens, k) for lens, k, _ in batch.lens_findings
               if (lens, str(k)) not in cited]
    if uncited:
        violations.content("batch.md leaves findings uncited: %s - every lens finding goes in the"
                           " batch, if only as a recommend-decline item" % ", ".join(uncited))


def lens_state_line(lens: Lens) -> str:
    """How a lens line reads in the view and the changelog."""
    if lens.state == "ran":
        return "ran"
    if lens.state == "not-run":
        return "not run - " + lens.reason
    return "not run - standalone review, no plan to check against"


def occurrences(text: str, needle: str) -> int:
    """0, 1 or 2 - how often <needle> occurs in <text>, counting no further
    than two."""
    return min(text.count(needle), 2)


class Edited:
    """A text as read, <fetched>, and as the accepted edits leave it,
    <text>."""

    def __init__(self, fetched: str):
        self.fetched = fetched
        self.text = fetched

    def edit(self, accepted: bool, edit: Edit) -> str:
        """<edit> made to the text when <accepted>, else its anchor checked on
        its own against the text as read: the anchor must occur exactly once
        in the text as read, and once in the text the earlier edits left. The
        problem when it does not, the text left unedited; "" when none."""
        text = self.text if accepted else self.fetched
        count = occurrences(self.fetched, edit.anchor)
        if count == 0:
            return "its anchor matches no text in the body"
        if count == 2:
            return "its anchor matches more than one place in the body"
        if occurrences(text, edit.anchor) != 1:
            return "its anchor no longer matches exactly once after the earlier items' edits"
        if accepted:
            self.text = text.replace(edit.anchor, edit.replace, 1)
        return ""


class Validation(Edited):
    """validate()'s answer: the batch, the batch file's text as read, each
    item's Disposition by its index, the body as read and as edited, the
    anchors visited and each anchor problem."""

    def __init__(self, batch: Batch, fetched: str, batch_text: str = "",
                 dispositions: Optional[Dict[int, "Disposition"]] = None):
        super().__init__(fetched)
        self.batch = batch
        self.batch_text = batch_text
        self.dispositions = dispositions or {}
        self.anchors = 0
        self.problems: List[str] = []

    def visit(self, accepted: bool, what: str, edit: Edit) -> None:
        """One anchor, counted, through edit(); a problem names <what>."""
        self.anchors += 1
        problem = self.edit(accepted, edit)
        if problem:
            self.problems.append("%s: %s" % (what, problem))


class Disposition:
    """What an answer did with an item: applied, declined, taken (a
    decision's option <taken>), undecided or resolved, and whether the
    human's call matched the recommendation (<as_recommended>)."""

    def __init__(self, disposition: str, taken: str = "", as_recommended: bool = False):
        self.disposition = disposition
        self.taken = taken
        self.as_recommended = as_recommended


ANSWER_FORMS = "is not recommended, all, none or a list of departures such as 3B, -4, +2"


def _held(item: Item, run: str) -> bool:
    """Whether <item> is a fundamental item the hold run holds back for the
    human's reply."""
    return run == "hold" and item.fundamental


def _resumed_as_recommended(item: Item, run: str) -> bool:
    """Whether <item> is one the resumed run's answer cannot name - a
    non-fundamental item, taken as recommended."""
    return run == "resume" and not item.fundamental


def answer_dispositions(batch: Batch, answer: str, run: str = "") -> Dict[int, Disposition]:
    """Each item's Disposition, by its index, from the batch question's
    <answer>: recommended, all, none, or an Other list such as `3B, -4, +2`
    naming only the departures from the recommendation - `<n><letter>` a
    decision's option, `-<n>` an item declined or a decision left undecided,
    `+<n>` a recommend-decline item applied - every item it does not name
    taken as recommended. <run> is the autopilot round's run, hold or resume,
    or "". Dies, before any write, on a token of no such form, an unknown item
    or option, a letter on an item that is no decision, `+` on a decision or
    on an item not recommended for decline, a resolved item named, or an
    item named twice."""
    dispositions: Dict[int, Disposition] = {}
    base = answer
    if answer not in ("recommended", "all", "none"):
        base = "recommended"
        for token in answer_tokens(answer):
            sign = letter = ""
            if token[:1] in ("-", "+") and token:
                sign, n = token[0], token[1:]
            else:
                n = re.match(r"[^A-Za-z]*", token).group()
                letter = token[len(n):]
            if (not plain_number(n)
                    or not (re.fullmatch(r"[A-Za-z]", letter) if not sign else not letter)):
                die("the answer '%s' %s - '%s' is not <n><letter>, -<n> or +<n>"
                    % (answer, ANSWER_FORMS, token))
            letter = letter.upper()
            index = next((i for i, item in enumerate(batch.items) if item.n == n), None)
            if index is None:
                die("the answer names item %s, which batch.md does not have" % n)
            item = batch.items[index]
            if index in dispositions:
                die("the answer names item %s twice" % n)
            if _held(item, run):
                die("the answer names item %s, a fundamental item held back for the human's"
                    " reply - it takes no answer in this run" % n)
            if _resumed_as_recommended(item, run):
                die("the answer names item %s, which is not a fundamental item - the resumed"
                    " answer names only fundamental items, the rest being taken as recommended"
                    % n)
            if item.rec == "resolved":
                die("the answer names item %s, which is resolved by item %s and takes no answer"
                    % (n, item.resolved))
            if not sign:
                if item.rec != "decision":
                    die("the answer gives item %s the letter %s, but item %s is no decision item"
                        % (n, letter, n))
                if item.option(letter) is None:
                    die("the answer gives item %s option %s, which it does not have" % (n, letter))
                dispositions[index] = Disposition("taken", letter, letter == item.arg)
            elif sign == "-":
                if item.rec == "decision":
                    dispositions[index] = Disposition("undecided")
                else:
                    dispositions[index] = Disposition("declined", "", item.rec == "decline")
            elif item.rec == "decline":
                dispositions[index] = Disposition("applied")
            elif item.rec == "decision":
                die("the answer names +%s, but item %s is a decision item: name its option, as %s%s"
                    % (n, n, n, item.arg))
            else:
                die("the answer names +%s, but item %s is not recommended for decline" % (n, n))
    for index, item in enumerate(batch.items):
        if item.rec == "resolved":
            dispositions[index] = Disposition("resolved")
            continue
        # A fundamental item is validated as recommended in the hold run; the
        # resumed run's answer is the fundamental items' alone.
        item_base = base
        if _held(item, run) or _resumed_as_recommended(item, run):
            item_base = "recommended"
        if index in dispositions:
            continue
        if item.rec == "apply" and item_base in ("recommended", "all") or (
                item.rec == "decline" and item_base == "all"):
            dispositions[index] = Disposition("applied", "", True)
        elif item.rec == "decision" and item_base in ("recommended", "all"):
            dispositions[index] = Disposition("taken", item.arg, True)
        elif item.rec == "decision":
            dispositions[index] = Disposition("undecided")
        elif item.rec == "decline":
            dispositions[index] = Disposition("declined", "", True)
        else:
            dispositions[index] = Disposition("declined")
    return dispositions


def _reason_split(flag: str, lineno: int, line: str) -> Tuple[str, str]:
    """One `<n>: <reason>` line of a reasons file split into its item number
    and its reason, or a death naming <flag>'s line."""
    n, colon, reason = line.partition(":")
    reason = trim(reason)
    if not (plain_number(n) and colon and reason and line.startswith(n + ": ")):
        die("%s line %d: want <n>: <reason>, got '%s'" % (flag, lineno, line))
    return n, reason


def reasons_read(flag: str, path: str, numbers: List[str], declined: List[bool], noun: str,
                 source: str, answer_name: str) -> Dict[int, str]:
    """The human's decline reasons from the file <path>, given as <flag> -
    none when <path> is empty - one `<n>: <reason>` line per item, by the
    index of <n> in <numbers>. Blank lines are skipped; a malformed line, or
    one naming an item <source> does not have, one whose item <answer_name>
    does not decline (per <declined>), or one named twice, dies, calling the
    item a <noun>."""
    reasons: Dict[int, str] = {}
    if not path:
        return reasons
    if not os.path.isfile(path):
        die("%s file not found: %s" % (flag, path))
    text = (read_raw(path) or "").replace("\x00", "")
    for lineno, line in enumerate(text.split("\n") if text else [], 1):
        line = without_cr(line)
        if not trim(line):
            continue
        n, reason = _reason_split(flag, lineno, line)
        index = numbers.index(n) if n in numbers else None
        if index is None:
            die("%s line %d names %s %s, which %s does not have" % (flag, lineno, noun, n, source))
        if not declined[index]:
            die("%s line %d names %s %s, which %s does not decline"
                % (flag, lineno, noun, n, answer_name))
        if index in reasons:
            die("%s line %d names %s %s a second time" % (flag, lineno, noun, n))
        reasons[index] = reason
    return reasons


def decline_reason(reasons: Dict[int, str], index: int, as_recommended: bool,
                   recommended_reason: str) -> str:
    """A declined item's changelog reason - the human's when it gave one,
    else, when the decline was the recommendation, the recommendation's own,
    else plain "declined"."""
    if index in reasons:
        return reasons[index]
    if as_recommended:
        return "declined as recommended: " + recommended_reason
    return "declined"


def validate(directory: str, body: str, violations: Violations, env, answer: str = "all",
             run: str = "") -> Validation:
    """The one validation check and apply share: reads <directory>/batch.md
    and the lens files of the lenses that ran, checks the citations, takes
    <answer> (answer_dispositions, in the autopilot <run>), and visits every
    anchor, in batch order, against the file <body>. Stops on the first
    structure violation or malformed lens file; each anchor problem is in the
    answer's problems, for the caller to react to."""
    text = read_raw(directory + "/batch.md") or ""
    batch = batch_parse(text, violations, autopilot_active(env))
    for name in SPEC_REVIEW_LENSES:
        if batch.lens(name).state == "ran":
            batch.lens_findings += lens_parse(directory, name, violations)
    findings_check(batch, violations)
    dispositions = answer_dispositions(batch, answer, run)
    fetched = read_raw(body)
    if fetched is None:
        violations.stop("could not read %s - nothing written" % body)
    result = Validation(batch, fetched.replace("\x00", ""), text, dispositions)
    for index, item in enumerate(batch.items):
        disposition = dispositions[index]
        if item.rec in ("apply", "decline"):
            # An item reported as having no anchor block has nothing to visit.
            if item.edit is not None:
                result.visit(disposition.disposition == "applied",
                             "batch.md line %d: item %s" % (item.edit.line, item.n), item.edit)
        elif item.rec == "decision":
            for option in item.options:
                if option.edit is None:
                    continue
                result.visit(disposition.disposition == "taken"
                             and disposition.taken == option.letter,
                             "batch.md line %d: item %s option %s"
                             % (option.edit.line, item.n, option.letter), option.edit)
    return result
