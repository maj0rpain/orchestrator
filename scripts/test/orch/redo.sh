# --- redo review ----------------------------------------------------------
# The full review -> implement transition: three distinct refusals below a
# terminal state, and a full composition above it.
#
# cmd_redo_review's PR close goes through the store-backed fake (fake_github)
# - a check of the fixture gh's log right after the first successful redo proves it never
# spawns a real gh subprocess. The real operation is pinned in "gh adapter
# contract".
echo
echo "redo review"
healthy_repo
fake_github
fake_issue 21 open
for n in 30 31 32 33 34; do fake_pr "$n" open orch/21-redotest main; done
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redotest >/dev/null

out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses outside the review phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the review phase"

state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
git push -q -u origin orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 30
store_before="$(fake_snapshot)"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses with no loop run yet" "$st" 1
assert_contains "distinct from the other two refusals" "$out" "no review loop has run yet"
assert_eq "and nothing reaches GitHub" "$(fake_snapshot)" "$store_before"

state_fixture iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a loop still short of its budget" "$st" 1
assert_contains "pointing at /orchestrator:next instead" "$out" "that's what /orchestrator:next (or orch-flow's Next phase section) is for"
# Claude Code users see the command alone, as before 1.0.0 (#121 story 2).
out="$(ORCHESTRATOR_HOST=claude "$ORCH" redo review 2>&1)"
assert_contains "names the bare command on Claude Code" "$out" "that's what /orchestrator:next is for"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" redo review 2>&1)"
assert_contains "and the orch-flow section when no host is detected" "$out" "/orchestrator:next (or orch-flow's Next phase section)"

state_fixture iteration 5
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "refuses a budget-spent loop with no terminal record" "$st" 1
assert_contains "reading as interrupted, distinct from pending" "$out" "looks interrupted, not stopped"

# A malformed record is refused before anything moves, with the rewrite to do.
mkdir -p .orchestrator/review
writeln '## Terminal state' 'Stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" redo review 2>&1 >/dev/null)"; st=$?
assert_status "refuses a malformed terminal record" "$st" 1
assert_contains "saying to rewrite the record's first line" "$out" "rewrite the first line of"
assert_contains "quoting the expected shape" "$out" "expected: first line"
assert_eq "leaving the phase, branch, and redo count unchanged" \
  "$("$ORCH" state get phase) $("$ORCH" state get branch) $("$ORCH" state get redo_count)" \
  "review orch/21-redotest 0"
rm .orchestrator/review/iteration-05.md

state_fixture pr 30
state_fixture base_sha deadbeefcafe
"$ORCH" state set flake_rerun_used true
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
: >"$GH_FIXTURE/env.log"
base_before="$("$ORCH" state get base)"
writeln '# plan' >.orchestrator/handoff/01-plan.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
plan_before="$(cat .orchestrator/handoff/01-plan.md)"
git push -q origin HEAD:refs/heads/redo-base
out="$(ORCHESTRATOR_HOST=claude "$ORCH" base set redo-base --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a branched flow at the review phase" "$st" 1
assert_contains "naming redo as the way back on Claude Code" "$out" \
  "flow redotest already has branch orch/21-redotest - its base can change again once /orchestrator:redo retires it"
assert_eq "leaving the flow's base unchanged" "$("$ORCH" state get base)" "$base_before"
out="$(ORCHESTRATOR_HOST=junie "$ORCH" base set redo-base --flow 2>&1)"
assert_contains "and with the orch-flow section on another host" "$out" \
  "flow redotest already has branch orch/21-redotest - its base can change again once /orchestrator:redo (or orch-flow's Redo section) retires it"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a genuinely terminal loop redoes" "$st" 0
assert_eq "keeps the flow's recorded base branch" "$("$ORCH" state get base)" "$base_before"
assert_eq "prints the new redo count" "$out" "1"
assert_eq "records it in state" "$("$ORCH" state get redo_count)" "1"
assert_eq "resets the iteration for a fresh budget" "$("$ORCH" state get iteration)" "0"
assert_eq "and clears branch, PR, and base SHA" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""
assert_eq "steps the flow back to implement" "$("$ORCH" state get phase)" "implement"
assert_eq "leaves the one-per-flow flake rerun untouched" \
  "$("$ORCH" state get flake_rerun_used)" "true"
