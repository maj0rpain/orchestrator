"""The spec-review noun: a standalone spec review's start, the wait for a
round's lenses and a lens's prompt. run() is the noun's entry point.

begin's guard and working-directory reset each have one right answer, so
they live here rather than in skill prose. It reads state.json only when one
exists (the Flow state reader, orch/flow_state.py), in one read of the flow's
phase and issue, and never writes it: the issue number is the caller's, and
the guard only compares. With --carry, given on rounds 2 and later, the reset
keeps what a round hands the next (orch/spec.py's dir_reset).

wait is the session's one blocking call for a round's lenses, run in the
response that starts them, so a lens's hand-back queues behind it instead of
taking a turn of its own. A lens is back when its findings file exists: each
lens writes it last. It is a re-callable command (ADR-0065): a call blocks at
most ORCH_WAIT_BLOCK seconds, and the total is stored across calls
(orch/wait.py's StoredTotal) under the key `spec-review wait <resolved dir>
<lens>...`, bash's, so a wait begun under either language goes on under the
other. How long it lasts and how often it looks are the
ORCH_SPEC_REVIEW_WAIT_TIMEOUT and ORCH_SPEC_REVIEW_WAIT_INTERVAL knobs.

prompt prints a lens's whole prompt, for the session to pass unchanged: path
existence is a fact orch.sh hands the lens, never one the lens discovers, so a
lens never probes a round file that is not there. Fidelity runs only in a
flow's round directory, its plan handoff the path `handoff path spec` gives
(orch/handoff.py), under autopilot read from the issue's comment.

check validates a round's batch before the batch question, as apply would
take the all answer (orch/spec_review_batch.py), with nothing written but
<dir>/view.md: every violation it can stand behind in one run, one `orch:`
line each, exit 1 and any earlier view.md left as it was; on a pass the view
on stdout, saved to view.md, and one pass line on stderr ending in the nudge -
the paste guards arm on its "; it is saved in <path>/view.md" tail - or,
with --unattended, in a tail of its own they never arm on. check --tickets
validates the round's tickets.md the same way (orch/spec_review_tickets.py),
reading no GitHub; with @@ none-affected it removes any earlier view.md and
saves none. apply applies a round's answer and publishes it
(orch/spec_review_apply.py).
"""
from __future__ import annotations

import os
import sys
import time
from typing import Callable, List, Mapping, Optional

from orch import spec, spec_review_apply
from orch.common import (ORCH_DIR_NAME, capture, die, err_line, file_lines, plain_number,
                         read_raw, require_poll_knobs, text_file_write, warn)
from orch.flow_state import STATE_UNREADABLE_MSG, flow_state_file, flow_state_get_many
from orch.gh import adapter
from orch.git import Git
from orch.handoff import handoff_path
from orch.host import flow_cmd
from orch.root import checkout_root, working_directory
from orch.spec_review_batch import (SPEC_REVIEW_LENSES, TITLES, Edited, Violations, lens_known,
                                    lens_state_line, validate)
from orch.spec_review_tickets import Tickets, TicketsOffline, tickets_parse
from orch.wait import StoredTotal, still_running, wait_block

# The verbs. docs_lint.sh reads a converted noun's verbs from this line, so it
# stays one `OPS = "<verb>|..."` line.
OPS = "begin|check|apply|wait|prompt"

BEGIN_USAGE = "usage: orch.sh spec-review begin <n> [--carry]"

# The wait's knobs and their defaults: how long it lasts, and how often it
# looks.
WAIT_TIMEOUT = ("ORCH_SPEC_REVIEW_WAIT_TIMEOUT", "900")
WAIT_INTERVAL = ("ORCH_SPEC_REVIEW_WAIT_INTERVAL", "5")


def require_lens(name: str) -> None:
    if not lens_known(name):
        die("unknown lens '%s' (want one of: %s)" % (name, " ".join(SPEC_REVIEW_LENSES)))


def _knob(env: Mapping[str, str], knob) -> str:
    """The knob's value in <env>, its default when unset or empty."""
    name, default = knob
    return env.get(name, "") or default


