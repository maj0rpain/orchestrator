"""The checkout concept's module, as far as a converted noun needs it: the
main checkout, the current branch and a checkout's branch, the checkout a
branch is checked out in, whether a path is a ticket worktree's, the
checkout scan, one checkout's kind, what a checkout holds, whether a merge
or a rebase is in progress, the ticket-worktree refusal, the busy-checkout
refusal, and the discard rule's pieces (ADR-0054): the flow-branch proof,
the work to discard, the discard sequence in a checkout and the flow-branch
discard - as the bash side's checkout.sh reads them, and its ticket-worktree
module did until the ticket nouns were converted. Its bash copies stay while
bash modules call them (ADR-0067).
"""
from __future__ import annotations

import os
from typing import List, Mapping, NamedTuple, Optional, Tuple

from orch.autopilot import autopilot_active
from orch.branch import branch_is_retired, branch_pr_get, branch_records_base
from orch.common import ORCH_DIR_NAME, die, list_join, plain_number
from orch.flow_state import flow_state_file, flow_state_get_many
from orch.host import flow_cmd
from orch.planning_allowlist import dirty_outside_allowlist


class Checkout(NamedTuple):
    """One checkout the scan found: its kind (main, ticket, side or
    hand-made), whether it holds a flow, git's own record of its branch
    (None on a detached HEAD) and its path."""

    kind: str
    flow: bool
    branch: Optional[str]
    path: str


def checkouts_unreadable() -> None:
    """Dies naming the failed checkout read - the one place its message is
    spelled."""
    die("could not read the checkouts - git worktree list failed")


def main_checkout_or_die(git) -> str:
    """The main checkout's root, through the git adapter <git>; dies when the
    checkouts cannot be read."""
    main = git.main_checkout()
    if main is None:
        checkouts_unreadable()
    return main


def current_branch_or_die(git, code: int = 1) -> str:
    """The current branch, through the git adapter <git>; dies on a detached
    HEAD, exit <code> - 2 where the bash caller dies through die2."""
    branch = git.current_branch()
    if branch is None:
        die("not on a branch (detached HEAD)", code)
    return branch


def checkout_branch(git, path: Optional[str] = None) -> Optional[str]:
    """The branch checked out in the checkout at <path> (where the git
    adapter <git> runs when None) - bash checkout_branch, read in full and
    its refs/heads/ taken off, never through --short; None on a detached
    HEAD."""
    return git.current_branch() if path is None else git.branch_at(path)


def branch_checkout(git, branch: str) -> Optional[str]:
    """The checkout that has <branch> checked out - bash branch_checkout:
    the first the worktree list names on it, a worktree whose directory is
    gone included - or None. Dies when the checkouts cannot be read."""
    worktrees = git.worktree_list()
    if worktrees is None:
        checkouts_unreadable()
    return next((worktree.path for worktree in worktrees if worktree.branch == branch), None)


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


def checkouts(git) -> Optional[List[Checkout]]:
    """The one walk over the clone's checkouts, through the git adapter
    <git>'s worktree list, the main checkout first - bash checkouts. Each is
    main for the first entry; ticket when its path is a ticket path under any
    listed checkout (whether or not it carries a side marker); side when it
    carries the side-checkout ownership marker; hand-made for anything else,
    a worktree whose directory is gone included. None when the list fails."""
    worktrees = git.worktree_list()
    if worktrees is None:
        return None
    paths = [worktree.path for worktree in worktrees]
    return [
        Checkout(checkout_classify(git, i, paths), checkout_has_flow(worktree.path),
                 worktree.branch, worktree.path)
        for i, worktree in enumerate(worktrees)
    ]


def checkout_classify(git, index: int, paths: List[str]) -> str:
    """The kind of entry <index> of <paths>: main, ticket, side or
    hand-made, checked in that order - bash checkout_classify, the one place
    the kind rule is spelled."""
    # Imported here: the side-checkout module reads the git folder through
    # this one.
    from orch.side_checkout import side_checkout_marker

    path = paths[index]
    if index == 0:
        return "main"
    if any(ticket_path(path, root) for root in paths):
        return "ticket"
    if side_checkout_marker(git, path) is not None:
        return "side"
    return "hand-made"


