# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- spec-review begin (#224) ------------------------------------------------
# A standalone spec review's guard and working-directory reset have one right
# answer each, so they live here: refuse an issue an active flow holds, and
# otherwise hand back an emptied .orchestrator/spec-review/<n>/.
echo
echo "spec-review begin (#224)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
sr_dir="$top/.orchestrator/spec-review/14"
mkdir -p "$sr_dir/sub"
echo stale >"$sr_dir/spec.md"
echo stale >"$sr_dir/sub/changelog.md"
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "with no state file it proceeds" "$st" 0
assert_eq "printing the working directory and nothing else" "$out" "$sr_dir/"
assert_eq "which exists and is empty" "$(ls -A "$sr_dir" 2>&1)" ""
[ -f "$top/.orchestrator/state.json" ] && bad "writes no state file" "state.json appeared" \
  || ok "writes no state file"
out="$("$ORCH" spec-review begin 15 2>&1)"; st=$?
assert_status "a directory that was never there is created" "$st" 0
assert_eq "empty" "$(ls -A "$top/.orchestrator/spec-review/15" 2>&1)" ""

sr_state="$top/.orchestrator/state.json"
sr_flow() { printf '{"slug":"x","phase":"%s","issue":%s,"branch":null}\n' "$1" "$2" >"$sr_state"; }
sr_seed() { mkdir -p "$sr_dir"; echo keep >"$sr_dir/spec.md"; }
for p in spec implement review; do
  sr_flow "$p" 14; sr_seed
  before="$(cksum <"$sr_state")"
  out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
  assert_status "an active flow on 14 at $p refuses 14" "$st" 1
  if [ "$p" = spec ]; then
    assert_contains "pointing at next at $p" "$out" "/orchestrator:next"
    assert_contains "because the spec phase will review it" "$out" "spec phase"
  else
    assert_contains "pointing at redo at $p" "$out" "/orchestrator:redo"
    assert_contains "because the tickets build from it at $p" "$out" "cannot change behind the flow"
  fi
  assert_contains "naming the issue at $p" "$out" "#14"
  assert_eq "leaving the directory untouched at $p" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
  assert_eq "and state.json byte-for-byte unchanged at $p" "$(cksum <"$sr_state")" "$before"
done

# State never holds any other phase; a corrupt one is refused, not guessed at.
sr_flow bogus 14; sr_seed
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "a phase outside PHASES refuses 14" "$st" 1
assert_contains "pointing at doctor" "$out" "doctor --flow"
assert_eq "leaving the directory untouched" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"

sr_flow implement 14; sr_seed
before="$(cksum <"$sr_state")"
out="$("$ORCH" spec-review begin 15 2>&1)"; st=$?
assert_status "an active flow on 14 lets 15 through" "$st" 0
assert_eq "printing 15's directory" "$out" "$top/.orchestrator/spec-review/15/"
assert_eq "leaving 14's directory alone" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
assert_eq "state.json unchanged by a pass" "$(cksum <"$sr_state")" "$before"

sr_flow "done" 14; sr_seed
before="$(cksum <"$sr_state")"
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "a done flow on 14 lets 14 through" "$st" 0
assert_eq "printing its directory" "$out" "$sr_dir/"
assert_eq "wiped" "$(ls -A "$sr_dir" 2>&1)" ""
assert_eq "state.json unchanged by a done-flow pass" "$(cksum <"$sr_state")" "$before"

rm -f "$sr_state"
sr_seed
for args in "" "abc" "14x" "../14" "14 15"; do
  # shellcheck disable=SC2086 # word splitting is the point: "14 15" is two args
  out="$("$ORCH" spec-review begin $args 2>&1)"; st=$?
  assert_status "refuses begin '$args'" "$st" 1
  assert_eq "and deletes nothing for '$args'" "$(cat "$sr_dir/spec.md" 2>&1)" "keep"
