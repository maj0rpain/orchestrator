"""orch.sh's init noun (ADR-0067), which starts a flow.

run(argv) takes the arguments after `init`, as orch.sh hands them on, and
returns the exit code; every error dies through orch.common.die, exit 1, but
the busy-checkout refusal's exit 3. It keeps the bash noun's usage line,
stdout, exit codes and `orch:` messages.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional, Tuple

from orch.base import base_setting, default_branch
from orch.checkout import refuse_busy_checkout
from orch.common import (ORCH_DIR_NAME, die, exclude_orch_dirs, normalize_slug, plain_number,
                         stderr_write, stdout_write)
from orch.flow_state import flow_state_create, flow_state_file, flow_state_seed, phase_write
from orch.gh import adapter_of, label_listed, open_issue_read
from orch.git import Git
from orch.handoff import handoff_dir
from orch.planning_allowlist import (RECORD_REDIRECT, allowlist_text, dirty_outside_allowlist,
                                     record)
from orch.repo import RepoPin
from orch.root import checkout_root
from orch.side_checkout import archive_flow, archive_root
from orch.triage_labels import TriageLabels
from orch.trust import warn_issue

USAGE = "usage: orch.sh init <slug> [--issue N]"


def parse_args(argv: List[str]) -> Tuple[str, str]:
    """(<slug>, <issue>) from `init <slug> [--issue N]`, the issue "" when
    none is given; dies with the usage line, or naming the flag or value it
    refuses. The slug is the first argument, whatever it is, as bash took
    it."""
    slug = argv[0] if argv else ""
    if not slug:
        die(USAGE)
    issue = ""
    rest = argv[1:]
    while rest:
        if rest[0] != "--issue":
            die("unknown init flag: %s (want --issue)" % rest[0])
        issue = rest[1] if len(rest) > 1 else ""
        if not issue:
            die(USAGE)
        if not plain_number(issue):
            die("--issue wants a plain issue number, got: %s" % issue)
        rest = rest[2:]
    return slug, issue


def fold_s(text: str, width: int) -> List[str]:
    """<text>, one line, broken as `fold -s -w <width>` breaks it: a line
    that would pass <width> characters breaks after its last space, or at
    <width> where it has none, the space kept on the line it ends."""
    lines = []
    line = ""
    for char in text:
        if len(line) + 1 > width:
            cut = line.rfind(" ") + 1
            if cut == 0:
                cut = len(line)
            lines.append(line[:cut])
            line = line[cut:]
        line += char
    return lines + [line]


def _indented(paths: List[str]) -> str:
    return "".join("       %s\n" % path for path in paths)


def require_clean_outside_allowlist(git) -> None:
    """The git-based backstop from ADR-0013: where no host hook arms the
    edit guard, planning can edit source unhindered, so flow start is where
    that gets caught, before any state exists. Judges the working tree the
    git adapter <git> runs in, so a flow started inside a worktree (ADR-0008)
    is judged by that worktree's changes. Dies listing the dirty paths, the
    planning records - which planning never edits in place - under their own
    heading with the redirect the edit guard gives."""
    dirty = dirty_outside_allowlist(git)
    if not dirty:
        return
    records = [path for path in dirty if record(path)]
    outside = [path for path in dirty if not record(path)]
    outside_block = _indented(outside) + \
        "     Planning may only change: %s." % allowlist_text()
    # With only source paths dirty, the message is exactly as before the
    # planning records (#186) got their own block.
    if not records:
        die("the working tree has changes outside the planning allowlist:\n%s\n"
            "     Commit, stash, or discard these changes, then run init again." % outside_block)
    # The redirect is one long sentence pair shared with the guard; wrapped
    # here to the message's own indent and width.
    msg = ("the working tree has changes planning does not make.\n"
           "     Planning records changed (planning does not edit these in place):\n"
           + _indented(records)
           + "\n".join("     " + line.rstrip(" ") for line in fold_s(RECORD_REDIRECT, 75)))
    # Committing a record from planning is the option ADR-0022 rejects, so
    # records are only ever discarded or stashed once their wording has moved.
    if not outside:
        die(msg + "\n     Discard or stash these changes, then run init again.")
    die(msg + "\n     Changes outside the planning allowlist:\n" + outside_block
        + "\n     Discard or stash the planning records; commit, stash, or discard the other"
        "\n     changes, then run init again.")


def validate_adopted_issue(gh, root: str, issue: str) -> None:
    """`init --issue N`'s one-time gate, through the gh adapter <gh>: the
    issue must exist, be open, and carry the checkout at <root>'s local name
    for the ready-for-agent role - resolved through its triage labels, never
    the literal string, so a repo that renamed its labels still gets a
    correct check. Checked once, here, and never again: a maintainer's later
    triage housekeeping must not stop a flow already running against the
    issue (docs/adr/0005)."""
    label = TriageLabels(lambda: root).label("ready-for-agent")
    labels, _ = open_issue_read(
        gh, issue, "issue #%s is not open - adoption requires an open issue." % issue,
        hint="check it exists and gh is authenticated")
    if not label_listed(labels, label):
        die("issue #%s is missing the '%s' triage label - adoption requires it."
            % (issue, label))


def make_folders(*folders: str) -> None:
    """mkdir -p <folders>: each folder made with its parents, one already
    there no failure. A folder it cannot make prints mkdir's own message
    for it, the others still made, then exits 1."""
    failed = False
    for folder in folders:
        try:
            os.makedirs(folder, exist_ok=True)
        except OSError as err:
            stderr_write("mkdir: cannot create directory '%s': %s\n"
                         % (folder, os.strerror(err.errno) if err.errno else err))
            failed = True
    if failed:
        raise SystemExit(1)


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
    clock: Callable[[], float] = time.time,
) -> int:
    """`orch.sh init <slug> [--issue N]`: the real adapters, the process's
    environment and the real clock unless a test hands in others. Outside a
    checkout it dies first, as orch.sh does."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    slug, issue = parse_args(argv)
    slug = normalize_slug(slug)
    # A busy checkout - a flow mid-pipeline, or a branch the plugin made with
    # no PR yet, as a quick implementation still running here leaves -
    # refuses with exit 3. Dirty paths are not a busy signal here: they get
    # the planning-allowlist check's own exit-1 refusal after it, so a stray
    # edit is not taken into a side checkout. A done flow does not hold the
    # checkout: init archives it below and proceeds.
    refuse_busy_checkout(git, root, env, "flow", "branch")
    require_clean_outside_allowlist(git)
    pin = RepoPin(env, git) if pin is None else pin
    gh_of = adapter_of(gh, env, pin)
    # Adoption is validated before anything is written, and before a done
    # flow is archived, so a bad --issue leaves it untouched and re-runnable.
    if issue:
        gh = gh_of()
        validate_adopted_issue(gh, root, issue)
        warn_issue(gh, issue, env)
    # The whole seed is built before anything is written, so a build that
    # fails leaves the previous state untouched. Its base is the base branch
    # in effect now: the base setting, else the default branch.
    base = base_setting(git) or default_branch(gh_of(), git, pin).name
    try:
        seed = flow_state_seed(slug, issue, base, clock)
    except (KeyError, ValueError):
        die("could not build the state seed - nothing was written")
    # archive_flow, not the archive noun: in a side checkout the old flow
    # moves to the main checkout's archive, but the worktree stays - the new
    # flow lives here.
    state_file = flow_state_file(root)
    archive_note = ""
    if os.path.isfile(state_file):
        home = archive_root(git, root)
        if home is None:
            die("could not read the checkouts - nothing was archived or written")
        archive_note = archive_flow(git, root, home, root, clock)
    make_folders(handoff_dir(root), os.path.join(root, ORCH_DIR_NAME, "review"))
    exclude_orch_dirs(git)
    if not flow_state_create(state_file, seed):
        die("could not write %s/state.json" % ORCH_DIR_NAME)
    phase_write(state_file, "spec", clock)
    if archive_note:
        stdout_write(archive_note + "\n")
    stdout_write(slug + "\n")
    return 0