def checkout_kind(git, path: str) -> Optional[str]:
    """The kind checkout_classify gives (main, ticket, side or hand-made)
    the checkout holding <path>, a folder inside a checkout included - bash
    checkout_kind, classifying only the matching entry. None when <path> is
    in no checkout, the list fails, or no entry matches."""
    top = git.toplevel_at(path)
    worktrees = git.worktree_list() if top is not None else None
    if worktrees is None:
        return None
    paths = [worktree.path for worktree in worktrees]
    if top not in paths:
        return None
    return checkout_classify(git, paths.index(top), paths)


def checkouts_or_die(git) -> List[Checkout]:
    """What checkouts gives, or dies naming the failed checkout read."""
    scan = checkouts(git)
    if scan is None:
        checkouts_unreadable()
    return scan


def checkout_has_flow(path: str) -> bool:
    """Whether the checkout at <path> holds a flow."""
    return os.path.isfile(flow_state_file(path))


def checkout_holding(git, path: str) -> str:
    """What the checkout at <path> holds: its flow (flow <slug> <phase>
    #<issue>, (no issue) for none recorded, or flow (state.json cannot be
    read)), else its checked-out branch (branch <name>), read through the
    git adapter <git>, else (no branch)."""
    state_file = flow_state_file(path)
    if os.path.isfile(state_file):
        state = flow_state_get_many(state_file, ("issue", "slug", "phase"))
        if state is None:
            return "flow (state.json cannot be read)"
        issue = "#" + state["issue"] if state["issue"] else "(no issue)"
        return "flow %s %s %s" % (state["slug"], state["phase"], issue)
    branch = git.branch_at(path)
    if branch is not None:
        return "branch " + branch
    return "(no branch)"


def checkout_gitdir_into(git, path: str) -> Optional[str]:
    """The absolute git folder of the checkout at <path> - bash
    checkout_gitdir_into - read from its own git pointer without starting
    git for a readable pointer: <path>/.git is the git folder itself in a
    main worktree, and in a linked worktree a file whose "gitdir: <dir>"
    line names it, <dir> relative to <path> when it is not absolute, its .
    and .. parts resolved. When that read fails (the pointer is missing,
    unreadable or names no folder holding a HEAD, or <path> is no checkout's
    root) it asks the git adapter <git>. None only when git fails too."""
    base = path if path.startswith("/") else os.path.join(os.getcwd(), path)
    pointer = base + "/.git"
    gitdir: Optional[str] = pointer
    if os.path.isfile(pointer):
        gitdir = _pointed_gitdir(base, pointer)
    if gitdir is not None and os.path.isfile(gitdir + "/HEAD"):
        return gitdir
    return git.absolute_git_dir_at(path)


def _pointed_gitdir(base: str, pointer: str) -> Optional[str]:
    """The folder the "gitdir: <dir>" first line of the git pointer file
    <pointer> names, read from the worktree at <base>, its . and .. parts
    resolved as bash's walk resolves them; None when the file cannot be read
    or its first line names none."""
    try:
        with open(pointer, "rb") as f:
            line = f.readline().decode("utf-8", "surrogateescape")
    except OSError:
        return None
    line = line[:-1] if line.endswith("\n") else line
    prefix = "gitdir: "
    if not line.startswith(prefix) or len(line) == len(prefix):
        return None
    gitdir = line[len(prefix):]
    if not gitdir.startswith("/"):
        gitdir = base + "/" + gitdir
    parts = gitdir.split("/")
    if "." not in parts and ".." not in parts:
        return gitdir
    resolved = ""
    for part in parts:
        if part in ("", "."):
            continue
        if part == "..":
            resolved = resolved.rsplit("/", 1)[0]
        else:
            resolved += "/" + part
    return resolved


