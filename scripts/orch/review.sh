# shellcheck shell=bash
# review.sh - orch.sh's review command, with its command-level CI logic
# (review ci, review rerun) and the labels review file creates.
# Its tests: scripts/test/orch/review.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# How long `review ci` waits, and how often it looks. Overridable through the
# environment rather than through positional arguments: the 60-second grace is
# what stops a repo whose checks have not registered yet being declared CI-less,
# and a test that could not turn it down would take a minute to prove it works.
# The environment keeps those knobs out of the documented command surface.
ORCH_CI_GRACE="${ORCH_CI_GRACE:-60}"
ORCH_CI_TIMEOUT="${ORCH_CI_TIMEOUT:-900}"
ORCH_CI_INTERVAL="${ORCH_CI_INTERVAL:-10}"

# --- review -----------------------------------------------------------------

# The severity label a filed finding carries, so triage can filter on it. It is
# this plugin's own, so overwriting it is safe: adapter_label_upsert updates a
# label that exists rather than failing on it, and filing works on a repo that
# has never seen the label and on one that has, with no listing step in between.
severity_label_ensure() {
  local err
  capture_err err adapter_label_upsert "$1" "$2" "$3" \
    || die "gh could not create label $1: $(gh_reason "$err")"
}

# The triage label is the repo's, not ours: created only where it is missing,
# and never rewritten, because a maintainer's colour and description on it are
# theirs to keep. A create that fails because the label exists is the common
# case and is ignored; one that fails for any other reason surfaces two lines
# later, when `gh issue create` cannot apply the label.
triage_label_ensure() {
  adapter_label_create "$1" e4e669 "Not yet triaged" 2>/dev/null || true
}

# category_for_axis <axis>: the category a finding filed on that review axis
# starts in, whatever the axis's case. A Spec finding misses what was asked
# for, so it is a bug; a Standards finding improves how it was built. Prints
# nothing and fails for any other axis; the caller words its own error.
category_for_axis() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    spec)      printf 'bug\n' ;;
    standards) printf 'enhancement\n' ;;
    *) return 1 ;;
  esac
}

# Float comparison and addition, in awk, because the timings are overridable and
# the tests turn them down to fractions of a second; bash arithmetic is integer
# only and would read a grace of 0.3 as 0. A fractional `sleep` is a GNU/BSD
# extension rather than POSIX, which is a line this file can hold because the
# fractions only ever come from a test - the shipped defaults are whole seconds.
float_lt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
float_add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a + b }'; }

# awk compares a number against a non-numeric string as strings, which makes
# every `float_lt` above true and the poll loop endless. A zero interval is the
# same hazard by a different route: `sleep 0` returns at once and never advances
# the clock the loop sleeps on, leaving it to poll a rate-limited API as fast as
# GitHub will answer. The three knobs are read once, here, before anything
# sleeps on one of them.
require_ci_knobs() {
  local k v
  for k in ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL; do
    eval "v=\$$k"
    case "$v" in
      ''|*[!0-9.]*|*.*.*|.) die "$k is not a number: $v" ;;
    esac
  done
  # Every character is a zero or the point, so the value is zero however it was
  # written - and a glob cannot say that without also matching 0.05.
  case "${ORCH_CI_INTERVAL//[0.]/}" in
    '') die "ORCH_CI_INTERVAL must be greater than zero: $ORCH_CI_INTERVAL" ;;
  esac
}

# The larger of the wall clock and the time this loop has spent asleep. The wall
# clock alone is whole seconds, which a sub-second override never reaches; the
# sleep total alone ignores however long each `gh` call took, which would stretch
# a 15-minute cap well past 15 minutes on a slow connection.
ci_elapsed() { awk -v w="$(( $(date +%s) - $1 ))" -v s="$2" 'BEGIN { print (w > s) ? w : s }'; }

# One turn of the poll loop: wait, then advance both clocks. It assigns to the
# caller's `slept` and `elapsed`, which bash scopes dynamically - threading two
# counters back out through a subshell's stdout would cost more than it explains.
ci_tick() {
  sleep "$ORCH_CI_INTERVAL"
  slept="$(float_add "$slept" "$ORCH_CI_INTERVAL")"
  elapsed="$(ci_elapsed "$started" "$slept")"
}