assert_eq "renames the old branch aside" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and republishes it on origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/orch/21-redotest-redo-1 >/dev/null && echo present || echo gone)" "present"
assert_eq "closes the old PR" "$(fake_pr_state_of 30)" "CLOSED"
assert_contains "with a comment naming the retired branch" \
  "$(fake_pr_comments_of 30)" "orch/21-redotest-redo-1"
assert_eq "the pr close call never reached a real gh subprocess" "$(gh_calls)" "0"
assert_eq "moves the old loop's records aside" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "leaving the flat trail empty" \
  "$([ -e .orchestrator/review/iteration-05.md ] && echo yes || echo no)" "no"
assert_eq "retires the stale implement handoff under the same redo number" \
  "$(cat .orchestrator/handoff/pre-redo-1/03-implement.md)" "# implement"
assert_eq "leaving no implement handoff behind" \
  "$([ -e .orchestrator/handoff/03-implement.md ] && echo yes || echo no)" "no"
assert_eq "and the plan handoff untouched" "$(cat .orchestrator/handoff/01-plan.md)" "$plan_before"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance then refuses to leave implement" "$st" 1
assert_contains "for want of the implement handoff" "$out" "/.orchestrator/handoff/03-implement.md before leaving the implement phase"
out="$("$ORCH" base set redo-base --flow 2>&1)"; st=$?
assert_status "base set --flow succeeds again once redo review retired the branch" "$st" 0
assert_eq "recording the corrected base" "$("$ORCH" state get base)" "redo-base"

# A second redo in the same flow numbers on rather than overwriting the first.
state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest orch/21-redotest-redo-1
stub_pushed_branch orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 31
state_fixture iteration 5
"$ORCH" state set budget 5
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a second stopped loop redoes just as the first did" "$st" 0
assert_eq "and numbers on rather than repeating redo-1" "$out" "2"
assert_eq "naming the branch redo-2" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-2 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "without disturbing redo-1's records" \
  "$([ -f .orchestrator/review/pre-redo-1/iteration-05.md ] && echo yes || echo no)" "yes"
assert_eq "moving the second loop's records into pre-redo-2" \
  "$([ -f .orchestrator/review/pre-redo-2/iteration-05.md ] && echo yes || echo no)" "yes"

state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
stub_pushed_branch orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 32
state_fixture iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
fake_fail adapter_pr_close $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a gh that will not close the PR fails the redo" "$st" 1
assert_eq "leaving the PR open" "$(fake_pr_state_of 32)" "OPEN"
assert_contains "naming the reason, with gh's first line (#846)" "$out" \
  "orch: gh could not close PR #32: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
assert_eq "still renames the branch aside since retire runs before the pr close" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and never moves the loop's records since gh failed first" \
  "$([ -f .orchestrator/review/iteration-01.md ] && echo yes || echo no)" "yes"
# Issue #63: the rename above is real, so state.branch has to follow it
# rather than keep naming a branch retire already renamed away - otherwise a
# retried redo dies confusingly against a branch that no longer exists.
assert_eq "updates state.branch to the branch retire actually produced" \
  "$("$ORCH" state get branch)" "orch/21-redotest-redo-3"
assert_eq "and records the bumped redo_count so a retry numbers on, not over" \
  "$("$ORCH" state get redo_count)" "3"

# A retry after that failure has to work from the state the failure left
# behind, and must not retire the already-retired branch a second time -
# issue #63 acceptance criterion 3: it should pick up from closing the PR.
rm -rf "$ORCH_GH_FAKE_STORE/fail"
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "retrying redo review after the gh failure now succeeds" "$st" 0
assert_eq "closing the PR this time" "$(fake_pr_state_of 32)" "CLOSED"
assert_eq "reuses redo-3 rather than numbering on to redo-4" "$out" "3"
assert_eq "does not retire the branch a second time" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-4 >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "leaves redo-3 as the actually-retired branch" \
  "$(git rev-parse --verify --quiet orch/21-redotest-redo-3 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and clears branch, PR, and base SHA on the now-successful redo" \
  "$("$ORCH" state get branch)$("$ORCH" state get pr)$("$ORCH" state get base_sha)" ""

