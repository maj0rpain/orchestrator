"""The branch concept's module and the branch noun (ADR-0067), its one copy
since the noun converted and the bash branch module went: the PR, retired
and forked-from keys spelled for a branch, read through the git adapter's
config_value, and the PR and forked-from ones written through its
config_set, the branch kinds and whether a branch is a plugin-made branch
that records a base, the flow's branch name and its redo form, a ticket
branch's name, the issue a flow or quick branch name gives, the discard
rule's own-branch proof and discard (as bash's discard_own_branch_work was),
branch_retire, every arm of `branch retire <old> <new>`, the start-point
decision and the fork branch off and branch create share, branch create's
own discard-rule decision, and the noun's run: its dispatch over the six
verbs and its create, off, busy, base-sha, sync and retire verbs, each with
the bash noun's usage line, output, exit codes and `orch: ` messages, which
orch.sh's converted-noun case runs.
"""
from __future__ import annotations

import os
import sys
from typing import List, Mapping, Optional

from orch.base import (base_branch_into, branch_base_get, branch_base_sha_get,
                       branch_base_sha_set, record_branch_base, recorded_base_into)
from orch.common import die, plain_number, require_clean_tree, stdout_write, warn
from orch.flow_state import (flow_base_fallback_into, flow_state_file, require_state_read,
                             require_value, state_write_many)
from orch.gh import adapter_of
from orch.git import Git, GitFailure, git_failed
from orch.repo import RepoPin
from orch.root import checkout_root


def branch_name_flow(issue: str, slug: str) -> str:
    """The flow's branch name for <issue> and <slug>: the one place the
    `orch/<issue>-<slug>` format lives."""
    return "orch/%s-%s" % (issue, slug)


def branch_name_redo(issue: str, slug: str, redo_count: str) -> str:
    """The flow's branch name with <redo_count>'s redo suffix: the name a
    redo's branch retire gives the branch it retires."""
    return "%s-redo-%s" % (branch_name_flow(issue, slug), redo_count)


def branch_name_ticket(parent: str, n: str) -> str:
    """Ticket <n>'s ticket branch, forked from <parent>: `<parent>--t<n>`."""
    return "%s--t%s" % (parent, n)


