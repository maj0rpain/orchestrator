# shellcheck shell=bash
# global.sh - orch.sh's bare global commands with no module of their own:
# status and archive. slug and help are converted nouns (orch/slug.py,
# orch/help.py). Its tests: scripts/test/orch/global.sh (archive and status's
# flow cases) and scripts/test/orch/side-checkout.sh (status's listing of other
# checkouts).
# Sourced by orch.sh, after common.sh and the ROOT block.

cmd_status() {
  if [ ! -f "$STATE" ]; then
    note "No active flow. Run $(flow_cmd start) from an approved plan."
  else
    status_flow
  fi
  status_others
}

# Lists every other checkout holding a flow, and every side checkout without
# one - the main checkout's flow included when run from a side checkout -
# under a heading of its own. Ticket worktrees, a hand-made worktree with no
# flow and a quick implementation in the main checkout hold no flow and carry
# no marker, so they never appear; with nothing to list, nothing is printed.
status_others() {
  local list kind flow _branch path lines=""
  # The walk below runs in command substitutions: load what it calls here,
  # once, rather than once per subshell.
  orch_load checkout
  orch_load side-checkout
  list="$(checkouts_or_die)" || exit $?
  while read -r kind flow _branch path; do
    [ "$path" != "$ROOT" ] || continue
    [ "$flow" = 1 ] || [ "$kind" = side ] || continue
    lines+="  $path $(checkout_holding "$path")"$'\n'
  done <<<"$list"
  [ -n "$lines" ] || return 0
  note ""
  note "other checkouts:"
  printf '%s' "$lines"
}

# Full detail on the current checkout's flow.
status_flow() {
  local slug phase issue branch pr iteration redo_count base base_raw budget budget_raw
  require_state_read slug=slug phase=phase issue=issue branch=branch pr=pr \
    iteration=iteration redo_count=redo_count base_raw=base budget_raw=budget
  flow_base_fallback_into base "$base_raw"
  budget="$(review_budget_fallback "$budget_raw")"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     ${issue:--}"
  note "base:      $base"
  note "branch:    ${branch:--}"
  note "PR:        ${pr:--}"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $budget"
  # Unconditional, like every other line here: a flow that has never been
  # redone still has an answer - 0 - rather than a line that only appears once
  # something has happened.
  note "redo:      $redo_count"
  note ""
  note "handoffs:"
  local f
  for f in "$HANDOFF_DIR"/*.md; do
    [ -e "$f" ] || { note "  (none yet)"; break; }
    note "  ${f#"$ROOT"/}"
  done
}

# Archive rather than delete: the moment you want a handoff back is precisely
# the moment you just threw it away. The directory is git-excluded anyway.
# In a side checkout, git worktree remove would delete the archive with the
# worktree - it deletes ignored files - so the flow moves to the main
# checkout's archive first, and only then is the worktree removed (ADR-0037).
cmd_archive() {
  require_state_exists
  local archive_home
  archive_home="$(archive_root "$ROOT")" || die "could not read the checkouts - nothing was archived"
  # Only a side checkout archives anywhere but in place.
  if [ "$archive_home" = "$ROOT" ]; then
    archive_flow "$ROOT" "$archive_home"
    return
  fi
  # A refused removal is kept and warned of: the archive has still succeeded.
  side_checkout_archive_and_remove_or_exit "$ROOT" "$archive_home" "$(pwd -P)" warn || true
}
