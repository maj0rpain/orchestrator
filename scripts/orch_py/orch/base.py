"""The base concept's module, holding only the default-branch lookup so far,
as the bash side's default_branch_resolve and default_branch_seed find it;
the later `base` noun grows it rather than moving it.

GitHub is asked first, and only when the repo pin resolves: origin/HEAD is a
local pointer frozen at clone time, which in a clone taken while a feature
branch was checked out names that branch. It is the fallback for a repo gh
cannot answer for, and the literal guess main the last. Each candidate counts
only when it is a valid branch name, so noise in gh's answer - or a failed
gh call - falls through to the next (#465).
"""
from __future__ import annotations

from typing import NamedTuple

from orch.gh import GhFailed

# The sources the lookup answers from, as bash's DEFAULT_BRANCH_SOURCE names
# them.
GITHUB = "github"
ORIGIN_HEAD = "origin-head"
FALLBACK = "fallback"


class DefaultBranch(NamedTuple):
    """The default branch's name, and the source it came from: github,
    origin-head or fallback."""

    name: str
    source: str


def default_branch(gh, git, pin) -> DefaultBranch:
    """The default branch: GitHub's answer through the gh adapter <gh>, asked
    only when the repo pin <pin> resolves, when it is a valid branch name;
    else the branch origin/HEAD names in the checkout <git> reads; else main.
    Never fails: a failed gh call falls through, silently."""
    repo = pin.resolve()
    if repo is not None:
        try:
            answer = gh.repo_default_branch(repo.name)
        except GhFailed:
            answer = ""
        if answer and git.is_branch_name(answer):
            return DefaultBranch(answer, GITHUB)
    head = git.origin_head_branch()
    if head and git.is_branch_name(head):
        return DefaultBranch(head, ORIGIN_HEAD)
    return DefaultBranch("main", FALLBACK)
