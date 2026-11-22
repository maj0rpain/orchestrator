"""A spec-review round's ticket items, <dir>/tickets.md: their parse and the
offline checks check --tickets and apply --tickets share, copied from the
bash spec-review module with its messages and its order of checks.

On the rerun after the ticket pause, tickets.md holds the ticket items the
session drafted - text edits against ticket-<t>.md or the collapsed body's
`## Ticket` section, and blocked-by edges - or the lone `@@ none-affected`.
Its grammar is the `@@` lines: `@@ recommend` first, then one entry per item
and per `@@ closed` line, each edit's anchor -> replace -> end block read by
the batch's shared @@ block reader (orch/spec_review_batch.py's
BlockReader). Each line has one trailing CR stripped before it is read
(#2547). A structure violation stops; a content violation - an item lacking
its summary or its edit - is collected under check (Violations).

The offline checks read no GitHub: every text item's anchor is visited
against the copy apply would edit - ticket-<t>.fetched.md once an apply run
has taken it, else ticket-<t>.md, or the round's body for a `## Ticket`
item - and every accepted edge against its ticket's `## Blocked by`
(orch/ticket.py's blocked_by_section_numbers). Each problem names its
tickets.md line, for the caller to react to.
"""
from __future__ import annotations

import os
from typing import Dict, List, NoReturn, Optional

from orch.common import die, plain_number, read_raw
from orch.spec_review_batch import (Block, BlockReader, Edit, Edited, Malformed, Violations,
                                    at_line, is_at_line, positive_number, read_words, trim,
                                    without_cr)
from orch.ticket import blocked_by_section_numbers


class TicketItem:
    """A ticket item: its number, its kind (ticket, section, block or
    unblock), its ticket <t> and, for an edge, its blocker <b>, its
    recommendation (apply or decline) and a decline's reason, its header
    line, and a text item's summary and edit."""

    def __init__(self, n: str, kind: str, t: str, b: str, rec: str, arg: str, line: int):
        self.n, self.kind, self.t, self.b = n, kind, t, b
        self.rec, self.arg, self.line = rec, arg, line
        self.summary: Optional[str] = None
        self.edit: Optional[Edit] = None

    def text(self) -> bool:
        return self.kind in ("ticket", "section")


class Closed:
    """A `@@ closed <t> <what changed>` line and its line number."""

    def __init__(self, t: str, what: str, line: int):
        self.t, self.what, self.line = t, what, line


class Tickets:
    """A parsed tickets.md: its recommended answer (apply or retire), or
    none-affected; its items and its closed lines, each in file order."""

    def __init__(self) -> None:
        self.recommend = ""
        self.none_affected = False
        self.items: List[TicketItem] = []
        self.closed: List[Closed] = []

    def item(self, n: str) -> Optional[TicketItem]:
        for item in self.items:
            if item.n == n:
                return item
        return None


def item_check(item: TicketItem, violations: Violations) -> None:
    """Reports, naming the item's header line, a text item lacking its
    summary or its anchor/replace block - each a content violation."""
    if not item.text():
        return
    if item.summary is None:
        violations.content("tickets.md line %d: item %s has no @@ summary" % (item.line, item.n))
    if item.edit is None:
        violations.content("tickets.md line %d: item %s has no @@ anchor/@@ replace/@@ end block"
                           % (item.line, item.n))


