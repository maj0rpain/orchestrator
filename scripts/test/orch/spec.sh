# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- spec ---------------------------------------------------------------------
# The spec review's one hand on GitHub: fetch the body, replace it, comment on
# it. The number comes from state so a review can never touch the wrong issue,
# and the store-backed fake (fake_github) holds what reached GitHub, so the
# test reads the body sent back, not only that the command exited zero -
# the fixture gh's log stays empty across every call below, proving none of them ever
# spawns a real gh subprocess. The real operations are pinned in "gh adapter
# contract".
echo
echo "spec"
fresh_flow spectest
fake_github
state_fixture phase review
spec_body="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
out="$("$ORCH" spec update "$spec_body" 2>&1)"; st=$?
assert_status "update refuses too" "$st" 1
assert_contains "for the same reason" "$out" "spec phase"
out="$("$ORCH" spec comment "$spec_body" 2>&1)"; st=$?
assert_status "and comment" "$st" 1
assert_contains "likewise" "$out" "spec phase"

"$ORCH" state set issue 14
fake_issue 14 open
fake_issue 15 open
# A body with everything a heredoc or a shell quote would mangle: a table, a
# fence, a `#nn` reference. What the lenses read must be what GitHub holds.
tricky="$(mktemp)"
writeln '## Solution' '' \
        '| Lens | Reads |' '|---|---|' '| Fidelity | plan handoff |' '' \
        '```sh' 'orch.sh spec fetch "$file"' '```' '' \
        'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
rm -f "$spec_body"
: >"$GH_FIXTURE/env.log"
fake_issue_body 14 "$(cat "$tricky")"
fake_issue_body 15 "Not the flow's issue."
untouched_15="$(fake_snapshot | grep '/issues/15/')"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch writes the body to the file" "$st" 0
assert_eq "of the issue state records, exactly as GitHub holds it - table, fence, and #nn survive" \
  "$(cat "$spec_body")" "$(cat "$tricky")"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

# The skill fetches into a fresh directory under .orchestrator/, so the first
# fetch of a review is the one that has to create it.
out="$("$ORCH" spec fetch .orchestrator/spec-review/spec.md 2>&1)"; st=$?
assert_status "fetch creates the directory it is told to write into" "$st" 0
assert_eq "and the body lands there" "$(cat .orchestrator/spec-review/spec.md)" "$(cat "$tricky")"
rm -rf .orchestrator/spec-review

rm -f "$spec_body"
fake_fail adapter_issue_body "fake gh: issue view refused"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the fetch" "$st" 1
assert_contains "with the reason" "$out" "issue view refused"
assert_eq "and leaves no file a lens could mistake for a body" \
  "$([ -e "$spec_body" ] && echo present || echo gone)" "gone"

: >"$GH_FIXTURE/env.log"
fake_issue_body 14 "The old body."
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "update replaces the body" "$st" 0
assert_eq "of the issue state records, with the file's contents" "$(fake_body_of 14)" "$(cat "$tricky")"
assert_eq "and no other" "$(fake_snapshot | grep '/issues/15/')" "$untouched_15"
assert_eq "and prints nothing" "$out" ""
assert_eq "the edit call never reached a real gh subprocess" "$(gh_calls)" "0"

before_store="$(fake_snapshot)"
out="$("$ORCH" spec update /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"

fake_fail adapter_issue_body_edit "fake gh: issue edit refused"
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "with gh's reason" "$out" "issue edit refused"
assert_contains "and the issue it was for" "$out" "issue #14"

: >"$GH_FIXTURE/env.log"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file" "$st" 0
assert_eq "on the issue state records, with the file's contents as the comment" \
  "$(fake_comments_of 14)" "$(cat "$tricky")"
assert_eq "and no other" "$(fake_snapshot | grep '/issues/15/')" "$untouched_15"
assert_eq "the comment call never reached a real gh subprocess" "$(gh_calls)" "0"

before_store="$(fake_snapshot)"
out="$("$ORCH" spec comment /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"

fake_fail adapter_issue_comment "fake gh: issue comment refused"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not comment fails it" "$st" 1
assert_contains "with gh's reason" "$out" "issue comment refused"
assert_contains "and the issue it was for" "$out" "issue #14"

# state.json outlives the flow it records: at phase done, the issue it names
# is finished work, so the flow-bound spec ops refuse it and point at the
# stateless issue ops for whatever issue the caller actually meant.
prior_phase="$("$ORCH" state get phase)"
state_fixture phase "done"
fake_github
fake_issue 14 open
fake_issue_body 14 "The flow's spec."
for op in fetch update comment; do
  before_store="$(fake_snapshot)"
  out="$("$ORCH" spec "$op" "$tricky" 2>&1)"; st=$?
  assert_status "spec $op refuses once the flow is done" "$st" 1
  assert_contains "naming the flow's issue" "$out" "issue #14"
  assert_contains "and pointing at issue $op for another issue" "$out" "issue $op <n>"
  assert_eq "and nothing reaches gh" "$(fake_snapshot)" "$before_store"
done
state_fixture phase spec
spec_scratch="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_scratch" 2>&1)"; st=$?
assert_status "spec fetch still works at phase spec" "$st" 0
out="$("$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "spec update still works at phase spec" "$st" 0
assert_eq "on the flow's issue" "$(fake_body_of 14)" "$(cat "$tricky")"
out="$("$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "spec comment still works at phase spec" "$st" 0
assert_eq "on the flow's issue" "$(fake_comments_of 14)" "$(cat "$tricky")"
rm -f "$spec_scratch"
state_fixture phase "$prior_phase"

# spec comments: the active flow's spec issue's comments, the number from
# state (issue #361).
spec_comments="$(mktemp)"
fake_github
fake_issue 14 open
fake_comment 14 pat 2026-09-02T11:30:00Z "A follow-up."
fake_issue 15 open
fake_comment 15 pat 2026-09-02T11:31:00Z "Not the flow's issue."
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments writes the flow issue's comments" "$st" 0
assert_eq "of the issue state records, each opened by its marker line" "$(cat "$spec_comments")" \
  "$(writeln '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'A follow-up.')"
state_fixture phase "done"
: >"$spec_comments"
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments refuses once the flow is done" "$st" 1
assert_contains "naming the flow's issue" "$out" "issue #14"
assert_contains "and pointing at issue comments for another issue" "$out" "issue comments <n>"
assert_eq "and reads nothing into the file" "$(wc -c <"$spec_comments" | tr -d ' ')" "0"
state_fixture phase "$prior_phase"
rm -f "$spec_comments"
assert_contains "help documents spec comments" "$("$ORCH" help)" "spec comments"
out="$("$ORCH" spec 2>&1)"; st=$?
assert_status "spec with no op refuses" "$st" 1
assert_contains "naming the missing op as <none>" "$out" "unknown spec op: <none>"
assert_contains "and listing the ops, comments among them" "$out" "fetch|update|comment|comments"

out="$("$ORCH" spec publish "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the four it does" "$out" "fetch|update|comment|comments"
out="$("$ORCH" spec fetch 2>&1)"; st=$?
assert_status "and a call with no file" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec"
assert_contains "help documents the spec verb" "$("$ORCH" help)" "spec fetch"
assert_contains "help says the spec ops refuse once the flow is done" "$("$ORCH" help)" "refusing once the flow is done"
assert_contains "and points at issue <op> for any other issue" "$("$ORCH" help)" "issue <op> <n> <file>"
restore_suite_env
