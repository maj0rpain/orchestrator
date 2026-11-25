"""orch.sh's status noun (ADR-0067), a bare global command: full detail on
the checkout's own flow - or the "No active flow" line naming the host's
start command - then every other checkout holding a flow, and every side
checkout without one, under a heading of their own.

run(argv) takes the arguments after `status`, as orch.sh hands them on, and
ignores them, as the bash noun did; it returns the exit code, and every error
dies through orch.common.die, exit 1. It keeps the bash noun's stdout, exit
codes and `orch:` messages.
"""
from __future__ import annotations

import glob
import os
from typing import List, Mapping, Optional

from orch.checkout import checkout_holding, checkouts_or_die
from orch.common import stdout_write
from orch.flow_state import (
    flow_base_fallback_into,
    flow_state_file,
    require_state_read,
    review_budget_fallback,
)
from orch.gh import adapter_of
from orch.git import Git
from orch.handoff import handoff_dir
from orch.host import flow_cmd
from orch.repo import RepoPin
from orch.root import checkout_root

# The keys the flow lines read, in one read.
FLOW_KEYS = ("slug", "phase", "issue", "branch", "pr", "iteration", "redo_count", "base",
             "budget")


def flow_lines(root: str, state_file: str, gh_of, git, pin, env: Mapping[str, str]) -> str:
    """The flow lines of the flow recorded in <state_file>, in the checkout
    at <root>: the base the default branch where none is recorded, the review
    budget DEFAULT_BUDGET where none can be counted, and every handoff written
    so far, by its path under <root>. Dies when the state cannot be read."""
    state = require_state_read(state_file, env, FLOW_KEYS, 1)
    base = flow_base_fallback_into(state["base"], gh_of, git, pin)
    lines = [
        "flow:      " + state["slug"],
        "phase:     " + state["phase"],
        "issue:     " + (state["issue"] or "-"),
        "base:      " + base,
        "branch:    " + (state["branch"] or "-"),
        "PR:        " + (state["pr"] or "-"),
        # Against the budget, not alone: "iteration 3" does not say how far
        # along the loop is, and the budget is the one number a human chose.
        "review:    iteration %s of %s" % (state["iteration"],
                                           review_budget_fallback(state["budget"])),
        # Unconditional, like every other line here: a flow never redone
        # still has an answer, 0.
        "redo:      " + state["redo_count"],
        "",
        "handoffs:",
    ]
    found = sorted(glob.glob(os.path.join(glob.escape(handoff_dir(root)), "*.md")))
    lines += ["  " + path[len(root) + 1:] for path in found] or ["  (none yet)"]
    return "".join(line + "\n" for line in lines)


def others(git, root: str) -> str:
    """The listing of every checkout but the one at <root> that holds a flow
    or is a side checkout - the main checkout's flow included from a side
    checkout - each by its path and what it holds, under a blank line and the
    `other checkouts:` heading; empty when there is none. Ticket worktrees, a
    hand-made worktree with no flow and a quick implementation in the main
    checkout hold no flow and carry no marker, so they never appear. Dies
    when the checkouts cannot be read."""
    listed = ["  %s %s\n" % (checkout.path, checkout_holding(git, checkout.path))
              for checkout in checkouts_or_die(git)
              if checkout.path != root and (checkout.flow or checkout.kind == "side")]
    if not listed:
        return ""
    return "\nother checkouts:\n" + "".join(listed)


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
) -> int:
    """`orch.sh status`: the real adapters and the process's environment
    unless a test hands in others. Outside a checkout it dies first, as
    orch.sh does. The gh adapter is made only when a flow's base falls back
    to the default branch."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    pin = RepoPin(env, git) if pin is None else pin
    state_file = flow_state_file(root)
    if os.path.isfile(state_file):
        stdout_write(flow_lines(root, state_file, adapter_of(gh, env, pin), git, pin, env))
    else:
        stdout_write("No active flow. Run %s from an approved plan.\n" % flow_cmd(env, "start"))
    stdout_write(others(git, root))
    return 0
