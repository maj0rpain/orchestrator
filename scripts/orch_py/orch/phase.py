"""The phase concept's Python side (scripts/orch/phase.sh): so far
phase_finish, the finished phase's close, which bash review ready reaches
through orch_python_call (`orch_python_call --as review phase phase_finish
...`). The noun's ops, phase advance and phase boundary, and the bash
phase_finish they call, stay in bash until the noun's cutover.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional

from orch.autopilot import autopilot_active
from orch.common import die
from orch.flow_state import flow_state_file, phase_write, require_value
from orch.gh import adapter_of
from orch.git import Git
from orch.root import checkout_root


def phase_finish(
    args: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> None:
    """`phase_finish <next> <reason> <issue>`: records <next> as the flow's
    phase in the checkout's state file, updated stamped with the time
    <clock> reads. In an autopilot session it first checks <issue>, the
    flow's issue the caller holds, with require_value, then runs
    standing_finish - the issue's phase label moved, the phase recorded, the
    claim released - <reason> naming what was done. It reads no state and
    prints nothing. The real adapters and the process's environment unless a
    test hands in others."""
    if len(args) != 3:
        die("usage: orch_python_call phase phase_finish <next> <reason> <issue>")
    next_phase, reason, issue = args
    env = os.environ if env is None else env
    git = Git() if git is None else git
    state_file = flow_state_file(checkout_root(git, env))
    if autopilot_active(env):
        require_value("issue", issue)
        # Imported on call: a plain session never loads the chain.
        from orch.standing import standing_finish

        standing_finish(adapter_of(gh, env)(), issue, next_phase, reason, state_file, clock)
    else:
        phase_write(state_file, next_phase, clock)
