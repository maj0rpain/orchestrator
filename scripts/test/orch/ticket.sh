# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# ticket_fixture: a ticket section's starting point - a healthy_repo with the
# store-backed fake GitHub (fake_github), no issue in it yet. Leaves the global
# body (a ticket body file reading "Build the thing.") set, and whatever
# healthy_repo and fake_github export. A section that calls it ends with
# restore_suite_env.
ticket_fixture() {
  healthy_repo
  fake_github
  body="$(mktemp)"
  writeln 'Build the thing.' >"$body"
}

# fake_blockers_of <n>: #n's blockers read back from the store, sorted by
# number, space-separated - nothing for none.
fake_blockers_of() { sort -n "$ORCH_GH_FAKE_STORE/blocked_by/$1" 2>/dev/null | paste -sd ' ' -; }

# --- ticket publish -----------------------------------------------------
# The one place the ticket-breakdown feature files a ticket and writes its
# sub-issue link and blocked-by edges, so no skill prose ever calls `gh api`
# on these endpoints directly. Stateless like issue publish/pr publish: the
# store-backed fake is the GitHub it writes to, not orch.sh state.
echo
echo "ticket publish"
ticket_fixture
fake_issue 50 open
fake_next_issue 100
out="$("$ORCH" ticket publish 50 "First ticket" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the child's issue number and nothing else" "$out" "100"
assert_eq "passes the title through" "$(fake_title_of 100)" "First ticket"
assert_eq "sends the body file's contents" "$(fake_body_of 100)" "Build the thing."
assert_eq "applies ready-for-agent" "$(fake_labels_of 100)" "ready-for-agent "
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "links the child as 50's sub-issue" "$(fake_sub_issues_of 50)" "100"

out="$("$ORCH" ticket publish 50 "Second ticket" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "publishes a ticket blocked by the first" "$st" 0
assert_eq "prints the new child's number" "$out" "101"
assert_eq "adding its blocking edge" "$(fake_blockers_of 101)" "100"
assert_eq "the still-blocked ticket is not in the frontier" "$("$ORCH" ticket next 50)" "100"

# GitHub stores a blocking edge once no matter how many times it is asked
# for - a duplicate in --blocked-by must not make the readback's set
# permanently smaller than what was requested and fail verification for a
# link that is actually correct.
out="$("$ORCH" ticket publish 50 "Third ticket" "$body" --blocked-by 100,100 2>&1)"; st=$?
assert_status "a duplicate blocker in the list still verifies and succeeds" "$st" 0
assert_eq "adding the edge once" "$(fake_blockers_of 102)" "100"

before="$(fake_snapshot)"
out="$("$ORCH" ticket publish 50 "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" ticket publish 50 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" ticket publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by "abc,5" 2>&1)"; st=$?
assert_status "refuses a --blocked-by list with a non-numeric entry" "$st" 1
assert_contains "naming the whole list" "$out" "abc,5"

for list in "1,,2" ",5" "5,"; do
  out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by "$list" 2>&1)"; st=$?
  assert_status "refuses a --blocked-by list with an empty entry: $list" "$st" 1
  assert_contains "naming the whole list" "$out" "--blocked-by must be plain issue numbers, got: $list"
done

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 --blocked-by "" 2>&1)"; st=$?
assert_status "refuses a repeated --blocked-by, an empty one included" "$st" 1
assert_contains "with publish's usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 2>&1)"; st=$?
assert_status "refuses a --blocked-by with no value" "$st" 1
assert_contains "with publish's usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by $'5\n' 2>&1)"; st=$?
assert_status "refuses a --blocked-by with a trailing newline" "$st" 1
assert_contains "as not plain issue numbers" "$out" "--blocked-by must be plain issue numbers"

out="$("$ORCH" ticket publish 50 "Title" "$body" --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket publish"

out="$("$ORCH" ticket publish 50 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1
assert_eq "none of the refusals wrote anything to GitHub" "$(fake_snapshot)" "$before"

fake_fail adapter_issue_create
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not create the ticket"
fake_unfail

fake_fail adapter_sub_issue_link "HTTP 422: Sub issue may only have one parent"
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that refuses the sub-issue link fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not link ticket #103 as a sub-issue of #50"
assert_contains "with gh's reason" "$out" "HTTP 422"
fake_unfail

fake_fail adapter_blocker_add
out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "a gh that refuses the blocking edge fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not add a blocking edge from ticket #104 on #100"
fake_unfail

out="$("$ORCH" ticket publish 50 "Unblocked" "$body" --blocked-by "" 2>&1)"; st=$?
assert_status "an empty --blocked-by still publishes" "$st" 0
assert_eq "printing the child's number" "$out" "105"
assert_eq "with no blockers" "$(fake_blockers_of 105)" ""

# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_issue_create $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a failed ticket create still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not create the ticket: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_sub_issue_link $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a failed sub-issue link still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not link ticket #106 as a sub-issue of #50: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_blocker_add $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket publish 50 "Title" "$body" --blocked-by 100 2>&1)"; st=$?
assert_status "a failed blocking-edge write still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not add a blocking edge from ticket #107 on #100: HTTP 502: Bad Gateway"
fake_unfail
restore_suite_env

# --- ticket publish verify-then-die ---------------------------------------
# Immediately after publishing, ticket_publish reads the links back (ADR-0011).
# One retry on a mismatch; a second failure dies naming the ticket, rather
# than falling back to a text-based `Blocked by:` convention nothing
# downstream ever reads. fake_lag makes a readback answer stale (empty) for N
# calls.
echo
echo "ticket publish verify-then-die"
ticket_fixture
fake_issue 50 open
fake_next_issue 200
fake_lag adapter_sub_issues 1
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that only shows up on the retry still succeeds" "$st" 0
assert_eq "prints the child's number" "$out" "200"

fake_lag adapter_sub_issues 2
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issue link that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #201"
assert_contains "not a silent fallback" "$out" "did not verify"
assert_eq "the link it wrote stays, for a human to see" "$(fake_sub_issues_of 50)" "200 201"

fake_next_issue 300
blocker="$("$ORCH" ticket publish 50 "Blocker" "$body")"
fake_lag adapter_blockers 2
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blocking edge that never shows up dies rather than falling back" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #301"
assert_contains "not a silent fallback" "$out" "did not verify"

fake_fail_times adapter_blockers 1
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a transient blocked-by read failure is retried, not died on" "$st" 0
assert_eq "printing only the child's number, no stray stderr" "$out" "302"
assert_eq "its edge is in place" "$(fake_blockers_of 302)" "$blocker"

