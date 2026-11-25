"""The Flow state module's Python side: a checkout's flow state,
.orchestrator/state.json, read by the rules of the bash Flow state module's
multi-key reader (scripts/flow-state.sh's flow_state_get_many), which stays
the state format's owner. Python init writes a new flow's seed - built from
the key table's seed column, created, and stamped with its spec phase - and
bash every later change. The golden state.json files of tests/flow_state/ pin
the two sides to each other (ADR-0067): those under read/ and refused/ the
readers, and those under seed/ the seed Python writes to the bytes bash init
wrote.

Beside the reader sit the pieces of bash's state module that only read
state.json: flow_holding_phase, the guard a branch or issue an active flow
holds answers to (ADR-0029), STATE_UNREADABLE_MSG, the refusal an unreadable
state.json earns, require_state_read, a command's entry read of the keys it
needs, and require_issue, the entry read of the flow's issue a command that
needs one makes.
"""
from __future__ import annotations

import json
import os
import time
from typing import Any, Callable, Dict, Mapping, NamedTuple, Optional, Sequence

from orch.common import ORCH_DIR_NAME, die, file_write_atomic
from orch.host import flow_cmd

# The key, default and seed columns of the bash state key table (STATE_KEYS
# in scripts/flow-state.sh), in table order. default: what a key reads as
# when it is null or missing. seed: the JSON literal Python init writes, or
# arg where init supplies the value at run time (flow_state_seed's _SEED_ARGS);
# bash writes every later change. The owner column serves `state set`, which
# stays in bash.
STATE_KEYS = (
    ("slug", "", "arg"),
    ("phase", "", "null"),
    ("issue", "", "arg"),
    ("base", "", "arg"),
    ("branch", "", "null"),
    ("pr", "", "null"),
    ("base_sha", "", "null"),
    ("budget", "", "null"),
    ("iteration", "0", "0"),
    ("flake_rerun_used", "false", "false"),
    ("redo_count", "0", "0"),
    ("host_fallbacks", "false", "true"),
    ("created", "", "arg"),
    ("updated", "", "arg"),
)
_DEFAULTS = {key: default for key, default, _ in STATE_KEYS}

# The one spelling of the refusal an unparseable state.json earns.
STATE_UNREADABLE_MSG = "state.json cannot be read - run orch.sh doctor --flow"
# The one spelling of the issue's required-field message.
NO_ISSUE_MSG = "no issue recorded in state - the spec phase must publish one first"


def flow_state_file(root: str) -> str:
    """The state file of the checkout at <root>, one trailing / stripped
    from <root> as bash's flow_state_file strips it."""
    root = root[:-1] if root.endswith("/") else root
    return "%s/%s/state.json" % (root, ORCH_DIR_NAME)


