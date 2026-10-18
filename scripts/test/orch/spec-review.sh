# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# dir_snapshot <dir>: every file in <dir> with its checksum, for a
# byte-identical comparison.
dir_snapshot() { (cd "$1" && find . -type f | LC_ALL=C sort | xargs cksum); }
# check_refused <runner> <label> <dir> <stderr>: <runner> <dir> - a check
# run that sets out, err and st - exits 1 with exactly <stderr>, nothing on
# stdout, and <dir> unchanged.
check_refused() {
  local runner="$1" before
  shift
  before="$(dir_snapshot "$2")"
  "$runner" "$2"
  assert_status "$1: refused" "$st" 1
  assert_eq "$1: exactly these errors" "$err" "$3"
  assert_eq "$1: nothing on stdout" "$out" ""
  assert_eq "$1: the directory unchanged" "$(dir_snapshot "$2")" "$before"
}
# src <dir> [arg...]: check on <dir> with any further args, its stdout, stderr
# and status into out, err and st.
src() {
  local src_err
  src_err="$(mktemp)"
  out="$("$ORCH" spec-review check "$@" 2>"$src_err")"; st=$?
  err="$(cat "$src_err")"
  rm -f "$src_err"
}

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
assert_contains "a missing number gets the usage" "$out" "usage: orch.sh spec-review begin <n> [--carry]"
out="$("$ORCH" spec-review begin abc 2>&1)"
assert_contains "a non-numeric number is named" "$out" "plain issue number"
out="$("$ORCH" spec-review wipe 14 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the one it does" "$out" "want begin"
assert_contains "help documents spec-review begin" "$("$ORCH" help)" "spec-review begin <n> [--carry]"

# --- spec-review begin --carry (#1141, #1185) --------------------------------
# Rounds 2 and later of a standalone review keep the Implementability lens's
# code map and the settled file through the wipe; every other file still goes.
echo
echo "spec-review begin --carry (#1141, #1185)"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
sr_dir="$top/.orchestrator/spec-review/14"
sr_state="$top/.orchestrator/state.json"
# cm_seed: a round directory holding a map, a settled file and the round's
# other files.
cm_seed() {
  rm -rf "$sr_dir"
  mkdir -p "$sr_dir/sub"
  printf 'scripts/orch/x.sh:12-30 x_fn - the spec changes it\n' >"$sr_dir/map-implementability.md"
  printf '## Spec review\nRound 1 of 2\n' >"$sr_dir/settled.md"
  echo stale >"$sr_dir/spec.md"
  echo stale >"$sr_dir/lens-implementability.md"
  echo stale >"$sr_dir/sub/changelog.md"
}
cm_seed
out="$("$ORCH" spec-review begin 14 --carry 2>&1)"; st=$?
assert_status "--carry with a map and a settled file proceeds" "$st" 0
assert_eq "printing the working directory" "$out" "$sr_dir/"
assert_eq "keeping only the map and the settled file" "$(ls -A "$sr_dir" | LC_ALL=C sort 2>&1)" \
  "map-implementability.md
settled.md"
assert_eq "the map with its content" "$(cat "$sr_dir/map-implementability.md" 2>&1)" \
  "scripts/orch/x.sh:12-30 x_fn - the spec changes it"
assert_eq "the settled file with its content" "$(cat "$sr_dir/settled.md" 2>&1)" \
  "## Spec review
Round 1 of 2"

cm_seed
out="$("$ORCH" spec-review begin 14 2>&1)"; st=$?
assert_status "no flag proceeds" "$st" 0
assert_eq "and wipes everything, the map and the settled file included" "$(ls -A "$sr_dir" 2>&1)" ""

cm_seed
rm -f "$sr_dir/map-implementability.md"
out="$("$ORCH" spec-review begin 14 --carry 2>&1)"; st=$?
assert_status "--carry with no map exits 0" "$st" 0
assert_eq "keeping the settled file alone" "$(ls -A "$sr_dir" 2>&1)" "settled.md"

cm_seed
rm -f "$sr_dir/map-implementability.md" "$sr_dir/settled.md"
out="$("$ORCH" spec-review begin 14 --carry 2>&1)"; st=$?
assert_status "--carry with neither exits 0" "$st" 0
assert_eq "leaving an empty directory" "$(ls -A "$sr_dir" 2>&1)" ""

out="$("$ORCH" spec-review begin 16 --carry 2>&1)"; st=$?
assert_status "--carry on a directory never there exits 0" "$st" 0
assert_eq "creating it empty" "$(ls -A "$top/.orchestrator/spec-review/16" 2>&1)" ""

for args in "14 --carry-map" "--carry 14" "14 --carry --carry" "14 --carry 15"; do
  cm_seed
  before="$(dir_snapshot "$sr_dir")"
  # shellcheck disable=SC2086 # word splitting is the point: each word is an arg
  out="$("$ORCH" spec-review begin $args 2>&1)"; st=$?
  assert_status "refuses begin '$args'" "$st" 1
  assert_eq "with the usage for '$args'" "$out" "orch: usage: orch.sh spec-review begin <n> [--carry]"
  assert_eq "deleting nothing for '$args'" "$(dir_snapshot "$sr_dir")" "$before"
done

cm_seed
out="$("$ORCH" spec-review begin abc --carry 2>&1)"; st=$?
assert_status "a non-numeric issue with --carry is refused" "$st" 1
assert_contains "as without the flag" "$out" "plain issue number"
assert_eq "deleting nothing" "$(cat "$sr_dir/spec.md" 2>&1)" "stale"

for p in spec implement review; do
  printf '{"slug":"x","phase":"%s","issue":14,"branch":null}\n' "$p" >"$sr_state"
  cm_seed
  plain="$("$ORCH" spec-review begin 14 2>&1)"
  out="$("$ORCH" spec-review begin 14 --carry 2>&1)"; st=$?
  assert_status "an active flow on 14 at $p refuses --carry" "$st" 1
  assert_eq "exactly as without the flag at $p" "$out" "$plain"
  assert_eq "deleting nothing at $p" "$(cat "$sr_dir/spec.md" 2>&1)" "stale"
done
rm -f "$sr_state"

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

