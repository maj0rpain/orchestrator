"""The spec-review noun's apply: a round's answer applied, the tickets
followed, the body published when it changed, any retire run, and the
changelog written to <dir>/changelog.md, posted, and appended to the
review-wide settled file, as the bash spec-review module had them, with its
arguments, messages, exit codes and order of checks.

Every check runs before the first write, so a refusal changes nothing; every
accepted edit is applied to the body as first fetched, <dir>/spec.fetched.md,
so a rerun never applies one twice. With an accepted edit and a ticket
breakdown but no --tickets the run pauses, exit 3, before any GitHub write,
printing the breakdown's kind; the session drafts tickets.md and runs apply
again with --tickets (orch/spec_review_tickets.py). Under autopilot a
round's fundamental items are held back (orch/spec.py's spec_round_hold): the
first run writes fundamental.md and exits 0, the run after the reply applies
the whole batch.

The GitHub writes go in a fixed order - ticket text edits, then edges, then
the body, then the retire, then the changelog comment - each through write(),
which appends its label to <dir>/applied.log once it lands. The labels are
the bash spec_review_write's, word for word, so a log bash wrote before the
noun's cutover resumes here.
The answer is saved (orch/spec.py's spec_round_answer_save) before the first
write, so `apply <dir> --resume --round <k>/<n>` reruns a dead apply with it,
skipping the writes applied.log records; with the changelog comment landed
only the round's local tail runs (orch/spec.py's spec_round_complete).

Flow mode, chosen by a missing --issue, takes the issue from one read of the
Flow state reader and refuses a done flow before any write. Either mode
writes the body and the comment through the in-process issue noun's update
and comment, the ticket writes through orch/ticket.py.
"""
from __future__ import annotations

import os
import re
import shutil
import sys
from typing import Callable, Dict, List, Mapping

from orch import spec, ticket
from orch.autopilot import autopilot_active
from orch.common import (capture, die, err_line, file_lines, plain_number, read_raw,
                         text_file_write)
from orch.flow_state import flow_state_file, require_issue
from orch.issue import Issue
from orch.marked_comment import marked_comment_write
from orch.spec_review_batch import (SPEC_REVIEW_LENSES, TITLES, Violations, decline_reason,
                                    lens_state_line, one_line, reasons_read, validate)
from orch.spec_review_tickets import (TICKETS_NO_BREAKDOWN, TICKETS_NO_EDIT, tickets_answer,
                                      tickets_follow, tickets_lines, tickets_parse)

USAGE = ("usage: orch.sh spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]"
         " [--tickets <answer> [--ticket-reasons <file>]] [--issue <n>] [--unattended]"
         " [--host-fallbacks <file>] | orch.sh spec-review apply <dir> --resume --round <k>/<n>")

# The options that take a value, and those of them whose value is a file the
# saved answer copies into the round directory.
VALUE_OPTIONS = ("--round", "--reasons", "--issue", "--host-fallbacks", "--tickets",
                 "--ticket-reasons")
FILE_OPTIONS = ("--reasons", "--ticket-reasons", "--host-fallbacks")


def label_changelog(issue: str) -> str:
    """The applied.log label of the changelog comment, which the resume
    reads back."""
    return "the changelog comment on issue #%s" % issue


def label_retire(issue: str) -> str:
    """The applied.log label of the breakdown's retire, which the resume
    reads back."""
    return "the retire of #%s's ticket breakdown" % issue


def _log(directory: str) -> str:
    return directory + "/applied.log"


def logged(directory: str, label: str) -> bool:
    """Whether <directory>/applied.log records <label>, as a line of its
    own."""
    return label in file_lines(_log(directory))


def landed(directory: str) -> str:
    """The writes <directory>/applied.log records, joined for a message, or
    "nothing" when none landed - each line a newline ends, as bash's read
    loop takes them."""
    text = read_raw(_log(directory)) if os.path.isfile(_log(directory)) else None
    labels = [line for line in (text or "").split("\n")[:-1] if line]
    return "; ".join(labels) or "nothing"


def write(directory: str, what: str, call: Callable[[], object]) -> None:
    """One GitHub write, <call>, appended to <directory>/applied.log as
    <what> once it lands; skipped when the log already records it. A failure
    dies naming <what> and every write already landed; nothing is rolled
    back and changelog.md stays."""
    if logged(directory, what):
        return
    _, err, code = capture(call)
    if code != 0:
        die("could not write %s: %s - already landed: %s; %s/changelog.md is kept, and the"
            " review stops here" % (what, err_line(err), landed(directory), directory))
    try:
        with open(_log(directory), "ab") as f:
            f.write((what + "\n").encode("utf-8", "surrogateescape"))
    except OSError:
        die("%s landed, but %s/applied.log could not record it" % (what, directory))