fake_fail adapter_blockers
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blocked-by read that fails twice dies" "$st" 1
assert_contains "with the links message" "$out" "gh could not read ticket #303's links: fake gh: adapter_blockers failed"
assert_not_contains "never calling a failed read a mismatch" "$out" "did not verify"
fake_unfail

# #843: a failed read-back is no mismatch. Each read path dies with gh's own
# first line, and only the second attempt decides which death it is.
fake_fail_after adapter_sub_issues 0 $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a sub-issues read-back that fails twice dies" "$st" 1
assert_contains "with gh's first line" "$out" "gh could not read ticket #304's links: HTTP 502: Bad Gateway"
assert_not_contains "and only its first line" "$out" "second line"
assert_not_contains "never calling a failed read a mismatch" "$out" "did not verify"
fake_unfail

fake_fail_after adapter_blockers 0 $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket publish 50 "Blocked" "$body" --blocked-by "$blocker" 2>&1)"; st=$?
assert_status "a blockers read-back that fails twice dies" "$st" 1
assert_contains "with gh's first line" "$out" "gh could not read ticket #305's links: HTTP 502: Bad Gateway"
assert_not_contains "and only its first line" "$out" "second line"
assert_not_contains "never calling a failed read a mismatch" "$out" "did not verify"
fake_unfail

fake_fail_after adapter_sub_issues 0 ''
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a silent read-back failure dies" "$st" 1
assert_contains "ending in gh gave no reason" "$out" "gh could not read ticket #306's links: gh gave no reason"
fake_unfail

fake_fail_times adapter_sub_issues 1 'HTTP 502: Bad Gateway'
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a transient sub-issues read failure then a good read succeeds" "$st" 0
assert_eq "printing only the child's number" "$out" "307"

fake_fail_times adapter_sub_issues 1 'HTTP 502: Bad Gateway'
fake_lag adapter_sub_issues 1
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a failed read then a mismatch dies" "$st" 1
assert_contains "with the verify message" "$out" \
  "ticket #308's sub-issue/blocked-by links did not verify - checked twice, both failed"
fake_unfail

fake_lag adapter_sub_issues 1
fake_fail_after adapter_sub_issues 1 'HTTP 502: Bad Gateway'
out="$("$ORCH" ticket publish 50 "Title" "$body" 2>&1)"; st=$?
assert_status "a mismatch then a failed read dies" "$st" 1
assert_contains "with the links message" "$out" "gh could not read ticket #309's links: HTTP 502: Bad Gateway"
assert_not_contains "not the verify message" "$out" "did not verify"
restore_suite_env

# --- ticket next -----------------------------------------------------------
# The parent's open sub-issues with zero open blockers, in the order they were
# published.
echo
echo "ticket next"
ticket_fixture
fake_issue 90 open
fake_next_issue 400
a="$("$ORCH" ticket publish 90 "A" "$body")"
b="$("$ORCH" ticket publish 90 "B" "$body" --blocked-by "$a")"
c="$("$ORCH" ticket publish 90 "C" "$body")"
out="$("$ORCH" ticket next 90)"
assert_eq "open-and-unblocked tickets only, in publish order, excluding the still-blocked one" \
  "$out" "$(printf '%s\n%s' "$a" "$c")"

"$ORCH" ticket close "$a" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed blocker drops out, freeing its dependent" "$out" "$(printf '%s\n%s' "$b" "$c")"

"$ORCH" ticket close "$c" >/dev/null
out="$("$ORCH" ticket next 90)"
assert_eq "a closed ticket itself is no longer in the frontier" "$out" "$b"

out="$("$ORCH" ticket next abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket next 2>&1)"; st=$?
assert_status "refuses with no parent" "$st" 1

fake_fail adapter_sub_issues
out="$("$ORCH" ticket next 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
restore_suite_env

# --- ticket list -------------------------------------------------------------
# Every sub-issue of <parent>, open or closed, one "<n> open|closed" line
# each in publish order - what a spec review reads to find the tickets its
# accepted edits touch, without calling a sub-issue endpoint itself.
echo
echo "ticket list"
ticket_fixture
fake_issue 90 open
fake_issue 91 open
fake_next_issue 450
a="$("$ORCH" ticket publish 90 "A" "$body")"
b="$("$ORCH" ticket publish 90 "B" "$body" --blocked-by "$a")"
"$ORCH" ticket close "$a" >/dev/null
out="$("$ORCH" ticket list 90)"
assert_eq "lists every sub-issue with its state, closed ones included, in publish order" \
  "$out" "$(printf '450 closed\n451 open')"

assert_eq "a parent with no sub-issues lists nothing" "$("$ORCH" ticket list 91)" ""

out="$("$ORCH" ticket list abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

fake_fail adapter_sub_issues
out="$("$ORCH" ticket list 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_sub_issues $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket list 90 2>&1)"; st=$?
assert_status "a failed sub-issue list still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not list sub-issues of #90: HTTP 502: Bad Gateway"
fake_unfail
restore_suite_env

# --- ticket close ------------------------------------------------------------
echo
echo "ticket close"
ticket_fixture
fake_issue 90 open
fake_next_issue 500
n="$("$ORCH" ticket publish 90 "Closeable" "$body")"
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "closes the ticket" "$st" 0
assert_eq "closing it" "$(fake_state_of "$n")" "CLOSED"
assert_eq "and it drops out of the parent's open sub-issues" \
  "$("$ORCH" ticket next 90)" ""

out="$("$ORCH" ticket close abc 2>&1)"; st=$?
assert_status "refuses a ticket that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

fake_fail adapter_issue_close
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "a gh that will not close the ticket fails" "$st" 1
assert_contains "naming what failed" "$out" "gh could not close ticket"
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_issue_close $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket close "$n" 2>&1)"; st=$?
assert_status "a failed close still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not close ticket #$n: HTTP 502: Bad Gateway"
fake_unfail
restore_suite_env

# --- ticket reset ------------------------------------------------------------
# Reopens every sub-issue of <parent> that is currently closed, and only
# those - what redo review needs before handing back to a fresh implement
# phase, whose frontier query would otherwise find nothing.
echo
echo "ticket reset"
ticket_fixture
fake_issue 90 open
fake_next_issue 600
x="$("$ORCH" ticket publish 90 "X" "$body")"
y="$("$ORCH" ticket publish 90 "Y" "$body")"
z="$("$ORCH" ticket publish 90 "Z" "$body")"
"$ORCH" ticket close "$x" >/dev/null
"$ORCH" ticket close "$y" >/dev/null
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "resets" "$st" 0
assert_eq "reopens exactly the tickets that were closed, and only those" \
  "$(fake_state_of "$x") $(fake_state_of "$y") $(fake_state_of "$z")" "OPEN OPEN OPEN"
