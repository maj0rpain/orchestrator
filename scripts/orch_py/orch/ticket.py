"""orch.sh's ticket noun (ADR-0067), and the ticket concept's Python copies
the spec-review, breakdown, phase and redo nouns reach: a breakdown's
sub-issue listing (ticket_sub_issues) and the state of one ticket in it; the
reads and rewrites of a body's markdown - the numbers a ticket's `## Blocked
by` section lists, that section rewritten, and the `## Ticket` heading a
collapsed breakdown sits under (ADR-0012), detected and cut; `ticket exists`,
`ticket block`, `ticket unblock`, `ticket retire` and `ticket reset`, with the
helpers they reach; the create and link breakdown publish runs on each
ticket, ticket_create and ticket_link, with ticket_links_verified,
ticket_edges_verified and blockers_set; and the open-tickets refusal phase
advance makes before it leaves implement, require_no_open_tickets, which
pr.sh's `pr open` and `pr publish` reach through the refuse_open_tickets
bridge. Each is copied from the bash ticket module under its bash name, with
its messages and its order of steps; the bash copies stay while a bash caller
remains.

run(argv) takes the arguments after `ticket`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die. Its verbs so
far are `publish`, `next`, `list`, `parent`, `report` (`save`, `show`) and the
five above, each behind bash's usage line and guard order, and an op it does
not run dies with bash's "unknown ticket op" refusal, every op bash has named
in it. A saved report keeps bash's layout, .orchestrator/reports/<n>.md, so
one a bash session saved reads back here.

The body reads take the body as awk reads it, one line per newline, a last
line with no newline included, and each line's trailing CR ignored, so a
body edited on the web reads as its LF twin. A heading inside a code fence
(orch.common's fenced) is text, never a heading.

`ticket exists` keeps its exit 2 for a GitHub it cannot read, a repo it
cannot pin and a usage error, so a caller never reads a failure as "no
breakdown". `ticket retire` keeps both retirement comment wordings, so a
ticket a retire already commented on, in either, is not commented on again.
"""
from __future__ import annotations

import os
import re
from typing import Callable, Dict, Iterable, List, Mapping, Optional, Sequence

from orch import comments
from orch.common import (ORCH_DIR_NAME, copy_or_die, die, fenced, lines_of, mkdir_p_or_die,
                         plain_number, read_raw, rm_f_or_die, rm_rf_or_die, state_word,
                         stdout_write, temp_text_file, without_cr)
from orch.gh import (GhFailed, SubIssue, adapter, adapter_of, gh_die, gh_or_die,
                     verify_twice)
from orch.git import Git
from orch.repo import REPO_REMEDY, RepoPin
from orch.root import checkout_root
from orch.triage_labels import TriageLabels

# Every op of the ticket noun, as its unknown-op refusal names them.
OPS = "publish|next|list|close|reset|parent|exists|retire|report|block|unblock|merge|reclaim"

# The fixed heading line a collapsed ticket breakdown sits under (ADR-0012).
TICKET_HEADING = "## Ticket"

# The heading of a ticket body's section listing its blockers.
BLOCKED_BY_HEADING = "## Blocked by"

# The refusal of a parent that is no plain issue number, the parent appended.
PARENT_NOT_PLAIN = "parent must be a plain issue number, got: "

# A line that is a `#` or `##` heading: what ends a section.
_SECTION_END = re.compile(r"##?([ \t]|$)")


def ticket_sub_issues(gh, parent: str, code: int = 1) -> List[SubIssue]:
    """<parent>'s sub-issues, open or closed, in the order GitHub published
    them - the listing the ticket commands read (#394). A <parent> that is no
    plain number is refused before asking GitHub, always exit 1; a GitHub
    that cannot list them dies in the gh failure contract's grammar, exit
    <code>."""
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent)
    return gh_or_die("list sub-issues of #" + parent, gh.sub_issues, int(parent), code=code)


