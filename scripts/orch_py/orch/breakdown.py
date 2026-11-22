"""The breakdown concept's module: the breakdown noun (ADR-0067), a spec's
approved ticket breakdown kept as a save point so a spec phase that died
mid-publish finishes it on restart, and where that save point lives, which the
ticket module's retire reaches too.

The save point is .orchestrator/breakdown/<parent>/: draft.md, the approved
draft; numbers, one `<k> <number> created|linked` line per ticket, the last
line for <k> winning; and published, the marker written last - the layout
bash's breakdown module writes, so either reads what the other left.

So far the noun answers `state` and refuses misuse of both verbs; publish's
work is still the bash noun's, which orch.sh runs until the cutover. Every
verb keeps the bash module's arguments, usage lines, stdout, exit codes and
`orch:` messages: publish dies with 1, state with 2, an unknown op with 1.
"""
from __future__ import annotations

import os
from typing import List, Mapping, Optional

from orch.common import ORCH_DIR_NAME, die, plain_number
from orch.git import Git
from orch.root import checkout_root
from orch.ticket import ticket_exists

# The verbs, in the unknown-op message's order. docs_lint.sh reads this line
# as the verbs the noun dispatches, so it stays one `OPS = "<verb>|..."` line.
OPS = "publish|state"

PARENT_NOT_PLAIN = "parent must be a plain issue number, got: "


def breakdown_dir(root: str, n: str) -> str:
    """Spec issue <n>'s breakdown save point under the checkout at <root>."""
    return "%s/%s/breakdown/%s" % (root, ORCH_DIR_NAME, n)


def publish(args: List[str]) -> int:
    """`breakdown publish <parent> <draft-file>`'s argument checks, exit 1."""
    if len(args) != 2:
        die("usage: orch.sh breakdown publish <parent> <draft-file>")
    if not plain_number(args[0]):
        die(PARENT_NOT_PLAIN + args[0])
    die("breakdown publish is not converted to Python yet - run it through orch.sh")


def state(args: List[str], gh_of, root: str) -> int:
    """`breakdown state <parent>`: complete, partial or none. The published
    marker answers first, then a saved draft, reading nothing from GitHub;
    with neither, `ticket exists` decides. Misuse, a failed read and a Repo
    that does not resolve exit 2, never read as none."""
    if len(args) != 1:
        die("usage: orch.sh breakdown state <parent>", 2)
    parent = args[0]
    if not plain_number(parent):
        die(PARENT_NOT_PLAIN + parent, 2)
    directory = breakdown_dir(root, parent)
    if os.path.isfile(directory + "/published"):
        print("complete")
    elif os.path.isfile(directory + "/draft.md"):
        print("partial")
    else:
        print("none" if ticket_exists(gh_of(), parent) is None else "complete")
    return 0


def run(
    argv: List[str],
    gh=None,
    git=None,
    env: Optional[Mapping[str, str]] = None,
    pin=None,
) -> int:
    """`orch.sh breakdown <op> ...`: the real adapters and the process's
    environment unless a test hands in others. Outside a checkout it dies
    first, as orch.sh does, whatever the op."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    root = checkout_root(git, env)
    op = argv[0] if argv else ""
    if op not in OPS.split("|"):
        die("unknown breakdown op: %s (want %s)" % (op or "<none>", OPS))

    # The gh adapter, made at the first GitHub call: a state the save point
    # answers makes none.
    def gh_of():
        if gh is not None:
            return gh
        from orch.gh import adapter

        return adapter(env, pin=pin)

    if op == "publish":
        return publish(argv[1:])
    return state(argv[1:], gh_of, root)
