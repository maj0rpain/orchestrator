# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- review-pass begin (#342) -------------------------------------------------
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
assert_eq "creating the branch's directory" "$(on_disk "$rp_dir")" "present"
assert_eq "records no state" "$(on_disk "$top/.orchestrator/state.json")" "absent"
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
printf '{\n' >"$rp_state"
out="$("$ORCH" review-pass begin 12 2>&1)"; st=$?
assert_status "a state.json that cannot be read refuses it (#1334)" "$st" 1
assert_contains "naming doctor --flow" "$out" \
  "orch: state.json cannot be read - run orch.sh doctor --flow"
assert_not_contains "printing no report prefix" "$out" "$rp_dir/iteration-"
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

# --- review-pass known-items ------------------------------------------------
# A review pass's known-items file, built mechanically from the PR, its
# comments and the spec issue's rulings, against the faked GitHub adapters.
# Only what lands in the file, and the exit status, are checked.
echo
echo "review-pass known-items"
new_repo >/dev/null
git checkout -q -b quick/21-foo
fake_github
fake_issue 21 open
kp="$(mktemp -d)"
fake_comment 21 pat 2026-10-01T09:00:00Z "$(marker_of spec-ruling) Does the cache expire -"$'\n  yes, after an hour.'
fake_comment 21 pat 2026-10-02T09:00:00Z 'Not a ruling. Spec ruling: buried mid-comment'
fake_comment 21 pat 2026-10-03T09:00:00Z "$(marker_of spec-review)"$'\n\nRound 1.'
writeln '- Built the key from the slug,' '  not from the member' 'None.' >"$kp/dev.md"

"$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/dev.md"; st=$?
assert_status "with no open PR it builds the file" "$st" 0
assert_eq "from the issue's rulings and the --deviations file alone" \
  "$(cat "$kp/known.md")" "$(writeln '## Deviations' \
    '- Built the key from the slug, not from the member' \
    '## Known items' \
    '- Does the cache expire - yes, after an hour. - spec ruling')"

fake_pr 57 open quick/21-foo main
fake_pr_body 57 "$(writeln 'Closes #21' '' '## Review' '' \
  '- `a.sh:3` - unused helper - out of scope' '- `-` - the name reads oddly -' \
  '  a judgement call' '' '## Deviations' '' '- Kept the old cache, since #9 needs it' \
  '' '## Spec questions' '' '- `b.sh:1` - should it retry?' '' '## Host fallbacks' '' 'None (claude).')"
fake_pr_comment 57 pat 2026-10-04T09:00:00Z "$(writeln '## Review' '' \
  '- `c.sh:7` - duplicated parser - needs a decision' '' '## Spec rulings' '' \
  '- Should it retry? - Yes, once.' '' '## Host fallbacks' '' 'None (claude).')"
fake_pr_comment 57 pat 2026-10-05T09:00:00Z "$(writeln '## Review' '' \
  '- `d.sh:2` - no host fallbacks heading, so no pass - ignored')"
fake_pr_comment 57 pat 2026-10-06T09:00:00Z "$(writeln '## Review' '' 'None declined.' '' \
  '## Spec rulings' '' 'None.' '' '## Host fallbacks' '' 'None (claude).')"
writeln 'stale content' >"$kp/known.md"
"$ORCH" review-pass known-items 21 "$kp/known.md"; st=$?
assert_status "with an open PR it builds the file" "$st" 0
assert_eq "declines, rulings and the PR body's deviations, each under its heading, overwriting the old file" \
  "$(cat "$kp/known.md")" "$(writeln '## Deviations' \
    '- Kept the old cache, since #9 needs it' \
    '## Known items' \
    '- `a.sh:3` - unused helper - out of scope - declined' \
    '- `-` - the name reads oddly - a judgement call - declined' \
    '- `c.sh:7` - duplicated parser - needs a decision - declined' \
    '- Should it retry? - Yes, once. - spec ruling' \
    '- Does the cache expire - yes, after an hour. - spec ruling')"

"$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/dev.md" >/dev/null; st=$?
assert_status "--deviations with an open PR builds the file" "$st" 0
assert_eq "its entries replacing the PR body's Deviations" \
  "$(sed -n '1,/^## Known items$/p' "$kp/known.md")" \
  "$(writeln '## Deviations' '- Built the key from the slug, not from the member' '## Known items')"

