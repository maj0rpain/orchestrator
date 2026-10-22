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
fake_comment 14 pat 2026-09-02T11:00:00Z "$(writeln '## Spec review' 'Round 1 of 1')"
fake_comment 14 pat 2026-09-02T11:30:00Z "A follow-up."
fake_comment 14 sam 2026-09-02T11:40:00Z "$(writeln 'A note that quotes' '## Spec review' 'lower down.')"
fake_issue 15 open
fake_comment 15 pat 2026-09-02T11:31:00Z "Not the flow's issue."
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments writes the flow issue's comments" "$st" 0
assert_eq "of the issue state records, each opened by its marker line, leaving out exactly the comments that open with ## Spec review (#1116)" \
  "$(cat "$spec_comments")" "$(writeln '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'A follow-up.' '' \
    '<!-- comment @sam 2026-09-02T11:40:00Z -->' 'A note that quotes' '## Spec review' 'lower down.')"
fake_github
fake_issue 14 open
fake_comment 14 pat 2026-09-02T11:00:00Z "$(writeln '## Spec review' 'Round 1 of 2')"
fake_comment 14 pat 2026-09-02T12:00:00Z "$(writeln '## Spec review' 'Round 2 of 2')"
printf 'known content\n' >"$spec_comments"
out="$("$ORCH" spec comments "$spec_comments" 2>&1)"; st=$?
assert_status "spec comments succeeds on a spec with only review changelogs" "$st" 0
assert_eq "leaving an empty file" "$(wc -c <"$spec_comments" | tr -d ' ')" "0"
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

# --- spec pause ---------------------------------------------------------------
# The spec phase's stop once it has written the spec (#1181): the marker names
# the flow's issue so the fresh session's spec phase goes straight to the spec
# review, and the block names the host's way to start that session. The phase
# stays spec - this is a stop inside a phase, not a boundary.
echo
echo "spec pause"
fresh_flow pausetest
fake_github
state_fixture phase spec
marker="$(dirname "$("$ORCH" handoff path spec)")/spec-paused"
out="$("$ORCH" spec pause 2>&1)"; st=$?
assert_status "spec pause refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
assert_eq "and writes no marker" "$(on_disk "$marker")" "absent"
"$ORCH" state set issue 21
out="$("$ORCH" spec pause 2>&1)"; st=$?
assert_status "spec pause succeeds at phase spec with an issue" "$st" 0
assert_eq "printing the stop block with the Claude Code Next line" "$out" \
  "$(printf 'Spec #21 written. The spec review runs in a fresh session.\n\n  Next: /clear, then /orchestrator:next')"
assert_eq "writing the marker naming the recorded issue" "$(cat "$marker")" "21"
assert_eq "and leaving the phase at spec" "$("$ORCH" state get phase)" "spec"
writeln 99 >"$marker"
out="$(ORCHESTRATOR_HOST=junie "$ORCH" spec pause 2>&1)"; st=$?
assert_status "spec pause runs again over a marker already there" "$st" 0
assert_eq "overwriting it with the recorded issue" "$(cat "$marker")" "21"
assert_eq "on Junie the Next line is Junie's" "$out" \
  "$(printf 'Spec #21 written. The spec review runs in a fresh session.\n\n  Next: /new, then ask for the next phase with /orch-flow')"
rm -f "$marker"
for ph in implement review; do
  state_fixture phase "$ph"
  out="$("$ORCH" spec pause 2>&1)"; st=$?
  assert_status "spec pause refuses at phase $ph" "$st" 1
  assert_contains "saying it runs only in the spec phase" "$out" "spec pause runs only in the spec phase"
  assert_eq "and writes no marker" "$(on_disk "$marker")" "absent"
done
state_fixture phase "done"
out="$("$ORCH" spec pause 2>&1)"; st=$?
assert_status "spec pause refuses once the flow is done" "$st" 1
assert_contains "naming the flow's issue" "$out" "the flow on issue #21 is done"
assert_eq "and writes no marker" "$(on_disk "$marker")" "absent"
state_fixture phase spec
out="$("$ORCH" spec pause extra 2>&1)"; st=$?
assert_status "spec pause takes no arguments" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec pause"
assert_contains "help documents spec pause" "$("$ORCH" help)" "spec pause"
new_repo >/dev/null
out="$("$ORCH" spec pause 2>&1)"; st=$?
assert_status "spec pause refuses with no flow" "$st" 1
assert_contains "saying there is no active flow" "$out" "no active flow"
restore_suite_env

