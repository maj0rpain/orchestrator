"""The Flow state module's Python side: a checkout's flow state,
.orchestrator/state.json, read by the rules of the bash Flow state module's
readers (scripts/flow-state.sh's flow_state_get_many, and flow_state_get for
the one key the state noun reads), which stays the state format's owner.
Python init writes a new flow's seed - built from the key table's seed
column, created, and stamped with its spec phase - the multi-key writer
(state_write_many, and state_write_many_try for a caller that words its own
failure) sets several keys in one write as bash's state_write_many did (its
bash copy gone with the bash branch noun), each value coerced as bash's
flow_state_json coerces it unless its pair is marked a string, the Python
phase writers (phase_write and phase_write_try) record a phase, with any
further keys in the same write, and the state noun's `state set`
(orch.state) writes one settable key: no bash command writes the file.
The golden state.json files of tests/flow_state/ pin the two sides to each
other (ADR-0067): those under read/ and refused/ the readers, and those
under seed/ the seed Python writes to the bytes bash init wrote.

Beside the reader sit the pieces of bash's state module that only read
state.json: flow_holding_phase, the guard a branch or issue an active flow
holds answers to (ADR-0029), STATE_UNREADABLE_MSG, the refusal an unreadable
state.json earns, require_state_exists, the refusal when there is no flow,
require_state, the refusal of no flow or an unreadable one (its bash copy
gone with the bash review noun, its one bash caller),
require_state_readable, the refusal of a state file that exists but cannot
be read, which handoff validate makes (its bash copy gone with the bash
handoff noun), require_state_read, a command's entry read of the keys it
needs, require_value, the refusal of a required field left empty (its bash
copy gone with the bash branch noun), and
require_issue, the entry read of the flow's issue a command that needs one
makes (its bash copy gone with the bash handoff noun); then what the base reads as when a flow never recorded it,
flow_base_fallback_into, whose bash copy stays for the bash nouns that read
it. The review budget's fallback is the review noun's (orch.review), its bash
copy gone with its last bash reader.
"""
from __future__ import annotations

import json
import os
import time
from typing import (Any, Callable, Dict, List, Mapping, NamedTuple, Optional, Sequence, Tuple,
                    Union)

from orch.base import default_branch
from orch.common import ORCH_DIR_NAME, UTC_STAMP_FORMAT, die, file_write_atomic, plain_number
from orch.host import flow_cmd

# Every flow state key, in table order, with its default, seed and owner. The
# key, default and seed columns are the bash state key table's (STATE_KEYS in
# scripts/flow-state.sh, where each key's row says why it is kept), which
# pytest's golden tests pin them to. default: what a key reads as when it is
# null or missing. seed: the JSON literal Python init writes, or arg where
# init supplies the value at run time (flow_state_seed's _SEED_ARGS). owner:
# - for a key `state set` may write; otherwise the reason it refuses, printed
# as "state set refuses <key>: <owner>". Only the keys skill prose sets are
# settable: every other key has a command that owns it, and that command's
# guard is the point - a phase set here would skip the handoff phase advance
# validates.
STATE_KEYS = (
    ("slug", "", "arg", "init seeds it"),
    ("phase", "", "null", "use phase advance (review ready and redo also move it)"),
    ("issue", "", "arg", "-"),
    ("base", "", "arg", "init seeds it"),
    ("branch", "", "null", "branch create records it"),
    ("pr", "", "null", "pr open records it"),
    ("base_sha", "", "null", "branch create records it"),
    ("budget", "", "null", "-"),
    ("iteration", "0", "0", "review begin counts it"),
    ("flake_rerun_used", "false", "false", "-"),
    ("redo_count", "0", "0", "a redo that retires a branch counts it"),
    ("host_fallbacks", "false", "true", "init seeds it"),
    ("created", "", "arg", "init seeds it"),
    ("updated", "", "arg", "every state change stamps it"),
)
_DEFAULTS = {key: default for key, default, _, _ in STATE_KEYS}

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
    return time.strftime(UTC_STAMP_FORMAT, time.gmtime(clock()))


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
    """The state a new flow is seeded with, ported from the deleted bash
    flow_state_seed: every key of the table in table order, a constant row
    its seed literal and an arg row its _SEED_ARGS value, created and updated
    stamped with the time <clock> reads. An arg row with no _SEED_ARGS value
    raises KeyError: a programming error, never a seed of null."""
    stamp = now(clock)
    return {key: _SEED_ARGS[key](slug, issue, base, stamp) if seed == "arg" else json.loads(seed)
            for key, _, seed, _ in STATE_KEYS}


def flow_state_create(path: str, state: Mapping[str, Any]) -> bool:
    """Writes <state> to <path> as jq prints it, creating the file or
    replacing it whole, ported from the deleted bash flow_state_create:
    through a temporary file beside it, so a failed write - its directory
    gone included - leaves <path> untouched and no temporary file. Whether
    it succeeded."""
    return file_write_atomic(path, _state_text(state), make_directory=False)