def begin(argv: List[str], env: Mapping[str, str], root: str) -> int:
    """`spec-review begin <n> [--carry]`: prints <root>/.orchestrator/
    spec-review/<n>/, reset, unless an active flow holds issue <n>."""
    if len(argv) == 2:
        if argv[1] != "--carry":
            die(BEGIN_USAGE)
    elif len(argv) != 1:
        die(BEGIN_USAGE)
    carry = len(argv) == 2
    issue = argv[0]
    if not plain_number(issue):
        die("issue must be a plain issue number, got: %s" % issue)
    state_file = flow_state_file(root)
    if os.path.isfile(state_file):
        state = flow_state_get_many(state_file, ("phase", "issue"))
        if state is None:
            die(STATE_UNREADABLE_MSG)
        phase = state["phase"]
        if phase != "done" and state["issue"] == issue:
            if phase == "spec":
                die("the active flow holds issue #%s at phase spec - the flow's own spec phase"
                    " will review it; run %s" % (issue, flow_cmd(env, "next")))
            if phase in ("implement", "review"):
                die("the active flow holds issue #%s at phase %s - the ticket subagents build"
                    " from this spec, so it cannot change behind the flow; run %s to step back"
                    " to the spec phase" % (issue, phase, flow_cmd(env, "redo")))
            die("the active flow holds issue #%s at phase '%s', which is not a flow phase -"
                " refusing to review it; run orch.sh doctor --flow" % (issue, phase))
    # Built from the validated number alone, so the wipe stays inside
    # spec-review/.
    directory = "%s/%s/spec-review/%s" % (root, ORCH_DIR_NAME, issue)
    spec.dir_reset(directory, carry=carry)
    print(directory + "/")
    return 0


def finding_count(path: str) -> int:
    """The `@@ finding ` lines of the findings file at <path>; 0 when it
    cannot be read."""
    return sum(1 for line in file_lines(path) if line.startswith("@@ finding "))


def wait(argv: List[str], env: Mapping[str, str], root: str,
         clock: Callable[[], float], sleep: Callable[[float], None]) -> int:
    """`spec-review wait <dir> <lens>...`: once <dir>/lens-<lens>.md exists
    for every named lens, prints `lenses back: <lens> <count>, ...` in the
    order named, <count> its `@@ finding ` lines - the file is not validated
    here. While one is missing, a call ends as still running once it has
    blocked its block, nothing on stdout; on the total timeout, nothing on
    stdout and exit 1 naming the lenses still missing."""
    if len(argv) < 2:
        die("usage: orch.sh spec-review wait <dir> <lens>...")
    directory = argv[0][:-1] if argv[0].endswith("/") else argv[0]
    lenses = argv[1:]
    if not os.path.isdir(directory):
        die("no such directory: " + directory)
    for lens in lenses:
        require_lens(lens)
    timeout, interval = _knob(env, WAIT_TIMEOUT), _knob(env, WAIT_INTERVAL)
    require_poll_knobs([(WAIT_TIMEOUT[0], timeout), (WAIT_INTERVAL[0], interval)])
    block = wait_block(env)
    # The total belongs to this directory and these lenses; it is forgotten
    # once a call delivers an outcome.
    key = "spec-review wait %s %s" % (os.path.realpath(directory), " ".join(lenses))
    total = StoredTotal.open("%s/%s" % (root, ORCH_DIR_NAME), key, block,
                             clock=clock, sleep=sleep)
    while True:
        missing = [lens for lens in lenses
                   if not os.path.exists("%s/lens-%s.md" % (directory, lens))]
        if not missing:
            break
        if not total.taken() < float(timeout):
            total.forget()
            die("lenses not back after %ss:%s" % (timeout, "".join(" " + m for m in missing)))
        if not total.tick(interval):
            return still_running(block)
    total.forget()
    print("lenses back: " + ", ".join(
        "%s %d" % (lens, finding_count("%s/lens-%s.md" % (directory, lens))) for lens in lenses))
    return 0