def require_no_open_tickets(gh, spec: str, command: str) -> None:
    """Dies unless <spec> has no open sub-issue, blocked or not, bash
    require_no_open_tickets - what phase advance requires before it leaves
    implement. <command> is the refusing command, named in the message. A
    collapsed breakdown or an issue with no sub-issues has none, so it
    passes; a GitHub that cannot be read dies in ticket_sub_issues'
    grammar."""
    still_open = ["#%d" % row.number for row in ticket_sub_issues(gh, spec) if row.state == "OPEN"]
    if still_open:
        die("#%s still has open tickets: %s - run the driver loop (orch.sh ticket next %s) or"
            " close them, then run %s again" % (spec, " ".join(still_open), spec, command))


def refuse_open_tickets(
    args: List[str],
    gh=None,
    env: Optional[Mapping[str, str]] = None,
) -> None:
    """Bridge for pr.sh's `pr open` and `pr publish`, once per command:
    `refuse_open_tickets <issue> <command>` runs require_no_open_tickets on
    <issue>, <command> the refusing command its message names. The real gh
    adapter and the process's environment unless a test hands in others."""
    if len(args) != 2:
        die("usage: orch_python_call ticket refuse_open_tickets <issue> <command>")
    gh = adapter(os.environ if env is None else env) if gh is None else gh
    require_no_open_tickets(gh, args[0], args[1])


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
    lines = [without_cr(line) for line in lines_of(body)]
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



def rewrite_blocked_by_section(body: str, blockers: Sequence[int]) -> str:
    """<body> with its first `## Blocked by` section outside a code fence -
    the heading through the line before the next `#` or `##` heading outside
    a code fence, or the end of the body; `###` does not end it - rewritten
    as: the heading, a blank line, one `- #<n>` line per blocker (or `None
    (can start immediately)` when there is none), then a blank line if
    another heading follows. The section's lines end the way its heading's
    line did, CRLF included. With no such section, one is appended after one
    blank line. Every other line is kept byte for byte, each ending in a
    newline, as awk prints it."""
    def section(eol: str) -> str:
        if not blockers:
            return "%s%s%sNone (can start immediately)%s" % (BLOCKED_BY_HEADING, eol, eol, eol)
        return BLOCKED_BY_HEADING + eol + eol + "".join("- #%d%s" % (b, eol) for b in blockers)

    out = []
    skip = done = False
    section_cr = last = last_cr = ""
    raw = lines_of(body)
    lines, fences = _read(body)
    for original, line, f in zip(raw, lines, fences):
        cr = "\r" if original.endswith("\r") else ""
        last, last_cr = line, cr
        if skip and not f and _SECTION_END.match(line):
            skip = False
            out.append(section_cr + "\n")
        if not done and not f and line == BLOCKED_BY_HEADING:
            section_cr = cr
            out.append(section(cr + "\n"))
            skip = done = True
            continue
        if skip:
            continue
        out.append(original + "\n")
    if not done:
        if raw and last != "":
            out.append(last_cr + "\n")
        out.append(section(last_cr + "\n"))
    return "".join(out)


def issue_number_list(flag: str, text: str) -> List[int]:
    """The one parser of a comma list of issue numbers: sorted and
    de-duplicated. Dies naming <flag> and the whole list on any entry that is
    not a plain issue number, an empty one included."""
    if not re.fullmatch(r"[0-9]+(,[0-9]+)*", text):
        die("%s must be plain issue numbers, got: %s" % (flag, text))
    return sorted({int(entry) for entry in text.split(",")})