def local_write(path: str, text: str) -> None:
    """<text> written to <path>, exactly, before any GitHub write - so a
    failure dies saying none was made."""
    text_file_write(path, text, "could not write %s - nothing written to GitHub" % path)


def ticket_numbers(directory: str) -> List[str]:
    """The numbers of <directory>'s ticket-<n>.md files; the .fetched.md
    copies are not among them."""
    numbers = []
    for name in sorted(os.listdir(directory)):
        match = re.fullmatch(r"ticket-([0-9]+)\.md", name)
        if match:
            numbers.append(match.group(1))
    return numbers


def _copy(source: str, target: str, unmade: str) -> None:
    try:
        shutil.copyfile(source, target)
    except OSError:
        die(unmade)


def item_sections(item) -> List[str]:
    """The changelog sections an item is recorded under - its group's
    (Fidelity for contradicts-the-plan), every lens its findings cite, and
    Consolidation when it cites a comment."""
    sections = ["fidelity" if item.group == "contradicts-the-plan" else item.group]
    sections += [finding.lens for finding in item.findings]
    return sections + ["consolidation" for _ in item.comments]


def quotes(batch, item) -> str:
    """An item's findings, then its comments' quotes, each word for word on
    one line, in double quotes, joined by " / "."""
    texts = [batch.finding_text(f.lens, f.k) for f in item.findings]
    texts += [comment.quote for comment in item.comments]
    return " / ".join('"%s"' % one_line(text) for text in texts)


def item_line(batch, index: int, item, disposition, reasons: Dict[int, str],
              unattended: bool) -> str:
    """An item's changelog line. An applied item reads `- (<n>) <summary>`,
    minor or material alike (#1352)."""
    n = item.n
    if disposition.disposition == "applied":
        return "- (%s) %s" % (n, item.summary)
    if disposition.disposition == "taken":
        label = item.option(disposition.taken).label
        if unattended:
            return "- decision (%s): took %s - %s, as recommended" % (n, disposition.taken, label)
        return "- (%s) decision: took %s - %s" % (n, disposition.taken, label)
    if disposition.disposition == "declined":
        reason = decline_reason(reasons, index, disposition.as_recommended, item.arg)
        if item.group == "contradicts-the-plan":
            reason = "spec departs from the plan: " + reason
        return "- (%s) %s - %s" % (n, quotes(batch, item), reason)
    if disposition.disposition == "undecided":
        return "- (%s) %s - left undecided" % (n, quotes(batch, item))
    return "- (%s) resolved by (%s)" % (n, item.resolved)


def changelog(result, reasons: Dict[int, str], round_arg: str, unattended: bool, tickets: str,
              hosts: str) -> str:
    """The round's changelog, from the validated batch, its dispositions and
    the reasons: the spec-review marked comment's line, `Round <k> of <n>`,
    one section per lens and Consolidation, then Tickets and any host
    fallbacks - its trailing newlines dropped."""
    batch = result.batch
    k, _, n = round_arg.partition("/")
    out = marked_comment_write("spec-review") + "Round %s of %s\n" % (k, n)
    if unattended:
        out += "Unattended spec review, run from a quick implementation: applied as recommended.\n"
    for section in ("consolidation",) + SPEC_REVIEW_LENSES:
        out += "\n### %s\n" % TITLES[section]
        if section != "consolidation" and batch.lens(section).state != "ran":
            out += lens_state_line(batch.lens(section)) + "\n"
            continue
        lines = [item_line(batch, i, item, result.dispositions[i], reasons, unattended) + "\n"
                 for i, item in enumerate(batch.items) if section in item_sections(item)]
        out += "".join(lines) or "None\n"
    out += "\n### Tickets\n%s\n" % tickets
    if hosts:
        out += "\n**Host fallbacks:** %s\n" % hosts
    return out.rstrip("\n")


class Options:
    """apply's parsed arguments: <saved> the ones the saved answer keeps, in
    the order given."""

    def __init__(self) -> None:
        self.directory = self.answer = self.round = self.reasons = self.issue = ""
        self.hosts_file = self.ticket_answer = self.ticket_reasons = ""
        self.have_answer = self.unattended = False
        self.saved: List[str] = []