assert_eq "in the frontier again" \
  "$("$ORCH" ticket next 90)" "$(printf '%s\n%s\n%s' "$x" "$y" "$z")"

out="$("$ORCH" ticket reset abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

"$ORCH" ticket close "$x" >/dev/null
fake_fail adapter_issue_reopen
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that will not reopen a ticket fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not reopen ticket #$x"
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_issue_reopen $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a failed reopen still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not reopen ticket #$x: HTTP 502: Bad Gateway"
fake_unfail

fake_fail adapter_sub_issues
out="$("$ORCH" ticket reset 90 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails the command" "$st" 1
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #90"
restore_suite_env

# --- ticket parent -----------------------------------------------------------
# The implementer's way to find its spec issue without calling the sub-issue
# endpoints itself: a sub-issue prints its parent's number, an issue with no
# parent prints nothing and still succeeds, and any gh failure is a failure.
echo
echo "ticket parent"
ticket_fixture
fake_issue 95 open
fake_next_issue 700
k="$("$ORCH" ticket publish 95 "Kid" "$body")"
out="$("$ORCH" ticket parent "$k" 2>&1)"; st=$?
assert_status "a sub-issue's parent lookup succeeds" "$st" 0
assert_eq "printing the parent's number" "$out" "95"

out="$("$ORCH" ticket parent 95 2>&1)"; st=$?
assert_status "an issue with no parent still succeeds" "$st" 0
assert_eq "printing nothing" "$out" ""

fake_fail adapter_issue_parent
errf="$(mktemp)"
out="$("$ORCH" ticket parent "$k" 2>"$errf")"; st=$?
assert_status "a gh that cannot read the issue fails the command" "$st" 1
assert_eq "naming what failed: exact stderr, gh's reason after it" "$(cat "$errf")" \
  "orch: gh could not read issue #$k's parent: fake gh: adapter_issue_parent failed"
assert_eq "printing nothing on stdout" "$out" ""
fake_unfail
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_issue_parent $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket parent "$k" 2>"$errf")"; st=$?
assert_status "a failed parent read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$(cat "$errf")" \
  "orch: gh could not read issue #$k's parent: HTTP 502: Bad Gateway"
assert_eq "still printing nothing on stdout" "$out" ""
fake_unfail
rm -f "$errf"

out="$("$ORCH" ticket parent abc 2>&1)"; st=$?
assert_status "refuses a ticket that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

out="$("$ORCH" ticket parent 2>&1)"; st=$?
assert_status "refuses with no ticket" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket parent"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket parent is in the usage text" "$out" "ticket parent <n>"
restore_suite_env

# --- ticket exists -----------------------------------------------------------
# "Already broken down" decided by structure, not prose: a blueprint's spec
# issue carries sub-issues, or - when its breakdown collapsed into it - a line
# that is exactly `## Ticket` outside a code fence.
echo
echo "ticket exists"
ticket_fixture
for p in 96 97 98 99; do fake_issue "$p" open; done
fake_next_issue 800
"$ORCH" ticket publish 96 "Open kid" "$body" >/dev/null
out="$("$ORCH" ticket exists 96 2>&1)"; st=$?
assert_status "an issue with a sub-issue has a breakdown" "$st" 0
assert_eq "printing sub-issues" "$out" "sub-issues"

closed_kid="$("$ORCH" ticket publish 97 "Closed kid" "$body")"
"$ORCH" ticket close "$closed_kid"
out="$("$ORCH" ticket exists 97 2>&1)"; st=$?
assert_status "an issue whose only sub-issue is closed still has a breakdown" "$st" 0
assert_eq "printing sub-issues" "$out" "sub-issues"

fake_issue_body 96 "$(writeln 'The spec.' '' '## Ticket' '' 'Build it.')"
out="$("$ORCH" ticket exists 96 2>&1)"; st=$?
assert_status "sub-issues and the heading together" "$st" 0
assert_eq "print sub-issues, which wins" "$out" "sub-issues"

fake_issue_body 98 "$(writeln 'The spec.' '' '## Ticket' '' 'Build it.')"
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a collapsed breakdown, the heading and no sub-issues" "$st" 0
assert_eq "prints collapsed" "$out" "collapsed"

fake_issue_body 99 'The spec, no breakdown yet.'
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "an issue with neither has no breakdown" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 "$(writeln 'The spec.' '' '### Ticket' '' 'Not the heading.')"
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a ### Ticket heading is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 'The spec mentions ## Ticket mid-line.'
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a mid-line ## Ticket is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

fake_issue_body 99 "$(writeln 'The spec quotes the format:' '```md' '## Ticket' '```')"
out="$("$ORCH" ticket exists 99 2>&1)"; st=$?
assert_status "a ## Ticket inside a code fence is not the collapse heading" "$st" 1
assert_eq "and prints nothing" "$out" ""

# An unreadable GitHub is not "no breakdown": a caller that read exit 1 as
# "neither" would publish a second breakdown, so a gh failure dies with 2.
fake_fail adapter_sub_issues
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues dies with 2, not no-breakdown's 1" "$st" 2
assert_contains "naming what failed" "$out" "gh could not list sub-issues of #98"
fake_unfail

fake_fail adapter_issue_body
out="$("$ORCH" ticket exists 98 2>&1)"; st=$?
assert_status "a gh that cannot read the issue dies with 2, not no-breakdown's 1" "$st" 2
assert_not_contains "never printing a verdict" "$out" "collapsed"
fake_unfail

# The same two failures pinned byte for byte: exact last line of stderr,
# exit 2, empty stdout (#347).
errf="$(mktemp)"
fake_fail adapter_sub_issues
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "unlistable sub-issues: exit 2" "$st" 2
assert_eq "unlistable sub-issues: exact stderr" "$(cat "$errf")" "orch: gh could not list sub-issues of #98: fake gh: adapter_sub_issues failed"
assert_eq "unlistable sub-issues: empty stdout" "$out" ""
fake_unfail

fake_fail adapter_issue_body
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "unreadable body: exit 2" "$st" 2
assert_eq "unreadable body: exact stderr" "$(cat "$errf")" "orch: gh could not read issue #98's body: fake gh: adapter_issue_body failed"
assert_eq "unreadable body: empty stdout" "$out" ""
fake_unfail

# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_sub_issues $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "a failed sub-issue list with a reason: exit 2" "$st" 2
assert_eq "carrying only gh's first line" "$(cat "$errf")" \
  "orch: gh could not list sub-issues of #98: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_issue_body $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "a failed body read with a reason: exit 2" "$st" 2
