"""The side-checkout concept's module, as far as the checkout scan and the
converted nouns need it: the ownership marker that makes a worktree a side
checkout, where a flow is archived, the archive itself, and the side
checkout's teardown - archived first, then removed (ADR-0037) - as the bash
side's side-checkout.sh makes them. A side checkout is a worktree the plugin
makes under the main checkout's .orchestrator/checkouts/ (ADR-0037); the
marker in the worktree's own git folder - which git deletes with the
worktree - is what makes it one, never a flow's state file, since a
hand-made worktree can hold a flow too. Its bash copies stay while bash
modules call them (ADR-0067).
"""
from __future__ import annotations

import errno
import os
import shutil
import time
from typing import Callable, Optional, Tuple

from orch.checkout import (checkout_gitdir_into, checkout_has_flow, checkout_kind,
                           refuse_ticket_worktrees)
from orch.common import ORCH_DIR_NAME, capture, die, dir_stamp, stdout_write, warn
from orch.flow_state import flow_state_file, flow_state_get_many

# The ownership marker's file name, in the worktree's own git folder.
SIDE_CHECKOUT_MARKER = "orchestrator-side-checkout"

# The top-level entries under .orchestrator/ that belong to no flow, which
# archive_flow leaves in place - bash FLOW_LESS_ENTRIES, whose comment gives
# each entry's reason and the rule a new entry follows.
FLOW_LESS_ENTRIES = ("archive", "checkouts", "spec-review", "review-pass", "audit",
                     "autopilot", "breakdown", "reports", "verification", "wait")


def side_checkout_marked(gitdir: str) -> bool:
    """Whether the git folder <gitdir> holds the ownership marker - the one
    place the marker's presence is tested."""
    return os.path.isfile(os.path.join(gitdir, SIDE_CHECKOUT_MARKER))


def side_checkout_marker(git, path: str) -> Optional[str]:
    """The ownership marker's path for the worktree at <path>; None when it
    carries none. The git folder comes from the worktree's own git pointer
    (checkout_gitdir_into), so a worktree costs no git process; only a
    pointer that cannot be read that way asks git, through the adapter
    <git>."""
    gitdir = checkout_gitdir_into(git, path)
    if gitdir is None or not side_checkout_marked(gitdir):
        return None
    return os.path.join(gitdir, SIDE_CHECKOUT_MARKER)


def _note(text: str) -> None:
    """bash note: <text> and a newline on stdout."""
    stdout_write(text + "\n")


def archive_root(git, root: str) -> Optional[str]:
    """The checkout whose .orchestrator/archive/ receives the flow in the
    checkout at <root> - the one computation of the rule. A side checkout's
    flow goes to the main checkout's archive; any other checkout, a ticket
    or hand-made worktree included, archives in place. None when the
    checkouts cannot be read, or <root> is a side checkout and the main
    checkout cannot be read - never archiving a side checkout's flow in
    place."""
    kind = checkout_kind(git, root)
    if kind is None:
        return None
    return git.main_checkout() if kind == "side" else root


def side_checkout_refuse_ticket_worktrees(git, root: str) -> None:
    """Refuses while ticket worktrees are left under the checkout at <root>,
    the one reason this module gives."""
    refuse_ticket_worktrees(git, root, "moving them would break git's record of them")


def _move_into(entry: str, dest: str) -> bool:
    """mv <entry> <dest>/: whether it moved - renamed, or across file
    systems copied and removed."""
    target = os.path.join(dest, os.path.basename(entry))
    try:
        os.rename(entry, target)
    except OSError as err:
        if err.errno != errno.EXDEV:
            return False
        try:
            shutil.move(entry, target)
        except (OSError, shutil.Error):
            return False
    return True