class _TicketsParser:
    """tickets_parse's state while it reads the file."""

    def __init__(self, violations: Violations):
        self.violations = violations
        self.tickets = Tickets()
        self.item: Optional[TicketItem] = None
        self.seen = False
        self.reader = BlockReader()

    def stop(self, line: int, message: str) -> NoReturn:
        self.violations.stop("tickets.md line %d: %s" % (line, message))

    def item_done(self) -> None:
        if self.item is not None:
            item_check(self.item, self.violations)

    def line(self, line: str, lineno: int) -> None:
        try:
            outcome = self.reader.feed(line, lineno)
        except Malformed as bad:
            self.stop(bad.line, bad.message)
        if outcome == "consumed":
            return
        if isinstance(outcome, Block):
            self.item.edit = Edit(outcome.anchor, outcome.anchor_line, outcome.text)
            return
        if not is_at_line(line):
            if not trim(line):
                return
            self.stop(lineno, "text outside an @@ anchor or @@ replace block")
        keyword, args = at_line(line)
        if self.tickets.none_affected:
            self.stop(lineno, "@@ none-affected stands alone in its file")
        if keyword in ("recommend", "none-affected"):
            if self.seen:
                self.stop(lineno, "@@ %s comes first, and only once" % keyword)
        elif not self.tickets.recommend:
            self.stop(lineno, "@@ recommend comes first: @@ recommend apply or @@ recommend retire")
        self.seen = True
        if keyword == "recommend":
            if args not in ("apply", "retire"):
                self.stop(lineno, "@@ recommend wants apply or retire, got '%s'" % args)
            self.tickets.recommend = args
        elif keyword == "none-affected":
            if args:
                self.stop(lineno, "@@ none-affected takes nothing after it")
            self.tickets.none_affected = True
        elif keyword == "item":
            self.kw_item(args, lineno)
        elif keyword in ("summary", "anchor"):
            self.kw_summary_anchor(keyword, args, lineno)
        elif keyword == "closed":
            self.kw_closed(args, lineno)
        elif keyword in ("replace", "end"):
            self.stop(lineno, "@@ %s with no @@ anchor open" % keyword)
        else:
            self.stop(lineno, "unknown line '@@ %s'" % keyword)

    def kw_item(self, args: str, lineno: int) -> None:
        self.item_done()
        n, kind, tail = read_words(args, 3)
        if not positive_number(n):
            self.stop(lineno, "item number must be a positive number, got '%s'" % n)
        if self.tickets.item(n) is not None:
            self.stop(lineno, "a second item " + n)
        t = b = ""
        if kind == "ticket":
            t, rec, arg = read_words(tail, 3)
        elif kind == "section":
            rec, arg = read_words(tail, 2)
        elif kind in ("block", "unblock"):
            t, by, b, rec, arg = read_words(tail, 5)
            if by != "by":
                self.stop(lineno, "@@ item %s %s wants <t> by <b>" % (n, kind))
            if not plain_number(b):
                self.stop(lineno, "@@ item %s %s wants <t> by <b>, each a plain issue number"
                          % (n, kind))
            if t == b:
                self.stop(lineno, "@@ item %s: a ticket never blocks itself" % n)
        else:
            self.stop(lineno, "item %s wants ticket <t>, section, block <t> by <b> or unblock"
                      " <t> by <b>" % n)
        if kind != "section" and not plain_number(t):
            self.stop(lineno, "@@ item %s %s wants a plain issue number, got '%s'" % (n, kind, t))
        if rec == "apply":
            if arg:
                self.stop(lineno, "@@ item %s ... apply takes nothing after it" % n)
        elif rec == "decline":
            if not arg:
                self.stop(lineno, "@@ item %s ... decline needs a reason" % n)
        else:
            self.stop(lineno, "item %s's recommendation must be apply or decline <reason>" % n)
        self.item = TicketItem(n, kind, t, b, rec, arg, lineno)
        self.tickets.items.append(self.item)

    def kw_summary_anchor(self, keyword: str, args: str, lineno: int) -> None:
        if self.item is None:
            self.stop(lineno, "@@ %s outside an item" % keyword)
        if not self.item.text():
            self.stop(lineno, "an edge item carries no @@ " + keyword)
        if keyword == "summary":
            if not args:
                self.stop(lineno, "@@ summary needs its line")
            if self.item.summary is not None:
                self.stop(lineno, "a second @@ summary for this item")
            self.item.summary = args
            return
        if args:
            self.stop(lineno, "@@ anchor takes nothing after it; the anchor is the lines below it")
        if self.item.edit is not None:
            self.stop(lineno, "a second @@ anchor for this item")
        self.reader.open("anchor", lineno)

    def kw_closed(self, args: str, lineno: int) -> None:
        self.item_done()
        self.item = None
        t, what = read_words(args, 2)
        if not plain_number(t):
            self.stop(lineno, "@@ closed wants <t> <what changed>, t a plain issue number")
        if not what:
            self.stop(lineno, "@@ closed %s needs what changed" % t)
        self.tickets.closed.append(Closed(t, what, lineno))

    def finish(self) -> Tickets:
        try:
            self.reader.finish()
        except Malformed as bad:
            self.stop(bad.line, bad.message)
        self.item_done()
        if not self.seen:
            die("tickets.md is empty - it holds @@ recommend and the ticket items, or"
                " @@ none-affected")
        return self.tickets