assert_eq "carrying only gh's first line" "$(cat "$errf")" \
  "orch: gh could not read issue #98's body: HTTP 502: Bad Gateway"
fake_unfail
fake_fail_times adapter_issue_body 9
out="$("$ORCH" ticket exists 98 2>"$errf")"; st=$?
assert_status "a silent failed body read: exit 2" "$st" 2
assert_eq "ending in gh gave no reason" "$(cat "$errf")" \
  "orch: gh could not read issue #98's body: gh gave no reason"
fake_unfail
rm -f "$errf"

# Bad input exits 2, never the meaningful "no breakdown" 1. The sub-issue
# read is armed to fail, so no `gh could not` text proves the refusal came
# before any GitHub read.
fake_fail adapter_sub_issues
out="$("$ORCH" ticket exists abc 2>&1)"; st=$?
assert_status "refuses a parent that is not a plain number" "$st" 2
assert_contains "naming it" "$out" "abc"
assert_not_contains "before any GitHub read" "$out" "gh could not"
fake_unfail

out="$("$ORCH" ticket exists 2>&1)"; st=$?
assert_status "refuses with no parent" "$st" 2
assert_contains "with a usage line" "$out" "usage: orch.sh ticket exists"

out="$("$ORCH" ticket exists 1 2 2>&1)"; st=$?
assert_status "refuses with two parents" "$st" 2
assert_contains "two parents: with a usage line" "$out" "usage: orch.sh ticket exists"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket exists is in the usage text" "$out" "ticket exists <parent>"
restore_suite_env

# --- ticket block ------------------------------------------------------------
# Adds native blocking edges to a published, open ticket, verifies them by
# reading the target's blocked-by list back (ADR-0011's verify-then-die), and
# rewrites the body's `## Blocked by` section to match. Idempotent, so a run
# that died part-way is finished by running it again.
echo
echo "ticket block"
ticket_fixture
for p in 96 97 199; do fake_issue "$p" open; done
fake_next_issue 800
ba="$("$ORCH" ticket publish 96 "A" "$body")"
bb="$("$ORCH" ticket publish 96 "B" "$body")"
bc="$("$ORCH" ticket publish 96 "C" "$body")"
bd="$("$ORCH" ticket publish 96 "D" "$body")"
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "blocking one ticket on a sibling succeeds" "$st" 0
assert_eq "adding the edge" "$(fake_blockers_of "$bb")" "$ba"
assert_eq "after block, ticket next no longer lists the target while its blocker is open" \
  "$("$ORCH" ticket next 96)" "$(printf '%s\n%s\n%s' "$ba" "$bc" "$bd")"

fake_fail adapter_blocker_add
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "blocking on an edge already present succeeds, writing no edge" "$st" 0
assert_eq "the edge is still there once" "$(fake_blockers_of "$bb")" "$ba"
fake_unfail

out="$("$ORCH" ticket block "$bd" --by "$bc,$ba,$bc" 2>&1)"; st=$?
assert_status "blocking on several siblings, one repeated, succeeds" "$st" 0
assert_eq "adding each edge once" "$(fake_blockers_of "$bd")" "$ba $bc"

out="$("$ORCH" ticket block abc --by "$ba" 2>&1)"; st=$?
assert_status "refuses a target that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
out="$("$ORCH" ticket block "$bc" --by "$ba,x1" 2>&1)"; st=$?
assert_status "refuses a --by list with a non-numeric entry" "$st" 1
assert_contains "naming the list" "$out" "$ba,x1"
out="$("$ORCH" ticket block "$bc" --by "$ba,,$ba" 2>&1)"; st=$?
assert_status "refuses a --by list with an empty entry" "$st" 1
assert_contains "naming the list" "$out" "--by must be plain issue numbers, got: $ba,,$ba"
out="$("$ORCH" ticket block "$bc" --by "" 2>&1)"; st=$?
assert_status "refuses an empty --by" "$st" 1
assert_contains "saying it got nothing" "$out" "--by must be plain issue numbers, got nothing"
out="$("$ORCH" ticket block "$bc" 2>&1)"; st=$?
assert_status "refuses a missing --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
out="$("$ORCH" ticket block --by "$ba" 2>&1)"; st=$?
assert_status "refuses a missing target" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
out="$("$ORCH" ticket block "$bc" --by "$ba" --by "$bb" 2>&1)"; st=$?
assert_status "refuses a repeated --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket block"
assert_eq "none of the refusals wrote an edge" "$(fake_blockers_of "$bc")" ""
before_store="$(fake_snapshot)"
out="$("$ORCH" ticket block "$bc" --by 2>&1)"; st=$?
assert_status "refuses a --by with no value" "$st" 1
assert_contains "with block's usage line" "$out" "usage: orch.sh ticket block"
assert_eq "writing nothing to GitHub" "$(fake_snapshot)" "$before_store"
out="$("$ORCH" ticket block "$bc" --by $'5\n' 2>&1)"; st=$?
assert_status "refuses a --by with a trailing newline" "$st" 1
assert_contains "as not plain issue numbers" "$out" "--by must be plain issue numbers"
assert_eq "writing nothing to GitHub" "$(fake_snapshot)" "$before_store"

be="$("$ORCH" ticket publish 96 "E" "$body")"
bx="$("$ORCH" ticket publish 97 "Elsewhere" "$body")"
"$ORCH" ticket close "$be" >/dev/null
out="$("$ORCH" ticket block "$be" --by "$ba" 2>&1)"; st=$?
assert_status "refuses a closed target" "$st" 1
assert_contains "naming it" "$out" "ticket #$be is closed"
out="$("$ORCH" ticket block 96 --by "$ba" 2>&1)"; st=$?
assert_status "refuses a target that is not a sub-issue" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue"
out="$("$ORCH" ticket block "$bc" --by "$ba,$bx" 2>&1)"; st=$?
assert_status "refuses a --by issue under another parent" "$st" 1
assert_contains "naming it" "$out" "#$bx is not a sub-issue of #96"
out="$("$ORCH" ticket block "$bc" --by 96 2>&1)"; st=$?
assert_status "refuses a --by issue with no parent" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue of #96"
assert_eq "the refusals wrote no edge, not even the sibling one" \
  "$(fake_blockers_of "$be")$(fake_blockers_of 96)$(fake_blockers_of "$bc")" ""
out="$("$ORCH" ticket block "$bc" --by "$be" 2>&1)"; st=$?
assert_status "accepts a closed blocker" "$st" 0
assert_eq "adding its edge" "$(fake_blockers_of "$bc")" "$be"

