# shellcheck shell=bash
# spec.sh - orch.sh's spec command: the flow's spec issue, read and written.
# Its tests: scripts/test/orch/spec.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# --- spec -------------------------------------------------------------------

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the four ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
# All four ops delegate to issue.sh's issue primitives, resolving the number
# from state. A done flow's issue is finished work: state.json lingers after
# the flow ends, so a spec op there would quietly touch an issue nobody is
# reviewing any more - it refuses and points at the stateless issue ops.
cmd_spec() {
  local op="${1:-}"
  shift || true
  require_state
  case "$op" in
    fetch|update|comment|comments) ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment|comments)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment|comments> <file>"
  local file="$1" issue
  require_issue issue
  [ "$(state_get phase)" != "done" ] \
    || die "the flow on issue #$issue is done - spec $op acts only on an active flow's issue; for another issue use orch.sh issue $op <n> <file>"
  "cmd_issue_$op" "$issue" "$file"
}
