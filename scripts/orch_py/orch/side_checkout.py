"""The side-checkout concept's module, as far as the checkout scan and the
converted nouns need it: the ownership marker that makes a worktree a side
checkout, where a flow is archived, the archive itself, and the side
checkout's teardown - archived first, then removed (ADR-0037) - as the bash
side's side-checkout.sh makes them, and the finished check, the sweep's
own, that doctor reports a side checkout left standing by. A side checkout is
a worktree the plugin makes under the main checkout's .orchestrator/checkouts/
(ADR-0037); the marker in the worktree's own git folder - which git deletes
with the worktree - is what makes it one, never a flow's state file, since a
hand-made worktree can hold a flow too. Its bash copies stay while bash
modules call them (ADR-0067).
"""
from __future__ import annotations

import errno
import os
import shutil
import time
from typing import Callable, List, NamedTuple, Optional, Tuple

from orch.checkout import (checkout_gitdir_into, checkout_has_flow, checkout_kind,
                           refuse_ticket_worktrees)
from orch.base import recorded_base_of
from orch.checkout import checkout_branch
from orch.common import (ORCH_DIR_NAME, capture, die, dir_stamp, mkdir_p_or_die, state_word,
                         stdout_write, tree_status, warn)
from orch.flow_state import flow_state_file, flow_state_get_many, recorded_pr
from orch.gh import GhFailed, Unparsed, gh_reason
from orch.trust import trust_filter_prs

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


def side_checkout_marker_issue(git, path: str) -> Optional[str]:
    """The issue the ownership marker of the worktree at <path> records -
    bash side_checkout_marker_issue_into; None when it carries no marker, or
    the marker's content - the whole file, trailing newlines dropped, judged
    as one value - is no plain issue number (a marker of more than one line
    or holding a NUL byte included). For a readable git pointer it starts no
    git process."""
    marker = side_checkout_marker(git, path)
    if marker is None:
        return None
    try:
        with open(marker, "rb") as f:
            value = f.read().decode("utf-8", "surrogateescape").rstrip("\n")
    except OSError:
        return None
    return value if value and value.isascii() and value.isdigit() else None


# --- the finished check ---
#
# Finished is read from GitHub's PR state, never git ancestry: a squash or
# rebase merge never makes the branch an ancestor of its base (ADR-0037).

# A verdict's codes, as bash's finished checks return them: finished; not
# finished, the reason given; or the verdict could not be read, GitHub or
# the checkout's own git status, the reason naming which, and its error.
FINISHED, NOT_FINISHED, UNREAD = 0, 1, 2


class Verdict(NamedTuple):
    """A finished check's answer: its code, and the reason - "" for
    finished."""

    code: int
    reason: str


def _not(reason: str) -> Verdict:
    return Verdict(NOT_FINISHED, reason)


def _unread(reason: str) -> Verdict:
    return Verdict(UNREAD, reason)


def finished_flow(gh, state_file: str, default: Callable[[], str]
                  ) -> Tuple[Verdict, str, List[str]]:
    """Whether the flow at <state_file> is finished - bash finished_flow: at
    done, and its recorded PR merged into its own base branch (the default
    branch <default> names where the flow recorded none), read through the
    gh adapter <gh>. With the verdict, the flow's branch and the one merged
    PR line - its number, a tab, its head SHA - the branch tip is judged
    against."""
    state = flow_state_get_many(state_file, ("phase", "slug", "branch", "pr", "base"))
    if state is None:
        return _unread("could not read " + state_file), "", []
    branch, pr = state["branch"], state["pr"]
    if state["phase"] != "done":
        return _not("flow %s is at %s, not done" % (state["slug"], state["phase"])), branch, []
    if not branch:
        return _not("no branch"), branch, []
    if not pr:
        return _not("no PR recorded"), branch, []
    base = state["base"] or default()
    try:
        pr_state, _ = gh.pr_state_draft(recorded_pr(pr))
        if pr_state != "MERGED":
            return _not("PR #%s is %s" % (pr, state_word(pr_state))), branch, []
        head, _, merged_base = gh.pr_refs(recorded_pr(pr))
    except GhFailed as failed:
        return _unread("could not read GitHub: " + gh_reason(failed.stderr)), branch, []
    if merged_base != base:
        return _not("PR #%s merged into %s, not %s" % (pr, merged_base, base)), branch, []
    return Verdict(FINISHED, ""), branch, ["%s\t%s" % (pr, head)]