def prompt_line(label: str, path: str) -> str:
    """`<label>: <path>` when <path> exists, `<label>: none` otherwise - an
    input the lens reads only when given."""
    return "%s: %s" % (label, path if os.path.exists(path) else "none")


def plan_handoff(gh, env: Mapping[str, str], root: str) -> str:
    """The Fidelity prompt's plan handoff, the path `handoff path spec`
    prints; dies, as bash's capture of it does, quoting its message or naming
    the path that does not exist."""
    answer, err, code = capture(lambda: handoff_path("spec", gh, env, root))
    if code == 0 and answer[1]:
        return answer[0]
    if err:
        die("no plan handoff for the Fidelity prompt: " + err_line(err))
    die("no plan handoff for the Fidelity prompt: %s does not exist" % answer[0])


def prompt(argv: List[str], gh, env: Mapping[str, str], root: str) -> int:
    """`spec-review prompt <dir> <lens>`: prints <lens>'s prompt, one
    labelled line per path in its row of the lens table, every path
    absolute, the findings file last. <dir> is a standalone review's
    directory or a flow's round directory, holding spec.md and comments.md,
    which the session fetched first. A missing optional input prints none;
    the findings file and the Implementability map file are write targets,
    always given."""
    if len(argv) != 2:
        die("usage: orch.sh spec-review prompt <dir> <lens>")
    given, lens = argv
    directory = given[:-1] if given.endswith("/") else given
    require_lens(lens)
    if not os.path.isdir(directory):
        die("no such directory: " + directory)
    if not os.access(directory, os.X_OK):
        die("cannot resolve the directory: " + given)
    directory = os.path.realpath(directory)
    if not os.path.isfile(directory + "/spec.md"):
        die("no spec body: %s/spec.md does not exist - fetch it first" % directory)
    if not os.path.isfile(directory + "/comments.md"):
        die("no comments file: %s/comments.md does not exist - fetch it first" % directory)
    plan = ""
    if lens == "fidelity":
        rounds = spec.rounds_dir(root)
        if not spec.in_flow(directory, rounds):
            die("the Fidelity lens runs only in a flow's spec review: %s is not under %s/"
                % (directory, rounds))
        plan = plan_handoff(gh(), env, root)
    lines = ["Spec body: %s/spec.md" % directory, "Comments: %s/comments.md" % directory]
    if lens == "consistency":
        lines += [prompt_line("Glossary", directory + "/glossary.md"),
                  prompt_line("ADR directory", root + "/docs/adr/")]
    elif lens == "testability":
        lines.append("Repo root: " + root)
    elif lens == "implementability":
        lines += ["Repo root: " + root,
                  prompt_line("Previous map", directory + "/map-implementability.md"),
                  "Map file: %s/map-implementability.md" % directory]
    else:
        lines.append("Plan handoff: " + plan)
    lines += [prompt_line("Settled", directory + "/settled.md"),
              "Findings file: %s/lens-%s.md" % (directory, lens)]
    print("\n".join(lines))
    return 0


CHECK_USAGE = "usage: orch.sh spec-review check <dir> [--tickets | --full <n>...]"

# What a check pass line that saved a view ends with: the instruction to end
# the turn on one plain-text reply holding the view word for word and the
# question, with no tool call (ADR-0051), and the view.md it was saved to, by
# absolute path. The bash spec_review_nudge's words, unchanged: the paste guards
# (scripts/paste-guard.sh) arm on a pass line ending "; it is saved in
# <path>/view.md", their PASTE_GUARD_NEEDLE.
NUDGE = (" - end your turn on one plain-text reply, no tool call: the view above word for word,"
         " then the question with its answer words spelled out; it is saved in %s")

# What an --unattended pass line ends with in place of the nudge. It carries
# no "; it is saved in" tail, so the paste guards never arm on it.
UNATTENDED_TAIL = " - unattended: not a turn-final reply; go straight on to apply"

def view_path(directory: str, env: Mapping[str, str]) -> str:
    """<directory>/view.md's absolute path - <directory> taken from the
    working directory, as bash's $PWD names it, when relative; symlinks left
    as named."""
    if directory.startswith("/"):
        return directory + "/view.md"
    return "%s/%s/view.md" % (working_directory(env), directory)


