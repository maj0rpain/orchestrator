"""The checkout concept's module, as far as a converted noun needs it: the
main checkout, and whether a path is a ticket worktree's, as the bash side's
checkout.sh reads them.
"""
from __future__ import annotations

import os

from orch.common import die, plain_number

# The directory every checkout keeps the orchestrator's own files in.
ORCH_DIR_NAME = ".orchestrator"


def main_checkout_or_die(git) -> str:
    """The main checkout's root, through the git adapter <git>; dies when the
    checkouts cannot be read."""
    main = git.main_checkout()
    if main is None:
        die("could not read the checkouts - git worktree list failed")
    return main


def ticket_path(path: str, checkout: str) -> bool:
    """Whether <path> is a ticket worktree's path: t<n>, n a positive integer
    with no leading zero, directly under <checkout>'s .orchestrator/worktrees.
    """
    parent, name = os.path.split(path)
    number = name[1:]
    return (
        name.startswith("t") and number[:1] in "123456789" and plain_number(number)
        and parent == os.path.join(checkout, ORCH_DIR_NAME, "worktrees")
    )
