"""The checkout concept's module, as far as a converted noun needs it: the
main checkout, the current branch, whether a path is a ticket worktree's,
the checkout scan, one checkout's kind, what a checkout holds, the
ticket-worktree refusal and the busy-checkout refusal, as the bash side's
checkout.sh and ticket-worktree.sh read them. Its bash copies stay while
bash modules call them (ADR-0067).
"""
from __future__ import annotations

import os
from typing import List, Mapping, NamedTuple, Optional, Tuple

from orch.branch import branch_is_retired, branch_pr_get, branch_records_base
from orch.common import ORCH_DIR_NAME, die, plain_number
from orch.flow_state import flow_state_file, flow_state_get_many
from orch.host import flow_cmd


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
