# shellcheck shell=bash
# state.sh - orch.sh's state command (state get and state set), with the state
# helpers every module calls (state_get, state_write, require_state_exists,
# require_state_read, require_value, require_field, require_issue).
# Two readers, each with a many-key form: state_get and
# state_get_many, the unguarded own-checkout readers, and state_get_in and
# state_get_many_in, the guarded shared ones; the guarded one-key reader costs
# one jq. A command's entry read is require_state_read: the two refusals and
# every key it needs in one jq. require_value checks a required field on a
# value the caller already holds; require_field reads one key and checks it.
# Its tests: scripts/test/orch/state.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The state format - STATE_KEYS, state_rows, now and the flow_state_
# functions - lives in scripts/flow-state.sh, the Flow state module orch.sh
# sources before this file. The functions below wrap it with their $STATE-bound
# names and orch.sh's die messages.

# Prints column $2 (default, seed or owner) of state key $1's row. An unknown
# key prints nothing and returns 1; the caller dies with its own message. An
# unknown column is a programming error, not caller input: it exits 2, never
# 1, so it is never read as an unknown key, and its caller exits with that
# status without a second message.
state_key_field() {
  local rc
  flow_state_key_field "$1" "$2" || {
    rc=$?
    [ "$rc" -ne 2 ] || die2 "state_key_field has no column: $2"
    return "$rc"
  }
}

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

# The shared reader, guarded: reads <key> from the state file <file> of any
# checkout, not only this one's, in one jq (flow_state_get_many with its one
# key). A failed read tells the causes apart, readability first: an unreadable
# <file> returns status 2 and prints nothing - no jq text, so a caller
# scanning other checkouts can skip it, a key outside the table included - and
# a key outside the table beside a readable file dies "unknown state key"; a
# failed read on a readable file returns 1 and prints nothing.
state_get_in() {
  local __sgi_v __sgi_rc
  flow_state_get_many "$1" __sgi_v="$2" 2>/dev/null && {
    printf '%s\n' "$__sgi_v"
    return 0
  }
  __sgi_rc=$?
  flow_state_readable "$1" || return 2
  state_many_recheck __sgi_v="$2"
  return "$__sgi_rc"
}

# state_read <file> <key>: the unguarded read both readers share - the Flow
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
# <file> of any checkout, guarded as state_get_in is: a file that cannot be
# read returns 2 and prints nothing, with no separate flow_state_readable run.
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

# The unrestricted writer behind every internal state change, over
# flow_state_write's coercion on $STATE. A failed write dies, whatever context
# the caller runs in: flow_state_write returns its status, and a caller in a
# condition would suspend set -e.
state_write() {
  flow_state_write "$STATE" "$1" "$2" ||
    die "could not record $1 in $STATE - the flow is unchanged"
}

# Stores value $2 under key $1 as a JSON string, always, over
# flow_state_write_string on $STATE.
# A failed write dies, as state_write's does.
state_write_string() {
  flow_state_write_string "$STATE" "$1" "$2" ||
    die "could not record $1 in $STATE - the flow is unchanged"
}

# state_write_many [--string] <key> <value> [[--string] <key> <value>]...: the
# many-key form of state_write: every key is set in one write, and --string
# before a pair stores its value as a JSON string. The pairs are built by
# flow_state_pairs_json and merged into $STATE by flow_state_merge. A
# malformed pair list dies "malformed state write: <args>". A failed write
# dies naming each key given once, in order (never a --string marker), as
# state_write's does, or naming no key when a value will not convert or the
# object's keys cannot be read. Both no-key failure paths share the one
# fall-through die.
state_write_many() {
  local obj keys
  if obj="$(flow_state_pairs_json "$@")"; then
    flow_state_merge "$STATE" "$obj" && return 0
    if keys="$(jq -r 'keys_unsorted | join(", ")' <<<"$obj")"; then
      die "could not record $keys in $STATE - the flow is unchanged"
    fi
  elif [ $? = 2 ]; then
    die "malformed state write: $*"
  fi
  die "could not record the state write in $STATE - the flow is unchanged"
}