def merge_in_progress(git, path: str) -> bool:
    """Whether a merge is in progress in the checkout at <path>."""
    return git.merge_in_progress_at(path)


def rebase_in_progress(git, path: str) -> bool:
    """Whether a rebase is in progress in the checkout at <path>: its git
    folder, read as checkout_gitdir_into reads it, holds git's
    rebase-merge or rebase-apply record. False where <path> is no
    checkout."""
    gitdir = checkout_gitdir_into(git, path)
    return gitdir is not None and (os.path.isdir(gitdir + "/rebase-merge")
                                   or os.path.isdir(gitdir + "/rebase-apply"))


def discard_work_in(git, path: str, who: str) -> None:
    """The discard sequence every site of the discard rule (ADR-0054) runs
    in the checkout at <path> - bash discard_work_in: a merge or rebase in
    progress is aborted, then the tree is reset and cleaned, through the git
    adapter <git>, git's output dropped. Nothing to discard changes nothing.
    A failed step dies "<who>: <git command> failed in <path>"."""
    if merge_in_progress(git, path) and not git.merge_abort_at(path):
        die("%s: git merge --abort failed in %s" % (who, path))
    if rebase_in_progress(git, path) and git.rebase_abort_at(path) is not None:
        die("%s: git rebase --abort failed in %s" % (who, path))
    if not git.reset_hard_at(path):
        die("%s: git reset --hard failed in %s" % (who, path))
    if not git.clean_at(path):
        die("%s: git clean failed in %s" % (who, path))


def require_flow_branch(who: str, branch: str, recorded: str) -> None:
    """Dies (exit 1, "nothing was discarded") unless <branch> is <recorded>,
    the branch the flow state records, whatever the phase - bash
    require_flow_branch, the proof a discard-rule caller owes before it
    discards. It reads nothing: the caller hands over the branch from its
    one read of flow state, empty for none recorded."""
    if not recorded:
        die("%s: on %s, the active flow records no branch yet - nothing was discarded"
            % (who, branch))
    if recorded != branch:
        die("%s: the current branch %s is not the flow's branch %s - nothing was discarded"
            % (who, branch, recorded))


def work_to_discard(git, root: str) -> Tuple[bool, bool, List[str]]:
    """The one definition of work to discard in the checkout at <root>,
    the git adapter <git>'s own - bash work_to_discard: (a merge in
    progress, a rebase in progress, the paths dirty outside the planning
    allowlist). A tree that cannot be read dies, never read as no work to
    discard."""
    return (merge_in_progress(git, root), rebase_in_progress(git, root),
            dirty_outside_allowlist(git))


def discard_flow_branch_work(git, root: str, env: Mapping[str, str]) -> None:
    """The flow-branch case of the discard rule (ADR-0054) - bash
    discard_flow_branch_work - in the checkout at <root>, the git adapter
    <git>'s own: a merge or rebase in progress is aborted, and a tree dirty
    outside the planning allowlist is reset and cleaned. Each caller first
    settles that the branch is the one to discard on; this checks no
    ownership. Nothing to discard changes nothing. In an interactive flow's
    main checkout - not an autopilot session by <env>, and checkout_kind
    main - it dies instead, naming the exact discard commands and writing
    nothing, as it does when it cannot tell whether <root> is the main
    checkout. A failed step dies naming it."""
    merging, rebasing, dirty = work_to_discard(git, root)
    if not (merging or rebasing or dirty):
        return
    if not autopilot_active(env):
        kind = checkout_kind(git, root)
        if kind is None:
            die("could not tell whether %s is the main checkout - nothing was discarded" % root)
        if kind == "main":
            commands = ('git -C "%s" merge --abort; ' % root if merging else "") + (
                'git -C "%s" rebase --abort; ' % root if rebasing else "")
            die("uncommitted or in-progress work on the flow's branch in the main checkout -"
                " discard it yourself (%s%s): %sgit -C \"%s\" reset --hard && git -C \"%s\""
                " clean -fd" % (list_join(dirty), " merge in progress" if merging else "",
                                commands, root, root))
    discard_work_in(git, root, "could not discard")