def issue_body_rewrite(gh, n: str, read_what: str, write_what: str,
                       rewrite: Callable[[str], str]) -> None:
    """Issue <n>'s body through <rewrite> and back: the body as gh prints it,
    a newline after it, so the bytes the rewrite keeps go back unchanged. A
    result identical to it is not written. A failed read dies with
    <read_what>, a failed write with <write_what>."""
    try:
        printed = gh.issue_body(int(n)) + "\n"
    except GhFailed as failed:
        gh_die(read_what, failed.stderr)
    result = rewrite(printed)
    if result == printed:
        return
    unmade = "could not create a temp file for issue #%s's rewritten body" % n
    with temp_text_file(result, unmade, unmade) as path:
        try:
            gh.issue_body_edit(int(n), path)
        except GhFailed as failed:
            gh_die(write_what, failed.stderr)


def ticket_blocked_by_rewrite(gh, n: str, want: Sequence[int]) -> None:
    """Ticket <n>'s `## Blocked by` section rewritten from <want>."""
    issue_body_rewrite(gh, n, "read ticket #%s's body" % n,
                       "rewrite ticket #%s's ## Blocked by section" % n,
                       lambda body: rewrite_blocked_by_section(body, want))


def blockers_set(numbers: Iterable[str]) -> List[int]:
    """The numbers of <numbers>, blank entries dropped, sorted numerically
    and de-duplicated; none for an empty list."""
    return sorted({int(n) for n in numbers if n})


def ticket_links_verified(gh, parent: str, child: str, want: Sequence[int]) -> bool:
    """Whether both links read back exactly as published: <parent>'s
    sub-issue listing contains <child>, and <child>'s blockers are the set
    <want>, in any order, both sides de-duplicated. Read fresh every call,
    never cached, so verify_twice's retry reads again; a failed read raises
    GhFailed, never answered as a mismatch (#843)."""
    if not ticket_listing_state(gh.sub_issues(int(parent)), child):
        return False
    return ticket_edges_verified(gh, child, want)


def ticket_edges_verified(gh, n: str, want: Sequence[int]) -> bool:
    """Whether ticket <n>'s blockers, read fresh, are the set <want>, both
    sides sorted and de-duplicated - the verifier verify_twice runs for its
    blocking edges, and ticket_links_verified's second half. A failed read
    raises GhFailed, never answered as a mismatch."""
    return sorted(set(gh.blockers(int(n)))) == sorted(set(want))


def ticket_create(gh, labels: TriageLabels, title: str, body_file: str) -> int:
    """The ticket's issue, created with <title> and the body in <body_file>
    under this repo's ready-for-agent label, as <labels> maps the role: its
    number. Dies when the create fails."""
    ready = labels.label("ready-for-agent")
    return gh_or_die("create the ticket", gh.issue_create, title, body_file, [ready])


def ticket_link(gh, parent: str, n: str, want: Sequence[int]) -> None:
    """Ticket <n> put in place under <parent> with the blockers <want> (a
    blockers_set), whatever already landed. The parent's sub-issue listing is
    read and the ticket linked only when it is not listed; its blockers are
    read once, and only when <want> is non-empty, and only the edges it lacks
    are added, so a resume never writes a link already present. Then every
    link is read back through verify_twice (ADR-0011), and once they verify
    the ticket's `## Blocked by` section is rewritten from <want>, as `ticket
    block` writes it."""
    subs = ticket_sub_issues(gh, parent)
    if not ticket_listing_state(subs, n):
        gh_or_die("link ticket #%s as a sub-issue of #%s" % (n, parent), gh.sub_issue_link,
                  int(parent), int(n))
    if want:
        have = ticket_blockers(gh, n)
        for b in want:
            if b in have:
                continue
            gh_or_die("add a blocking edge from ticket #%s on #%d" % (n, b), gh.blocker_add,
                      int(n), b)
    verify_twice("read ticket #%s's links" % n,
                 "ticket #%s's sub-issue/blocked-by links did not verify - checked twice, both"
                 " failed" % n,
                 lambda: ticket_links_verified(gh, parent, n, want))
    ticket_blocked_by_rewrite(gh, n, want)