@@ item 1 consolidation apply material
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
@@ why The comment asks for alpha prime
@@ item 2 contradicts-the-plan decline material the plan chose this
@@ finding fidelity 1
@@ summary Reverse the plan on Beta
@@ anchor
Beta line.
@@ replace
Beta reversed.
@@ end
@@ why Beta follows the plan's reversal
@@ item 3 consistency decision A material
@@ finding consistency 1
@@ finding testability 1
@@ why Gamma must agree with the summary
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
@@ item 4 testability apply minor
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
# sra <dir> <answer> [flags...]: apply on issue #14, standalone, round
# $sra_rnd (1/2 when unset), its output and status into out and st.
sra() {
  local d="$1" a="$2"
  shift 2
  out="$("$ORCH" spec-review apply "$d" "$a" --round "${sra_rnd:-1/2}" --issue 14 "$@" 2>&1)"; st=$?
}
# sra_refused <label> <dir> <want-in-message> <answer> [flags...]: apply is
# refused, naming <want>, with nothing written: spec.md, changelog.md and
# settled.md as they were, and the store untouched.
sra_refused() {
  local label="$1" d="$2" want="$3" before snap
  shift 3
  before="$(cat "$d/spec.md"; echo; cat "$d/changelog.md" "$d/settled.md" 2>/dev/null)"
  snap="$(fake_snapshot)"
  sra "$d" "$@"
  assert_status "$label: refused" "$st" 1
  assert_contains "$label: naming it" "$out" "$want"
  assert_eq "$label: spec.md, changelog.md and settled.md unchanged" \
    "$(cat "$d/spec.md"; echo; cat "$d/changelog.md" "$d/settled.md" 2>/dev/null)" "$before"
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
- (4, minor) Insert a test note after Delta
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

# The settled file (#1185): each round's changelog appended, exactly as
# changelog.md holds it.
sra_cmp() { cmp -s "$1" "$2" && echo same || echo differs; }
d="$(sra_dir)"
sra "$d" recommended
assert_eq "a round with a declined, an applied and a decided item writes settled.md as changelog.md" \
  "$(sra_cmp "$d/settled.md" "$d/changelog.md")" same

# A second round, carried with begin --carry, appends after the first.
sr_dir="$top/.orchestrator/spec-review/14"
# sra_round <k/n>: copy a fresh fixture into the review's directory and apply
# it as recommended, as round <k/n>.
sra_round() {
  local src
  src="$(sra_dir)"
  cp "$src"/* "$sr_dir/"
  sra_rnd="$1" sra "$sr_dir" recommended
}
sra_tmp="$(mktemp -d)"
"$ORCH" spec-review begin 14 >/dev/null
sra_round 1/2
assert_status "round 1 in the review's directory applies" "$st" 0
cp "$sr_dir/changelog.md" "$sra_tmp/round1.md"
"$ORCH" spec-review begin 14 --carry >/dev/null
sra_round 2/2
assert_status "round 2 in the carried directory applies" "$st" 0
cat "$sra_tmp/round1.md" "$sr_dir/changelog.md" >"$sra_tmp/both.md"
assert_eq "settled.md holds round 1's changelog, then round 2's" \
  "$(sra_cmp "$sr_dir/settled.md" "$sra_tmp/both.md")" same
assert_contains "round 2's changelog is its own" "$(cat "$sr_dir/changelog.md")" "Round 2 of 2"
rm -rf "$top/.orchestrator" "$sra_tmp"

# A first GitHub write that fails leaves settled.md as it was; the rerun
# appends once.
d="$(sra_dir)"
printf 'earlier round\n' >"$d/settled.md"
fake_fail adapter_issue_body_edit
sra "$d" recommended
fake_unfail
assert_status "a failed first write stops apply" "$st" 1
assert_eq "leaving settled.md unchanged" "$(cat "$d/settled.md")" "earlier round"
sra "$d" recommended
assert_status "the rerun applies" "$st" 0
{ printf 'earlier round\n'; cat "$d/changelog.md"; } >"$d/want-settled"
assert_eq "appending the changelog once" "$(sra_cmp "$d/settled.md" "$d/want-settled")" same

# A settled.md that cannot be appended to dies once every write has landed.
d="$(sra_dir)"
mkdir "$d/settled.md"
sra "$d" recommended
assert_status "a failed append stops apply" "$st" 1
assert_contains "naming settled.md" "$out" "$d/settled.md"
assert_contains "and that every GitHub write landed" "$out" "every GitHub write landed"
assert_contains "the comment among them" "$(fake_comments_of 14)" "Round 1 of 2"

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

# An Other override answer names only its departures (#1239): a decision's
# letter and a `-<n>` decline, every item it does not name as recommended.
d="$(sra_dir)"
printf '\n1: the comment is stale\n' >"$d/reasons"
sra "$d" "3B, -1" --reasons "$d/reasons"
assert_status "an override answer applies" "$st" 0
assert_eq "the departures taken, every unnamed item as recommended" "$(cat "$d/spec.md")" '# Spec

Alpha line.
Beta line.
Gamma dropped.
Delta line.
Test note.
Twice.
Twice.'
sra_cl="$(cat "$d/changelog.md")"
assert_eq "<n><letter>: the decision takes that option" \
  "$(has_line "$sra_cl" "- (3) decision: took B - Drop gamma")" yes
assert_eq "-<n>: the item declined, with its --reasons line" \
  "$(has_line "$sra_cl" '- (1) "Alpha should say alpha prime." - the comment is stale')" yes
assert_eq "an unnamed recommend-decline item, declined as recommended" \
  "$(has_line "$sra_cl" '- (2) "The spec reverses the plan'"'"'s choice of beta." - spec departs from the plan: declined as recommended: the plan chose this')" yes
assert_eq "an unnamed minor apply item, applied and tagged minor" \
  "$(has_line "$sra_cl" "- (4, minor) Insert a test note after Delta")" yes
assert_eq "posted as the round's comment" "$(fake_comments_of 14)" "$sra_cl"

# `+<n>` applies a recommend-decline item; `-<n>` leaves a decision undecided
# and declines an apply item.
d="$(sra_dir)"
sra "$d" "-3, +2, -4"
assert_status "an override answer with + and - applies" "$st" 0
assert_eq "the recommend-decline edit applied, the decision and item 4 not" "$(cat "$d/spec.md")" '# Spec

Alpha prime line.
Beta reversed.
Gamma line.
Delta line.
Twice.
Twice.'
sra_cl="$(cat "$d/changelog.md")"
assert_eq "+<n>: recorded applied, by its summary" \
  "$(has_line "$sra_cl" "- (2) Reverse the plan on Beta")" yes
assert_eq "-<n> on a decision: left undecided under Consistency and Testability alike" \
  "$(grep -c '^- (3) .* - left undecided$' "$d/changelog.md")" 2
assert_eq "-<n> on an apply item: declined" \
  "$(has_line "$sra_cl" '- (4) "Delta has no test." - declined')" yes
assert_eq "the resolved item still resolved" "$(has_line "$sra_cl" "- (5) resolved by (4)")" yes

# A departure that matches the recommendation is recorded as recommended.
d="$(sra_dir)"
sra "$d" "3A, -2"
assert_status "an override answer naming only the recommendation applies" "$st" 0
assert_eq "its changelog is the recommended answer's" "$(cat "$d/changelog.md")" "$sra_log"
assert_eq "its spec.md is the recommended answer's" "$(cat "$d/spec.md")" "$sra_clean"

# The minor tag (#1240): a minor item applied by the human's answer reads
# `(<n>, minor)` in the changelog and settled.md; nothing else is tagged.
# sra_minor_dir: sra_dir, with item 2 a minor recommend-decline item.
sra_minor_dir() {
  local d
  d="$(sra_dir)"
  sed -i '18s/contradicts-the-plan decline material/fidelity decline minor/; 26s/.*//' "$d/batch.md"
  printf '%s\n' "$d"
}
for sra_case in "all|by all" "+2|by +<n>"; do
  d="$(sra_minor_dir)"
  sra "$d" "${sra_case%%|*}"
  assert_status "a minor recommend-decline item applied ${sra_case#*|}: applies" "$st" 0
  assert_eq "a minor recommend-decline item applied ${sra_case#*|}: tagged minor" \
    "$(has_line "$(cat "$d/changelog.md")" "- (2, minor) Reverse the plan on Beta")" yes
  assert_eq "a minor recommend-decline item applied ${sra_case#*|}: tagged minor in settled.md" \
    "$(has_line "$(cat "$d/settled.md")" "- (2, minor) Reverse the plan on Beta")" yes
done
d="$(sra_dir)"
sra "$d" recommended
assert_eq "a minor item applied by recommended: tagged minor in settled.md" \
  "$(has_line "$(cat "$d/settled.md")" "- (4, minor) Insert a test note after Delta")" yes
d="$(sra_minor_dir)"
sra "$d" "3B"
assert_status "an override answer leaving minor items unnamed applies" "$st" 0
sra_cl="$(cat "$d/changelog.md")"
assert_eq "a minor item left unnamed in an override answer: tagged minor" \
  "$(has_line "$sra_cl" "- (4, minor) Insert a test note after Delta")" yes
assert_eq "a minor item left unnamed in an override answer: tagged minor in settled.md" \
  "$(has_line "$(cat "$d/settled.md")" "- (4, minor) Insert a test note after Delta")" yes
assert_eq "a minor item declined as recommended: untagged" \
  "$(has_line "$sra_cl" '- (2) "The spec reverses the plan'"'"'s choice of beta." - declined as recommended: the plan chose this')" yes
assert_eq "a material item applied: untagged" \
  "$(has_line "$sra_cl" "- (1) Folded in @alice's comment on Alpha")" yes
assert_eq "a decision line: untagged" "$(has_line "$sra_cl" "- (3) decision: took B - Drop gamma")" yes
assert_eq "a resolved line: untagged" "$(has_line "$sra_cl" "- (5) resolved by (4)")" yes
for sra_case in "-4|by -<n>" "none|by none"; do
  d="$(sra_dir)"
  sra "$d" "${sra_case%%|*}"
  assert_eq "a minor item declined ${sra_case#*|}: untagged" \
    "$(has_line "$(cat "$d/settled.md")" '- (4) "Delta has no test." - declined')" yes
done
d="$(sra_minor_dir)"
sra "$d" recommended --unattended
assert_status "an unattended run with minor items applies" "$st" 0
assert_eq "an unattended run's changelog: no line tagged minor" \
  "$(grep -c 'minor)' "$d/changelog.md")" 0
assert_eq "an unattended run's minor applied item: untagged" \
  "$(has_line "$(cat "$d/changelog.md")" "- (4) Insert a test note after Delta")" yes

# A --reasons line naming an item the override answer does not decline.
d="$(sra_dir)"
printf '4: why\n' >"$d/reasons"
sra_refused "a reason for an item the override answer applies" "$d" "item 4, which the answer does not decline" \
  "-1" --reasons "$d/reasons"
printf '2: why\n' >"$d/reasons"
sra_refused "a reason for an item applied by +<n>" "$d" "item 2, which the answer does not decline" \
  "+2" --reasons "$d/reasons"

# Answers refused before any write.
d="$(sra_dir)"
echo "old log" >"$d/changelog.md"
sra_form="is not <n><letter>, -<n> or +<n>"
sra_refused "the old list form" "$d" "'2' $sra_form" "2, 3"
sra_refused "a bare number on a decision" "$d" "'3' $sra_form" "3"
sra_refused "a malformed answer" "$d" "'1;2' $sra_form" "1;2"
sra_refused "a sign with no number" "$d" "'-' $sra_form" "-"
sra_refused "a sign and a letter" "$d" "'+3B' $sra_form" "+3B"
sra_refused "two letters" "$d" "'3AB' $sra_form" "3AB"
sra_refused "an empty token" "$d" "'' $sra_form" "-4,"
sra_refused "an unknown item" "$d" "item 9, which batch.md does not have" "-1, -9"
sra_refused "an unknown item with a letter" "$d" "item 9, which batch.md does not have" "9A"
sra_refused "an unknown option" "$d" "option C" "3C"
sra_refused "a letter on no decision" "$d" "no decision item" "4B"
sra_refused "+ on a decision" "$d" "item 3 is a decision item" "+3"
sra_refused "+ on an item not recommended for decline" "$d" "item 4 is not recommended for decline" "+4"
sra_refused "- on a resolved item" "$d" "resolved by item 4" "-5"
sra_refused "+ on a resolved item" "$d" "resolved by item 4" "+5"
sra_refused "a letter on a resolved item" "$d" "resolved by item 4" "5A"
sra_refused "an item named twice" "$d" "item 4 twice" "-4, -4"
sra_refused "a decision named twice" "$d" "item 3 twice" "3B, -3"
sra_refused "an unknown long option, though the answer may begin with -" "$d" \
  "unknown option: --bogus" "-4" --bogus

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

# The parser's refusals say why the line is wrong (#1149).
sra_resolved_takes='a resolved item takes no @@ anchor, @@ replace or @@ end'
d="$(sra_dir)"
printf '@@ end\n' >>"$d/batch.md"
sra_refused "a resolved item carrying @@ end" "$d" "batch.md line 58: $sra_resolved_takes" recommended
d="$(sra_dir)"
printf '@@ replace\nx\n@@ end\n' >>"$d/batch.md"
sra_refused "a resolved item carrying @@ replace" "$d" "batch.md line 58: $sra_resolved_takes" recommended
d="$(sra_dir)"
sed -i '21,25d' "$d/batch.md"
sra_refused "a decline item with no block" "$d" \
  "batch.md line 18: item 2 has no @@ anchor/@@ replace/@@ end block - a decline item still carries the edit it declines" recommended
d="$(sra_dir)"
sed -i '48,53d' "$d/batch.md"
sra "$d" recommended
assert_status "an apply item with no block: refused" "$st" 1
assert_eq "an apply item with no block keeps its message" "$out" \
  "orch: batch.md line 45: item 4 has no @@ anchor/@@ replace/@@ end block"
d="$(sra_dir)"
sed -i '16,17d' "$d/batch.md"
sra_refused "a replacement left open at the next @@ item" "$d" \
  "batch.md line 16: expected @@ end to end the replacement begun on line 14, got '@@ item 2 contradicts-the-plan decline material the plan chose this'" recommended
d="$(sra_dir)"
sed -i '14d' "$d/batch.md"
sra "$d" recommended
assert_status "an anchor left open: refused" "$st" 1
assert_eq "an anchor left open keeps its message" "$out" \
  "orch: batch.md line 15: expected @@ replace to end the anchor begun on line 12"

# Malformed marks (#1237): refused attended and unattended, before any write.
for sra_flag in "" --unattended; do
  for sra_case in \
    "45s/ minor$//|no mark|batch.md line 45: @@ item 4 ... apply needs its mark, material or minor" \
    "45s/ minor$/ major/|an unknown mark|batch.md line 45: item 4's mark must be material or minor, got 'major'" \
    "55s/$/ minor/|a mark on a resolved item|batch.md line 55: @@ item 5 ... a resolved item carries no mark" \
    "27s/ material$/ minor/|a decision marked minor|batch.md line 27: decision item 3 is always material, never minor" \
    "18s/decline material/decline minor/|a contradicts-the-plan item marked minor|batch.md line 18: contradicts-the-plan item 2 is always material, never minor"; do
    d="$(sra_dir)"
    printf 'earlier round\n' >"$d/settled.md"
    sed -i "${sra_case%%|*}" "$d/batch.md"
    sra_label="${sra_case#*|}"
    sra_refused "${sra_flag:-attended}: ${sra_label%%|*}" "$d" "${sra_label#*|}" recommended ${sra_flag:+"$sra_flag"}
  done
done

# @@ why (#1248): a material item missing it refused attended and unattended,
# before any write.
for sra_flag in "" --unattended; do
  d="$(sra_dir)"
  printf 'earlier round\n' >"$d/settled.md"
  sed -i '17s/.*//' "$d/batch.md"
  sra_refused "${sra_flag:-attended}: a material item with no @@ why" "$d" \
    "batch.md line 6: item 1 has no @@ why" recommended ${sra_flag:+"$sra_flag"}
done
d="$(sra_dir)"
sra "$d" recommended
assert_status "a valid batch with @@ why lines applies" "$st" 0
assert_eq "its changelog is unchanged" "$(cat "$d/changelog.md")" "$sra_log"
assert_eq "a declined finding still quoted word for word" \
  "$(has_line "$(cat "$d/changelog.md")" '- (2) "The spec reverses the plan'"'"'s choice of beta." - spec departs from the plan: declined as recommended: the plan chose this')" yes
for sra_why in "The comment asks for alpha prime" "Beta follows the plan's reversal" "Gamma must agree with the summary"; do
  assert_not_contains "no @@ why text in the changelog: $sra_why" "$(cat "$d/changelog.md")" "$sra_why"
done

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
sed -i 's/^@@ lens fidelity ran$/@@ lens fidelity standalone/; /^@@ item 2 /,/^@@ why /d' "$d/batch.md"
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
assert_eq "--unattended writes settled.md too" "$(sra_cmp "$d/settled.md" "$d/changelog.md")" same

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
assert_eq "and no settled.md" "$(on_disk "$d/settled.md")" absent
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
rm -rf "$top/.orchestrator"

# The ticket step (#1118): after the pause, the session fetches the tickets
# and writes tickets.md, and apply --tickets follows them in the same call
# that publishes the body - ticket text edits, then edges, then the body, then
# any retire, then the comment.
srt_t20='## What to build

Build alpha.

## Blocked by

None (can start immediately)
'
srt_t21='## What to build

Build gamma.

## Blocked by

- #20
'
# srt_dir: sra_dir's round directory, with #14 broken down into open tickets
# #20 and #21 (#21 blocked by #20) and closed #22, and tickets.md drafted;
# prints its path. The ticket files are srt_fetch's, as the session fetches
# them after the pause.
srt_dir() {
  local d
  d="$(sra_dir)"
  fake_issue 20 open; fake_issue_body 20 "$srt_t20"
  fake_issue 21 open; fake_issue_body 21 "$srt_t21"
  fake_issue 22 closed
  rm -rf "$ORCH_GH_FAKE_STORE/subs" "$ORCH_GH_FAKE_STORE/blocked_by"
  mkdir -p "$ORCH_GH_FAKE_STORE/subs" "$ORCH_GH_FAKE_STORE/blocked_by"
  printf '20\n21\n22\n' >"$ORCH_GH_FAKE_STORE/subs/14"
  printf '20\n' >"$ORCH_GH_FAKE_STORE/blocked_by/21"
  cat >"$d/tickets.md" <<'TICKETS'
@@ recommend apply
@@ item 1 ticket 20 apply
@@ summary #20 builds alpha prime
@@ anchor
Build alpha.
@@ replace
Build alpha prime.
@@ end

@@ item 2 unblock 21 by 20 apply
@@ item 3 block 20 by 21 apply
@@ item 4 ticket 21 decline gamma is unchanged
@@ summary #21 builds gamma twice
@@ anchor
Build gamma.
@@ replace
Build gamma twice.
@@ end
@@ item 5 block 21 by 20 decline already there
@@ closed 22 the gamma API
TICKETS
  printf '%s\n' "$d"
}
# srt_fetch <dir>: the tickets' bodies fetched into ticket-<n>.md.
srt_fetch() { printf '%s' "$srt_t20" >"$1/ticket-20.md"; printf '%s' "$srt_t21" >"$1/ticket-21.md"; }
# srt_files <dir>: spec.md, the ticket files and changelog.md, for a refusal
# to leave as they were.
srt_files() { cat "$1/spec.md" "$1/ticket-20.md" "$1/ticket-21.md" "$1/changelog.md" 2>/dev/null; }
# srt_refused <label> <dir> <want> <answer> [flags...]: sra_refused, the
# ticket files unchanged too.
srt_refused() {
  local before
  before="$(srt_files "$2")"
  sra_refused "$@"
  assert_eq "$1: the ticket files unchanged" "$(srt_files "$2")" "$before"
}

# The pause, then the --tickets rerun.
d="$(srt_dir)"
sra "$d" recommended
assert_status "the first run pauses for the ticket question" "$st" 3
srt_fetch "$d"
sra "$d" recommended --tickets recommended
assert_status "the --tickets rerun applies" "$st" 0
assert_eq "ticket-20.fetched.md is taken on the rerun" "$(cat "$d/ticket-20.fetched.md")" "$(printf '%s' "$srt_t20")"
assert_eq "ticket-20.md carries its text edit" "$(cat "$d/ticket-20.md")" '## What to build

Build alpha prime.

## Blocked by

None (can start immediately)'
assert_eq "a text edit then an edge on #20: both land, in that order" "$(fake_body_of 20)" '## What to build

Build alpha prime.

## Blocked by

- #21'
assert_eq "#21 unblocked, its declined text edit not made" "$(fake_body_of 21)" '## What to build

Build gamma.

## Blocked by

None (can start immediately)'
assert_eq "the edges as recommended: #20 blocked by #21" "$(cat "$ORCH_GH_FAKE_STORE/blocked_by/20")" 21
assert_eq "and #21 by nothing" "$(cat "$ORCH_GH_FAKE_STORE/blocked_by/21")" ""
assert_eq "the body published is spec.md" "$(fake_body_of 14)" "$sra_clean"
srt_tickets='### Tickets
- (1) #20 builds alpha prime
- (2) #21 no longer blocked by #20
- (3) #20 now blocked by #21
- (4) "Build gamma twice." - declined as recommended: gamma is unchanged
- (5) "block #21 by #20" - declined as recommended: already there
- #22 closed, built against the earlier spec: the gamma API'
assert_contains "the Tickets section, line for line" "$(cat "$d/changelog.md")" $'\n\n'"$srt_tickets"
assert_eq "it ends the changelog" "$(tail -n 7 "$d/changelog.md")" "$srt_tickets"
assert_eq "posted" "$(fake_comments_of 14)" "$(cat "$d/changelog.md")"
assert_eq "the writes in order: ticket text, edges, body, comment" "$(cat "$d/applied.log")" "ticket #20's body
unblock #21 by #20
block #20 by #21
the body of issue #14
the changelog comment on issue #14"
srt_after="$(cat "$d/spec.md" "$d/ticket-20.md" "$d/ticket-21.md" "$d/changelog.md"; fake_body_of 14; fake_body_of 20; fake_body_of 21)"

# A clean run, --tickets given from the start, gives the same result.
d="$(srt_dir)"
srt_fetch "$d"
sra "$d" recommended --tickets recommended
assert_status "a clean --tickets run applies" "$st" 0
assert_eq "the --tickets rerun after a pause gives the same result as a clean run" \
  "$(cat "$d/spec.md" "$d/ticket-20.md" "$d/ticket-21.md" "$d/changelog.md"; fake_body_of 14; fake_body_of 20; fake_body_of 21)" "$srt_after"

# An Other list: a text edit on #21 before its unblock; a declined edge's
# reason from --ticket-reasons.
d="$(srt_dir)"
srt_fetch "$d"
printf '5: the edge stays\n' >"$d/treasons"
sra "$d" recommended --tickets "1, 2, 4" --ticket-reasons "$d/treasons"
assert_status "an Other ticket list applies" "$st" 0
assert_eq "#21's text edit, then its unblock" "$(fake_body_of 21)" '## What to build

Build gamma twice.

## Blocked by

None (can start immediately)'
assert_eq "#20 not blocked: item 3 left out" "$(cat "$ORCH_GH_FAKE_STORE/blocked_by/20" 2>/dev/null)" ""
sra_cl="$(cat "$d/changelog.md")"
assert_eq "an applied ticket text edit by its summary" "$(has_line "$sra_cl" "- (4) #21 builds gamma twice")" yes
assert_eq "an edge left out, declined" "$(has_line "$sra_cl" '- (3) "block #20 by #21" - declined')" yes
assert_eq "a declined edge with the human's reason" "$(has_line "$sra_cl" '- (5) "block #21 by #20" - the edge stays')" yes
assert_eq "ticket writes in item order, text before edge" "$(head -n 3 "$d/applied.log")" "ticket #20's body
ticket #21's body
unblock #21 by #20"

# --tickets none: no ticket write, the body still published.
d="$(srt_dir)"
srt_fetch "$d"
printf '1: alpha is fine\n' >"$d/treasons"
sra "$d" recommended --tickets none --ticket-reasons "$d/treasons"
assert_status "--tickets none applies" "$st" 0
assert_eq "no ticket written" "$(fake_body_of 20)" "$(printf '%s' "$srt_t20")"
assert_eq "a declined text edit quotes its replacement, then the reason" \
  "$(has_line "$(cat "$d/changelog.md")" '- (1) "Build alpha prime." - alpha is fine')" yes
assert_eq "only the body and the comment written" "$(cat "$d/applied.log")" "the body of issue #14
the changelog comment on issue #14"

# --tickets retire, and recommended with @@ recommend retire: the retire runs
# after the publish, and no ticket is edited.
for srt_how in retire recommended; do
  d="$(srt_dir)"
  srt_fetch "$d"
  [ "$srt_how" = retire ] || sed -i 's/^@@ recommend apply$/@@ recommend retire/' "$d/tickets.md"
  sra "$d" recommended --tickets "$srt_how"
  assert_status "$srt_how: retires" "$st" 0
  assert_eq "$srt_how: the breakdown unlinked" "$(fake_sub_issues_of 14)" ""
  assert_eq "$srt_how: #20 closed as not planned" "$(fake_state_of 20) $(fake_reason_of 20)" "CLOSED not planned"
  assert_contains "$srt_how: its text not edited" "$(fake_body_of 20)" "Build alpha."
  assert_eq "$srt_how: the retire after the publish" "$(cat "$d/applied.log")" "the body of issue #14
the retire of #14's ticket breakdown
the changelog comment on issue #14"
  assert_eq "$srt_how: the Tickets section" "$(tail -n 3 "$d/changelog.md")" '### Tickets
- retired, to be broken down again
- #22 closed, built against the earlier spec: the gamma API'
done

# @@ none-affected.
d="$(srt_dir)"
printf '@@ none-affected\n' >"$d/tickets.md"
sra "$d" recommended --tickets recommended
assert_status "@@ none-affected applies" "$st" 0
assert_eq "recorded so" "$(tail -n 2 "$d/changelog.md")" '### Tickets
None - no ticket affected'
assert_eq "no ticket written" "$(fake_body_of 20)" "$(printf '%s' "$srt_t20")"

# --unattended pauses like any run and takes only --tickets recommended.
d="$(srt_dir)"
sra "$d" recommended --unattended
assert_status "--unattended pauses too" "$st" 3
srt_fetch "$d"
srt_refused "--unattended with --tickets all" "$d" "--unattended takes only --tickets recommended" recommended --unattended --tickets all
sra "$d" recommended --unattended --tickets recommended
assert_status "--unattended with --tickets recommended applies" "$st" 0
assert_eq "following the tickets" "$(cat "$ORCH_GH_FAKE_STORE/blocked_by/20")" 21

# Refusals before any write.
d="$(srt_dir)"
sra "$d" recommended
mv "$d/tickets.md" "$d/tickets.keep"
srt_refused "no tickets.md" "$d" "tickets.md not found" recommended --tickets recommended
cp "$d/tickets.keep" "$d/tickets.md"
srt_refused "a ticket item with no ticket file" "$d" "ticket item 1: ticket-20.md not found" recommended --tickets recommended
srt_fetch "$d"
assert_eq "ticket-20.fetched.md not yet taken by a run that found no file" "$(on_disk "$d/ticket-20.fetched.md")" absent
sed -i 's/^Build alpha\.$/Nowhere./' "$d/tickets.md"
srt_refused "a ticket anchor matching nothing" "$d" "ticket item 1 (#20): its anchor matches no text" recommended --tickets recommended
assert_eq "the refused run took ticket-20.fetched.md" "$(cat "$d/ticket-20.fetched.md")" "$(printf '%s' "$srt_t20")"
sed -i 's/^Nowhere\.$/##/' "$d/tickets.md"
srt_refused "a ticket anchor matching twice" "$d" "ticket item 1 (#20): its anchor matches more than one place" recommended --tickets recommended
cp "$d/tickets.keep" "$d/tickets.md"
printf '@@ bogus\n' >>"$d/tickets.md"
srt_refused "a malformed tickets.md" "$d" "tickets.md line 21: unknown line '@@ bogus'" recommended --tickets recommended
printf '@@ item 1 ticket 20 apply\n' >"$d/tickets.md"
srt_refused "tickets.md with no @@ recommend" "$d" "tickets.md line 1: @@ recommend comes first" recommended --tickets recommended
printf '@@ recommend apply\n@@ item 1 ticket 20 apply\n@@ anchor\nx\n@@ replace\ny\n@@ end\n' >"$d/tickets.md"
srt_refused "a ticket text item with no summary" "$d" "tickets.md line 2: item 1 has no @@ summary" recommended --tickets recommended
printf '@@ recommend apply\n@@ item 1 block 20 21 apply\n' >"$d/tickets.md"
srt_refused "a malformed edge item" "$d" "tickets.md line 2" recommended --tickets recommended
printf '@@ none-affected\n@@ closed 22 x\n' >"$d/tickets.md"
srt_refused "@@ none-affected with company" "$d" "tickets.md line 2" recommended --tickets recommended
cp "$d/tickets.keep" "$d/tickets.md"
srt_refused "an Other ticket list naming an unknown item" "$d" "ticket item 9" recommended --tickets "1, 9"
srt_refused "a malformed --tickets answer" "$d" "--tickets" recommended --tickets "1B"
printf 'one: why\n' >"$d/treasons"
srt_refused "a malformed --ticket-reasons line" "$d" "--ticket-reasons line 1" recommended --tickets none --ticket-reasons "$d/treasons"
printf '1: why\n' >"$d/treasons"
srt_refused "a ticket reason for an accepted item" "$d" "does not decline" recommended --tickets recommended --ticket-reasons "$d/treasons"
printf '9: why\n' >"$d/treasons"
srt_refused "a ticket reason for an unknown item" "$d" "item 9" recommended --tickets none --ticket-reasons "$d/treasons"
srt_refused "a block for an edge already present" "$d" "ticket item 5: #21 is already blocked by #20" recommended --tickets all
sed -i 's/^@@ item 2 unblock 21 by 20 apply$/@@ item 2 unblock 20 by 21 apply/' "$d/tickets.md"
srt_refused "an unblock for an edge not present" "$d" "ticket item 2: #20 is not blocked by #21" recommended --tickets recommended
cp "$d/tickets.keep" "$d/tickets.md"
sed -i 's/^@@ item 5 block 21 by 20 /@@ item 5 block 99 by 20 /' "$d/tickets.md"
srt_refused "an edge item whose ticket is not in the breakdown" "$d" "ticket item 5: #99 is not a ticket of #14's breakdown" recommended --tickets recommended
cp "$d/tickets.keep" "$d/tickets.md"
sra "$d" recommended --tickets recommended
assert_status "the corrected rerun applies" "$st" 0
assert_eq "giving the same result as a clean run" \
  "$(cat "$d/spec.md" "$d/ticket-20.md" "$d/ticket-21.md" "$d/changelog.md"; fake_body_of 14; fake_body_of 20; fake_body_of 21)" "$srt_after"

# A collapsed breakdown: its ## Ticket edit anchored on the body the batch
# items left, and published with the body.
srt_collapsed() {
  local d
  d="$(sra_dir)"
  rm -rf "$ORCH_GH_FAKE_STORE/subs"
  printf '%s\n## Ticket\n\nBuild the spec.\n' "$sra_body" >"$d/spec.md"
  fake_issue_body 14 "$(cat "$d/spec.md")"$'\n'
  printf '@@ recommend apply\n@@ item 1 section apply\n@@ summary The ticket builds alpha prime first\n@@ anchor\nBuild the spec.\n@@ replace\nBuild the spec, alpha prime first.\n@@ end\n' >"$d/tickets.md"
  printf '%s\n' "$d"
}
d="$(srt_collapsed)"
sra "$d" recommended --tickets recommended
assert_status "a collapsed ## Ticket edit applies" "$st" 0
assert_eq "published with the body" "$(fake_body_of 14)" "$sra_clean"'

## Ticket

Build the spec, alpha prime first.'
assert_eq "one body write" "$(cat "$d/applied.log")" "the body of issue #14
the changelog comment on issue #14"
assert_eq "recorded" "$(tail -n 1 "$d/changelog.md")" "- (1) The ticket builds alpha prime first"
d="$(srt_collapsed)"
sed -i 's/^Build the spec\.$/Alpha line./' "$d/tickets.md"
srt_refused "a ## Ticket anchor on text the batch items replaced" "$d" "ticket item 1 (## Ticket): its anchor matches no text" recommended --tickets recommended
d="$(srt_dir)"
srt_fetch "$d"
printf '@@ recommend apply\n@@ item 1 section apply\n@@ summary s\n@@ anchor\nAlpha line.\n@@ replace\nx\n@@ end\n' >"$d/tickets.md"
srt_refused "a ## Ticket item on a sub-issue breakdown" "$d" "ticket item 1: a ## Ticket item, but #14's breakdown is sub-issues" recommended --tickets recommended

# A failed ticket write stops apply, naming the writes already landed, in
# both modes.
srt_fail() {
  local mode="$1" how="$2" op="$3" n="$4"
  d="$(srt_dir)"
  srt_fetch "$d"
  rm -f "$top/.orchestrator/state.json"
  if [ "$mode" = flow ]; then
    "$ORCH" init srt >/dev/null 2>&1; "$ORCH" state set issue 14 >/dev/null
  fi
  if [ "$n" = 0 ]; then fake_fail "$op"; else fake_fail_after "$op" "$n"; fi
  if [ "$mode" = flow ]; then
    out="$("$ORCH" spec-review apply "$d" recommended --round 1/2 --tickets "$how" 2>&1)"; st=$?
  else
    sra "$d" recommended --tickets "$how"
  fi
  fake_unfail
  assert_status "$mode: a failed $op stops apply" "$st" 1
  assert_eq "$mode: changelog.md stays after a failed $op" "$(on_disk "$d/changelog.md")" present
}
for sra_mode in issue flow; do
  srt_fail "$sra_mode" recommended adapter_issue_body_edit 0
  assert_contains "$sra_mode: a ticket update failure named" "$out" "could not write ticket #20's body"
  assert_contains "$sra_mode: nothing landed" "$out" "already landed: nothing"
  srt_fail "$sra_mode" recommended adapter_blocker_remove 0
  assert_contains "$sra_mode: an unblock failure named" "$out" "could not write unblock #21 by #20"
  assert_contains "$sra_mode: the text edit landed" "$out" "already landed: ticket #20's body;"
  srt_fail "$sra_mode" recommended adapter_blocker_add 0
  assert_contains "$sra_mode: a block failure named" "$out" "could not write block #20 by #21"
  assert_contains "$sra_mode: the text edit and the unblock landed" "$out" "already landed: ticket #20's body; unblock #21 by #20;"
  # The ticket update, then the two edges' ## Blocked by rewrites, then the body.
  srt_fail "$sra_mode" recommended adapter_issue_body_edit 3
  assert_contains "$sra_mode: a body failure named" "$out" "could not write the body of issue #14"
  assert_contains "$sra_mode: the ticket writes landed" "$out" "already landed: ticket #20's body; unblock #21 by #20; block #20 by #21;"
  srt_fail "$sra_mode" retire adapter_issue_close 0
  assert_contains "$sra_mode: a retire failure named" "$out" "could not write the retire of #14's ticket breakdown"
  assert_contains "$sra_mode: the body landed before it" "$out" "already landed: the body of issue #14;"
  srt_fail "$sra_mode" recommended adapter_issue_comment 0
  assert_contains "$sra_mode: a comment failure named" "$out" "could not write the changelog comment on issue #14"
  assert_contains "$sra_mode: every other write landed" "$out" "already landed: ticket #20's body; unblock #21 by #20; block #20 by #21; the body of issue #14;"
done
rm -rf "$top/.orchestrator"
d="$(srt_dir)"
srt_fetch "$d"
fake_fail adapter_blocker_add
sra "$d" recommended --unattended --tickets recommended
fake_unfail
assert_status "an unattended ticket write failure stops apply" "$st" 1
assert_contains "naming the landed writes" "$out" "already landed: ticket #20's body; unblock #21 by #20;"
restore_suite_env

# --- spec-review check (#1137) -------------------------------------------------
# A round's batch validated before the batch question: everything apply checks
# that does not depend on the answer - grammar, lens files, citations, every
# anchor on its own and in the all answer's dry run - with nothing written.
echo
echo "spec-review check (#1137)"
new_repo >/dev/null
fake_github
top="$(git rev-parse --show-toplevel)"
src_body='# Spec

Alpha line.
Beta line.
Gamma line.
Delta line.
Twice.
Twice.
'
# src_dir: a fresh round directory holding the fixture spec, batch and lens
# files, with issue #14 reset to the fixture body; prints its path. The batch's
# @@ anchor lines: item 1 on 9, item 2 on 18, item 3's options A and B on 29
# and 36. Each material item's @@ why sits where it costs no line: an apply or
# decline item's after its @@ end, a decision item's before its options.
src_dir() {
  local d
  d="$(mktemp -d)"
  printf '%s' "$src_body" >"$d/spec.md"
  cat >"$d/batch.md" <<'BATCH'
@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability not-run timed out

@@ item 1 fidelity apply minor
@@ finding fidelity 1
@@ summary Alpha primed
@@ anchor
Alpha line.
@@ replace
Alpha prime line.
@@ end

@@ item 2 consistency decline material the plan chose this
@@ finding consistency 1
@@ summary Beta reversed
@@ anchor
Beta line.
@@ replace
Beta reversed.
@@ end
@@ why Beta contradicts the plan
@@ item 3 testability decision A material
@@ finding testability 1
@@ why Gamma must be testable
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
@@ item 4 testability resolved
@@ finding testability 2
@@ resolved-by 3
BATCH
  printf '@@ finding 1\nAlpha is stale.\n' >"$d/lens-fidelity.md"
  printf '@@ finding 1\nBeta contradicts the plan.\n' >"$d/lens-consistency.md"
  printf '@@ finding 1\nGamma is untestable.\n@@ finding 2\nGamma again.\n' >"$d/lens-testability.md"
  fake_issue 14 open
  fake_issue_body 14 "$src_body"
  printf '%s\n' "$d"
}

# A clean batch: exit 0, the view on stdout, the one-line summary on stderr,
# nothing written.
d="$(src_dir)"
before="$(dir_snapshot "$d")"
src "$d"
assert_status "a clean batch passes" "$st" 0
assert_eq "with a one-line summary on stderr" "$err" \
  "batch.md passes: 4 items, 4 anchors, each matching once in spec.md, and the all answer applies cleanly"
assert_not_contains "and not on stdout" "$out" "batch.md passes"
assert_eq "the directory byte-identical" "$(dir_snapshot "$d")" "$before"
assert_eq "no spec.fetched.md created" "$(on_disk "$d/spec.fetched.md")" absent

# The Implementability lens's code map sits outside the lens-<name>.md
# namespace, so check never parses it (#1141).
d="$(src_dir)"
printf '@@ item 9 bogus\n@@ finding nowhere 7\n@@ lens implementability ran\n' >"$d/map-implementability.md"
before="$(dir_snapshot "$d")"
src "$d"
assert_status "a map full of @@ lines passes" "$st" 0
assert_eq "with the same summary on stderr" "$err" \
  "batch.md passes: 4 items, 4 anchors, each matching once in spec.md, and the all answer applies cleanly"
assert_eq "the directory, map included, byte-identical" "$(dir_snapshot "$d")" "$before"

# The compact view (#1250): the lens lines first, then the material items as
# one numbered list, numbered as in batch.md, each a header line and its
# sub-bullets - why, the findings it cites, its change - with no ### Item
# heading; the minor list unchanged after it.
d="$(src_dir)"
src "$d"
assert_eq "the compact view, its layout pinned" "$out" '## The batch

### Lenses

- Fidelity: ran
- Consistency: ran
- Testability: ran
- Implementability: not run - timed out

2. **Consistency** - Beta reversed (recommend decline: the plan chose this)
   - why: Beta contradicts the plan
   - findings: Consistency 1
   - Beta ~~line.~~ **reversed.**
3. **Testability** (decision, option A recommended)
   - why: Gamma must be testable
   - findings: Testability 1
   - Option A - Keep gamma (recommended): Gamma kept
     - Gamma ~~line.~~ **line (kept).**
   - Option B - Drop gamma: Gamma dropped
     - Gamma ~~line.~~ **dropped.**

### Minor edits

1. Fidelity: Alpha primed
4. Testability: resolved by item 3'
assert_eq "no ### Item heading, only the lens and minor ones" "$(grep '^### ' <<<"$out")" '### Lenses
### Minor edits'
for src_quote in "Beta contradicts the plan." "Gamma is untestable." "Gamma again." "Alpha is stale."; do
  assert_not_contains "no finding quoted: $src_quote" "$out" "$src_quote"
done
d="$(src_dir)"
sed -i '6s/ minor$/ material/; 14s/.*/@@ why Alpha is stale/' "$d/batch.md"
src "$d"
assert_status "a round with a resolved item but no minor one passes" "$st" 0
assert_eq "its Minor edits list holds the resolved item alone" "${out#*$'\n\n### Minor edits\n\n'}" \
  '4. Testability: resolved by item 3'
sed -i '/^@@ item 4 /,$d' "$d/batch.md"
src "$d"
assert_status "a round with nothing minor or resolved passes" "$st" 0
assert_not_contains "and prints no Minor edits heading" "$out" "Minor edits"
d="$(src_dir)"
sed -i '15s/ material / minor /; 23s/.*//' "$d/batch.md"
src "$d"
assert_eq "a recommend-decline minor item's line carries its reason" \
  "$(has_line "$out" "2. Consistency: Beta reversed - recommend decline: the plan chose this")" yes

# Marks: each malformed one refused, naming its batch.md line.
d="$(src_dir)"
sed -i '6s/ minor$//' "$d/batch.md"
check_refused src "an item with no mark" "$d" \
  "orch: batch.md line 6: @@ item 1 ... apply needs its mark, material or minor"
d="$(src_dir)"
sed -i '15s/ material / /' "$d/batch.md"
check_refused src "a decline item with no mark" "$d" \
  "orch: batch.md line 15: item 2's mark must be material or minor, got 'the'"
d="$(src_dir)"
sed -i '6s/ minor$/ major/' "$d/batch.md"
check_refused src "an unknown mark" "$d" \
  "orch: batch.md line 6: item 1's mark must be material or minor, got 'major'"
d="$(src_dir)"
sed -i '41s/$/ minor/' "$d/batch.md"
check_refused src "a mark on a resolved item" "$d" \
  "orch: batch.md line 41: @@ item 4 ... a resolved item carries no mark"
d="$(src_dir)"
sed -i '24s/ material$/ minor/' "$d/batch.md"
check_refused src "a decision item marked minor" "$d" \
  "orch: batch.md line 24: decision item 3 is always material, never minor"
d="$(src_dir)"
sed -i '6s/fidelity apply minor/contradicts-the-plan apply minor/' "$d/batch.md"
check_refused src "a contradicts-the-plan item marked minor" "$d" \
  "orch: batch.md line 6: contradicts-the-plan item 1 is always material, never minor"

# @@ why (#1248): required on every material item, refused anywhere else, each
# refusal naming its batch.md line.
d="$(src_dir)"
sed -i '23s/.*//' "$d/batch.md"
check_refused src "a material decline item with no @@ why" "$d" \
  "orch: batch.md line 15: item 2 has no @@ why"
d="$(src_dir)"
sed -i '26d' "$d/batch.md"
check_refused src "a decision item with no @@ why" "$d" \
  "orch: batch.md line 24: item 3 has no @@ why"
d="$(src_dir)"
sed -i '23s/.*/@@ why/' "$d/batch.md"
check_refused src "an empty @@ why" "$d" "orch: batch.md line 23: @@ why needs its line"
d="$(src_dir)"
sed -i '14s/.*/@@ why Alpha is stale/' "$d/batch.md"
check_refused src "a @@ why on a minor item" "$d" "orch: batch.md line 14: a minor item carries no @@ why"
d="$(src_dir)"
printf '@@ why Gamma again\n' >>"$d/batch.md"
check_refused src "a @@ why on a resolved item" "$d" "orch: batch.md line 44: a resolved item carries no @@ why"
d="$(src_dir)"
sed -i '26d; 27a @@ why Gamma must be testable' "$d/batch.md"
check_refused src "a @@ why under an @@ option" "$d" \
  "orch: batch.md line 27: @@ why belongs to the item, never under an @@ option"
d="$(src_dir)"
sed -i '16a @@ why Beta again' "$d/batch.md"
check_refused src "a second @@ why on one item" "$d" "orch: batch.md line 24: a second @@ why for this item"

# The view of the skill's worked-example batch, as it stands: one item of each
# kind and its ran and standalone lens lines.
d="$(mktemp -d)"
cat >"$d/spec.md" <<'BODY'
# Widget export

## Problem Statement

Exports time out on large widgets.

## Solution

The export streams each widget in pages of 100.
The export writes one file.

## Testing Decisions

- One seam: the `widget export` CLI.
BODY
cat >"$d/batch.md" <<'BATCH'
@@ lens fidelity standalone
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability ran

@@ item 1 consolidation apply material
@@ summary Failed pages are retried once
@@ why A page that fails once should not fail the whole export
@@ comment @alice 2026-10-01T09:00:00Z
@@ quote
A failed page should be retried once before the export gives up.
@@ anchor
The export streams each widget in pages of 100.
@@ replace
The export streams each widget in pages of 100.
A failed page is retried once before the export fails.
@@ end

@@ item 2 testability apply material
@@ finding testability 1
@@ summary The seam's test runs against a fake store
@@ why The seam names no store to test against
@@ anchor
- One seam: the `widget export` CLI.
@@ replace
- One seam: the `widget export` CLI, end to end, against a fake store.
@@ end

@@ item 3 consistency decline minor the glossary's term is widget, as the body says
@@ finding consistency 1
@@ summary Widgets renamed items
@@ anchor
Exports time out on large widgets.
@@ replace
Exports time out on large items.
@@ end

@@ item 4 implementability decision B material
@@ finding implementability 1
@@ why One file cannot hold the largest exports
@@ option A One file
@@ summary The export writes one compressed file
@@ anchor
The export writes one file.
@@ replace
The export writes one compressed file.
@@ end
@@ option B One file per widget
@@ summary The export writes one file per widget
@@ anchor
The export writes one file.
@@ replace
The export writes one file per widget.
@@ end

@@ item 5 implementability resolved
@@ finding implementability 2
@@ resolved-by 4
BATCH
printf '@@ finding 1\nThe body says widget where the glossary says item.\n' >"$d/lens-consistency.md"
printf '@@ finding 1\nThe seam names no store to test against.\n' >"$d/lens-testability.md"
printf '@@ finding 1\nOne file cannot hold the largest exports.\nThe store caps a file at 2 GB.\n@@ finding 2\nOne file is written before every page is fetched.\n' \
  >"$d/lens-implementability.md"
before="$(dir_snapshot "$d")"
src "$d"
assert_status "the worked example passes" "$st" 0
assert_eq "its view, the material items as a list, the minor and resolved ones listed" "$out" '## The batch

### Lenses

- Fidelity: not run - standalone review, no plan to check against
- Consistency: ran
- Testability: ran
- Implementability: ran

1. **Consolidation** - Failed pages are retried once (apply)
   - why: A page that fails once should not fail the whole export
   - comments: comment by @alice, 2026-10-01T09:00:00Z
   - …widget in pages of 100. **A failed page is retried once before the export fails.**
2. **Testability** - The seam'"'"'s test runs against a fake store (apply)
   - why: The seam names no store to test against
   - findings: Testability 1
   - …One seam: the `widget export` ~~CLI.~~ **CLI, end to end, against a fake store.**
4. **Implementability** (decision, option B recommended)
   - why: One file cannot hold the largest exports
   - findings: Implementability 1
   - Option A - One file: The export writes one compressed file
     - The export writes one **compressed** file.
   - Option B - One file per widget (recommended): The export writes one file per widget
     - The export writes one ~~file.~~ **file per widget.**

### Minor edits

3. Consistency: Widgets renamed items - recommend decline: the glossary'"'"'s term is widget, as the body says
5. Implementability: resolved by item 4'
assert_eq "its summary on stderr" "$err" \
  "batch.md passes: 5 items, 5 anchors, each matching once in spec.md, and the all answer applies cleanly"
assert_eq "the worked example's directory unchanged" "$(dir_snapshot "$d")" "$before"

# The view of a flow's batch: Fidelity ran with a contradicts-the-plan item,
# and a lens that did not run, cited by nothing. An edit holding a fence is
# diffed as words like any other, its backticks passed through as is.
d="$(mktemp -d)"
cat >"$d/spec.md" <<'BODY'
# Sync

Run sync nightly:
```sh
orch sync
```
BODY
cat >"$d/batch.md" <<'BATCH'
@@ lens fidelity ran
@@ lens consistency ran
@@ lens testability not-run timed out twice
@@ lens implementability ran

@@ item 1 contradicts-the-plan apply material
@@ finding fidelity 1
@@ summary Sync runs hourly, as the plan decided
@@ why The plan decided hourly
@@ anchor
Run sync nightly:
```sh
orch sync
```
@@ replace
Run sync hourly:
```sh
orch sync --hourly
```
@@ end
BATCH
printf '@@ finding 1\nThe plan decided hourly; the spec says nightly.\n' >"$d/lens-fidelity.md"
printf '@@ none\n' >"$d/lens-consistency.md"
printf '@@ none\n' >"$d/lens-implementability.md"
before="$(dir_snapshot "$d")"
src "$d"
assert_status "a flow batch passes" "$st" 0
assert_eq "its view, the fenced edit diffed word by word, unfenced" "$out" '## The batch

### Lenses

- Fidelity: ran
- Consistency: ran
- Testability: not run - timed out twice
- Implementability: ran

1. **Contradicts the plan** - Sync runs hourly, as the plan decided (apply)
   - why: The plan decided hourly
   - findings: Fidelity 1
   - Run sync ~~nightly:~~ **hourly:** ```sh orch sync **--hourly** ```'
assert_eq "its summary on stderr" "$err" \
  "batch.md passes: 1 items, 1 anchors, each matching once in spec.md, and the all answer applies cleanly"
assert_eq "the flow batch's directory unchanged" "$(dir_snapshot "$d")" "$before"

# The word diff (#1250): the anchor against the replacement, word by word,
# each changed span one sub-bullet with up to 5 words of context, `…` only
# where context is cut short.
# srd_words <from> <to>: the words w<from> to w<to>, one space apart.
srd_words() {
  local k out=""
  for ((k = $1; k <= $2; k++)); do out="${out:+$out }w$k"; done
  printf '%s' "$out"
}
# srd <anchor> <replacement>: check on a round whose one item, material,
# edits <anchor> to <replacement>; its status into st, its change sub-bullets
# into chg.
srd() {
  local d
  d="$(mktemp -d)"
  printf '# Spec\n\n%s\n' "$1" >"$d/spec.md"
  printf '@@ lens fidelity ran\n@@ lens consistency ran\n@@ lens testability ran\n@@ lens implementability ran\n
@@ item 1 fidelity apply material\n@@ finding fidelity 1\n@@ summary S\n@@ why W\n@@ anchor\n%s\n@@ replace\n%s\n@@ end\n' \
    "$1" "$2" >"$d/batch.md"
  printf '@@ finding 1\nF.\n' >"$d/lens-fidelity.md"
  printf '@@ none\n' | tee "$d/lens-consistency.md" "$d/lens-testability.md" >"$d/lens-implementability.md"
  src "$d"
  chg="$(sed -n '/^   - findings: /,${//d;p}' <<<"$out")"
}
srd "$(srd_words 1 20)" "$(srd_words 1 9) X $(srd_words 11 20)"
assert_status "a word diff's batch passes" "$st" 0
assert_eq "context cut short on both sides is marked" "$chg" \
  "   - …w5 w6 w7 w8 w9 ~~w10~~ **X** w11 w12 w13 w14 w15…"
srd "a b c" "a X c"
assert_eq "context running to the start and the end is not" "$chg" "   - a ~~b~~ **X** c"
srd "$(srd_words 1 30)" "$(srd_words 1 4) X $(srd_words 6 16) Y $(srd_words 18 30)"
assert_eq "two runs 11 unchanged words apart are two spans" "$chg" \
  "   - w1 w2 w3 w4 ~~w5~~ **X** w6 w7 w8 w9 w10…
   - …w12 w13 w14 w15 w16 ~~w17~~ **Y** w18 w19 w20 w21 w22…"
srd "$(srd_words 1 30)" "$(srd_words 1 4) X $(srd_words 6 15) Y $(srd_words 17 30)"
assert_eq "two runs 10 unchanged words apart share one span, the words between in full" "$chg" \
  "   - w1 w2 w3 w4 ~~w5~~ **X** w6 w7 w8 w9 w10 w11 w12 w13 w14 w15 ~~w16~~ **Y** w17 w18 w19 w20 w21…"
srd "a b c d" "a b new words c d"
assert_eq "a pure insertion shows only its added words" "$chg" "   - a b **new words** c d"
srd "a b gone c d" "a b c d"
assert_eq "a pure deletion only its removed words" "$chg" "   - a b ~~gone~~ c d"
srd "one two
three four" "one two
three five"
assert_eq "a multi-line anchor diffs as one run of words" "$chg" "   - one two three ~~four~~ **five**"
srd "a b c" "a  b
c"
assert_status "an edit with no changed words passes" "$st" 0
assert_eq "and shows it changes only whitespace" "$chg" "   - whitespace only, see full view"
srd "a $(srd_words 1 20)" "a $(sed 's/w/x/g' <<<"$(srd_words 1 21)")"
assert_eq "41 changed words collapse to the edit's size" "$chg" "   - rewritten, 41 words, see full view"
srd "a $(srd_words 1 20)" "a $(sed 's/w/x/g' <<<"$(srd_words 1 20)")"
assert_eq "40 do not" "$chg" "   - a ~~$(srd_words 1 20)~~ **$(sed 's/w/x/g' <<<"$(srd_words 1 20)")**"
d="$(src_dir)"
sed -i "39s/.*/Gamma $(srd_words 1 40)/" "$d/batch.md"
src "$d"
assert_contains "a decision option past the limit collapses on its own" "$out" \
  "   - Option A - Keep gamma (recommended): Gamma kept
     - Gamma ~~line.~~ **line (kept).**
   - Option B - Drop gamma: Gamma dropped
     - rewritten, 41 words, see full view"

# The word lists live in a mktemp -d directory check removes, on success and
# when git fails; a git exiting above 1 fails check naming the item.
src_tmp="$(mktemp -d)"
d="$(src_dir)"
TMPDIR="$src_tmp" src "$d"
assert_status "check passes with its own TMPDIR" "$st" 0
assert_eq "check leaves no file behind" "$(ls -A "$src_tmp")" ""
TMPDIR="$src_tmp" src "$d" --full 1 3
assert_status "--full passes with its own TMPDIR" "$st" 0
assert_eq "--full leaves no file behind" "$(ls -A "$src_tmp")" ""
src_git="$(mktemp -d)"
cat >"$src_git/git" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" --no-index "*) echo "fatal: broken" >&2; exit 128 ;; esac
exec $(type -P git) "\$@"
FAKE
chmod +x "$src_git/git"
before="$(dir_snapshot "$d")"
PATH="$src_git:$PATH" TMPDIR="$src_tmp" src "$d"
assert_status "a git exiting above 1 fails check" "$st" 1
assert_eq "with an orch: message naming the item" "$err" "fatal: broken
orch: item 2: git diff exited 128 rendering its word diff"
assert_eq "and no half view" "$out" ""
assert_eq "leaving no file behind" "$(ls -A "$src_tmp")" ""
assert_eq "and the round directory unchanged" "$(dir_snapshot "$d")" "$before"
# A failed write of the diff output is not git's "texts differ": the first
# diff leaves its output read-only, so the next one cannot open it to write.
cat >"$src_git/git" <<FAKE
#!/usr/bin/env bash
case " \$* " in *" --no-index "*) chmod 400 "\$(dirname "\${@: -1}")/diff" ;; esac
exec $(type -P git) "\$@"
FAKE
PATH="$src_git:$PATH" TMPDIR="$src_tmp" src "$d"
assert_status "a failed write of the word diff fails check" "$st" 1
assert_contains "with an orch: message naming the item" "$err" "orch: item 3 option A: could not write its word diff in $src_tmp/"
assert_not_contains "not git's exit status 1" "$err" "git diff exited"
assert_eq "and no half view, no whitespace-only line" "$out" ""
assert_eq "leaving no file behind on a failed write" "$(ls -A "$src_tmp")" ""
rm -rf "$src_tmp" "$src_git"

