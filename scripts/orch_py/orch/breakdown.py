"""The breakdown concept's module: the breakdown noun (ADR-0067), a spec's
approved ticket breakdown kept as a save point so a spec phase that died
mid-publish finishes it on restart, and where that save point lives, which the
ticket module's retire reaches too.

The save point is .orchestrator/breakdown/<parent>/: draft.md, the approved
draft; numbers, one `<k> <number> created|linked` line per ticket, the last
line for <k> winning; and published, the marker written last - the layout
bash's breakdown module writes, so either reads what the other left. The
draft has one block per ticket, in draft order:

    @@ ticket <k> <title>
    @@ blocked-by <k>,<k>,...      (optional; blockers by draft position)
    <body>
    @@ end

It is parsed in memory by the rules of bash's awk parser, with its messages
and line numbers. Positions are text everywhere, never integers, so 01 and 1
are two positions, as in bash.

Every verb keeps the bash module's arguments, usage lines, stdout, exit codes
and `orch:` messages: publish dies with 1, state with 2, an unknown op with
1.
"""
from __future__ import annotations

import os
import re
import shutil
from typing import Dict, List, Mapping, NamedTuple, NoReturn, Optional, Tuple

from orch.common import (AT_LINE_ESCAPE_HINT, ORCH_DIR_NAME, die, file_lines, lines_of,
                         mkdir_p_or_die, plain_number, read_raw, temp_text_file,
                         text_file_append, text_file_write)
from orch.git import Git
from orch.repo import REPO_REMEDY, RepoPin
from orch.root import checkout_root
from orch.spec_review_batch import read_words
from orch.ticket import (blockers_set, issue_number_list, ticket_create, ticket_exists,
                         ticket_link)
from orch.triage_labels import TriageLabels

# The verbs, in the unknown-op message's order. docs_lint.sh reads this line
# as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "publish|state"

PARENT_NOT_PLAIN = "parent must be a plain issue number, got: "

MALFORMED = "the breakdown draft is malformed: "


def breakdown_dir(root: str, n: str) -> str:
    """Spec issue <n>'s breakdown save point under the checkout at <root>."""
    return "%s/%s/breakdown/%s" % (root, ORCH_DIR_NAME, n)


class DraftTicket(NamedTuple):
    """One block of a draft: its position and title as written, its
    `@@ blocked-by` list as written ("" for none), and its body, each line
    ending in a newline."""

    position: str
    title: str
    blocked_by: str
    body: str


def _malformed(number: int, message: str) -> NoReturn:
    die("%sline %d: %s" % (MALFORMED, number, message))


def breakdown_parse(text: str) -> List[DraftTicket]:
    """The draft's blocks, in draft order. Each line has one trailing CR
    dropped. Inside a block, a line of one or more backslashes then @@ loses
    one backslash and is a body line; `@@ blocked-by` counts only as a
    block's first line after its `@@ ticket`; `@@ end`, trailing blanks
    allowed, closes it; any other `@@ ` or bare `@@` line is a stray grammar
    line. Outside a block only blank lines may stand. Dies on a malformed
    draft, naming the line as bash's awk parser does."""
    tickets: List[DraftTicket] = []
    seen = set()
    in_block = first = False
    k = title = blocked = ""
    body: List[str] = []
    for number, line in enumerate(lines_of(text), 1):
        if line.endswith("\r"):
            line = line[:-1]
        if in_block and re.match(r"\\+@@", line):
            body.append(line[1:])
            first = False
        elif line.startswith("@@ ticket "):
            if in_block:
                _malformed(number, "@@ ticket inside an unfinished block" + AT_LINE_ESCAPE_HINT)
            rest = line[len("@@ ticket "):]
            k = rest.split(" ", 1)[0]
            title = rest[len(k):].lstrip(" ")
            if not re.fullmatch(r"[0-9]+", k):
                _malformed(number, "ticket position is not a plain number: " + k)
            if title == "":
                _malformed(number, "ticket %s has no title" % k)
            if k in seen:
                _malformed(number, "ticket %s appears twice" % k)
            seen.add(k)
            in_block = first = True
            blocked = ""
            body = []
        elif in_block and first and line.startswith("@@ blocked-by "):
            blocked = line[len("@@ blocked-by "):]
            first = False
        elif in_block and re.fullmatch(r"@@ end[ \t]*", line):
            tickets.append(DraftTicket(k, title, blocked, "".join(b + "\n" for b in body)))
            in_block = False
        elif in_block and (line == "@@" or line.startswith("@@ ")):
            _malformed(number, "stray grammar line inside ticket %s: %s%s"
                       % (k, line, AT_LINE_ESCAPE_HINT))
        elif in_block:
            body.append(line)
            first = False
        elif not re.fullmatch(r"[ \t]*", line):
            _malformed(number, "text outside a ticket block")
    if in_block:
        die("%sticket %s has no @@ end" % (MALFORMED, k))
    if not tickets:
        die(MALFORMED + "no ticket blocks")
    return tickets


