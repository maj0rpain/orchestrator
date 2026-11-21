"""The PR concept's module (scripts/orch/pr.sh), kept to what the review-pass
noun uses: the current branch's open PR.
"""
from __future__ import annotations

from typing import Optional

from orch.checkout import current_branch_or_die
from orch.common import die
from orch.gh import Unparsed, gh_or_die
from orch.repo import REPO_REMEDY
from orch.trust import trust_filter_prs


def current_open_pr(gh, git, code: int = 2) -> Optional[int]:
    """The current branch's open PR number, the newest the Trust module
    trusts, or None when the branch has none - bash's exit 1. Every other
    failure dies with <code>, 2 unless given, bash's die2: a detached HEAD;
    no repo (checked here, after the detached-HEAD check, so nothing reaches
    gh unpinned); a GitHub that cannot be read; a listing that does not
    parse."""
    branch = current_branch_or_die(git, code)
    if not gh.pin():
        die(REPO_REMEDY, code)
    lines = gh_or_die("list the open PRs from " + branch, gh.prs_open, branch, code=code)
    try:
        kept = trust_filter_prs(branch, lines)
    except Unparsed:
        die("the open PRs from %s could not be read" % branch, code)
    if not kept:
        return None
    return int(kept[0].split("\t", 1)[0])