def _parse(args: List[str]) -> Options:
    options = Options()
    i = 0
    while i < len(args):
        arg = args[i]
        if arg in VALUE_OPTIONS:
            if i + 1 >= len(args) or not args[i + 1]:
                die("%s needs a value (%s)" % (arg, USAGE))
            value = args[i + 1]
            options.saved += [arg, value]
            attribute = {"--round": "round", "--reasons": "reasons", "--issue": "issue",
                         "--host-fallbacks": "hosts_file", "--tickets": "ticket_answer",
                         "--ticket-reasons": "ticket_reasons"}[arg]
            setattr(options, attribute, value)
            i += 2
            continue
        if arg == "--unattended":
            options.unattended = True
            options.saved.append(arg)
            i += 1
            continue
        # An override answer may begin with -, as -4: before <dir> any leading
        # dash makes an unknown option, after it only a double one - one dash
        # is stripped first, so a single dash starts the answer.
        option_like = arg if not options.directory else (arg[1:] if arg.startswith("-") else arg)
        if option_like.startswith("-"):
            die("unknown option: %s (%s)" % (arg, USAGE))
        if not options.directory:
            options.directory = arg
        elif not options.have_answer:
            options.answer, options.have_answer = arg, True
            options.saved.append(arg)
        else:
            die(USAGE)
        i += 1
    return options


def _resume_args(given: List[str]) -> List[str]:
    """`apply <dir> --resume --round <k>/<n>`'s arguments: <dir>, then the
    answer the dead apply saved, after its own checks."""
    directory = round_arg = ""
    i = 0
    while i < len(given):
        arg = given[i]
        if arg == "--round":
            if i + 1 >= len(given) or not given[i + 1]:
                die("--round needs a value (%s)" % USAGE)
            round_arg = given[i + 1]
            i += 2
        elif arg.startswith("-"):
            die("--resume takes only <dir> and --round <k>/<n>, got: %s (%s)" % (arg, USAGE))
        else:
            if directory:
                die(USAGE)
            directory = arg
            i += 1
    if not directory or not round_arg:
        die(USAGE)
    if not os.path.isdir(directory):
        die("no such directory: " + directory)
    directory = directory[:-1] if directory.endswith("/") else directory
    if spec.spec_round_state(directory) != "applying":
        die("--resume: %s holds no %s - there is no apply to resume; run apply with its answer"
            % (directory, spec.spec_round_answer_name()))
    return [directory, round_arg] + spec.spec_round_answer_load(directory)


def _hosts(path: str) -> str:
    """The --host-fallbacks file's text on one line."""
    if not os.path.isfile(path):
        die("--host-fallbacks file not found: " + path)
    text = read_raw(path)
    if text is None:
        die("--host-fallbacks file is unreadable: " + path)
    hosts = one_line(text.replace("\x00", "").rstrip("\n"))
    if not hosts:
        die("--host-fallbacks file is empty: " + path)
    return hosts


def _flow_issue(root: str, env: Mapping[str, str]) -> str:
    """The active flow's issue, from one read of its phase and issue;
    refusing a done flow before any write."""
    state = require_issue(flow_state_file(root), env, ("phase",))
    if state["phase"] == "done":
        die("the flow on issue #%s is done - spec-review apply acts only on an active flow's"
            " issue; for another issue use --issue <n>" % state["issue"])
    return state["issue"]


def _held_blocks(result) -> str:
    """The held-back items' blocks in the batch grammar, behind the batch's
    `@@ lens` lines, from the batch file as validate read it: every line
    newline-ended, as grep and awk print them."""
    held = {item.n for item in result.batch.items if item.fundamental}
    lines = result.batch_text.split("\n")
    if lines[-1] == "":
        lines.pop()
    lens_lines = [line + "\n" for line in lines if line.startswith("@@ lens ")]
    item_lines = []
    keep = False
    for line in lines:
        if line.startswith("@@ item "):
            fields = re.split(r"[ \t]+", line.strip(" \t"))
            keep = len(fields) > 2 and fields[2] in held
        if keep:
            item_lines.append(line + "\n")
    return "".join(lens_lines + item_lines)


