"""The wait concept's module, as far as a converted re-callable command
(ADR-0065) needs it: the block a call waits at most, ORCH_WAIT_BLOCK seconds
(default 570, under a host tool call's 600), and the line a call ends on when
its block is spent with no outcome, as the bash side's wait.sh spells them.
"""
from __future__ import annotations

from typing import Mapping

from orch.common import require_poll_knobs, warn

# A call's block in seconds when ORCH_WAIT_BLOCK is unset or empty.
WAIT_BLOCK_DEFAULT = "570"

# The exit of a call whose block ended with its wait not over.
STILL_RUNNING = 75


def wait_block(env: Mapping[str, str]) -> str:
    """ORCH_WAIT_BLOCK as <env> sets it, else its default, checked as a poll
    knob: its text, as the still-running line names it."""
    block = env.get("ORCH_WAIT_BLOCK", "") or WAIT_BLOCK_DEFAULT
    require_poll_knobs([("ORCH_WAIT_BLOCK", block)])
    return block


def still_running(block: str) -> int:
    """Says on stderr that the call's wait is not over, after <block>
    seconds: STILL_RUNNING, the exit for the caller to end with."""
    warn("still running after %ss - run the same command again" % block)
    return STILL_RUNNING
