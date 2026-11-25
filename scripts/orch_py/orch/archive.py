"""orch.sh's archive noun (ADR-0067), a bare global command: archives the
checkout's flow rather than deleting it - the moment a handoff is wanted back
is the moment it was thrown away, and the directory is git-excluded anyway.

In the main checkout, or any checkout but a side checkout, the flow moves
into the checkout's own .orchestrator/archive/. In a side checkout, git
worktree remove would delete the archive with the worktree - it deletes
ignored files - so the flow moves to the main checkout's archive first, and
only then is the worktree removed, never with force (ADR-0037); a refused
removal is kept and warned of, and the archive still counts as made, exit 0.

run(argv) takes the arguments after `archive`, as orch.sh hands them on, and
ignores them, as the bash noun did; it returns the exit code, and every error
dies through orch.common.die, exit 1. It keeps the bash noun's stdout, exit
codes and `orch:` messages.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional

from orch.common import die, stdout_write
from orch.flow_state import flow_state_file, require_state_exists
from orch.git import Git
from orch.root import checkout_root
from orch.side_checkout import (
    archive_flow,
    archive_root,
    side_checkout_archive_and_remove_or_exit,
)


def run(
    argv: List[str],
    git=None,
    env: Optional[Mapping[str, str]] = None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh archive`: the real git adapter and the process's environment
    unless a test hands in others, the archive directory stamped by
    <clock>. Outside a checkout it dies first, as orch.sh does."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    require_state_exists(flow_state_file(root), env)
    home = archive_root(git, root)
    if home is None:
        die("could not read the checkouts - nothing was archived")
    # Only a side checkout archives anywhere but in place.
    if home == root:
        stdout_write(archive_flow(git, root, home, root, clock) + "\n")
        return 0
    # The directory the command runs in, read before the removal: the close
    # note's test of whether the session's working directory is gone.
    here = os.path.realpath(os.getcwd())
    # A refused removal is kept and warned of: the archive has still succeeded.
    side_checkout_archive_and_remove_or_exit(git, root, home, here, "warn", root, clock)
    return 0
