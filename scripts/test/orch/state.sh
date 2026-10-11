# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- state ------------------------------------------------------------------
echo
echo "state"
fake_flow state
assert_eq "round-trips a string value" \
  "$("$ORCH" state set budget unbounded; "$ORCH" state get budget)" "unbounded"
"$ORCH" state set budget 3
assert_eq "sets budget" "$("$ORCH" state get budget)" "3"
"$ORCH" state set flake_rerun_used true
assert_eq "sets flake_rerun_used" "$("$ORCH" state get flake_rerun_used)" "true"
"$ORCH" state set budget null
"$ORCH" state set flake_rerun_used false
before="$("$ORCH" state get phase)"
out="$("$ORCH" state set phase review 2>&1)"; st=$?
assert_status "refuses to set phase" "$st" 1
assert_eq "naming phase advance as its owner, in full" "$out" \
  "orch: state set refuses phase: use phase advance (review ready and redo also move it)"
assert_eq "and leaves the phase as it was" "$("$ORCH" state get phase)" "$before"
# Each refusal is pinned as its whole line, so a change to any wording fails.
for pair in "branch|branch create records it" "base_sha|branch create records it" \
            "pr|pr open records it" "iteration|review begin counts it" \
            "redo_count|redo review counts it" "slug|init seeds it" \
            "base|init seeds it" "created|init seeds it" \
            "host_fallbacks|init seeds it" "updated|every state change stamps it" \
            "bogus|settable keys are issue, budget, flake_rerun_used"; do
  key="${pair%%|*}"; owner="${pair#*|}"
  out="$("$ORCH" state set "$key" 1 2>&1)"; st=$?
  assert_status "refuses to set $key" "$st" 1
  assert_eq "naming what owns $key, in full" "$out" "orch: state set refuses $key: $owner"
done
"$ORCH" state set issue 42
assert_eq "coerces a numeric value to a number" "$("$ORCH" state get issue)" "42"
assert_eq "stores issue as JSON number, not string" \
  "$("$ORCH" state get | jq -r '.issue | type')" "number"
"$ORCH" state set issue null
assert_eq "accepts an explicit null" "$("$ORCH" state get | jq -r '.issue | type')" "null"
for b in true false; do
  "$ORCH" state set flake_rerun_used "$b"
  assert_eq "stores flake_rerun_used $b as a JSON boolean" \
    "$("$ORCH" state get | jq -r '.flake_rerun_used | type')" "boolean"
  assert_eq "reads flake_rerun_used $b back as $b" "$("$ORCH" state get flake_rerun_used)" "$b"
done
for pair in unbounded:string 3:number null:null; do
  "$ORCH" state set budget "${pair%%:*}"
  assert_eq "stores budget ${pair%%:*} as a JSON ${pair#*:}" \
    "$("$ORCH" state get | jq -r '.budget | type')" "${pair#*:}"
done
"$ORCH" state set budget false
assert_eq "reads a stored false back as false, not the key's default" \
  "$("$ORCH" state get budget)" "false"
# Digits with a trailing newline are not all digits, so they are stored as a
# string. jq's regex `$` used to match before the newline, and the set then
# died on tonumber's error (#711).
"$ORCH" state set budget $'12\n'; st=$?
assert_status "accepts digits with a trailing newline" "$st" 0
assert_eq "stores them as a JSON string" \
  "$("$ORCH" state get | jq -r '.budget | type')" "string"
assert_eq "and leaves the rest of state.json intact" "$("$ORCH" state get slug)" "state"
restore_suite_env

# --- a flow from before the budget shipped ----------------------------------
# An in-flight flow carries whatever state the version that started it wrote:
# no `budget`, no `loop`, no `flake_rerun_used`. Failing on any absence would
# strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the budget shipped"
fresh_flow legacy
# Raw jq, not state_fixture: deleting keys simulates an older release, and the
# Flow state module has no delete operation - one only tests would use.
legacy="$(mktemp)"
jq 'del(.budget, .loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for _ in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and it runs the default budget" "$st" 1
assert_contains "of five" "$out" "budget of 5 iterations"

state_fixture phase review
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
complete_implement_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0
assert_contains "status reads its budget as the default" "$("$ORCH" status)" "iteration 5 of 5"

# ci and ready need a PR, which a flow this old still records the same way.
state_fixture pr 3
fake_github
fake_pr 3 open orch/legacy main
fake_pr_draft 3
fake_checks 3 all green
out="$(ORCH_CI_GRACE=0.2 ORCH_CI_INTERVAL=0.05 "$ORCH" review ci 2>&1)"; st=$?
assert_status "review ci reads its PR from a state with no budget key" "$st" 0
assert_first_line "and classifies it" "$out" "green"
assert_eq "review ready marks the PR and finishes the flow" \
  "$("$ORCH" review ready)" "3"
assert_eq "recording done as it goes" "$("$ORCH" state get phase)" "done"
assert_eq "with the PR no longer a draft" "$(fake_pr_draft_of 3)" "no"
restore_suite_env

