"""The side-checkout concept's module, as far as the checkout scan needs it:
the ownership marker that makes a worktree a side checkout, as the bash
side's side-checkout.sh reads it. A side checkout is a worktree the plugin
makes under the main checkout's .orchestrator/checkouts/ (ADR-0037); the
marker in the worktree's own git folder - which git deletes with the
worktree - is what makes it one, never a flow's state file, since a
hand-made worktree can hold a flow too.
"""
from __future__ import annotations

import os
from typing import Optional

from orch.checkout import checkout_gitdir_into

# The ownership marker's file name, in the worktree's own git folder.
SIDE_CHECKOUT_MARKER = "orchestrator-side-checkout"


def side_checkout_marked(gitdir: str) -> bool:
    """Whether the git folder <gitdir> holds the ownership marker - the one
    place the marker's presence is tested."""
    return os.path.isfile(os.path.join(gitdir, SIDE_CHECKOUT_MARKER))


def side_checkout_marker(git, path: str) -> Optional[str]:
    """The ownership marker's path for the worktree at <path>; None when it
    carries none. The git folder comes from the worktree's own git pointer
    (checkout_gitdir_into), so a worktree costs no git process; only a
    pointer that cannot be read that way asks git, through the adapter
    <git>."""
    gitdir = checkout_gitdir_into(git, path)
    if gitdir is None or not side_checkout_marked(gitdir):
        return None
    return os.path.join(gitdir, SIDE_CHECKOUT_MARKER)
