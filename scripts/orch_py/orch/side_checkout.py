"""The side-checkout concept's module, as far as the checkout scan and the
converted nouns need it: the ownership marker that makes a worktree a side
checkout, where a flow is archived, the archive itself, and the side
checkout's teardown - archived first, then removed (ADR-0037) - as the bash
side's side-checkout.sh makes them, and the finished check, the sweep's
own, that doctor reports a side checkout left standing by. It holds too the
side-checkout verbs Python autopilot reaches, which the side-checkout
conversion will call: add, with the name a picked-up issue's side checkout
is made under, the finished sweep (prune), with its merged-PR close calling
the pr module's close_missed_finish in-process, the side checkouts directory
and the side checkout an issue's marker records. A side checkout is
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
import sys
import time
from contextlib import contextmanager, redirect_stdout
from typing import (Callable, Dict, Iterator, List, Mapping, NamedTuple, Optional, Sequence,
                    Tuple)

from orch.base import base_in_effect, default_branch, recorded_base_of
from orch.branch import branch_issue_of
from orch.checkout import (checkout_branch, checkout_gitdir_into, checkout_has_flow,
                           checkout_kind, checkouts, main_checkout_or_die,
                           refuse_ticket_worktrees)
from orch.common import (ORCH_DIR_NAME, capture, die, dir_stamp, err_line, exclude_orch_dirs,
                         first_line, mkdir_p_or_die, normalize_slug, plain_number, state_word,
                         stderr_write, stdout_write, subshell, tree_status, warn)
from orch.flow_state import flow_state_file, flow_state_get_many, recorded_pr
from orch.gh import GhFailed, Unparsed, gh_reason
from orch.repo import RepoPin
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
    return value if plain_number(value) else None


def side_checkouts_dir(main_root: str) -> str:
    """Where the side checkouts of the main checkout at <main_root> live."""
    return "%s/%s/checkouts" % (main_root, ORCH_DIR_NAME)


def side_checkout_for_issue(git, issue: str) -> Optional[str]:
    """The path of the side checkout whose marker records <issue>, read
    through the git adapter <git>'s checkout scan - bash
    side_checkout_for_issue; None when there is none, the scan failing
    included."""
    found = checkouts(git)
    for checkout in found or ():
        if checkout.kind == "side" and side_checkout_marker_issue(git, checkout.path) == issue:
            return checkout.path
    return None


# The longest short slug a side checkout is named for: whole words of the
# issue title up to it.
SHORT_SLUG_MAX = 40


def short_slug(title: str) -> str:
    """The normalised <title> as whole hyphen-separated words of at most
    SHORT_SLUG_MAX characters in all - bash autopilot_short_slug. A first
    word over the limit on its own is cut at it, so the slug is never empty;
    a title that normalises to nothing gives `untitled`."""
    norm, _, _ = capture(lambda: normalize_slug(title))
    if not norm:
        return "untitled"
    slug = ""
    for word in norm.split("-"):
        longer = slug + "-" + word if slug else word
        if len(longer) > SHORT_SLUG_MAX:
            return slug or word[:SHORT_SLUG_MAX]
        slug = longer
    return slug


def side_checkout_free_slug(main_root: str, title: str, issue: str) -> str:
    """The name the side checkout for issue <issue>, titled <title>, is made
    under in the main checkout at <main_root> - bash
    autopilot_pickup_side_add's: its short slug, else <slug>-<issue>, else
    <slug>-<issue>-2, -3 and so on, the first with no entry of that name in
    the side checkouts directory, a plain file counting as a clash."""
    directory = side_checkouts_dir(main_root)
    slug = short_slug(title)
    if not os.path.exists(os.path.join(directory, slug)):
        return slug
    stem = slug = "%s-%s" % (slug, issue)
    n = 1
    while os.path.exists(os.path.join(directory, slug)):
        n += 1
        slug = "%s-%d" % (stem, n)
    return slug


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


def _not_finished(reason: str) -> Verdict:
    return Verdict(NOT_FINISHED, reason)


# A state file's reader, flow_state_get_many's shape: the values of the keys
# asked, or None for a file that cannot be read.
StateRead = Callable[[str, Sequence[str]], Optional[Dict[str, str]]]


def finished_flow(gh, state_file: str, default: Callable[[], str], read_state: StateRead
                  ) -> Tuple[Verdict, str, List[str]]:
    """Whether the flow at <state_file> is finished - bash finished_flow: at
    done, and its recorded PR merged into its own base branch (the default
    branch <default> names where the flow recorded none), its state read by
    <read_state> and GitHub through the gh adapter <gh>. With the verdict,
    the flow's branch and the one merged PR line - its number, a tab, its
    head SHA - the branch tip is judged against."""
    state = read_state(state_file, ("phase", "slug", "branch", "pr", "base"))
    if state is None:
        return Verdict(UNREAD, "could not read " + state_file), "", []
    branch, pr = state["branch"], state["pr"]
    if state["phase"] != "done":
        reason = "flow %s is at %s, not done" % (state["slug"], state["phase"])
        return _not_finished(reason), branch, []
    if not branch:
        return _not_finished("no branch"), branch, []
    if not pr:
        return _not_finished("no PR recorded"), branch, []
    base = state["base"] or default()
    try:
        pr_state, _ = gh.pr_state_draft(recorded_pr(pr))
        if pr_state != "MERGED":
            return _not_finished("PR #%s is %s" % (pr, state_word(pr_state))), branch, []
        head, _, merged_base = gh.pr_refs(recorded_pr(pr))
    except GhFailed as failed:
        return Verdict(UNREAD, "could not read GitHub: " + gh_reason(failed.stderr)), branch, []
    if merged_base != base:
        return _not_finished("PR #%s merged into %s, not %s" % (pr, merged_base, base)), branch, []
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
        return Verdict(UNREAD, "could not read the tip of " + branch)
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
            return Verdict(UNREAD, "could not compare %s with PR #%s's head %s"
                           % (branch, n, head[:7]))
    if missing is not None:
        return _not_finished("%s: PR #%s's head %s is not in this repo - fetch it to let the sweep"
                             " judge" % (branch, missing[0], missing[1][:7]))
    first_n, first_head = first or ("", "")
    return _not_finished("%s has commits past PR #%s's merged head %s"
                         % (branch, first_n, first_head[:7]))


def side_checkout_finished(gh, git, path: str, default: Callable[[], str],
                           read_state: StateRead) -> Verdict:
    """Whether the side checkout at <path> is finished - bash
    side_checkout_finished, the sweep's own test and the glossary's
    **Finished**: the verdict side_checkout_verdict gives, without its
    branch."""
    return side_checkout_verdict(gh, git, path, default, read_state)[0]


def side_checkout_verdict(gh, git, path: str, default: Callable[[], str],
                          read_state: StateRead) -> Tuple[Verdict, str]:
    """Whether the side checkout at <path> is finished, and the branch the
    sweep deletes when it is - "" where none was read: a clean tree, and
    either a finished flow (finished_flow, its recorded branch), or no flow
    and a PR merged from its checked-out branch into the base branch
    recorded for it (recorded_base_of, the default branch <default> names) -
    and the branch's tip held by a merged PR (tip_covered), so the sweep's
    branch -D never drops a commit. Read through the gh adapter <gh> and the
    git adapter <git>, a flow's state by <read_state>. A git status that
    cannot run is unread, as an unreadable GitHub is, so nothing is removed
    on a tree that could not be read."""
    status, why = tree_status(git, path)
    if status is None:
        return Verdict(UNREAD, why), ""
    if status:
        return _not_finished("uncommitted changes or untracked files"), ""
    if checkout_has_flow(path):
        verdict, branch, merged = finished_flow(gh, flow_state_file(path), default, read_state)
        if verdict.code != FINISHED:
            return verdict, branch
        return tip_covered(git, branch, merged), branch
    branch = checkout_branch(git, path)
    if branch is None:
        return _not_finished("no branch"), ""
    base = recorded_base_of(git, branch, default)
    try:
        raw = gh.prs_merged(branch, base)
    except GhFailed as failed:
        return Verdict(UNREAD, "could not read GitHub: " + gh_reason(failed.stderr)), branch
    try:
        prs = trust_filter_prs(branch, raw)
    except Unparsed:
        return Verdict(UNREAD, "could not read GitHub: the merged PRs from %s into %s"
                       % (branch, base)), branch
    if not prs:
        return _not_finished("no merged PR from %s into %s" % (branch, base)), branch
    return tip_covered(git, branch, prs), branch


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


# --- the finished sweep and add -------------------------------------------------
#
# The side-checkout verbs Python autopilot reaches, as bash side-checkout.sh's
# cmd_side_checkout_prune and cmd_side_checkout_add make them: each takes the
# verb's arguments, the gh and git adapters, the environment, the root of the
# checkout the command runs in (an archive's directory is shown from it) and,
# for a test, the directory it runs in and the clock. Each prints what the
# bash verb prints, and dies as it dies. Neither starts orch.sh.

PRUNE_USAGE = "usage: orch.sh side-checkout prune"
ADD_USAGE = "usage: orch.sh side-checkout add <slug> [--issue N]"


def _here() -> str:
    """The directory the command runs in, as bash's `pwd -P` reads it; ""
    where it is gone."""
    try:
        return os.path.realpath(os.getcwd())
    except OSError:
        return ""


@contextmanager
def _in_main_checkout(main_root: str) -> Iterator[None]:
    """Runs the body from the main checkout at <main_root>, as bash's `cd
    "$main_root"`, so removing the checkout the command ran in leaves it
    somewhere to stand; dies when it cannot enter it. The directory the
    command ran in is entered again afterwards, as bash's subshell leaves
    it, while it still exists."""
    try:
        before: Optional[str] = os.getcwd()
    except OSError:
        before = None
    try:
        os.chdir(main_root)
    except OSError:
        die("could not enter the main checkout " + main_root)
    try:
        yield
    finally:
        if before is not None:
            try:
                os.chdir(before)
            except OSError:
                pass


def _default_once(gh, git, env: Mapping[str, str]) -> Tuple[object, Callable[[], str]]:
    """<gh> with its default-branch answer asked of GitHub once (pr's
    DefaultOnce), and the default branch read through it - bash's memo of
    the default branch, which a sweep, its merged-PR closes and add share."""
    from orch.pr import DefaultOnce

    once = DefaultOnce(gh)
    pin = RepoPin(env, git)
    return once, lambda: default_branch(once, git, pin).name


def side_checkout_close_missed(gh, git, env: Mapping[str, str], path: str, branch: str,
                               clock: Callable[[], float] = time.time) -> None:
    """The merged-PR backstop (#2477) for a checkout the sweep judged
    finished, run before it is archived or removed - bash
    side_checkout_close_missed. A flow's issue and PR are the ones its state
    records; a flow-less checkout's PR is the newest merged from <branch>
    and its issue the one a `quick/<issue>-` branch names - any other branch
    is skipped. Reads the issue's state through gh's state-and-labels read,
    and closes it, when open, through pr's close_missed_finish, in-process,
    at <clock>'s time. A failed read or close warns and never fails the
    sweep: a death in the close is the close's alone."""
    from orch.pr import close_missed_finish

    if checkout_has_flow(path):
        state = flow_state_get_many(flow_state_file(path), ("issue", "pr"))
        if state is None or not state["issue"] or not state["pr"]:
            return
        issue, pr = state["issue"], state["pr"]
    else:
        issue = branch_issue_of(branch) if branch.startswith("quick/") else None
        if issue is None:
            return
        pr = ""
    # state set refuses an issue that is no plain number, so a flow's never
    # is one: there is nothing to read.
    if not plain_number(issue):
        return
    try:
        state_read, _ = gh.issue_state_labels(int(issue))
    except GhFailed as failed:
        warn("could not read issue #%s: %s - the merged-PR close skips it"
             % (issue, gh_reason(failed.stderr)))
        return
    if state_read != "OPEN":
        return
    subshell(lambda: close_missed_finish([issue, pr, branch], gh=gh, git=git, env=env,
                                         now=clock))


def side_checkout_prune(argv: Sequence[str], gh, git, env: Mapping[str, str], root: str,
                        here: Optional[str] = None,
                        clock: Callable[[], float] = time.time) -> int:
    """`side-checkout prune`, the sweep behind /orchestrator:finish - bash
    cmd_side_checkout_prune. Every verdict is read first, so a GitHub that
    cannot be read removes nothing at all. Then each finished side checkout,
    in git's order, has its merged-PR close run, its flow archived into the
    main checkout, its worktree removed - never with force - and its local
    branch deleted with -D, which -d would refuse for a squash merge; a
    failure is reported, that checkout left as it stands, and the sweep
    moves on. The main checkout's finished flow is archived in place, its
    branch left checked out. A hand-made worktree holding a flow is reported
    and left alone. Its status: 0, or 1 when any finished checkout failed;
    it dies when a verdict could not be read."""
    if argv:
        die(PRUNE_USAGE)
    here = _here() if here is None else here
    walk = checkouts(git)
    if not walk:
        die("could not read the checkouts - nothing was removed")
    main_root = walk[0].path
    gh, default = _default_once(gh, git, env)
    with _in_main_checkout(main_root):
        finished: List[Tuple[str, str]] = []
        unread = 0
        for checkout in walk:
            if checkout.kind == "main":
                if not checkout.flow:
                    continue
                verdict, branch, _ = finished_flow(gh, flow_state_file(checkout.path), default,
                                                   flow_state_get_many)
            elif checkout.kind == "side":
                verdict, branch = side_checkout_verdict(gh, git, checkout.path, default,
                                                        flow_state_get_many)
            else:
                if checkout.flow:
                    stdout_write("%s: not a side checkout, left alone\n" % checkout.path)
                continue
            if verdict.code == FINISHED:
                finished.append((checkout.path, branch))
            elif verdict.code == NOT_FINISHED:
                stdout_write("skipped %s: %s\n" % (checkout.path, verdict.reason))
            else:
                warn("could not check %s: %s" % (checkout.path, verdict.reason))
                unread += 1
        if unread:
            die("%d checkout(s) could not be checked - nothing was removed" % unread)
        if not finished:
            stdout_write("no finished side checkouts\n")
            return 0
        failed = False
        for path, branch in finished:
            side_checkout_close_missed(gh, git, env, path, branch, clock)
            if path == main_root:
                failed = not _archive_main_in_place(git, main_root, root, clock) or failed
                continue
            status, archive_out = side_checkout_archive_and_remove(
                git, path, main_root, here, "warn", root, clock)
            if status == 2:
                warn("could not archive the flow in side checkout %s: %s - left as it stands"
                     % (path, err_line(archive_out)))
            if status != 0:
                failed = True
                continue
            refused = git.branch_delete(branch)
            if refused is not None:
                warn("could not delete branch %s: %s" % (branch, first_line(refused.stderr)))
                failed = True
                continue
            stdout_write("deleted branch %s\n" % branch)
    return 1 if failed else 0


def _archive_main_in_place(git, main_root: str, root: str, clock: Callable[[], float]) -> bool:
    """The sweep's step for the main checkout's finished flow: archived in
    place, its branch left checked out, each noted; a failed archive warned
    of with one prefix. Whether it was archived."""
    shown, err, code = capture(lambda: archive_flow(git, main_root, main_root, root, clock))
    if code != 0:
        warn("could not archive the main checkout's flow: " + err_line(err))
        return False
    stdout_write(shown + "\n")
    stdout_write("archived the main checkout's flow in place - %s is still checked out\n"
                 % (checkout_branch(git, main_root) or ""))
    return True


def side_checkout_add(argv: Sequence[str], gh, git, env: Mapping[str, str], root: str,
                      here: Optional[str] = None,
                      clock: Callable[[], float] = time.time) -> str:
    """`side-checkout add <slug> [--issue N]` - bash cmd_side_checkout_add:
    the finished sweep first, its report on stderr, a failed one warned of
    and never stopping add; then a worktree under the main checkout's side
    checkouts directory, on no branch at origin/<base>, the base branch in
    effect, freshly fetched - git refuses one branch in two worktrees, and
    the main checkout usually holds the base - carrying the ownership
    marker, with --issue's number written into it, so a session opened
    there picks up the quick implementation's issue. Prints the new path,
    alone, on stdout, and gives it. A bad command line or a failed fetch
    dies before any worktree exists; a failed marker write takes the fresh
    worktree back out."""
    if not argv or not argv[0]:
        die(ADD_USAGE)
    slug, rest, issue = argv[0], list(argv[1:]), ""
    while rest:
        if rest[0] != "--issue":
            die("unknown side-checkout add flag: %s (want --issue)" % rest[0])
        issue = rest[1] if len(rest) > 1 else ""
        if not issue:
            die(ADD_USAGE)
        if not plain_number(issue):
            die("--issue wants a plain issue number, got: " + issue)
        rest = rest[2:]
    slug = normalize_slug(slug)
    main_root = main_checkout_or_die(git)
    # The base is read before the sweep, so the sweep shares its one ask of
    # GitHub for the default branch.
    gh, default = _default_once(gh, git, env)
    base = base_in_effect(git, default)
    with redirect_stdout(sys.stderr):
        swept = subshell(lambda: side_checkout_prune([], gh, git, env, root, here, clock))
    if swept != 0:
        warn("the finished sweep failed - carrying on with add")
    with _in_main_checkout(main_root):
        path = "%s/%s" % (side_checkouts_dir(main_root), slug)
        if os.path.exists(path):
            die("side checkout %s already exists" % path)
        exclude_orch_dirs(git)
        if not git.fetch_branch_at(main_root, base):
            die("could not fetch base branch %s from origin - no side checkout was made" % base)
        refused = git.worktree_add_detached_at(main_root, path, "refs/remotes/origin/" + base)
        if refused is not None:
            stderr_write(refused.stderr)
            die("could not add side checkout " + path)
        gitdir = git.absolute_git_dir_at(path)
        if gitdir is None or not _marker_written(gitdir, issue):
            # A freshly added worktree holds nothing of anyone's, so no force
            # is needed.
            git.worktree_remove(main_root, path)
            die("could not write the side-checkout marker - removed %s again" % path)
    stdout_write(path + "\n")
    return path


def _marker_written(gitdir: str, issue: str) -> bool:
    """Whether the ownership marker was written into the git folder
    <gitdir>: empty, or <issue> on a line of its own."""
    try:
        with open(os.path.join(gitdir, SIDE_CHECKOUT_MARKER), "w") as marker:
            marker.write(issue + "\n" if issue else "")
    except OSError:
        return False
    return True