def now(clock: Callable[[], float] = time.time) -> str:
    """The time <clock> reads as the created and updated stamp: ISO-8601,
    UTC, to the second, as bash's now prints it."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(clock()))


def _state_text(state: Mapping[str, Any]) -> str:
    """<state> as jq prints a state file: two-space indented, non-ASCII
    kept, and a trailing newline."""
    return json.dumps(state, indent=2, ensure_ascii=False) + "\n"


# The run-time value of each arg row of the seed column, given the seed's
# slug, issue, base and stamp: an empty issue seeds null, any other a number.
_SEED_ARGS = {
    "slug": lambda slug, issue, base, stamp: slug,
    "issue": lambda slug, issue, base, stamp: int(issue) if issue else None,
    "base": lambda slug, issue, base, stamp: base,
    "created": lambda slug, issue, base, stamp: stamp,
    "updated": lambda slug, issue, base, stamp: stamp,
}


def flow_state_seed(slug: str, issue: str, base: str,
                    clock: Callable[[], float] = time.time) -> Dict[str, Any]:
    """The state a new flow is seeded with, bash flow_state_seed: every key
    of the table in table order, a constant row its seed literal and an arg
    row its _SEED_ARGS value, created and updated stamped with the time
    <clock> reads. An arg row with no _SEED_ARGS value raises KeyError: a
    programming error, never a seed of null."""
    stamp = now(clock)
    return {key: _SEED_ARGS[key](slug, issue, base, stamp) if seed == "arg" else json.loads(seed)
            for key, _, seed in STATE_KEYS}


def flow_state_create(path: str, state: Mapping[str, Any]) -> bool:
    """Writes <state> to <path> as jq prints it, creating the file or
    replacing it whole, bash flow_state_create: through a temporary file
    beside it, so a failed write - its directory gone included - leaves
    <path> untouched and no temporary file. Whether it succeeded."""
    return file_write_atomic(path, _state_text(state), make_directory=False)


def phase_write(path: str, phase: str, clock: Callable[[], float] = time.time) -> None:
    """Records <phase> in the state file at <path>, bash phase_write: updated
    stamped with the time <clock> reads, then phase set, both in place in the
    file's key order, the file rewritten as flow_state_create writes it.
    Dies unless <phase> is a flow phase, and, leaving the file untouched,
    when it is absent, is not exactly one JSON object, or cannot be
    written."""
    # Imported here: the handoff module reads this one at its own import.
    from orch.handoff import PHASE_TABLE
    phases = " ".join(row[0] for row in PHASE_TABLE)
    if phase not in phases.split():
        die("not a flow phase: %s (want one of: %s)" % (phase, phases))
    try:
        with open(path, "rb") as f:
            state = json.loads(f.read().decode("utf-8", "replace"), parse_constant=_refuse_constant)
    except (OSError, ValueError):
        state = None
    if not isinstance(state, dict) or not flow_state_create(
            path, dict(state, updated=now(clock), phase=phase)):
        die("could not record phase in %s - the flow is unchanged" % path)


def _refuse_constant(name: str) -> Any:
    raise ValueError("not JSON: " + name)


def _tostring(value: Any) -> str:
    """<value> as jq's tostring prints it: a string as itself, true and
    false as words, a number or any other value as its compact JSON."""
    if isinstance(value, str):
        return value
    if isinstance(value, bool):
        return "true" if value else "false"
    return json.dumps(value, separators=(",", ":"), ensure_ascii=False)


def flow_state_get_many(path: str, keys: Sequence[str]) -> Optional[Dict[str, str]]:
    """Every one of <keys> in the state file at <path>, in one read: a dict
    of each key's value as jq's tostring prints it, a NUL inside it dropped,
    or the key's table default when it is null or missing - never for a
    stored false or 0. None for a failed read, which assigns nothing: no
    file, or one that is not exactly one JSON object (null, an array,
    truncated JSON, trailing text or a second value included). A key outside
    the table raises ValueError, before any read: a programming error, never
    a failed read. With no keys nothing is read."""
    unknown = [key for key in keys if key not in _DEFAULTS]
    if unknown:
        raise ValueError("not a flow state key: %s" % ", ".join(unknown))
    if not keys:
        return {}
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8", "replace")
        state = json.loads(text, parse_constant=_refuse_constant)
    except (OSError, ValueError):
        return None
    if not isinstance(state, dict):
        return None
    values = {}
    for key in keys:
        value = state.get(key)
        values[key] = (_DEFAULTS[key] if value is None else _tostring(value)).replace("\0", "")
    return values


class Hold(NamedTuple):
    """An active flow's hold on a branch or issue: its phase, and the issue
    it holds, both from the one read that found the hold."""

    phase: str
    issue: str


class StateUnreadable(Exception):
    """state.json exists but cannot be read: a guard reading it fails
    closed."""


def flow_holding_phase(state_file: str, branch: str, issue: str) -> Optional[Hold]:
    """The Hold of the active flow (phase not done) recorded in <state_file>
    when it holds <branch>, or <issue> where one is given; None when there is
    no state file or no active flow holds them. Raises StateUnreadable when
    the file exists and cannot be read. Reads it only when it exists, in one
    read."""
    if not os.path.isfile(state_file):
        return None
    state = flow_state_get_many(state_file, ("phase", "branch", "issue"))
    if state is None:
        raise StateUnreadable(state_file)
    if state["phase"] == "done":
        return None
    if state["branch"] != branch and (not issue or state["issue"] != issue):
        return None
    return Hold(state["phase"], state["issue"])


def require_state_read(state_file: str, env: Mapping[str, str], keys: Sequence[str],
                       code: int) -> Dict[str, str]:
    """A command's entry read, bash require_state_read: every one of <keys>
    in <state_file>, in one read (flow_state_get_many). Dies, exit <code> - 2
    for a command that reserves exit 1 for a meaningful "no" - when there is
    no state file, naming the host's start command from <env>, and with
    STATE_UNREADABLE_MSG when it cannot be read."""
    if not os.path.isfile(state_file):
        die("no active flow (%s/state.json not found). Run %s first."
            % (ORCH_DIR_NAME, flow_cmd(env, "start")), code)
    state = flow_state_get_many(state_file, keys)
    if state is None:
        die(STATE_UNREADABLE_MSG, code)
    return state


def require_issue(state_file: str, env: Mapping[str, str],
                  keys: Sequence[str] = ()) -> Dict[str, str]:
    """The state read of <state_file>, its recorded issue and any further
    <keys> a caller reads with it, in one read; dies, in bash
    require_issue's order, when there is no state file (naming the host's
    start command from <env>), when it cannot be read, and when no issue is
    recorded."""
    state = require_state_read(state_file, env, ("issue",) + tuple(keys), 1)
    if not state["issue"]:
        die(NO_ISSUE_MSG)
    return state
