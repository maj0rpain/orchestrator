# --- state ------------------------------------------------------------------
echo
echo "state"
new_repo >/dev/null
fake_github
"$ORCH" init state >/dev/null
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
legacy="$(mktemp)"
jq 'del(.budget, .loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for i in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
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
# doctor --flow check above would fail a state file lacking it.
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
