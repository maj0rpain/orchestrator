"""The branch concept's module, as far as the busy checkout's branch signal
and the review loop's terminal-state read need it: the PR and retired keys
bash's branch.sh records on a branch, read through the git adapter's
config_value, whether a branch is a plugin-made branch that records a base,
by bash branch_kind's rule, and the flow's branch name and its redo form
(bash branch_name_flow_into and branch_name_redo). A later `branch` noun
grows it rather than moving it, as the base module was grown for `base`.
"""
from __future__ import annotations

from typing import Optional

from orch.base import branch_base_get


def branch_name_flow(issue: str, slug: str) -> str:
    """The flow's branch name for <issue> and <slug>: the one place the
    `orch/<issue>-<slug>` format lives, as bash branch_name_flow_into."""
    return "orch/%s-%s" % (issue, slug)


def branch_name_redo(issue: str, slug: str, redo_count: str) -> str:
    """The flow's branch name with <redo_count>'s redo suffix: the name a
    redo's branch retire gives the branch it retires."""
    return "%s-redo-%s" % (branch_name_flow(issue, slug), redo_count)


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