def nudge(directory: str, env: Mapping[str, str]) -> str:
    return NUDGE % view_path(directory, env)


def group_title(item) -> str:
    """The title an item's header gives its group: Contradicts the plan, else
    its section's heading."""
    if item.group == "contradicts-the-plan":
        return "Contradicts the plan"
    return TITLES[item.group]


def option_line(item, option) -> str:
    """A decision item's option as both views name it - `Option <L> -
    <label>`, then ` (recommended)` when it is the recommended one."""
    recommended = " (recommended)" if option.letter == item.arg else ""
    return "Option %s - %s%s" % (option.letter, option.label, recommended)


def quoted(text: str) -> str:
    """<text> as a markdown blockquote, line for line."""
    return "".join("> %s\n" % line if line else ">\n" for line in text.split("\n"))


def code_fenced(text: str) -> str:
    """<text> in a code block whose fence of backticks is longer than any run
    of backticks in it, so a fence in the text stays text."""
    fence = "```"
    while fence in text:
        fence += "`"
    return "%s\n%s\n%s" % (fence, text, fence)


def edit_view(edit) -> str:
    """An edit's Current and Proposed, both in full."""
    return "\n**Current**\n\n%s\n\n**Proposed**\n\n%s\n" % (
        code_fenced(edit.anchor), code_fenced(edit.replace))


def item_view(batch, item) -> str:
    """An item in full - its group, its recommendation (a resolved item's
    resolving item), the text of each finding it cites and of each comment it
    folds in, and its edit, or each option's, in full."""
    recommendation = {
        "apply": "apply",
        "decline": "recommend decline - " + item.arg,
        "decision": "decision - option %s recommended" % item.arg,
        "resolved": "resolved by item %s" % item.resolved,
    }[item.rec]
    out = "\n### Item %s - %s\n\n**Recommendation:** %s\n" % (
        item.n, group_title(item), recommendation)
    for finding in item.findings:
        out += "\n**Finding** (%s %s):\n\n" % (TITLES[finding.lens], finding.k)
        out += quoted(batch.finding_text(finding.lens, finding.k).rstrip("\n"))
    for comment in item.comments:
        out += "\n**Comment** by %s, %s:\n\n" % (comment.login, comment.created)
        out += quoted(comment.quote)
    if item.rec in ("apply", "decline"):
        out += edit_view(item.edit)
    elif item.rec == "decision":
        for option in item.options:
            out += "\n#### %s\n" % option_line(item, option) + edit_view(option.edit)
    return out


def minor_line(item) -> str:
    """A minor or resolved item on one line - `- **<n>** - <Group>:
    <summary>`, a recommend-decline's reason after it, or a resolved item's
    resolving item in place of a summary. The number is literal, never a
    Markdown ordered-list number a renderer would recount."""
    head = "- **%s** - %s: " % (item.n, group_title(item))
    if item.rec == "resolved":
        return head + "resolved by item %s\n" % item.resolved
    if item.rec == "decline":
        return head + "%s - recommend decline: %s\n" % (item.summary, item.arg)
    return head + item.summary + "\n"


def material_entry(item) -> str:
    """A material item as one entry of the compact view's list, under its
    literal batch.md number: one line, its summary and its reason; a decision
    item's header, then one sub-bullet per option, indented a fixed 2 spaces,
    so none is ever a 4-space code block. No citation and no diff: --full
    shows those."""
    head = "- **%s** - **%s**" % (item.n, group_title(item))
    if item.rec == "apply":
        return "%s - %s (apply) - %s\n" % (head, item.summary, item.why)
    if item.rec == "decline":
        return "%s - %s (recommend decline: %s) - %s\n" % (head, item.summary, item.arg, item.why)
    out = "%s (decision, option %s recommended) - %s\n" % (head, item.arg, item.why)
    for option in item.options:
        out += "  - %s: %s\n" % (option_line(item, option), option.summary)
    return out


