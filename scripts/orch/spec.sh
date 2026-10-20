# shellcheck shell=bash
# spec.sh - orch.sh's spec command: the flow's spec issue, read and written,
# and the pause that stops the spec phase's session once it is written.
# Its tests: scripts/test/orch/spec.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the four ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
# The four read and write ops delegate to issue.sh's issue primitives,
# resolving the number from state; pause touches no issue. A done flow's issue
# is finished work: state.json lingers after the flow ends, so a spec op there
# would quietly touch an issue nobody is reviewing any more - it refuses and
# points at the stateless issue ops.
cmd_spec() {
  local op="${1:-}"
  shift || true
  require_state
  case "$op" in
    fetch|update|comment|comments) ;;
    pause) cmd_spec_pause "$@"; return ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment|comments|pause)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment|comments> <file>"
  local file="$1" issue
  require_issue issue
  flow_active \
    || die "the flow on issue #$issue is done - spec $op acts only on an active flow's issue; for another issue use orch.sh issue $op <n> <file>"
  "cmd_issue_$op" "$issue" "$file"
}

# The marker a spec phase leaves when it stops its session once the spec is
# written (#1181), holding the issue number: the fresh session's spec phase
# reads it and goes straight to the spec review. A file in the handoff folder
# but not a handoff - no phase table entry names it, so handoff validate and
# doctor never look at it - and no state.json field (ADR-0005). redo spec moves
# it aside with the stale handoffs.
readonly SPEC_PAUSED_MARKER=spec-paused

# Stops the spec phase's session after the spec is written: writes the marker,
# then prints the stop block with the host's Next line. The marker is written
# first, so a failed write prints no block; the phase is left at spec.
cmd_spec_pause() {
  [ $# -eq 0 ] || die "usage: orch.sh spec pause"
  local issue phase
  require_issue issue
  flow_active \
    || die "the flow on issue #$issue is done - spec pause acts only on an active flow"
  phase="$(state_get phase)"
  [ "$phase" = spec ] \
    || die "spec pause runs only in the spec phase - the flow is at phase $phase"
  mkdir -p "$HANDOFF_DIR" || die "cannot create $HANDOFF_DIR"
  printf '%s\n' "$issue" >"$HANDOFF_DIR/$SPEC_PAUSED_MARKER" \
    || die "cannot write $HANDOFF_DIR/$SPEC_PAUSED_MARKER"
  print_next_block "Spec #$issue written. The spec review runs in a fresh session."
}
