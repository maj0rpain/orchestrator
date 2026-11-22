"""A spec-review round's ticket items, <dir>/tickets.md: their parse and the
offline checks check --tickets and apply --tickets share, copied from the
bash spec-review module, gone since the noun's cutover, with its messages
and its order of checks.

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

apply --tickets adds the ticket question's answer (tickets_answer), the
checks that read GitHub - every entry naming a ticket is a ticket of the
breakdown in the state its kind needs (tickets_follow) - and the changelog's
Tickets lines (tickets_lines).
"""
from __future__ import annotations

import os
from typing import Dict, List, NoReturn, Optional, Tuple

from orch.common import (die, lines_of, plain_number, plain_positive_number, read_raw,
                         read_words, trim)
from orch.spec_review_batch import (Block, BlockReader, Edit, Edited, Malformed, Violations,
                                    answer_tokens, at_line, decline_reason, is_at_line,
                                    one_line, without_cr)
from orch.ticket import blocked_by_section_numbers, ticket_listing_state, ticket_sub_issues

# The Tickets lines that report no ticket outcome.
TICKETS_NO_EDIT = "Not checked - no edit applied"
TICKETS_NO_BREAKDOWN = "None - no ticket breakdown"
TICKETS_NONE_AFFECTED = "None - no ticket affected"


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

    def is_text_edit(self) -> bool:
        """Whether the item edits text - a ticket's body or the `## Ticket`
        section - rather than an edge."""
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
    if not item.is_text_edit():
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
        if not plain_positive_number(n):
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
        if not self.item.is_text_edit():
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
    lines = lines_of(text)
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
        if item.is_text_edit():
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



class TicketAnswer:
    """The ticket question's answer taken: whether it retires the breakdown,
    and otherwise each item's disposition, applied or declined, by its index,
    and the indexes whose disposition matched the recommendation."""

    def __init__(self) -> None:
        self.retire = False
        self.dispositions: Dict[int, str] = {}
        self.as_recommended: set = set()

    def applied(self, index: int) -> bool:
        return self.dispositions.get(index) == "applied"


def tickets_answer(tickets: Tickets, answer: str) -> TicketAnswer:
    """Each ticket item's disposition from the ticket question's <answer>:
    recommended (following @@ recommend), all, none, retire, or an Other list
    such as `1, 3`, each item it names applied and the rest declined. Dies,
    before any write, on a token that is no item number, an unknown item or
    one named twice."""
    taken = TicketAnswer()
    if answer == "retire" or (answer == "recommended" and tickets.recommend == "retire"):
        taken.retire = True
        return taken
    numbers = [item.n for item in tickets.items]
    if answer not in ("recommended", "all", "none"):
        for token in answer_tokens(answer):
            if not plain_number(token):
                die("the --tickets answer '%s' is not recommended, all, none, retire or a list such"
                    " as 1, 3 - '%s' is no ticket item" % (answer, token))
            if token not in numbers:
                die("the --tickets answer names ticket item %s, which tickets.md does not have"
                    % token)
            index = numbers.index(token)
            if index in taken.dispositions:
                die("the --tickets answer names ticket item %s twice" % token)
            taken.dispositions[index] = "applied"
            if tickets.items[index].rec == "apply":
                taken.as_recommended.add(index)
    for index, item in enumerate(tickets.items):
        if index in taken.dispositions:
            continue
        if item.rec == "apply" and answer in ("recommended", "all"):
            taken.dispositions[index] = "applied"
            taken.as_recommended.add(index)
        elif item.rec == "decline" and answer == "all":
            taken.dispositions[index] = "applied"
        elif item.rec == "decline":
            taken.dispositions[index] = "declined"
            taken.as_recommended.add(index)
        else:
            taken.dispositions[index] = "declined"
    return taken


def _named_check(where: str, t: str, want: str, listing, issue: str) -> None:
    """Dies, before any write, unless #<t> is a sub-issue of <issue> in the
    state <want> (OPEN, CLOSED or any) in <listing>. <where> is the message's
    prefix, up to and including its colon."""
    state = ticket_listing_state(listing, t)
    if not state:
        die("%s #%s is not a ticket of #%s's breakdown - nothing written" % (where, t, issue))
    if want == "OPEN" and state == "CLOSED":
        die("%s #%s is a closed ticket of #%s's breakdown - nothing written" % (where, t, issue))
    if want == "CLOSED" and state == "OPEN":
        die("%s #%s is an open ticket of #%s's breakdown - nothing written" % (where, t, issue))


def tickets_follow(gh, tickets: Tickets, taken: TicketAnswer, directory: str, body: str,
                   kind: str, issue: str) -> TicketsOffline:
    """Every ticket item checked against <body>, the round's body as the
    batch items left it, and the ticket copies in <directory>: an accepted
    one applied in memory, a declined text item's anchor checked on its own
    (TicketsOffline) - and the checks that read GitHub: every entry naming a
    ticket is a ticket of <issue>'s breakdown in the state its kind needs (a
    text item's and an edge item's ticket open, an edge item's blocker
    either, a `@@ closed` line's closed), and a `## Ticket` item only on a
    breakdown of <kind> collapsed. Dies, before any write, on the first
    GitHub-reading check that fails - the items in order, then the `@@
    closed` lines - else on the first offline problem. The checks' answer
    holds the edited body and copies; a retire checks nothing."""
    offline = TicketsOffline(directory, Edited(body), Violations(collect=False))
    if taken.retire:
        return offline
    listing = []
    if tickets.closed or any(item.kind != "section" for item in tickets.items):
        listing = ticket_sub_issues(gh, issue)
    for index, item in enumerate(tickets.items):
        what = "tickets.md line %d: ticket item %s:" % (item.line, item.n)
        if item.kind == "section":
            if kind != "collapsed":
                die("%s: a ## Ticket item, but #%s's breakdown is %s - nothing written"
                    % (what[:-1], issue, kind))
        elif item.kind == "ticket":
            _named_check(what, item.t, "OPEN", listing, issue)
        else:
            _named_check(what, item.t, "OPEN", listing, issue)
            _named_check(what, item.b, "any", listing, issue)
        offline.visit(item, taken.applied(index))
    for closed in tickets.closed:
        _named_check("tickets.md line %d:" % closed.line, closed.t, "CLOSED", listing, issue)
    if offline.problems:
        die(offline.problems[0] + " - nothing written")
    return offline


def tickets_lines(tickets: Tickets, taken: TicketAnswer, reasons: Dict[int, str]) -> str:
    """The changelog's Tickets lines, from the parsed tickets.md, the ticket
    answer and the human's decline reasons."""
    lines = []
    if taken.retire:
        lines.append("- retired, to be broken down again")
    for index, item in enumerate(tickets.items if not taken.retire else []):
        n = item.n
        if taken.applied(index):
            if item.is_text_edit():
                lines.append("- (%s) %s" % (n, item.summary))
            elif item.kind == "block":
                lines.append("- (%s) #%s now blocked by #%s" % (n, item.t, item.b))
            else:
                lines.append("- (%s) #%s no longer blocked by #%s" % (n, item.t, item.b))
            continue
        reason = decline_reason(reasons, index, index in taken.as_recommended, item.arg)
        if item.is_text_edit():
            lines.append('- (%s) "%s" - %s' % (n, one_line(item.edit.replace), reason))
        else:
            lines.append('- (%s) "%s #%s by #%s" - %s' % (n, item.kind, item.t, item.b, reason))
    for closed in tickets.closed:
        lines.append("- #%s closed, built against the earlier spec: %s" % (closed.t, closed.what))
    return "\n".join(lines) or TICKETS_NONE_AFFECTED