# A loop that stopped short of its budget - a failed base sync goes straight
# to Termination - has ended as surely as one that spent it, and redoes.
state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotest
stub_pushed_branch orch/21-redotest
state_fixture branch orch/21-redotest
state_fixture pr 34
state_fixture iteration 2
"$ORCH" state set budget 5
writeln '## Terminal state' 'stop - base sync failed.' >.orchestrator/review/iteration-02.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a loop stopped short of its budget redoes" "$st" 0
assert_eq "numbering on to redo-4" "$out" "4"
assert_eq "closing its PR" "$(fake_pr_state_of 34)" "CLOSED"

# A loop that ended by marking the PR ready has already moved the flow to
# phase done, in the same operation that decided "ready" - there is no real
# window where redo could ever see phase: review with a ready terminal
# record. Produced the way the system actually produces it (review ready
# itself, not a hand-crafted state), redo rejects it exactly as it would any
# other done flow, through the same phase gate, not a ready-specific branch.
state_fixture phase review
state_fixture pr 33
state_fixture iteration 1
"$ORCH" state set budget 1
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-01.md
"$ORCH" review ready >/dev/null
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a loop that ended ready is out of scope for redo, same as any done flow" "$st" 1
assert_contains "the same phase-gate refusal as any other done flow" "$out" "flow is not at the review phase"
assert_eq "leaving the ready PR open" "$(fake_pr_state_of 33)" "OPEN"
restore_suite_env

# --- redo review refuses a taken handoff destination ------------------------
# Issue #304: the implement handoff retires into exactly the pre-redo-N/ that
# pairs with review/pre-redo-N/, or redo stops naming it - never a suffixed
# pre-redo-N-2/. The destination is pre-created, so no clock is involved.
echo
echo "redo review refuses a taken handoff destination"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init redotaken >/dev/null
state_fixture phase review
"$ORCH" state set issue 21
git checkout -q -b orch/21-redotaken
git push -q -u origin orch/21-redotaken
state_fixture branch orch/21-redotaken
state_fixture pr 35
state_fixture iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review .orchestrator/handoff/pre-redo-1
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
writeln '# older implement' >.orchestrator/handoff/pre-redo-1/03-implement.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
fake_github
fake_issue 21 open
fake_pr 35 open orch/21-redotaken main
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "a destination already holding the handoff fails the redo" "$st" 1
assert_contains "naming the destination" "$out" "pre-redo-1"
assert_eq "leaving the live implement handoff in place" \
  "$(cat .orchestrator/handoff/03-implement.md 2>/dev/null)" "# implement"
assert_eq "and the retired one untouched" \
  "$(cat .orchestrator/handoff/pre-redo-1/03-implement.md)" "# older implement"
assert_eq "never retiring into a suffixed pre-redo-1-2" \
  "$([ -e .orchestrator/handoff/pre-redo-1-2 ] && echo present || echo gone)" "gone"
restore_suite_env

# --- redo review reopens tickets -------------------------------------------
# Acceptance criterion from issue #88: a prior implement phase closes every
# ticket of the flow's spec issue as it works the frontier, so a redo back to
# implement has to reopen them - otherwise the redone implement phase's
# frontier query (ticket next) finds nothing and opens an empty PR.
echo
echo "redo review reopens tickets"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init tickettest >/dev/null

fake_github
fake_issue 60 open
fake_pr 40 open orch/60-tickettest main
body="$(mktemp)"; printf 'Body of the ticket.\n' >"$body"
t1="$("$ORCH" ticket publish 60 "One" "$body")"
t2="$("$ORCH" ticket publish 60 "Two" "$body")"
"$ORCH" ticket close "$t1" >/dev/null
"$ORCH" ticket close "$t2" >/dev/null
assert_eq "frontier is empty once every ticket is closed" "$("$ORCH" ticket next 60)" ""

state_fixture phase review
"$ORCH" state set issue 60
git checkout -q -b orch/60-tickettest
git push -q -u origin orch/60-tickettest
state_fixture branch orch/60-tickettest
state_fixture pr 40
state_fixture iteration 1
"$ORCH" state set budget 1
mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-01.md
out="$("$ORCH" redo review 2>&1)"; st=$?
assert_status "redo review succeeds with every ticket already closed" "$st" 0
assert_eq "reopens exactly the tickets the flow's implement phase had closed" \
  "$("$ORCH" ticket next 60)" "$(printf '%s\n%s' "$t1" "$t2")"