done
out="$("$ORCH" spec-review begin 2>&1)"
assert_contains "a missing number gets the usage" "$out" "usage: orch.sh spec-review begin <n>"
out="$("$ORCH" spec-review begin abc 2>&1)"
assert_contains "a non-numeric number is named" "$out" "plain issue number"
out="$("$ORCH" spec-review wipe 14 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the one it does" "$out" "want begin"
assert_contains "help documents spec-review begin" "$("$ORCH" help)" "spec-review begin <n>"

# --- quick implementation runs an unattended spec review (#237) -------------
# A quick implementation runs an unattended standalone spec review before any flow
# exists, so spec-review begin needs no state.
echo
echo "quick implementation runs an unattended spec review (#237)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
out="$("$ORCH" spec-review begin 21 2>&1)"; st=$?
assert_status "spec-review begin with no flow state succeeds" "$st" 0
assert_eq "and prints the working directory" "$out" "$top/.orchestrator/spec-review/21/"

# --- spec-review apply (#1117) -------------------------------------------------
# A round's answer, taken as given: the accepted items applied to spec.md by
# exact anchor, the body published when it changed, and the changelog written
# and posted - every check before the first write. GitHub is the store-backed
# fake; each case reads back what reached it.
echo
echo "spec-review apply (#1117)"
new_repo >/dev/null
fake_github
top="$(git rev-parse --show-toplevel)"
sra_body='# Spec

Alpha line.
Beta line.
Gamma line.
Delta line.
Twice.
Twice.
'
# sra_dir: a fresh round directory holding the fixture spec, batch and lens
# files, with issue #14 reset to the fixture body; prints its path.
sra_dir() {
  local d
  d="$(mktemp -d)"
  printf '%s' "$sra_body" >"$d/spec.md"
  cat >"$d/batch.md" <<'BATCH'
@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability not-run timed out twice

@@ item 1 consolidation apply
@@ comment @alice 2026-01-02T00:00:00Z
@@ quote
Alpha should say
alpha prime.
@@ summary Folded in @alice's comment on Alpha
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end

@@ item 2 contradicts-the-plan decline the plan chose this
@@ finding fidelity 1
@@ summary Reverse the plan on Beta
@@ anchor
Beta line.
@@ replace
Beta reversed.
@@ end

@@ item 3 consistency decision A
@@ finding consistency 1
@@ finding testability 1
@@ option A Keep gamma
@@ summary Gamma kept
@@ anchor
Gamma line.
@@ replace
Gamma line (kept).
@@ end
@@ option B Drop gamma
@@ summary Gamma dropped
@@ anchor
Gamma line.
@@ replace
Gamma dropped.
@@ end

@@ item 4 testability apply
@@ finding testability 2
@@ summary Insert a test note after Delta
@@ anchor
Delta line.
@@ replace
Delta line.
Test note.
@@ end

@@ item 5 testability resolved
@@ finding testability 3
@@ resolved-by 4
BATCH
  printf '@@ finding 1\nThe spec reverses the plan'"'"'s\nchoice of beta.\n' >"$d/lens-fidelity.md"
  printf '@@ finding 1\nGamma contradicts the summary.\n' >"$d/lens-consistency.md"
  printf '@@ finding 1\nGamma is untestable.\n@@ finding 2\nDelta has no test.\n\n@@ finding 3\nDelta needs a note.\n' >"$d/lens-testability.md"
  fake_issue 14 open
  fake_issue_body 14 "$sra_body"
  printf '%s\n' "$d"
}
# sra <dir> <answer> [flags...]: apply on issue #14, standalone, round 1 of 2,
# its output and status into out and st.
sra() {
  local d="$1" a="$2"
  shift 2
  out="$("$ORCH" spec-review apply "$d" "$a" --round 1/2 --issue 14 "$@" 2>&1)"; st=$?
}
# sra_refused <label> <dir> <want-in-message> <answer> [flags...]: apply is
# refused, naming <want>, with nothing written: spec.md and changelog.md as
# they were, and the store untouched.
sra_refused() {
  local label="$1" d="$2" want="$3" before snap
  shift 3
  before="$(cat "$d/spec.md"; echo; cat "$d/changelog.md" 2>/dev/null)"
  snap="$(fake_snapshot)"
  sra "$d" "$@"
  assert_status "$label: refused" "$st" 1
  assert_contains "$label: naming it" "$out" "$want"
  assert_eq "$label: spec.md and changelog.md unchanged" \
    "$(cat "$d/spec.md"; echo; cat "$d/changelog.md" 2>/dev/null)" "$before"
  assert_eq "$label: no GitHub write" "$(fake_snapshot)" "$snap"
}