def tickets_parse(text: str, violations: Violations) -> Tickets:
    """The tickets file's <text> parsed: a structure violation stops, named
    by its line number, after the content violations collected before it; a
    content violation goes to <violations>."""
    parser = _TicketsParser(violations)
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    for lineno, line in enumerate(lines, 1):
        parser.line(without_cr(line), lineno)
    return parser.finish()


class TicketsOffline:
    """The offline checks of one run over the ticket items in <directory>:
    the ticket copies loaded, each once, the anchors visited, each problem
    found. <body> is the round's body as the batch items left it, which a
    `## Ticket` item edits."""

    def __init__(self, directory: str, body: Edited, violations: Violations):
        self.directory = directory
        self.body = body
        self.violations = violations
        self.copies: Dict[str, Edited] = {}
        self.anchors = 0
        self.problems: List[str] = []

    def load(self, t: str, what: str) -> Optional[Edited]:
        """Ticket #<t>'s copy, loaded once - ticket-<t>.fetched.md, else,
        before any apply run has taken that copy, ticket-<t>.md. When the
        session wrote no ticket-<t>.md, the problem, naming <what>, is
        recorded and None answered; a copy that cannot be read stops, naming
        <what> too."""
        if t in self.copies:
            return self.copies[t]
        if not os.path.isfile("%s/ticket-%s.md" % (self.directory, t)):
            self.problems.append("%s: ticket-%s.md not found in %s - fetch each ticket a ticket"
                                 " item names into it" % (what, t, self.directory))
            return None
        path = "%s/ticket-%s.fetched.md" % (self.directory, t)
        if not os.path.exists(path):
            path = "%s/ticket-%s.md" % (self.directory, t)
        text = read_raw(path)
        if text is None:
            self.violations.stop("%s: could not read %s - nothing written" % (what, path))
        self.copies[t] = Edited(text.replace("\x00", ""))
        return self.copies[t]

    def visit(self, item: TicketItem, accepted: bool) -> None:
        """Ticket item <item>'s checks that read no GitHub. A text item,
        counted, has its anchor visited (Edited.edit) against its ticket's
        copy or the body: made in memory when <accepted>, else checked on its
        own. An accepted edge is checked against its ticket's copy's
        `## Blocked by` as fetched. A problem names the item's `@@ anchor`
        line for a text item, else its header line."""
        what = "tickets.md line %d: ticket item %s" % (item.line, item.n)
        if item.text():
            # A text item reported as having no anchor block has nothing to
            # check.
            if item.edit is None:
                return
            self.anchors += 1
            if item.kind == "ticket":
                target = self.load(item.t, what)
                if target is None:
                    return
                label = "ticket item %s (#%s)" % (item.n, item.t)
            else:
                target, label = self.body, "ticket item %s (## Ticket)" % item.n
            problem = target.edit(accepted, item.edit)
            if problem:
                self.problems.append("tickets.md line %d: %s: %s"
                                     % (item.edit.line, label, problem))
            return
        if not accepted:
            return
        copy = self.load(item.t, what)
        if copy is None:
            return
        have = item.b in blocked_by_section_numbers(copy.fetched + "\n")
        if item.kind == "block" and have:
            self.problems.append("%s: #%s is already blocked by #%s" % (what, item.t, item.b))
        elif item.kind == "unblock" and not have:
            self.problems.append("%s: #%s is not blocked by #%s" % (what, item.t, item.b))
