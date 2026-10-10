# shellcheck shell=bash
# state.sh - orch.sh's state command: state get and state set.
# Its tests: scripts/test/orch/state.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

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