def branch_issue_of(name: str) -> Optional[str]:
    """The issue number of a flow or quick branch name: the digits after
    orch/ or quick/ up to the first `-`.
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


def branch_pr_set(git, branch: str, pr: str) -> Optional[GitFailure]:
    """Records PR <pr> as the one opened for <branch> (#1200), in the
    repository's own config, so a busy check tells the branch's work is
    handed off: None when it wrote, else git's status and stderr."""
    return git.config_set("local", branch_pr_key(branch), pr)


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
    """What kind of branch <branch> is - the one definition of branch
    kinds - read from git config, through the git
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
    """The discard rule's prelude and the discard in one, as bash's
    discard_own_branch_work was, its bash copy gone: proves <branch> is the
    caller's own, then runs the flow-branch discard in the checkout at
    <root>, the git adapter <git>'s own, <env> telling an autopilot session.
    <recorded> is the flow's recorded branch (empty for none) and <active>
    whether a flow is active, both from the caller's one read of flow state;
    this reads none.
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
        _exit_on(git.branch_rename(old, new))
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
            # An undo git refuses ends the run as bash's `set -e` did, before
            # the line below.
            if not resumed:
                _exit_on(git.branch_rename(new, old))
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
    # Bash let the record's write print git's own refusal, ahead of its line.
    if git_failed(branch_retired_set(git, new)):
        die("could not record %s - %s is retired; %s to record it"
            % (branch_retired_key(new), new, rerun))
    stdout_write(new + "\n")


def _exit_on(failed: Optional[GitFailure]) -> None:
    """Ends the run with git's status, its stderr printed, when <failed> is
    a failure, as a failed command under bash's `set -e` does."""
    if git_failed(failed):
        sys.exit(failed.code)


# The remedy for a base origin says is gone, when the caller names none:
# only a flow has a base it can correct.
GONE_BASE_REMEDY = "start again on another base branch"


def new_branch_start(git, name: str, base: str, remedy: str = GONE_BASE_REMEDY) -> str:
    """The start point branch <name> forks from off base branch <base>,
    shared by branch off and branch create, run before
    anything is written so a refusal leaves the checkout as it was: origin's
    refs/remotes/origin/<base> after a fetch that worked; when origin could
    not be asked, that remote-tracking ref if it exists, else the local
    refs/heads/<base>. Every ref is named in full, so a branch or tag called
    <name> or origin/<base> never captures the name check or the start point
    (#1331, #2337). Dies when <name> is taken, when origin answers that
    <base> is gone (naming <remedy>), or when the fetch failed while origin
    has <base>."""
    if git.branch_exists(name):
        die("branch %s already exists" % name)
    tracking = "refs/remotes/origin/" + base
    if git.fetch_default_branch(base):
        return tracking
    # Only an origin that could not be asked earns the local fallback: one
    # that answered "no such branch" means the base is gone, and forking from
    # a stale local copy of it would build on work nobody will merge; one
    # that has the base but failed the fetch could leave a stale ref.
    has = git.origin_has_branch(base)
    if has is False:
        die("base branch %s does not exist on origin - push it, or %s" % (base, remedy))
    if has:
        die("could not fetch %s from origin" % base)
    return tracking if git.ref_exists(tracking) else "refs/heads/" + base


def fork_new_branch(git, name: str, start: str) -> None:
    """Checks out new branch <name> at exactly <start>, the start point
    new_branch_start decided, with no fallback of its own and no upstream
    (#1152): the base is recorded in the branch's own config, and pr publish
    sets the real upstream on the first push. Dies with git's refusal."""
    failed = git.checkout_new_branch(name, start)
    if failed is not None:
        die("could not create %s from %s: %s" % (name, start, failed.stderr))


# The six verbs, as the bash noun's unknown-op refusal lists them.
OPS = "create|off|busy|base-sha|sync|retire"


def run(argv: List[str], gh=None, git=None, env: Optional[Mapping[str, str]] = None,
        pin=None) -> int:
    """`orch.sh branch <op>`: the real adapters and the process's environment
    unless a test hands in others. Outside a checkout it dies first, as
    orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op, rest = (argv[0], argv[1:]) if argv else ("", [])
    pin = RepoPin(env, git) if pin is None else pin
    gh_of = adapter_of(gh, env, pin)
    if op == "busy":
        return busy_verb(rest, git, root, env)
    if op == "base-sha":
        return base_sha_verb(rest, gh_of, git, pin)
    if op == "retire":
        if len(rest) != 2:
            die("usage: orch.sh branch retire <old> <new>")
        branch_retire(git, rest[0], rest[1])
        return 0
    if op == "off":
        return off_verb(rest, gh_of, git, root, env, pin)
    if op == "sync":
        return sync_verb(rest, gh_of, git, pin, root, env)
    if op == "create":
        return create_verb(rest, gh_of, git, root, env, pin)
    die("unknown branch op: %s (want %s)" % (op or "<none>", OPS))


# The remedy a flow's create names for a base origin says is gone: a flow
# can correct the base it records.
FLOW_GONE_BASE_REMEDY = "point this flow at another base: orch.sh base set <branch> --flow"


def discard_create_work(git, root: str, env: Mapping[str, str], name: str) -> None:
    """The discard rule's decision for both branch create paths, <name>
    being the flow's branch, in the checkout at
    <root>: on the flow's own branch, or a detached HEAD with no rebase in
    progress, it applies discard_flow_branch_work. On any other branch -
    foreign, or plugin-made but not the flow's, a rebase in progress naming
    the branch it rebases - it discards nothing: with no work to discard it
    returns, so the caller goes on, and with any it dies, exit 1, naming that
    branch."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import (checkout_branch_or_rebasing, discard_flow_branch_work,
                               work_to_discard)

    branch = checkout_branch_or_rebasing(git, root)
    if branch is None or branch == name:
        discard_flow_branch_work(git, root, env)
        return
    merging, rebasing, dirty = work_to_discard(git, root)
    if merging or rebasing or dirty:
        die("branch create: the current branch %s is not the flow's branch %s - nothing was"
            " discarded" % (branch, name))


