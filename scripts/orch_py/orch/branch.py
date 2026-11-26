"""The branch concept's module, as far as the busy checkout's branch signal,
the review loop's terminal-state read, redo and the ticket nouns need it:
the PR, retired and forked-from keys bash's branch.sh records on a branch,
read through the git adapter's config_value and the forked-from one written
through its config_set, the branch kinds (bash branch_kind) and whether a
branch is a plugin-made branch that records a base, the flow's branch name
and its redo form (bash branch_name_flow_into and branch_name_redo), a
ticket branch's name, the issue a flow or quick branch name gives, the
discard rule's own-branch proof and discard (bash discard_own_branch_work),
and branch_retire, every arm of bash `branch retire <old> <new>`. A later
`branch` noun grows it rather than moving it, as the base module was grown
for `base`.
"""
from __future__ import annotations

import sys
from typing import Mapping, Optional

from orch.base import branch_base_get
from orch.common import die, plain_number, stderr_write, stdout_write
from orch.git import GitFailure, git_failed


def branch_name_flow(issue: str, slug: str) -> str:
    """The flow's branch name for <issue> and <slug>: the one place the
    `orch/<issue>-<slug>` format lives, as bash branch_name_flow_into."""
    return "orch/%s-%s" % (issue, slug)


def branch_name_redo(issue: str, slug: str, redo_count: str) -> str:
    """The flow's branch name with <redo_count>'s redo suffix: the name a
    redo's branch retire gives the branch it retires."""
    return "%s-redo-%s" % (branch_name_flow(issue, slug), redo_count)


def branch_name_ticket(parent: str, n: str) -> str:
    """Ticket <n>'s ticket branch, forked from <parent>: `<parent>--t<n>`."""
    return "%s--t%s" % (parent, n)


def branch_issue_of(name: str) -> Optional[str]:
    """The issue number of a flow or quick branch name - bash
    branch_issue_of: the digits after orch/ or quick/ up to the first `-`.
    None unless that run is non-empty, all digits and followed by a
    non-empty slug."""
    for prefix in ("orch/", "quick/"):
        if name.startswith(prefix):
            issue, dash, slug = name[len(prefix):].partition("-")
            if dash and slug and plain_number(issue):
                return issue
            return None
    return None


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


def forked_from_set(git, branch: str, parent: str) -> Optional[GitFailure]:
    """Records <parent> as ticket branch <branch>'s forked-from branch, in
    the repository's own config: None when it wrote, else git's status and
    stderr."""
    return git.config_set("local", forked_from_key(branch), parent)


def branch_kind(git, branch: str) -> str:
    """What kind of branch <branch> is - bash branch_kind, the one
    definition of branch kinds - read from git config, through the git
    adapter <git>, and the name only. A plugin-made branch is a `ticket` (a
    ticket parent is recorded), a `flow` (a base is recorded and the name is
    orch/<issue>-<slug>, redo form included) or a `quick` (a base is
    recorded and the name is anything else); every other branch is
    `foreign`."""
    if forked_from_branch(git, branch) is not None:
        return "ticket"
    if branch_base_get(git, branch) is None:
        return "foreign"
    if branch.startswith("orch/") and branch_issue_of(branch) is not None:
        return "flow"
    return "quick"


def branch_records_base(git, branch: str) -> bool:
    """Whether <branch> is a plugin-made branch that records a base - a
    flow's or a quick implementation's branch, never a ticket branch - as
    branch_kind tells them."""
    return branch_kind(git, branch) in ("flow", "quick")


def discard_own_branch_work(git, root: str, env: Mapping[str, str], who: str, branch: str,
                            recorded: str, active: bool) -> None:
    """The discard rule's prelude and the discard in one - bash
    discard_own_branch_work: proves <branch> is the caller's own, then runs
    the flow-branch discard in the checkout at <root>, the git adapter
    <git>'s own, <env> telling an autopilot session. <recorded> is the
    flow's recorded branch (empty for none) and <active> whether a flow is
    active, both from the caller's one read of flow state; this reads none.
    Own is the branch the flow records, in any phase; else, with an active
    flow, the flow-branch proof dies on it; with none, a `quick` branch."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import discard_flow_branch_work, require_flow_branch

    if recorded != branch:
        if active:
            require_flow_branch(who, branch, recorded)
        elif branch_kind(git, branch) != "quick":
            die("%s: no active flow, and %s is not a quick implementation's branch - nothing"
                " was discarded" % (who, branch))
    discard_flow_branch_work(git, root, env)


def branch_retired_set(git, branch: str) -> Optional[GitFailure]:
    """Records that a redo retired <branch>: None when it wrote, else git's
    status and stderr."""
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
                git_failed(git.branch_rename(new, old))
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
    if git_failed(branch_retired_set(git, new)):
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
