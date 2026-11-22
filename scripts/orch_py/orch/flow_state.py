"""The Flow state reader, read-only: a checkout's flow state,
.orchestrator/state.json, read by the rules of the bash Flow state module's
multi-key reader (scripts/flow-state.sh's flow_state_get_many), which stays
the state format's owner and its one writer. The golden state.json files of
tests/flow_state/ pin the two readers to each other (ADR-0067).

Beside the reader sit the pieces of bash's state module that only read
state.json: flow_holding_phase, the guard a branch or issue an active flow
holds answers to (ADR-0029), STATE_UNREADABLE_MSG, the refusal an unreadable
state.json earns, and require_issue, the entry read of the flow's issue a
command that needs one makes.
"""
from __future__ import annotations

import json
import os
from typing import Any, Dict, Mapping, NamedTuple, Optional, Sequence

from orch.common import ORCH_DIR_NAME, die
from orch.host import flow_cmd

# The key and default columns of the bash state key table (STATE_KEYS in
# scripts/flow-state.sh), in table order: what a key reads as when it is null
# or missing. The seed and owner columns serve the writers and `state set`,
# which stay in bash.
STATE_KEYS = (
    ("slug", ""),
    ("phase", ""),
    ("issue", ""),
    ("base", ""),
    ("branch", ""),
    ("pr", ""),
    ("base_sha", ""),
    ("budget", ""),
    ("iteration", "0"),
    ("flake_rerun_used", "false"),
    ("redo_count", "0"),
    ("host_fallbacks", "false"),
    ("created", ""),
    ("updated", ""),
)
_DEFAULTS = dict(STATE_KEYS)

# The one spelling of the refusal an unparseable state.json earns.
STATE_UNREADABLE_MSG = "state.json cannot be read - run orch.sh doctor --flow"
# The one spelling of the issue's required-field message.
NO_ISSUE_MSG = "no issue recorded in state - the spec phase must publish one first"


def flow_state_file(root: str) -> str:
    """The state file of the checkout at <root>, one trailing / stripped
    from <root> as bash's flow_state_file strips it."""
    root = root[:-1] if root.endswith("/") else root
    return "%s/%s/state.json" % (root, ORCH_DIR_NAME)


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


def require_issue(state_file: str, env: Mapping[str, str],
                  keys: Sequence[str] = ()) -> Dict[str, str]:
    """The state read of <state_file>, its recorded issue and any further
    <keys> a caller reads with it, in one read; dies, in bash
    require_issue's order, when there is no state file (naming the host's
    start command from <env>), when it cannot be read, and when no issue is
    recorded."""
    if not os.path.isfile(state_file):
        die("no active flow (%s/state.json not found). Run %s first."
            % (ORCH_DIR_NAME, flow_cmd(env, "start")))
    state = flow_state_get_many(state_file, ("issue",) + tuple(keys))
    if state is None:
        die(STATE_UNREADABLE_MSG)
    if not state["issue"]:
        die(NO_ISSUE_MSG)
    return state
