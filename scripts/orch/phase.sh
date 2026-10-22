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

# advance needs the base SHA the review diffs against before leaving implement.
require_base_sha() { require_field "$1" base_sha "no base SHA recorded in state - branch create records it"; }

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

cmd_phase() {
  local op="${1:-}"
  shift || true
  case "$op" in
    advance)
      [ $# -eq 0 ] || die "usage: orch.sh phase advance"
      require_state
      local phase next file name issue _unused
      phase="$(state_get phase)"
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
      file="$HANDOFF_DIR/$(handoff_file_for "$next")"
      if autopilot_active; then
        # The handoff is the posted comment: fetched, then checked as a file.
        require_issue issue
        name="$(handoff_file_for "$next")"
        file="$HANDOFF_SCRATCH_DIR/$name"
        handoff_comment_fetch "$issue" "${name%.md}" "$file" ||
          die "issue #$issue has no ${name%.md} handoff comment - post it with handoff post before leaving the $phase phase"
        handoff_check "$file" "" "$name" || die "the ${name%.md} comment on issue #$issue is not valid - post a fixed one, then run phase advance again; the flow stays at $phase"
      else
        handoff_check "$file" || case $? in
          2) die "write $file before leaving the $phase phase" ;;
          *) die "$file is not valid - fix it, then run phase advance again; the flow stays at $phase" ;;
        esac
      fi
      # Deliberately a per-phase switch, not a phase table column: each
      # requirement carries its own remedy message, which a column of field
      # names could only reach through a naming convention.
      case "$next" in
        implement) require_issue _unused ;;
        review)    require_branch _unused; require_base_sha _unused; require_pr _unused ;;
      esac
      if autopilot_active; then
        autopilot_phase_move "$issue" "$next" ""
        note "Phase $(phase_cell writer "$next") complete. Handoff posted on issue #$issue; the watcher starts the $next phase."
        return 0
      fi
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
