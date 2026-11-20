# shellcheck shell=bash
# review.sh - orch.sh's review command, with its command-level CI logic
# (review ci, review ci-log, review rerun) and the labels review file creates.
# `review ci [<pr>]` reads the PR given, with no flow state, or the flow's PR;
# its stored total is the same wait store either way.
# `review ci --no-wait` is one pass of review ci's probe: where the waiting
# form would sleep and look again it prints `pending`; it reads no stored
# total, never sleeps and writes no state, wait file or guard.
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

# The bound belongs here rather than in the skill's prose: a session that has
# spent four iterations arguing with itself is exactly the one that would
# re-remember five as six. The number itself is the human's, read from state;
# this is only what it reads as when nobody has set one - a flow started before
# the key existed, or a value nothing can count.
readonly DEFAULT_BUDGET=5

# review_budget_fallback <raw>: prints the budget read from state, or
# DEFAULT_BUDGET where <raw> is empty or not a number.
review_budget_fallback() {
  local b="$1"
  case "$b" in ''|*[!0-9]*) b="$DEFAULT_BUDGET" ;; esac
  printf '%s\n' "$b"
}

# One look at the PR's checks, classified. Prints the classification on the
# first line and any detail on the lines after it, indented like doctor's
# remedies.
#
# adapter_pr_checks answers nothing at all for a repo with no checks, and fails
# for an API that would not answer or an answer it could not read - so the two
# meanings an empty read could carry stay apart. Getting that distinction
# backwards is what would make the loop declare a CI-having repo CI-less, or
# mark a PR ready over checks nobody read.
ci_probe() {
  local out err rc=0
  gh_capture out err adapter_pr_checks "$1" "$2" || rc=$?
  ci_classify "$rc" "$out" "$err"
}

# ci_classify <rc> <checks> <stderr>: ci_probe's classification of one
# adapter_pr_checks answer - its status, its TSV and its stderr - so a caller
# that read the checks itself (ci_counted) classifies them the same way.
ci_classify() {
  local rc="$1" out="$2" err="$3" failed="" pending="" line bucket name
  if [ "$rc" -ne 0 ]; then
    ci_unreachable "$(gh_reason "$err")"
    return 0
  fi
  if [ -z "$out" ]; then note none; return 0; fi
  # One pass over the checks: each failed or cancelled one's name, and
  # whether any is pending.
  while IFS= read -r line; do
    tsv_split "$line" bucket name
    case "$bucket" in
      fail|cancel) failed+="$name"$'\n' ;;
      pending) pending=1 ;;
    esac
  done <<<"$out"
  newlines_strip failed
  if [ -n "$failed" ]; then
    note failing
    while IFS= read -r name; do [ -z "$name" ] || note "      $name"; done <<<"$failed"
    return 0
  fi
  if [ -n "$pending" ]; then note pending; return 0; fi
  note green
}

# ci_counted <out-var> <err-var> <pr>: the one owner of which checks count for
# a PR - the required checks where any are reported, else every check. It sets
# <out-var> to the checks in adapter_pr_checks's TSV shape and <err-var> to the
# stderr of the last read it made (gh's reason on a failure, gh's no-checks
# line on an empty answer), and returns that read's status, so a failed read
# stays apart from an empty one. It has no grace: callers that wait do so
# before calling it. Runs in the current shell, as capture does.
ci_counted() {
  local _cc_rc=0
  gh_capture "$1" "$2" adapter_pr_checks "$3" required || _cc_rc=$?
  [ "$_cc_rc" -eq 0 ] || return "$_cc_rc"
  [ -z "${!1}" ] || return 0
  gh_capture "$1" "$2" adapter_pr_checks "$3" all
}

# ci_counted_probe <pr>: ci_probe's classification of the counted checks (see
# ci_counted), the counterpart of `ci_probe <pr> <scope>`.
ci_counted_probe() {
  local out err rc=0
  ci_counted out err "$1" || rc=$?
  ci_classify "$rc" "$out" "$err"
}

# ci_ready_gate [--exit 2] [--hint <text>] <pr>: the check before a PR is
# marked ready. One look, no grace and no polling, through ci_counted: the
# required checks first, every check when none are required. It only refuses;
# `review ci` keeps the waiting. Failed and unreadable checks die (through
# die2 under --exit 2, with the hint appended); pending ones note it on stderr
# and return; green or none return silently.
ci_ready_gate() {
  local opts=() pr res verdict detail checks
  while [ $# -gt 1 ]; do
    case "$1" in
      --exit|--hint) die_opt_check ci_ready_gate $# "$@"; opts+=("$1" "$2"); shift 2 ;;
      *) die "ci_ready_gate: unknown option $1" ;;
    esac
  done
  pr="$1"
  res="$(ci_counted_probe "$pr")"
  lines_split "$res" verdict detail
  # ci_probe indents each detail line; the message joins them, comma-separated.
  checks="$(list_join "$(sed 's/^ *//' <<<"$detail")")"
  case "$verdict" in
    failing)     die_hinted ${opts[@]+"${opts[@]}"} "PR #$pr has failed checks: $checks" ;;
    unreachable) die_hinted ${opts[@]+"${opts[@]}"} "PR #$pr checks cannot be read: $checks" ;;
    pending)     warn "PR #$pr checks are still pending"; return 0 ;;
    *)           return 0 ;;
  esac
}

# review_record_terminal <path> <var>: sets <var> to the Terminal state section
# of the record at <path>, and succeeds only when the record exists and that
# section holds more than whitespace - the one test of a loop's recorded end.
review_record_terminal() {
  local text=""
  [ -f "$1" ] || { printf -v "$2" '%s' ""; return 1; }
  text="$(section_body "$1" '## Terminal state')" || true
  printf -v "$2" '%s' "$text"
  [ -n "${text//[[:space:]]/}" ]
}