# No flow state read, no GitHub touched.
mkdir -p "$top/.orchestrator"
printf '{not json' >"$top/.orchestrator/state.json"
fake_offline
src "$d"
assert_status "a malformed state.json and an unreachable GitHub do not matter" "$st" 0
fake_online
rm -rf "$top/.orchestrator"

# The body read is spec.fetched.md when it exists.
d="$(src_dir)"
sed 's/^Alpha line\.$/Alpha prime line./' <<<"$src_body" >"$d/spec.md"
printf '%s' "$src_body" >"$d/spec.fetched.md"
src "$d"
assert_status "an edited spec.md passes against the spec.fetched.md it came from" "$st" 0
assert_contains "naming spec.fetched.md" "$err" "each matching once in spec.fetched.md"
printf '%s' "$src_body" >"$d/spec.md"
sed 's/^Alpha line\.$/Alpha moved./' <<<"$src_body" >"$d/spec.fetched.md"
check_refused src "an anchor spec.md has but spec.fetched.md lacks" "$d" \
  "orch: batch.md line 9: item 1: its anchor matches no text in the body"

# Anchors: each problem once, every one in one run, each naming its line.
d="$(src_dir)"
sed -i '10s/.*/Twice./' "$d/batch.md"
check_refused src "an anchor matching twice, reported once" "$d" \
  "orch: batch.md line 9: item 1: its anchor matches more than one place in the body"