# A state write's pairs: each (key, value), value a string coerced as bash's
# flow_state_json coerces it, or (key, value, True) to store the value as a
# JSON string, as bash's --string before a pair marks it.
Pair = Union[Tuple[str, str], Tuple[str, str, bool]]

# The words flow_state_json stores as JSON literals.
_JSON_WORDS = {"null": None, "true": True, "false": False}


def flow_state_json(value: str) -> Any:
    """<value> as bash's flow_state_json stores it: null, true and false
    literally, an all-digit value as a number, anything else as a string."""
    if value in _JSON_WORDS:
        return _JSON_WORDS[value]
    return int(value) if plain_number(value) else value


def state_pairs_json(pairs: Sequence[Pair]) -> Dict[str, Any]:
    """<pairs> as one object, bash's flow_state_pairs_json: each value
    coerced by flow_state_json, or kept a string where its pair is marked;
    a key given twice keeps its first place and its last value."""
    obj: Dict[str, Any] = {}
    for key, value, *string in pairs:
        obj[key] = value if string and string[0] else flow_state_json(value)
    return obj


def state_write_many_try(path: str, pairs: Sequence[Pair],
                         clock: Callable[[], float] = time.time) -> bool:
    """Sets every one of <pairs> (state_pairs_json) in the state file at
    <path> in one write, bash's flow_state_write_many: updated stamped with
    the time <clock> reads, then the keys set, each in place in the file's
    key order and a new one last, the file rewritten as flow_state_create
    writes it. Whether it succeeded, printing nothing and leaving the file
    untouched when it is absent, is not exactly one JSON object, or cannot
    be written."""
    state = _state_object(path)
    if state is None:
        return False
    state = dict(state, updated=now(clock))
    state.update(state_pairs_json(pairs))
    return flow_state_create(path, state)


def state_write_many(path: str, pairs: Sequence[Pair],
                     clock: Callable[[], float] = time.time) -> None:
    """state_write_many_try, dying "could not record <keys> in <path> - the
    flow is unchanged" where the write fails, each key named once, in order,
    as bash's state_write_many died."""
    if not state_write_many_try(path, pairs, clock):
        die("could not record %s in %s - the flow is unchanged"
            % (", ".join(state_pairs_json(pairs)), path))


def _phase_pairs(phase: str, pairs: Sequence[Pair]) -> List[Pair]:
    """The pairs a phase write records: phase first, then <pairs>. Dies
    unless <phase> is a flow phase, as bash's require_flow_phase did."""
    # Imported here: the handoff module reads this one at its own import.
    from orch.handoff import PHASES
    if phase not in PHASES:
        die("not a flow phase: %s (want one of: %s)" % (phase, " ".join(PHASES)))
    return [("phase", phase, True)] + list(pairs)


def phase_write_try(path: str, phase: str, clock: Callable[[], float] = time.time,
                    pairs: Sequence[Pair] = ()) -> bool:
    """Records <phase> in the state file at <path>, ported from the deleted
    bash phase_write_try, with <pairs> written with it in one write, as bash
    phase_write <phase> <key> <value>... wrote them (state_write_many_try):
    the phase and the keys are recorded together or not at all. Dies unless
    <phase> is a flow phase, writing nothing; whether the write succeeded
    otherwise, printing nothing and leaving the file untouched when it is
    absent, is not exactly one JSON object, or cannot be written, for a
    caller that words its own failure."""
    return state_write_many_try(path, _phase_pairs(phase, pairs), clock)


def phase_write(path: str, phase: str, clock: Callable[[], float] = time.time,
                pairs: Sequence[Pair] = ()) -> None:
    """phase_write_try, dying "could not record phase in <path> - the flow
    is unchanged" where the write fails, phase followed by each key of
    <pairs> once, in order, as bash phase_write died (state_write_many)."""
    state_write_many(path, _phase_pairs(phase, pairs), clock)


def _refuse_constant(name: str) -> Any:
    raise ValueError("not JSON: " + name)


def _state_object(path: str) -> Optional[Dict[str, Any]]:
    """The JSON object the state file at <path> holds, read as bytes and
    decoded as UTF-8 with any bad byte replaced. None when there is no file
    or it cannot be read, or when it is not exactly one JSON object (null,
    an array, truncated JSON, trailing text, a second value or a NaN or
    Infinity included)."""
    try:
        with open(path, "rb") as f:
            state = json.loads(f.read().decode("utf-8", "replace"), parse_constant=_refuse_constant)
    except (OSError, ValueError):
        return None
    return state if isinstance(state, dict) else None


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
    state = _state_object(path)
    if state is None:
        return None
    values = {}
    for key in keys:
        value = state.get(key)
        values[key] = (_DEFAULTS[key] if value is None else _tostring(value)).replace("\0", "")
    return values


