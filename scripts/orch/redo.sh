# shellcheck shell=bash
# redo.sh - orch.sh's redo command: redo review and redo spec.
# Its tests: scripts/test/orch/redo.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The first retire step, shared by both redos: prints the pair the retire
# plans, two lines, "<n>" then "<resumed>": the number the attempt's retire
# carries and whether its rename is already done.
# A previous call at this same redo can have already retired the branch and
# recorded it in state before dying: branch and redo_count are set together
# right after a real retire, so if the recorded branch already matches what this
# redo_count's retire would have produced, the rename is done. The PR close ran
# before the rename, so a rerun that finds it done skips the close outright
# rather than retiring an already-retired branch a second time (issue #63).
redo_retire_plan() {
  local issue="$1" slug="$2" branch redo_count
  branch="$(state_get branch)"
  redo_count="$(state_get redo_count)"
  if [ "$redo_count" -gt 0 ] && [ "$branch" = "$(branch_name_redo "$issue" "$slug" "$redo_count")" ]; then
    printf '%s\n1\n' "$redo_count"
  else
    printf '%s\n0\n' $(( redo_count + 1 ))
  fi
}

# redo_refuse_ticket_worktrees: both redos' guard, dying while ticket
# worktrees are left under the checkout, before anything moves.
redo_refuse_ticket_worktrees() {
  refuse_ticket_worktrees "$ROOT" "a redo would strand their unmerged ticket work"
}

# The second retire step, shared by both redos: close state.pr with the redo
# comment, then rename state.branch to its -redo-<n> name and record it at
# once - unless <resumed> says the rename is done, which also means the close
# came before it, so a resumed rerun does neither. The close comes first
# because deleting an open PR's head branch makes GitHub close the PR itself,
# and gh's later close-with-comment would then post nothing (issue #1932). A
# rerun after a death between the two closes again, which gh treats as a no-op.
# With no branch recorded it closes nothing, renames nothing and leaves
# redo_count alone. The caller clears branch, pr and base_sha itself, last, so
# a rerun finds the retired branch.
redo_retire_attempt() {
  local issue="$1" slug="$2" n="$3" resumed="$4" branch pr new_branch msg
  branch="$(state_get branch)"
  [ -n "$branch" ] || return 0
  [ "$resumed" -eq 0 ] || return 0
  new_branch="$(branch_name_redo "$issue" "$slug" "$n")"
  pr="$(state_get pr)"
  if [ -n "$pr" ]; then
    msg="$(printf 'This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\nA new PR will follow once the redone implement phase reaches pr open again.\n' "$new_branch")"
    gh_or_die "close PR #$pr" adapter_pr_close "$pr" "$msg"
  fi
  cmd_branch retire "$branch" "$new_branch" >/dev/null
  # Recorded immediately: the rename already happened for real, so
  # state.branch has to track it.
  state_write_string branch "$new_branch"
  state_write redo_count "$n"
}

# Clears the attempt's branch, pr and base_sha from state. The callers of
# redo_retire_attempt run it last, so a rerun finds the retired branch.
redo_clear_attempt() {
  state_write branch null
  state_write pr null
  state_write base_sha null
}

# The full `review -> implement` transition: retire the old branch and PR,
# reopen the spec issue's closed tickets, move the old loop's records aside,
# and reset the state a fresh implement attempt needs - never mid-budget, and
# never over a loop nobody has confirmed actually ended. `flake_rerun_used` is
# deliberately untouched throughout: it is one per loop, and review begin
# resets it when the next loop starts.
cmd_redo_review() {
  [ $# -eq 0 ] || die "usage: orch.sh redo review"
  require_state
  local phase i b word detail slug issue branch pr new_n resumed
  phase="$(state_get phase)"
  [ "$phase" = review ] || die "flow is not at the review phase - nothing to redo back from"
  i="$(state_get iteration)"
  b="$(review_budget)"
  local terminal; terminal="$(review_terminal_state)" || true
  lines_split "$terminal" word detail
  case "$word" in
    none)
      die "no review loop has run yet - nothing to redo back from; run $(flow_cmd next) to start one." ;;
    pending)
      die "the review loop hasn't reached its budget yet (iteration $i of budget $b) - that's what $(flow_cmd next) is for; redo is for after a loop ends." ;;
    interrupted)
      die "the review loop's last iteration ($i) has no recorded terminal state - the session looks interrupted, not stopped. Resume it with $(flow_cmd next); redo only runs once a loop actually ends." ;;
    malformed)
      die "the review loop's last iteration ($i) has a malformed terminal state - rewrite the first line of $(cmd_review path "$i") in the shape below; redo only runs once a loop actually ends.