# The readback lags only after the read ahead of the write answered current.
bf="$("$ORCH" ticket publish 96 "F" "$body")"
bg="$("$ORCH" ticket publish 96 "G" "$body")"
fake_lag_after adapter_blockers 1 1 999999
out="$("$ORCH" ticket block "$bf" --by "$ba" 2>&1)"; st=$?
assert_status "a readback that is wrong once and right on the retry succeeds" "$st" 0
fake_lag_after adapter_blockers 1 2 999999
out="$("$ORCH" ticket block "$bg" --by "$ba" 2>&1)"; st=$?
assert_status "a readback that is wrong twice dies" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$bg's blocking edges did not verify"
fake_fail adapter_blocker_add "HTTP 422: Validation Failed"
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that refuses the edge write fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not add a blocking edge from ticket #$bf on #$bb"
assert_contains "with gh's reason" "$out" "HTTP 422"
fake_unfail
fake_fail adapter_blockers $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that cannot read the blockers fails the command" "$st" 1
assert_contains "naming the ticket, with gh's first line" "$out" \
  "gh could not read ticket #$bf's blockers: HTTP 502: Bad Gateway"
assert_not_contains "and only its first line" "$out" "second line"
fake_unfail
fake_fail adapter_issue_state
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a gh that cannot read the target fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$bf"
fake_unfail
errf="$(mktemp)"
fake_fail adapter_issue_parent
"$ORCH" ticket block "$bf" --by "$bb" >/dev/null 2>"$errf"; st=$?
assert_status "a gh that cannot read the ticket's parent fails the command" "$st" 1
assert_eq "naming the ticket: exact stderr, gh's reason after it" "$(cat "$errf")" \
  "orch: gh could not read issue #$bf's parent: fake gh: adapter_issue_parent failed"
fake_unfail
fake_fail_after adapter_issue_parent 1
"$ORCH" ticket block "$bf" --by "$bb" >/dev/null 2>"$errf"; st=$?
assert_status "a gh that cannot read a blocker's parent fails the command" "$st" 1
assert_eq "naming the blocker and the ticket: exact stderr" "$(cat "$errf")" \
  "orch: gh could not read issue #$bb's parent, a blocker of ticket #$bf: fake gh: adapter_issue_parent failed"
fake_unfail
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_issue_state $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a failed state read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read ticket #$bf: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_issue_parent $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a failed ticket parent read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read issue #$bf's parent: HTTP 502: Bad Gateway"
fake_unfail
fake_fail_after adapter_issue_parent 1 $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a failed blocker parent read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read issue #$bb's parent, a blocker of ticket #$bf: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_blocker_add $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket block "$bf" --by "$bb" 2>&1)"; st=$?
assert_status "a failed edge add still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not add a blocking edge from ticket #$bf on #$bb: HTTP 502: Bad Gateway"
fake_unfail
assert_eq "none of the failures added the edge" "$(fake_blockers_of "$bf")" "$ba"

# The body rewrite, driven by no-op runs: $bb is blocked by $ba alone and
# $bd by $ba and $bc, so each run below writes no edge and only brings the
# body's section in line. Each body is seeded as gh's read of it answers.
fake_body_read "$bd" 'Intro\n\n## Blocked by\n\n- #999\nold\n\n### Detail\nx\n\n## After\nTail.\n'
out="$("$ORCH" ticket block "$bd" --by "$ba" 2>&1)"; st=$?
assert_status "a no-op run with a stale section succeeds" "$st" 0
assert_eq "replaces a section in the middle of the body, a ### heading inside it included" \
  "$(fake_body_of "$bd" | od -c)" \
  "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n- #%s\n\n## After\nTail.\n' "$ba" "$bc" | od -c)"

fake_body_read "$bb" 'Intro\n\n## Blocked by\n\nNone (can start immediately)\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "replaces a section at the end of the body" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\nMore.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "appends a missing section after one blank line" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\nMore.\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\n## Blocked by\n\nNone\n# Top\nTail.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a # heading ends the section" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\n- #%s\n\n# Top\nTail.\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\r\n\r\n## Blocked by\r\n\r\nNone\r\n\r\n## After\r\nTail.\r\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a CRLF body keeps its CRLF lines, the rewritten section in kind" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\r\n\r\n## Blocked by\r\n\r\n- #%s\r\n\r\n## After\r\nTail.\r\n' "$ba" | od -c)"

fake_body_read "$bb" 'Intro\n\n```md\n## Blocked by\n\n- #1\n```\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a fenced ## Blocked by is ignored and a real section appended" \
  "$(fake_body_of "$bb" | od -c)" "$(printf 'Intro\n\n```md\n## Blocked by\n\n- #1\n```\n\n## Blocked by\n\n- #%s\n' "$ba" | od -c)"

fake_body_read "$bb" '## Blocked by\n\n```\n## Not a heading\n```\n\n## After\nTail.\n'
"$ORCH" ticket block "$bb" --by "$ba" >/dev/null 2>&1
assert_eq "a fenced ## line inside the section does not end it" \
  "$(fake_body_of "$bb" | od -c)" "$(printf '## Blocked by\n\n- #%s\n\n## After\nTail.\n' "$ba" | od -c)"

fake_body_read "$bb" '## Blocked by\n\n- #%s\n' "$ba"
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket block "$bb" --by "$ba" 2>&1)"; st=$?
assert_status "a run with nothing to change succeeds, writing no body when the result is byte-identical" "$st" 0
fake_unfail

# Ascending means numeric: #98 sorts before #100.
fake_next_issue 98
s98="$("$ORCH" ticket publish 199 "S98" "$body")"
s99="$("$ORCH" ticket publish 199 "S99" "$body")"
s100="$("$ORCH" ticket publish 199 "S100" "$body")"
"$ORCH" ticket block "$s99" --by "$s100,$s98" >/dev/null 2>&1
assert_eq "lists the blockers sorted ascending by number" \
  "$(fake_body_of "$s99")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #98\n- #100')"

# Any gh failure dies naming the ticket; edges already written stay, and the
# same command run again finishes the job.
fake_next_issue 820
bh="$("$ORCH" ticket publish 96 "H" "$body")"
fake_body_read "$bh" 'Intro\n'
fake_fail adapter_issue_body
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a gh that cannot read the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$bh's body"
assert_eq "the edge it wrote stays" "$(fake_blockers_of "$bh")" "$ba"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a gh that cannot write the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not rewrite ticket #$bh's ## Blocked by section"
fake_unfail
out="$("$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "re-running after the body failures succeeds" "$st" 0
assert_eq "finishing the body" "$(fake_body_of "$bh")" "$(printf 'Intro\n\n## Blocked by\n\n- #%s' "$ba")"

