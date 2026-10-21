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

# The bound belongs here rather than in the skill's prose: a session that has
# spent four iterations arguing with itself is exactly the one that would
# re-remember five as six. The number itself is the human's, read from state;
# this is only what it reads as when nobody has set one - a flow started before
# the key existed, or a value nothing can count.
readonly DEFAULT_BUDGET=5

# review_budget: prints the flow's review budget from state, or DEFAULT_BUDGET
# where none is set or the value is not a number. Returns the read's status
# when state.json cannot be read, never a default in its place.
review_budget() {
  local b
  b="$(state_get budget)" || return
  case "$b" in ''|*[!0-9]*) b="$DEFAULT_BUDGET" ;; esac
  printf '%s\n' "$b"
}

# One look at the PR's checks, classified. Prints the classification on the first
# line and any detail on the lines after it, indented like doctor's remedies.
#
# adapter_pr_checks answers nothing at all for a repo with no checks, and fails
# for an API that would not answer or an answer it could not read - so the two
# meanings an empty read could carry stay apart. Getting that distinction
# backwards is what would make the loop declare a CI-having repo CI-less, or
# mark a PR ready over checks nobody read.
ci_probe() {
  local pr="$1" scope="$2" out err failed="" pending="" line bucket name
  if ! capture out err adapter_pr_checks "$pr" "$scope"; then
    note unreachable
    note "      $(gh_reason "$err")"
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

# Classifies the review loop's last iteration against its budget - the one
# answer `review terminal` and doctor's `check_flow_review_terminal` both read,
# rather than each re-deriving which iteration counts as done. Checked with
# the same section_body/required-heading pattern handoff_report already uses,
# not a second implementation of it. Prints the classification word on the
# first line, and for `stop`, the recorded reason on the lines after it; for
# `malformed`, the one expected-shape line callers quote rather than copy;
# for `unreadable`, what could not be read - the iteration or the record's
# path. Exit status is 0 for ready/stop, non-zero for none/pending/
# interrupted/malformed/unreadable - a single boolean a caller can act on
# without re-deriving which words count as terminal.
#
# The section is read as markdown is written: blank lines under the heading
# are skipped, the first line is trimmed, and `stop` may carry its reason on
# the same line after a separator (-, –, —, :). Anything else in a non-empty
# section is malformed, never silently interrupted - interrupted means the
# record or its section is missing or empty once the budget is spent; short
# of it, the same absence is pending.
review_terminal_state() {
  require_state
  local i b path err sec="" line started="" body="" first_raw first rest after s sep
  # Its callers run it in `$(...) || true`, where errexit is off, so each read
  # is checked here: a failure answers unreadable, never pending/interrupted.
  i="$(state_get iteration)" \
    || { note unreadable; note "cannot read iteration from $STATE"; return 1; }
  b="$(review_budget)" \
    || { note unreadable; note "cannot read budget from $STATE"; return 1; }
  if [ "$i" -eq 0 ]; then note none; return 1; fi
  # The detail is cmd_review path's own last orch: line.
  capture path err cmd_review path "$i" \
    || { note unreadable; note "${err##*orch: }"; return 1; }
  # A loop can stop short of its budget (a failed base sync goes straight to
  # Termination), so a recorded terminal state is read whatever the
  # iteration; only its absence depends on the budget - pending before it is
  # spent, interrupted once it is.
  if [ -f "$path" ]; then sec="$(section_body "$path" '## Terminal state')" || true; fi
  if [ ! -f "$path" ] || [ -z "${sec//[[:space:]]/}" ]; then
    if [ "$i" -lt "$b" ]; then note pending; else note interrupted; fi
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
  if grep -Eq '\.ya?ml$' <<<"$out"; then return 1; fi
  # 2. Required checks, from classic protection or a ruleset. A read that
  # fails is an answer nobody has.
  out="$(adapter_branch_required_checks "$base" 2>/dev/null)" || return 1
  [ -z "$out" ] || return 1
  out="$(adapter_branch_rules "$base" 2>/dev/null)" || return 1
  if list_has "$out" required_status_checks; then return 1; fi
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
  local pr="${1:-}" out err rc=0 link="" run name="" line bucket no_checks
  [ $# -eq 1 ] || die2 "usage: orch.sh review rerun <pr>"
  case "$pr" in ''|*[!0-9]*) die2 "not a PR number: $pr" ;; esac
  repo_pin || die2 "$REPO_REMEDY"
  # gh's stderr is kept apart from the checks, so its line - a failure's
  # reason, or the "no checks" answer naming the branch - is what the death
  # message carries.
  capture out err adapter_pr_checks "$pr" all || rc=$?
  [ "$rc" -eq 0 ] || gh_die --exit 2 "read the checks of PR #$pr" "$err"
  # gh's "no checks" answer, not a failure reason, so not gh_reason's to cut.
  if [ -z "$out" ]; then
    no_checks="${err%%$'\n'*}"
    die2 "PR #$pr has no checks to rerun: ${no_checks:-no checks reported}"
  fi
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
  gh_or_die --exit 2 "rerun the failed jobs of Actions run $run" \
    adapter_run_rerun "$run" >/dev/null
  note "$run"
}

# review_file <sev> <title> <flag> <value> ...: files a finding as a GitHub
# issue, its body rendered from its parts by the Filed finding module. Every
# check - the flags, the severity, the axis, the title, the finding file, the
# location, and the round trip of the rendered body through the parser - comes
# before any label or issue write, so a malformed finding never reaches GitHub
# rather than surfacing weeks later as "body does not parse" in triage.
review_file() {
  local usage="usage: orch.sh review file <${FILED_SEVERITIES// /|}> <title> --axis <spec|standards|suite-cost> --finding-file <f> --severity-reason <r> --location <file>:<line|suite> --sha <sha> --pr <url> --why <reason> [--spec-question <q>]"
  [ $# -ge 2 ] || die "$usage"
  local severity="$1" title="$2" flag value
  local axis="" finding="" reason="" location="" sha="" pr="" why="" question=""
  local seen=" "
  shift 2
  while [ $# -gt 0 ]; do
    flag="$1"
    case "$flag" in
      --axis|--finding-file|--severity-reason|--location|--sha|--pr|--why|--spec-question) ;;
      *) die "$usage" ;;
    esac
    [ $# -ge 2 ] || die "$usage"
    case "$seen" in *" $flag "*) die "$usage" ;; esac
    seen+="$flag "
    value="$(trim "$2")"
    [ -n "$value" ] || die "$usage"
    case "$flag" in
      --axis)            axis="$value" ;;
      --finding-file)    finding="$value" ;;
      --severity-reason) reason="$value" ;;
      --location)        location="$value" ;;
      --sha)             sha="$value" ;;
      --pr)              pr="$value" ;;
      --why)             why="$value" ;;
      --spec-question)   question="$value" ;;
    esac
    shift 2
  done
  for flag in --axis --finding-file --severity-reason --location --sha --pr --why; do
    case "$seen" in *" $flag "*) ;; *) die "$usage" ;; esac
  done

  local colour desc category triage n file line body
  is_filed_severity "$severity" \
    || die "not a severity that gets filed: $severity (want ${FILED_SEVERITIES// / or } - blocking is always fixed, never filed)"
  filed_severity_label "$severity" colour desc
  # The category follows the axis; finding triage confirms or flips it later.
  category="$(category_for_axis "$axis")" \
    || die "not a review axis: $axis (want spec, standards or suite-cost)"
  [ -n "$title" ] || die "the title is empty"
  [ -f "$finding" ] || die "finding file not found: $finding"
  [ -n "$(tr -d '[:space:]' <"$finding")" ] || die "finding file is empty: $finding"
  # Split at the last colon: the line is the part after it, N or N-M. The
  # literal suite - a suite-cost finding's - names the suite, with no line.
  if [ "$location" = "$SUITE_LOCATION" ]; then
    file="$SUITE_LOCATION" line=""
  else
    file="${location%:*}" line="${location##*:}"
    [[ $location == *:* && -n $file && $line =~ ^[0-9]+(-[0-9]+)?$ ]] \
      || die "not a location: $location (want <file>:<line>, <file>:<start>-<end> or suite)"
  fi

  # The round trip. The temp file is removed on every exit - a refusal or a
  # gh failure dies, so a trap, not a closing rm, is what removes it.
  body="$(mktemp)" || die "could not create a temp file for the issue body"
  # shellcheck disable=SC2064 # expanded now: $body is local, gone by exit
  trap "rm -f $(printf '%q' "$body")" EXIT
  finding_body_render "$finding" "$axis" "$severity" "$reason" "$file" "$line" \
    "$sha" "$pr" "$why" "$question" >"$body"
  # shellcheck disable=SC2034 # finding_body_parse writes them; read by name below
  local got_axis got_severity got_reason got_file got_line got_sha got_pr got_pr_number got_why got_question
  finding_body_parse "$(cat "$body")" got
  local field given ref
  for field in axis severity reason file line sha pr why question; do
    case "$field" in
      axis) given="$(printf '%s' "$axis" | tr '[:upper:]' '[:lower:]')" ;;
      *)    given="${!field}" ;;
    esac
    ref="got_$field"
    [ "$given" = "${!ref}" ] \
      || die "the rendered body does not parse back: $field (given '$given', parsed '${!ref}')"
  done

  severity_label_ensure "review:$severity" "$colour" "$desc"
  triage="$(triage_label_for needs-triage)"
  triage_label_ensure "$triage"
  category_label_ensure "$category"
  # The title carries no severity prefix: the label holds it, where triage
  # can change it, and the title reads as an issue.
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body" "review:$severity" "$triage" "$category"
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
  implement="$HANDOFF_DIR/$(handoff_file_for review)"
  plan="$HANDOFF_DIR/$(handoff_file_for spec)"
  [ -f "$implement" ] || die "implement handoff not found: $implement"
  [ -f "$plan" ] || die "plan handoff not found: $plan"

  local record n entry tag deviations="" waiting="" filed="" rejected=""
  entries_append deviations "$implement" '## Deviations'
  for record in "$REVIEW_DIR"/iteration-*.md; do
    # Only the records themselves: the reports and known-items files beside
    # them carry a suffix after the number.
    n="${record##*/iteration-}"; n="${n%.md}"
    case "$n" in ''|*[!0-9]*) continue ;; esac
    if [ "$((10#$n))" -gt "$boundary" ]; then
      entries_append waiting "$record" '## Waiting to be filed' "waiting to be filed, iteration $n"
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
  entries_append rejected "$plan" '## Rejected alternatives' 'rejected alternative'
  known_items_write "$path" "$deviations" "$waiting$filed$rejected"
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
      mkdir -p "$REVIEW_DIR" || die "cannot create the review directory $REVIEW_DIR"
      printf '%s/iteration-%02d.md\n' "$REVIEW_DIR" "$n"
      ;;
    file)
      require_state
      review_file "$@"
      ;;
    ready)
      require_state
      local pr
      require_pr pr
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      gh_or_die --hint "the flow stays in review" "mark PR #$pr ready" \
        adapter_pr_ready "$pr"
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
      # refs_err is pr_refs_read's error output, which ci ignores.
      # shellcheck disable=SC2034
      local pr started slept=0 elapsed=0 res verdict refs_err head_oid head_ref base_ref pushed push_age=0
      local commits="" no_ci=0
      require_poll_knobs ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL
      require_pr pr
      started="$(date +%s)"
      # Two clocks: the timeout counts from this call, the grace from the push.
      # By the time the loop ends the fixer's last push is usually minutes old,
      # and a CI that has not registered a check in that time is not about to.
      # `push_age` is how long before this call the push landed; a PR that will
      # not say what its head is, or a head with no reflog entry, leaves it at zero,
      # and the grace counts from the call as it always did.
      if pr_refs_read "$pr" head_oid head_ref base_ref commits refs_err; then
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
    known-items)
      require_state
      review_known_items "$@"
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
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|known-items|ci|rerun|ready|terminal|retire)" ;;
  esac
}
