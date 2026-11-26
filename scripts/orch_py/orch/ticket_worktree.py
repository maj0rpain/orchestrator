"""orch.sh's ticket-worktree noun (ADR-0067), `add`, `list` and `remove`, and
the ticket worktree concept the ticket noun's merge, close and reclaim reach:
a ticket number's check and its worktree's path, ticket_facts - the one read
of everything about a ticket, a TicketFacts record in place of bash's
associative array - and the requirements on it, the merged check of a ticket
branch, and ticket_worktree_teardown, the one site that tears a ticket
worktree down. orch.sh runs the noun as a converted noun, and the bash
ticket-worktree module is gone: each helper keeps the name it had there, with
its messages and its order of steps. ticket_worktrees_under and
refuse_ticket_worktrees are orch.checkout's, their bash copies in the bash
Checkout module, where side-checkout's per-checkout walk runs them with no
Python process. worktrees_left is the bridge doctor's leftover-ticket-worktree
check calls through orch_python_call.

A ticket worktree is a ticket's own worktree on its own ticket branch, so the
ticket subagents of one breakdown can build at once without sharing a
working tree (ADR-0036). Each lives at .orchestrator/worktrees/t<n> under the
current checkout's top level - inside the session's project directory, so an
implementer's edits draw no permission prompt - kept out of git status by
the clone's exclude file. Its ticket branch, <current-branch>--t<n>, records
the branch it was forked from under
branch.<ticket branch>.orchestrator-ticket-parent.

run(argv) takes the arguments after `ticket-worktree`, as orch.sh hands them
on, and returns the exit code; every error dies through orch.common.die. A
git command whose stderr bash let through hands it on here too, before the
`orch:` line, through git_failed, which ticket merge's fast-forward shares.
"""
from __future__ import annotations

import os
import sys
from typing import List, Mapping, NamedTuple, Optional

from orch.branch import branch_name_ticket, forked_from_branch, forked_from_set
from orch.checkout import (checkouts_unreadable, current_branch_or_die, discard_work_in,
                           rebase_in_progress, ticket_worktrees_under)
from orch.common import (ORCH_DIR_NAME, die, exclude_orch_dirs, plain_number, require_clean_tree,
                         stderr_write, stdout_write, warn)
from orch.git import Git
from orch.root import checkout_root

# The worktree states ticket_facts reads, one word each: a worktree sits at
# the path; git's record names the path and nothing is there; git's record
# names it and something that is not a worktree is there; no record (a
# leftover directory with no record behind it included).
WORKTREE, GONE, OCCUPIED, NONE = "worktree", "gone", "occupied", "none"


class TicketFacts(NamedTuple):
    """Everything about one ticket, read once by ticket_facts:
      n           the ticket number, so a helper handed only the facts can
                  name it
      path        where its ticket worktree lives
      worktree    the worktree state: WORKTREE, GONE, OCCUPIED or NONE
      wt_branch   the branch checked out in the ticket worktree; "" during
                  a rebase and in every state but WORKTREE
      parent      this checkout's current branch; "" on a detached HEAD
      own_branch  the ticket's own branch <parent>--t<n>; "" when parent is
                  ""
      own_exists  whether own_branch exists"""

    n: str
    path: str
    worktree: str
    wt_branch: str
    parent: str
    own_branch: str
    own_exists: bool


def ticket_worktree_number(text: str) -> str:
    """The ticket number <text> names, or dies: digits only, not zero, no
    leading zero."""
    if not plain_number(text) or text.startswith("0"):
        die("not a ticket number: %s (want a positive integer)" % (text or "<none>"))
    return text


def ticket_worktree_path(root: str, n: str) -> str:
    """The path of ticket #<n>'s worktree under the checkout at <root>."""
    return "%s/%s/worktrees/t%s" % (root, ORCH_DIR_NAME, n)


def ticket_facts(git, root: str, n: str) -> TicketFacts:
    """Reads everything about ticket <n> (already validated) under the
    checkout at <root>, through the git adapter <git>, and writes nothing.
    Reads git's record of the checkouts on every call and dies, exit 1, only
    when it cannot be read, never reading that as none."""
    path = ticket_worktree_path(root, n)
    worktrees = git.worktree_list()
    if worktrees is None:
        checkouts_unreadable()
    entry = next((worktree for worktree in worktrees if worktree.path == path), None)
    state, wt_branch = NONE, ""
    if git.toplevel_at(path) == path:
        state = WORKTREE
        wt_branch = (entry.branch or "") if entry is not None else ""
    elif entry is not None:
        state = OCCUPIED if os.path.lexists(path) else GONE
    parent = git.current_branch() or ""
    own_branch = branch_name_ticket(parent, n) if parent else ""
    own_exists = bool(own_branch) and git.branch_exists(own_branch)
    return TicketFacts(n, path, state, wt_branch, parent, own_branch, own_exists)