def _blocker_positions(ticket: DraftTicket) -> List[str]:
    """The ticket's blockers by position, as the draft wrote them: checked
    by the issue-number-list reader, ordered by number and de-duplicated by
    number as bash's `sort -un` does, the first of equal ones kept. An empty
    list is no blockers."""
    if ticket.blocked_by == "":
        return []
    issue_number_list("ticket-%s blocked-by" % ticket.position, ticket.blocked_by)
    kept: Dict[int, str] = {}
    for entry in ticket.blocked_by.split(","):
        kept.setdefault(int(entry), entry)
    return [kept[number] for number in sorted(kept)]


def breakdown_order(tickets: List[DraftTicket]) -> Tuple[List[str], Dict[str, List[str]]]:
    """The positions in publishing order - draft order, each ticket after
    its blockers - and each position's blockers. Dies, before ordering, on
    a ticket blocked by itself or by a position that is no ticket of the
    draft, checked in draft order; then on a cycle."""
    positions = [ticket.position for ticket in tickets]
    blockers: Dict[str, List[str]] = {}
    for ticket in tickets:
        k = ticket.position
        blockers[k] = _blocker_positions(ticket)
        for b in blockers[k]:
            if b == k:
                die("ticket %s is blocked by itself" % k)
            if b not in positions:
                die("ticket %s is blocked by %s, which is no ticket of the draft" % (k, b))
    order: List[str] = []
    pending = positions
    while pending:
        rest = []
        for k in pending:
            if all(b in order for b in blockers[k]):
                order.append(k)
            else:
                rest.append(k)
        if len(rest) == len(pending):
            die("the breakdown draft's blocked-by edges form a cycle")
        pending = rest
    return order, blockers


def breakdown_number(numbers: str, k: str) -> Tuple[str, str]:
    """The number and status of the last line for position <k> in the
    numbers file, both "" when there is none or the file is missing. Read
    afresh at each call: a ticket's publish appends to it mid-loop."""
    found = ("", "")
    for line in file_lines(numbers):
        position, n, status = read_words(line, 3)
        if position == k:
            found = (n, status)
    return found


def breakdown_record(numbers: str, k: str, n: str, status: str) -> None:
    """One `<k> <n> <status>` line appended to the numbers file; a failed
    write dies."""
    text_file_append(numbers, "%s %s %s" % (k, n, status),
                     "could not write ticket #%s's %s record to %s" % (n, status, numbers))


def _save_draft(draft: str, directory: str, saved: str) -> None:
    """The given draft saved as the save point's draft.md: copied to a temp
    file beside it, then renamed over it."""
    mkdir_p_or_die(directory, "could not create " + directory)
    try:
        shutil.copyfile(draft, saved + ".tmp")
        os.replace(saved + ".tmp", saved)
    except OSError:
        die("could not save the breakdown draft to " + saved)


def _first_numbers(numbers: str) -> List[str]:
    """The first number recorded for each position, in the order the
    positions first appear in the numbers file, as bash's
    `awk '!seen[$1]++ { print $2 }'` prints them."""
    seen = set()
    out = []
    for line in file_lines(numbers):
        position, n, _ = read_words(line, 3)
        if position not in seen:
            seen.add(position)
            out.append(n)
    return out