d="$(src_dir)"
sed -i '10a Beta line.' "$d/batch.md"
check_refused src "two overlapping edits, caught by the all dry run" "$d" \
  "orch: batch.md line 19: item 2: its anchor no longer matches exactly once after the earlier items' edits"
d="$(src_dir)"
sed -i '37s/.*/Nowhere either./' "$d/batch.md"
check_refused src "a decision option's anchor matching nothing" "$d" \
  "orch: batch.md line 36: item 3 option B: its anchor matches no text in the body"
d="$(src_dir)"
sed -i '10s/.*/Nowhere./; 19s/.*/Twice./; 37s/.*/Nowhere either./' "$d/batch.md"
check_refused src "several bad anchors" "$d" \
  "orch: batch.md line 9: item 1: its anchor matches no text in the body
orch: batch.md line 18: item 2: its anchor matches more than one place in the body
orch: batch.md line 36: item 3 option B: its anchor matches no text in the body"

# Grammar: the first error only.
d="$(src_dir)"
sed -i '7s/.*/@@ bogus/; 16s/.*/@@ bogus/' "$d/batch.md"
check_refused src "two grammar errors" "$d" "orch: batch.md line 7: unknown line '@@ bogus'"

# Lens files and citations.
d="$(src_dir)"
sed -i '42s/.*/@@ finding testability 3/' "$d/batch.md"
check_refused src "a citation past its lens file's count" "$d" \
  "orch: batch.md line 42: cites finding 3 of lens testability, but lens-testability.md holds 2"
