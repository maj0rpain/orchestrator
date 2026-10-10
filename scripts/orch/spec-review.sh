# shellcheck shell=bash
# spec-review.sh - orch.sh's spec-review command: a standalone spec review's start.
# Its tests: scripts/test/orch/spec-review.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A standalone spec review's start: the guard and the working-directory reset
# each have one right answer, so they live here rather than in skill prose.
# It reads state.json only when one exists, never through require_state - it
# dies with no flow, and no flow is the common case - and never writes it.
# The issue number is the caller's, never state's: the guard only compares.
# State holds only the phases in PHASES, so every not-done phase is one below.
cmd_spec_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) ;;
    *) die "unknown spec-review op: ${op:-<none>} (want begin)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec-review begin <n>"
  local issue="$1"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  if [ -f "$STATE" ]; then
    local phase held
    phase="$(state_get phase)"
    held="$(state_get issue)"
    if [ "$phase" != "done" ] && [ "$held" = "$issue" ]; then
      case "$phase" in
        spec)
          die "the active flow holds issue #$issue at phase spec - the flow's own spec phase will review it; run $(flow_cmd next)" ;;
        implement|review)
          die "the active flow holds issue #$issue at phase $phase - the ticket subagents build from this spec, so it cannot change behind the flow; run $(flow_cmd redo) to step back to the spec phase" ;;
        *)
          die "the active flow holds issue #$issue at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
      esac
    fi
  fi
  # Built from the validated number alone, so the wipe stays inside
  # spec-review/.
  local dir="$ORCH/spec-review/$issue"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s/\n' "$dir"
}