def ticket_facts_require_worktree(facts: TicketFacts, *states: str) -> None:
    """Dies, "no ticket worktree for ticket <n> at <path>", unless the
    worktree state in <facts> is one of the <states> its caller accepts."""
    if facts.worktree not in states:
        die("no ticket worktree for ticket %s at %s" % (facts.n, facts.path))


def ticket_facts_require_wt_branch(facts: TicketFacts) -> None:
    """Dies unless the ticket worktree in <facts> is on a branch."""
    if not facts.wt_branch:
        die("ticket worktree %s is not on a branch (detached HEAD)" % facts.path)


def ticket_facts_require_parent(git, facts: TicketFacts) -> None:
    """Dies unless this checkout is on a branch, through
    current_branch_or_die so that message keeps its one home."""
    if not facts.parent:
        current_branch_or_die(git)


def ticket_branch_merged(git, branch: str) -> bool:
    """Whether ticket branch <branch> records a forked-from branch and is an
    ancestor of it - the one merged check. Both are named in full, so a tag
    of either name is never taken for the branch (#2337)."""
    parent = forked_from_branch(git, branch)
    return parent is not None and git.is_ancestor("refs/heads/" + branch,
                                                  "refs/heads/" + parent)


def ticket_branch_merged_or_die(git, branch: str, what: str) -> None:
    """Dies unless ticket_branch_merged holds, shared by ticket-worktree
    remove and ticket close. Each refusal ends "pass --unmerged to <what>",
    <what> naming the command's act."""
    parent = forked_from_branch(git, branch)
    if parent is None:
        die("branch %s records no forked-from branch - pass --unmerged to %s" % (branch, what))
    if not ticket_branch_merged(git, branch):
        die("branch %s is not merged into %s - merge it first, or pass --unmerged to %s"
            % (branch, parent, what))


def git_failed(failure) -> bool:
    """Hands a failed git run's stderr on, as bash let it through: whether
    the run failed."""
    if failure is None:
        return False
    stderr_write(failure.stderr)
    return True


def add(args: List[str], git, root: str) -> None:
    """Forks <current-branch>--t<n> from the current branch's tip, records
    the forked-from branch on it, checks it out at
    .orchestrator/worktrees/t<n> and prints the path. The exclude entry is
    written before the branch exists; anything failing after that takes the
    worktree and the branch back out before dying."""
    if len(args) != 1:
        die("usage: orch.sh ticket-worktree add <n>")
    n = ticket_worktree_number(args[0])
    facts = ticket_facts(git, root, n)
    ticket_facts_require_parent(git, facts)
    path, own_branch = facts.path, facts.own_branch
    if os.path.exists(path):
        die("ticket worktree %s already exists" % path)
    if facts.own_exists:
        die("branch %s already exists" % own_branch)
    exclude_orch_dirs(git)
    if git_failed(git.branch_create(own_branch, "HEAD")):
        die("could not create branch %s" % own_branch)
    if git_failed(git.worktree_add(path, own_branch)) \
            or not forked_from_set(git, own_branch, facts.parent):
        # A freshly added worktree holds nothing of anyone's, so no force is
        # needed to take it back out; -D deletes the branch's config section
        # too. Both run silenced, as bash's 2>/dev/null.
        if os.path.exists(path):
            git.worktree_delete(path)
        git.branch_delete(own_branch)
        die("could not add ticket worktree %s - removed branch %s again" % (path, own_branch))
    stdout_write(path + "\n")


# The results ticket_worktree_teardown returns, one per removal step; each is
# outside 0, 1, 2 and 3, which commands give their own meanings.
TICKET_TEARDOWN_WORKTREE_FAILED = 10
TICKET_TEARDOWN_BRANCH_FAILED = 11