# --- spec round-dir -----------------------------------------------------------
# A flow's spec review round works in a fixed directory derived from its
# number (#1346): round-dir makes it ready - emptied, round 1 clearing every
# other round's, a later round carrying in the previous round's code map and
# settled file - and writes the round marker last, so a round never runs
# without it.
echo
echo "spec round-dir"
fresh_flow rounddirtest
state_fixture phase spec
top="$(git rev-parse --show-toplevel)"
rounds="$top/.orchestrator/spec-rounds"
handoff_dir="$(dirname "$("$ORCH" handoff path spec)")"
round_marker="$handoff_dir/spec-round"
# rd_snapshot: every path under spec-rounds/ and the round marker's content,
# so a refusal is checked to have created and deleted nothing.
rd_snapshot() { find "$rounds" 2>/dev/null | sort; cat "$round_marker" 2>/dev/null; }
before="$(rd_snapshot)"
out="$("$ORCH" spec round-dir 1/1 2>&1)"; st=$?
assert_status "round-dir refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
assert_eq "creating nothing and writing no marker" "$(rd_snapshot)" "$before"
"$ORCH" state set issue 21
out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
assert_status "round-dir 1/2 succeeds at phase spec with an issue" "$st" 0
assert_eq "printing round 1's fixed directory and nothing else" "$out" "$rounds/1/"
assert_eq "which it creates, empty" "$(ls -A "$rounds/1" 2>&1)" ""
mkdir -p "$rounds/1/sub"
writeln stale >"$rounds/1/changelog.md"
writeln stale >"$rounds/1/settled.md"
writeln stale >"$rounds/1/sub/x"
out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
assert_status "round-dir runs again over a populated round directory" "$st" 0
assert_eq "emptying it" "$(ls -A "$rounds/1" 2>&1)" ""
mkdir -p "$rounds/2" "$rounds/3"
writeln stale >"$rounds/2/changelog.md"
writeln stale >"$rounds/3/map-implementability.md"
out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
assert_status "round-dir 1 succeeds over other rounds' directories" "$st" 0
assert_eq "deleting every one but its own" "$(ls -A "$rounds" 2>&1)" "1"

writeln 'the code map' >"$rounds/1/map-implementability.md"
writeln 'round 1 changelog' >"$rounds/1/settled.md"
writeln 'round 1 changelog' >"$rounds/1/changelog.md"
: >"$rounds/1/round-complete"
mkdir -p "$rounds/2"
writeln stale >"$rounds/2/spec.md"
out="$("$ORCH" spec round-dir 2/2 2>&1)"; st=$?
assert_status "round-dir 2/2 succeeds" "$st" 0
assert_eq "printing round 2's fixed directory" "$out" "$rounds/2/"
assert_eq "emptied, then holding only round 1's code map and settled file" \
  "$(ls -A "$rounds/2" 2>&1)" "$(writeln map-implementability.md settled.md)"
assert_eq "the code map copied as it was" "$(cat "$rounds/2/map-implementability.md")" "the code map"
assert_eq "and the settled file" "$(cat "$rounds/2/settled.md")" "round 1 changelog"
assert_eq "leaving round 1's directory as it was" "$(ls -A "$rounds/1" 2>&1)" \
  "$(writeln changelog.md map-implementability.md round-complete settled.md)"
rm -f "$rounds/1/map-implementability.md" "$rounds/1/settled.md"
out="$("$ORCH" spec round-dir 2/2 2>&1)"; st=$?
assert_status "round-dir 2/2 succeeds when round 1 left no code map or settled file" "$st" 0
assert_eq "silently, printing only the path" "$out" "$rounds/2/"
assert_eq "copying nothing" "$(ls -A "$rounds/2" 2>&1)" ""

out="$("$ORCH" spec round-dir 1/1 2>&1)"; st=$?
assert_status "round-dir 1/1 succeeds" "$st" 0
assert_eq "writing the marker, so spec round runs round 1 of 1" "$("$ORCH" spec round 2>&1)" "1 1"
: >"$rounds/1/round-complete"
assert_eq "and, once round 1 holds round-complete, every round is done" "$("$ORCH" spec round 2>&1)" "done 1"

before="$(rd_snapshot)"
for arg in "" 1 0/2 1/0 2/1 a/2 1/b 1/2/3 /2 1/ -1/2 "1 /2"; do
  out="$("$ORCH" spec round-dir "$arg" 2>&1)"; st=$?
  assert_status "round-dir refuses '$arg'" "$st" 1
  assert_eq "creating and deleting nothing for '$arg'" "$(rd_snapshot)" "$before"
done
assert_contains "naming the form it wants" "$out" "<k>/<n>"
out="$("$ORCH" spec round-dir 2>&1)"; st=$?
assert_status "round-dir refuses no argument" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec round-dir <k>/<n>"
out="$("$ORCH" spec round-dir 3/2 2>&1)"; st=$?
assert_status "round-dir refuses k past n" "$st" 1
assert_contains "naming the round count" "$out" "round count 2"
assert_eq "creating and deleting nothing" "$(rd_snapshot)" "$before"
for ph in implement review; do
  state_fixture phase "$ph"
  out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
  assert_status "round-dir refuses at phase $ph" "$st" 1
  assert_contains "saying it runs only in the spec phase" "$out" "spec round-dir runs only in the spec phase"
  assert_eq "creating and deleting nothing" "$(rd_snapshot)" "$before"