# The ## Blocked by rewrite carries gh's reason on its read and its write, and
# a failed read or write leaves no temp file (#846).
fake_body_read "$bh" 'Intro\n'
rw_tmp="$(mktemp -d)"
fake_fail adapter_issue_body $'HTTP 502: Bad Gateway\nsecond line'
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a failed ## Blocked by read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read ticket #$bh's body: HTTP 502: Bad Gateway"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
fake_unfail
fake_fail_times adapter_issue_body 9
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a silent failed ## Blocked by read exits 1" "$st" 1
assert_eq "ending in gh gave no reason" "$out" \
  "orch: gh could not read ticket #$bh's body: gh gave no reason"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
fake_unfail
fake_fail adapter_issue_body_edit $'HTTP 502: Bad Gateway\nsecond line'
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket block "$bh" --by "$ba" 2>&1)"; st=$?
assert_status "a failed ## Blocked by write still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not rewrite ticket #$bh's ## Blocked by section: HTTP 502: Bad Gateway"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
assert_eq "and the body untouched" "$(fake_body_of "$bh")" "Intro"
fake_unfail
rm -rf "$rw_tmp"

bi="$("$ORCH" ticket publish 96 "I" "$body")"
fake_fail_after adapter_blocker_add 1
out="$("$ORCH" ticket block "$bi" --by "$ba,$bb" 2>&1)"; st=$?
assert_status "a multi-edge run that dies part-way fails" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$bi"
assert_eq "keeping the edge it wrote" "$(fake_blockers_of "$bi")" "$ba"
fake_fail_after adapter_blocker_add 1
out="$("$ORCH" ticket block "$bi" --by "$ba,$bb" 2>&1)"; st=$?
assert_status "re-running the same command succeeds, adding only the missing edge" "$st" 0
fake_unfail
assert_eq "both edges in place" "$(fake_blockers_of "$bi")" "$ba $bb"
assert_contains "and bringing the body in line" "$(fake_body_of "$bi")" "$(printf -- '- #%s\n- #%s' "$ba" "$bb")"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket block is in the usage text" "$out" "ticket block <n> --by N,N,..."

restore_suite_env

# --- ticket unblock ----------------------------------------------------------
# Removes native blocking edges from a published, open ticket, verifies the
# rest by reading them back (ADR-0011), and rewrites the body's `## Blocked
# by` section to match. Idempotent, so a run that died part-way is finished
# by running it again.
echo
echo "ticket unblock"
ticket_fixture
for p in 96 97; do fake_issue "$p" open; done
fake_next_issue 900
ua="$("$ORCH" ticket publish 96 "A" "$body")"
ub="$("$ORCH" ticket publish 96 "B" "$body")"
uc="$("$ORCH" ticket publish 96 "C" "$body")"
ud="$("$ORCH" ticket publish 96 "D" "$body")"
"$ORCH" ticket block "$ud" --by "$ua,$ub,$uc" >/dev/null 2>&1
out="$("$ORCH" ticket unblock "$ud" --by "$ub" 2>&1)"; st=$?
assert_status "unblocking one edge succeeds" "$st" 0
assert_eq "removing that edge alone" "$(fake_blockers_of "$ud")" "$ua $uc"
assert_eq "and bringing the body in line" \
  "$(fake_body_of "$ud")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s\n- #%s' "$ua" "$uc")"
out="$("$ORCH" ticket unblock "$ud" --by "$uc,$ua,$uc" 2>&1)"; st=$?
assert_status "unblocking several edges, one repeated, succeeds" "$st" 0
assert_eq "removing each of them" "$(fake_blockers_of "$ud")" ""
assert_eq "removing the last edge writes None (can start immediately)" \
  "$(fake_body_of "$ud")" "$(printf 'Build the thing.\n\n## Blocked by\n\nNone (can start immediately)')"
assert_eq "after unblock, ticket next lists the target again" \
  "$("$ORCH" ticket next 96)" "$(printf '%s\n%s\n%s\n%s' "$ua" "$ub" "$uc" "$ud")"

fake_body_read "$ud" 'Intro\n\n## Blocked by\n\n- #%s\n' "$ua"
fake_fail adapter_blocker_remove
out="$("$ORCH" ticket unblock "$ud" --by "$ua" 2>&1)"; st=$?
assert_status "unblocking an edge already absent succeeds, writing no edge" "$st" 0
fake_unfail
assert_eq "still bringing the body section in line" \
  "$(fake_body_of "$ud" | od -c)" "$(printf 'Intro\n\n## Blocked by\n\nNone (can start immediately)\n' | od -c)"

out="$("$ORCH" ticket unblock abc --by "$ua" 2>&1)"; st=$?
assert_status "refuses a target that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
out="$("$ORCH" ticket unblock "$uc" --by "$ua,x1" 2>&1)"; st=$?
assert_status "refuses a --by list with a non-numeric entry" "$st" 1
assert_contains "naming the list" "$out" "$ua,x1"
out="$("$ORCH" ticket unblock "$uc" --by "$ua,,$ua" 2>&1)"; st=$?
assert_status "refuses a --by list with an empty entry" "$st" 1
assert_contains "naming the list" "$out" "--by must be plain issue numbers, got: $ua,,$ua"
out="$("$ORCH" ticket unblock "$uc" --by "" 2>&1)"; st=$?
assert_status "refuses an empty --by" "$st" 1
assert_contains "saying it got nothing" "$out" "--by must be plain issue numbers, got nothing"
out="$("$ORCH" ticket unblock "$uc" 2>&1)"; st=$?
assert_status "refuses a missing --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"
out="$("$ORCH" ticket unblock --by "$ua" 2>&1)"; st=$?
assert_status "refuses a missing target" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"
out="$("$ORCH" ticket unblock "$uc" --by "$ua" --by "$ub" 2>&1)"; st=$?
assert_status "refuses a repeated --by" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket unblock"