# The one spelling of the refusal an unparseable state.json earns.
STATE_UNREADABLE_MSG="state.json cannot be read - run orch.sh doctor --flow"

# require_state_exists [die2]: dies unless an active flow's state file exists,
# for cmd_state, whose bare get still prints a state.json that does not parse,
# and for require_state_read, which checks parsing after it.
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

# The one spelling of each required field's message, by key: sets the caller's
# __rv_msg (require_value's local), with no subshell. Returns 1 for a key with
# no message.
state_required_msg() {
  case "$1" in
    issue) __rv_msg="no issue recorded in state - the spec phase must publish one first" ;;
    branch) __rv_msg="no branch recorded in state" ;;
    pr) __rv_msg="no PR recorded in state - the implement phase opens it" ;;
    base_sha) __rv_msg="no base SHA recorded in state - branch create records it" ;;
    *) return 1 ;;
  esac
}

# require_value <key> <value> [die2]: dies with <key>'s required-field message,
# through die or die2, when <value> is empty. It reads nothing. A key with no
# message exits 2, whatever the value.
require_value() {
  local __rv_msg
  state_required_msg "$1" || die2 "no required-field message for state key: $1"
  [ -n "$2" ] || "${3:-die}" "$__rv_msg"
}

# require_field <var> <key> [die2]: one guarded one-key read into the caller's
# <var>, then require_value: one jq and no subshell, refusing in order with no
# state file, an unreadable one, and an empty value. Call it as a bare
# statement on its own line - `local pr; require_field pr pr` - never folded
# into `$(...)`: the out-param is assigned in the caller's own shell, and `die`
# runs there too, so `set -e` stops it instead of the caller carrying on with an
# empty value. A caller-named out-param is a `printf -v`, not a nameref, which
# needs bash 4.3. The third argument, die2, dies through die2, for a command
# that reserves exit 1 for a meaningful "no".
require_field() {
  require_state_read "${3:-die}" "$1=$2"
  require_value "$2" "${!1}" "${3:-die}"
}

# The spec issue number, for the handoff ops that need it before touching
# GitHub. A second argument, die2, is passed on to
# require_field.
require_issue() { require_field "$1" issue "${2:-die}"; }

# flow_base_fallback_into <var> <raw>: sets <var> to the base read from state,
# or the default branch when <raw> is empty - a flow started before base was
# recorded - in the caller's shell. Never fails.
flow_base_fallback_into() {
  if [ -n "$2" ]; then printf -v "$1" '%s' "$2"; else default_branch_into "$1"; fi
}

# Succeeds when state set may write key $1: its owner column is -. The one
# place an owner is compared against -; an unknown key is not settable.
state_key_settable() {
  local owner rc
  owner="$(state_key_field "$1" owner)" || {
    rc=$?
    [ "$rc" -eq 1 ] || exit "$rc"
    return 1
  }
  [ "$owner" = - ]
}

# Prints every state key, one per line, in table order.
state_keys() {
  local k rest
  while IFS='|' read -r k rest; do
    printf '%s\n' "$k"
  done <<EOF
$(state_rows)
EOF
}

cmd_state() {
  local op="${1:-get}"
  shift || true
  case "$op" in
    get)
      require_state_exists
      if [ $# -gt 0 ]; then state_get "$1"; else cat "$STATE"; fi
      ;;
    set)
      require_state_exists
      [ $# -eq 2 ] || die "usage: orch.sh state set <key> <value>"
      # Only the keys skill prose sets are public. Every other key has a
      # command that owns it, and that command's guard is the point: a phase
      # set here would skip the handoff phase advance validates.
      local owner settable="" k rc
      owner="$(state_key_field "$1" owner)" || {
        rc=$?
        [ "$rc" -eq 1 ] || exit "$rc"
        for k in $(state_keys); do
          state_key_settable "$k" || continue
          settable="${settable:+$settable, }$k"
        done
        die "state set refuses $1: settable keys are $settable"
      }
      state_key_settable "$1" || die "state set refuses $1: $owner"
      state_write "$1" "$2"
      ;;
    *) die "unknown state op: $op (want get|set)" ;;
  esac
}
