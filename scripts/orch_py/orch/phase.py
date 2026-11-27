"""orch.sh's phase noun (ADR-0067): `phase advance`, which leaves the
current phase once the handoff it writes for the next one is valid and the
state the next one needs is recorded, and `phase boundary`, the block that
ends a phase's session. Beside them finish, the finished phase's close,
which phase advance runs and review ready calls in process.

run(argv) takes the arguments after `phase`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die. It keeps
the bash noun's stdout, exit codes and `orch:` messages, in a plain and an
autopilot (ORCH_AUTOPILOT=1) session.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional

from orch.autopilot import autopilot_active
from orch.common import die
from orch.flow_state import flow_state_file, phase_write, require_state_read, require_value
from orch.gh import adapter_of
from orch.git import Git
from orch.handoff import (handoff_check, handoff_dir, handoff_file_for, handoff_invalid,
                          handoff_read, phase_next, phase_writer)
from orch.host import print_next_block
from orch.repo import RepoPin
from orch.root import checkout_root

OPS = "advance|boundary"


def print_boundary(phase: str, root: str, env: Mapping[str, str]) -> None:
    """The block that ends every phase, for the handoff <phase>, the phase
    now recorded, reads: the next phase needs a fresh session this one
    cannot start, so the block names it in the host's own words. The
    finished phase is the writer of the handoff <phase> consumes; done and a
    phase outside the table have none, so no boundary."""
    done_name = phase_writer(phase)
    if done_name is None:
        die("no phase boundary at phase: %s - the flow is not between phases" % phase)
    print_next_block(env, "Phase %s complete. Handoff written to %s/%s."
                     % (done_name, handoff_dir(root), handoff_file_for(phase)))


# The keys phase advance's entry read takes, in one read.
ADVANCE_KEYS = ("phase", "issue", "branch", "base_sha", "pr")


def advance(args: List[str], root: str, gh_of, env: Mapping[str, str],
            clock: Callable[[], float]) -> None:
    """`phase advance`: refuses, in this order, extra arguments, no flow or
    an unreadable state, the review and done phases, and a phase outside the
    table; then a missing or invalid handoff of the one this phase writes
    for the next - checked before the state fields, so a missing handoff,
    the likelier gap, is the one reported - then a state field the next
    phase needs. Past them it finishes the phase (finish) and prints
    the boundary block, or in an autopilot session the note naming the
    watcher."""
    if args:
        die("usage: orch.sh phase advance")
    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, ADVANCE_KEYS, 1)
    current, issue = state["phase"], state["issue"]
    if current == "review":
        die("the review phase ends through review ready, once the PR is ready"
            " - phase advance does not leave it")
    if current == "done":
        die("the flow is done - there is no phase to advance to")
    next_phase = phase_next(current)
    if next_phase is None:
        die("not a flow phase: '%s' - run orch.sh doctor --flow" % current)
    name = handoff_file_for(next_phase)
    path = handoff_read(name, "before leaving the %s phase" % current, gh_of, env, root)
    if handoff_check(path, state_file, env, "", name) != 0:
        handoff_invalid(name, "then run phase advance again; the flow stays at " + current,
                        env, root, issue)
    # Deliberately a per-phase switch, not a phase table column: it keeps
    # each check's place in the refusal order beside the phase that needs it.
    if next_phase == "implement":
        require_value("issue", issue)
    elif next_phase == "review":
        for key in ("branch", "base_sha", "pr", "issue"):
            require_value(key, state[key])
        # Imported on call: only leaving implement lists the tickets.
        from orch.ticket import require_no_open_tickets

        require_no_open_tickets(gh_of(), issue, "phase advance")
    finish(next_phase, "", issue, state_file, gh_of, env, clock)
    if autopilot_active(env):
        print("Phase %s complete. Handoff posted on issue #%s; the watcher starts the %s phase."
              % (phase_writer(next_phase), issue, next_phase))
    else:
        print_boundary(next_phase, root, env)


def boundary(args: List[str], root: str, env: Mapping[str, str]) -> None:
    """`phase boundary`: the block for the recorded phase."""
    if args:
        die("usage: orch.sh phase boundary")
    state = require_state_read(flow_state_file(root), env, ("phase",), 1)
    print_boundary(state["phase"], root, env)


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh phase <op>`: the real adapters, the process's environment
    and the system clock unless a test hands in others. Outside a checkout
    it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op == "advance":
        # The gh adapter, made at the first GitHub call, on a repo pin
        # resolved once: only an autopilot session and leaving implement
        # make one.
        advance(argv[1:], root, adapter_of(gh, env, RepoPin(env, git)), env, clock)
    elif op == "boundary":
        boundary(argv[1:], root, env)
    else:
        die("unknown phase op: %s (want %s)" % (op or "<none>", OPS))
    return 0


def finish(next_phase: str, reason: str, issue: str, state_file: str, gh_of,
           env: Mapping[str, str], clock: Callable[[], float]) -> None:
    """The finished phase's close: records <next_phase> as the flow's phase
    in the state file at <state_file>, updated stamped with the time <clock>
    reads. In an autopilot session it first checks <issue>, the flow's issue
    the caller holds, with require_value, then runs standing_finish on the gh
    adapter <gh_of> makes - the issue's phase label moved, the phase
    recorded, the claim released - <reason> naming what was done. It reads
    no state and prints nothing."""
    if autopilot_active(env):
        require_value("issue", issue)
        # Imported on call: a plain session never loads the chain.
        from orch.standing import standing_finish

        standing_finish(gh_of(), issue, next_phase, reason, state_file, clock)
    else:
        phase_write(state_file, next_phase, clock)
