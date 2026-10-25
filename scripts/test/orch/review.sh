# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# pushed_head <branch> [<seconds ago>]: pushes HEAD to <branch> on a bare
# origin and prints its SHA; given an age, backdates the push's reflog entry.
pushed_head() {
  local bare sha
  bare="$(mktemp -d)"
  git init -q --bare "$bare"
  bare_origin "$bare"
  git update-ref -d "refs/remotes/origin/$1" 2>/dev/null || true
  git push -q origin "HEAD:refs/heads/$1" 2>/dev/null
  sha="$(git rev-parse HEAD)"
  if [ -n "${2:-}" ]; then
    git update-ref -d "refs/remotes/origin/$1"
    GIT_COMMITTER_DATE="@$(( $(date +%s) - $2 )) +0000" \
      git update-ref -m 'update by push' "refs/remotes/origin/$1" "$sha"
  fi
  printf '%s\n' "$sha"
}

# review_ci_flow <slug>: a review ci section's starting point - review_flow
# <slug> with PR #7 recorded in state and open from topic onto main in the
# store-backed fake (fake_github), the base tip's one check run as the CI
# evidence that keeps the grace, and the CI knobs short: ORCH_CI_GRACE=0.3,
# ORCH_CI_TIMEOUT=1, ORCH_CI_INTERVAL=0.05. A section that calls it ends with
# its teardown, review_ci_restore.
review_ci_flow() {
  review_flow "$1"
  state_fixture pr 7
  export ORCH_CI_GRACE=0.3 ORCH_CI_TIMEOUT=1 ORCH_CI_INTERVAL=0.05
  fake_github
  fake_pr 7 open topic main
  fake_check_run main
}

# review_ci_restore: review_ci_flow's teardown - restore_suite_env with the
# CI knobs review_ci_flow set.
review_ci_restore() {
  restore_suite_env ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL
}

# fake_pr_head <n> <sha> [commit...]: seeds PR #n's head SHA and its commits,
# oldest first - given none, the head alone.
fake_pr_head() {
  local d="$ORCH_GH_FAKE_STORE/prs/$1"
  printf '%s\n' "$2" >"$d/head_oid"
  shift 2
  rm -f "$d/commits"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$d/commits"
}

# fake_required_checks <branch> <context>...: classic branch protection on the
# branch, requiring the checks named.
fake_required_checks() {
  local b="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/protection"
  printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/protection/$b"
}

# fake_rules <branch> <type>...: the rules the repo's rulesets apply to the
# branch, by type.
fake_rules() {
  local b="$1"
  shift
  mkdir -p "$ORCH_GH_FAKE_STORE/rules"
  printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/rules/$b"
}

# fake_check_run <ref> / fake_status <ref>: the ref - a SHA, or a branch name
# for its tip - has a check run, or a commit status. fake_unreadable_ref <ref>:
# both reads of the ref fail.
fake_check_run() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/check_runs"; }
fake_status() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/statuses"; }
fake_unreadable_ref() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/unreadable_refs"; }

# fake_ci_reset: no checks scripted, nothing required, no rules, and no ref
# with a check run or status - every CI signal absent.
fake_ci_reset() {
  rm -rf "$ORCH_GH_FAKE_STORE/checks" "$ORCH_GH_FAKE_STORE/protection" "$ORCH_GH_FAKE_STORE/rules" \
    "$ORCH_GH_FAKE_STORE/check_runs" "$ORCH_GH_FAKE_STORE/statuses" "$ORCH_GH_FAKE_STORE/unreadable_refs"
}

# fake_reruns: the Actions run ids rerun, read back, space-separated, in order.
fake_reruns() { tr '\n' ' ' 2>/dev/null <"$ORCH_GH_FAKE_STORE/reruns" | sed 's/ $//'; }

