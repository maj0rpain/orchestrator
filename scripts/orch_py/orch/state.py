"""`orch.sh state get [<key>]` and `orch.sh state set <key> <value>`, the
state noun, ported from the deleted bash cmd_state: a read of one key of the
flow's state.json, or the whole file as it stands, and a write of one key
skill prose sets. A module of its own rather than a part of orch.flow_state,
which the other nouns import for its readers and writers: this one is only
the command surface over them. The key table, its owner column included, is
orch.flow_state's STATE_KEYS.

The one departure from bash: on a state.json that is not exactly one JSON
object, `state get <key>` and `state set` die with STATE_UNREADABLE_MSG, as
the converted nouns' entry read does, where bash passed jq's own parse error
and status through.
"""
from __future__ import annotations

import os
import time
from typing import Callable, List, Mapping, Optional, Sequence

from orch.common import die, stdout_write
from orch.flow_state import (STATE_KEYS, STATE_UNREADABLE_MSG, flow_state_file, flow_state_get,
                             require_state_exists, require_state_readable, state_write_many)
from orch.git import Git
from orch.root import checkout_root

OPS = "get|set"

# Each key's owner: - for a key state set may write; otherwise the reason it
# refuses, printed as "state set refuses <key>: <owner>".
OWNERS = {key: owner for key, _, _, owner in STATE_KEYS}
# The keys state set may write, in table order.
SETTABLE = [key for key, owner in OWNERS.items() if owner == "-"]


def get(argv: Sequence[str], state_file: str, env: Mapping[str, str]) -> None:
    """`orch.sh state get [<key>]`: <key>'s value (flow_state_get), or with
    no key the whole file as it stands, read or not. Dies with no flow, for
    a key outside the table "unknown state key: <key>", and with
    STATE_UNREADABLE_MSG when the file cannot be read. Any further argument
    is ignored, as bash ignored it."""
    require_state_exists(state_file, env)
    if not argv:
        with open(state_file, "rb") as f:
            stdout_write(f.read().decode("utf-8", "surrogateescape"))
        return
    try:
        value = flow_state_get(state_file, argv[0])
    except ValueError:
        die("unknown state key: %s" % argv[0])
    if value is None:
        die(STATE_UNREADABLE_MSG)
    stdout_write(value + "\n")


def set_key(argv: Sequence[str], state_file: str, env: Mapping[str, str],
            clock: Callable[[], float]) -> None:
    """`orch.sh state set <key> <value>`: <value> stored under <key>,
    coerced as flow_state_json coerces it, updated stamped, printing
    nothing. Only the keys skill prose sets are public: every other key has a
    command that owns it, and that command's guard is the point - a phase
    set here would skip the handoff phase advance validates. Dies, in bash's
    order: with no flow, the usage line, an unknown key naming the settable
    ones, an owned key naming its owner, then STATE_UNREADABLE_MSG for a file
    that cannot be read and "could not record <key> in <state> - the flow is
    unchanged" for a failed write, each leaving the file as it was."""
    require_state_exists(state_file, env)
    if len(argv) != 2:
        die("usage: orch.sh state set <key> <value>")
    key, value = argv
    owner = OWNERS.get(key)
    if owner is None:
        die("state set refuses %s: settable keys are %s" % (key, ", ".join(SETTABLE)))
    if owner != "-":
        die("state set refuses %s: %s" % (key, owner))
    require_state_readable(state_file)
    state_write_many(state_file, [(key, value)], clock)


def run(argv: List[str], git=None, env: Optional[Mapping[str, str]] = None,
        clock: Callable[[], float] = time.time) -> int:
    """`orch.sh state <op>`: the real git adapter, the process's environment
    and the system clock unless a test hands in others. Outside a checkout
    it dies first, as orch.sh does, whatever the op; a missing or empty op
    is get, as bash's ${1:-get} read it."""
    env = os.environ if env is None else env
    git = Git() if git is None else git
    state_file = flow_state_file(checkout_root(git, env))
    op, rest = (argv[0] or "get", argv[1:]) if argv else ("get", [])
    if op == "get":
        get(rest, state_file, env)
    elif op == "set":
        set_key(rest, state_file, env, clock)
    else:
        die("unknown state op: %s (want %s)" % (op, OPS))
    return 0
