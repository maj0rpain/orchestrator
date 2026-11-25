"""The branch concept's module, as far as the busy checkout's branch signal
needs it: the PR and retired keys bash's branch.sh records on a branch, read
through the git adapter's config_value, and whether a branch is a
plugin-made branch that records a base, by bash branch_kind's rule. A later
`branch` noun grows it rather than moving it, as the base module was grown
for `base`.
"""
from __future__ import annotations

from typing import Optional

from orch.base import branch_base_get


def branch_pr_key(branch: str) -> str:
    """The git config key recording the PR opened for <branch>."""
    return "branch.%s.orchestrator-pr" % branch


def branch_retired_key(branch: str) -> str:
    """The git config key branch retire records on a branch a redo retired,
    so no name says it (#2550)."""
    return "branch.%s.orchestrator-retired" % branch


def forked_from_key(branch: str) -> str:
    """The git config key recording the branch ticket branch <branch> was
    forked from."""
    return "branch.%s.orchestrator-ticket-parent" % branch


def branch_pr_get(git, branch: str) -> Optional[str]:
    """The PR recorded for <branch>, read through the git adapter <git>;
    None when none is recorded."""
    return git.config_value(branch_pr_key(branch))


def branch_is_retired(git, branch: str) -> bool:
    """Whether a redo retired <branch>: its retired key holds true."""
    return git.config_value(branch_retired_key(branch)) == "true"


def forked_from_branch(git, branch: str) -> Optional[str]:
    """The forked-from branch recorded on ticket branch <branch> (its ticket
    parent); None when none is recorded."""
    return git.config_value(forked_from_key(branch))


def branch_records_base(git, branch: str) -> bool:
    """Whether <branch> is a plugin-made branch that records a base - a
    flow's or a quick implementation's branch, never a ticket branch - by
    bash branch_kind's rule: a branch recording a forked-from parent is a
    ticket branch, checked before its base key is read."""
    if forked_from_branch(git, branch) is not None:
        return False
    return branch_base_get(git, branch) is not None