def ticket_exists(gh, parent: str) -> Optional[str]:
    """`ticket exists <parent>`: "sub-issues" when <parent> has sub-issues,
    open or closed, else "collapsed" when its body has the `## Ticket`
    heading outside a code fence, else None - bash's exit 1. A GitHub it
    cannot read, a repo it cannot pin, or a parent that is no plain number
    dies with 2, never 1."""
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent, 2)
    if not gh.pin():
        die(REPO_REMEDY, 2)
    if ticket_sub_issues(gh, parent, code=2):
        return "sub-issues"
    body = gh_or_die("read issue #%s's body" % parent, gh.issue_body, int(parent), code=2)
    return "collapsed" if has_ticket_heading(body) else None


def ticket_edge_preconditions(gh, n: str, by: Sequence[int]) -> None:
    """Dies, before any write, unless ticket <n> is open, is a sub-issue,
    and every <by> issue is its sibling. A closed blocker is allowed."""
    state = gh_or_die("read ticket #" + n, gh.issue_state, int(n))
    if state == "CLOSED":
        die("ticket #%s is closed - its blocking edges can no longer change anything" % n)
    parent = gh_or_die("read issue #%s's parent" % n, gh.issue_parent, int(n))
    if parent is None:
        die("#%s is not a sub-issue, so it is no ticket of a breakdown" % n)
    for b in by:
        if gh_or_die("read issue #%d's parent, a blocker of ticket #%s" % (b, n),
                     gh.issue_parent, b) != parent:
            die("#%d is not a sub-issue of #%d, ticket #%s's parent - edges never cross breakdowns"
                % (b, parent, n))


def ticket_blockers(gh, n: str) -> List[int]:
    """Ticket <n>'s blocker numbers, read fresh, sorted and de-duplicated."""
    return sorted(set(gh_or_die("read ticket #%s's blockers" % n, gh.blockers, int(n))))


def ticket_edges_change(gh, verb: str, n: str, by_text: str) -> None:
    """`ticket block` and `ticket unblock`'s one driver, on ticket <n> and the
    --by list <by_text>: the preconditions, one edge write per edge that
    needs it - block adds those missing, unblock removes those present - the
    edges verified twice against the wanted set, and the `## Blocked by`
    rewrite. Either re-run is idempotent."""
    if not plain_number(n):
        die("not a plain issue number: " + n)
    if not by_text:
        die("--by must be plain issue numbers, got nothing")
    by = issue_number_list("--by", by_text)
    ticket_edge_preconditions(gh, n, by)
    before = ticket_blockers(gh, n)
    block = verb == "block"
    for b in by:
        if (b in before) == block:
            continue
        gh_or_die("%s a blocking edge from ticket #%s on #%d" % ("add" if block else "remove", n, b),
                  gh.blocker_add if block else gh.blocker_remove, int(n), b)
    want = sorted(set(before) | set(by)) if block else [b for b in before if b not in by]
    verify_twice("read ticket #%s's blockers" % n,
                 "ticket #%s's blocking edges did not verify - checked twice, both failed" % n,
                 lambda: ticket_edges_verified(gh, n, want))
    ticket_blocked_by_rewrite(gh, n, want)


def ticket_block(gh, n: str, by: str) -> None:
    """`ticket block <n> --by <by>`: a native blocking edge on <n> for every
    --by issue it lacks."""
    ticket_edges_change(gh, "block", n, by)


def ticket_unblock(gh, n: str, by: str) -> None:
    """`ticket unblock <n> --by <by>`: the native blocking edge on <n>
    removed for every --by issue it has."""
    ticket_edges_change(gh, "unblock", n, by)


def ticket_reports_dir(root: str) -> str:
    """The directory the driver's saved ticket reports live in, under the
    checkout at <root>: .orchestrator/reports, one <n>.md each."""
    return "%s/%s/reports" % (root, ORCH_DIR_NAME)


def ticket_report_remove(root: str, n: str) -> None:
    """Ticket <n>'s saved report, under the checkout at <root>, dropped if it
    has one."""
    rm_f_or_die("%s/%s.md" % (ticket_reports_dir(root), n),
                "could not remove ticket #%s's saved report" % n)