def batch_view(batch) -> str:
    """The parsed batch as the human reads it before the batch question: the
    lens lines, worded as the changelog words them, then the material items as
    one list in batch order, then, under a Minor edits heading left out when
    there are none, every minor and resolved item on one line, in batch
    order."""
    out = "## The batch\n\n### Lenses\n\n"
    for lens in batch.lenses:
        out += "- %s: %s\n" % (TITLES[lens.name], lens_state_line(lens))
    material = [item for item in batch.items if item.mark == "material"]
    minor = [item for item in batch.items if item.mark != "material"]
    if material:
        out += "\n" + "".join(material_entry(item) for item in material)
    if minor:
        out += "\n### Minor edits\n\n" + "".join(minor_line(item) for item in minor)
    return out


def tickets_view(tickets: Tickets) -> str:
    """The parsed tickets.md as the human reads it before the ticket
    question - every item in order, with its ticket or the `## Ticket`
    section, its recommendation and its edit in full, then the closed
    tickets and the file's recommended answer; with @@ none-affected, a stub
    saying so."""
    out = "## The ticket items\n"
    if tickets.none_affected:
        return out + "\nNo open ticket is affected.\n"
    for item in tickets.items:
        if item.kind == "ticket":
            target = "#" + item.t
        elif item.kind == "section":
            target = "the `## Ticket` section"
        else:
            target = "%s #%s by #%s" % (item.kind, item.t, item.b)
        out += "\n### Item %s - %s\n" % (item.n, target)
        if item.rec == "apply":
            out += "\n**Recommendation:** apply\n"
        else:
            out += "\n**Recommendation:** recommend decline - %s\n" % item.arg
        if item.text():
            out += edit_view(item.edit)
    out += "\n### Closed tickets\n\n"
    out += "".join("- #%s - %s\n" % (closed.t, closed.what) for closed in tickets.closed)
    if not tickets.closed:
        out += "None\n"
    if tickets.recommend == "apply":
        return out + "\n**Recommended answer:** apply\n"
    return (out + "\n**Recommended answer:** retire - the ticket breakdown retired, to be"
            " broken down again\n")


def tickets_check(directory: str, unattended: bool, env: Mapping[str, str]) -> int:
    """`spec-review check <dir> --tickets [--unattended]`: <dir>/tickets.md
    validated as apply --tickets would take the all answer, against the
    ticket copies and <dir>/spec.md, with nothing written but view.md and no
    GitHub read. A structure violation stops the run after the content
    violations before it; otherwise every problem is reported, content
    violations first, and exits 1. A clean file prints its view, saved to
    view.md, and the pass line; with @@ none-affected its stdout is a stub,
    any earlier view.md is removed, none written, and the pass line names
    none."""
    if not os.path.isfile(directory + "/tickets.md"):
        die("tickets.md not found in " + directory)
    if not os.path.isfile(directory + "/spec.md"):
        die("spec.md not found in " + directory)
    violations = Violations(collect=True)
    tickets = tickets_parse(read_raw(directory + "/tickets.md") or "", violations)
    body = read_raw(directory + "/spec.md")
    if body is None:
        violations.stop("could not read %s/spec.md" % directory)
    offline = TicketsOffline(directory, Edited(body.replace("\x00", "")), violations)
    # The all answer applies every item, a recommended decline included.
    for item in tickets.items:
        offline.visit(item, True)
    if violations.recorded or offline.problems:
        violations.flush()
        for problem in offline.problems:
            warn(problem)
        return 1
    view = tickets_view(tickets)
    if tickets.none_affected:
        try:
            os.remove(directory + "/view.md")
        except FileNotFoundError:
            pass
        except OSError:
            die("could not remove " + view_path(directory, env))
        sys.stdout.write(view)
        sys.stdout.flush()
        sys.stderr.write("tickets.md passes: no open ticket affected\n")
        return 0
    text_file_write(directory + "/view.md", view, "could not write " + view_path(directory, env))
    sys.stdout.write(view)
    sys.stdout.flush()
    tail = UNATTENDED_TAIL if unattended else nudge(directory, env)
    sys.stderr.write("tickets.md passes: %d items, %d anchors, each matching once, and the all"
                     " answer applies cleanly%s\n" % (len(tickets.items), offline.anchors, tail))
    return 0


