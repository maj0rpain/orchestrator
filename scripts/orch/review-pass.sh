# shellcheck shell=bash
# review-pass.sh - orch.sh's review-pass command: a review pass's start.
# Its tests: scripts/test/orch/review-pass.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# --- review-pass ------------------------------------------------------------

# A review pass's start, for a quick implementation's step 6 and a standalone
# review pass alike: the guard and the numbered report prefix each have one
# right answer, so they live here rather than in skill prose. Needs no flow
# state and may run where init never did, so it excludes the orchestrator
# directories itself. It reads state.json only when one exists, never through
# require_state, and never writes it: a branch or issue an active flow holds
# belongs to that flow (ADR-0029). Never wipes - each pass takes the next
# number, so a second pass on a branch never overwrites the first.
cmd_review_pass() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) ;;
    *) die "unknown review-pass op: ${op:-<none>} (want begin)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh review-pass begin <issue>"
  local issue="$1" branch
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  [ "$branch" != "$(recorded_base "$branch")" ] \
    || die "$branch is the base branch - a review pass reviews a branch's change against it; check out the change's branch"
  local phase held
  if phase="$(flow_holding_phase "$branch" "$issue")"; then
    held="$(state_get issue)"
    case "$phase" in
      implement|review)
        die "the active flow holds issue #$held at phase $phase - this change belongs to that flow's review loop; run $(flow_cmd next)" ;;
      spec)
        die "the active flow holds issue #$held at phase spec - its change has not been built yet; run $(flow_cmd next)" ;;
      *)
        die "the active flow holds issue #$held at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
    esac
  fi
  exclude_orch_dirs
  local dir="$ORCH/review-pass/$branch" f n max=0
  mkdir -p "$dir"
  for f in "$dir"/iteration-[0-9][0-9]-*; do
    [ -e "$f" ] || continue
    n="${f##*/iteration-}"
    n="${n%%-*}"
    [ "$((10#$n))" -le "$max" ] || max="$((10#$n))"
  done
  printf '%s/iteration-%02d\n' "$dir" "$((max + 1))"
}