def ticket_reset(gh, parent: str, root: str) -> None:
    """`ticket reset <parent>`: every sub-issue of <parent> that is closed,
    and only those, reopened after its saved report is dropped, then the
    parent's own saved report dropped - a collapsed breakdown's one ticket
    saves its report under the parent's number, and a left-over one would read
    as landed to `ticket reclaim`. Any GitHub failure dies."""
    for row in ticket_sub_issues(gh, parent):
        if row.state != "CLOSED":
            continue
        n = str(row.number)
        # The report goes first: once the ticket is open again no rerun
        # removes it, so a death between the two would strand it.
        ticket_report_remove(root, n)
        gh_or_die("reopen ticket #" + n, gh.issue_reopen, row.number)
    ticket_report_remove(root, parent)


# The comment a retire leaves on each ticket, and the wording a retire posted
# before a spec review could retire too: a ticket carrying either is already
# commented on.
RETIRED = ("This ticket was retired: its spec, #%s, changed and will be broken down into"
           " tickets again.")
RETIRED_BY_REDO = ("This ticket was retired by an orchestrator redo: its spec, #%s, is being"
                   " redone and will be broken down into tickets again.")


def ticket_retire(gh, parent: str, root: str) -> None:
    """`ticket retire <parent>`: every sub-issue of <parent> closed as not
    planned with the retirement comment, a closed one commented on unless it
    carries either wording, its saved report dropped and it unlinked; then the
    parent's own saved report dropped, every `## Ticket` section cut from its
    body and its breakdown save point removed. A breakdown already retired
    writes nothing. Any GitHub failure dies."""
    # Imported here, not at the top: the breakdown noun imports this module,
    # and only this one path lookup reaches back.
    from orch.breakdown import breakdown_dir

    subs = ticket_sub_issues(gh, parent)
    message, old_message = RETIRED % parent, RETIRED_BY_REDO % parent
    for row in subs:
        n = str(row.number)
        if row.state == "OPEN":
            gh_or_die("close ticket #" + n, gh.issue_close, row.number, reason="not planned",
                      comment=message)
        else:
            text = comments.rendered(gh, "read ticket #%s's comments" % n, n, "issue")
            if message not in text and old_message not in text:
                unmade = "could not create a temp file for the comment on ticket #" + n
                with temp_text_file(message + "\n", unmade, unmade) as path:
                    gh_or_die("comment on ticket #" + n, gh.issue_comment, row.number, path)
        # Before the unlink: once unlinked, no rerun lists the ticket to clean it.
        ticket_report_remove(root, n)
        gh_or_die("unlink ticket #%s from #%s" % (n, parent), gh.sub_issue_unlink, int(parent),
                  row.number)
    # A collapsed breakdown saved its report under the parent's own number.
    ticket_report_remove(root, parent)
    issue_body_rewrite(gh, parent, "read issue #%s's body" % parent,
                       "remove the ## Ticket section from #" + parent, strip_ticket_sections)
    # The save point goes with it, so `breakdown state` never reads a retired
    # breakdown as complete.
    rm_rf_or_die(breakdown_dir(root, parent),
                 "could not remove the breakdown save point of #" + parent)


def flag_value_once(usage: str, given: bool, left: int) -> None:
    """The rule for a flag that takes a value, shared by `ticket publish
    --blocked-by` and `ticket block`/`unblock --by`: dies with <usage> unless
    this is the flag's first appearance (<given> False) and a value follows
    it (<left>, the arguments left from the flag on, at least 2)."""
    if left < 2 or given:
        die(usage)


PUBLISH_USAGE = ("usage: orch.sh ticket publish <parent> <title> <body-file>"
                 " [--blocked-by N,N,...]")