# --- state get reads every key with its default -----------------------------
# A state file written by an older flow lacks keys a fresh one seeds; each key
# still reads back as what an absent value has always meant.
echo
echo "state get defaults"
fresh_flow sparse
# Raw jq, not state_fixture: deleting keys simulates an older release, and the
# Flow state module has no delete operation - one only tests would use.
jq 'del(.iteration, .redo_count, .host_fallbacks, .flake_rerun_used, .budget)' \
  .orchestrator/state.json >state.tmp && mv state.tmp .orchestrator/state.json
assert_eq "an absent iteration reads as 0" "$("$ORCH" state get iteration)" "0"
assert_eq "an absent redo_count reads as 0" "$("$ORCH" state get redo_count)" "0"
assert_eq "an absent host_fallbacks reads as false" "$("$ORCH" state get host_fallbacks)" "false"
assert_eq "an absent flake_rerun_used reads as false" "$("$ORCH" state get flake_rerun_used)" "false"
assert_eq "an absent budget reads as empty" "$("$ORCH" state get budget)" ""
out="$("$ORCH" state get nonsense 2>&1)"; st=$?
assert_status "a key outside the schema is refused" "$st" 1
assert_contains "naming the key" "$out" "nonsense"
complete_plan_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow passes a state file lacking those keys" "$st" 0
# The string keys read back empty when missing too. phase goes only now: the
# doctor --flow check above would fail a state file lacking it. Raw jq, as
# above: the module has no delete operation.
jq 'del(.slug, .phase, .issue, .base, .branch, .pr, .base_sha, .created, .updated)' \
  .orchestrator/state.json >state.tmp && mv state.tmp .orchestrator/state.json
for key in slug phase issue base branch pr base_sha created updated; do
  out="$("$ORCH" state get "$key" 2>&1)"; st=$?
  assert_status "an absent $key still reads" "$st" 0
  assert_eq "an absent $key reads as empty" "$out" ""
done
restore_suite_env

# --- state.json schema ------------------------------------------------------
# What a fresh init writes, pinned: every key it seeds reads back through
# state get, and the raw file holds exactly these keys, in this order, with
# these seeds. A change to the state-key schema that alters state.json or loses
# a key's default fails here.
echo
echo "state.json schema"
fresh_flow schema
for key in $(jq -r 'keys_unsorted[]' .orchestrator/state.json); do
  "$ORCH" state get "$key" >/dev/null 2>&1; st=$?
  assert_status "state get reads $key, which init writes" "$st" 0
done
assert_eq "slug, base, created and updated are non-empty strings" \
  "$(jq -c '[.slug, .base, .created, .updated] | map(type == "string" and . != "")' .orchestrator/state.json)" \
  "[true,true,true,true]"
assert_eq "state.json holds the pinned keys, order and seeds" \
  "$(jq -c '.slug = "S" | .base = "B" | .created = "C" | .updated = "U"' .orchestrator/state.json)" \
  '{"slug":"S","phase":"spec","issue":null,"base":"B","branch":null,"pr":null,"base_sha":null,"budget":null,"iteration":0,"flake_rerun_used":false,"redo_count":0,"host_fallbacks":true,"created":"C","updated":"U"}'
restore_suite_env

# --- state set on a corrupt state.json --------------------------------------
# A write jq cannot apply stops orch.sh and leaves the file as it found it,
# with no temp file left beside it. The invalid JSON is written raw: no writer
# can produce it.
echo
echo "state set on a corrupt state.json"
fresh_flow corrupt
printf 'not json\n' >.orchestrator/state.json
before_ls="$(ls -A .orchestrator)"
"$ORCH" state set budget 3 >/dev/null 2>&1; st=$?
assert_ne "state set on an unparseable state.json exits non-zero" "$st" 0
assert_eq "and leaves it byte-identical" "$(cat .orchestrator/state.json)" "not json"
assert_eq "with nothing new beside it" "$(ls -A .orchestrator)" "$before_ls"
# A fixture arranging state on such a file fails too, so a failed arrangement
# fails its test rather than leaving a state the test did not ask for.
state_fixture budget 3 2>/dev/null; st=$?
assert_ne "state_fixture on an unparseable state.json returns non-zero" "$st" 0
assert_eq "and leaves it untouched" "$(cat .orchestrator/state.json)" "not json"
assert_eq "with nothing new beside it, after the fixture" "$(ls -A .orchestrator)" "$before_ls"
restore_suite_env

