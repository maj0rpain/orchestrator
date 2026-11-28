# shellcheck shell=bash
# state.sh - the bash state helpers (state_get, state_write_string,
# require_state_exists) and require_state_read, a command's entry read, which
# no bash noun calls now: the state noun itself is Python (orch.state), its
# bash cmd_state gone.
# The readers: state_get and state_get_many, the unguarded own-checkout
# readers, and state_get_many_in, the guarded shared one, which costs one jq.
# A command's entry read is require_state_read: the two refusals and
# every key it needs in one jq.
# Its tests: scripts/test/orch/state.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The state format - STATE_KEYS, state_rows, now and the flow_state_
# functions - lives in scripts/flow-state.sh, the Flow state module orch.sh
# sources before this file. The functions below wrap it with their $STATE-bound
# names and orch.sh's die messages.

# The own-checkout reader, unguarded: every read of this checkout's state.json
# goes through here, so what an absent key means is decided in the STATE_KEYS
# table rather than at each call site. A key outside the table dies: a
# misspelt read would otherwise look exactly like an unset one. It calls the
# Flow state module's reader directly and does not check the file parses, so
# on an unreadable state.json jq's own parse error and status come through;
# commands that must refuse such a file read through require_state_read.
state_get() {
  state_read "$STATE" "$1"
}

# state_read <file> <key>: the unguarded read state_get makes - the Flow
# state module's reader. The key is looked up only on a failed read, to pick the
# message: a key outside the table dies, and any other failure returns the
# read's own status (jq's), never a lookup's.
state_read() {
  local rc
  flow_state_get "$1" "$2" && return
  rc=$?
  flow_state_key_field "$2" default >/dev/null || die "unknown state key: $2"
  return "$rc"
}

# state_get_many <var>=<key>...: the own-checkout reader of several keys in one
# jq, unguarded as state_get is: it assigns each <key>'s value to the caller's
# <var> (flow_state_get_many). It declares no unprefixed local, so a caller may
# name an out-variable anything but __sgm_rc or one of the reader's
# __fsgm_ locals, which take the value instead of the caller. A failed read
# rechecks the arguments, which die "unknown state key: <key>" or "malformed
# state read: <arg>"; any other status is a failed read and is returned, jq's
# text through.
state_get_many() {
  local __sgm_rc
  flow_state_get_many "$STATE" "$@" && return
  __sgm_rc=$?
  state_many_recheck "$@"
  return "$__sgm_rc"
}

# state_get_many_in <file> <var>=<key>...: state_get_many on the state file
# <file> of any checkout, guarded: a file that cannot be read returns 2 and
# prints nothing, so a caller reading another checkout's state can skip it.
# A failed read rechecks the arguments as state_get_many does; any other
# status is a failed read, 2.
state_get_many_in() {
  flow_state_get_many "$@" 2>/dev/null && return
  shift
  state_many_recheck "$@"
  return 2
}

# state_many_recheck <var>=<key>...: after a failed many-key read, dies with
# the message for the argument that was at fault, returns state_rows's own
# non-zero status when the rows cannot be read, and returns 0 when no
# argument was at fault. It runs only after a failure, when nothing was
# assigned, so its locals cannot shadow a caller's out-variable.
state_many_recheck() {
  local __smr_arg __smr_rows __smr_rc __smr_var __smr_key __smr_def
  __smr_rows="$(state_rows)" || return
  for __smr_arg in "$@"; do
    flow_state_resolve_many_arg "$__smr_arg" "$__smr_rows" __smr_ && continue
    __smr_rc=$?
    [ "$__smr_rc" = 2 ] && die "malformed state read: $__smr_arg"
    die "unknown state key: ${__smr_arg#*=}"
  done
}

# Stores value $2 under key $1 as a JSON string, always, over
# flow_state_write_string on $STATE. A failed write dies, whatever context the
# caller runs in: flow_state_write_string returns its status, and a caller in a
# condition would suspend set -e.
state_write_string() {
  flow_state_write_string "$STATE" "$1" "$2" ||
    die "could not record $1 in $STATE - the flow is unchanged"
}

# The one spelling of the refusal an unparseable state.json earns.
STATE_UNREADABLE_MSG="state.json cannot be read - run orch.sh doctor --flow"

# require_state_exists [die2]: dies unless an active flow's state file exists,
# for require_state_read, which checks parsing after it.
require_state_exists() {
  [ -f "$STATE" ] || "${1:-die}" "no active flow ($ORCH_DIR_NAME/state.json not found). Run $(flow_cmd start) first."
}

# require_state_read [die|die2] <var>=<key>...: a command's entry read. Dies
# "no active flow" on a missing state file and with STATE_UNREADABLE_MSG on one
# that is not exactly one JSON object, through the dier given (die, or die2
# for a command that reserves exit 1 for a meaningful "no"); then assigns each
# <key>'s value, with its table default, to the caller's <var>, all in one jq
# (flow_state_get_many). Call it as a bare statement: it declares no unprefixed
# local, so a caller may name an out-variable anything but a __rsr_ or
# __fsgm_ name. A key outside the table dies "unknown state key", and a
# malformed <var>=<key> "malformed state read", as state_get_many does.
require_state_read() {
  local __rsr_die=die
  case "${1:-}" in die | die2) __rsr_die="$1"; shift ;; esac
  require_state_exists "$__rsr_die"
  flow_state_get_many "$STATE" "$@" 2>/dev/null && return
  state_many_recheck "$@"
  "$__rsr_die" "$STATE_UNREADABLE_MSG"
}

# flow_base_fallback_into <var> <raw>: sets <var> to the base read from state,
# or the default branch when <raw> is empty - a flow started before base was
# recorded - in the caller's shell. Never fails.
flow_base_fallback_into() {
  if [ -n "$2" ]; then printf -v "$1" '%s' "$2"; else default_branch_into "$1"; fi
}