# Apply as recommended.
d="$(sra_dir)"
sra "$d" recommended
assert_status "recommended applies" "$st" 0
assert_eq "the recommended items, and only they, land in spec.md - the insertion keeping its anchor" \
  "$(cat "$d/spec.md")" '# Spec

Alpha prime line.
Beta line.
Gamma line (kept).
Delta line.
Test note.
Twice.
Twice.'
assert_eq "the body published is spec.md" "$(fake_body_of 14)" "$(cat "$d/spec.md")"
assert_eq "spec.fetched.md is the body as fetched" "$(cat "$d/spec.fetched.md")" "$(printf '%s' "$sra_body")"
sra_log='## Spec review
Round 1 of 2

### Consolidation
- (1) Folded in @alice'"'"'s comment on Alpha

### Fidelity
- (2) "The spec reverses the plan'"'"'s choice of beta." - spec departs from the plan: declined as recommended: the plan chose this

### Consistency
- (3) decision: took A - Keep gamma

### Testability
- (3) decision: took A - Keep gamma
- (4) Insert a test note after Delta
- (5) resolved by (4)

### Implementability
not run - timed out twice

### Tickets
None - no ticket breakdown'
assert_eq "the changelog, line for line" "$(cat "$d/changelog.md")" "$sra_log"
assert_eq "posted as the round's one comment" "$(fake_comments_of 14)" "$sra_log"
assert_eq "applied.log records both writes" "$(cat "$d/applied.log")" \
  "the body of issue #14
the changelog comment on issue #14"
sra_clean="$(cat "$d/spec.md")"

# A rerun once a write landed is refused, naming the writes.
sra_refused "a non-empty applied.log" "$d" "the body of issue #14; the changelog comment on issue #14" recommended

# Apply all: the recommend-decline item too.
d="$(sra_dir)"
sra "$d" all
assert_status "all applies" "$st" 0
assert_contains "the declined-as-recommended edit lands too" "$(cat "$d/spec.md")" "Beta reversed."
assert_eq "recorded under Fidelity by its summary" \
  "$(has_line "$(cat "$d/changelog.md")" "- (2) Reverse the plan on Beta")" yes

# Apply none: nothing changes, so no body update, and the changelog is posted.
d="$(sra_dir)"
printf '1: the comment is stale\n' >"$d/reasons"
fake_fail adapter_issue_body_edit
sra "$d" none --reasons "$d/reasons"
assert_status "none applies, without a body update" "$st" 0
fake_unfail
assert_eq "spec.md is the body as fetched" "$(cat "$d/spec.md")" "$(printf '%s' "$sra_body")"
assert_eq "the body is not written" "$(fake_body_of 14)" "$(printf '%s' "$sra_body")"
sra_cl="$(cat "$d/changelog.md")"
assert_eq "a declined consolidation item quotes its comment, then the human's reason" \
  "$(has_line "$sra_cl" '- (1) "Alpha should say alpha prime." - the comment is stale')" yes
assert_eq "a decision left out is quoted on each side, then left undecided" \
  "$(has_line "$sra_cl" '- (3) "Gamma contradicts the summary." / "Gamma is untestable." - left undecided')" yes
assert_eq "an apply item declined with no reason reads declined" \
  "$(has_line "$sra_cl" '- (4) "Delta has no test." - declined')" yes