def publish(args: List[str], gh_of, root: str) -> int:
    """`breakdown publish <parent> <draft-file>`: every ticket of the draft
    created, linked as a sub-issue of <parent> with its blocking edges, and
    verified, in publishing order; then the published marker, and the
    numbers printed in publishing order. A saved draft wins over the one
    given; with none, the given draft is parsed and ordered before it is
    saved, so a malformed or cyclic draft saves nothing. Every failure dies
    with 1."""
    if len(args) != 2:
        die("usage: orch.sh breakdown publish <parent> <draft-file>")
    parent, draft = args
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent)
    directory = breakdown_dir(root, parent)
    saved = directory + "/draft.md"
    if not os.path.isfile(saved):
        if not os.path.isfile(draft):
            die("draft file not found: " + draft)
        breakdown_order(breakdown_parse(read_raw(draft) or ""))
        _save_draft(draft, directory, saved)
    tickets = {ticket.position: ticket for ticket in breakdown_parse(read_raw(saved) or "")}
    order, blockers = breakdown_order(list(tickets.values()))
    numbers = directory + "/numbers"
    labels = TriageLabels(lambda: root)
    gh = None
    for k in order:
        n, status = breakdown_number(numbers, k)
        if status == "linked":
            continue
        want = blockers_set(breakdown_number(numbers, b)[0] for b in blockers[k])
        if gh is None:
            # The first GitHub call: a Repo that does not resolve dies here,
            # with the draft saved and nothing created, as every adapter
            # call it could not pin would.
            gh = gh_of()
            if not gh.pin():
                die(REPO_REMEDY)
        if not n:
            ticket = tickets[k]
            unmade = "could not create a temp file for ticket %s's body" % k
            with temp_text_file(ticket.body, unmade, unmade) as body_file:
                try:
                    n = str(ticket_create(gh, labels, ticket.title, body_file))
                except SystemExit:
                    die("ticket %s of the draft: the create failed" % k)
            # Recorded before the link, so a rerun can tell "created,
            # unlinked" from "not created". A failed write dies here.
            breakdown_record(numbers, k, n, "created")
        # Fresh or resumed alike: link only what is not yet linked, add only
        # the blocking edges the ticket lacks, read it all back.
        try:
            ticket_link(gh, parent, n, want)
        except SystemExit:
            die("ticket %s of the draft (#%s): the link failed" % (k, n))
        breakdown_record(numbers, k, n, "linked")
    text_file_write(directory + "/published", "",
                    "could not write the published marker %s/published" % directory)
    for n in _first_numbers(numbers):
        print(n)
    return 0


def state(args: List[str], gh_of, root: str) -> int:
    """`breakdown state <parent>`: complete, partial or none. The published
    marker answers first, then a saved draft, reading nothing from GitHub;
    with neither, `ticket exists` decides. Misuse, a failed read and a Repo
    that does not resolve exit 2, never read as none."""
    if len(args) != 1:
        die("usage: orch.sh breakdown state <parent>", 2)
    parent = args[0]
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent, 2)
    directory = breakdown_dir(root, parent)
    if os.path.isfile(directory + "/published"):
        print("complete")
    elif os.path.isfile(directory + "/draft.md"):
        print("partial")
    else:
        print("none" if ticket_exists(gh_of(), parent) is None else "complete")
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
) -> int:
    """`orch.sh breakdown <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    # The Repo, resolved once and memoised, for every gh call the op makes.
    pin = RepoPin(env, git) if pin is None else pin
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown breakdown op: %s (want %s)" % (op or "<none>", OPS))

    # The gh adapter, made at the first GitHub call: a state the save point
    # answers makes none.
    def gh_of():
        if gh is not None:
            return gh
        from orch.gh import adapter

        return adapter(env, pin=pin)

    if op == "publish":
        return publish(argv[1:], gh_of, root)
    return state(argv[1:], gh_of, root)