$detail" ;;
    unreadable)
      die "cannot read the review loop's terminal state: $detail" ;;
    stop) ;;
    *) die "review_terminal_state answered something redo does not know: $word" ;;
  esac
  redo_refuse_ticket_worktrees

  slug="$(state_get slug)"
  require_issue issue
  require_branch branch
  require_pr pr
  local retire
  retire="$(redo_retire_plan "$issue" "$slug")"
  lines_split "$retire" new_n resumed

  # The implement handoff described the attempt being retired; left in place,
  # phase advance would let the redone implement phase leave on it (#279).
  # Retired first, before any state moves, so a redo that dies partway leaves
  # the phase as it was; the label pairs it with the review records beside it.
  # A resumed redo finds it already retired. The plan handoff is never touched.
  # shellcheck disable=SC2046 # handoff filenames hold no spaces or globs
  handoff_retire "pre-redo-$new_n" $(handoffs_written_from implement)

  redo_retire_attempt "$issue" "$slug" "$new_n" "$resumed"

  # The prior implement phase closed every ticket it finished, so the redone
  # implement phase's frontier query (ticket next) would otherwise find
  # nothing and open an empty PR - reopen exactly what ticket close closed.
  cmd_ticket_reset "$issue" >/dev/null

  cmd_review retire "$new_n" >/dev/null

  redo_clear_attempt
  state_write iteration 0
  phase_write implement
  note "$new_n"
}

# The full `implement -> spec` transition. Defaults to keeping the existing
# spec issue and re-reviewing it - through the spec phase's step 0, whose
# redo check reads the pre-redo-spec-* folder this leaves behind and so
# skips the rewrite decision an adopted issue gets - and retires that issue's
# ticket breakdown (`ticket retire`, issue #334) so the redone spec is broken
# down again. The handoffs retire first, then the breakdown: a GitHub failure at
# the latter dies with the phase still `implement`, the handoffs already in
# their pre-redo-spec-* folder and the markers in place, so a re-run resumes.
# Only `--new-issue` closes the old one and clears state.issue, so orch-to-spec
# runs again from scratch; its tickets are left as they are.
cmd_redo_spec() {
  require_state
  local phase new_issue=0
  phase="$(state_get phase)"
  [ "$phase" = implement ] || die "flow is not at the implement phase - nothing to redo back from"
  case "${1:-}" in
    "") ;;
    --new-issue) new_issue=1; shift ;;
    *) die "usage: orch.sh redo spec [--new-issue]" ;;
  esac
  [ $# -eq 0 ] || die "usage: orch.sh redo spec [--new-issue]"
  redo_refuse_ticket_worktrees
  # The spec handoff - and the implement handoff built on it, if any - are
  # stale once the spec is being redone, so phase advance must not pass on
  # them (#279). They are retired first, before any state moves, as in redo
  # review. The folder is told apart by a UTC timestamp. The implement attempt
  # retires next, under the old issue number, bumping redo_count when it
  # retires a branch.
  local issue label slug retire n resumed
  require_issue issue
  label="pre-redo-spec-$(dir_stamp)"
  # shellcheck disable=SC2046 # handoff filenames hold no spaces or globs
  handoff_retire "$label" $(handoffs_written_from spec)
  slug="$(state_get slug)"
  retire="$(redo_retire_plan "$issue" "$slug")"
  lines_split "$retire" n resumed
  redo_retire_attempt "$issue" "$slug" "$n" "$resumed"
  if [ "$new_issue" -eq 1 ]; then
    local msg
    msg="$(printf 'This issue was closed by an orchestrator redo because the spec itself needed to change.\n\nA fresh issue will follow from orch-to-spec in this same flow.\n')"
    gh_or_die "close issue #$issue" adapter_issue_close "$issue" --comment "$msg"
    state_write issue null
  else
    cmd_ticket_retire "$issue"
  fi
  # The spec-paused marker (#1181) moves late, into this run's pre-redo-spec
  # folder (the handoffs' too, unless a re-run after a death between the two
  # moves computed a new stamp): left behind, it would carry the redone spec
  # phase past its rewrite decision. The round marker (#1348) moves with it
  # for the same reason: left behind, it would carry the redone spec review
  # past round 1.
  # The round directories stay in place, since round 1's `spec round-dir 1/<n>`
  # clears them.
  move_files_aside "$HANDOFF_DIR" "$HANDOFF_DIR/$label" "a retired handoff" "$SPEC_PAUSED_MARKER" "$SPEC_ROUND_MARKER"
  redo_clear_attempt
  phase_write spec
}

cmd_redo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    review) cmd_redo_review "$@" ;;
    spec)   cmd_redo_spec "$@" ;;
    *) die "unknown redo op: ${op:-<none>} (want review|spec)" ;;
  esac
}