def ticket_worktree_teardown(git, facts: TicketFacts, unmerged: bool = False,
                             discard: bool = False) -> int:
    """The one site that tears a ticket worktree down, from the <facts> its
    caller read with ticket_facts; it reads none itself. The branch it
    deletes is always the ticket's own, never one the worktree merely has
    checked out (that one is left in place). <discard> first discards the
    work in the worktree under the label "ticket #<n>". <unmerged> aborts a
    rebase in progress there and skips the merged check of the ticket
    branch, which otherwise runs before anything is removed. A dirty
    worktree is refused and nothing is ever forced; the worktree is then
    removed and the ticket branch deleted with -D (the merged check, when it
    applies, already proved it merged into its forked-from branch, where -d
    would judge it against this checkout's HEAD). A refusal before anything
    is removed dies. A failed removal step prints its message and returns its
    own result, TICKET_TEARDOWN_WORKTREE_FAILED or
    TICKET_TEARDOWN_BRANCH_FAILED, leaving what already happened in place;
    0 when both steps are done."""
    ticket_facts_require_parent(git, facts)
    path = facts.path
    # Only a worktree at the path itself: a leftover t<n> directory's
    # enclosing checkout is not ours to discard, abort or remove.
    if facts.worktree == OCCUPIED:
        die("ticket worktree path %s holds something that is not a worktree, though git's"
            " record names it - delete it and run the command again" % path)
    # A record with its directory gone has nothing to discard, abort or check.
    if facts.worktree == WORKTREE:
        if discard:
            discard_work_in(git, path, "ticket #" + facts.n)
        if unmerged and rebase_in_progress(git, path) \
                and git_failed(git.rebase_abort_at(path)):
            die("could not abort the rebase in progress in ticket worktree %s" % path)
        require_clean_tree(git, path, "ticket worktree %s is dirty - commit or discard its"
                                      " changes first; it is never removed with force" % path)
    elif facts.worktree == NONE and not facts.own_exists:
        die("no ticket worktree or branch for ticket %s at %s" % (facts.n, path))
    if not unmerged:
        ticket_branch_merged_or_die(git, facts.own_branch, "discard it")
    if facts.worktree != NONE and git_failed(git.worktree_delete(path)):
        warn("could not remove ticket worktree %s" % path)
        return TICKET_TEARDOWN_WORKTREE_FAILED
    if facts.own_exists and git_failed(git.branch_delete(facts.own_branch)):
        warn("could not delete branch %s" % facts.own_branch)
        return TICKET_TEARDOWN_BRANCH_FAILED
    return 0


def _listing(git, root: str) -> None:
    """Prints <n> <path> for every ticket worktree under the checkout at
    <root>, and nothing else."""
    stdout_write("".join("%s %s\n" % pair for pair in ticket_worktrees_under(git, root)))


def list_(args: List[str], git, root: str) -> None:
    """Prints <n> <path> for every ticket worktree under this checkout's
    .orchestrator/worktrees/, and nothing else: another checkout's ticket
    worktrees are that checkout's business."""
    if args:
        die("usage: orch.sh ticket-worktree list")
    _listing(git, root)


REMOVE_USAGE = "usage: orch.sh ticket-worktree remove <n> [--unmerged]"


def remove(args: List[str], git, root: str) -> None:
    """Removes ticket <n>'s worktree and deletes its branch, never with
    force: argument parsing over ticket_worktree_teardown, dying when there
    is no worktree and exiting 1 when either removal step fails."""
    n, unmerged = "", False
    for arg in args:
        if arg == "--unmerged":
            unmerged = True
        elif arg.startswith("-"):
            die("unknown flag: %s (%s)" % (arg, REMOVE_USAGE))
        elif n:
            die(REMOVE_USAGE)
        else:
            n = arg
    # Only that a worktree or git's record of one exists is required here:
    # its branch cannot be read, while a rebase leaves HEAD detached, until
    # the teardown has aborted the rebase. A record with something else at
    # its path is the teardown's refusal to make.
    n = ticket_worktree_number(n)
    facts = ticket_facts(git, root, n)
    ticket_facts_require_worktree(facts, WORKTREE, GONE, OCCUPIED)
    if ticket_worktree_teardown(git, facts, unmerged=unmerged) != 0:
        sys.exit(1)


VERBS = {"add": add, "list": list_, "remove": remove}


def worktrees_left(args: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> None:
    """Bridge for doctor's leftover-ticket-worktree check, once per run:
    prints the <n> <path> lines `ticket-worktree list` prints, from the same
    root, this checkout's. It takes no arguments. The real git adapter and
    the process's environment unless a test hands in others."""
    if args:
        die("usage: orch_python_call ticket-worktree worktrees_left")
    git = Git() if git is None else git
    _listing(git, checkout_root(git, os.environ if env is None else env))


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None) -> int:
    """`orch.sh ticket-worktree <op> ...`: the real git adapter and the
    process's environment unless a test hands in others. Outside a checkout
    it dies first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    verb = VERBS.get(op)
    if verb is None:
        die("unknown ticket-worktree op: %s (want add|list|remove)" % (op or "<none>"))
    verb(argv[1:], git, root)
    return 0