# review_record_path <i>: prints the path of iteration <i>'s review record, as
# `review path` does - numeric check, base 10, the review directory made - and
# reads no state.
review_record_path() {
  local n="$1"
  case "$n" in ''|*[!0-9]*) die "not an iteration number: $n" ;; esac
  # Base 10 explicitly: printf reads a zero-padded argument as octal, and
  # `08` is not a number in base 8.
  n=$((10#$n))
  # Flat, and numbered on across every loop the flow runs: one flow, one
  # trail, and nothing is ever moved aside for a loop that comes later.
  mkdir -p "$REVIEW_DIR" || die "cannot create the review directory $REVIEW_DIR"
  printf '%s/iteration-%02d.md\n' "$REVIEW_DIR" "$n"
}

# review_terminal_record <i>: prints the path of the record iteration <i>'s
# terminal state is read from - the flat iteration-NN.md, or, when that is gone
# while a redo review is half-finished (redo_midway), the same record under
# review/pre-redo-<redo_count>/ if it is there. The classification and its
# callers' malformed messages both take the path from here. It reads state
# only on that fallback: issue, slug, branch and redo_count in one many-key
# read, a failed one counting as no redo in progress.
review_terminal_record() {
  local flat retired n issue slug branch redo_count
  flat="$(review_record_path "$1")" || return 1
  if [ ! -e "$flat" ] \
    && state_get_many_in "$STATE" issue=issue slug=slug branch=branch redo_count=redo_count \
    && n="$(redo_midway "$issue" "$slug" "$branch" "$redo_count")"; then
    retired="$REVIEW_DIR/pre-redo-$n/${flat##*/}"
    if [ -e "$retired" ]; then printf '%s\n' "$retired"; return 0; fi
  fi
  printf '%s\n' "$flat"
}

# review_flat_record_gone <i>: succeeds, silently, when iteration <i> is an
# integer above 0 and its flat iteration-NN.md is gone - the one state in which
# review_terminal_record looks past it (redo_midway). Callers that load a module
# only that look reaches test it here, rather than re-deriving the condition.
review_flat_record_gone() {
  local flat
  is_positive_int "$1" || return 1
  flat="$(review_record_path "$1" 2>/dev/null)" && [ ! -e "$flat" ]
}

# review_terminal_state <iteration> <budget>: reads neither the iteration nor
# the budget - the caller's entry read holds both, so a state file that cannot
# be read is its refusal. Its one read of state is review_terminal_record's
# fallback.
# Classifies the review loop's last iteration against its budget - the one
# answer `review terminal` and doctor's `check_flow_review_terminal` both read,
# rather than each re-deriving which iteration counts as done. Checked with
# the same section_body/required-heading pattern handoff_report already uses,
# not a second implementation of it. Prints the classification word on the
# first line, and for `stop`, the recorded reason on the lines after it; for
# `malformed`, the one expected-shape line callers quote rather than copy;
# for `unreadable`, the record's path, which could not be read. Exit status is
# 0 for ready/stop, non-zero for none/pending/interrupted/malformed/unreadable
# - a single boolean a caller can act on without re-deriving which words count
# as terminal.
#
# The section is read as markdown is written: blank lines under the heading
# are skipped, the first line is trimmed, and `stop` may carry its reason on
# the same line after a separator (-, –, —, :). Anything else in a non-empty
# section is malformed, never silently interrupted - interrupted means the
# record or its section is missing or empty once the budget is spent; short
# of it, the same absence is pending. While a redo review is half-finished
# (redo_midway) and the flat record is gone, the record is read from
# pre-redo-<redo_count>/ (review_terminal_record), so the stopped loop's end
# stays readable until the redo's closing write.
review_terminal_state() {
  local i="$1" budget="$2" path err sec="" line started="" body=""
  local first_raw first rest after s sep
  if [ "$i" -eq 0 ]; then note none; return 1; fi
  # The detail is review_record_path's own last orch: line.
  capture path err review_terminal_record "$i" \
    || { note unreadable; note "${err##*orch: }"; return 1; }
  # A loop can stop short of its budget (a failed base sync goes straight to
  # Termination), so a recorded terminal state is read whatever the
  # iteration; only its absence depends on the budget - pending before it is
  # spent, interrupted once it is.
  if ! review_record_terminal "$path" sec; then
    if [ "$i" -lt "$budget" ]; then note pending; else note interrupted; fi
    return 1
  fi
  # The section from its first line holding more than spaces and tabs on.
  while IFS= read -r line; do
    if [ -z "$started" ]; then
      case "$line" in *[!$' \t']*) started=1 ;; *) continue ;; esac
    fi
    body+="$line"$'\n'
  done <<<"$sec"
  newlines_strip body
  lines_split "$body" first_raw rest
  first="$(trim "$first_raw")"
  case "$first" in
    ready) note ready; return 0 ;;
    stop*)
      after="$(trim "${first#stop}")"
      sep=
      for s in - – — :; do
        case "$after" in "$s"*) sep="$s"; break ;; esac
      done
      # Bare `stop`, or `stop` and a separator: anything else after the word
      # (`stopped`, `stop CI failed`) falls through to malformed.
      if [ -z "$after" ] || [ -n "$sep" ]; then
        after="$(trim "${after#"$sep"}")"
        note stop
        [ -z "$after" ] || printf '%s\n' "$after"
        [ -z "$rest" ] || printf '%s\n' "$rest"
        return 0
      fi ;;
  esac
  note malformed
  note "expected: first line 'ready', or 'stop' with its reason after a separator (-, –, —, :) or on the lines below"
  return 1
}

# One turn of the poll loop: wait (wait_tick), then advance `elapsed`. It
# assigns to the caller's `elapsed`, which bash scopes dynamically.
ci_tick() {
  wait_tick "$ORCH_CI_INTERVAL"
  elapsed="$(wait_taken)"
}

# ci_unreachable <detail>: the `unreachable` verdict and its indented detail
# line, the one spelling of both.
ci_unreachable() {
  note unreachable
  note "      $1"
}

# review ci's two forms (review_ci_once, review_ci_wait) share four helpers,
# which read and set their caller's locals through bash's dynamic scope.
#
# ci_refs <step>: the refs read of PR <pr> into head_oid, head_ref, base_ref,
# refs_err and refs_rc, then <step> (a command its caller supplies: `:` or
# wait_guard_check, which may end the call at 75), then the stop for a PR given
# by number that could not be read: returns 1 after its `unreachable` lines.
# A refs read that failed leaves head_oid empty.
ci_refs() {
  pr_refs_read "$pr" head_oid head_ref base_ref refs_err || refs_rc=$?
  "$1"
  ci_refs_unread "$refs_rc" "$pr_arg" "$pr" "${refs_err-}" && return 1
  [ "$refs_rc" -eq 0 ] || head_oid=""
  return 0
}