def ticket_worktrees_under(git, root: str) -> List[Tuple[str, str]]:
    """(<n>, <path>) for every ticket worktree under the checkout at <root>,
    in the worktree list's order, read through the git adapter <git>; dies
    when the checkouts cannot be read, never reading that as none."""
    worktrees = git.worktree_list()
    if worktrees is None:
        checkouts_unreadable()
    return [
        (os.path.basename(worktree.path)[1:], worktree.path)
        for worktree in worktrees if ticket_path(worktree.path, root)
    ]


def refuse_ticket_worktrees(git, root: str, reason: str) -> None:
    """Dies, naming every ticket worktree under the checkout at <root> and
    the command that removes each, when any is left. <reason> is the clause
    after the dash: why the caller cannot proceed."""
    left = ticket_worktrees_under(git, root)
    if not left:
        return
    named = "\n".join(
        "       %s (orch.sh ticket-worktree remove %s)" % (path, n) for n, path in left
    )
    die("ticket worktrees are left under %s - %s:\n%s\n"
        "     Remove each with orch.sh ticket-worktree remove <n> first." % (root, reason, named))


# The busy signals the Python side checks, in the order bash checkout_busy
# checks them. Its tree signal stays in bash: init gives a dirty tree its own
# planning-allowlist refusal.
BUSY_SIGNALS = ("flow", "branch")


def checkout_busy(git, root: str, env: Mapping[str, str],
                  signals: Tuple[str, ...]) -> Optional[Tuple[str, str]]:
    """The line naming what makes the checkout at <root> a busy checkout -
    one holding work a new branch must not move - and its remedy, or None
    when it is free - bash checkout_busy for the flow and branch signals.
    Reads local git and state facts only, through the git adapter <git>,
    never GitHub. The signals are checked in this order, the first that
    holds reported, and only those in <signals> apply:
      flow    a flow mid-pipeline (phase not done); a state file that
              cannot be read counts as one
      branch  the current branch records a base but no PR; a detached HEAD
              never does, nor does a branch a redo retired, nor a ticket
              branch
    A signal outside BUSY_SIGNALS raises ValueError: a programming error.
    The host's abort command is named from <env>."""
    unknown = [signal for signal in signals if signal not in BUSY_SIGNALS]
    if unknown:
        raise ValueError("not a busy signal: %s" % ", ".join(unknown))
    state_file = flow_state_file(root)
    if "flow" in signals and os.path.isfile(state_file):
        state = flow_state_get_many(state_file, ("slug", "phase"))
        if state is None:
            return ("busy: a flow's state.json cannot be read",
                    "Run orch.sh doctor --flow, or %s." % flow_cmd(env, "abort"))
        if state["phase"] != "done":
            return ("busy: a flow is mid-pipeline (slug: %s, phase: %s)"
                    % (state["slug"], state["phase"]),
                    "One flow at a time - finish it, or run %s." % flow_cmd(env, "abort"))
    if "branch" in signals:
        branch = git.current_branch()
        if (branch is not None and branch_records_base(git, branch)
                and not branch_is_retired(git, branch)
                and branch_pr_get(git, branch) is None):
            return ("busy: branch %s has no PR yet" % branch,
                    "Open its PR, or switch off it.")
    return None


def refuse_busy_checkout(git, root: str, env: Mapping[str, str], *signals: str) -> None:
    """The busy-checkout refusal, bash refuse_busy_checkout: checks the
    <signals> named, as checkout_busy does; in a busy checkout it dies with
    the line naming what holds it and its remedy, exit 3, a code no other
    failure of its callers uses, so a skill can tell a busy checkout apart
    from every other refusal."""
    busy = checkout_busy(git, root, env, signals)
    if busy is not None:
        die("%s\n     %s" % busy, 3)