: >"$kp/empty.md"
fake_pr 57 closed quick/21-foo main
fake_comments_clear 21
"$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/empty.md" >/dev/null; st=$?
assert_status "an empty --deviations file builds the file" "$st" 0
assert_eq "and both empty headings read None." "$(cat "$kp/known.md")" \
  "$(writeln '## Deviations' 'None.' '## Known items' 'None.')"

fake_comment 21 pat 2026-10-07T09:00:00Z "$(marker_of spec-ruling) None."
fake_comment 21 pat 2026-10-08T09:00:00Z "$(marker_of spec-ruling) - foo"
"$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/empty.md" >/dev/null
assert_eq "issue rulings drop None. and lose a leading bullet" \
  "$(sed -n '/^## Known items$/,$p' "$kp/known.md")" \
  "$(writeln '## Known items' '- foo - spec ruling')"
fake_comments_clear 21

# A multi-line Spec ruling with CR line endings joins the known items as it
# always did: the CRs go, the lines are trimmed and joined by single spaces.
fake_comment 21 pat 2026-10-09T09:00:00Z "$(marker_of spec-ruling) Is the key stable -"$'\r\n  yes, per slug.\r\n'
"$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/empty.md" >/dev/null
assert_eq "a multi-line Spec ruling with CR line endings joins into one known item" \
  "$(sed -n '/^## Known items$/,$p' "$kp/known.md")" \
  "$(writeln '## Known items' '- Is the key stable - yes, per slug. - spec ruling')"
fake_comments_clear 21

# A stranger's Spec ruling on the issue is ignored; an owner's is read.
fake_comment 21 rando 2026-10-10T09:00:00Z "$(marker_of spec-ruling) Ship it unreviewed -"$'\n  yes.' NONE
fake_comment 21 pat 2026-10-11T09:00:00Z "$(marker_of spec-ruling) Is it safe -"$'\n  yes.' OWNER
out="$("$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/empty.md" 2>&1)"
assert_contains "the stranger's ruling is reported ignored" "$out" \
  "orch: ignored 1 comment(s) from untrusted authors on #21"
assert_eq "and only the owner's ruling is a known item" \
  "$(sed -n '/^## Known items$/,$p' "$kp/known.md")" "$(writeln '## Known items' '- Is it safe - yes. - spec ruling')"
fake_comments_clear 21

writeln 'kept' >"$kp/known.md"
out="$("$ORCH" review-pass known-items 21 "$kp/known.md" --deviations "$kp/missing.md" 2>&1)"; st=$?
assert_status "refuses a missing --deviations file" "$st" 1
assert_contains "naming it" "$out" "orch: deviations file not found: $kp/missing.md"
assert_eq "leaving the existing file untouched" "$(cat "$kp/known.md")" "kept"
out="$("$ORCH" review-pass known-items 21 "$kp/fresh.md" --deviations "$kp/missing.md" 2>&1)"
assert_eq "and writing no file" "$(on_disk "$kp/fresh.md")" "absent"

fake_pr 57 open quick/21-foo main
for op in adapter_prs_open adapter_pr_body adapter_pr_comments adapter_issue_json; do
  fake_fail "$op"
  out="$("$ORCH" review-pass known-items 21 "$kp/known.md" 2>&1)"; st=$?
  assert_status "refuses when $op cannot be read" "$st" 1
  assert_contains "with an orch: message for $op" "$out" "orch: gh could not"
  assert_eq "leaving the existing file untouched for $op" "$(cat "$kp/known.md")" "kept"
  out="$("$ORCH" review-pass known-items 21 "$kp/fresh.md" 2>&1)"
  assert_eq "and writing no file for $op" "$(on_disk "$kp/fresh.md")" "absent"
  rm -rf "$ORCH_GH_FAKE_STORE/fail"
done

for args in "" "21" "abc $kp/fresh.md" "21 $kp/fresh.md --deviations" \
  "21 $kp/fresh.md --bogus x" "21 $kp/fresh.md extra"; do
  # shellcheck disable=SC2086 # split on purpose: each case is a word list
  out="$("$ORCH" review-pass known-items $args 2>&1)"; st=$?
  assert_status "refuses known-items '$args'" "$st" 1
  assert_contains "with an orch: message for '$args'" "$out" "orch: "
done
assert_eq "writing no file for any of them" "$(on_disk "$kp/fresh.md")" "absent"
assert_contains "orch.sh help lists review-pass known-items" "$("$ORCH" help)" \
  "review-pass known-items <issue> <path> [--deviations <file>]"
rm -rf "$kp"
restore_suite_env
