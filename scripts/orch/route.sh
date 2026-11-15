# shellcheck shell=bash
# route.sh - orch.sh's route command: the default route.
# Its tests: scripts/test/orch/route.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The default route: which of the four routes the interview's Closing lists
# first. Read here alone, so the skills never call git config; it is set with
# git config [--global] orchestrator.route <route>. git config --get gives the
# clone's local value before the user's global one.
cmd_route() {
  local op="${1:-}" v
  shift || true
  case "$op" in
    show)
      [ $# -eq 0 ] || die "usage: orch.sh route show"
      v="$(git config --get orchestrator.route 2>/dev/null || true)"
      case "$v" in
        "") v=none ;;
        flow | quick | blueprint | autopilot) ;;
        *) die "orchestrator.route is $v - it must be one of flow, quick, blueprint or autopilot (git config orchestrator.route <route>)" ;;
      esac
      note "$v"
      ;;
    *) die "unknown route op: ${op:-<none>} (want show)" ;;
  esac
}