# ci_context: how long before WAIT_START the head was pushed (push_age, zero
# when unknown) and whether the PR has no evidence of CI anywhere (no_ci).
ci_context() {
  [ -n "$head_oid" ] || return 0
  local pushed
  pushed="$(ci_push_time "$head_oid" "$head_ref")"
  case "$pushed" in
    ''|*[!0-9]*) ;;
    *) [ "$pushed" -ge "$WAIT_START" ] || push_age=$(( WAIT_START - pushed )) ;;
  esac
  # With no evidence of CI anywhere, there is nothing for the grace to
  # wait on. It replaces only the wait: the unfiltered probe still runs,
  # so a check already reported on the head gives its verdict as before.
  if no_ci_evidence "$head_oid" "$base_ref" "$pr"; then
    no_ci=1
  fi
}

# ci_pass: one probe of the PR's checks into res, its first line in verdict, and
# grace_none (1 when the answer was `none` from the required checks while the
# grace remains). It prints and acts on nothing.
# Branch protection's required checks decide it wherever it names any.
# When nothing required has reported, gh's message cannot tell
# "this repo requires nothing" from
# "what it requires has not registered yet" - so the grace is spent
# waiting on the required set, and only once it runs out does the net
# widen to every check on the commit. Widening sooner is how an
# unrelated green check gets mistaken for a required one that never
# arrived, and the PR marked ready over it.
# While the grace remains a pass probes the required checks alone and reports
# a `none` through grace_none, leaving what to do about it - wait, or print
# pending - to the caller; once it is spent or skipped, the pass reads through
# ci_counted, which widens to every check.
ci_pass() {
  grace_none=0
  if [ "$no_ci" = 0 ] && float_lt "$(float_add "$push_age" "$elapsed")" "$ORCH_CI_GRACE"; then
    res="$(ci_probe "$pr" required)"
    [ "${res%%$'\n'*}" != none ] || grace_none=1
  else
    res="$(ci_counted_probe "$pr")"
  fi
  verdict="${res%%$'\n'*}"
}

# ci_deliver: prints a terminal verdict's lines (res) and sets ci_status to its
# status, returning 0; returns 1, printing nothing, for `pending`.
ci_deliver() {
  case "$verdict" in
    green)       printf '%s\n' "$res"; ci_status=0 ;;
    # Reported, not fixed: which failure is worth a flake rerun is a
    # judgement, and the budget for it belongs to the flow.
    failing)     printf '%s\n' "$res"; ci_status=1 ;;
    unreachable) printf '%s\n' "$res"; ci_status=1 ;;
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
      ci_status=0 ;;
    pending) return 1 ;;
    # Unreachable while ci_probe prints one of the five words above, and
    # the arm that keeps it that way: an unrecognised answer with no arm
    # would fall through to the next pass with nothing to wait on, and
    # spin the waiting form silently on the one command built to be bounded.
    *)
      ci_unreachable "unrecognised answer from gh pr checks: $verdict"
      ci_status=1 ;;
  esac
}

# review_ci_once <pr> <pr_arg>: `review ci --no-wait`, one pass of the probe
# the waiting form repeats: it reads no total, never sleeps and writes no
# state, wait file or guard; where the loop would sleep it prints `pending`.
# A rate limit is given up on at once (NO_WAIT_CALL).
# It sets WAIT_START to this call's start, as no total is open.
review_ci_once() {
  local pr="$1" pr_arg="$2" elapsed=0 res verdict refs_err head_oid head_ref base_ref push_age=0
  local no_ci=0 ci_status refs_rc=0 grace_none
  is_number "$ORCH_CI_GRACE" || die2 "ORCH_CI_GRACE is not a number: $ORCH_CI_GRACE"
  export NO_WAIT_CALL=1
  orch_load wait
  WAIT_START="$WAIT_CALL_START"
  ci_refs : || return 1
  ci_context
  ci_pass
  if [ "$grace_none" = 1 ]; then note pending; return 0; fi
  ci_deliver || { printf '%s\n' "$res"; ci_status=0; }
  return "$ci_status"
}

# review_ci_wait <pr> <pr_arg>: `review ci`, the loop: polls until a verdict or
# ORCH_CI_TIMEOUT. Two clocks: the timeout counts from the wait's first call
# (the stored total), the grace from the push. By the time the loop ends the
# fixer's last push is usually minutes old, and a CI that has not registered a
# check in that time is not about to. `push_age` is how long before the wait's
# first call the push landed; a PR that will not say what its head is, or a
# head with no reflog entry, leaves it at zero, and the grace counts from the
# first call.
# The total is stored from the first call: a wait belongs to this PR and head
# commit, or to the PR alone when the head cannot be read, and is forgotten
# once a call delivers an outcome (wait.sh).
# The refs read runs before the wait's key is known, so a provisional guard
# stands in for it: a limit the block cannot hold is slept short and marked
# there (wait_guard, wait_guard_check), and ends the call as still running with
# no total yet.
review_ci_wait() {
  local pr="$1" pr_arg="$2"
  local elapsed=0 res verdict refs_err head_oid head_ref base_ref push_age=0
  local no_ci=0 ci_status refs_rc=0 grace_none
  require_poll_knobs die2 ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL
  wait_block_check die2
  wait_guard "$pr"
  ci_refs wait_guard_check || return 1
  wait_open "review ci $pr $head_oid"
  elapsed="$(wait_taken)"
  ci_context
  [ -z "$head_oid" ] || wait_limited_check
  while :; do
    ci_pass
    wait_limited_check
    if [ "$grace_none" = 1 ]; then ci_tick; continue; fi
    if ! ci_deliver; then
      if float_lt "$elapsed" "$ORCH_CI_TIMEOUT"; then ci_tick; continue; fi
      # Still pending at the cap is an answer we do not have, not a green
      # one. The loop stops rather than marking a PR ready over something
      # nothing ever verified.
      ci_unreachable "checks were still pending after ${ORCH_CI_TIMEOUT}s"
      ci_status=1
    fi
    break
  done
  # Every terminal verdict leaves the loop with its status, and only a pending
  # verdict, or `none` while the grace remains, continues, so the stored total
  # is forgotten in this one place.
  wait_forget
  return "$ci_status"
}