def create_verb(argv: List[str], gh_of, git, root: str, env: Mapping[str, str], pin) -> int:
    """`branch create`: the flow's branch orch/<issue>-<slug>, named from
    the flow state of the checkout at <root>. A restarted implement phase
    finds it already made - state.branch records it and it exists locally -
    and it is checked out if not current and printed, after the discard
    rule's decision, with no busy refusal and no write: base_sha and the
    branch's recorded base stay as they are (ADR-0054). Otherwise, in this
    order: the busy refusal, exit 3, on the branch signal only - the flow
    mid-pipeline is its own; the start point off the flow's base (through
    the flow base fallback, the gh adapter gh_of() makes and the repo pin
    <pin>); the discard rule's decision; the fork; state's branch and
    base_sha in one write; the base and base SHA in the branch's git config,
    where branch sync and branch base-sha find them once the flow is gone;
    the name printed. A refusal before the fork writes and discards nothing.
    The state refusals come before the usage check, as bash's did."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import checkout_branch, refuse_busy_checkout

    state_file = flow_state_file(root)
    state = require_state_read(state_file, env, ("slug", "issue", "branch", "base"), 1)
    if argv:
        die("usage: orch.sh branch create")
    require_value("issue", state["issue"])
    name = branch_name_flow(state["issue"], state["slug"])
    if state["branch"] == name and git.branch_exists(name):
        discard_create_work(git, root, env, name)
        if checkout_branch(git) != name:
            if git_failed(git.checkout_existing_branch(name)):
                die("could not check out %s" % name)
        stdout_write(name + "\n")
        return 0
    refuse_busy_checkout(git, root, env, "branch")
    base = flow_base_fallback_into(state["base"], gh_of, git, pin)
    start = new_branch_start(git, name, base, FLOW_GONE_BASE_REMEDY)
    discard_create_work(git, root, env, name)
    fork_new_branch(git, name, start)
    sha = git.resolve_commit("HEAD") or ""
    state_write_many(state_file, [("branch", name, True), ("base_sha", sha, True)])
    _exit_on(record_branch_base(git, name, base, sha))
    stdout_write(name + "\n")
    return 0


def off_verb(argv: List[str], gh_of, git, root: str, env: Mapping[str, str], pin) -> int:
    """`branch off <name>`: a quick implementation keeps no state.json, so
    the caller names the branch. It refuses a busy checkout with exit 3,
    every signal applying, before anything else, so it never moves another
    implementation's branch or carries its edits; then forks <name> from the
    base branch in effect (base_branch_into, through the gh adapter gh_of()
    makes and the repo pin <pin>), records that base and the base tip at
    branching as the branch's base SHA in its git config - where pr publish
    and its reviewers find them, even if the setting moves - and prints the
    name. A record git refuses ends the run as bash's `set -e` did."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import BUSY_SIGNALS, refuse_busy_checkout

    if len(argv) != 1:
        die("usage: orch.sh branch off <name>")
    name = argv[0]
    refuse_busy_checkout(git, root, env, *BUSY_SIGNALS)
    base = base_branch_into(gh_of(), git, pin)
    fork_new_branch(git, name, new_branch_start(git, name, base))
    _exit_on(record_branch_base(git, name, base, git.resolve_commit("HEAD") or ""))
    stdout_write(name + "\n")
    return 0


def busy_verb(argv: List[str], git, root: str, env: Mapping[str, str]) -> int:
    """`branch busy`: whether the checkout at <root> is a busy checkout,
    every signal applying - exit 3 with the one line naming what holds it on
    stdout, exit 0 printing nothing when it is free, exit 1 on a usage error
    or a working tree that cannot be read. Exit 3 is used by no other
    failure, so a skill can branch on it."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import BUSY_SIGNALS, checkout_busy

    if argv:
        die("usage: orch.sh branch busy")
    busy = checkout_busy(git, root, env, BUSY_SIGNALS)
    if busy is None:
        return 0
    stdout_write(busy[0] + "\n")
    return 3


def base_sha_verb(argv: List[str], gh_of, git, pin) -> int:
    """`branch base-sha`: the current branch's base SHA, as branch off,
    branch create or branch sync recorded it. A branch made before that was
    recorded falls back to the merge-base with the base it belongs to
    (recorded_base_into, through the gh adapter gh_of() makes and the repo
    pin <pin>), preferring origin's copy of it to the local one. Only a
    fallback: a base merged in mid-branch moves the merge-base and silently
    shrinks the diff it bounds."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import current_branch_or_die

    if argv:
        die("usage: orch.sh branch base-sha")
    branch = current_branch_or_die(git)
    sha = branch_base_sha_get(git, branch)
    if sha:
        stdout_write(sha + "\n")
        return 0
    base = recorded_base_into(gh_of(), git, pin, branch)
    ref = next((ref for ref in ("refs/remotes/origin/" + base, "refs/heads/" + base)
                if git.ref_exists(ref)), None)
    if ref is None:
        die("base branch %s of %s is neither on origin nor local - no base SHA to fall back to"
            % (base, branch))
    merge_base = git.merge_base("HEAD", ref)
    if merge_base is None:
        die("%s shares no history with base branch %s" % (branch, base))
    stdout_write(merge_base + "\n")
    return 0


def on_origin_base(git, sha: Optional[str], base: str) -> bool:
    """Whether the local origin/<base> resolves and <sha> is on it - its tip
    or an ancestor of it."""
    ref = "refs/remotes/origin/" + base
    return sha is not None and git.ref_exists(ref) and git.is_ancestor(sha, ref)