d="$(src_dir)"
printf 'preamble\n@@ finding 1\nx\n' >"$d/lens-consistency.md"
check_refused src "a malformed lens file" "$d" \
  "orch: lens-consistency.md line 1: text before the first @@ finding"

# Errors with no batch line.
d="$(src_dir)"
rm "$d/batch.md"
check_refused src "no batch.md" "$d" "orch: batch.md not found in $d"
d="$(src_dir)"
sed -i '2d' "$d/batch.md"
check_refused src "a missing @@ lens line" "$d" \
  "orch: batch.md: no @@ lens line for consistency - every lens in the table has one"

# A batch check passes applies with all.
d="$(src_dir)"
src "$d"
assert_status "check passes the batch" "$st" 0
out="$("$ORCH" spec-review apply "$d" all --round 1/1 --issue 14 2>&1)"; st=$?
assert_status "which apply then takes with all" "$st" 0
assert_eq "every edit landing" "$(cat "$d/spec.md")" '# Spec

Alpha prime line.
Beta reversed.
Gamma line (kept).
Delta line.
Twice.
Twice.'

# apply checks only the anchors its answer accepts, naming the batch line.
src_bad2() { d="$(src_dir)"; sed -i '19s/.*/Nowhere./' "$d/batch.md"; }
src_bad2
out="$("$ORCH" spec-review apply "$d" none --round 1/1 --issue 14 2>&1)"; st=$?
assert_status "apply none passes over an unapplied item's bad anchor" "$st" 0
src_bad2
out="$("$ORCH" spec-review apply "$d" "3A, -2" --round 1/1 --issue 14 2>&1)"; st=$?
assert_status "apply with an override answer declining the item passes too" "$st" 0
assert_contains "applying the items it does not decline" "$(cat "$d/spec.md")" "Alpha prime line."
src_bad2
src "$d"
assert_eq "check names the bad anchor's line" "$err" \
  "orch: batch.md line 18: item 2: its anchor matches no text in the body"
