# shellcheck shell=bash
# phase.sh - orch.sh's phase command: phase advance and the phase boundary.
# Its tests: scripts/test/orch/phase.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

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

# Prints a block that ends a session: <headline>, a blank line, then the
# indented Next line naming the fresh session to start, through next_phase_cmd.
print_next_block() { printf '%s\n\n  Next: %s\n' "$1" "$(next_phase_cmd)"; }

# The block that ends every phase, for the handoff the phase now recorded
# reads: the next phase needs a fresh session this one cannot start, so the
# block names it in the host's own words, through next_phase_cmd. The finished
# phase is the writer of the handoff <phase> consumes, read from the phase
# table; done and a phase outside it have none, so no boundary.
print_boundary() {
  local phase="$1" done_name file
  done_name="$(phase_cell writer "$phase")" ||
    die "no phase boundary at phase: $phase - the flow is not between phases"
  file="$(handoff_file_for "$phase")"
  print_next_block "Phase $done_name complete. Handoff written to $HANDOFF_DIR/$file."
}

# phase_finish <next> <reason> <issue>: records <next> as the flow's phase. In an
# autopilot session it also checks <issue>, the flow's issue the caller holds,
# with require_value, moves the issue's phase label and releases the claim,
# <reason> naming what was done. It reads no state. It reports success only, never its
# mode - a caller asks autopilot_active for that - so it is called as a plain
# statement, never in a condition, where set -e would be suspended.
phase_finish() {
  if autopilot_active; then
    require_value issue "$3"
    standing_finish "$3" "$1" "$2"
  else
    phase_write "$1"
  fi
}

cmd_phase() {
  local op="${1:-}"
  shift || true
  case "$op" in
    advance)
      [ $# -eq 0 ] || die "usage: orch.sh phase advance"
      local phase next file name issue branch base_sha pr
      require_state_read phase=phase issue=issue branch=branch base_sha=base_sha pr=pr
      # The guards run in this order; past them, the next phase is the phase
      # table's, and phase_next fails only on a phase outside the table.
      case "$phase" in
        review) die "the review phase ends through review ready, once the PR is ready - phase advance does not leave it" ;;
        done)   die "the flow is done - there is no phase to advance to" ;;
      esac
      next="$(phase_next "$phase")" ||
        die "not a flow phase: '$phase' - run orch.sh doctor --flow"
      # The handoff this phase writes is the one the next phase reads. It is
      # checked before the state fields so a missing handoff - the likelier
      # gap - is the one reported.
      name="$(handoff_file_for "$next")"
      file="$(handoff_read "$name" "before leaving the $phase phase")"
      handoff_check "$file" "" "$name" ||
        handoff_invalid "$name" "then run phase advance again; the flow stays at $phase"
      # Deliberately a per-phase switch, not a phase table column: each
      # requirement carries its own remedy message, which a column of field
      # names could only reach through a naming convention.
      case "$next" in
        implement) require_value issue "$issue" ;;
        review)    require_value branch "$branch"; require_value base_sha "$base_sha"
               require_value pr "$pr"; require_value issue "$issue"
               require_no_open_tickets "$issue" "phase advance" ;;
      esac
      phase_finish "$next" "" "$issue"
      if autopilot_active; then
        note "Phase $(phase_cell writer "$next") complete. Handoff posted on issue #$issue; the watcher starts the $next phase."
      else
        print_boundary "$next"
      fi
      ;;
    boundary)
      [ $# -eq 0 ] || die "usage: orch.sh phase boundary"
      local phase
      require_state_read phase=phase
      print_boundary "$phase"
      ;;
    *) die "unknown phase op: ${op:-<none>} (want advance|boundary)" ;;
  esac
}