ue="$("$ORCH" ticket publish 96 "E" "$body")"
ux="$("$ORCH" ticket publish 97 "Elsewhere" "$body")"
uf="$("$ORCH" ticket publish 96 "F" "$body")"
"$ORCH" ticket block "$ue" --by "$ua" >/dev/null 2>&1
"$ORCH" ticket block "$uf" --by "$ua,$ub" >/dev/null 2>&1
"$ORCH" ticket close "$ue" >/dev/null
out="$("$ORCH" ticket unblock "$ue" --by "$ua" 2>&1)"; st=$?
assert_status "refuses a closed target" "$st" 1
assert_contains "naming it" "$out" "ticket #$ue is closed"
assert_eq "leaving its edge" "$(fake_blockers_of "$ue")" "$ua"
out="$("$ORCH" ticket unblock 96 --by "$ua" 2>&1)"; st=$?
assert_status "refuses a target that is not a sub-issue" "$st" 1
assert_contains "naming it" "$out" "#96 is not a sub-issue"
out="$("$ORCH" ticket unblock "$uf" --by "$ua,$ux" 2>&1)"; st=$?
assert_status "refuses a --by issue under another parent" "$st" 1
assert_contains "naming it" "$out" "#$ux is not a sub-issue of #96"
assert_eq "the refusal removed no edge, not even the sibling one" \
  "$(fake_blockers_of "$uf")" "$ua $ub"
before_store="$(fake_snapshot)"
out="$("$ORCH" ticket unblock "$uf" --by 2>&1)"; st=$?
assert_status "refuses a --by with no value" "$st" 1
assert_contains "with unblock's usage line" "$out" "usage: orch.sh ticket unblock"
assert_eq "writing nothing to GitHub, the target's edges kept" "$(fake_snapshot)" "$before_store"
"$ORCH" ticket block "$uf" --by "$ue" >/dev/null 2>&1
out="$("$ORCH" ticket unblock "$uf" --by "$ue" 2>&1)"; st=$?
assert_status "accepts a closed blocker" "$st" 0
assert_eq "removing its edge" "$(fake_blockers_of "$uf")" "$ua $ub"

# The readback lags only after the read ahead of the write answered current.
fake_lag_after adapter_blockers 1 1 999999
out="$("$ORCH" ticket unblock "$uf" --by "$ub" 2>&1)"; st=$?
assert_status "a readback that is wrong once and right on the retry succeeds" "$st" 0
assert_eq "having removed the edge" "$(fake_blockers_of "$uf")" "$ua"
fake_lag_after adapter_blockers 1 2 999999
out="$("$ORCH" ticket unblock "$uf" --by "$ua" 2>&1)"; st=$?
assert_status "a readback that is wrong twice dies" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$uf's blocking edges did not verify"

ug="$("$ORCH" ticket publish 96 "G" "$body")"
"$ORCH" ticket block "$ug" --by "$ua,$ub" >/dev/null 2>&1
fake_fail adapter_blocker_remove
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that refuses the edge removal fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not remove a blocking edge from ticket #$ug on #$ua"
fake_unfail
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_blocker_remove $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a failed edge removal still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not remove a blocking edge from ticket #$ug on #$ua: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_blockers
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that cannot read the blockers fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug's blockers"
fake_unfail
fake_fail adapter_issue_state
out="$("$ORCH" ticket unblock "$ug" --by "$ua" 2>&1)"; st=$?
assert_status "a gh that cannot read the target fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug"
fake_unfail
assert_eq "none of the failures removed an edge" "$(fake_blockers_of "$ug")" "$ua $ub"

fake_fail adapter_issue_body
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "a gh that cannot read the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not read ticket #$ug's body"
assert_eq "the edge it removed stays removed" "$(fake_blockers_of "$ug")" "$ua"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "a gh that cannot write the body fails the command" "$st" 1
assert_contains "naming the ticket" "$out" "gh could not rewrite ticket #$ug's ## Blocked by section"
assert_eq "the edge stays removed" "$(fake_blockers_of "$ug")" "$ua"
fake_unfail
out="$("$ORCH" ticket unblock "$ug" --by "$ub" 2>&1)"; st=$?
assert_status "re-running after the body failures succeeds" "$st" 0
assert_eq "finishing the body" "$(fake_body_of "$ug")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s' "$ua")"

uh="$("$ORCH" ticket publish 96 "H" "$body")"
"$ORCH" ticket block "$uh" --by "$ua,$ub,$uc" >/dev/null 2>&1
fake_fail_after adapter_blocker_remove 1
out="$("$ORCH" ticket unblock "$uh" --by "$ua,$ub" 2>&1)"; st=$?
assert_status "a multi-edge run that dies part-way fails" "$st" 1
assert_contains "naming the ticket" "$out" "ticket #$uh"
assert_eq "the edge it removed stays removed" "$(fake_blockers_of "$uh")" "$ub $uc"
fake_fail_after adapter_blocker_remove 1
out="$("$ORCH" ticket unblock "$uh" --by "$ua,$ub" 2>&1)"; st=$?
assert_status "re-running the same command succeeds, removing only the edge still present" "$st" 0
fake_unfail
assert_eq "leaving the other edge" "$(fake_blockers_of "$uh")" "$uc"
assert_eq "and bringing the body in line" \
  "$(fake_body_of "$uh")" "$(printf 'Build the thing.\n\n## Blocked by\n\n- #%s' "$uc")"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket unblock is in the usage text" "$out" "ticket unblock <n> --by N,N,..."

restore_suite_env

# --- ticket: unknown op ------------------------------------------------------
new_repo >/dev/null
out="$("$ORCH" ticket bogus 2>&1)"; st=$?
assert_status "ticket bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown ticket op"

# --- ticket merge (#621) -------------------------------------------------------
# Lands a ticket branch on the branch it was forked from: rebase inside the
# ticket worktree, then fast-forward the forked-from branch wherever it is
# checked out. Checked through branches, tips and exit status.
echo
echo "ticket merge"
# tm_commit <dir> <file> <content>: commit <content> to <file> in <dir>.
tm_commit() { echo "$3" >"$1/$2" && git -C "$1" add "$2" && git -C "$1" commit -qm "$2: $3"; }
# tm_rebasing <dir>: "yes" when a rebase is in progress in <dir>'s checkout.
tm_rebasing() {
  local d
  for d in rebase-merge rebase-apply; do
    [ ! -e "$(git -C "$1" rev-parse --git-path "$d")" ] || { echo yes; return; }
  done
  echo no
}

tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" ticket.txt one
tm_commit "$wt" ticket2.txt two
tm_commit . other.txt landed-first
flow_tip="$(git rev-parse orch/5-feature)"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge of a clean ticket succeeds" "$st" 0
assert_eq "the forked-from branch now holds the ticket's commits" \
  "$(git log --format=%s orch/5-feature -3 | tr '\n' '|')" "ticket2.txt: two|ticket.txt: one|other.txt: landed-first|"