out="$("$ORCH" spec-review apply "$d" all --round 1/1 --issue 14 2>&1)"; st=$?
assert_status "apply all refuses it" "$st" 1
assert_eq "naming the same batch line" "$out" \
  "orch: batch.md line 18: item 2: its anchor matches no text in the body - nothing applied, nothing written"

# check --full <n>... (#1249): the named items alone, each in the full
# rendering, in the order named - any item in batch.md, minor or resolved
# included - with nothing written.
d="$(src_dir)"
before="$(dir_snapshot "$d")"
snap="$(fake_snapshot)"
src "$d" --full 4 1 2
assert_status "--full passes on a clean batch" "$st" 0
assert_eq "--full prints the named items in full, in the order named, a minor and a resolved one among them" "$out" '
### Item 4 - Testability

**Recommendation:** resolved by item 3

**Finding** (Testability 2):

> Gamma again.

### Item 1 - Fidelity

**Recommendation:** apply

**Finding** (Fidelity 1):

> Alpha is stale.

**Current**

```
Alpha line.
```

**Proposed**

```
Alpha prime line.
```

### Item 2 - Consistency

**Recommendation:** recommend decline - the plan chose this

**Finding** (Consistency 1):

> Beta contradicts the plan.

**Current**

```
Beta line.
```

