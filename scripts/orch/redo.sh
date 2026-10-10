# shellcheck shell=bash

# --- redo ---------------------------------------------------------------

# True when any of the named files exists under <dir>.
any_exist_under() {
  local dir="$1" f
  shift
  for f in "$@"; do [ -e "$dir/$f" ] && return 0; done
  return 1
}

# Moves each named handoff that exists into exactly <dest>, created only when
# there is something to move. A <dest> already holding one of them is refused
# before any handoff moves; unlike `review retire`, a <dest> that merely
# exists is fine.
retire_handoffs() {
  local dest="$1" f
  shift
  any_exist_under "$HANDOFF_DIR" "$@" || return 0
  if any_exist_under "$dest" "$@"; then
    die "$dest already holds a retired handoff - refusing to overwrite it"
  fi
  mkdir -p "$dest"
  for f in "$@"; do
    [ -e "$HANDOFF_DIR/$f" ] && mv "$HANDOFF_DIR/$f" "$dest/"
  done
  return 0
}

# The full `review -> implement` transition: retire the old branch and PR,
# reopen the spec issue's closed tickets, move the old loop's records aside,
# and reset the state a fresh implement attempt needs - never mid-budget, and
# never over a loop nobody has confirmed actually ended. `flake_rerun_used` is
# deliberately untouched throughout, per docs/adr/0007: it is a per-flow
# allowance, not a per-loop one.
cmd_redo_review() {
  [ $# -eq 0 ] || die "usage: orch.sh redo review"
  require_state
  local phase i b word slug issue branch pr redo_count new_n new_branch msg err
  phase="$(state_get phase)"
  [ "$phase" = review ] || die "flow is not at the review phase - nothing to redo back from"
  i="$(state_get iteration)"
  b="$(review_budget)"
  local terminal; terminal="$(review_terminal_state)" || true
  word="$(first_line "$terminal")"
  case "$word" in
    none)
      die "no review loop has run yet - nothing to redo back from; run $(flow_cmd next) to start one." ;;
    pending)
      die "the review loop hasn't reached its budget yet (iteration $i of budget $b) - that's what $(flow_cmd next) is for; redo is for after a loop ends." ;;
    interrupted)
      die "the review loop's last iteration ($i) has no recorded terminal state - the session looks interrupted, not stopped. Resume it with $(flow_cmd next); redo only runs once a loop actually ends." ;;
    malformed)
      die "the review loop's last iteration ($i) has a malformed terminal state - rewrite the first line of $(cmd_review path "$i") in the shape below; redo only runs once a loop actually ends.
$(printf '%s\n' "$terminal" | tail -n +2)" ;;
    stop) ;;
    *) die "review_terminal_state answered something redo does not know: $word" ;;
  esac

  slug="$(state_get slug)"
  require_issue issue
  require_branch branch
  require_pr pr
  redo_count="$(state_get redo_count)"

  # A previous call at this same redo can have already retired the branch
  # and recorded it here before dying on the PR close below - branch and
  # redo_count are set together right after a real retire, so if the
  # recorded branch already matches what this redo_count's retire would
  # have produced, the retire already happened: resume at closing the PR
  # instead of retiring an already-retired branch a second time, which
  # issue #63 called out by name as not what a retry should do.
  if [ "$redo_count" -gt 0 ] && [ "$branch" = "orch/${issue}-${slug}-redo-${redo_count}" ]; then
    new_n="$redo_count"
    new_branch="$branch"
  else
    new_n=$(( redo_count + 1 ))
    new_branch="orch/${issue}-${slug}-redo-${new_n}"
    cmd_branch retire "$branch" "$new_branch" >/dev/null
    # Recorded immediately, before the gh call below that can still fail:
    # the rename already happened for real, so state.branch has to track it
    # now rather than keep naming a branch that no longer exists if pr
    # close dies and a retry has to find the real current name.
    state_write_string branch "$new_branch"
    state_write redo_count "$new_n"
  fi

  msg="$(printf 'This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\nA new PR will follow once the redone implement phase reaches pr open again.\n' "$new_branch")"
  capture_err err adapter_pr_close "$pr" "$msg" || die "gh could not close PR #$pr: $(gh_reason "$err")"

  # The prior implement phase closed every ticket it finished, so the redone
  # implement phase's frontier query (ticket next) would otherwise find
  # nothing and open an empty PR - reopen exactly what ticket close closed.
  cmd_ticket_reset "$issue" >/dev/null

  cmd_review retire "$new_n" >/dev/null
  # The implement handoff described the attempt just retired; left in place,
  # phase advance would let the redone implement phase leave on it (#279).
  # Same N as the review records beside it. 01-plan.md is never touched.
  retire_handoffs "$HANDOFF_DIR/pre-redo-$new_n" 03-implement.md

  state_write branch null
  state_write pr null
  state_write base_sha null
  state_write iteration 0
  phase_write implement
  note "$new_n"
}

# The full `implement -> spec` transition. Defaults to keeping the existing
# spec issue and re-reviewing it - through the spec phase's step 0, whose
# redo check reads the pre-redo-spec-* folder this leaves behind and so
# skips the rewrite question an adopted issue gets - and retires that issue's ticket
# breakdown (`ticket retire`, issue #334) so the redone spec is broken down
# again. The retire runs first: a GitHub failure there dies with the phase
# still `implement` and the handoffs in place, so a re-run resumes. Only
# `--new-issue` closes the old one and clears state.issue, so orch-to-spec
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
  if [ "$new_issue" -eq 1 ]; then
    local issue msg err
    require_issue issue
    msg="$(printf 'This issue was closed by an orchestrator redo because the spec itself needed to change.\n\nA fresh issue will follow from orch-to-spec in this same flow.\n')"
    capture_err err adapter_issue_close "$issue" --comment "$msg" \
      || die "gh could not close issue #$issue: $(gh_reason "$err")"
    state_write issue null
  else
    local kept
    require_issue kept
    cmd_ticket_retire "$kept"
  fi
  # The spec handoff - and the implement handoff built on it, if any - are
  # stale once the spec is being redone, so phase advance must not pass on
  # them (#279). redo_count stays put: it counts review step-backs and names
  # the retired branch, so the directory is told apart by a UTC timestamp.
  local dest
  dest="$HANDOFF_DIR/pre-redo-spec-$(dir_stamp)"
  retire_handoffs "$dest" 02-spec.md 03-implement.md
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