# When the PR's head was pushed, in epoch seconds: the newest reflog entry of
# the head branch's remote-tracking ref whose new value is the head SHA. Prints
# nothing when there is no such entry - pushed from another machine, or a
# reflog that is not kept - and the grace then counts from the first call.
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
  local head="$1" base="$2" pr="$3" tree required rules evidence line sha verdict
  [ -n "$head" ] && [ -n "$base" ] || return 1
  # 1. A head this clone has never fetched is unreadable, not empty.
  git cat-file -e "$head^{commit}" 2>/dev/null || return 1
  # --full-tree: the pathspec is otherwise read from the current directory,
  # and from a subdirectory an empty listing would read as no workflows.
  tree="$(git ls-tree --full-tree --name-only "$head" -- .github/workflows/ 2>/dev/null)" || return 1
  if grep -Eq '\.ya?ml$' <<<"$tree"; then return 1; fi
  # 2. Required checks, from classic protection or a ruleset. A read that
  # fails is an answer nobody has.
  repo_resolve || :
  required="$(adapter_branch_required_checks "$base" 2>/dev/null)" || return 1
  [ -z "$required" ] || return 1
  rules="$(adapter_branch_rules "$base" 2>/dev/null)" || return 1
  if list_has "$rules" required_status_checks; then return 1; fi
  # 4 and 3, from one read: the base tip's answer, then a line per PR commit.
  # The refs read's head is skipped by SHA, not by position: a push landing
  # between the two reads leaves a newer last commit, judged as an earlier one.
  evidence="$(adapter_pr_commits_checked "$pr" 2>/dev/null)" || return 1
  [ "${evidence%%$'\n'*}" = no ] || return 1
  [[ "$evidence" == *$'\n'* ]] || return 0
  while IFS= read -r line; do
    sha="${line%%$'\t'*}"
    verdict="${line#*$'\t'}"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] && { [ "$verdict" = yes ] || [ "$verdict" = no ]; } || return 1
    [ "$sha" = "$head" ] || [ "$verdict" = no ] || return 1
  done <<<"${evidence#*$'\n'}"
  return 0
}

# The loop's flake rerun (issue #525): the failed jobs of every distinct
# GitHub Actions run behind the failing counted checks - the checks `review ci`
# reads (ci_counted: the required checks where any are reported, else every
# check), every failed or cancelled one, not only the first. A run's id is the
# `runs/<id>` segment of a check's link. `gh run rerun` with no id opens a
# prompt a non-interactive caller cannot answer, so the id is always passed.
# Every failing check's link is verified before any rerun starts, so exit 1
# never leaves a rerun half started. Each run is rerun once, in the order first
# met, and its id printed as its rerun starts. Exit 0 means every rerun
# started, and is the only answer that spends the loop's rerun. Exit 1 means a
# failing check is no Actions run - an outside CI's status - so no rerun could
# make CI green, and nothing is rerun. Everything else - a usage error, no
# repo, a GitHub that cannot be read, no failing check, a refused rerun - goes
# through die2. The repo is resolved here rather than left to the guard, whose
# death exits 1 and would read as "nothing to rerun".
review_rerun() {
  local pr="${1:-}" out err rc=0 link run name line bucket no_checks
  local runs=() r unrerunnable=0 seen=" " failing=0
  [ $# -eq 1 ] || die2 "usage: orch.sh review rerun <pr>"
  case "$pr" in ''|*[!0-9]*) die2 "not a PR number: $pr" ;; esac
  repo_pin || die2 "$REPO_REMEDY"
  # gh's stderr is kept apart from the checks, so its line - a failure's
  # reason, or the "no checks" answer naming the branch - is what the death
  # message carries.
  ci_counted out err "$pr" || rc=$?
  [ "$rc" -eq 0 ] || gh_die --exit 2 "read the checks of PR #$pr" "$err"
  # gh's "no checks" answer, not a failure reason, so not gh_reason's to cut.
  if [ -z "$out" ]; then
    no_checks="${err%%$'\n'*}"
    die2 "PR #$pr has no checks to rerun: ${no_checks:-no checks reported}"
  fi
  # Each failed or cancelled check's name and link, split by tsv_split so an
  # empty name survives: IFS=$'\t' read would collapse it, a tab being IFS
  # whitespace.
  while IFS= read -r line; do
    tsv_split "$line" bucket name link
    case "$bucket" in fail|cancel) ;; *) continue ;; esac
    failing=1
    case "$link" in
      */actions/runs/[0-9]*) ;;
      *) warn "check $name on PR #$pr is not a GitHub Actions run - nothing to rerun"
         unrerunnable=1; continue ;;
    esac
    run="${link##*/actions/runs/}"   # N/job/M -> N
    run="${run%%/*}"
    case "$run" in
      ''|*[!0-9]*) warn "check $name on PR #$pr links no Actions run id - nothing to rerun"; unrerunnable=1; continue ;;
    esac
    case "$seen" in *" $run "*) ;; *) seen+="$run "; runs+=("$run") ;; esac
  done <<<"$out"
  [ "$failing" -eq 1 ] || die2 "PR #$pr has no failed or cancelled check to rerun"
  [ "$unrerunnable" -eq 0 ] || return 1
  for r in "${runs[@]}"; do
    gh_or_die --exit 2 "rerun the failed jobs of Actions run $r" \
      adapter_run_rerun "$r" >/dev/null
    note "$r"
  done
}

# ci_refs_unread <refs_rc> <pr_arg> <pr> <err>: whether review ci must stop
# because the PR it was given by number could not be read - prints
# `unreachable` and its detail line, and returns 0; returns 1 otherwise (a read
# that worked, or the flow's PR, whose unread refs only key its total by PR).
ci_refs_unread() {
  [ "$1" -ne 0 ] && [ -n "$2" ] || return 1
  ci_unreachable "could not read PR #$3: $(gh_reason "$4")"
}