# --- the Flow state module, sourced alone -----------------------------------
# flow-state.sh is sourced by the hooks, which have no die, no ROOT and no
# STATE: each case runs it alone in a clean bash -c under set -u, outside any
# git repo, so a reference to any of them on a path exercised here fails.
echo
echo "the Flow state module, sourced alone"
fs_module="${ORCH%/*}/flow-state.sh"
fs_dir="$(mktemp -d)"
# fs_run <code>: runs <code> with the module sourced, in fs_dir, in a clean
# environment; prints its stdout and stderr together and then its status as
# the last line.
fs_run() {
  ( cd "$fs_dir" && env -i PATH="$SUITE_PATH" HOME="$SUITE_HOME" FS_MODULE="$fs_module" \
      bash --noprofile --norc -c 'set -u; source "$FS_MODULE"; '"$1"' ; echo "status $?"' 2>&1 )
}
assert_eq "it runs outside any git repo" \
  "$(fs_run 'git rev-parse --show-toplevel >/dev/null 2>&1')" "status 128"
assert_eq "with no die, ROOT or STATE" \
  "$(fs_run 'type die >/dev/null 2>&1 || [ -n "${ROOT+x}${STATE+x}" ]')" "status 1"
assert_eq "flow_state_file prints the state file under a root" \
  "$(fs_run 'flow_state_file /r')" "/r/.orchestrator/state.json
status 0"
printf '{"slug":"s"}' >"$fs_dir/object.json"
printf 'not json' >"$fs_dir/invalid.json"
printf '[1]' >"$fs_dir/array.json"
for pair in object:0 absent:1 invalid:1 array:1; do
  assert_eq "flow_state_readable answers ${pair#*:} for a ${pair%%:*} file, printing nothing" \
    "$(fs_run "flow_state_readable ${pair%%:*}.json")" "status ${pair#*:}"
done
printf '{"slug":"s","iteration":null,"budget":null,"host_fallbacks":false}' >"$fs_dir/read.json"
for pair in slug:s iteration:0 redo_count:0 budget: flake_rerun_used:false host_fallbacks:false; do
  assert_eq "flow_state_get reads ${pair%%:*} as '${pair#*:}'" \
    "$(fs_run "flow_state_get read.json ${pair%%:*}")" "${pair#*:}
status 0"
done
assert_eq "flow_state_get returns 1 for a key outside the table, printing nothing" \
  "$(fs_run 'flow_state_get read.json bogus')" "status 1"
assert_eq "flow_state_key_field returns 2 for an unknown column, printing nothing" \
  "$(fs_run 'flow_state_key_field slug bogus')" "status 2"
assert_eq "flow_state_key_field returns 1 for an unknown key, printing nothing" \
  "$(fs_run 'flow_state_key_field bogus default')" "status 1"
assert_eq "flow_state_key_field prints a key's column" \
  "$(fs_run 'flow_state_key_field iteration default')" "0
status 0"
assert_ne "flow_state_get on an unparseable file returns non-zero" \
  "$(fs_run 'flow_state_get invalid.json slug >/dev/null 2>&1' | tail -n 1)" "status 0"
printf '{"slug":"s"}' >"$fs_dir/write.json"
for pair in null:null true:boolean false:boolean 42:number abc:string 4a:string ':string'; do
  assert_eq "flow_state_write stores '${pair%%:*}' as a JSON ${pair#*:}" \
    "$(fs_run "flow_state_write write.json budget '${pair%%:*}' && jq -r '.budget | type' write.json")" \
    "${pair#*:}
status 0"
done
for v in null true 42 abc; do
  assert_eq "flow_state_write_string stores '$v' as a JSON string" \
    "$(fs_run "flow_state_write_string write.json budget '$v' && jq -c '.budget' write.json")" \
    "\"$v\"
status 0"
done
assert_eq "a write leaves the other keys as they were" "$(jq -r .slug "$fs_dir/write.json")" "s"
assert_contains "a write stamps updated with a UTC timestamp" \
  "$(fs_run 'flow_state_write write.json budget 1 && jq -r .updated write.json' | sed -n 1p)" "Z"
assert_eq "a write of updated itself sticks" \
  "$(fs_run 'flow_state_write write.json updated SENTINEL && flow_state_get write.json updated')" \
  "SENTINEL
status 0"
before_ls="$(ls -A "$fs_dir")"
assert_ne "a write to an unparseable file returns non-zero" \
  "$(fs_run 'flow_state_write invalid.json budget 1 2>/dev/null' | tail -n 1)" "status 0"
assert_eq "and leaves the file untouched" "$(cat "$fs_dir/invalid.json")" "not json"
assert_eq "with nothing new in its directory" "$(ls -A "$fs_dir")" "$before_ls"
assert_ne "a write to an absent file returns non-zero" \
  "$(fs_run 'flow_state_write absent.json budget 1 2>/dev/null' | tail -n 1)" "status 0"
assert_eq "and creates nothing" "$(ls -A "$fs_dir")" "$before_ls"
printf '{"phase":"done"}' >"$fs_dir/done.json"
printf '{"phase":"review"}' >"$fs_dir/review.json"
for pair in absent:1 done:1 review:0 invalid:0; do
  assert_eq "flow_state_active answers ${pair#*:} for a ${pair%%:*} file, printing nothing" \
    "$(fs_run "flow_state_active ${pair%%:*}.json")" "status ${pair#*:}"
done
restore_suite_env