# parts_with <flag> [<value>]: sets args to review file's parts - its --flag
# value pairs - with <flag>'s value replaced by <value>, in place, or, given no
# value, with <flag> and its value dropped. An empty <value> still replaces.
parts_with() {
  local i=0
  args=()
  while [ "$i" -lt "${#parts[@]}" ]; do
    if [ "${parts[$i]}" != "$1" ]; then
      args+=("${parts[$i]}" "${parts[$((i + 1))]}")
    elif [ $# -gt 1 ]; then
      args+=("$1" "$2")
    fi
    i=$((i + 2))
  done
}

# --- review ready's pointer to /orchestrator:finish (#727) --------------------
# review ready's stdout stays the PR number alone everywhere; in a side
# checkout it points the human at /orchestrator:finish on stderr, for after the
# PR merges.
echo
echo "review ready's finish pointer"
sc_clone
fake_github
fake_offline
rr="$(sc_add rr)"
fake_online
(cd "$rr" && orch_gh_failing init rr-flow >/dev/null && state_fixture phase review && state_fixture pr 70)
fake_pr 70 open orch/rr-flow main
fake_pr_draft 70
err_f="$(mktemp)"
out="$(cd "$rr" && orch_gh_failing review ready 2>"$err_f")"; st=$?
assert_status "review ready succeeds in a side checkout" "$st" 0
assert_eq "printing only the PR number on stdout" "$out" "70"
assert_contains "pointing at /orchestrator:finish on stderr" "$(cat "$err_f")" "/orchestrator:finish"

# A ticket worktree carrying a copied marker is no side checkout (#1110).
marked="$(marked_ticket_worktree 43)"
(cd "$marked" && orch_gh_failing init rr-ticket >/dev/null && state_fixture phase review && state_fixture pr 72)
fake_pr 72 open orch/rr-ticket main
fake_pr_draft 72
out="$(cd "$marked" && orch_gh_failing review ready 2>"$err_f")"; st=$?
assert_status "review ready succeeds in a ticket worktree carrying a copied marker" "$st" 0
assert_not_contains "with no side-checkout warning" "$(cat "$err_f")" "side checkout"
git worktree remove --force "$marked"
git branch -q -D main--t43

orch_gh_failing init rr-main >/dev/null
state_fixture phase review; state_fixture pr 71
fake_pr 71 open orch/rr-main main
fake_pr_draft 71
out="$(orch_gh_failing review ready 2>"$err_f")"; st=$?
assert_status "review ready succeeds in the main checkout" "$st" 0
assert_eq "printing only the PR number on stdout there too" "$out" "71"
assert_not_contains "with no /orchestrator:finish pointer" "$(cat "$err_f")" "/orchestrator:finish"
restore_suite_env

# --- review begin -----------------------------------------------------------
# The bound lives in bash precisely so a long session cannot re-remember five as
# six, so what matters here is the refusal, not the counting. The budget is the
# human's number, read from state; a flow that never wrote one runs the default.
echo
echo "review begin"
healthy_repo

# --- review path ------------------------------------------------------------
# One flow, one trail: the records sit flat under review/, numbered on across
# every loop the flow runs, so nothing is ever moved aside.
echo
echo "review path"
fresh_flow reviewpath
state_fixture iteration 5
assert_contains "files the record flat under review/" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
assert_contains "zero-pads an explicit iteration" \
  "$("$ORCH" review path 2)" "/review/iteration-02.md"
assert_eq "creates the directory it names" \
  "$(on_disk .orchestrator/review)" "present"
out="$("$ORCH" review path nope 2>&1)"; st=$?
assert_status "rejects an iteration that is not a number" "$st" 1
restore_suite_env

# --- the multi-loop machinery is gone ---------------------------------------
# Every loop reads the implement handoff, whatever the flow has been through.
# The old entry points are removed rather than deprecated, so each one has to
# fail loudly: a session that found a path back into them would be driving a
# loop nothing else understands.
echo
echo "the multi-loop machinery is gone"
fresh_flow multiloop
state_fixture phase review
state_fixture iteration 7
assert_contains "review reads the implement handoff however far in the flow is" \
  "$("$ORCH" handoff path review)" "03-implement.md"
state_fixture iteration 5

out="$("$ORCH" handoff path review-next 2>&1)"; st=$?
assert_status "there is no handoff for a next loop to read" "$st" 1
assert_eq "and no path printed for a caller to use" \
  "$(printf '%s\n' "$out" | grep -c '/handoff/')" "0"

writeln '## PR' '#3' >.orchestrator/handoff/04-review.md
out="$("$ORCH" handoff validate .orchestrator/handoff/04-review.md 2>&1)"; st=$?
assert_status "a review handoff is not a handoff validate knows" "$st" 1
assert_contains "and it says so rather than passing it empty" "$out" "unknown handoff file"
rm .orchestrator/handoff/04-review.md

out="$("$ORCH" review loop-next 2>&1)"; st=$?
assert_status "review loop-next is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown review op"
restore_suite_env

# --- review file ------------------------------------------------------------

# Filing is mechanism: which labels, what title, which body, and the number
# printed back. What reached GitHub is the assertion - a finding filed with no
# severity label is a finding triage never finds.
#
# Labels and issue both go to the store-backed fake (fake_github) and are read
# back from its store - neither ever spawns a subprocess. The real operations
# are pinned in "gh adapter contract" after this section.
#
# review file takes the body's parts and renders it, so each part is a flag
# and the body is asserted byte for byte, read back with a sentinel so its
# trailing newlines count.
echo
echo "review file"
fresh_flow reviewfile
fake_github
finding="$(mktemp)"
printf 'The reviewer said this.\n\nIt spans two paragraphs.\n\n\n\n' >"$finding"
pr_url=https://github.com/o/r/pull/7
parts=(--axis standards --finding-file "$finding" --severity-reason "Misleads a reader"
  --location scripts/a.sh:12 --sha abc1234 --pr "$pr_url" --why "found in the final iteration")
: >"$GH_FIXTURE/env.log"
tab="$(printf '\t')"
fake_label review:major ffffff "An older description"
fake_label needs-triage 000000 "The repo's own"
fake_next_issue 17
out="$("$ORCH" review file major "Comment drifted from the code" "${parts[@]}" 2>&1)"; st=$?
assert_status "files a major" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "17"
assert_contains "making the severity label ours over one that exists already" "$(fake_labels)" \
  "review:major${tab}d93f0b${tab}Review finding filed at major severity"
assert_contains "and leaving the repo's own triage label as the repo has it" "$(fake_labels)" \
  "needs-triage${tab}000000${tab}The repo's own"
assert_contains "and creating the category label the repo lacks" "$(fake_labels)" \
  "enhancement${tab}a2eeef${tab}New feature or request"
assert_eq "passes the title through unprefixed" "$(fake_title_of 17)" "Comment drifted from the code"
assert_eq "labels the issue with the severity, needs-triage and the category" \
  "$(fake_labels_of 17)" "enhancement needs-triage review:major "
want="$(printf '%s\n' 'The reviewer said this.' '' 'It spans two paragraphs.' '' \
  '**Axis:** Standards' '' \
  '**Severity:** major - Misleads a reader' '' \
  '**Location:** `scripts/a.sh:12` at abc1234' '' \
  "**PR:** $pr_url" '' \
  '**Why not fixed in the loop:** found in the final iteration' ''; printf x)"
assert_eq "renders every part into the body, in the closer's layout, the finding's trailing newlines stripped" \
  "$(fake_body_of 17; printf x)" "$want"
assert_not_contains "with no spec question line when none was given" "$(fake_body_of 17)" "**Spec question:**"
assert_eq "neither the labels nor the issue create reached a real gh subprocess" \
  "$(gh_calls)" "0"

# The flags come in any order; a spec question adds its line, last; a line
# range files; a padded value files trimmed; and the axis is accepted in any
# case, rendered capitalised.
fake_github
fake_next_issue 18
out="$("$ORCH" review file major "Misses a criterion" --why "  it is a spec question  " \
  --spec-question " Should it archive first? " --pr "$pr_url" --sha abc1234 \
  --location scripts/a.sh:12-20 --severity-reason "Misses a criterion - the second one" \
  --finding-file "$finding" --axis SPEC 2>&1)"; st=$?
assert_status "files with the flags in any order" "$st" 0
want="$(printf '%s\n' 'The reviewer said this.' '' 'It spans two paragraphs.' '' \
  '**Axis:** Spec' '' \
  '**Severity:** major - Misses a criterion - the second one' '' \
  '**Location:** `scripts/a.sh:12-20` at abc1234' '' \
  "**PR:** $pr_url" '' \
  '**Why not fixed in the loop:** it is a spec question' '' \
  '**Spec question:** Should it archive first?' ''; printf x)"
assert_eq "adding the spec question line, a line range and trimmed values, the axis capitalised" \
  "$(fake_body_of 18; printf x)" "$want"
assert_eq "--axis SPEC files as bug" "$(fake_labels_of 18)" "bug needs-triage review:major "

# A suite-cost finding - the `grew` major the driver raises from
# `suite-cost check` - names the suite as a whole: axis suite-cost, location
# the literal suite, with no line. It files as an enhancement.
fake_github
fake_next_issue 19
out="$("$ORCH" review file major "Suite cost grew 25%" --axis suite-cost --finding-file "$finding" \
  --severity-reason "Suite cost grew past the threshold" --location suite --sha abc1234 \
  --pr "$pr_url" --why "found in the final iteration" 2>&1)"; st=$?
assert_status "files a suite-cost finding located at the suite" "$st" 0
assert_eq "printing its number" "$out" "19"
want="$(printf '%s\n' 'The reviewer said this.' '' 'It spans two paragraphs.' '' \
  '**Axis:** Suite-cost' '' \
  '**Severity:** major - Suite cost grew past the threshold' '' \
  '**Location:** `suite` at abc1234' '' \
  "**PR:** $pr_url" '' \
  '**Why not fixed in the loop:** found in the final iteration' ''; printf x)"
assert_eq "rendering the suite-cost axis and the suite as its location" \
  "$(fake_body_of 19; printf x)" "$want"
assert_eq "--axis suite-cost files as enhancement" "$(fake_labels_of 19)" "enhancement needs-triage review:major "

# A sha in upper-case hex files as given.
fake_github
parts_with --sha ABC1234
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "files an upper-case hex sha" "$st" 0
assert_contains "naming it in the location line" "$(fake_body_of "$out")" \
  '**Location:** `scripts/a.sh:12` at ABC1234'

fake_github
out="$("$ORCH" review file nit "Rename it" "${parts[@]}" 2>&1)"; st=$?
assert_status "files a nit" "$st" 0
assert_contains "under the nit label" "$(fake_labels_of "$out")" "review:nit "
assert_contains "creating it" "$(fake_labels)" "review:nit${tab}c5def5${tab}Review finding filed at nit severity"
assert_contains "and the triage label a repo without one lacks" "$(fake_labels)" \
  "needs-triage${tab}e4e669${tab}Not yet triaged"
assert_contains "the severity line naming the nit" "$(fake_body_of "$out")" "**Severity:** nit - Misleads a reader"

# The category is the axis's: a Spec finding is a defect against what was
# asked for, a Standards finding an improvement on how it was built.
parts_with --axis spec
fake_github
out="$("$ORCH" review file major "Misses a criterion" "${args[@]}" 2>&1)"; st=$?
assert_status "files a Spec finding" "$st" 0
assert_eq "labelled bug, and not enhancement" "$(fake_labels_of "$out")" "bug needs-triage review:major "
assert_contains "creating bug with GitHub's default colour and description" \
  "$(fake_labels)" "bug${tab}d73a4a${tab}Something isn't working"
assert_not_contains "and no enhancement label" "$(fake_labels)" "enhancement${tab}"

fake_github
parts_with --axis Standards
out="$("$ORCH" review file nit "Rename it" "${args[@]}" 2>&1)"; st=$?
assert_status "files a Standards finding, whatever the axis's case" "$st" 0
assert_eq "labelled enhancement, and not bug" "$(fake_labels_of "$out")" "enhancement needs-triage review:nit "
assert_contains "creating enhancement with GitHub's default colour and description" \
  "$(fake_labels)" "enhancement${tab}a2eeef${tab}New feature or request"

# A category label that cannot be created - most often because the repo has
# it already - does not stop the filing, and the repo's own is left as it is.
fake_github
fake_label bug 123456 "The repo's own bug"
fake_label enhancement 654321 "The repo's own enhancement"
fake_next_issue 23
parts_with --axis spec
out="$("$ORCH" review file major "Misses a criterion" "${args[@]}" 2>&1)"; st=$?
assert_status "a category label the repo has already does not stop filing" "$st" 0
assert_eq "the number is still printed" "$out" "23"
assert_contains "and the issue still carries the label" "$(fake_labels_of 23)" "bug "
assert_contains "never over the repo's own bug label" "$(fake_labels)" "bug${tab}123456${tab}The repo's own bug"
out="$("$ORCH" review file nit "Rename it" "${parts[@]}" 2>&1)"; st=$?
assert_contains "nor over its own enhancement label" "$(fake_labels)" \
  "enhancement${tab}654321${tab}The repo's own enhancement"

fake_github
fake_fail adapter_label_create "HTTP 502: Bad Gateway"
fake_next_issue 24
parts_with --axis spec
out="$("$ORCH" review file major "Misses a criterion" "${args[@]}" 2>&1)"; st=$?
assert_status "nor does one gh fails to create for another reason" "$st" 0
assert_eq "the number alone printed, gh's error kept out of it" "$out" "24"
fake_unfail

# Every refusal comes before any write: the fake's label and issue stores are
# as they were. The store starts empty, so "as they were" is also "nothing".
fake_github
# shellcheck disable=SC2016 # expanded by the inner bash
sevs="$(bash -c 'source "$1" && printf "%s" "${FILED_SEVERITIES// /|}"' _ "$ORCH")"
# shellcheck disable=SC2016 # expanded by the inner bash
axes="$(bash -c 'source "$1" && printf "%s" "${FILED_AXES// /|}"' _ "$ORCH")"
usage="orch: usage: orch.sh review file <$sevs> <title> --axis <$axes> --finding-file <f> --severity-reason <r> --location <<file>:<line>|suite> --sha <sha> --pr <url> --why <reason> [--spec-question <q>]"
before="$(fake_snapshot)"
# each case is one line, label|drop|add: parts less the flag named by drop and
# its value, then add, word-split on spaces, so no value in add may hold one
while IFS='|' read -r label drop add; do
  parts_with "$drop"
  # shellcheck disable=SC2206
  [ -z "$add" ] || args+=($add)
  out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
  assert_status "refuses $label" "$st" 1
  assert_eq "with the usage line ($label)" "$out" "$usage"
  assert_eq "leaving the stores as they were ($label)" "$(fake_snapshot)" "$before"
done <<'CASES'
a missing --axis|--axis|
a missing --finding-file|--finding-file|
a missing --severity-reason|--severity-reason|
a missing --location|--location|
a missing --sha|--sha|
a missing --pr|--pr|
a missing --why|--why|
a repeated flag||--sha def5678
an unknown flag||--frobnicate x
a flag with no value||--spec-question
the old --body-file||--body-file x
CASES
for flag in --axis --finding-file --severity-reason --location --sha --pr --why --spec-question; do
  # --spec-question is not in parts, so its empty value is appended instead
  if [ "$flag" = --spec-question ]; then args=("${parts[@]}" "$flag" ""); else parts_with "$flag" "   "; fi
  out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
  assert_status "refuses an empty $flag" "$st" 1
  assert_eq "with the usage line (empty $flag)" "$out" "$usage"
  assert_eq "leaving the stores as they were (empty $flag)" "$(fake_snapshot)" "$before"
done
out="$("$ORCH" review file major "Title" --axis spec "$finding" 2>&1)"; st=$?
assert_status "insists on its flags rather than guessing a positional" "$st" 1
assert_eq "with the usage line" "$out" "$usage"

parts_with --axis style
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses an unknown axis" "$st" 1
assert_eq "in exactly these words" "$out" "orch: not a review axis: style (want spec or standards or suite-cost)"
for axis in $(bash -c 'source "$1" && printf "%s\n" "$FILED_AXES"' _ "$ORCH"); do
  assert_contains "naming review axis $axis, read from FILED_AXES" "$out" "$axis"
done
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

out="$("$ORCH" review file blocking "Wrong" "${parts[@]}" 2>&1)"; st=$?
assert_status "refuses a blocking severity - the loop fixes those" "$st" 1
assert_contains "naming what it accepts" "$out" "major"
assert_contains "saying blocking is always fixed, never filed" "$out" "blocking is always fixed, never filed"
assert_not_contains "without claiming the loop fixes blocking only" "$out" "the loop fixes blocking)"
for sev in $(bash -c 'source "$1" && printf "%s\n" "$FILED_SEVERITIES"' _ "$ORCH"); do
  assert_contains "naming filed severity $sev, read from FILED_SEVERITIES" "$out" "$sev"
done
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

out="$("$ORCH" review file major "" "${parts[@]}" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1
assert_eq "saying so" "$out" "orch: the title is empty"
assert_eq "before anything reaches gh" "$(fake_snapshot)" "$before"

parts_with --finding-file /nonexistent/finding.md
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a finding file that does not exist" "$st" 1
assert_eq "naming it" "$out" "orch: finding file not found: /nonexistent/finding.md"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

blank="$(mktemp)"
printf '  \n\t\n\n' >"$blank"
parts_with --finding-file "$blank"
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a finding file holding only whitespace" "$st" 1
assert_eq "naming it" "$out" "orch: finding file is empty: $blank"
: >"$blank"
parts_with --finding-file "$blank"
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "and an empty one" "$st" 1
assert_eq "naming it too" "$out" "orch: finding file is empty: $blank"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

for loc in scripts/a.sh scripts/a.sh: :12 scripts/a.sh:x scripts/a.sh:12- scripts/a.sh:-3 scripts/a.sh:1-2-3; do
  parts_with --location "$loc"
  out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
  assert_status "refuses the location '$loc'" "$st" 1
  assert_eq "naming it and what it wants ($loc)" "$out" \
    "orch: not a location: $loc (want <file>:<line>, <file>:<start>-<end> or suite)"
done
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

parts_with --sha HEAD
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a sha that is not hex" "$st" 1
assert_eq "naming the sha, not a field of the round trip" "$out" \
  "orch: not a sha: HEAD (want a hex commit SHA)"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

# The round trip: a body that does not parse back to its parts is refused,
# naming the first field that did not.
parts_with --why "$(printf 'one line\nand another')"
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a value holding a newline" "$st" 1
assert_eq "naming the field the round trip lost" "$out" \
  "orch: the rendered body does not parse back: why (given 'one line
and another', parsed 'one line')"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

quoting="$(mktemp)"
printf 'It reads the line\n**Axis:** Spec\nas the axis.\n' >"$quoting"
parts_with --finding-file "$quoting"
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a finding text quoting a labelled line at a line's start" "$st" 1
assert_eq "naming the field it shadows" "$out" \
  "orch: the rendered body does not parse back: axis (given 'standards', parsed 'spec')"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

parts_with --location 'scripts/a`b.sh:12'
out="$("$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a location file holding a backtick" "$st" 1
assert_eq "naming the file field" "$out" \
  "orch: the rendered body does not parse back: file (given 'scripts/a\`b.sh', parsed 'b.sh')"
assert_eq "and writes nothing" "$(fake_snapshot)" "$before"

assert_gh_dies "a gh that will not create the issue fails the command" adapter_issue_create "$GH_502" 1 \
  "orch: gh could not create the issue: HTTP 502: Bad Gateway" \
  "$ORCH" review file major "Title" "${parts[@]}"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"
assert_eq "filing no issue" "$(fake_issues)" ""
assert_contains "and the labels already ensured stay" "$(fake_labels)" \
  "review:major${tab}d93f0b${tab}Review finding filed at major severity"

fake_github
assert_gh_dies "a gh that will not create the label fails it too" adapter_label_upsert "$GH_502" 1 \
  "orch: gh could not create label review:major: HTTP 502: Bad Gateway" \
  "$ORCH" review file major "Title" "${parts[@]}"
assert_eq "filing no issue" "$(fake_issues)" ""

# The rendered body's temp file is gone on every exit.
fake_github
empty_tmp="$(mktemp -d)"
out="$(TMPDIR="$empty_tmp" "$ORCH" review file major "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "files with TMPDIR an empty directory" "$st" 0
assert_eq "leaving it empty after a success" "$(ls -A "$empty_tmp")" ""
parts_with --finding-file "$quoting"
out="$(TMPDIR="$empty_tmp" "$ORCH" review file major "Title" "${args[@]}" 2>&1)"; st=$?
assert_status "refuses a body that does not parse back" "$st" 1
assert_eq "leaving it empty after a round-trip refusal" "$(ls -A "$empty_tmp")" ""
fake_fail adapter_issue_create "$GH_502"
out="$(TMPDIR="$empty_tmp" "$ORCH" review file major "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "dies on a gh failure" "$st" 1
assert_eq "leaving it empty after a gh failure" "$(ls -A "$empty_tmp")" ""
fake_unfail

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from: a repo that renamed it must not get a second label the name
# this plugin happens to know.
fake_github
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" review file nit "Rename it" "${parts[@]}" 2>&1)"; st=$?
assert_status "files under a renamed triage label" "$st" 0
assert_contains "creating the repo's name for it" "$(fake_labels)" "triage me${tab}e4e669${tab}Not yet triaged"
assert_eq "and applying it rather than the canonical one" \
  "$(fake_labels_of "$out")" "enhancement review:nit triage me "
assert_not_contains "nor creating it" "$(fake_labels)" "needs-triage"
labels_doc docs/agents/triage-labels.md
restore_suite_env

# --- review ready -----------------------------------------------------------
# Marking the PR ready and recording the flow as done are one operation, because
# either half alone is a lie: a `done` flow over a draft PR, or a PR promoted
# out of draft by a flow that still thinks it is reviewing.
#
# Goes through the store-backed fake (fake_github) - the fixture gh's log stays
# empty across both calls, proving neither reaches a real gh subprocess. The
# real operation is pinned in "gh adapter contract".
echo
echo "review ready"
review_flow reviewready
state_fixture pr 7
fake_github
fake_pr 7 open orch/1-reviewready main
fake_pr_draft 7
: >"$GH_FIXTURE/env.log"
assert_gh_dies "fails when GitHub will not mark the PR ready" adapter_pr_ready "$GH_502" 1 \
  "orch: gh could not mark PR #7 ready: HTTP 502: Bad Gateway - the flow stays in review" \
  "$ORCH" review ready
assert_eq "and leaves the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
assert_eq "with the PR still a draft" "$(fake_pr_draft_of 7)" "yes"
assert_gh_dies "fails when gh fails silently too" adapter_pr_ready '' 1 \
  "orch: gh could not mark PR #7 ready: gh gave no reason - the flow stays in review" \
  "$ORCH" review ready
assert_eq "the phase still review" "$("$ORCH" state get phase)" "review"
assert_eq "and the PR still a draft" "$(fake_pr_draft_of 7)" "yes"
"$ORCH" review ready >/dev/null
assert_eq "records the flow as done once the PR is ready" "$("$ORCH" state get phase)" "done"
assert_eq "the PR no longer a draft" "$(fake_pr_draft_of 7)" "no"
assert_eq "and neither call ever reached a real gh subprocess" "$(gh_calls)" "0"
state_fixture phase review
restore_suite_env

# --- review ci --------------------------------------------------------------
# The classification is what decides whether a PR may be marked ready, so each
# of the four answers is asserted for its exit status as well as its word.
#
# Every GitHub read here goes through the store-backed fake: fake_checks
# scripts the checks each scope answers, call by call, and the base tip's one
# check run (fake_check_run main) is the CI evidence that keeps the grace,
# until a case below says otherwise. How the real operations read gh -
# --required, exit 8 for pending, an answer jq cannot read - is pinned by
# their contract tests in "gh adapter contract".
echo
echo "review ci"
review_ci_flow reviewci
: >"$GH_FIXTURE/env.log"
fake_checks 7 all green
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "green checks let the loop finish" "$st" 0
assert_first_line "and say so in one word" "$out" "green"
assert_eq "the checks call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_checks 7 all failing
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a failing check stops the loop" "$st" 1
assert_first_line "classified as failing" "$out" "failing"
assert_contains "names the check that failed" "$out" "build"
assert_eq "and not the ones that passed" "$(printf '%s\n' "$out" | grep -c 'lint')" "0"

# A cancelled run is not a run that passed, and it is never going to report. It
# classifies as failing, which is also the arm that offers the flake rerun - the
# right remedy for a check that was killed rather than one that judged the
# change.
fake_checks 7 all cancel
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a cancelled check stops the loop too" "$st" 1
assert_first_line "classified as failing rather than waited on" "$out" "failing"
assert_contains "naming the check that was cancelled" "$out" "build"

# Requiring CI in a repo that has none would make the plugin unusable in its own
# repo, which has none.
fake_checks 7 all none
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo with no checks at all is not thereby failing" "$st" 0
assert_first_line "classified as none" "$out" "none"

# The grace period is the whole reason `none` is not concluded on the first
# answer: this is the CI-having repo that would otherwise be called CI-less. It
# is spent on the *required* probe, because gh reports "no required checks"
# whether the repo requires nothing or requires something that has not landed
# yet. Widening to every check on the commit before the grace is out is how an
# unrelated green check gets mistaken for a required one that never arrived - so
# the unfiltered answer here is `failing`, and a green result proves it was
# never consulted. The grace is set well clear of a whole-second wall-clock
# tick, so what the test proves is the second answer winning rather than how
# fast the first one came.
fake_checks 7 required none green
fake_checks 7 all failing
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "a required check that has not registered yet is waited for" "$out" "green"
assert_status "and the loop finishes on the answer it waited for" "$st" 0

# Where branch protection names required checks, those are the checks that
# matter - and a failure outside them is not the flow's business.
fake_checks 7 required green
fake_checks 7 all failing
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "required checks decide it where branch protection names them" "$st" 0
assert_first_line "so the unfiltered answer is never asked for" "$out" "green"

# ...and where it names none, the answer is every check on the commit, but only
# once the grace has run out.
fake_checks 7 required none
fake_checks 7 all green
out="$(ORCH_CI_GRACE=0.2 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo that requires nothing falls back to every check" "$st" 0
assert_first_line "reading the commit's own checks for its answer" "$out" "green"

fake_checks 7 all boom
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "an API that will not answer stops the loop" "$st" 1
assert_first_line "classified as unreachable" "$out" "unreachable"
assert_contains "carrying the reason it could not be asked" "$out" "dial tcp"

# doctor's "an unreachable API is a warn" rule was written for a read-only
# diagnostic. Here the outcome is an action, so an answer that never arrived
# cannot be treated as a green one.
fake_checks 7 all pending
out="$(ORCH_CI_TIMEOUT=0.2 "$ORCH" review ci 2>&1)"; st=$?
assert_status "checks still pending at the cap stop the loop" "$st" 1
assert_first_line "rather than being read as green" "$out" "unreachable"
assert_contains "and it says the wait ran out" "$out" "still pending"

# The clocks are compared with awk, which compares a number against a
# non-numeric string as strings - so a mistyped knob makes every comparison
# true, and the one command written to be bounded polls GitHub until something
# else kills it. The leash is what makes this assertable: without the fix the
# command never returns on its own.
out="$(ORCH_CI_GRACE=oops timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a grace that is not a number stops the command, not the clock" "$st" 1
assert_contains "naming the knob it could not read" "$out" "ORCH_CI_GRACE"

# A zero interval passes for a number and still defeats the bound: `sleep 0`
# returns at once and never advances the clock, so the loop polls as fast as
# GitHub answers for the whole timeout.
out="$(ORCH_CI_INTERVAL=0 timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "an interval of zero is refused rather than busy-polled" "$st" 1
assert_contains "saying the interval has to be above zero" "$out" "greater than zero"

# The one direction this classifier must never fail in: an answer nobody could
# read is not an answer that there is nothing to read. adapter_pr_checks fails
# on one (its contract test), and that failure's reason is what review ci says.
fake_fail adapter_pr_checks "gh pr checks answered with something jq could not read"
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "checks nobody could read stop the loop" "$st" 1
assert_first_line "rather than passing as a repo with no checks" "$out" "unreachable"
assert_contains "saying what it could not read" "$out" "could not read"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
review_ci_restore

# --- the grace counts from the push (issue #475) ---
# review ci runs when the loop ends, usually minutes after the fixer's last
# push, so a grace counted from the call is a minute paid for nothing. It
# counts from the push instead: the newest reflog entry of the head branch's
# remote-tracking ref that set it to the PR's head SHA. The anchor is real git
# - a push to a local bare remote, its entry rewritten under a past committer
# date - while the PR's head and branch come from the fake adapter.
review_ci_flow gracepush
head_sha="$(pushed_head topic 3600)"
fake_pr_head 7 "$head_sha"

# With the push an hour old, the grace is long spent: the first answer of
# nothing required widens at once, and nothing at all reported is `none`. A
# grace counted from the call would wait for the green the second answer holds.
fake_checks 7 required none green
fake_checks 7 all none
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "an old push with nothing reported is none without waiting the grace" "$out" "none"
assert_status "and none still lets the loop finish" "$st" 0

# The grace is measured from that one push alone: an entry for another SHA
# says nothing about when this head arrived, so the grace counts from the call.
fake_checks 7 required none green
fake_pr_head 7 1111111111111111111111111111111111111111
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "with no reflog entry for the head SHA, the grace counts from the call" "$out" "green"
fake_pr_head 7 "$head_sha"

# A PR whose head branch has no remote-tracking ref at all is the same case.
fake_checks 7 required none green
fake_pr 7 open elsewhere main
fake_pr_head 7 "$head_sha"
out="$(ORCH_CI_GRACE=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "nor with no remote-tracking ref for the head branch" "$out" "green"
fake_pr 7 open topic main
fake_pr_head 7 "$head_sha"

# The timeout keeps counting from the call: an hour-old push is no reason to
# give up on checks that are still running now.
fake_checks 7 required pending green
out="$(ORCH_CI_TIMEOUT=5 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "the timeout counts from the call even when the push is old" "$out" "green"

# A push younger than the grace still waits: nothing required yet, and the
# green that arrives within the grace wins over the unfiltered failure. The
# push's 60s age and the 600s grace are the #476 section's, explained there.
head_sha="$(pushed_head topic 60)"
fake_pr_head 7 "$head_sha"
fake_checks 7 required none green
fake_checks 7 all failing
out="$(ORCH_CI_GRACE=600 timeout 30 "$ORCH" review ci 2>&1)"; st=$?
assert_first_line "a push younger than the grace still waits it before widening" "$out" "green"
review_ci_restore

# --- the grace is skipped on no evidence of CI (issue #476) ---
# Zero checks straight after a push is ambiguous only where the repo might have
# CI. With no workflow in the head, nothing required on the base, and no check
# or status on an earlier PR commit or the base tip, there is nothing to wait
# for, and `none` arrives without the grace. The push is recorded as 60s old
# and each case runs under a 600s grace, far above that age, so whether the
# grace is waited never depends on how fast the machine reached the case:
# `none`, then `green`, on the required probe tells the two apart, green
# meaning the grace was waited and none that it was skipped. The green arrives
# on the second probe, so the long grace costs no time, and `timeout` turns a
# grace that never ends into a failed assertion, not a hang.
# ci_absent: every CI signal absent, and the checks scripted that way - the
# store each case below turns one signal back on in.
ci_absent() {
  fake_ci_reset
  fake_checks 7 required none green
  fake_checks 7 all none
}
# no_ci <expected first line> <name>: one review ci call, on PR #7 as the store
# holds it - by default, a single-commit PR whose head is head_sha.
no_ci() {
  out="$(ORCH_CI_GRACE=600 timeout 30 "$ORCH" review ci 2>&1)"; st=$?
  assert_first_line "$2" "$out" "$1"
}
review_ci_flow nocievidence
head_sha="$(pushed_head topic 60)"
fake_pr_head 7 "$head_sha"
ci_absent
no_ci none "with no evidence of CI anywhere, none arrives without the grace"
assert_status "and lets the loop finish" "$st" 0
assert_contains "saying it found no CI signals" "$out" "no CI signals found"
assert_contains "naming the signals it looked for" "$out" "no workflow files in the head"

# The other path to none: the grace waited and ran out with nothing reported.
# The head is a commit never pushed, so with no reflog entry the suite's short
# grace counts from the call and is really waited, not spent by the aged push.
unpushed_sha="$(git commit-tree "HEAD^{tree}" -p HEAD -m 'not pushed')"
fake_pr_head 7 "$unpushed_sha"
fake_ci_reset
fake_check_run main
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_first_line "evidence of CI keeps the grace, and none still comes after it" "$out" "none"
assert_contains "saying the grace ran out" "$out" "grace ran out"
assert_eq "and not that no signals were found" "$(printf '%s\n' "$out" | grep -c 'no CI signals')" "0"
fake_pr_head 7 "$head_sha"

# The pre-check replaces only the wait: the unfiltered probe still runs, so a
# check already reported on the head gives its verdict, not none.
ci_absent; fake_checks 7 all failing
no_ci failing "with no evidence of CI, a check reported on the head still decides it"
ci_absent; fake_checks 7 all green
no_ci green "and a green one reads green"

# Each signal alone keeps the grace.
wf_index="$(mktemp -u)"
GIT_INDEX_FILE="$wf_index" git read-tree HEAD
GIT_INDEX_FILE="$wf_index" git update-index --add --cacheinfo \
  "100644,$(printf 'on: push\n' | git hash-object -w --stdin),.github/workflows/ci.yml"
wf_sha="$(git commit-tree "$(GIT_INDEX_FILE="$wf_index" git write-tree)" -p HEAD -m 'add CI')"
fake_pr_head 7 "$wf_sha"
ci_absent
no_ci green "a workflow file in the head's tree keeps the grace"
# git ls-tree reads its pathspec from the current directory: from a
# subdirectory, the workflow must still be seen, not read as absent.
mkdir -p wf-subdir
ci_absent
out="$(cd wf-subdir && ORCH_CI_GRACE=600 timeout 30 "$ORCH" review ci 2>&1)"
assert_first_line "and so does one seen from a subdirectory" "$out" "green"
rmdir wf-subdir
fake_pr_head 7 "$head_sha"
ci_absent; fake_required_checks main build
no_ci green "required checks from classic branch protection keep the grace"
ci_absent; fake_rules main required_status_checks
no_ci green "required checks from a ruleset keep the grace"
ci_absent; fake_rules main deletion
no_ci none "a ruleset that requires no checks is not evidence of CI"
# Signals longer than a pipe holds (#987), each with its match first: a check
# that pipes the listing into a quiet grep sees the match while the writer
# still blocks on later lines, takes SIGPIPE and, under pipefail, reads the
# signal as absent - no CI - on every run.
big_rules=(required_status_checks)
for i in $(seq -w 1 10000); do big_rules+=("filler_rule_type_$i"); done
ci_absent; fake_rules main "${big_rules[@]}"
no_ci green "a ruleset requiring checks keeps the grace, among about 200 KiB of other rules"
wf_index="$(mktemp -u)"
GIT_INDEX_FILE="$wf_index" git read-tree HEAD
wf_blob="$(printf 'on: push\n' | git hash-object -w --stdin)"
{
  printf '100644 %s\t.github/workflows/a.yml\n' "$wf_blob"
  for i in $(seq -w 1 10000); do
    printf '100644 %s\t.github/workflows/b-filler-entry-%s.txt\n' "$wf_blob" "$i"
  done
} | GIT_INDEX_FILE="$wf_index" git update-index --index-info
big_wf_sha="$(git commit-tree "$(GIT_INDEX_FILE="$wf_index" git write-tree)" -p HEAD -m 'add CI among many')"
rm -f "$wf_index"
fake_pr_head 7 "$big_wf_sha"
ci_absent
no_ci green "a workflow file listed first keeps the grace, among about 200 KiB of other entries"
fake_pr_head 7 "$head_sha"
earlier=2222222222222222222222222222222222222222
fake_pr_head 7 "$head_sha" "$earlier" "$head_sha"
ci_absent; fake_check_run "$earlier"
no_ci green "a check-run on an earlier PR commit keeps the grace"
ci_absent; fake_status "$earlier"
no_ci green "a commit status on an earlier PR commit keeps the grace"
fake_pr_head 7 "$head_sha"
ci_absent; fake_check_run main
no_ci green "a check-run on the base tip keeps the grace"
ci_absent; fake_status main
no_ci green "a commit status on the base tip keeps the grace"

# A single-commit PR has no earlier commit: the head's own checks are what the
# probes read, not evidence the grace is worth waiting for.
ci_absent; fake_check_run "$head_sha"; fake_status "$head_sha"
no_ci none "a single-commit PR has no earlier-commit signal"

# A signal that cannot be read counts as CI - a protection read GitHub refused
# with anything but its 404 for an unprotected branch included, which
# adapter_branch_required_checks fails on (its contract test).
ci_absent; fake_fail adapter_branch_required_checks "gh: Not Found (HTTP 404)"
no_ci green "a protection read that fails keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
ci_absent; fake_fail adapter_branch_rules
no_ci green "a ruleset read that fails keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
ci_absent; fake_unreadable_ref main
no_ci green "a base-tip read that fails keeps the grace"
fake_pr_head 7 "$head_sha" "$earlier" "$head_sha"
ci_absent; fake_unreadable_ref "$earlier"
no_ci green "an earlier commit's read that fails keeps the grace"
fake_pr_head 7 3333333333333333333333333333333333333333
ci_absent
no_ci green "a head this clone does not hold keeps the grace"
fake_pr_head 7 "$head_sha"
ci_absent; fake_fail adapter_pr_refs
no_ci green "a PR that will not say what its head is keeps the grace"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

state_fixture pr null
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "refuses to classify checks on a PR that does not exist yet" "$st" 1
# require_pr dies inside a command substitution, so what stops the command is
# `set -e` on the assignment rather than the exit itself. Asserting the message
# is what would catch the guard degrading into an empty PR number.
assert_contains "saying which phase was supposed to open it" "$out" "the implement phase opens it"
review_ci_restore

# --- review rerun -------------------------------------------------------------
# The flow's one flake rerun (#525): the failed jobs of the Actions run behind
# the PR's first failed or cancelled check, taken from that check's link. Exit 0
# is the only answer that spends the rerun; 1 is "no Actions run to rerun" and
# 2 everything else. Stateless: the PR is named on the command line.
echo
echo "review rerun"
new_repo >/dev/null
fake_github
fake_checks 7 all failing
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a failed Actions check is rerun" "$st" 0
assert_eq "printing the run it reran" "$out" "4242"
assert_eq "the run id taken from the failing check's link" "$(fake_reruns)" "4242"

rm -f "$ORCH_GH_FAKE_STORE/reruns"
fake_checks 7 all cancel
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a cancelled Actions check is rerun too" "$st" 0
assert_eq "from the cancelled check's run" "$(fake_reruns)" "5150"

rm -f "$ORCH_GH_FAKE_STORE/reruns"
fake_checks 7 all external
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a first failing check that is no Actions run has nothing to rerun" "$st" 1
assert_eq "warning that the check is no Actions run" "$out" \
  "orch: check ext-ci on PR #7 is not a GitHub Actions run - nothing to rerun"
assert_eq "and reruns nothing, not even a later Actions run" "$(fake_reruns)" ""

fake_checks 7 all badrunid
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a failing check linking no Actions run id has nothing to rerun" "$st" 1
assert_eq "warning that the check links no run id" "$out" \
  "orch: check build on PR #7 links no Actions run id - nothing to rerun"
assert_eq "and reruns nothing" "$(fake_reruns)" ""

fake_checks 7 all boom
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a GitHub that cannot be read is exit 2" "$st" 2
assert_contains "carrying gh's reason" "$out" "dial tcp"
fake_checks 7 all green
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no failed or cancelled check is exit 2" "$st" 2
assert_contains "saying there is nothing failed to rerun" "$out" "no failed or cancelled check"
fake_checks 7 all none
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no checks at all is exit 2" "$st" 2
assert_eq "saying there are no checks to rerun, with gh's own line" "$out" \
  "orch: PR #7 has no checks to rerun: no checks reported on the 'topic' branch"
fake_checks 7 all empty
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "an empty list of checks is exit 2" "$st" 2
assert_eq "saying no checks were reported when gh said nothing" "$out" \
  "orch: PR #7 has no checks to rerun: no checks reported"
fake_checks 7 all failing
fake_fail_times adapter_pr_checks 1
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a checks read that fails silently is exit 2" "$st" 2
assert_eq "ending in gh gave no reason, never a bare colon" "$out" \
  "orch: gh could not read the checks of PR #7: gh gave no reason"
fake_unfail
assert_gh_dies "a checks read that fails is exit 2" adapter_pr_checks "$GH_502" 2 \
  "orch: gh could not read the checks of PR #7: HTTP 502: Bad Gateway" \
  "$ORCH" review rerun 7
# The same silence from a read that succeeds is an answer, not a failure:
# no checks at all, so the death is the no-checks one, not the failed read's.
fake_checks 7 all empty
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a successful read with no checks is exit 2" "$st" 2
assert_eq "dying with no checks to rerun, not a failed read" "$out" \
  "orch: PR #7 has no checks to rerun: no checks reported"
fake_checks 7 all failing
fake_fail adapter_run_rerun "$(writeln "HTTP 403: Resource not accessible by integration" "see https://docs.github.com")"
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a rerun gh refuses is exit 2" "$st" 2
assert_eq "naming the run, with gh's first line only" "$out" \
  "orch: gh could not rerun the failed jobs of Actions run 4242: HTTP 403: Resource not accessible by integration"
fake_unfail
fake_fail_times adapter_run_rerun 1
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "a rerun gh refuses silently is exit 2" "$st" 2
assert_eq "ending in gh gave no reason" "$out" \
  "orch: gh could not rerun the failed jobs of Actions run 4242: gh gave no reason"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
out="$("$ORCH" review rerun 2>&1)"; st=$?
assert_status "no PR is a usage error, exit 2" "$st" 2
out="$("$ORCH" review rerun abc 2>&1)"; st=$?
assert_status "a PR that is not a number is a usage error, exit 2" "$st" 2
git remote remove origin
out="$("$ORCH" review rerun 7 2>&1)"; st=$?
assert_status "no repo to work on is exit 2, not the guard's 1" "$st" 2
assert_eq "dying with the repo remedy" "$out" \
  "orch: $repo_remedy"
assert_contains "help documents review rerun" "$("$ORCH" help)" "review rerun <pr>"
restore_suite_env

# --- review terminal ----------------------------------------------------
# The one classifier `review terminal` and doctor's check both read - none and
# pending need no iteration file at all, interrupted/ready/stop all do.
echo
echo "review terminal"
fresh_flow terminaltest

out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "no loop yet is not terminal" "$st" 1
assert_first_line "and classifies as none" "$out" "none"

state_fixture iteration 3
"$ORCH" state set budget 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "short of its budget is not terminal" "$st" 1
assert_first_line "and classifies as pending" "$out" "pending"

# A loop can stop before its budget - a failed base sync sends it straight to
# Termination - and the record it leaves says so. A mid-budget record with a
# terminal state classifies from it; one without stays pending.
mkdir -p .orchestrator/review
writeln '## Findings' 'None' >.orchestrator/review/iteration-03.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a mid-budget record with no Terminal state is not terminal" "$st" 1
assert_first_line "and still classifies as pending" "$out" "pending"
writeln '## Terminal state' 'stop - base sync failed.' >.orchestrator/review/iteration-03.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a stop recorded short of the budget is terminal" "$st" 0
assert_eq "classified as stop with its reason, not pending" "$out" \
  "$(printf 'stop\nbase sync failed.')"
rm .orchestrator/review/iteration-03.md

state_fixture iteration 5
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "at budget with no iteration record is not terminal" "$st" 1
assert_first_line "classified as interrupted, not pending" "$out" "interrupted"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a record with no Terminal state heading is still interrupted" "$st" 1
assert_first_line "not silently read as done" "$out" "interrupted"

writeln '## Terminal state' '' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "an empty Terminal state section is interrupted too" "$st" 1
assert_first_line "same as a missing one" "$out" "interrupted"

writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a ready heading is terminal" "$st" 0
assert_first_line "and classifies as ready" "$out" "ready"

# The driver writes `## CI` at termination, before the closer's `## Filed` and
# its own `## Terminal state`. Only the last is read: a CI answer never
# classifies a loop on its own.
writeln '## CI' 'failing' 'build: failed' '' '## Filed' 'None' '' \
  '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a CI section before Terminal state leaves it terminal" "$st" 0
assert_first_line "classified from Terminal state, not CI" "$out" "ready"

writeln '## CI' 'green' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a CI section with no Terminal state is not terminal" "$st" 1
assert_first_line "still classified as interrupted" "$out" "interrupted"

writeln '## Terminal state' 'stop' 'CI failed twice, flake rerun spent.' \
  >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a stop heading is terminal too" "$st" 0
assert_first_line "classified as stop" "$out" "stop"
assert_contains "carrying the recorded reason on the lines after it" \
  "$out" "CI failed twice, flake rerun spent."

# Per-reviewer report files sit beside the records under a suffixed name, and
# records are addressed only by their exact iteration-NN.md name - so a report
# never changes a classification, even one that reads like a record.
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-standards.md
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-spec.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "report files beside a stop record leave it terminal" "$st" 0
assert_first_line "still classified as stop, not read from a report" "$out" "stop"
assert_contains "review path still names the record, not a report" \
  "$("$ORCH" review path 5)" "/review/iteration-05.md"
rm .orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "report files with no record are not terminal" "$st" 1
assert_first_line "classified as interrupted" "$out" "interrupted"
assert_contains "and review path still names the missing record" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
rm .orchestrator/review/iteration-05-standards.md .orchestrator/review/iteration-05-spec.md

# A record written as ordinary markdown reads the way it was meant (#604):
# blank lines under the heading, whitespace around the first line, and a stop
# with its reason on the same line all classify, never as interrupted.
writeln '## Terminal state' '' 'stop' 'CI never ran on the reviewed head.' \
  >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a blank line under the heading still reads stop" "$st" 0
assert_first_line "classified as stop, not interrupted" "$out" "stop"
assert_eq "with the reason intact below it" \
  "$(printf '%s\n' "$out" | tail -n +2)" "CI never ran on the reviewed head."

writeln '## Terminal state' '   ' '' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace-only lines under the heading still read ready" "$st" 0
assert_first_line "classified as ready" "$out" "ready"

writeln '## Terminal state' '  ready  ' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace around ready is tolerated" "$st" 0
assert_eq "and prints the bare word" "$out" "ready"

writeln '## Terminal state' '  stop  ' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "whitespace around stop is tolerated" "$st" 0
assert_eq "and prints stop and its reason" "$out" "$(printf 'stop\nCI failed twice.')"

for line in 'stop - CI failed twice.' 'stop – CI failed twice.' 'stop — CI failed twice.' \
  'stop: CI failed twice.' 'stop:CI failed twice.' 'stop-CI failed twice.' \
  '  stop - CI failed twice.  '; do
  writeln '## Terminal state' "$line" 'The flake rerun is spent.' \
    >.orchestrator/review/iteration-05.md
  out="$("$ORCH" review terminal 2>&1)"; st=$?
  assert_status "'$line' on one line is stop" "$st" 0
  assert_eq "'$line' prints its reason first, then the lines below" "$out" \
    "$(printf 'stop\nCI failed twice.\nThe flake rerun is spent.')"
done

writeln '## Terminal state' 'stop -' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a separator with nothing after it is still stop" "$st" 0
assert_eq "with an empty reason" "$out" "stop"

writeln '## Terminal state' 'stop -' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a bare separator with a reason below is stop" "$st" 0
assert_eq "reading the reason from below" "$out" "$(printf 'stop\nCI failed twice.')"

writeln '## Terminal state' '   ' '	' >.orchestrator/review/iteration-05.md
out="$("$ORCH" review terminal 2>&1)"; st=$?
assert_status "a whitespace-only section is not terminal" "$st" 1
assert_first_line "and still classifies as interrupted" "$out" "interrupted"

for line in 'Stop' '**stop**' 'ready - all green' 'done' 'stopped' 'stop CI failed'; do
  writeln '## Terminal state' '' "$line" 'CI failed twice.' >.orchestrator/review/iteration-05.md
  out="$("$ORCH" review terminal 2>&1)"; st=$?
  assert_status "'$line' is not terminal" "$st" 1
  assert_first_line "'$line' classifies as malformed, not interrupted" "$out" "malformed"
  assert_contains "'$line' prints the expected shape" "$out" "expected: first line"
done

out="$("$ORCH" review terminal extra 2>&1)"; st=$?
assert_status "takes no arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review terminal"
restore_suite_env

# --- review resume ------------------------------------------------------------
# A loop whose session died mid-iteration resumes without spending budget
# (ADR-0054): the dead iteration's reports are cleared and it reruns under the
# same number, or its landed record sends the loop on.
echo
echo "review resume"
fresh_flow resumetest
resume_facts() {
  "$ORCH" state get iteration; "$ORCH" state get budget
  ls .orchestrator/review 2>/dev/null
  git status --porcelain
}
mkdir -p .orchestrator/review
state_fixture iteration 2
"$ORCH" state set budget 5
writeln '## Findings' 'None' >.orchestrator/review/iteration-01.md
writeln 'old' >.orchestrator/review/iteration-02-spec.md
writeln 'old' >.orchestrator/review/iteration-02-standards.md
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "resume with no record for the last iteration succeeds" "$st" 0
assert_eq "printing rerun with that iteration" "$out" "rerun 2"
assert_eq "clearing the dead iteration's reports" \
  "$(ls .orchestrator/review)" "iteration-01.md"
assert_eq "keeping iteration" "$("$ORCH" state get iteration)" "2"
assert_eq "and budget" "$("$ORCH" state get budget)" "5"

writeln '## Findings' 'None' >.orchestrator/review/iteration-02.md
writeln 'kept' >.orchestrator/review/iteration-02-spec.md
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "resume with a record lacking a Terminal state succeeds" "$st" 0
assert_eq "printing next while pending" "$out" "next"
assert_eq "and leaving that iteration's reports" \
  "$(cat .orchestrator/review/iteration-02-spec.md)" "kept"

"$ORCH" state set budget 2
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "resume when interrupted succeeds" "$st" 0
assert_eq "printing terminate" "$out" "terminate"
assert_eq "keeping budget" "$("$ORCH" state get budget)" "2"

writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-02.md
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "a finished loop has nothing to resume" "$st" 1
assert_contains "saying so" "$out" "nothing to resume"

# A failed clear dies naming the report, leaving iteration and budget.
rm -f .orchestrator/review/iteration-02.md .orchestrator/review/iteration-02-spec.md
mkdir -p .orchestrator/review/iteration-02-spec.md/sub
"$ORCH" state set budget 5
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "a failed clear dies with exit 1" "$st" 1
assert_contains "naming the report" "$out" "could not clear the dead iteration's reviewer report"
assert_eq "leaving iteration" "$("$ORCH" state get iteration)" "2"
rm -rf .orchestrator/review/iteration-02-spec.md

# The discard rule: refused in an interactive main checkout, applied beside one.
writeln 'old' >.orchestrator/review/iteration-02-spec.md
git add -A >/dev/null 2>&1; git commit -qm base >/dev/null 2>&1
echo hand >>README.md
before="$(resume_facts)"
out="$("$ORCH" review resume 2>&1)"; st=$?
assert_status "a dirty tree in an interactive main checkout is refused" "$st" 1
assert_contains "naming the discard command" "$out" "reset --hard"
assert_eq "touching nothing" "$(resume_facts)" "$before"

sc_clone
side="$(sc_add sideresume)"
(
  cd "$side" || exit 1
  "$ORCH" init sideresume >/dev/null
  state_fixture iteration 1
  "$ORCH" state set budget 3
  echo hand >>README.md
  out="$("$ORCH" review resume 2>&1)"; st=$?
  assert_status "a dirty tree in a side checkout is discarded" "$st" 0
  assert_eq "and the iteration reruns" "$out" "rerun 1"
  assert_eq "leaving it clean" "$(git status --porcelain)" ""

  # a dead base sync's merge in progress
  leave_merge_in_progress clash-a
  assert_eq "(fixture) a merge is in progress" \
    "$(merge_state)" "merging"
  out="$("$ORCH" review resume 2>&1)"; st=$?
  assert_status "a merge in progress in a side checkout is aborted" "$st" 0
  assert_eq "leaving no merge in progress" \
    "$(merge_state)" "none"
  assert_eq "and a clean tree" "$(git status --porcelain)" ""

  # a dead rebase in progress
  leave_rebase_in_progress clash-r
  assert_eq "(fixture) a rebase is in progress" \
    "$(rebase_state)" "rebasing"
  out="$("$ORCH" review resume 2>&1)"; st=$?
  assert_status "a rebase in progress in a side checkout is aborted" "$st" 0
  assert_eq "leaving no rebase in progress" \
    "$(rebase_state)" "none"

  # a finished loop has nothing to resume: refused before anything is discarded
  mkdir -p .orchestrator/review
  writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-01.md
  echo hand >>README.md
  out="$("$ORCH" review resume 2>&1)"; st=$?
  assert_status "nothing to resume in a side checkout exits 1" "$st" 1
  assert_contains "saying so" "$out" "nothing to resume"
  assert_eq "and discards no edits" "$(git status --porcelain README.md)" " M README.md"
)
restore_suite_env

# --- review retire -------------------------------------------------------
# The archive test's directory-move assertions are the direct template.
echo
echo "review retire"
fake_flow retiretest

out="$("$ORCH" review retire 1)"
assert_contains "a no-op with nothing to move still prints the destination" \
  "$out" "/review/pre-redo-1"
assert_eq "and creates no directory for it" \
  "$(on_disk .orchestrator/review/pre-redo-1)" "absent"

mkdir -p .orchestrator/review
: >.orchestrator/review/iteration-01.md
: >.orchestrator/review/iteration-02.md
out="$("$ORCH" review retire 1)"
assert_contains "moves every iteration record into pre-redo-N" \
  "$out" "/review/pre-redo-1"
assert_eq "iteration-01 landed under it" \
  "$(on_disk .orchestrator/review/pre-redo-1/iteration-01.md)" "present"
assert_eq "iteration-02 landed under it too" \
  "$(on_disk .orchestrator/review/pre-redo-1/iteration-02.md)" "present"
assert_eq "and the flat trail is empty afterwards" \
  "$(on_disk .orchestrator/review/iteration-01.md)" "absent"

# The per-reviewer report files ride along with their records.
: >.orchestrator/review/iteration-03.md
: >.orchestrator/review/iteration-03-standards.md
: >.orchestrator/review/iteration-03-spec.md
"$ORCH" review retire 2 >/dev/null
for f in iteration-03.md iteration-03-standards.md iteration-03-spec.md; do
  assert_eq "$f landed in pre-redo-2" \
    "$(on_disk ".orchestrator/review/pre-redo-2/$f")" "present"
  assert_eq "$f left the flat trail" \
    "$(on_disk ".orchestrator/review/$f")" "absent"
done

: >.orchestrator/review/iteration-01.md
out="$("$ORCH" review retire 1 2>&1)"; st=$?
assert_status "dies rather than collide with an existing pre-redo-N" "$st" 1
assert_contains "naming the directory" "$out" "pre-redo-1"

out="$("$ORCH" review retire nope 2>&1)"; st=$?
assert_status "refuses a non-numeric redo count" "$st" 1

out="$("$ORCH" review retire 2>&1)"; st=$?
assert_status "refuses with no argument" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh review retire"
restore_suite_env

# --- review known-items -----------------------------------------------------
# The loop's known-items file, built mechanically from the records and the
# handoffs. Only what lands in the file, and the exit status, are checked.
echo
echo "review known-items"
review_flow knownitems
mkdir -p .orchestrator/review
writeln '## Decisions' 'Placeholder.' '' '## Rejected alternatives' '' \
  '- Driver-side matching made cheaper' '  - the waste is the reviewers'"'"' output' \
  'A bare line of its own' '' '## Constraints' 'None' \
  >.orchestrator/handoff/01-plan.md
writeln '## PR' '#7' '## Deviations' '' '- Built the key from the slug,' \
  '  not from the member' '- None of the cache was kept' '## Verification' 'ok' \
  >.orchestrator/handoff/03-implement.md
writeln '# Review iteration 1' '## Waiting to be filed' '' \
  '- Standards/nit: `a.sh:3` an old loop nit - final iteration' \
  '## Filed' '' '- #41 nit: a.sh:3 old loop nit' \
  >.orchestrator/review/iteration-01.md
writeln '# Review iteration 2' '## Waiting to be filed' 'None' \
  '## Filed' 'None.' >.orchestrator/review/iteration-02.md
writeln '# Review iteration 3' '## Waiting to be filed' '' \
  '- Spec/major: `b.sh:10` the parser is duplicated - needs a decision' \
  '- Standards/nit: - the name reads oddly - not mechanical' \
  '## Filed' '' '- #99 major: b.sh:1 never read below the boundary' \
  >.orchestrator/review/iteration-03.md
: >.orchestrator/review/iteration-03-spec.md
writeln '## Waiting to be filed' '- Standards/nit: `x.sh:1` a report, not a record - x' \
  >.orchestrator/review/iteration-03-standards.md
writeln 'stale content' >known.md
"$ORCH" review known-items known.md 2; st=$?
assert_status "builds the file" "$st" 0
assert_eq "with every source under its heading and its tag, overwriting the old file" \
  "$(cat known.md)" "$(writeln '## Deviations' \
    '- Built the key from the slug, not from the member' \
    '- None of the cache was kept' \
    '## Known items' \
    '- Spec/major: `b.sh:10` the parser is duplicated - needs a decision - waiting to be filed, iteration 03' \
    '- Standards/nit: - the name reads oddly - not mechanical - waiting to be filed, iteration 03' \
    '- #41 nit: a.sh:3 old loop nit - filed #41' \
    "- Driver-side matching made cheaper - the waste is the reviewers' output - rejected alternative" \
    '- A bare line of its own - rejected alternative')"

"$ORCH" review known-items known.md 3 >/dev/null; st=$?
assert_status "builds at a boundary with no record above it" "$st" 0
assert_not_contains "nothing is waiting to be filed then" "$(cat known.md)" "waiting to be filed"
assert_contains "and every record at or below it contributes Filed" \
  "$(cat known.md)" "- #99 major: b.sh:1 never read below the boundary - filed #99"

writeln '## Rejected alternatives' 'None.' >.orchestrator/handoff/01-plan.md
writeln '## Deviations' '- None' >.orchestrator/handoff/03-implement.md
rm .orchestrator/review/iteration-0[13].md
"$ORCH" review known-items known.md 0 >/dev/null; st=$?
assert_status "builds from sources that are all None" "$st" 0
assert_eq "and both headings read None." "$(cat known.md)" \
  "$(writeln '## Deviations' 'None.' '## Known items' 'None.')"

writeln 'kept' >known.md
for args in "known.md" "known.md two" "known.md -1"; do
  # shellcheck disable=SC2086 # split on purpose: each case is a word list
  out="$("$ORCH" review known-items $args 2>&1)"; st=$?
  assert_status "refuses boundary args '$args'" "$st" 1
  assert_contains "with an orch: message for '$args'" "$out" "orch: "
done
assert_eq "and leaves the existing file untouched" "$(cat known.md)" "kept"
for f in 03-implement.md 01-plan.md; do
  mv ".orchestrator/handoff/$f" "$f.bak"
  out="$("$ORCH" review known-items fresh.md 0 2>&1)"; st=$?
  assert_status "refuses with no $f" "$st" 1
  assert_contains "naming it" "$out" "$f"
  assert_eq "writing no file without $f" "$(on_disk fresh.md)" "absent"
  mv "$f.bak" ".orchestrator/handoff/$f"
done
rm .orchestrator/state.json
out="$("$ORCH" review known-items fresh.md 0 2>&1)"; st=$?
assert_status "refuses with no flow state" "$st" 1
assert_contains "with an orch: message" "$out" "orch: no active flow"
assert_eq "writing no file" "$(on_disk fresh.md)" "absent"
assert_contains "orch.sh help lists review known-items" "$("$ORCH" help)" "review known-items <path> <loop boundary>"
restore_suite_env

# --- review ready in an autopilot flow (#1457) --------------------------------
# The label moves to orch:done and the claim is released once the PR is ready.
echo
echo "review ready in an autopilot flow"
review_flow autopilot-ready
state_fixture issue 7
state_fixture pr 9
fake_github
fake_pr 9 open
fake_issue 7 open ready-for-agent orch:review orch:running
fake_claim_seed 7
out="$(ORCH_AUTOPILOT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "review ready in autopilot succeeds" "$st" 0
assert_eq "moving the label to orch:done" "$(fake_labels_of 7)" "orch:done ready-for-agent "
assert_eq "releasing the claim" "$(fake_claim_held 7)" free

# a failure partway leaves the claim held and names the writes that landed
fake_issue 7 open ready-for-agent orch:review orch:running
state_fixture phase review
fake_claim_seed 7
fake_fail adapter_claim_delete "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "a failed claim delete dies" "$st" 1
assert_contains "naming the claim ref" "$out" "delete the claim ref"
assert_contains "and the writes that landed" "$out" "marked PR #9 ready, moved the phase label to orch:done, recorded phase done, removed orch:running"
assert_eq "the claim is still held" "$(fake_claim_held 7)" held
fake_unfail
fake_issue 7 open ready-for-agent orch:review orch:running
state_fixture phase review
fake_fail adapter_issue_relabel "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "a failed label move dies" "$st" 1
assert_contains "naming the PR write that landed" "$out" "writes that landed: marked PR #9 ready;"
assert_eq "recording no phase" "$("$ORCH" state get phase)" "review"
assert_eq "the claim is still held after it" "$(fake_claim_held 7)" held
fake_unfail
restore_suite_env

# --- review known-items in an autopilot flow (#1457) --------------------------
# The plan and implement handoffs are comments there, fetched and read as files.
echo
echo "review known-items in an autopilot flow"
review_flow autopilot-known
state_fixture issue 7
fake_github
fake_issue 7 open ready-for-agent orch:review orch:running
mkdir -p .orchestrator/review
out="$(ORCH_AUTOPILOT=1 "$ORCH" review known-items known.md 0 2>&1)"; st=$?
assert_status "with no handoff comment it dies" "$st" 1
assert_contains "naming the missing comment" "$out" "no 03-implement handoff comment"
rm -rf .orchestrator/handoff
printf '## Decisions\nNone\n\n## Rejected alternatives\n\n- Polling the PR\n  - too slow\n' >plan.md
printf '## PR\n#7\n## Deviations\n\n- Kept the cache\n## Verification\nok\n' >impl.md
fake_comment 7 o 2026-01-01T00:00:00Z "$(printf '<!-- orch:handoff 01-plan -->\n'; cat plan.md)"
fake_comment 7 o 2026-01-02T00:00:00Z "$(printf '<!-- orch:handoff 03-implement -->\n'; cat impl.md)"
ORCH_AUTOPILOT=1 "$ORCH" review known-items known.md 0 >/dev/null 2>&1; st=$?
assert_status "with the comments posted it builds the file" "$st" 0
assert_contains "carrying the implement comment's deviation" "$(cat known.md)" "- Kept the cache"
assert_contains "and the plan comment's rejected alternative" "$(cat known.md)" "- Polling the PR - too slow - rejected alternative"
restore_suite_env

# --- review standards (#1532) -------------------------------------------------
# The standards documents both reviewers read, resolved mechanically: only
# what the one printed line says is checked, on fixture repos.
echo
echo "review standards"
new_repo >/dev/null
assert_eq "a repo with no standards document prints none" \
  "$("$ORCH" review standards)" "Standards: none"
out_dir="$(mktemp -d)"; : >"$out_dir/out.md"
mkdir -p docs/agents docs/deep
: >docs/agents/c.md; : >docs/deep/third.md; : >CONTRIBUTING.md
# Each refused mention names a file that would exist in the repo were its
# filter to fail: the path clamped at the root, the absolute path or the URL
# read as relative.
mkdir -p "$(basename "$out_dir")" etc docs/agents/etc docs/agents/https:/example.com
: >"$(basename "$out_dir")/out.md"; : >etc/x.md; : >docs/agents/etc/x.md
: >docs/agents/https:/example.com/README.md
writeln '# claude' 'See `docs/agents/a.md` and [the guide](docs/agents/missing.md).' \
  'Also `AGENTS.md`, `CONTRIBUTING.md#develop` and `docs/agents/` itself.' >CLAUDE.md
writeln '# agents' 'Read [c](docs/agents/c.md#section) first.' >AGENTS.md
writeln '# a' 'Then [b](b.md#top), `CONTRIBUTING.md` again,' \
  "[out](../../../$(basename "$out_dir")/out.md), [abs](/etc/x.md)," \
  '[url](https://example.com/README.md), `/etc/x.md` and `docs/agents/gone.md`.' \
  >docs/agents/a.md
writeln '# b' 'A third hop: [third](../deep/third.md), `docs/deep/third.md`.' >docs/agents/b.md
assert_eq "both root agent files, then first-hop then second-hop mentions, each once, no third hop, joined by ', '" \
  "$("$ORCH" review standards)" \
  "Standards: CLAUDE.md, AGENTS.md, docs/agents/a.md, CONTRIBUTING.md, docs/agents/c.md, docs/agents/b.md"
rm AGENTS.md
writeln '# claude' 'Nothing to follow.' >CLAUDE.md
assert_eq "only CLAUDE.md is listed when AGENTS.md is missing" \
  "$("$ORCH" review standards)" "Standards: CLAUDE.md"
rm CLAUDE.md
writeln '# contributing' 'See [the standards](docs/agents/a.md).' >CONTRIBUTING.md
writeln '# coding' 'Plain.' >CODING_STANDARDS.md
assert_eq "with no root agent file, CODING_STANDARDS.md then CONTRIBUTING.md, followed the same two hops" \
  "$("$ORCH" review standards)" \
  "Standards: CODING_STANDARDS.md, CONTRIBUTING.md, docs/agents/a.md, docs/agents/b.md"
out="$("$ORCH" review standards extra 2>&1)"; st=$?
assert_status "refuses an argument" "$st" 1
assert_contains "with its usage" "$out" "orch: usage: orch.sh review standards"
assert_contains "orch.sh help lists review standards" "$("$ORCH" help)" "review standards"
rm -rf "$out_dir"
restore_suite_env
