# shellcheck shell=bash

# Names how to start the next phase in a fresh session, in the host's own
# words: the boundary block's Next line. Junie's fresh-session wording is its
# own, not a flow_cmd name (docs/host-capabilities.md, "Start a fresh
# session"); every other host gets flow_cmd's.
next_phase_cmd() {
  case "$(host_detect)" in
    claude) printf '/clear, then %s' "$(flow_cmd next)" ;;
    junie)  printf '/new, then ask for the next phase with /orch-flow' ;;
    *)      printf 'a fresh session, then %s' "$(flow_cmd next)" ;;
  esac
}

# advance needs the base SHA the review diffs against before leaving implement.
require_base_sha() { require_field "$1" base_sha "no base SHA recorded in state - branch create records it"; }

# --- phases -----------------------------------------------------------------

# The block that ends every phase, for the handoff the phase now recorded
# reads: the next phase needs a fresh session this one cannot start, so the
# block names it in the host's own words, through next_phase_cmd.
print_boundary() {
  local phase="$1" done_name file next
  case "$phase" in
    spec)      done_name=plan ;;
    implement) done_name=spec ;;
    review)    done_name=implement ;;
    *) die "no phase boundary at phase: $phase - the flow is not between phases" ;;
  esac
  file="$(handoff_file_for "$phase")"
  next="$(next_phase_cmd)"
  printf 'Phase %s complete. Handoff written to %s/%s.\n\n  Next: %s\n' \
    "$done_name" "$HANDOFF_DIR" "$file" "$next"
}

cmd_phase() {
  local op="${1:-}"
  shift || true
  case "$op" in
    advance)
      [ $# -eq 0 ] || die "usage: orch.sh phase advance"
      require_state
      local phase next file _unused
      phase="$(state_get phase)"
      case "$phase" in
        spec)      next=implement ;;
        implement) next=review ;;
        review)    die "the review phase ends through review ready, once the PR is ready - phase advance does not leave it" ;;
        done)      die "the flow is done - there is no phase to advance to" ;;
        *)         die "not a flow phase: '$phase' - run orch.sh doctor --flow" ;;
      esac
      # The handoff this phase writes is the one the next phase reads. It is
      # checked before the state fields so a missing handoff - the likelier
      # gap - is the one reported.
      file="$HANDOFF_DIR/$(handoff_file_for "$next")"
      handoff_check "$file" || case $? in
        2) die "write $file before leaving the $phase phase" ;;
        *) die "$file is not valid - fix it, then run phase advance again; the flow stays at $phase" ;;
      esac
      case "$next" in
        implement) require_issue _unused ;;
        review)    require_branch _unused; require_base_sha _unused; require_pr _unused ;;
      esac
      phase_write "$next"
      print_boundary "$next"
      ;;
    boundary)
      [ $# -eq 0 ] || die "usage: orch.sh phase boundary"
      require_state
      print_boundary "$(state_get phase)"
      ;;
    *) die "unknown phase op: ${op:-<none>} (want advance|boundary)" ;;
  esac
}