restore_suite_env

# --- redo spec --------------------------------------------------------------
# --new-issue's close goes through the store-backed fake (fake_github), the
# closed issue read back from its store - the fixture gh's log stays empty, proving it
# never spawns a real gh subprocess. The real operation is pinned in "gh
# adapter contract".
echo
echo "redo spec"
fresh_flow redospec

out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "refuses outside the implement phase" "$st" 1
assert_contains "naming the reason" "$out" "flow is not at the implement phase"

state_fixture phase implement
"$ORCH" state set issue 40
state_fixture redo_count 2
writeln '# plan' >.orchestrator/handoff/01-plan.md
writeln '# spec' >.orchestrator/handoff/02-spec.md
writeln '# implement' >.orchestrator/handoff/03-implement.md
fake_github
fake_issue 40 open
before="$(fake_snapshot)"
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "the default path steps back to spec" "$st" 0
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "keeping the existing issue" "$("$ORCH" state get issue)" "40"
assert_eq "and, with no breakdown to retire, writing nothing to GitHub" "$(fake_snapshot)" "$before"
retired="$(ls -d .orchestrator/handoff/pre-redo-spec-* 2>/dev/null)"
assert_eq "retires the handoffs into one timestamped directory" \
  "$(printf '%s\n' "$retired" | grep -c '^\.orchestrator/handoff/pre-redo-spec-[0-9]\{8\}-[0-9]\{6\}$')" "1"
assert_eq "holding the stale spec handoff" "$(cat "$retired/02-spec.md" 2>/dev/null)" "# spec"
assert_eq "and the stale implement handoff" "$(cat "$retired/03-implement.md" 2>/dev/null)" "# implement"
assert_eq "leaving neither behind" \
  "$(ls .orchestrator/handoff/02-spec.md .orchestrator/handoff/03-implement.md 2>/dev/null)" ""
assert_eq "the plan handoff untouched" "$(cat .orchestrator/handoff/01-plan.md)" "# plan"
assert_eq "without bumping redo_count" "$("$ORCH" state get redo_count)" "2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance then refuses to leave spec" "$st" 1
assert_contains "for want of the spec handoff" "$out" "/.orchestrator/handoff/02-spec.md before leaving the spec phase"

state_fixture phase implement
"$ORCH" state set issue 41
# Clear the first run's directory so a second run in the same second does not
# meet a taken destination, which retire_handoffs refuses (#304).
rm -rf .orchestrator/handoff/pre-redo-spec-*
writeln '# spec again' >.orchestrator/handoff/02-spec.md
: >"$GH_FIXTURE/env.log"
fake_github
fake_issue 41 open
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue also steps back to spec" "$st" 0
# shellcheck disable=SC2010 # counts what the glob matched; ls prints nothing when it matches none
assert_eq "with no implement handoff, retires the spec handoff alone" \
  "$(ls .orchestrator/handoff/pre-redo-spec-*/02-spec.md 2>/dev/null | grep -c .) $(ls .orchestrator/handoff/pre-redo-spec-*/03-implement.md 2>/dev/null | grep -c .)" "1 0"
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "clearing the old issue" "$("$ORCH" state get issue)" ""
assert_eq "closes the old issue" "$(fake_state_of 41)" "CLOSED"
assert_contains "saying why, in a comment on it" "$(fake_comments_of 41)" \
  "This issue was closed by an orchestrator redo because the spec itself needed to change."
assert_eq "the close call never reached a real gh subprocess" "$(gh_calls)" "0"

state_fixture phase implement
"$ORCH" state set issue 42
fake_issue 42 open
fake_fail adapter_issue_close $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "a gh that will not close the issue fails --new-issue" "$st" 1
assert_contains "passing gh's first line through, in the death (#846)" "$out" \
  "orch: gh could not close issue #42: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "leaving the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "implement"

out="$("$ORCH" redo spec --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh redo spec"
restore_suite_env

