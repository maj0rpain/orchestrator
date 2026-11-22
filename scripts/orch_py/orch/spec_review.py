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

check and apply are still served by the bash spec-review module.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional

from orch import spec
from orch.common import (ORCH_DIR_NAME, capture, die, err_line, file_lines, plain_number,
                         require_poll_knobs)
from orch.flow_state import STATE_UNREADABLE_MSG, flow_state_file, flow_state_get_many
from orch.gh import adapter
from orch.git import Git
from orch.handoff import handoff_path
from orch.host import flow_cmd
from orch.root import checkout_root
from orch.wait import StoredTotal, still_running, wait_block

# The verbs. docs_lint.sh reads a converted noun's verbs from this line, so it
# stays one `OPS = "<verb>|..."` line.
OPS = "begin|check|apply|wait|prompt"

BEGIN_USAGE = "usage: orch.sh spec-review begin <n> [--carry]"

# The lenses, in the lens table's order - the changelog's section order.
SPEC_REVIEW_LENSES = ("fidelity", "consistency", "testability", "implementability")

# The wait's knobs and their defaults: how long it lasts, and how often it
# looks.
WAIT_TIMEOUT = ("ORCH_SPEC_REVIEW_WAIT_TIMEOUT", "900")
WAIT_INTERVAL = ("ORCH_SPEC_REVIEW_WAIT_INTERVAL", "5")


def lens_known(name: str) -> bool:
    """Whether <name> is one of the four lenses, matched whole."""
    return name in SPEC_REVIEW_LENSES


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
    if op in ("check", "apply"):
        raise NotImplementedError("spec-review %s is still served by bash" % op)
    if op == "wait":
        return wait(argv[1:], env, root, clock, sleep)
    if op == "prompt":
        # The gh adapter is made only for the Fidelity lens, the one whose
        # plan handoff may be read from a comment.
        return prompt(argv[1:], lambda: gh if gh is not None else adapter(env, pin=pin),
                      env, root)
    return begin(argv[1:], env, root)