assert_eq "on top of its prior tip" "$(git rev-parse orch/5-feature~2)" "$flow_tip"
assert_eq "with no merge commit" "$(git rev-list --merges orch/5-feature | wc -l | tr -d ' ')" "0"
assert_eq "the forked-from branch's tip is the ticket branch's" \
  "$(git rev-parse orch/5-feature)" "$(git rev-parse orch/5-feature--t7)"
assert_eq "its checkout's working tree is updated too" "$(cat ticket2.txt)" "two"
assert_eq "and left clean" "$(git status --porcelain)" ""
out="$("$ORCH" ticket-worktree remove 7)"; st=$?
assert_status "a merged ticket's worktree then removes without --unmerged" "$st" 0

# Conflict: both sides change the same line.
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" feature.txt from-ticket
tm_commit . feature.txt from-flow
flow_tip="$(git rev-parse orch/5-feature)"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge exits 3 on a rebase conflict" "$st" 3
assert_contains "saying it conflicted" "$out" "conflict"
assert_eq "the forked-from branch stays at its prior tip" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "the ticket branch stays at its prior tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "no rebase is left in progress" "$(tm_rebasing "$wt")" "no"
assert_eq "the ticket worktree is left clean" "$(git -C "$wt" status --porcelain)" ""
assert_eq "and the flow's checkout too" "$(git status --porcelain)" ""

# A rebase already in progress in the ticket worktree: refused before anything
# moves, and the rebase is left for whoever started it.
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a ticket worktree mid-rebase" "$st" 1
assert_contains "naming it not on a branch" "$out" \
  "orch: ticket worktree $wt is not on a branch (detached HEAD)"
assert_eq "the rebase is still in progress" "$(tm_rebasing "$wt")" "yes"
assert_eq "the forked-from branch stays at its prior tip" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "the ticket branch stays at its prior tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
git -C "$wt" rebase --abort

# A rebase that fails for a reason other than a conflict exits 1, naming
# git's first line, never 3.
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" ticket.txt one
tm_commit . other.txt landed-first
flow_tip="$(git rev-parse orch/5-feature)"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
hooks="$(mktemp -d)"
printf '#!/bin/sh\necho "no rebasing today"\nexit 1\n' >"$hooks/pre-rebase"
chmod +x "$hooks/pre-rebase"
git config core.hooksPath "$hooks"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge exits 1 when a pre-rebase hook refuses" "$st" 1
assert_contains "naming the hook's line" "$out" \
  "orch: rebasing orch/5-feature--t7 onto orch/5-feature failed: no rebasing today"
assert_not_contains "not calling it a conflict" "$out" "conflict"
assert_eq "the forked-from branch stays at its prior tip" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "the ticket branch stays at its prior tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "no rebase is left in progress" "$(tm_rebasing "$wt")" "no"

printf '#!/bin/sh\nexit 1\n' >"$hooks/pre-rebase"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge exits 1 when a silent pre-rebase hook refuses" "$st" 1
assert_contains "naming git's own line" "$out" \
  "orch: rebasing orch/5-feature--t7 onto orch/5-feature failed: error: The pre-rebase hook refused to rebase."
assert_eq "the forked-from branch stays at its prior tip" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "the ticket branch stays at its prior tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "no rebase is left in progress" "$(tm_rebasing "$wt")" "no"
git config --unset core.hooksPath

# Refusals: each exits 1 and changes nothing.
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
tm_commit "$wt" ticket.txt one
tm_commit . other.txt landed-first
flow_tip="$(git rev-parse orch/5-feature)"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
echo dirty >"$wt/README.md"
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a dirty ticket worktree" "$st" 1
assert_contains "naming it dirty" "$out" \
  "orch: ticket worktree $wt is dirty - commit or discard its changes first"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "and the ticket worktree's change" "$(cat "$wt/README.md")" "dirty"
git -C "$wt" checkout -q -- README.md

echo dirty >README.md
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a dirty forked-from checkout" "$st" 1
assert_contains "naming it dirty" "$out" \
  "orch: $(pwd -P), the checkout of orch/5-feature, is dirty - commit or discard its changes first"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
assert_eq "and the checkout's change" "$(cat README.md)" "dirty"
git checkout -q -- README.md

git checkout -q --detach
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a forked-from branch checked out nowhere" "$st" 1
assert_contains "naming the branch" "$out" "orch/5-feature"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
git checkout -q orch/5-feature

git config --unset branch.orch/5-feature--t7.orchestrator-ticket-parent
out="$("$ORCH" ticket merge 7 2>&1)"; st=$?
assert_status "merge refuses a branch that records no forked-from branch" "$st" 1
assert_contains "saying so" "$out" "orch: branch orch/5-feature--t7 records no forked-from branch"
assert_not_contains "with no --unmerged hint" "$out" "--unmerged"
assert_eq "leaving the forked-from branch" "$(git rev-parse orch/5-feature)" "$flow_tip"
assert_eq "and the ticket branch" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
git config branch.orch/5-feature--t7.orchestrator-ticket-parent orch/5-feature

out="$("$ORCH" ticket merge 9 2>&1)"; st=$?
assert_status "merge refuses a ticket with no ticket worktree" "$st" 1
out="$("$ORCH" ticket merge 2>&1)"; st=$?
assert_status "merge refuses a missing ticket number" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh ticket merge <n>"

# The forked-from branch checked out in a linked worktree (an ADR-0008 flow
# checkout): the merge fast-forwards it there.
tw_repo
main_top="$(git rev-parse --show-toplevel)"
linked="$(mktemp -d)/linked"
git worktree add -q -b orch/6-other "$linked"
cd "$linked" || exit 1
wt="$("$ORCH" ticket-worktree add 4)"
tm_commit "$wt" ticket.txt four
tm_commit . other.txt landed-first
out="$("$ORCH" ticket merge 4 2>&1)"; st=$?
assert_status "merge succeeds when the forked-from branch is in a linked worktree" "$st" 0
assert_eq "fast-forwarding it there" "$(git -C "$linked" rev-parse HEAD)" "$(git rev-parse orch/6-other--t4)"
assert_eq "linearly" "$(git -C "$linked" log --format=%s -2 | tr '\n' '|')" "ticket.txt: four|other.txt: landed-first|"
assert_eq "updating its working tree" "$(cat "$linked/ticket.txt")" "four"
assert_eq "and leaving the main checkout's branch alone" \
  "$(git -C "$main_top" branch --show-current)" "orch/5-feature"
cd "$main_top" || exit 1

out="$("$ORCH" help 2>&1)"
assert_contains "ticket merge is in the usage text" "$out" "ticket merge <n>"
assert_contains "the CLI conventions' noun table lists merge among ticket's verbs" \
  "$(grep '^| `ticket` ' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`merge`'
restore_suite_env