# --- redo spec retires the ticket breakdown (#334) ---------------------------
# A spec redone because it had to change gets a fresh breakdown: the default
# path retires the kept issue's old one before stepping back, so the spec
# phase's `ticket exists` answers 1 and orch-to-tickets runs again.
echo
echo "redo spec retires the ticket breakdown (#334)"
fresh_flow redospecbreakdown
fake_github
for p in 50 51 52 53 54 55 56 57 58; do fake_issue "$p" open; done
tbody="$(mktemp)"
writeln 'A ticket.' >"$tbody"
fake_next_issue 900
rt1="$("$ORCH" ticket publish 50 "One" "$tbody")"
rt2="$("$ORCH" ticket publish 50 "Two" "$tbody")"
rt3="$("$ORCH" ticket publish 50 "Three" "$tbody")"
"$ORCH" ticket close "$rt2" >/dev/null
fake_issue_body 50 'The spec of #50.'
redo_spec_at() {
  state_fixture phase implement
  "$ORCH" state set issue "$1"
  rm -rf .orchestrator/handoff/pre-redo-spec-*
  writeln '# spec' >.orchestrator/handoff/02-spec.md
  writeln '# implement' >.orchestrator/handoff/03-implement.md
}
redo_spec_at 50
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a sub-issue breakdown: redo spec succeeds" "$st" 0
assert_eq "the parent is left with no sub-issues" "$(fake_sub_issues_of 50)" ""
retire_msg="This ticket was retired: its spec, #50, changed and will be broken down into tickets again."
for t in "$rt1" "$rt2" "$rt3"; do
  assert_eq "old ticket #$t is closed" "$(fake_state_of "$t")" "CLOSED"
  assert_contains "old ticket #$t carries the retirement comment, naming a changed spec" \
    "$(fake_comments_of "$t")" "$retire_msg"
  assert_eq "old ticket #$t carries no comment in the old redo wording" \
    "$(fake_comments_of "$t" | grep -c "retired by an orchestrator redo")" "0"
done
assert_eq "an open old ticket is closed as not planned" "$(fake_reason_of "$rt1")" "not planned"
out="$("$ORCH" ticket exists 50 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1
assert_eq "phase becomes spec" "$("$ORCH" state get phase)" "spec"
assert_eq "keeping the issue" "$("$ORCH" state get issue)" "50"
out="$("$ORCH" ticket reset 50 2>&1)"; st=$?
assert_eq "a later ticket reset reopens none of the old tickets" \
  "$(fake_state_of "$rt1") $(fake_state_of "$rt2") $(fake_state_of "$rt3")" "CLOSED CLOSED CLOSED"

# Each body below is seeded as gh's read of it answers.
fake_body_read 51 'Intro\r\n\r\n## Ticket\r\n\r\n### What to build\r\nBuild.\r\n\r\n## After\r\nTail.\r\n'
redo_spec_at 51
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a collapsed CRLF breakdown: redo spec succeeds" "$st" 0
assert_eq "the ## Ticket section is gone and the rest of the CRLF body is unchanged" \
  "$(fake_body_of 51 | od -c)" "$(printf 'Intro\r\n\r\n## After\r\nTail.\r\n' | od -c)"
out="$("$ORCH" ticket exists 51 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1

fake_body_read 52 '%s\n' 'The spec.' '' '## Ticket' '' '```sh' '# not a heading' '```' 'Build it.'
redo_spec_at 52
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a collapsed breakdown at the body's end: redo spec succeeds" "$st" 0
assert_eq "drops the section and the blank line before it, a fenced # line included" \
  "$(fake_body_of 52 | od -c)" "$(writeln 'The spec.' | od -c)"

before="$(fake_snapshot)"
out="$("$ORCH" ticket retire 50 2>&1)"; st=$?
assert_status "retiring an already-retired sub-issue breakdown succeeds" "$st" 0
out="$("$ORCH" ticket retire 52 2>&1)"; st=$?
assert_status "retiring an already-retired collapsed breakdown succeeds" "$st" 0
assert_eq "and writes nothing to GitHub" "$(fake_snapshot)" "$before"

rt4="$("$ORCH" ticket publish 53 "Four" "$tbody")"
redo_spec_at 53
fake_fail adapter_sub_issue_unlink
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that will not unlink a ticket fails redo spec" "$st" 1
assert_contains "naming what failed" "$out" "gh could not unlink ticket #$rt4"
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
assert_eq "and the handoffs in place" "$(cat .orchestrator/handoff/02-spec.md .orchestrator/handoff/03-implement.md)" \
  "$(printf '# spec\n# implement')"
