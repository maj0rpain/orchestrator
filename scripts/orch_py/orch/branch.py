"""The branch concept's module, as far as the busy checkout's branch signal,
the review loop's terminal-state read and redo need it: the PR and retired
keys bash's branch.sh records on a branch, read through the git adapter's
config_value, whether a branch is a plugin-made branch that records a base,
by bash branch_kind's rule, the flow's branch name and its redo form (bash
branch_name_flow_into and branch_name_redo), and branch_retire, every arm of
bash `branch retire <old> <new>`. A later `branch` noun grows it rather than
moving it, as the base module was grown for `base`.
"""
from __future__ import annotations

import sys
from typing import Optional

from orch.base import branch_base_get
from orch.common import die, stderr_write, stdout_write


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


def branch_retired_set(git, branch: str) -> bool:
    """Records that a redo retired <branch>: whether the write succeeded."""
    return git.config_set("local", branch_retired_key(branch), "true")


def branch_retire(git, old: str, new: str) -> None:
    """`branch retire <old> <new>`: renames local branch <old> to <new>,
    moves it on origin when it is there, records <new>'s retirement key and
    prints <new>, every arm and message as bash's verb. A rename git refuses
    ends the run with git's own status and stderr, as bash's `set -e` did."""
    rerun = "rerun orch.sh branch retire %s %s" % (old, new)
    old_ok, new_ok = git.branch_exists(old), git.branch_exists(new)
    resumed = False
    if old_ok and new_ok:
        die("branch %s already exists" % new)
    elif not old_ok and not new_ok:
        die("branch %s does not exist" % old)
    elif old_ok:
        upstream = git.branch_upstream(old)
        _rename_or_exit(git, old, new)
    else:
        # <old> is already gone and <new> already exists: a previous call
        # renamed locally (issue #63). That state is also what a completed
        # retire leaves, local-only or not, so it does not say a remote step
        # remains: origin's own answer for <old> does. Still there - resume the
        # remote steps. Answered no - nothing remote is left, and the
        # retirement key is still recorded. Not answered - guess neither way
        # and die, so a rerun can ask again. This call made no rename, so it
        # never rolls one back.
        resumed = True
        has = git.origin_has_branch(old)
        if has is None:
            die("could not reach origin to check whether %s is still there - nothing was"
                " changed; %s" % (old, rerun))
        upstream = "origin" if has else None
    # A leftover remote ref under the old name is exactly what the next
    # implement attempt will reuse, and its plain push is not a force-push -
    # so the old ref's delete is not optional, and both failures die.
    if upstream:
        why = git.push_set_upstream("origin", "refs/heads/%s:refs/heads/%s" % (new, new))
        if why is not None:
            # The fresh arm's rename is local-only and free to undo, which
            # keeps <old> a branch a retry can find; the resume arm made none.
            if not resumed:
                undone = git.branch_rename(new, old)
                if undone is not None:
                    stderr_write(undone.stderr)
            die("could not push %s to origin: %s" % (new, why))
        why = git.remote_delete("origin", "refs/heads/" + old)
        if why is not None:
            # Answered no - a previous call's delete already landed: carry
            # on. Still there - die. Not answered - die unrecorded, so a
            # rerun takes the resume arm and asks again.
            has = git.origin_has_branch(old)
            if has:
                die("could not delete origin/%s: %s" % (old, why))
            if has is None:
                die("could not confirm origin/%s is gone: could not ask origin whether it is"
                    " still there after its delete failed (%s); %s is pushed but its"
                    " retirement is not recorded; %s" % (old, why, new, rerun))
    if not branch_retired_set(git, new):
        die("could not record %s - %s is retired; %s to record it"
            % (branch_retired_key(new), new, rerun))
    stdout_write(new + "\n")


def _rename_or_exit(git, old: str, new: str) -> None:
    """Renames <old> to <new>, or ends the run with git's status, its stderr
    printed, as a failed command under bash's `set -e` does."""
    failed = git.branch_rename(old, new)
    if failed is not None:
        stderr_write(failed.stderr)
        sys.exit(failed.code)