**Proposed**

```
Beta reversed.
```'
assert_eq "--full keeps check's one-line summary on stderr" "$err" \
  "batch.md passes: 4 items, 4 anchors, each matching once in spec.md, and the all answer applies cleanly"
assert_eq "--full leaves the directory byte-identical" "$(dir_snapshot "$d")" "$before"
assert_eq "--full creates no spec.fetched.md" "$(on_disk "$d/spec.fetched.md")" absent
assert_eq "--full makes no GitHub write" "$(fake_snapshot)" "$snap"
src "$d" --full 3
assert_contains "--full shows a decision item's options in full" "$out" "#### Option A - Keep gamma (recommended)"
assert_not_contains "and no item it was not asked for" "$out" "### Item 2"
assert_not_contains "nor the lens lines" "$out" "### Lenses"

# Refusals: a missing or unknown number, and --full with --tickets.
src_full_none() { src "$1" --full; }
src_full_9() { src "$1" --full 9; }
src_full_word() { src "$1" --full 2 two; }
src_full_tickets() { src "$1" --full 2 --tickets; }
src_tickets_full() { src "$1" --tickets --full 2; }
d="$(src_dir)"
check_refused src_full_none "--full with no number" "$d" \
  "orch: --full needs at least one item number (usage: orch.sh spec-review check <dir> [--tickets | --full <n>...])"
check_refused src_full_9 "--full naming an item not in batch.md" "$d" \
  "orch: --full 9: batch.md has no item 9"
check_refused src_full_word "--full naming a non-number" "$d" \
  "orch: --full two: batch.md has no item two"
check_refused src_full_tickets "--full then --tickets" "$d" \
  "orch: --full and --tickets do not combine (usage: orch.sh spec-review check <dir> [--tickets | --full <n>...])"
check_refused src_tickets_full "--tickets then --full" "$d" \
  "orch: --full and --tickets do not combine (usage: orch.sh spec-review check <dir> [--tickets | --full <n>...])"
d="$(src_dir)"
sed -i '19s/.*/Nowhere./' "$d/batch.md"
src_full_1() { src "$1" --full 1; }
check_refused src_full_1 "--full on a batch check refuses" "$d" \
  "orch: batch.md line 18: item 2: its anchor matches no text in the body"

# Discoverability.
out="$("$ORCH" spec-review wipe 2>&1)"
assert_contains "the unknown-op message lists check" "$out" "want begin|check|apply"
assert_contains "help documents spec-review check" "$("$ORCH" help)" "spec-review check <dir>"
assert_contains "help documents spec-review check --full" "$("$ORCH" help)" "spec-review check <dir> [--tickets | --full <n>...]"
restore_suite_env

# --- spec-review check --tickets (#1226) ---------------------------------------
# The ticket items validated before the ticket question - grammar, every text
# anchor against the copy apply would edit, and every edge against its
# ticket's ## Blocked by, as the all answer would take them - with nothing
# written and no GitHub read, then the ticket view on stdout.
echo
echo "spec-review check --tickets (#1226)"
new_repo >/dev/null
fake_github
srct_t20='## What to build

Build alpha.

## Blocked by

None (can start immediately)'
srct_t21='## What to build

Build gamma.

## Blocked by

- #20'
# srct_dir: a fresh round directory after the pause - spec.md, #20 and #21
# fetched into ticket-<n>.md, and tickets.md drafted; prints its path. Its
# @@ anchor lines: item 1 on 4, item 4 on 14.
srct_dir() {
  local d
  d="$(mktemp -d)"
  printf '# Spec\n\nAlpha line.\n' >"$d/spec.md"
  printf '%s' "$srct_t20" >"$d/ticket-20.md"
  printf '%s' "$srct_t21" >"$d/ticket-21.md"
  cat >"$d/tickets.md" <<'TICKETS'
@@ recommend apply
@@ item 1 ticket 20 apply
@@ summary #20 builds alpha prime
@@ anchor
Build alpha.
@@ replace
Build alpha prime.
@@ end

@@ item 2 unblock 21 by 20 apply
@@ item 3 block 20 by 21 apply
@@ item 4 ticket 21 decline gamma is unchanged
@@ summary #21 builds gamma twice
@@ anchor
Build gamma.
@@ replace
Build gamma twice.
@@ end
@@ closed 22 the gamma API
TICKETS
  printf '%s\n' "$d"
}
# srct <dir>: src with --tickets.
srct() { src "$1" --tickets; }
# srct_passes <label> <dir> <stdout> <stderr>: check --tickets exits 0 with
# exactly <stdout> and <stderr>, and <dir> unchanged.
srct_passes() {
  local before
  before="$(dir_snapshot "$2")"
  srct "$2"
  assert_status "$1: passes" "$st" 0
  assert_eq "$1: the ticket view on stdout" "$out" "$3"
  assert_eq "$1: the pass summary on stderr" "$err" "$4"
  assert_not_contains "$1: and not on stdout" "$out" "tickets.md passes"
  assert_eq "$1: the directory unchanged" "$(dir_snapshot "$2")" "$before"
}

d="$(srct_dir)"
srct_passes "a ticket batch" "$d" '## The ticket items

### Item 1 - #20

**Recommendation:** apply