assert_eq "Tickets: not checked" "$(has_line "$sra_cl" "Not checked - no edit applied")" yes
assert_eq "the changelog is still posted" "$(fake_comments_of 14)" "$sra_cl"
assert_eq "applied.log records only the comment" "$(cat "$d/applied.log")" "the changelog comment on issue #14"

# An Other list with a decision letter; an item left out is declined.
d="$(sra_dir)"
printf '\n2: keep the plan\n' >"$d/reasons"
sra "$d" "3B, 4" --reasons "$d/reasons"
assert_status "an Other list applies" "$st" 0
assert_eq "exactly the items named, the decision by its letter" "$(cat "$d/spec.md")" '# Spec

Alpha line.
Beta line.
Gamma dropped.
Delta line.
Test note.
Twice.
Twice.'
sra_cl="$(cat "$d/changelog.md")"
assert_eq "the decision taken" "$(has_line "$sra_cl" "- (3) decision: took B - Drop gamma")" yes
assert_eq "an item left out, declined by the human" \
  "$(has_line "$sra_cl" '- (1) "Alpha should say alpha prime." - declined')" yes
assert_eq "a contradicts-the-plan decline with the human's reason" \
  "$(has_line "$sra_cl" '- (2) "The spec reverses the plan'"'"'s choice of beta." - spec departs from the plan: keep the plan')" yes

d="$(sra_dir)"
sra "$d" "1, 4"
assert_status "an Other list leaving a decision out applies" "$st" 0
assert_contains "the decision item's anchor untouched" "$(cat "$d/spec.md")" $'\nGamma line.\n'
assert_eq "left undecided under Consistency and Testability alike" \
  "$(grep -c '^- (3) .* - left undecided$' "$d/changelog.md")" 2

# Answers refused before any write.
d="$(sra_dir)"
echo "old log" >"$d/changelog.md"
sra_refused "an unknown item" "$d" "item 9" "1, 9"
sra_refused "an unknown option" "$d" "option C" "3C"
sra_refused "a letter on no decision" "$d" "no decision item" "4B"
sra_refused "a decision with no letter" "$d" "without an option letter" "3"
sra_refused "a resolved item named" "$d" "resolved by item 4" "4, 5"
sra_refused "an item named twice" "$d" "twice" "4, 4"
sra_refused "a malformed answer" "$d" "is no item" "1;2"

# Anchors: no match, two matches - the whole batch refused.
sed -i 's/^Delta line\.$/Nowhere line./' "$d/batch.md"
sra_refused "an anchor matching nothing" "$d" "item 4: its anchor matches no text" recommended
sed -i 's/^Nowhere line\.$/Twice./' "$d/batch.md"
sra_refused "an anchor matching twice" "$d" "item 4: its anchor matches more than one place" recommended
sed -i 's/^Twice\.$/Delta line./' "$d/batch.md"
sra "$d" recommended
assert_status "the corrected rerun applies" "$st" 0
assert_eq "leaving the same spec.md as a clean run" "$(cat "$d/spec.md")" "$sra_clean"

# A malformed batch file, named by its line.
d="$(sra_dir)"
sed -i '7s/.*/@@ bogus/' "$d/batch.md"
sra_refused "an unknown batch line" "$d" "batch.md line 7: unknown line '@@ bogus'" recommended
d="$(sra_dir)"
printf 'stray text\n' >>"$d/batch.md"
sra_refused "text outside a block" "$d" "batch.md line 58: text outside" recommended
d="$(sra_dir)"
sed -i '/^@@ summary Insert/d' "$d/batch.md"
sra_refused "an item with no summary" "$d" "item 4 has no @@ summary" recommended
d="$(sra_dir)"
sed -i '/^@@ lens consistency/d' "$d/batch.md"
sra_refused "a lens with no @@ lens line" "$d" "no @@ lens line for consistency" recommended

