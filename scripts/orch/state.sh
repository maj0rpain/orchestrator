# shellcheck shell=bash
# state.sh - orch.sh's state command (state get and state set), with the state
# helpers every module calls (state_get, state_write, require_state,
# require_pr, require_issue, flow_active). Two readers: state_get, the
# unguarded own-checkout reader, and state_get_in, the guarded shared one.
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
# commands that must refuse such a file do it first, with
# require_state_readable.
state_get() {
  local rc
  flow_state_get "$STATE" "$1" && return
  rc=$?
  state_get_failed "$1" "$rc"
}

# The shared reader, guarded: reads <key> from the state file <file> of any
# checkout, not only this one's. An unreadable <file> (flow_state_readable)
# returns status 2 and prints nothing - no jq text, so a caller scanning other
# checkouts can skip it. On a readable one it behaves as state_get does.
state_get_in() {
  local rc
  flow_state_readable "$1" || return 2
  flow_state_get "$1" "$2" && return
  rc=$?
  state_get_failed "$2" "$rc"
}

# state_get_failed <key> <status>: what a failed read of <key> returns. The key
# is looked up only now, to pick the message: a key outside the table dies, and
# any other failure returns <status>, the read's own (jq's), never a lookup's.
state_get_failed() {
  flow_state_key_field "$1" default >/dev/null || die "unknown state key: $1"
  return "$2"
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

# require_state [die2]: dies unless an active flow's state file exists and
# parses (require_state_exists, then require_state_readable) - with die2 for a
# command that reserves exit 1 for a meaningful "no".
# shellcheck disable=SC2120 # die2 is passed by spec_phase_guard, in spec.sh
require_state() {
  require_state_exists "$@"
  require_state_readable "$@"
}

# The one spelling of the refusal an unparseable state.json earns.
STATE_UNREADABLE_MSG="state.json cannot be read - run orch.sh doctor --flow"

# require_state_exists [die2]: require_state's existence check alone, for
# doctor --flow and abort, which must still run on a state.json that does not
# parse.
require_state_exists() {
  [ -f "$STATE" ] || "${1:-die}" "no active flow ($ORCH_DIR_NAME/state.json not found). Run $(flow_cmd start) first."
}

# require_state_readable [die2]: dies, through the dier given, when the state
# file exists but does not parse as a JSON object. A missing file passes: the
# caller settles whether a flow must exist.
require_state_readable() {
  [ ! -f "$STATE" ] || flow_state_readable "$STATE" || "${1:-die}" "$STATE_UNREADABLE_MSG"
}

# Fetches a required state field through state_get, dies with $3 if it comes
# back empty, and otherwise writes it into the variable named by $1 - a
# caller-named out-param via `printf -v` rather than a nameref: bash 3.2 has
# neither `local -n` nor `declare -n`, and this file promises to still run there
# (the same idiom `d_gate` uses in doctor.sh).
#
# Call it as a bare statement on its own line - `local pr; require_pr pr` -
# never folded into `$(...)`. A caller-named out-param has no result to
# capture with `pr="$(require_pr)"` in the first place, so that old shape no
# longer compiles into anything that reads state; the only thing left to write
# is the bare form, and `die` in that form runs directly in the caller's flow
# rather than inside a command substitution subshell, so `set -e` actually
# stops it instead of the caller carrying on with an empty value.
#
# A fourth argument, die2, dies through die2 instead, for a command that
# reserves exit 1 for a meaningful "no".
require_field() {
  local __rf_out="$1" __rf_key="$2" __rf_msg="$3" __rf_die="${4:-die}" __rf_val
  require_state_readable "$__rf_die"
  __rf_val="$(state_get "$__rf_key")"
  [ -n "$__rf_val" ] || "$__rf_die" "$__rf_msg"
  printf -v "$__rf_out" '%s' "$__rf_val"
}

# Every review command that reaches GitHub needs the flow's PR number and none
# of them can do anything useful without it.
require_pr() { require_field "$1" pr "no PR recorded in state - the implement phase opens it"; }

# branch create, pr open, and every spec op need the flow's spec issue number
# before touching GitHub. A second argument, die2, is passed on to
# require_field.
require_issue() { require_field "$1" issue "no issue recorded in state - the spec phase must publish one first" "${2:-die}"; }

# pr open and redo review both need the flow's branch before touching GitHub.
require_branch() { require_field "$1" branch "no branch recorded in state"; }

# The writers of state.phase: phase_write, which dies on a failed write, and
# phase_write_try, which returns the writer's status for a caller that words
# its own failure. They know only which phases exist: every caller - advance,
# review ready, both redos, and init's seed - keeps its own guard on which
# transition it may make, so a step back needs no handoff check here.
phase_write() {
  phase_write_try "$1" || die "could not record phase in $STATE - the flow is unchanged"
}
phase_write_try() {
  word_listed "$PHASES" "$1" || die "not a flow phase: $1 (want one of: $PHASES)"
  flow_state_write "$STATE" phase "$1"
}

# The active flow's own base branch, recorded by init. A flow started before
# base was recorded has none, and always forked from the default branch.
flow_base() { flow_base_in "$STATE"; }

# flow_base against another checkout's state file <file>. A state file that
# cannot be read returns the read's failure: the default branch stands in
# only for a readable state that records no base.
flow_base_in() {
  local b
  b="$(state_get_in "$1" base)" || return
  if [ -n "$b" ]; then printf '%s\n' "$b"; else default_branch; fi
}

# Whether a flow is active: state.json exists and its phase is not done.
flow_active() { flow_state_active "$STATE"; }

# flow_holding_phase <branch> [issue]: prints the phase of the active flow
# (phase not done) when it holds the branch, or the issue where one is given,
# and returns 0. Returns 1 printing nothing when no active flow holds them,
# and 2 when state.json cannot be read - so the guard fails closed. A branch
# or issue an active flow holds belongs to it (ADR-0029), so review-pass begin
# and pr draft/ready refuse it, each with its own message, and refuse status 2
# too. Reads state.json only when one exists. Every
# read is checked here: callers run it in `$(...) ||`, where errexit is off.
flow_holding_phase() {
  local branch="$1" issue="${2:-}" phase held_branch held_issue
  flow_active || return 1
  flow_state_readable "$STATE" || return 2
  phase="$(state_get phase)" || return 2
  held_branch="$(state_get branch)" || return 2
  if [ "$held_branch" != "$branch" ]; then
    [ -n "$issue" ] || return 1
    held_issue="$(state_get issue)" || return 2
    [ "$held_issue" = "$issue" ] || return 1
  fi
  printf '%s\n' "$phase"
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