def tip_covered(git, branch: str, prs: List[str]) -> Verdict:
    """Whether <branch>'s local tip is held by a merged PR - bash
    tip_covered: equal to its head SHA or an ancestor of it, read through
    the git adapter <git>. <prs> are lines of a number, a tab and a head
    SHA, newest first; any covering head is enough. Not finished names the
    newest PR whose head is missing from this repo (the sweep never
    fetches), or else the newest PR; unread where git cannot judge a head
    that is present."""
    tip = git.resolve_commit("refs/heads/" + branch)
    if tip is None:
        return _unread("could not read the tip of " + branch)
    first = missing = None
    for line in prs:
        n, _, head = line.partition("\t")
        if not n:
            continue
        first = first or (n, head)
        if not head or not git.has_commit(head):
            missing = missing or (n, head)
            continue
        if tip == head:
            return Verdict(FINISHED, "")
        covered = git.ancestry(tip, head)
        if covered:
            return Verdict(FINISHED, "")
        if covered is None:
            return _unread("could not compare %s with PR #%s's head %s" % (branch, n, head[:7]))
    if missing is not None:
        return _not("%s: PR #%s's head %s is not in this repo - fetch it to let the sweep judge"
                    % (branch, missing[0], missing[1][:7]))
    n, head = first or ("", "")
    return _not("%s has commits past PR #%s's merged head %s" % (branch, n, head[:7]))


def side_checkout_finished(gh, git, path: str, default: Callable[[], str]) -> Verdict:
    """Whether the side checkout at <path> is finished - bash
    side_checkout_finished, the sweep's own test and the glossary's
    **Finished**: a clean tree, and either a finished flow (finished_flow),
    or no flow and a PR merged from its checked-out branch into the base
    branch recorded for it (recorded_base_of, the default branch <default>
    names) - and the branch's tip held by a merged PR (tip_covered), so the
    sweep's branch -D never drops a commit. Read through the gh adapter <gh>
    and the git adapter <git>. A git status that cannot run is unread, as
    an unreadable GitHub is, so nothing is removed on a tree that could not
    be read."""
    status, why = tree_status(git, path)
    if status is None:
        return _unread(why)
    if status:
        return _not("uncommitted changes or untracked files")
    if checkout_has_flow(path):
        verdict, branch, merged = finished_flow(gh, flow_state_file(path), default)
        return verdict if verdict.code != FINISHED else tip_covered(git, branch, merged)
    branch = checkout_branch(git, path)
    if branch is None:
        return _not("no branch")
    base = recorded_base_of(git, branch, default)
    try:
        raw = gh.prs_merged(branch, base)
    except GhFailed as failed:
        return _unread("could not read GitHub: " + gh_reason(failed.stderr))
    try:
        prs = trust_filter_prs(branch, raw)
    except Unparsed:
        return _unread("could not read GitHub: the merged PRs from %s into %s" % (branch, base))
    if not prs:
        return _not("no merged PR from %s into %s" % (branch, base))
    return tip_covered(git, branch, prs)


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
    state_file = flow_state_file(root)
    side_checkout_refuse_ticket_worktrees(git, root)
    # A state.json that does not parse still archives - abort is the remedy
    # for it - under a slug standing in for the one it cannot give.
    state = flow_state_get_many(state_file, ("slug",))
    slug = state["slug"] if state is not None else "unreadable"
    dest = os.path.join(home, ORCH_DIR_NAME, "archive", dir_stamp(clock) + "-" + slug)
    mkdir_p_or_die(dest, "could not create the archive directory %s - nothing was archived" % dest)
    try:
        names = sorted(name for name in os.listdir(orch) if not name.startswith("."))
    except OSError:
        names = []
    entries = [
        os.path.join(orch, name) for name in names
        if name not in FLOW_LESS_ENTRIES and os.path.exists(os.path.join(orch, name))
        and os.path.join(orch, name) != state_file
    ]
    if os.path.exists(state_file):
        entries.append(state_file)
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
        stdout_write("This session's working directory was that side checkout, and it is gone"
                     " - close this session.\n")


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
    stdout_write("removed side checkout " + path + "\n")
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
        stdout_write(archive_out + "\n")
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