# When the PR's head was pushed, in epoch seconds: the newest reflog entry of
# the head branch's remote-tracking ref whose new value is the head SHA. Prints
# nothing when there is no such entry - pushed from another machine, or a
# reflog that is not kept - and the grace then counts from the call instead.
ci_push_time() {
  local oid="$1" branch="$2"
  [ -n "$oid" ] && [ -n "$branch" ] || return 0
  git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null || return 0
  git reflog show --date=unix --format='%H %gd' "refs/remotes/origin/$branch" -- 2>/dev/null \
    | awk -v h="$oid" '$1 == h { sub(/.*@\{/, "", $2); sub(/\}$/, "", $2); print $2; exit }' || true
}

# Whether the repo shows no evidence of CI, for review ci's grace (issue
# #476, ADR-0032). Succeeds only when all four signals read as absent:
#   1. workflow files in the PR head's tree, read locally;
#   2. required checks on the base branch, by classic protection or a ruleset;
#   3. a check-run or commit status on an earlier commit of the PR;
#   4. a check-run or commit status on the base branch tip.
# Fails on the first signal present or unreadable. The errors are asymmetric:
# a false "has CI" costs a minute of grace, a false "no CI" marks a PR ready
# over checks nobody verified - so anything this cannot read counts as CI.
# Recomputed on every call: a workflow the PR itself adds is always seen.
no_ci_evidence() {
  local head="$1" base="$2" commits="$3" out sha
  [ -n "$head" ] && [ -n "$base" ] || return 1
  # 1. A head this clone has never fetched is unreadable, not empty.
  git cat-file -e "$head^{commit}" 2>/dev/null || return 1
  # --full-tree: the pathspec is otherwise read from the current directory,
  # and from a subdirectory an empty listing would read as no workflows.
  out="$(git ls-tree --full-tree --name-only "$head" -- .github/workflows/ 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -Eq '\.ya?ml$'; then return 1; fi
  # 2. Required checks, from classic protection or a ruleset. A read that
  # fails is an answer nobody has.
  out="$(adapter_branch_required_checks "$base" 2>/dev/null)" || return 1
  [ -z "$out" ] || return 1
  out="$(adapter_branch_rules "$base" 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -qx required_status_checks; then return 1; fi
  # 4, then 3: the base tip is one ref, the PR's earlier commits may be many.
  ci_ref_unchecked "$base" || return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] || [ "$sha" = "$head" ] || ci_ref_unchecked "$sha" || return 1
  done <<<"$commits"
  return 0
}

# Succeeds when one ref has neither a check-run nor a commit status, and the
# two reads both answered.
ci_ref_unchecked() {
  [ "$(adapter_commit_has_check_runs "$1" 2>/dev/null)" = no ] || return 1
  [ "$(adapter_commit_has_statuses "$1" 2>/dev/null)" = no ]
}

# The flow's flake rerun (issue #525): the failed jobs of the GitHub Actions
# run behind the PR's first failed or cancelled check, whose id is the
# `runs/<id>` segment of that check's link. `gh run rerun` with no id opens a
# prompt a non-interactive caller cannot answer, so the id is always passed.
# Exit 0 means the rerun started, and is the only answer that spends the
# flow's rerun. Exit 1 means the first failing check is no Actions run - an
# outside CI's status - so there is nothing to rerun. Everything else - a usage
# error, no repo, a GitHub that cannot be read, no failing check, a refused
# rerun - goes through die2. The repo is resolved here rather than left to the
# guard, whose death exits 1 and would read as "nothing to rerun".
review_rerun() {
  local pr="${1:-}" out err gh_line rc=0 link="" run name="" line bucket
  [ $# -eq 1 ] || die2 "usage: orch.sh review rerun <pr>"
  case "$pr" in ''|*[!0-9]*) die2 "not a PR number: $pr" ;; esac
  repo_pin || die2 "$REPO_REMEDY"
  # gh's stderr is kept apart from the checks, so its line - a failure's
  # reason, or the "no checks" answer naming the branch - is what the death
  # message carries.
  capture out err adapter_pr_checks "$pr" all || rc=$?
  gh_line="${err%%$'\n'*}"
  [ "$rc" -eq 0 ] || die2 "gh could not read the checks of PR #$pr: $(gh_reason "$err")"
  [ -n "$out" ] || die2 "PR #$pr has no checks to rerun: ${gh_line:-no checks reported}"
  # The first failed or cancelled check's name and link, split by tsv_split
  # so an empty name survives: IFS=$'\t' read would collapse it, a tab being
  # IFS whitespace. No failed check leaves both empty.
  while IFS= read -r line; do
    tsv_split "$line" bucket name link
    case "$bucket" in fail|cancel) break ;; esac
    name=""; link=""
  done <<<"$out"
  [ -n "$link" ] || die2 "PR #$pr has no failed or cancelled check to rerun"
  case "$link" in
    */actions/runs/[0-9]*) ;;
    *) warn "check $name on PR #$pr is not a GitHub Actions run - nothing to rerun"
       return 1 ;;
  esac
  run="${link##*/actions/runs/}"   # N/job/M -> N
  run="${run%%/*}"
  case "$run" in ''|*[!0-9]*) warn "check $name on PR #$pr links no Actions run id - nothing to rerun"; return 1 ;; esac
  # rerun_out is the rerun's throwaway half: only its stderr is read.
  # shellcheck disable=SC2034
  local rerun_out rerun_err
  capture rerun_out rerun_err adapter_run_rerun "$run" \
    || die2 "gh could not rerun the failed jobs of Actions run $run: $(gh_reason "$rerun_err")"
  note "$run"
}