# Lens files and citations.
d="$(sra_dir)"
sed -i 's/^@@ finding testability 3$/@@ finding testability 4/' "$d/batch.md"
sra_refused "a finding past its lens file's count" "$d" "lens-testability.md holds 3" recommended
d="$(sra_dir)"
rm "$d/lens-consistency.md"
sra_refused "a missing lens file" "$d" "lens-consistency.md not found" recommended
d="$(sra_dir)"
printf 'preamble\n@@ finding 1\nx\n' >"$d/lens-consistency.md"
sra_refused "a malformed lens file" "$d" "lens-consistency.md line 1" recommended
d="$(sra_dir)"
printf '@@ finding 1\nx\n@@ finding 3\ny\n' >"$d/lens-consistency.md"
sra_refused "a lens file out of order" "$d" "expected @@ finding 2" recommended

# --reasons.
d="$(sra_dir)"
printf 'one: why\n' >"$d/reasons"
sra_refused "a malformed reasons line" "$d" "--reasons line 1" none --reasons "$d/reasons"
printf '9: why\n' >"$d/reasons"
sra_refused "a reason for an unknown item" "$d" "item 9" none --reasons "$d/reasons"
printf '4: why\n' >"$d/reasons"
sra_refused "a reason for an accepted item" "$d" "does not decline" recommended --reasons "$d/reasons"

# --unattended.
d="$(sra_dir)"
out="$("$ORCH" spec-review apply "$d" recommended --round 1/1 --unattended 2>&1)"; st=$?
assert_status "--unattended without --issue is refused" "$st" 1
assert_contains "saying so" "$out" "--unattended needs --issue"
sra_refused "--unattended with another answer" "$d" "takes only the answer recommended" all --unattended
sed -i 's/^@@ lens fidelity ran$/@@ lens fidelity standalone/; /^@@ item 2 /,/^@@ end$/d' "$d/batch.md"
printf 'AskUserQuestion fell back to a plain question\n' >"$d/hosts"
sra "$d" recommended --unattended --host-fallbacks "$d/hosts"
assert_status "--unattended applies as recommended" "$st" 0
assert_eq "its changelog" "$(cat "$d/changelog.md")" '## Spec review
Round 1 of 2
Unattended spec review, run from a quick implementation: applied as recommended.

### Consolidation
- (1) Folded in @alice'"'"'s comment on Alpha

### Fidelity
not run - standalone review, no plan to check against

### Consistency
- decision (3): took A - Keep gamma, as recommended

### Testability
- decision (3): took A - Keep gamma, as recommended
- (4) Insert a test note after Delta
- (5) resolved by (4)

### Implementability
not run - timed out twice

### Tickets
None - no ticket breakdown

**Host fallbacks:** AskUserQuestion fell back to a plain question'

# The ticket step's entry: a breakdown pauses before any GitHub write.
d="$(sra_dir)"
fake_issue 20 open
mkdir -p "$ORCH_GH_FAKE_STORE/subs" && printf '20\n' >"$ORCH_GH_FAKE_STORE/subs/14"
snap="$(fake_snapshot)"
sra "$d" recommended
assert_status "a breakdown and an applied edit pause with exit 3" "$st" 3
assert_eq "printing the breakdown kind" "$out" "sub-issues"
assert_eq "no GitHub write" "$(fake_snapshot)" "$snap"
assert_eq "spec.md edited" "$(cat "$d/spec.md")" "$sra_clean"
assert_eq "no changelog.md" "$(on_disk "$d/changelog.md")" absent
sra "$d" recommended
assert_status "a rerun pauses again" "$st" 3
rm "$ORCH_GH_FAKE_STORE/subs/14"
sra "$d" recommended
assert_status "with the breakdown gone it runs through" "$st" 0
assert_eq "applying from the fetched copy, never twice" "$(cat "$d/spec.md")" "$sra_clean"
d="$(sra_dir)"
fake_issue_body 14 "$sra_body"$'\n## Ticket\n\nThe one ticket.\n'
sra "$d" recommended
assert_status "a collapsed breakdown pauses too" "$st" 3
assert_eq "printing collapsed" "$out" "collapsed"
d="$(sra_dir)"
fake_fail adapter_sub_issues
sra_refused "a ticket exists failure" "$d" "ticket exists #14 exited 2" recommended
fake_unfail
assert_eq "and leaves no changelog.md" "$(on_disk "$d/changelog.md")" absent