**Current**

```
Build alpha.
```

**Proposed**

```
Build alpha prime.
```

### Item 2 - unblock #21 by #20

**Recommendation:** apply

### Item 3 - block #20 by #21

**Recommendation:** apply

### Item 4 - #21

**Recommendation:** recommend decline - gamma is unchanged

**Current**

```
Build gamma.
```

**Proposed**

```
Build gamma twice.
```

### Closed tickets

- #22 - the gamma API

**Recommended answer:** apply' \
  "tickets.md passes: 4 items, 2 anchors, each matching once, and the all answer applies cleanly"
assert_eq "no fetched copy taken" "$(on_disk "$d/ticket-20.fetched.md")" absent

# A collapsed breakdown's ## Ticket item, anchored on spec.md.
d="$(mktemp -d)"
printf '# Spec\n\n## Ticket\n\nBuild the spec.\n' >"$d/spec.md"
printf '@@ recommend retire\n@@ item 1 section apply\n@@ summary The ticket builds alpha first\n@@ anchor\nBuild the spec.\n@@ replace\nBuild the spec, alpha first.\n@@ end\n' >"$d/tickets.md"
srct_passes "a ## Ticket item" "$d" '## The ticket items

### Item 1 - the `## Ticket` section

**Recommendation:** apply

**Current**

```
Build the spec.
```

**Proposed**

```
Build the spec, alpha first.
```

### Closed tickets

None

**Recommended answer:** retire - the ticket breakdown retired, to be broken down again' \
  "tickets.md passes: 1 items, 1 anchors, each matching once, and the all answer applies cleanly"
printf '@@ recommend apply\n@@ item 1 section apply\n@@ summary s\n@@ anchor\nNowhere.\n@@ replace\nx\n@@ end\n' >"$d/tickets.md"
check_refused srct "a section anchor not in spec.md" "$d" \
  "orch: tickets.md line 4: ticket item 1 (## Ticket): its anchor matches no text in the body"

# @@ none-affected.
d="$(mktemp -d)"
printf '# Spec\n' >"$d/spec.md"
printf '@@ none-affected\n' >"$d/tickets.md"
srct_passes "@@ none-affected" "$d" '## The ticket items

No open ticket is affected.' "tickets.md passes: no open ticket affected"

# An earlier run's fetched copy is the one apply edits, so the anchor is
# checked against it.
d="$(srct_dir)"
printf '%s' "$srct_t20" >"$d/ticket-20.fetched.md"
printf 'Rewritten.\n' >"$d/ticket-20.md"
srct "$d"
assert_status "an anchor matching the fetched copy, not ticket-20.md, passes" "$st" 0
d="$(srct_dir)"
printf 'Rewritten.\n' >"$d/ticket-20.fetched.md"
check_refused srct "an anchor matching ticket-20.md, not the fetched copy" "$d" \
  "orch: tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"

# Refusals.
d="$(srct_dir)"
sed -i 's/^Build alpha\.$/Nowhere./' "$d/tickets.md"
check_refused srct "a ticket anchor matching nothing" "$d" \
  "orch: tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body"
d="$(srct_dir)"
sed -i 's/^Build alpha\.$/##/' "$d/tickets.md"
check_refused srct "a ticket anchor matching twice" "$d" \
  "orch: tickets.md line 4: ticket item 1 (#20): its anchor matches more than one place in the body"
d="$(srct_dir)"
sed -i 's/^Build alpha\.$/Nowhere./; s/^Build gamma\.$/Nowhere./' "$d/tickets.md"
check_refused srct "two bad anchors, each named" "$d" \
  "orch: tickets.md line 4: ticket item 1 (#20): its anchor matches no text in the body
orch: tickets.md line 14: ticket item 4 (#21): its anchor matches no text in the body"
d="$(srct_dir)"
printf '@@ bogus\n' >>"$d/tickets.md"
check_refused srct "a grammar error" "$d" "orch: tickets.md line 20: unknown line '@@ bogus'"
d="$(srct_dir)"
rm "$d/tickets.md"
check_refused srct "no tickets.md" "$d" "orch: tickets.md not found in $d"
d="$(srct_dir)"
rm "$d/spec.md"
check_refused srct "no spec.md" "$d" "orch: spec.md not found in $d"
d="$(srct_dir)"
rm "$d/ticket-20.md"
check_refused srct "no ticket file, named by each item needing it" "$d" \
  "orch: tickets.md line 2: ticket item 1: ticket-20.md not found in $d - fetch each ticket a ticket item names into it
orch: tickets.md line 11: ticket item 3: ticket-20.md not found in $d - fetch each ticket a ticket item names into it"
d="$(srct_dir)"
sed -i 's/^@@ item 3 block 20 by 21 apply$/@@ item 3 block 21 by 20 apply/' "$d/tickets.md"
check_refused srct "a block edge already present" "$d" \
  "orch: tickets.md line 11: ticket item 3: #21 is already blocked by #20"
d="$(srct_dir)"
sed -i 's/^@@ item 2 unblock 21 by 20 apply$/@@ item 2 unblock 20 by 21 apply/' "$d/tickets.md"
check_refused srct "an unblock edge absent" "$d" \
  "orch: tickets.md line 10: ticket item 2: #20 is not blocked by #21"

assert_contains "help documents spec-review check --tickets" "$("$ORCH" help)" "spec-review check <dir> [--tickets | --full <n>...]"
restore_suite_env

# --- spec-review wait (#1183) --------------------------------------------------
# The session running a spec review starts its lenses and waits for all of them
# in one blocking call: a lens is back when its findings file exists, and the
# wait prints one summary line, or times out naming the lenses still missing.
echo
echo "spec-review wait (#1183)"
new_repo >/dev/null
export ORCH_SPEC_REVIEW_WAIT_TIMEOUT=1 ORCH_SPEC_REVIEW_WAIT_INTERVAL=0.05
wait_dir="$(mktemp -d)"
printf '@@ finding 1\nOne.\n@@ finding 2\nTwo.\n' >"$wait_dir/lens-testability.md"
printf '@@ none\n' >"$wait_dir/lens-consistency.md"
printf 'neither kind of line\n' >"$wait_dir/lens-implementability.md"
out="$("$ORCH" spec-review wait "$wait_dir" testability consistency implementability 2>&1)"; st=$?
assert_status "every named lens file present: the wait succeeds" "$st" 0
assert_eq "one summary line, in the order named, @@ none and a file with neither counting 0" "$out" \
  "lenses back: testability 2, consistency 0, implementability 0"

: >"$wait_dir/lens-implementability.md"
out="$("$ORCH" spec-review wait "$wait_dir/" implementability 2>&1)"; st=$?
assert_status "an empty findings file is back too" "$st" 0
assert_eq "counting 0" "$out" "lenses back: implementability 0"

out="$("$ORCH" spec-review wait "$wait_dir" consistency 2>&1)"; st=$?
assert_status "only the named lenses are waited for: a missing unnamed lens does not block" "$st" 0
assert_eq "and only the named lens is summarized" "$out" "lenses back: consistency 0"

wait_late="$(mktemp -d)"
( sleep 0.3; printf '@@ finding 1\nLate.\n' >"$wait_late/lens-fidelity.md" ) &
out="$(ORCH_SPEC_REVIEW_WAIT_TIMEOUT=5 "$ORCH" spec-review wait "$wait_late" fidelity 2>&1)"; st=$?
wait
assert_status "a file that appears during the wait ends it" "$st" 0
assert_eq "with that lens's count" "$out" "lenses back: fidelity 1"

wait_err="$(mktemp)"
out="$("$ORCH" spec-review wait "$wait_dir" testability fidelity consistency implementability 2>"$wait_err")"; st=$?
assert_status "a named lens missing past the timeout fails" "$st" 1
assert_eq "printing nothing on stdout" "$out" ""
assert_eq "and naming only the missing lens on stderr" "$(cat "$wait_err")" \
  "orch: lenses not back after 1s: fidelity"
rm -f "$wait_dir/lens-consistency.md"
"$ORCH" spec-review wait "$wait_dir" consistency testability fidelity >/dev/null 2>"$wait_err"; st=$?
assert_status "two missing lenses fail too" "$st" 1
assert_eq "naming both, in the order named" "$(cat "$wait_err")" \
  "orch: lenses not back after 1s: consistency fidelity"

out="$("$ORCH" spec-review wait "$wait_dir" testability clarity 2>&1)"; st=$?
assert_status "an unknown lens name is a usage error" "$st" 1
assert_eq "naming it and the four lenses" "$out" \
  "orch: unknown lens 'clarity' (want one of: fidelity consistency testability implementability)"
out="$("$ORCH" spec-review wait "$wait_dir/nowhere" testability 2>&1)"; st=$?
assert_status "a missing directory is a usage error" "$st" 1
assert_eq "naming it" "$out" "orch: no such directory: $wait_dir/nowhere"
out="$("$ORCH" spec-review wait "$wait_dir" 2>&1)"; st=$?
assert_status "no lens names is a usage error" "$st" 1
assert_eq "printing the usage" "$out" "orch: usage: orch.sh spec-review wait <dir> <lens>..."

out="$(ORCH_SPEC_REVIEW_WAIT_TIMEOUT=soon "$ORCH" spec-review wait "$wait_dir" testability 2>&1)"; st=$?
assert_status "a non-numeric timeout is rejected" "$st" 1
assert_eq "naming the variable" "$out" "orch: ORCH_SPEC_REVIEW_WAIT_TIMEOUT is not a number: soon"
out="$(ORCH_SPEC_REVIEW_WAIT_INTERVAL=often "$ORCH" spec-review wait "$wait_dir" testability 2>&1)"; st=$?
assert_status "a non-numeric interval is rejected" "$st" 1
assert_eq "naming the variable" "$out" "orch: ORCH_SPEC_REVIEW_WAIT_INTERVAL is not a number: often"
out="$(ORCH_SPEC_REVIEW_WAIT_INTERVAL=0.0 timeout 5 "$ORCH" spec-review wait "$wait_dir" fidelity 2>&1)"; st=$?
assert_status "a zero interval is rejected" "$st" 1
assert_eq "naming the variable" "$out" "orch: ORCH_SPEC_REVIEW_WAIT_INTERVAL must be greater than zero: 0.0"

out="$("$ORCH" spec-review wipe 2>&1)"
assert_contains "the unknown-op message lists wait" "$out" "want begin|check|apply|wait"
assert_contains "help documents spec-review wait" "$("$ORCH" help)" "spec-review wait <dir> <lens>..."
rm -rf "$wait_dir" "$wait_late" "$wait_err"
restore_suite_env ORCH_SPEC_REVIEW_WAIT_TIMEOUT ORCH_SPEC_REVIEW_WAIT_INTERVAL