cmd_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin)
      require_state
      local n budget
      n=$(( $(state_get iteration) + 1 ))
      budget="$(review_budget)"
      [ "$n" -le "$budget" ] || \
        die "budget of $budget iterations spent - stop the loop and report, do not start another"
      state_write iteration "$n"
      note "$n"
      ;;
    path)
      require_state
      [ $# -le 1 ] || die "usage: orch.sh review path [iteration]"
      local n
      n="${1:-$(state_get iteration)}"
      case "$n" in ''|*[!0-9]*) die "not an iteration number: $n" ;; esac
      # Base 10 explicitly: printf reads a zero-padded argument as octal, and
      # `08` is not a number in base 8.
      n=$((10#$n))
      # Flat, and numbered on across every loop the flow runs: one flow, one
      # trail, and nothing is ever moved aside for a loop that comes later.
      mkdir -p "$REVIEW_DIR"
      printf '%s/iteration-%02d.md\n' "$REVIEW_DIR" "$n"
      ;;
    file)
      require_state
      local usage="usage: orch.sh review file <${FILED_SEVERITIES// /|}> <title> --axis <spec|standards> --body-file <file>"
      [ $# -eq 6 ] && [ "$3" = --axis ] && [ "$5" = --body-file ] || die "$usage"
      local severity="$1" title="$2" axis="$4" body="$6" colour category triage n err
      is_filed_severity "$severity" \
        || die "not a severity that gets filed: $severity (want ${FILED_SEVERITIES// / or } - blocking is always fixed, never filed)"
      case "$severity" in
        major) colour=d93f0b ;;
        nit)   colour=c5def5 ;;
        *) die "no label colour for filed severity: $severity" ;;
      esac
      # The category follows the axis; finding triage confirms or flips it later.
      category="$(category_for_axis "$axis")" \
        || die "not a review axis: $axis (want spec or standards)"
      [ -n "$title" ] || die "the title is empty"
      [ -f "$body" ] || die "body file not found: $body"
      severity_label_ensure "review:$severity" "$colour" "Review finding filed at $severity severity"
      triage="$(triage_label_for needs-triage)"
      triage_label_ensure "$triage"
      category_label_ensure "$category"
      # The title carries no severity prefix: the label holds it, where triage
      # can change it, and the title reads as an issue.
      capture n err adapter_issue_create "$title" "$body" "review:$severity" "$triage" "$category" \
        || die "gh could not create the issue: $(gh_reason "$err")"
      # Prints the number alone: the record cites a number, and the caller
      # would otherwise be parsing a URL out of prose every time.
      note "$n"
      ;;
    ready)
      require_state
      local pr err
      require_pr pr
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      capture_err err adapter_pr_ready "$pr" \
        || die "gh could not mark PR #$pr ready: $(gh_reason "$err") - the flow stays in review"
      phase_write "done"
      note "$pr"
      # stdout stays the PR number alone; the pointer goes to stderr. A side
      # checkout outlives its PR, so the human is told how to clear it once
      # the PR merges.
      if is_side_checkout "$(pwd -P)"; then
        warn "this is a side checkout - once PR #$pr merges, run $(flow_cmd finish) to archive its flow and remove it"
      fi
      ;;
    ci)
      require_state
      local pr started slept=0 elapsed=0 res verdict refs head_oid head_ref base_ref pushed push_age=0
      local commits="" no_ci=0
      require_ci_knobs
      require_pr pr
      started="$(date +%s)"
      # Two clocks: the timeout counts from this call, the grace from the push.
      # By the time the loop ends the fixer's last push is usually minutes old,
      # and a CI that has not registered a check in that time is not about to.
      # `push_age` is how long before this call the push landed; a PR that will
      # not say what its head is, or a head with no reflog entry, leaves it at zero,
      # and the grace counts from the call as it always did.
      if refs="$(adapter_pr_refs "$pr" 2>/dev/null)"; then
        lines_split "$refs" head_oid head_ref base_ref commits
        pushed="$(ci_push_time "$head_oid" "$head_ref")"
        case "$pushed" in
          ''|*[!0-9]*) ;;
          *) [ "$pushed" -ge "$started" ] || push_age=$(( started - pushed )) ;;
        esac
        # With no evidence of CI anywhere, there is nothing for the grace to
        # wait on. It replaces only the wait: the unfiltered probe still runs,
        # so a check already reported on the head gives its verdict as before.
        if no_ci_evidence "$head_oid" "$base_ref" "$commits"; then
          no_ci=1
        fi
      fi
      while :; do
        # Branch protection's required checks decide it wherever it names any.
        # When nothing required has reported, gh's message cannot tell "this repo
        # requires nothing" from "what it requires has not registered yet" - so
        # the grace is spent waiting on the required set, and only once it runs
        # out does the net widen to every check on the commit. Widening sooner is
        # how an unrelated green check gets mistaken for a required one that
        # never arrived, and the PR marked ready over it.
        res="$(ci_probe "$pr" required)"
        verdict="${res%%$'\n'*}"
        if [ "$verdict" = none ]; then
          if [ "$no_ci" = 0 ] && float_lt "$(float_add "$push_age" "$elapsed")" "$ORCH_CI_GRACE"; then
            ci_tick; continue
          fi
          res="$(ci_probe "$pr" all)"
          verdict="${res%%$'\n'*}"
        fi
        case "$verdict" in
          green)       printf '%s\n' "$res"; return 0 ;;
          # Reported, not fixed: which failure is worth a flake rerun is a
          # judgement, and the budget for it belongs to the flow.
          failing)     printf '%s\n' "$res"; return 1 ;;
          unreachable) printf '%s\n' "$res"; return 1 ;;
          # Only reachable with the grace spent or skipped: nothing required
          # reported, and then nothing at all reported either. The detail line
          # says which, here rather than in ci_probe, so doctor's lines are
          # unchanged.
          none)
            printf '%s\n' "$res"
            if [ "$no_ci" = 1 ]; then
              note "      no CI signals found: no workflow files in the head, no required checks on $base_ref, no checks or statuses on earlier PR commits or the $base_ref tip"
            else
              note "      nothing reported before the ${ORCH_CI_GRACE}s grace ran out"
            fi
            return 0 ;;
          pending)
            if float_lt "$elapsed" "$ORCH_CI_TIMEOUT"; then ci_tick; continue; fi
            # Still pending at the cap is an answer we do not have, not a green
            # one. The loop stops rather than marking a PR ready over something
            # nothing ever verified.
            note unreachable
            note "      checks were still pending after ${ORCH_CI_TIMEOUT}s"
            return 1 ;;
          # Unreachable while ci_probe prints one of the five words above, and
          # the arm that keeps it that way: an unrecognised answer with no arm
          # would fall through to the next pass with nothing to wait on, and
          # spin this loop silently on the one command built to be bounded.
          *)
            note unreachable
            note "      unrecognised answer from gh pr checks: $verdict"
            return 1 ;;
        esac
      done
      ;;
    rerun) review_rerun "$@" ;;
    terminal)
      require_state
      [ $# -eq 0 ] || die "usage: orch.sh review terminal"
      review_terminal_state
      ;;
    retire)
      require_state
      [ $# -eq 1 ] || die "usage: orch.sh review retire <n>"
      local n="$1" dest f
      case "$n" in ''|*[!0-9]*) die "not a redo number: $n" ;; esac
      dest="$REVIEW_DIR/pre-redo-$n"
      [ ! -e "$dest" ] || die "$dest already exists - redo_count should only increase"
      mkdir -p "$REVIEW_DIR"
      for f in "$REVIEW_DIR"/iteration-*.md; do
        [ -e "$f" ] || continue
        mkdir -p "$dest"
        mv "$f" "$dest/"
      done
      note "$dest"
      ;;
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|ci|rerun|ready|terminal|retire)" ;;
  esac
}
