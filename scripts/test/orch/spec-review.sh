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