def sync_verb(argv: List[str], gh_of, git, pin, root: str, env: Mapping[str, str]) -> int:
    """`branch sync [--finish]`: a base sync of the current plugin-made
    branch - origin's tip of its base merged in, never a rebase, never the
    local base - its base SHA moved to that tip, and a push when it tracks
    its own name. The branch is the one this checkout's flow holds, its base
    the flow's (through the flow base fallback, made by gh_of() and the repo
    pin <pin>), else one whose git config records a base. Exit 3 is a
    conflict, or a pending base merge a failed sync left, the merge left in
    progress for a resolver with nothing else moved; every refusal is exit 1
    with nothing moved. A failed push is the one exit 1 after something
    moved: the merge and base SHA stand, and a rerun retries the push.
    --finish never fetches: the newest merge on HEAD's first-parent chain,
    fix commits above it accepted, must have its second parent on the local
    origin/<base>; that parent is recorded as the base SHA, then pushed."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import current_branch_or_die, merge_in_progress

    # bash's case on "$*": the arguments joined by spaces.
    joined = " ".join(argv)
    if joined not in ("", "--finish"):
        die("usage: orch.sh branch sync [--finish]")
    finish = joined == "--finish"
    branch = current_branch_or_die(git, suffix=" - nothing was synced")
    state_file = flow_state_file(root)
    state = {"branch": "", "base": ""}
    if os.path.isfile(state_file):
        state = require_state_read(state_file, env, ("branch", "base"), 1)
    held = state["branch"] == branch
    if held:
        base = flow_base_fallback_into(state["base"], gh_of, git, pin)
    elif branch_records_base(git, branch):
        base = branch_base_get(git, branch) or ""
    else:
        die("%s is not a branch the plugin made: no flow here holds it and it records no base"
            " - nothing was synced" % branch)
    if branch == base:
        die("%s is its own base branch - nothing was synced" % branch)
    if finish:
        if merge_in_progress(git, root):
            die("a merge is in progress on %s - commit it (or git merge --abort), then rerun"
                " orch.sh branch sync --finish; nothing was synced" % branch)
        merge = git.newest_merge_commit("HEAD")
        if merge is None:
            die("no merge commit on the first-parent chain of %s - nothing to finish; nothing"
                " was synced" % branch)
        tip = git.second_parent(merge)
        if not on_origin_base(git, tip, base):
            die("the second parent of the newest merge on %s is not on origin/%s - nothing to"
                " finish; nothing was synced" % (branch, base))
    else:
        tip = _merged_base_tip(git, root, branch, base)
    _exit_on(branch_base_sha_set(git, branch, tip))
    if held:
        state_write_many(state_file, [("base_sha", tip, True)])
    # Its own upstream only: a branch made before branch create and branch off
    # passed --no-track (#1152) may still track its base until its first push.
    if git.config_value("branch.%s.merge" % branch) == "refs/heads/" + branch:
        remote = git.config_value("branch.%s.remote" % branch) or "origin"
        why = git.push(remote, "refs/heads/%s:refs/heads/%s" % (branch, branch))
        if why is not None:
            die("could not push %s - the merge and base SHA are recorded; rerun orch.sh branch"
                " sync%s to push: %s" % (branch, " --finish" if finish else "", why))
    stdout_write("%s synced with origin/%s at %s\n" % (branch, base, tip))
    return 0


def _merged_base_tip(git, root: str, branch: str, base: str) -> str:
    """A plain sync's merge of origin's tip of <base> into <branch>: that
    tip. Ends the run with exit 3 on a pending base merge (nothing fetched)
    or a conflict (the merge left in progress), and dies on another merge in
    progress, a dirty tree, a failed fetch or a merge git could not start."""
    # Imported here: the checkout module reads this one at its own import.
    from orch.checkout import merge_in_progress

    if merge_in_progress(git, root):
        if on_origin_base(git, git.resolve_commit("MERGE_HEAD"), base):
            warn("a merge of origin/%s into %s is pending resolution - the merge is left in"
                 " progress; resolve and commit it, then run orch.sh branch sync --finish"
                 % (base, branch))
            sys.exit(3)
        die("a merge is in progress on %s - commit it (or git merge --abort), then rerun"
            " orch.sh branch sync" % branch)
    require_clean_tree(git, root, "the working tree is dirty - commit or discard its changes"
                       " first; nothing was synced")
    if not git.fetch_branch_at(root, base):
        die("could not fetch %s from origin - nothing was synced" % base)
    tip = git.resolve_commit("refs/remotes/origin/" + base) or ""
    if git.merge_no_edit_at(root, "refs/remotes/origin/" + base) is not None:
        if merge_in_progress(git, root):
            warn("merging origin/%s into %s hit a conflict - the merge is left in progress;"
                 " resolve and commit it, then run orch.sh branch sync --finish"
                 % (base, branch))
            sys.exit(3)
        die("git could not merge origin/%s into %s" % (base, branch))
    return tip
