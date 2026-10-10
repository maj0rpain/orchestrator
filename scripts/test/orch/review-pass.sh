# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- review-pass begin (#342) --------------------------------------------------
# A review pass's start: the guard and the numbered report prefix each have one
# right answer, so they live here. Needs no flow state, may run where init never
# did, and never wipes: a second pass on a branch never overwrites the first.
echo
echo "review-pass begin (#342)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
git config orchestrator.base trunk
git checkout -q -b trunk
git checkout -q -b quick/12-foo
rp_dir="$top/.orchestrator/review-pass/quick/12-foo"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "with no state file it proceeds" "$st" 0
assert_eq "printing the absolute iteration-01 prefix, the slashed branch as nested directories" \
  "$out" "$rp_dir/iteration-01"
assert_eq "creating the branch's directory" "$([ -d "$rp_dir" ] && echo yes || echo no)" "yes"
assert_eq "records no state" "$([ -f "$top/.orchestrator/state.json" ] && echo yes || echo no)" "no"
assert_contains "git-excludes .orchestrator/" "$(cat "$(git rev-parse --git-common-dir)/info/exclude")" ".orchestrator/"
assert_contains "git-excludes .scratch/" "$(cat "$(git rev-parse --git-common-dir)/info/exclude")" ".scratch/"
assert_eq "and leaves the working tree clean" "$(git status --porcelain)" ""
echo first >"$rp_dir/iteration-01-spec.md"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a second pass succeeds" "$st" 0
assert_eq "numbered iteration-02 once a report for 01 exists" "$out" "$rp_dir/iteration-02"
assert_eq "leaving the 01 report in place" "$(cat "$rp_dir/iteration-01-spec.md" 2>&1)" "first"
echo third >"$rp_dir/iteration-03-standards.md"
echo stray >"$rp_dir/iteration-09.md"
echo stray >"$rp_dir/notes-11-x.md"
out="$("$ORCH" review-pass begin 12 2>&1)"
assert_eq "one past the highest number, over a gap, ignoring stray files" "$out" "$rp_dir/iteration-04"

rp_state="$top/.orchestrator/state.json"
rp_flow() { printf '{"slug":"x","phase":"%s","issue":%s,"branch":%s}\n' "$1" "$2" "$3" >"$rp_state"; }
rp_next="/orchestrator:next (or orch-flow's Next phase section)"
for p in implement review; do
  rp_flow "$p" 12 '"orch/12-x"'
  before="$(cksum <"$rp_state")"
  out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
  assert_status "an active flow holding the issue at $p refuses it" "$st" 1
  assert_eq "naming the next command at $p" "$out" \
    "orch: the active flow holds issue #12 at phase $p - this change belongs to that flow's review loop; run $rp_next"
  assert_eq "state.json byte-identical at $p" "$(cksum <"$rp_state")" "$before"
done
rp_flow review 30 '"quick/12-foo"'
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "an active flow holding the current branch under another issue refuses it" "$st" 1
assert_eq "naming the flow's own issue" "$out" \
  "orch: the active flow holds issue #30 at phase review - this change belongs to that flow's review loop; run $rp_next"
rp_flow spec 12 null
before="$(cksum <"$rp_state")"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a flow at spec holding the issue refuses it" "$st" 1
assert_eq "with the spec-phase message" "$out" \
  "orch: the active flow holds issue #12 at phase spec - its change has not been built yet; run $rp_next"
assert_eq "state.json byte-identical at spec" "$(cksum <"$rp_state")" "$before"
rp_flow bogus 12 null
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a phase outside PHASES refuses it" "$st" 1
assert_eq "pointing at doctor --flow" "$out" \
  "orch: the active flow holds issue #12 at phase 'bogus', which is not a flow phase - refusing to review it; run orch.sh doctor --flow"
rp_flow "done" 12 '"quick/12-foo"'
before="$(cksum <"$rp_state")"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a done flow holding the issue and branch is allowed" "$st" 0
assert_eq "printing the next prefix" "$out" "$rp_dir/iteration-04"
assert_eq "state.json byte-identical after begin" "$(cksum <"$rp_state")" "$before"
rp_flow implement 14 '"orch/14-x"'
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "an active flow on another issue and branch lets it through" "$st" 0
rm -f "$rp_state"

for args in "" "abc" "12x" "../12" "12 13"; do
  # shellcheck disable=SC2086 # word splitting is the point: "12 13" is two args
  out="$("$ORCH" review-pass begin $args 2>&1)"; st=$?
  assert_status "refuses begin '$args'" "$st" 1
done
out="$("$ORCH" review-pass begin 2>&1)"
assert_contains "a missing number gets the usage" "$out" "usage: orch.sh review-pass begin <issue>"
out="$("$ORCH" review-pass begin abc 2>&1)"
assert_contains "a non-numeric issue is named" "$out" "issue must be a plain issue number"
out="$("$ORCH" review-pass wipe 12 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the one it does" "$out" "want begin"
git checkout -q trunk
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "refuses the base branch" "$st" 1
assert_contains "saying so" "$out" "is the base branch"
git checkout -q --detach
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "refuses a detached HEAD" "$st" 1
assert_contains "saying so" "$out" "not on a branch (detached HEAD)"
out="$("$ORCH" quick path 2>&1)"; st=$?
assert_status "quick path is gone" "$st" 1
assert_contains "as an unknown command" "$out" "unknown command: quick"
help="$("$ORCH" help)"
assert_contains "help documents review-pass begin" "$help" "review-pass begin <issue>"
assert_not_contains "help no longer mentions quick path" "$help" "quick path"