# Write order and failure.
d="$(sra_dir)"
mkdir "$d/changelog.md"
snap="$(fake_snapshot)"
sra "$d" recommended
assert_status "a failed changelog.md write stops apply" "$st" 1
assert_contains "naming it" "$out" "could not write $d/changelog.md"
assert_eq "before any GitHub write" "$(fake_snapshot)" "$snap"

for sra_mode in issue flow; do
  for sra_op in adapter_issue_body_edit adapter_issue_comment; do
    d="$(sra_dir)"
    rm -f "$top/.orchestrator/state.json"
    if [ "$sra_mode" = flow ]; then
      "$ORCH" init sra >/dev/null 2>&1; "$ORCH" state set issue 14 >/dev/null
    fi
    fake_fail "$sra_op"
    if [ "$sra_mode" = flow ]; then
      out="$("$ORCH" spec-review apply "$d" recommended --round 1/2 2>&1)"; st=$?
    else
      sra "$d" recommended
    fi
    fake_unfail
    assert_status "$sra_mode: a failed $sra_op stops apply" "$st" 1
    if [ "$sra_op" = adapter_issue_body_edit ]; then
      assert_contains "$sra_mode: naming the failed write" "$out" "could not write the body of issue #14"
      assert_contains "$sra_mode: and that nothing landed" "$out" "already landed: nothing"
    else
      assert_contains "$sra_mode: naming the failed write" "$out" "could not write the changelog comment on issue #14"
      assert_contains "$sra_mode: and the body as landed" "$out" "already landed: the body of issue #14"
    fi
    assert_eq "$sra_mode: changelog.md stays" "$(on_disk "$d/changelog.md")" present
  done
done
rm -rf "$top/.orchestrator"

d="$(sra_dir)"
fake_fail adapter_issue_comment
sra "$d" recommended --unattended
fake_unfail
assert_status "an unattended write failure stops apply too" "$st" 1
assert_contains "naming the landed body" "$out" "already landed: the body of issue #14"

# Flow mode: the issue from state, through the spec command's guards.
d="$(sra_dir)"
out="$("$ORCH" spec-review apply "$d" recommended --round 1/1 2>&1)"; st=$?
assert_status "flow mode with no flow is refused" "$st" 1
assert_contains "naming the missing flow" "$out" "no active flow"
"$ORCH" init srflow >/dev/null 2>&1
out="$("$ORCH" spec-review apply "$d" recommended --round 1/1 2>&1)"; st=$?
assert_status "flow mode with no recorded issue is refused" "$st" 1
assert_contains "naming the missing issue" "$out" "no issue recorded"
"$ORCH" state set issue 14 >/dev/null
out="$("$ORCH" spec-review apply "$d" recommended --round 1/1 2>&1)"; st=$?
assert_status "flow mode applies on state's issue" "$st" 0
assert_eq "publishing the body" "$(fake_body_of 14)" "$sra_clean"
assert_contains "and the comment" "$(fake_comments_of 14)" "Round 1 of 1"
d="$(sra_dir)"
state_fixture phase "done"
out="$("$ORCH" spec-review apply "$d" recommended --round 1/1 2>&1)"; st=$?
assert_status "flow mode in a done flow is refused" "$st" 1
assert_contains "naming the done flow" "$out" "is done"
sra "$d" recommended
assert_status "--issue on a done flow's own issue succeeds" "$st" 0
chmod 000 "$top/.orchestrator/state.json"
d="$(sra_dir)"
sra "$d" recommended
assert_status "--issue never reads state.json" "$st" 0
chmod 644 "$top/.orchestrator/state.json"

out="$("$ORCH" spec-review apply "$d" recommended --issue 14 2>&1)"; st=$?
assert_status "--round is required" "$st" 1
assert_contains "help documents spec-review apply" "$("$ORCH" help)" "spec-review apply <dir> <answer>"
restore_suite_env