# review_ci_log <pr>: the failed-step log of each failing Actions job behind
# the counted checks (ci_counted), for the driver to judge a failing CI. A
# job's log is cut to its last 200 lines, a line before it counting the lines
# cut. A failing check that is no Actions job gets a line saying so, and a
# job whose log cannot be read a line naming it, and the next job goes on.
# Everything on stdout. A GitHub that cannot be read dies.
review_ci_log() {
  local pr="${1:-}" out err rc=0 line bucket name link job log total
  [ $# -eq 1 ] || die "usage: orch.sh review ci-log <pr>"
  case "$pr" in ''|*[!0-9]*) die "not a PR number: $pr" ;; esac
  repo_pin || die "$REPO_REMEDY"
  ci_counted out err "$pr" || rc=$?
  [ "$rc" -eq 0 ] || gh_die "read the checks of PR #$pr" "$err"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    tsv_split "$line" bucket name link
    case "$bucket" in fail|cancel) ;; *) continue ;; esac
    case "$link" in
      */actions/runs/[0-9]*/job/[0-9]*) job="${link##*/job/}"; job="${job%%[!0-9]*}" ;;
      *) note "check $name is not a GitHub Actions run - no log to read"; continue ;;
    esac
    err=""
    if ! gh_capture log err adapter_job_failed_log "$job"; then
      note "check $name: the log of job $job could not be read: $(gh_reason "$err")"
      continue
    fi
    total="$(printf '%s\n' "$log" | wc -l | tr -d ' ')"
    note "check $name: failed-step log of job $job"
    if [ "$total" -gt 200 ]; then
      note "[cut: $((total - 200)) earlier lines of $total]"
    fi
    printf '%s\n' "$log" | tail -n 200
  done <<<"$out"
}

# review_file <pr> <sev> <title> <flag> <value> ...: <pr> is the flow's recorded
# PR, from the caller's entry read, checked with require_value after the usage
# and finding checks. Files a finding as a GitHub
# issue, its body rendered from its parts by the Filed finding module. Every
# check - the flags, the severity, the axis, the title, the finding file, the
# location, the PR's head sha, and the round trip of the rendered body
# through the parser - comes before any label or issue write, so a malformed
# finding never reaches GitHub rather than surfacing weeks later as "body
# does not parse" in triage.
review_file() {
  local pr_n="$1"
  shift
  orch_load filed-finding
  local usage="usage: orch.sh review file <${FILED_SEVERITIES// /|}> <title> --axis <${FILED_AXES// /|}> --finding-file <f> --severity-reason <r> --location <<file>:<line>> --why <reason> [--spec-question <q>]"
  [ $# -ge 2 ] || die "$usage"
  local severity="$1" title="$2" flag value
  local axis="" finding="" reason="" location="" why="" question=""
  local seen=" "
  shift 2
  finding_flags_parse "$usage" "--axis --finding-file --severity-reason --location --why --spec-question" "$@"
  local i
  for i in "${!FINDING_FLAGS[@]}"; do
    flag="${FINDING_FLAGS[i]}" value="${FINDING_VALUES[i]}"
    ! word_listed "$seen" "$flag" || die "$usage"
    seen+="$flag "
    case "$flag" in
      --axis)            axis="${value,,}" ;;
      --finding-file)    finding="$value" ;;
      --severity-reason) reason="$value" ;;
      --location)        location="$value" ;;
      --why)             why="$value" ;;
      --spec-question)   question="$value" ;;
    esac
  done
  for flag in --axis --finding-file --severity-reason --location --why; do
    word_listed "$seen" "$flag" || die "$usage"
  done

  local colour desc category triage n file line body_file pr sha err
  is_filed_severity "$severity" \
    || die "not a severity that gets filed: $severity (want ${FILED_SEVERITIES// / or } - blocking is always fixed, never filed)"
  filed_severity_label "$severity" colour desc
  # The category follows the axis; finding triage confirms or flips it later.
  category="$(category_for_axis "$axis")" \
    || die "not a review axis: $axis (want ${FILED_AXES// / or })"
  finding_input_check "$title" "$finding"
  # Split at the last colon: the line is the part after it, N or N-M.
  finding_location_check "$location"
  file="${location%:*}" line="${location##*:}"
  # The PR's URL and remote head come from GitHub for the flow's recorded PR,
  # before any write: the URL is right on any host, and the remote head is
  # what finding triage scan fetches.
  require_value pr "$pr_n"
  pr_url_head_read "$pr_n" pr sha err \
    || gh_die "read the URL and head of PR #$pr_n, recorded in state" "$err"
  [[ $sha =~ ^[0-9a-fA-F]+$ ]] || die "not a sha: $sha (want a hex commit SHA)"

  # The round trip. The temp file is removed on every exit - a refusal or a
  # gh failure dies, so a trap, not a closing rm, is what removes it.
  finding_body_file_new body_file
  finding_body_render "$finding" "$axis" "$severity" "$reason" "$file" "$line" \
    "$sha" "$pr" "$why" "$question" >"$body_file"
  local -A got
  finding_body_parse "$(cat "$body_file")" got
  local field
  for field in axis severity reason file line sha pr why question; do
    [ "${!field}" = "${got[$field]}" ] \
      || die "the rendered body does not parse back: $field (given '${!field}', parsed '${got[$field]}')"
  done

  severity_label_ensure "review:$severity" "$colour" "$desc"
  needs_triage_label_ready triage
  category_label_ensure "$category"
  # The title carries no severity prefix: the label holds it, where triage
  # can change it, and the title reads as an issue.
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body_file" "review:$severity" "$triage" "$category"
  # Prints the number alone: the record cites a number, and the caller
  # would otherwise be parsing a URL out of prose every time.
  note "$n"
}