def archive_flow(git, root: str, home: str, here_root: str,
                 clock: Callable[[], float] = time.time) -> str:
    """Moves the flow in the checkout at <root> into a directory under
    <home>'s .orchestrator/archive/, named for <clock>'s stamp and the
    flow's slug, and gives that directory - relative to <here_root>, the
    checkout the command runs in, when inside it, else in full. <home> is
    the caller's: a side checkout's flow goes to the main checkout's
    archive; any other checkout archives in place (see archive_root).

    Refuses while ticket worktrees are left under <root>. A failed
    archive-directory creation or move dies naming the path. state.json
    moves last, so a move failing partway leaves the flow recognisable where
    it stands - the entries already moved stay in the new archive directory,
    the rest in place, the message naming both - and a rerun archives what
    is left into a fresh directory. There is no rollback."""
    orch = os.path.join(root, ORCH_DIR_NAME)
    state = flow_state_file(root)
    side_checkout_refuse_ticket_worktrees(git, root)
    # A state.json that does not parse still archives - abort is the remedy
    # for it - under a slug standing in for the one it cannot give.
    read = flow_state_get_many(state, ("slug",))
    slug = read["slug"] if read is not None else "unreadable"
    dest = os.path.join(home, ORCH_DIR_NAME, "archive", dir_stamp(clock) + "-" + slug)
    try:
        os.makedirs(dest, exist_ok=True)
    except OSError:
        die("could not create the archive directory %s - nothing was archived" % dest)
    try:
        names = sorted(name for name in os.listdir(orch) if not name.startswith("."))
    except OSError:
        names = []
    entries = [
        os.path.join(orch, name) for name in names
        if name not in FLOW_LESS_ENTRIES and os.path.exists(os.path.join(orch, name))
        and os.path.join(orch, name) != state
    ]
    if os.path.exists(state):
        entries.append(state)
    for i, entry in enumerate(entries):
        if not _move_into(entry, dest):
            die("could not move %s into %s - moved there: %s; left in place: %s"
                % (entry, dest, " ".join(entries[:i]) or "nothing", " ".join(entries[i:])))
    prefix = here_root + "/"
    return dest[len(prefix):] if dest.startswith(prefix) else dest


def side_checkout_close_note(path: str, here: str) -> None:
    """Tells the human to close the session when the command ran in <here>,
    inside <path>, a worktree just removed: the session's working directory
    is gone."""
    if (here + "/").startswith(path + "/"):
        _note("This session's working directory was that side checkout, and it is gone"
              " - close this session.")


def side_checkout_remove_worktree(git, path: str, main_root: str, here: str,
                                  policy: str) -> bool:
    """Removes the side checkout at <path>, through the main checkout at
    <main_root>, never with force - the one site of a side checkout's
    teardown and of its refusal message. Then notes the removal and, when
    <here> (the directory the command ran in, read before the removal) was
    inside <path>, tells the human to close the session. A refusal dies
    under the `die` <policy>; under `warn` it warns and gives False."""
    err = git.worktree_remove(main_root, path)
    if err is not None:
        message = ("could not remove side checkout %s: %s - left as it stands. Commit or"
                   " discard its changes, then run orch.sh side-checkout remove %s."
                   % (path, err, os.path.basename(path)))
        if policy == "die":
            die(message)
        warn(message)
        return False
    _note("removed side checkout " + path)
    side_checkout_close_note(path, here)
    return True


def side_checkout_archive_and_remove(git, path: str, main_root: str, here: str, policy: str,
                                     here_root: str, clock: Callable[[], float] = time.time
                                     ) -> Tuple[int, str]:
    """The one site of ADR-0037's order: the flow in the side checkout at
    <path>, if any, is archived into the main checkout at <main_root> first
    (archive_flow, its directory shown from <here_root>), and only then is
    the worktree removed (see side_checkout_remove_worktree for <here> and
    <policy>). Gives (status, archive output): 0 removed, 1 removal refused
    under `warn`, 2 the archive failed - nothing removed, whatever the
    policy, the output then the archive's error as printed. A made archive
    is noted."""
    archive_out = ""
    if checkout_has_flow(path):
        shown, err, code = capture(
            lambda: archive_flow(git, path, main_root, here_root, clock))
        if code != 0:
            return 2, err.rstrip("\n")
        archive_out = shown
        _note(archive_out)
    removed = side_checkout_remove_worktree(git, path, main_root, here, policy)
    return (0 if removed else 1), archive_out


def side_checkout_archive_and_remove_or_exit(git, path: str, main_root: str, here: str,
                                             policy: str, here_root: str,
                                             clock: Callable[[], float] = time.time) -> int:
    """The CLI callers' shape of side_checkout_archive_and_remove - a failed
    archive relays its error through die, everything through its first
    `orch: ` dropped so it carries one prefix; otherwise its status (0
    removed, 1 removal refused under `warn`)."""
    status, archive_out = side_checkout_archive_and_remove(
        git, path, main_root, here, policy, here_root, clock)
    if status == 2:
        head, found, rest = archive_out.partition("orch: ")
        die(rest if found else head)
    return status