fake_unfail
fake_fail adapter_sub_issues
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that cannot list sub-issues fails redo spec" "$st" 1
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
fake_unfail
fake_issue_body 54 "$(writeln 'Spec.' '' '## Ticket' 'Build.')"
redo_spec_at 54
fake_fail adapter_issue_body_edit
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a gh that will not rewrite the body fails redo spec" "$st" 1
assert_eq "leaving the phase at implement" "$("$ORCH" state get phase)" "implement"
fake_unfail
redo_spec_at 53
out="$("$ORCH" redo spec 2>&1)"; st=$?
assert_status "a re-run after the failure resumes and succeeds" "$st" 0
assert_eq "retiring the ticket it could not unlink before" \
  "$(fake_sub_issues_of 53) $(fake_state_of "$rt4")" " CLOSED"

assert_eq "without commenting on it a second time" \
  "$(fake_comments_of "$rt4" | grep -cxF "This ticket was retired: its spec, #53, changed and will be broken down into tickets again.")" "1"

# A closed ticket still linked to its parent, carrying a comment in the old
# redo wording: the state a retire that died part-way under the old wording
# leaves. A retire now treats that comment as already posted.
rt5="$("$ORCH" ticket publish 55 "Five" "$tbody")"
"$ORCH" ticket close "$rt5" >/dev/null
fake_comment "$rt5" fake-gh 2026-01-01T00:00:00Z \
  "This ticket was retired by an orchestrator redo: its spec, #55, is being redone and will be broken down into tickets again."
fake_fail adapter_issue_comment
out="$("$ORCH" ticket retire 55 2>&1)"; st=$?
assert_status "a closed, linked ticket with an old-wording comment: retire succeeds, posting no second comment" "$st" 0
fake_unfail
assert_eq "leaving its one old-wording comment alone" "$(fake_comments_of "$rt5" | grep -c .)" "1"
assert_eq "and unlinking it" "$(fake_sub_issues_of 55)" ""
out="$("$ORCH" ticket exists 55 2>&1)"; st=$?
assert_status "ticket exists then finds no breakdown" "$st" 1

fake_issue_body 56 "$(writeln 'Intro' '```md' '## Ticket' 'example' '```' '' '## Ticket' 'Build.')"
out="$("$ORCH" ticket retire 56 2>&1)"; st=$?
assert_status "a body with a fenced ## Ticket example: retire succeeds" "$st" 0
assert_eq "cutting only the real section, the fenced example kept" \
  "$(fake_body_of 56 | od -c)" "$(writeln 'Intro' '```md' '## Ticket' 'example' '```' | od -c)"
out="$("$ORCH" ticket exists 56 2>&1)"; st=$?
assert_status "ticket exists then ignores the fenced example" "$st" 1
fake_issue_body 57 "$(writeln 'Intro' '```md' '## Ticket' '```')"
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 57 2>&1)"; st=$?
assert_status "a body whose only ## Ticket is fenced: retire succeeds, writing nothing to GitHub" "$st" 0
fake_unfail
out="$("$ORCH" ticket exists 57 2>&1)"; st=$?
assert_status "ticket exists finds no breakdown in a fenced ## Ticket alone" "$st" 1
fake_body_read 58 'Spec.\n\n## Ticket\nBuild.\n\n## After\nTail.\n\n\n'
"$ORCH" ticket retire 58 >/dev/null 2>&1
assert_eq "trailing blank lines after the section are kept" \
  "$(fake_body_of 58 | od -c)" "$(printf 'Spec.\n\n## After\nTail.\n\n\n' | od -c)"
fake_body_read 58 'Spec, no ticket heading.\n'
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 58 2>&1)"; st=$?
assert_status "a body with no ## Ticket heading: retire succeeds, writing nothing to GitHub" "$st" 0
fake_unfail

