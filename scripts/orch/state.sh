# shellcheck shell=bash
# state.sh - orch.sh's state command: state get and state set.
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

# Every read of state.json goes through here, so what an absent key means is
# decided in the STATE_KEYS table rather than at each call site. A key outside
# the table dies: a misspelt read would otherwise look exactly like an unset one.
state_get() { state_get_in "$STATE" "$1"; }

# state_get against the state file <file>: reads <key> from any checkout's
# state file, not only this one's. The key is validated first, so the read's
# status is jq's own, never a lookup's.
state_get_in() {
  local rc
  state_key_field "$2" default >/dev/null || {
    rc=$?
    [ "$rc" -ne 1 ] || die "unknown state key: $2"
    exit "$rc"
  }
  flow_state_get "$1" "$2"
}

# The unrestricted writer behind every internal state change, over
# flow_state_write's coercion on $STATE. A failed write stops orch.sh through
# set -e with jq's status.
state_write() { flow_state_write "$STATE" "$1" "$2"; }

# Stores value $2 under key $1 as a JSON string, always, over
# flow_state_write_string on $STATE.
state_write_string() { flow_state_write_string "$STATE" "$1" "$2"; }

require_state() {
  [ -f "$STATE" ] || die "no active flow ($ORCH_DIR_NAME/state.json not found). Run $(flow_cmd start) first."
}

# Fetches a required state field through state_get, dies with $3 if it comes back empty,
# and otherwise writes it into the variable named by $1 - a caller-named
# out-param via `printf -v` rather than a nameref: bash 3.2 has neither
# `local -n` nor `declare -n`, and this file promises to still run there (the
# same idiom `d_gate` uses in doctor.sh).
#
# Call it as a bare statement on its own line - `local pr; require_pr pr` -
# never folded into `$(...)`. A caller-named out-param has no result to
# capture with `pr="$(require_pr)"` in the first place, so that old shape no
# longer compiles into anything that reads state; the only thing left to write
# is the bare form, and `die` in that form runs directly in the caller's flow
# rather than inside a command substitution subshell, so `set -e` actually
# stops it instead of the caller carrying on with an empty value.
require_field() {
  local __rf_out="$1" __rf_key="$2" __rf_msg="$3" __rf_val
  __rf_val="$(state_get "$__rf_key")"
  [ -n "$__rf_val" ] || die "$__rf_msg"
  printf -v "$__rf_out" '%s' "$__rf_val"
}

# Every review command that reaches GitHub needs the flow's PR number and none
# of them can do anything useful without it.
require_pr() { require_field "$1" pr "no PR recorded in state - the implement phase opens it"; }

# branch create, pr open, and every spec op need the flow's spec issue number
# before touching GitHub.
require_issue() { require_field "$1" issue "no issue recorded in state - the spec phase must publish one first"; }

# pr open and redo review both need the flow's branch before touching GitHub.
require_branch() { require_field "$1" branch "no branch recorded in state"; }

# The one writer of state.phase. It knows only which phases exist: every caller
# - advance, review ready, both redos, and init's seed - keeps its own guard on
# which transition it may make, so a step back needs no handoff check here.
phase_write() {
  case " $PHASES " in
    *" $1 "*) ;;
    *) die "not a flow phase: $1 (want one of: $PHASES)" ;;
  esac
  state_write phase "$1"
}

# The active flow's own base branch, recorded by init. A flow started before
# base was recorded has none, and always forked from the default branch.
flow_base() { flow_base_in "$STATE"; }

# flow_base against another checkout's state file <file>.
flow_base_in() {
  local b
  b="$(state_get_in "$1" base)"
  if [ -n "$b" ]; then printf '%s\n' "$b"; else default_branch; fi
}

# Whether a flow is active: state.json exists and its phase is not done.
flow_active() { flow_state_active "$STATE"; }

# flow_holding_phase <branch> [issue]: prints the phase of the active flow
# (phase not done) when it holds the branch, or the issue where one is given,
# and fails printing nothing otherwise. A branch or issue an active flow holds
# belongs to it (ADR-0029), so review-pass begin and pr draft/ready refuse it,
# each with its own message. Reads state.json only when one exists.
flow_holding_phase() {
  local branch="$1" issue="${2:-}" phase
  flow_active || return 1
  phase="$(state_get phase)"
  [ "$(state_get branch)" = "$branch" ] \
    || { [ -n "$issue" ] && [ "$(state_get issue)" = "$issue" ]; } \
    || return 1
  printf '%s\n' "$phase"
}

# The refusal of a second flow beside one mid-pipeline, shared by init and
# branch off (a quick implementation must never move an active flow's checkout
# off its branch). It exits 3, a code no other failure of either uses, so a
# skill can tell "a flow is active" apart from every other refusal.
refuse_beside_active_flow() {
  flow_active || return 0
  warn "a flow is already active (slug: $(state_get slug), phase: $(state_get phase)).
     One flow at a time - finish it, or run $(flow_cmd abort)."
  exit 3
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
      require_state
      if [ $# -gt 0 ]; then state_get "$1"; else cat "$STATE"; fi
      ;;
    set)
      require_state
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