def flow_state_get(path: str, key: str) -> Optional[str]:
    """<key>'s value in the state file at <path>, as jq's tostring prints
    it, or its table default when it is null or missing - never for a stored
    false or 0 - as bash's flow_state_get reads one key: a NUL inside it is
    kept, as jq -r printed it. None for a failed read: no file, or one that
    is not exactly one JSON object. A key outside the table raises
    ValueError, before any read: a programming error, never a failed read."""
    if key not in _DEFAULTS:
        raise ValueError("not a flow state key: %s" % key)
    state = _state_object(path)
    if state is None:
        return None
    value = state.get(key)
    return _DEFAULTS[key] if value is None else _tostring(value)


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


def require_state_exists(state_file: str, env: Mapping[str, str], code: int = 1) -> None:
    """Dies, exit <code>, when there is no state file at <state_file>,
    naming the host's start command from <env> - bash require_state_exists,
    the one spelling of the no-flow refusal."""
    if not os.path.isfile(state_file):
        die("no active flow (%s/state.json not found). Run %s first."
            % (ORCH_DIR_NAME, flow_cmd(env, "start")), code)


def require_state(state_file: str, env: Mapping[str, str]) -> None:
    """Dies unless an active flow's state file exists (require_state_exists)
    and is exactly one JSON object, STATE_UNREADABLE_MSG its refusal - as
    bash's require_state was, its bash copy gone: for a command that needs a
    flow but reads no key."""
    require_state_exists(state_file, env)
    require_state_readable(state_file)


def require_state_readable(state_file: str) -> None:
    """Dies with STATE_UNREADABLE_MSG when a state file exists at
    <state_file> but is not exactly one JSON object, as bash's
    require_state_readable did. A missing file passes: the caller settles
    whether a flow must exist."""
    if os.path.isfile(state_file) and _state_object(state_file) is None:
        die(STATE_UNREADABLE_MSG)


def require_state_read(state_file: str, env: Mapping[str, str], keys: Sequence[str],
                       code: int) -> Dict[str, str]:
    """A command's entry read, bash require_state_read: every one of <keys>
    in <state_file>, in one read (flow_state_get_many). Dies, exit <code> - 2
    for a command that reserves exit 1 for a meaningful "no" - when there is
    no state file (require_state_exists), and with STATE_UNREADABLE_MSG when
    it cannot be read."""
    require_state_exists(state_file, env, code)
    state = flow_state_get_many(state_file, keys)
    if state is None:
        die(STATE_UNREADABLE_MSG, code)
    return state


# The one spelling of each required field's message, by key: bash
# state_required_msg.
REQUIRED_MSGS = {
    "issue": NO_ISSUE_MSG,
    "branch": "no branch recorded in state",
    "pr": "no PR recorded in state - the implement phase opens it",
    "base_sha": "no base SHA recorded in state - branch create records it",
}


def require_value(key: str, value: str, code: int = 1) -> None:
    """Dies, exit <code>, with <key>'s required-field message when <value>
    is empty, as bash's require_value did. It reads nothing. A key with no message
    exits 2, whatever the value: a programming error."""
    message = REQUIRED_MSGS.get(key)
    if message is None:
        die("no required-field message for state key: %s" % key, 2)
    if not value:
        die(message, code)


def recorded_pr(value: str) -> Union[int, str]:
    """The flow's recorded PR <value> as a gh adapter call takes it: a plain
    number, which pr open writes, as an int; anything else as it is, for gh
    to refuse with its own reason, as bash's adapter calls did."""
    return int(value) if plain_number(value) else value


def require_issue(state_file: str, env: Mapping[str, str],
                  keys: Sequence[str] = (), code: int = 1) -> Dict[str, str]:
    """The state read of <state_file>, its recorded issue and any further
    <keys> a caller reads with it, in one read; dies, exit <code> - 2 where
    bash's caller died through die2 - in the order bash's require_issue had,
    when there is no state file (naming the host's start command from <env>),
    when it cannot be read, and when no issue is recorded."""
    state = require_state_read(state_file, env, ("issue",) + tuple(keys), code)
    require_value("issue", state["issue"], code)
    return state


def flow_base_fallback_into(raw: str, gh_of: Callable[[], Any], git, pin) -> str:
    """The base read from state, <raw>, or the default branch where it is
    empty - a flow started before base was recorded - bash
    flow_base_fallback_into. The gh adapter is made by <gh_of> only when the
    default branch is looked up, through the git adapter <git> and the repo
    pin <pin>. Never fails."""
    if raw:
        return raw
    return default_branch(gh_of(), git, pin).name