# review_known_items <path> <loop boundary>: writes the loop's known-items
# file to <path>, overwriting it - `## Deviations`, the implement handoff's
# Deviations, then `## Known items`: Waiting to be filed from each record
# numbered above the boundary, Filed from each at or below it, and the plan's
# Rejected alternatives, every entry tagged with its source. A heading with no
# entry reads None. Every refusal comes before the write, and the file is
# built aside and moved into place, so a refused run leaves <path> as it was.
review_known_items() {
  [ $# -eq 2 ] || die "usage: orch.sh review known-items <path> <loop boundary>"
  local path="$1" boundary="$2" implement plan
  case "$boundary" in ''|*[!0-9]*) die "not a loop boundary: $boundary (want the iteration read before the loop's first)" ;; esac
  boundary=$((10#$boundary))
  implement="$(handoff_read "$(handoff_file_for review)")" || exit 1
  plan="$(handoff_read "$(handoff_file_for spec)")" || exit 1

  local record n entry tag deviations="" waiting="" filed="" rejected=""
  section_entries_append deviations "$implement" '## Deviations'
  for record in "$REVIEW_DIR"/iteration-*.md; do
    # Only the records themselves: the reports and known-items files beside
    # them carry a suffix after the number.
    n="${record##*/iteration-}"; n="${n%.md}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$((10#$n))" -gt "$boundary" ]; then
      section_entries_append waiting "$record" '## Waiting to be filed' "waiting to be filed, iteration $n"
    else
      while IFS= read -r entry; do
        # The issue number is the entry's leading #<n>; an entry without one
        # is tagged filed alone.
        tag="filed"
        [[ $entry =~ ^(#[0-9]+) ]] && tag="filed ${BASH_REMATCH[1]}"
        filed+="- $entry - $tag"$'\n'
      done < <(section_entries "$record" '## Filed')
    fi
  done
  section_entries_append rejected "$plan" '## Rejected alternatives' 'rejected alternative'
  known_items_write "$path" "$deviations" "$waiting$filed$rejected"
}

# review_standards_resolve <base> <path>: the repo-relative path <path> names,
# taken against <base> (a repo-relative directory, empty for the repo root),
# with any # fragment dropped. Prints nothing for a URL, an absolute path, a
# path that leaves the repo, or one not ending in .md.
review_standards_resolve() {
  local base="$1" target="$2" seg out=()
  target="${target%%#*}"
  case "$target" in
    ''|/*|*[[:space:]]*) return 0 ;;
  esac
  [[ $target =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && return 0
  [[ $target == *.md ]] || return 0
  local IFS=/ segs
  read -ra segs <<< "$base/$target"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..) [ "${#out[@]}" -gt 0 ] || return 0; unset 'out[${#out[@]}-1]' ;;
      *) out+=("$seg") ;;
    esac
  done
  [ "${#out[@]}" -eq 0 ] || printf '%s\n' "${out[*]}"
}

# review_standards_mentions <file>: the repo-relative .md paths <file> mentions,
# in backticks (against the repo root) or as Markdown links (against <file>'s
# directory), one per line in the order they appear. Backticks pair per
# paragraph of review_standards_paragraphs, so a span may wrap a line break
# and a stray backtick never pairs across a blank line.
review_standards_mentions() {
  local file="$1" dir="" m link
  [[ $file == */* ]] && dir="${file%/*}"
  while IFS= read -r m; do
    case "$m" in
      \`*) review_standards_resolve "" "${m:1:${#m}-2}" ;;
      *)
        link="${m#](}"; link="${link%)}"; link="${link%%[[:space:]]*}"
        link="${link#<}"; link="${link%>}"
        review_standards_resolve "$dir" "$link"
        ;;
    esac
  done < <(review_standards_paragraphs "$file" | cut -f2- | grep -oE '`[^`]+`|\]\([^)]+\)')
}

# review_standards_paragraphs <file>: the paragraphs of the repo file <file>,
# one per line, each tagged `U` (unfenced) or `F` (fenced) and a tab before its
# lines joined by spaces. A paragraph ends at a blank line (inside a fence or
# out), an ATX heading outside a fence or a fence delimiter line; a heading is
# a paragraph of its own; lines inside a fence join into fenced paragraphs;
# delimiter lines are in no paragraph.
review_standards_paragraphs() {
  awk "$FENCE_AWK$STANDARDS_HEADING_AWK"'
    function flush() { if (p != "") print kind "\t" p; p = "" }
    { l = $0; sub(/\r$/, "", l); f = fenced(l) }
    f == 2 { flush(); next }
    f == 1 && l !~ /[^[:space:]]/ { flush(); next }
    f == 1 { kind = "F"; p = (p == "" ? l : p " " l); next }
    is_heading(l) { flush(); print "U\t" l; next }
    l !~ /[^[:space:]]/ { flush(); next }
    { kind = "U"; p = (p == "" ? l : p " " l) }
    END { flush() }
  ' "$ROOT/$1" 2>/dev/null
}

# STANDARDS_HEADING_AWK: awk functions, the one ATX heading rule:
# is_heading(line) is true for 1 to 6 #s, at most 3 spaces in, then a space, a
# tab or the line's end; heading_text(line) is that heading's text,
# surrounding whitespace and closing #s trimmed.
# No interval braces: mawk and BSD awk lack them.
# shellcheck disable=SC2016 # awk program, not shell
STANDARDS_HEADING_AWK='
  function is_heading(line,   h, hashes) {
    if (line !~ /^ ? ? ?#/) return 0
    h = line; sub(/^ */, "", h); hashes = h; sub(/[^#].*$/, "", hashes)
    if (length(hashes) > 6) return 0
    return (h == hashes || substr(h, length(hashes) + 1, 1) ~ /[ \t]/)
  }
  function heading_text(line,   h) {
    h = line; sub(/^ */, "", h); sub(/^#+/, "", h)
    sub(/[[:space:]]+#+[[:space:]]*$/, "", h)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
    return h
  }
'

# review_standards_declaration <file>: the first `Standards:` paragraph of the
# root file <file>, its lines joined, or nothing when it has none: the first
# unfenced paragraph of review_standards_paragraphs that starts with Standards:.
# It reads all of the producer's output, so the producer meets no closed pipe.
review_standards_declaration() {
  review_standards_paragraphs "$1" |
    awk '!found && /^U\tStandards:/ { sub(/^U\t/, ""); print; found = 1 }'
}

# review_standards_heading_count <file> <heading>: how many ATX headings of the
# repo file <file> read exactly <heading>, surrounding whitespace and closing #s
# trimmed. Lines inside a fenced code block (blank lines too) are no headings.
review_standards_heading_count() {
  WANT_HEADING="$2" awk "$FENCE_AWK$STANDARDS_HEADING_AWK"'
    BEGIN { want = ENVIRON["WANT_HEADING"] }
    fenced($0) { next }
    is_heading($0) && heading_text($0) == want { n++ }
    END { print n + 0 }
  ' "$ROOT/$1"
}

# review_standards_realpath <file>: the physical path of the existing file
# <file>, every symlink in it followed (no realpath or readlink -f: macOS).
review_standards_realpath() {
  local f="$1" dir link i
  for ((i = 0; i < 40; i++)); do
    [ -L "$f" ] || break
    link="$(readlink "$f")"
    case "$link" in
      /*) f="$link" ;;
      *) f="${f%/*}/$link" ;;
    esac
  done
  dir="${f%/*}"
  [ "$dir" != "$f" ] || dir=.
  printf '%s/%s\n' "$(cd -P "$dir" && pwd -P)" "${f##*/}"
}

# review_standards_inside <path>: succeeds when the existing file <path>
# (repo-relative), every symlink followed, lies under the repo's physical root.
review_standards_inside() {
  local real root_real
  [ -f "$ROOT/$1" ] || return 1
  real="$(review_standards_realpath "$ROOT/$1")" || return 1
  root_real="$(cd -P "$ROOT" && pwd -P)"
  case "$real" in
    "$root_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# review_standards_declared <entry>: dies unless the entry is a
# repo-relative path naming a regular file inside the repo, optionally with a
# #Heading naming one section that must match exactly once.
review_standards_declared() {
  local e="$1" seg depth segs path n
  case "$e" in
    /*) die "Standards entry \`$e\` is an absolute path (want a repo-relative path)" ;;
  esac
  [[ $e =~ ^[A-Za-z][A-Za-z0-9+.-]*: ]] && die "Standards entry \`$e\` is a URL (want a repo-relative path)"
  depth=0
  path="${e%%#*}"
  IFS=/ read -ra segs <<< "$path"
  for seg in "${segs[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..) depth=$((depth - 1)); [ "$depth" -ge 0 ] || die "Standards entry \`$e\` leaves the repo (want a path inside it)" ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
  [ -e "$ROOT/$path" ] || die "Standards entry \`$e\` names a missing file"
  [ -f "$ROOT/$path" ] || die "Standards entry \`$e\` is not a regular file"
  review_standards_inside "$path" || die "Standards entry \`$e\` leaves the repo (want a path inside it)"
  [ "$path" = "$e" ] && return 0
  n="$(review_standards_heading_count "$path" "${e#*#}")"
  [ "$n" -ge 1 ] || die "Standards entry \`$e\` names a missing heading"
  [ "$n" -eq 1 ] || die "Standards entry \`$e\` names an ambiguous heading (matches $n times)"
}

# review_standards_resolve_source: the Standards resolution, and the path it
# took: a declaration in the root files when one exists, else the crawl:
# root CLAUDE.md and AGENTS.md, or with neither CODING_STANDARDS.md and
# CONTRIBUTING.md, then the .md paths they mention, then the ones those
# mention: two hops, never a third, each path listed once at its first place
# and only when it exists. Prints a first line, `declared <file>` or
# `crawled`, then the list, one path per line (none when the crawl finds
# nothing). A declaration the resolution rejects dies with its message, after
# printing the first line and the entries up to the rejected one, last.
review_standards_resolve_source() {
  local listed=() hop=() next=() f p span entry
  for f in CLAUDE.md AGENTS.md; do
    ! review_standards_inside "$f" || listed+=("$f")
  done
  if [ "${#listed[@]}" -eq 0 ]; then
    for f in CODING_STANDARDS.md CONTRIBUTING.md; do
      ! review_standards_inside "$f" || listed+=("$f")
    done
  fi
  local decl entries=()
  for f in ${listed[@]+"${listed[@]}"}; do
    decl="$(review_standards_declaration "$f")"
    [ -n "$decl" ] || continue
    while IFS= read -r span; do
      entries+=("${span:1:${#span}-2}")
    done < <(grep -oE '`[^`]+`' <<< "$decl")
    # The declaring file leads and each entry is printed before it is checked,
    # so a die leaves the file and, last, the rejected entry on stdout for
    # doctor to read as data.
    printf 'declared %s\n' "$f"
    [ "${#entries[@]}" -gt 0 ] || die "$f declares Standards: with no entries (want backticked paths)"
    for entry in "${entries[@]}"; do
      printf '%s\n' "$entry"
      review_standards_declared "$entry"
    done
    return 0
  done
  hop=(${listed[@]+"${listed[@]}"})
  local i
  for ((i = 0; i < 2; i++)); do
    next=()
    for f in ${hop[@]+"${hop[@]}"}; do
      while IFS= read -r p; do
        review_standards_inside "$p" || continue
        list_has "$(printf '%s\n' "${listed[@]}")" "$p" && continue
        listed+=("$p"); next+=("$p")
      done < <(review_standards_mentions "$f")
    done
    hop=(${next[@]+"${next[@]}"})
  done
  printf 'crawled\n'
  [ "${#listed[@]}" -eq 0 ] || printf '%s\n' "${listed[@]}"
}

# review_standards: the one Standards: line both reviewers' prompts end with,
# from review_standards_resolve_source's list.
review_standards() {
  [ $# -eq 0 ] || die "usage: orch.sh review standards"
  local resolved first list
  resolved="$(review_standards_resolve_source)" || exit $?
  lines_split "$resolved" first list
  if [ -z "$list" ]; then
    note "Standards: none"
  else
    note "Standards: $(list_join "$list")"
  fi
}

# check_standards_declaration: doctor's Standards declaration check, named in
# its env check list: the resolution review_standards_resolve_source makes,
# reported - never parsed a second time. A declaration it dies on is a FAIL
# carrying its own message.
check_standards_declaration() {
  local resolved err list first decl_file entry=""
  if ! capture resolved err review_standards_resolve_source; then
    d_fail "$(err_line "$err")"
    # The died resolution left its stdout: the declaring file, then the entries
    # up to the rejected one (none when the paragraph had no entries).
    lines_split "$resolved" first list
    decl_file="${first#declared }"
    entry="${list##*$'\n'}"
    if [ -n "$entry" ]; then
      d_remedy "change the entry \`$entry\` in the Standards: paragraph of $decl_file to a repo-relative path of a file in the repo, with at most one #Heading that matches once - or delete the paragraph to have the reviewers crawl the standards documents" \
        "see docs/repo-setup.md under the plugin root"
    else
      d_remedy "list backticked repo-relative paths in the Standards: paragraph of $decl_file - or delete the paragraph to have the reviewers crawl the standards documents" \
        "see docs/repo-setup.md under the plugin root"
    fi
    return 0
  fi
  lines_split "$resolved" first list
  case "$first" in
    declared\ *) d_ok "Standards declared in ${first#declared }: $(list_join "$list")" ;;
    *)
      if [ -n "$list" ]; then d_ok "no Standards: declaration - the list is crawled: $(list_join "$list")"
      else d_ok "no Standards: declaration and nothing to crawl - the reviewers apply the smell baseline alone"; fi ;;
  esac
  return 0
}

# review_resume: resumes a review loop whose driving session died mid-iteration,
# spending no budget (ADR-0054). It reads `review terminal` first: only pending
# and interrupted resume, any other state exits 1 with nothing changed. Then it
# proves the current branch is the flow's recorded one (require_flow_branch),
# then applies the discard rule to it - a refusal in an interactive
# main checkout exits 1 with nothing else touched. With no record for the last
# iteration the dead run's reviewer reports are cleared and `rerun <i>` is
# printed; with a record whose Terminal state is empty the iteration finished,
# and `next` (pending) or `terminate` (interrupted) is printed. `iteration` and
# `budget` are never written. A failed clear dies (exit 1) naming the report.
review_resume() {
  [ $# -eq 0 ] || die "usage: orch.sh review resume"
  local state i path report b budget_raw budget recorded phase active=""
  require_state_read i=iteration budget_raw=budget recorded=branch phase=phase
  budget="$(review_budget_fallback "$budget_raw")"
  state="$(review_terminal_state "$i" "$budget")" || true
  state="${state%%$'\n'*}"
  case "$state" in
    pending|interrupted) ;;
    *) die "nothing to resume: review terminal says ${state:-nothing}" ;;
  esac
  b="$(checkout_branch_or_rebasing "$ROOT")" || die "review resume: the current checkout is on no branch - nothing was discarded"
  [ "$phase" = "done" ] || active=1
  discard_own_branch_work "review resume" "$b" "$recorded" "$active"
  path="$(review_record_path "$i")" || exit 1
  if [ ! -f "$path" ]; then
    for report in "${path%.md}"-*.md; do
      [ -e "$report" ] || [ -L "$report" ] || continue
      rm -f -- "$report" 2>/dev/null || die "could not clear the dead iteration's reviewer report $report"
    done
    note "rerun $i"
  elif [ "$state" = pending ]; then
    note next
  else
    note terminate
  fi
}

cmd_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin)
      local n budget budget_raw prior prior_path sec
      require_state_read prior=iteration budget_raw=budget
      n=$(( prior + 1 ))
      budget="$(review_budget_fallback "$budget_raw")"
      [ "$n" -le "$budget" ] || \
        die "budget of $budget iterations spent - stop the loop and report, do not start another"
      # A loop's first iteration - iteration 0, or the one after a record with a
      # Terminal state - renews the loop's flake rerun, in the write that
      # records the iteration; resume never gets here.
      if [ "$prior" -eq 0 ] ||
        { prior_path="$(review_record_path "$prior")" && review_record_terminal "$prior_path" sec; }; then
        state_write_many iteration "$n" flake_rerun_used false
      else
        state_write iteration "$n"
      fi
      note "$n"
      ;;
    path)
      local n
      if [ $# -eq 0 ] || { [ $# -eq 1 ] && [ -z "$1" ]; }; then
        require_state_read n=iteration
      else
        require_state
        [ $# -le 1 ] || die "usage: orch.sh review path [iteration]"
        n="$1"
      fi
      review_record_path "$n"
      ;;
    file)
      local file_pr
      require_state_read file_pr=pr
      review_file "$file_pr" "$@"
      ;;
    ready)
      local pr issue
      require_state_read pr=pr issue=issue
      require_value pr "$pr"
      ci_ready_gate --hint "the flow stays in review" "$pr"
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      gh_or_die --hint "the flow stays in review" "mark PR #$pr ready" \
        adapter_pr_ready "$pr"
      phase_finish "done" "marked PR #$pr ready" "$issue"
      note "$pr"
      # stdout stays the PR number alone; the pointer goes to stderr. A side
      # checkout outlives its PR, so the human is told how to clear it once
      # the PR merges.
      if is_side_checkout "$(pwd -P)"; then
        warn "this is a side checkout - once PR #$pr merges, run $(flow_cmd finish) to archive its flow and remove it"
      fi
      ;;
    ci)
      local nowait=0 pr_arg="" pr_given=0 pr
      while [ $# -gt 0 ]; do
        case "$1" in
          --no-wait) nowait=1 ;;
          *) [ "$pr_given" = 0 ] || die2 "usage: orch.sh review ci [--no-wait] [<pr>]"
             pr_given=1; pr_arg="$1" ;;
        esac
        shift
      done
      if [ "$pr_given" = 1 ]; then
        case "$pr_arg" in ''|*[!0-9]*) die2 "not a PR number: $pr_arg" ;; esac
      fi
      if [ -n "$pr_arg" ]; then
        pr="$pr_arg"
      else
        require_state_read die2 pr=pr
        require_value pr "$pr" die2
      fi
      repo_pin || die2 "$REPO_REMEDY"
      if [ "$nowait" = 1 ]; then
        review_ci_once "$pr" "$pr_arg"
      else
        review_ci_wait "$pr" "$pr_arg"
      fi
      ;;
    known-items)
      require_state
      review_known_items "$@"
      ;;
    standards) review_standards "$@" ;;
    ci-log) review_ci_log "$@" ;;
    rerun) review_rerun "$@" ;;
    resume) review_resume "$@" ;;
    terminal)
      local i budget_raw
      require_state_read i=iteration budget_raw=budget
      [ $# -eq 0 ] || die "usage: orch.sh review terminal"
      review_terminal_state "$i" "$(review_budget_fallback "$budget_raw")"
      ;;
    retire)
      require_state
      [ $# -eq 1 ] || die "usage: orch.sh review retire <n>"
      local n="$1" dest f
      local -a names=()
      case "$n" in ''|*[!0-9]*) die "not a redo number: $n" ;; esac
      dest="$REVIEW_DIR/pre-redo-$n"
      # An existing dest is the one a previous run of this same redo made
      # before dying: resume into it, but never overwrite a record already
      # there - move_files_aside checks every name before the first move.
      mkdir -p "$REVIEW_DIR"
      for f in "$REVIEW_DIR"/iteration-*.md; do
        [ -e "$f" ] && names+=("${f##*/}")
      done
      move_files_aside "$REVIEW_DIR" "$dest" "a review record - redo_count should only increase" ${names[@]+"${names[@]}"}
      note "$dest"
      ;;
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|known-items|standards|ci|ci-log|rerun|ready|terminal|resume|retire)" ;;
  esac
}