def ticket_publish(args: List[str], gh_of, root: str) -> None:
    """`ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]`:
    a child issue published - ticket_create then ticket_link: a native
    sub-issue of <parent>, a native blocking edge for every --blocked-by
    number, this repo's ready-for-agent label, every link read back and its
    `## Blocked by` section rewritten - its number printed. Every argument
    check runs before the first GitHub write, and a second --blocked-by is
    refused, never allowed to replace the first."""
    if len(args) < 3:
        die(PUBLISH_USAGE)
    parent, title, body_file = args[:3]
    rest = args[3:]
    blocked_by: Optional[str] = None
    while rest:
        if rest[0] != "--blocked-by":
            die(PUBLISH_USAGE)
        flag_value_once(PUBLISH_USAGE, blocked_by is not None, len(rest))
        blocked_by, rest = rest[1], rest[2:]
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent)
    if not title:
        die("the title is empty")
    if not os.path.isfile(body_file):
        die("body file not found: " + body_file)
    # A wholly empty --blocked-by "" means no blockers. The list comes back
    # de-duplicated: GitHub stores a blocking edge once however often it is
    # requested, so a duplicate would leave the readback's set permanently
    # smaller than the one wanted and fail verification for a correct link.
    want = issue_number_list("--blocked-by", blocked_by) if blocked_by else []
    gh = gh_of()
    child = str(ticket_create(gh, TriageLabels(lambda: root), title, body_file))
    ticket_link(gh, parent, child, want)
    stdout_write(child + "\n")


def _one_arg(args: List[str], usage: str, code: int = 1) -> str:
    """The one argument of a verb that takes exactly one; dies with <usage>,
    exit <code>, on any other count."""
    if len(args) != 1:
        die(usage, code)
    return args[0]


def ticket_next(args: List[str], gh_of, _root: str) -> None:
    """`ticket next <parent>`: the parent's open sub-issues with no open
    blocker, one number a line, in the order GitHub published them. A
    sub-issue GitHub gave no dependency summary for is never read as
    unblocked."""
    parent = _one_arg(args, "usage: orch.sh ticket next <parent>")
    stdout_write("".join("%d\n" % row.number for row in ticket_sub_issues(gh_of(), parent)
                         if row.state == "OPEN" and row.open_blockers == 0))


def ticket_list(args: List[str], gh_of, _root: str) -> None:
    """`ticket list <parent>`: every sub-issue of <parent>, open or closed,
    one `<n> open|closed` line each, in the order GitHub published them - how
    a spec review finds the tickets its accepted edits touch without calling
    a sub-issue endpoint."""
    parent = _one_arg(args, "usage: orch.sh ticket list <parent>")
    stdout_write("".join("%d %s\n" % (row.number, state_word(row.state))
                         for row in ticket_sub_issues(gh_of(), parent)))


def ticket_parent(args: List[str], gh_of, _root: str) -> None:
    """`ticket parent <n>`: <n>'s parent issue number, or nothing (still exit
    0) when <n> is not a sub-issue. Every gh failure is a real one."""
    n = _one_arg(args, "usage: orch.sh ticket parent <n>")
    if not plain_number(n):
        die("not a plain issue number: " + n)
    parent = gh_or_die("read issue #%s's parent" % n, gh_of().issue_parent, int(n))
    if parent is not None:
        stdout_write("%d\n" % parent)


REPORT_USAGE = "usage: orch.sh ticket report save <n> <file> | show <n>"


def _nonempty_file(path: str) -> bool:
    """Whether <path> exists and is not empty, as bash's `[ -s ]` reads it."""
    try:
        return os.stat(path).st_size > 0
    except OSError:
        return False


