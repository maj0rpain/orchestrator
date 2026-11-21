"""The review-pass noun: a review pass's start, for a quick implementation's
step 6 and a standalone review pass alike. run() is the noun's entry point.

begin's guard and numbered report prefix each have one right answer, so they
live here rather than in skill prose. It needs no flow state and may run
where init never did, so it excludes the orchestrator directories itself. It
reads state.json only when one exists (the Flow state reader,
orch/flow_state.py), and never writes it: a branch or issue an active flow
holds belongs to that flow (ADR-0029). It never wipes - each pass takes the
next number, so a second pass on a branch never overwrites the first. Its
checks run in the bash verb's order, every one before any write: the usage,
the plain number, the current branch, the recorded base, the flow-holding
guard; then the exclude lines, the pass directory and the prefix.

known-items is still served by the bash review-pass module.
"""
from __future__ import annotations

import os
from typing import List, Mapping, Optional

from orch.base import recorded_base_into
from orch.checkout import current_branch_or_die
from orch.common import ORCH_DIR_NAME, die, exclude_orch_dirs, plain_number
from orch.flow_state import (
    STATE_UNREADABLE_MSG,
    StateUnreadable,
    flow_holding_phase,
    flow_state_file,
)
from orch.gh import adapter
from orch.git import Git
from orch.host import flow_cmd
from orch.repo import RepoPin
from orch.root import checkout_root

# The verbs. docs_lint.sh reads a converted noun's verbs from this line, so it
# stays one `OPS = "<verb>|..."` line.
OPS = "begin|known-items"

PREFIX = "iteration-"


def next_iteration(directory: str) -> int:
    """One past the largest number of an iteration-<digits>-<rest> name in
    <directory>, read as decimal; 1 when there is none. Any other name is
    skipped, as bash's iteration-[0-9]*-* glob and digits check skip it."""
    largest = 0
    for name in os.listdir(directory):
        rest = name[len(PREFIX):]
        if not name.startswith(PREFIX) or not plain_number(rest[:1]) or "-" not in rest[1:]:
            continue
        number = rest.split("-", 1)[0]
        if plain_number(number) and os.path.exists(os.path.join(directory, name)):
            largest = max(largest, int(number, 10))
    return largest + 1


def begin(argv: List[str], gh, git, pin, env: Mapping[str, str], root: str) -> int:
    """`review-pass begin <issue>`: prints the next numbered report prefix,
    <root>/.orchestrator/review-pass/<branch>/iteration-NN, making the
    directory, unless the current branch is its own base or an active flow
    holds the branch or <issue>."""
    if len(argv) != 1:
        die("usage: orch.sh review-pass begin <issue>")
    issue = argv[0]
    if not plain_number(issue):
        die("issue must be a plain issue number, got: %s" % issue)
    branch = current_branch_or_die(git)
    if branch == recorded_base_into(gh, git, pin, branch):
        die("%s is the base branch - a review pass reviews a branch's change against it;"
            " check out the change's branch" % branch)
    try:
        hold = flow_holding_phase(flow_state_file(root), branch, issue)
    except StateUnreadable:
        die(STATE_UNREADABLE_MSG)
    if hold is not None:
        if hold.phase in ("implement", "review"):
            die("the active flow holds issue #%s at phase %s - this change belongs to that"
                " flow's review loop; run %s" % (hold.issue, hold.phase, flow_cmd(env, "next")))
        if hold.phase == "spec":
            die("the active flow holds issue #%s at phase spec - its change has not been"
                " built yet; run %s" % (hold.issue, flow_cmd(env, "next")))
        die("the active flow holds issue #%s at phase '%s', which is not a flow phase -"
            " refusing to review it; run orch.sh doctor --flow" % (hold.issue, hold.phase))
    exclude_orch_dirs(git)
    directory = os.path.join(root, ORCH_DIR_NAME, "review-pass", branch)
    try:
        os.makedirs(directory, exist_ok=True)
    except OSError:
        die("cannot make the review pass directory %s" % directory)
    print("%s/%s%02d" % (directory, PREFIX, next_iteration(directory)))
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
) -> int:
    """`orch.sh review-pass <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown review-pass op: %s (want %s)" % (op or "<none>", OPS))
    if op == "known-items":
        raise NotImplementedError("review-pass known-items is still served by bash")
    pin = RepoPin(env, git) if pin is None else pin
    gh = adapter(env, pin=pin) if gh is None else gh
    return begin(argv[1:], gh, git, pin, env, root)