done
state_fixture phase "done"
out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
assert_status "round-dir refuses once the flow is done" "$st" 1
assert_contains "naming the flow's issue" "$out" "the flow on issue #21 is done"
assert_eq "creating and deleting nothing" "$(rd_snapshot)" "$before"
state_fixture phase spec

rm -f "$round_marker"
chmod a-w "$handoff_dir"
if : 2>/dev/null >"$handoff_dir/.probe"; then
  rm -f "$handoff_dir/.probe"
  chmod u+w "$handoff_dir"
  skip "a failed marker write prints no path" "the handoff folder stays writable (running as root?)"
else
  out="$("$ORCH" spec round-dir 1/2 2>&1)"; st=$?
  chmod u+w "$handoff_dir"
  assert_status "round-dir fails when the marker cannot be written" "$st" 1
  assert_not_contains "printing no path" "$out" "$rounds/1/"
  assert_contains "naming the marker" "$out" "$round_marker"
  assert_eq "and leaving no marker" "$(on_disk "$round_marker")" absent
fi
assert_contains "help documents spec round-dir" "$("$ORCH" help)" "spec round-dir <k>/<n>"
rm -rf "$rounds" "$round_marker"
restore_suite_env

# --- spec round ---------------------------------------------------------------
# The resumed session's marker check (#1346): the round to run next and the
# count, from the round marker and whether that round's directory holds
# round-complete. Exit 1 means "no marker for this flow", so every failure is
# exit 2 - step 0 must never read one as "no marker".
echo
echo "spec round"
fresh_flow roundtest
state_fixture phase spec
top="$(git rev-parse --show-toplevel)"
rounds="$top/.orchestrator/spec-rounds"
round_marker="$(dirname "$("$ORCH" handoff path spec)")/spec-round"
"$ORCH" state set issue 21
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round exits 1 with no marker" "$st" 1
assert_eq "printing nothing" "$out" ""
"$ORCH" spec round-dir 1/2 >/dev/null
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round succeeds with a marker" "$st" 0
assert_eq "printing the marker's round and count" "$out" "1 2"
"$ORCH" state set issue 22
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round exits 1 with a marker naming another issue" "$st" 1
assert_eq "printing nothing" "$out" ""
"$ORCH" state set issue 21
: >"$rounds/1/round-complete"
assert_eq "once round 1 holds round-complete, round 2 runs next" "$("$ORCH" spec round 2>&1)" "2 2"
writeln 'round 1 changelog' >"$rounds/1/settled.md"
"$ORCH" spec round-dir 2/2 >/dev/null
assert_eq "round 2's directory with only a carried-in settled.md is not done" \
  "$("$ORCH" spec round 2>&1)" "2 2"
: >"$rounds/2/round-complete"
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round succeeds once the last round is complete" "$st" 0
assert_eq "printing done and the count" "$out" "done 2"

saved_marker="$(cat "$round_marker")"
for bad_marker in "" garbage "21" "21 1" "21 3 2" "21 0 2" "21 a 2" "x 1 2" "21 1 2 9"; do
  writeln "$bad_marker" >"$round_marker"
  out="$("$ORCH" spec round 2>&1)"; st=$?
  assert_status "spec round exits 2 on the malformed marker '$bad_marker'" "$st" 2
  assert_contains "with an orch: message naming it" "$out" "orch: malformed round marker"
done
writeln "$saved_marker" >"$round_marker"
for ph in implement review; do
  state_fixture phase "$ph"
  out="$("$ORCH" spec round 2>&1)"; st=$?
  assert_status "spec round exits 2 at phase $ph" "$st" 2
  assert_contains "with an orch: message saying it runs only in the spec phase" "$out" \
    "orch: spec round runs only in the spec phase"
done
state_fixture phase "done"
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round exits 2 once the flow is done" "$st" 2
assert_contains "with an orch: message naming the flow's issue" "$out" "orch: the flow on issue #21 is done"
state_fixture phase spec
state_fixture_drop issue
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round exits 2 when state records no issue" "$st" 2
assert_contains "with an orch: message naming the phase that records one" "$out" "orch: no issue recorded"
out="$("$ORCH" spec round extra 2>&1)"; st=$?
assert_status "spec round takes no arguments, exiting 2" "$st" 2
assert_contains "with the usage" "$out" "usage: orch.sh spec round"
assert_contains "help documents spec round" "$("$ORCH" help)" "spec round  "
new_repo >/dev/null
out="$("$ORCH" spec round 2>&1)"; st=$?
assert_status "spec round exits 2 with no flow" "$st" 2
assert_contains "saying there is no active flow" "$out" "no active flow"
restore_suite_env