errf="$(mktemp)"
fake_issue_body 58 "$(writeln 'Spec.' '' '## Ticket' 'Build.')"
fake_fail adapter_issue_body
out="$("$ORCH" ticket retire 58 2>"$errf")"; st=$?
assert_status "a gh that cannot read the body fails ticket retire" "$st" 1
assert_eq "naming the body read: exact stderr" "$(cat "$errf")" "orch: gh could not read issue #58's body: fake gh: adapter_issue_body failed"
fake_unfail
fake_fail adapter_issue_body_edit
out="$("$ORCH" ticket retire 58 2>"$errf")"; st=$?
assert_status "a gh that cannot write the body fails ticket retire" "$st" 1
assert_eq "naming the section cut: exact stderr" "$(cat "$errf")" "orch: gh could not remove the ## Ticket section from #58: fake gh: adapter_issue_body_edit failed"
fake_unfail
rm -f "$errf"

# gh's reason rides on orch's own line, first line only, at every retire
# death (#846); the ## Ticket cut's read and write leave no temp file.
rw_tmp="$(mktemp -d)"
fake_fail adapter_issue_body $'HTTP 502: Bad Gateway\nsecond line'
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket retire 58 2>&1)"; st=$?
assert_status "a failed ## Ticket read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read issue #58's body: HTTP 502: Bad Gateway"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
fake_unfail
fake_fail adapter_issue_body_edit $'HTTP 502: Bad Gateway\nsecond line'
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket retire 58 2>&1)"; st=$?
assert_status "a failed ## Ticket write still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not remove the ## Ticket section from #58: HTTP 502: Bad Gateway"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
fake_unfail
fake_fail_times adapter_issue_body_edit 9
out="$(TMPDIR="$rw_tmp" "$ORCH" ticket retire 58 2>&1)"; st=$?
assert_status "a silent failed ## Ticket write exits 1" "$st" 1
assert_eq "ending in gh gave no reason" "$out" \
  "orch: gh could not remove the ## Ticket section from #58: gh gave no reason"
assert_eq "leaving no temp file" "$(ls -A "$rw_tmp")" ""
fake_unfail
rm -rf "$rw_tmp"

# A body gh reads back with no final newline gets none back from the cut.
bare_adapter="$(mktemp)"
writeln "source $(printf %q "$GH_ADAPTER_FAKE")" \
        'adapter_issue_body() {' \
        '  ! fake_failing adapter_issue_body || return 1' \
        '  fake_issue_known "$1" || return 1' \
        '  cat "$(fake_issue_dir "$1")/body"' \
        '}' >"$bare_adapter"
fake_body_read 58 'Spec.\n\n## Ticket\nBuild.\n\n## After\nTail.\n'
ORCH_GH_ADAPTER="$bare_adapter" "$ORCH" ticket retire 58 >/dev/null 2>&1; st=$?
assert_status "a body read with no final newline: retire succeeds" "$st" 0
assert_eq "the cut body gets no final newline back" \
  "$(fake_body_of 58 | od -c)" "$(printf 'Spec.\n\n## After\nTail.' | od -c)"
rm -f "$bare_adapter"

for p in 59 60; do fake_issue "$p" open; done
rt6="$("$ORCH" ticket publish 59 "Six" "$tbody")"
"$ORCH" ticket close "$rt6" >/dev/null
fake_fail adapter_issue_comments $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket retire 59 2>&1)"; st=$?
assert_status "a failed comments read still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read ticket #$rt6's comments: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_issue_comment $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket retire 59 2>&1)"; st=$?
assert_status "a failed retirement comment still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not comment on ticket #$rt6: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_sub_issue_unlink $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket retire 59 2>&1)"; st=$?
assert_status "a failed unlink still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not unlink ticket #$rt6 from #59: HTTP 502: Bad Gateway"
fake_unfail
rt7="$("$ORCH" ticket publish 60 "Seven" "$tbody")"
fake_fail adapter_issue_close $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" ticket retire 60 2>&1)"; st=$?
assert_status "a failed close still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not close ticket #$rt7: HTTP 502: Bad Gateway"
fake_unfail

rt5="$("$ORCH" ticket publish 55 "Five" "$tbody")"
redo_spec_at 55
out="$("$ORCH" redo spec --new-issue 2>&1)"; st=$?
assert_status "--new-issue still steps back to spec" "$st" 0
assert_eq "without retiring the closed issue's tickets" \
  "$(fake_sub_issues_of 55) $(fake_state_of "$rt5")" "$rt5 OPEN"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket retire is in the usage text" "$out" "ticket retire <parent>"
restore_suite_env