def ticket_report(args: List[str], _gh_of, root: str) -> None:
    """`ticket report save <n> <file> | show <n>`: a returned ticket report
    outlives the driver session as .orchestrator/reports/<n>.md. A save
    replaces an earlier one, through a temporary file beside it; a missing or
    empty file is refused with nothing written, and `show` prints the saved
    bytes as they are, dying when no report is saved."""
    op, rest = (args[0], args[1:]) if args else ("", [])
    directory = ticket_reports_dir(root)
    if op not in ("save", "show") or len(rest) != (2 if op == "save" else 1):
        die(REPORT_USAGE)
    n = rest[0]
    if not plain_number(n):
        die("not a plain issue number: " + n)
    saved = "%s/%s.md" % (directory, n)
    if op == "show":
        if not os.path.isfile(saved):
            die("no saved report for ticket #" + n)
        text = read_raw(saved)
        if text is None:
            die("could not read ticket #%s's saved report" % n)
        stdout_write(text)
        return
    report = rest[1]
    if not _nonempty_file(report):
        die("report file %s is missing or empty - nothing saved" % report)
    mkdir_p_or_die(directory, "could not create " + directory)
    unsaved = "could not save ticket #%s's report" % n
    copy_or_die(report, saved + ".tmp", unsaved)
    try:
        os.replace(saved + ".tmp", saved)
    except OSError:
        die(unsaved)


def _exists(args: List[str], gh_of, _root: str) -> int:
    """`ticket exists <parent>`: ticket_exists's verdict printed, exit 0, or
    nothing and exit 1 for no breakdown. A usage error exits 2, never 1."""
    parent = _one_arg(args, "usage: orch.sh ticket exists <parent>", 2)
    kind = ticket_exists(gh_of(), parent)
    if kind is None:
        return 1
    stdout_write(kind + "\n")
    return 0


def _edge_args(verb: str, args: List[str]):
    """`ticket <verb> <n> --by N,N,...`'s target and --by list, the flag
    anywhere among them: dies with <verb>'s usage line on a missing target or
    --by, a second of either, a --by with no value, or any other flag."""
    usage = "usage: orch.sh ticket %s <n> --by N,N,..." % verb
    n = ""
    by: Optional[str] = None
    rest = list(args)
    while rest:
        if rest[0] == "--by":
            flag_value_once(usage, by is not None, len(rest))
            by, rest = rest[1], rest[2:]
            continue
        if rest[0].startswith("-") or n:
            die(usage)
        n, rest = rest[0], rest[1:]
    if not n or by is None:
        die(usage)
    return n, by


def _block(args: List[str], gh_of, _root: str) -> None:
    n, by = _edge_args("block", args)
    ticket_block(gh_of(), n, by)


def _unblock(args: List[str], gh_of, _root: str) -> None:
    n, by = _edge_args("unblock", args)
    ticket_unblock(gh_of(), n, by)


def _retire(args: List[str], gh_of, root: str) -> None:
    parent = _one_arg(args, "usage: orch.sh ticket retire <parent>")
    ticket_retire(gh_of(), parent, root)


def _reset(args: List[str], gh_of, root: str) -> None:
    parent = _one_arg(args, "usage: orch.sh ticket reset <parent>")
    ticket_reset(gh_of(), parent, root)


# The ops this noun runs, each taking the arguments after the op, the gh
# adapter's maker and the checkout's root, and returning its exit code (None
# for 0).
VERBS: Dict[str, Callable[[List[str], Callable[[], object], str], Optional[int]]] = {
    "publish": ticket_publish,
    "next": ticket_next,
    "list": ticket_list,
    "parent": ticket_parent,
    "report": ticket_report,
    "exists": _exists,
    "block": _block,
    "unblock": _unblock,
    "retire": _retire,
    "reset": _reset,
}


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
) -> int:
    """`orch.sh ticket <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    # The Repo, resolved once and memoised, for every gh call the op makes;
    # the adapter itself is made at the op's first GitHub call.
    gh_of = adapter_of(gh, env, pin=RepoPin(env, git))
    op = argv[0] if argv else ""
    verb = VERBS.get(op)
    if verb is None:
        die("unknown ticket op: %s (want %s)" % (op or "<none>", OPS))
    code = verb(argv[1:], gh_of, root)
    return 0 if code is None else code