def check(argv: List[str], env: Mapping[str, str]) -> int:
    """`spec-review check <dir> [--full <n>... | --unattended]`: the round's
    batch validated as apply would take the all answer, against
    <dir>/spec.fetched.md when it exists, else <dir>/spec.md. Every violation
    it can stand behind is reported in one run - content violations,
    citation errors, then anchor problems - and exits 1, writing nothing; a
    clean batch prints its view, saved to <dir>/view.md, and the pass line on
    stderr. With --full, the named items alone, each in full, in the order
    named."""
    directory = ""
    tickets = full = unattended = False
    wanted: List[str] = []
    for arg in argv:
        if arg == "--tickets":
            tickets = True
        elif arg == "--full":
            full = True
        elif arg == "--unattended":
            unattended = True
        elif arg.startswith("-"):
            die("unknown option: %s (%s)" % (arg, CHECK_USAGE))
        elif full:
            wanted.append(arg)
        else:
            if directory:
                die(CHECK_USAGE)
            directory = arg
    if not directory:
        die(CHECK_USAGE)
    if full and tickets:
        die("--full and --tickets do not combine (%s)" % CHECK_USAGE)
    if full and not wanted:
        die("--full needs at least one item number (%s)" % CHECK_USAGE)
    if full and unattended:
        die("--full and --unattended do not combine (%s)" % CHECK_USAGE)
    if directory.endswith("/"):
        directory = directory[:-1]
    if not os.path.isdir(directory):
        die("no such directory: " + directory)
    if tickets:
        return tickets_check(directory, unattended, env)
    if not os.path.isfile(directory + "/batch.md"):
        die("batch.md not found in " + directory)
    body = "spec.fetched.md"
    if not os.path.lexists("%s/%s" % (directory, body)):
        body = "spec.md"
    if not os.path.isfile("%s/%s" % (directory, body)):
        die("spec.md not found in " + directory)
    violations = Violations(collect=True)
    result = validate(directory, "%s/%s" % (directory, body), violations, env)
    if violations.recorded or result.problems:
        violations.flush()
        for problem in result.problems:
            warn(problem)
        return 1
    batch = result.batch
    if full:
        for n in wanted:
            if batch.item(n) is None:
                die("--full %s: batch.md has no item %s" % (n, n))
        view = "".join(item_view(batch, batch.item(n)) for n in wanted)
    else:
        view = batch_view(batch)
    text_file_write(directory + "/view.md", view, "could not write " + view_path(directory, env))
    sys.stdout.write(view)
    sys.stdout.flush()
    tail = UNATTENDED_TAIL if unattended else nudge(directory, env)
    sys.stderr.write("batch.md passes: %d items, %d anchors, each matching once in %s, and the"
                     " all answer applies cleanly%s\n"
                     % (len(batch.items), result.anchors, body, tail))
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
    clock: Callable[[], float] = time.time,
    sleep: Callable[[float], None] = time.sleep,
) -> int:
    """`orch.sh spec-review <op> ...`: the real adapters, the process's
    environment, clock and sleep unless a test hands in others. Outside a
    checkout it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown spec-review op: %s (want %s)" % (op or "<none>", OPS))
    if op == "apply":
        # The gh adapter is made at the first GitHub call: a refusal before it
        # makes none.
        return spec_review_apply.apply(
            argv[1:], lambda: gh if gh is not None else adapter(env, pin=pin), git, env, root)
    if op == "check":
        return check(argv[1:], env)
    if op == "wait":
        return wait(argv[1:], env, root, clock, sleep)
    if op == "prompt":
        # The gh adapter is made only for the Fidelity lens, the one whose
        # plan handoff may be read from a comment.
        return prompt(argv[1:], lambda: gh if gh is not None else adapter(env, pin=pin),
                      env, root)
    return begin(argv[1:], env, root)