def apply(argv: List[str], gh_of: Callable[[], object], git, env: Mapping[str, str],
          root: str) -> int:
    """`spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
    [--tickets <answer> [--ticket-reasons <file>]] [--issue <n>]
    [--unattended] [--host-fallbacks <file>]`, or `spec-review apply <dir>
    --resume --round <k>/<n>`: its exit code, 3 for the ticket pause. <gh_of>
    makes the gh adapter, at the first GitHub call."""
    resume = "--resume" in argv
    given = [arg for arg in argv if arg != "--resume"]
    resumed_round = ""
    if resume:
        resumed = _resume_args(given)
        resumed_dir, resumed_round = resumed[0], resumed[1]
        given = [resumed_dir] + resumed[2:]
    options = _parse(given)
    if resume and resumed_round != options.round:
        die("--resume --round %s: the saved answer in %s is for round %s"
            % (resumed_round, resumed_dir, options.round))
    if not options.directory or not options.have_answer:
        die(USAGE)
    if not options.round:
        die("--round <k>/<n> is required (%s)" % USAGE)
    spec.spec_round_count_parse(options.round)
    issue = options.issue
    if issue and not plain_number(issue):
        die("--issue must be a plain issue number, got: " + issue)
    ticket_answer = options.ticket_answer
    if ticket_answer not in ("", "recommended", "all", "none", "retire") and re.search(
            r"[^0-9, ]", ticket_answer):
        die("--tickets wants recommended, all, none, retire or a list such as 1, 3, got: "
            + ticket_answer)
    if options.ticket_reasons and not ticket_answer:
        die("--ticket-reasons goes with --tickets: it holds the ticket answer's decline reasons")
    if options.unattended:
        if not issue:
            die("--unattended needs --issue: an unattended spec review is a standalone one")
        if options.answer != "recommended":
            die("--unattended takes only the answer recommended, got: " + options.answer)
        if ticket_answer not in ("", "recommended"):
            die("--unattended takes only --tickets recommended, got: " + ticket_answer)
    directory = options.directory
    if not os.path.isdir(directory):
        die("no such directory: " + directory)
    directory = directory[:-1] if directory.endswith("/") else directory
    if not resume and spec.spec_round_state(directory) == "applying":
        die("%s/%s holds the answer of an apply that died - run spec-review apply %s --resume"
            " --round %s to resume it"
            % (directory, spec.spec_round_answer_name(), directory, options.round))
    if not resume and os.path.exists(_log(directory)) and os.path.getsize(_log(directory)) > 0:
        die("%s/applied.log records writes that already landed: %s - this review stopped at a"
            " failed write; apply refuses to run again" % (directory, landed(directory)))
    # An autopilot round's two runs (orch/spec.py's spec_round_hold): the
    # first holds the fundamental items back and writes nothing else, the run
    # after the reply, finding fundamental.md, applies the whole batch.
    run = ""
    if autopilot_active(env):
        run = "resume" if spec.spec_round_held(directory) else "hold"
    hosts = _hosts(options.hosts_file) if options.hosts_file else ""
    flow = not issue
    if flow:
        issue = _flow_issue(root, env)

    # The changelog comment landed: only the local tail is left.
    if resume and logged(directory, label_changelog(issue)):
        if not os.path.isfile(directory + "/changelog.md"):
            die("changelog.md not found in " + directory)
        settled_log = read_raw(directory + "/changelog.md")
        if settled_log is None:
            die("could not read %s/changelog.md - every GitHub write landed: %s"
                % (directory, landed(directory)))
        spec.spec_round_complete(directory, settled_log.replace("\x00", "").rstrip("\n"),
                                 landed(directory))
        return 0
    if not os.path.isfile(directory + "/spec.md"):
        die("spec.md not found in " + directory)
    if not os.path.isfile(directory + "/batch.md"):
        die("batch.md not found in " + directory)
    if not os.path.exists(directory + "/spec.fetched.md"):
        _copy(directory + "/spec.md", directory + "/spec.fetched.md",
              "could not copy spec.md to %s/spec.fetched.md - nothing written" % directory)
    # Each ticket file's fetched copy, taken by the first run that finds the
    # file - the --tickets rerun, as the session fetches tickets after the
    # pause.
    for t in ticket_numbers(directory):
        if not os.path.exists("%s/ticket-%s.fetched.md" % (directory, t)):
            _copy("%s/ticket-%s.md" % (directory, t), "%s/ticket-%s.fetched.md" % (directory, t),
                  "could not copy ticket-%s.md to %s/ticket-%s.fetched.md - nothing written"
                  % (t, directory, t))

    # Every anchor checked against the fetched copy, and every accepted one
    # applied to it; the first problem refuses the batch.
    result = validate(directory, directory + "/spec.fetched.md", Violations(collect=False), env,
                      options.answer, run)
    if result.problems:
        die(result.problems[0] + " - nothing applied, nothing written")
    batch = result.batch
    if run == "hold" and any(item.fundamental for item in batch.items):
        spec.spec_round_hold(directory, _held_blocks(result))
        return 0
    reasons = reasons_read("--reasons", options.reasons, [item.n for item in batch.items],
                           [result.dispositions[i].disposition == "declined"
                            for i in range(len(batch.items))],
                           "item", "batch.md", "the answer")

    # The ticket step's entry: only an applied edit can leave a ticket behind.
    gh_made: List[object] = []

    def gh():
        if not gh_made:
            gh_made.append(gh_of())
        return gh_made[0]

    text, changed = result.text, result.text != result.fetched
    tickets = TICKETS_NO_EDIT
    kind, breakdown = "", changed
    copies: Dict[str, object] = {}
    items = None
    if changed and resume and logged(directory, label_retire(issue)):
        # The dead run's retire landed, so the live state no longer shows the
        # breakdown it decided on; the rerun keeps that decision.
        kind = ""
    elif changed:
        kind, err, code = capture(lambda: ticket.ticket_exists(gh(), issue))
        if code == 0 and kind is None:
            code = 1
        if code == 1:
            tickets, breakdown = TICKETS_NO_BREAKDOWN, False
        elif code != 0:
            die("ticket exists #%s exited %d: %s - nothing written" % (issue, code, err_line(err)))
    if breakdown:
        if not ticket_answer:
            # The pause: the session drafts the ticket items and runs apply
            # again.
            local_write(directory + "/spec.md", text)
            spec.spec_round_answer_clear(directory, landed(directory))
            print(kind)
            return 3
        if not os.path.isfile(directory + "/tickets.md"):
            die("tickets.md not found in %s - --tickets answers the ticket items it holds"
                % directory)
        items = tickets_parse(read_raw(directory + "/tickets.md") or "", Violations(collect=False))
        taken = tickets_answer(items, ticket_answer)
        ticket_reasons = reasons_read(
            "--ticket-reasons", options.ticket_reasons, [item.n for item in items.items],
            [taken.dispositions.get(i) == "declined" for i in range(len(items.items))],
            "ticket item", "tickets.md", "the --tickets answer")
        followed = tickets_follow(gh(), items, taken, directory, text, kind, issue)
        text, copies = followed.body.text, followed.copies
        tickets = tickets_lines(items, taken, ticket_reasons)
    local_write(directory + "/spec.md", text)
    for t, copy in copies.items():
        local_write("%s/ticket-%s.md" % (directory, t), copy.text)

    # The answer saved before the first GitHub write, for --resume to rerun; a
    # resumed run keeps the file it was resumed from.
    if not resume:
        spec.spec_round_answer_save(directory, FILE_OPTIONS, options.saved)
    log = changelog(result, reasons, options.round, options.unattended, tickets, hosts)
    local_write(directory + "/changelog.md", log + "\n")

    issues = Issue(gh(), git, env)
    # Ticket text edits, then edges, then the body, then the retire: a ticket's
    # text edit before its edge, whose ## Blocked by rewrite reads the edited
    # body back; a collapsed ## Ticket edit inside the body; a retire after it.
    applied = [] if items is None else [
        item for i, item in enumerate(items.items) if taken.applied(i)]
    done = []
    for item in applied:
        if item.kind == "ticket" and item.t not in done:
            done.append(item.t)
            write(directory, "ticket #%s's body" % item.t, lambda t=item.t: issues.update(
                [t, "%s/ticket-%s.md" % (directory, t)]))
    for item in applied:
        if item.kind in ("block", "unblock"):
            change = ticket.ticket_block if item.kind == "block" else ticket.ticket_unblock
            write(directory, "%s #%s by #%s" % (item.kind, item.t, item.b),
                  lambda item=item, change=change: change(gh(), item.t, item.b))
    if changed:
        write(directory, "the body of issue #" + issue,
              lambda: issues.update([issue, directory + "/spec.md"]))
    if items is not None and taken.retire:
        write(directory, label_retire(issue), lambda: ticket.ticket_retire(gh(), issue, root))
    write(directory, label_changelog(issue),
          lambda: issues.comment([issue, directory + "/changelog.md"]))
    spec.spec_round_complete(directory, log, landed(directory))
    return 0
