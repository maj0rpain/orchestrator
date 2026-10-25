# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- phase advance / phase boundary ------------------------------------------
# A phase is left only once the handoff it writes for the next one is valid
# (#279): advance is the one place that rule is enforced, so a model that skips
# the prose cannot skip it.
echo
echo "phase advance"
fake_flow advancing
export ORCHESTRATOR_HOST=claude

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no spec handoff" "$st" 1
assert_contains "names the missing handoff" "$out" "02-spec.md"
assert_contains "prints a FAIL line for it" "$out" "FAIL  handoff not found:"
assert_contains "dies with only the remedy" "$out" "02-spec.md before leaving the spec phase"
assert_not_contains "without repeating that it was not found" "$(printf '%s\n' "$out" | grep '^orch:')" "handoff not found"
assert_eq "leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

"$ORCH" state set issue 7
hs2="$("$ORCH" handoff path implement)"
writeln '## Spec issue' '#7.' '' '## Ticket breakdown' '' '' \
        '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with an invalid spec handoff" "$st" 1
assert_contains "prints the FAIL lines" "$out" "FAIL  empty section: ## Ticket breakdown"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

writeln '## Ticket breakdown' '#7.' '' '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no Spec issue in the handoff" "$st" 1
assert_contains "naming the missing Spec issue" "$out" "Spec issue"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

writeln '## Spec issue' '' '' '## Ticket breakdown' '#7.' '' \
        '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with an empty Spec issue" "$st" 1
assert_contains "naming the empty Spec issue" "$out" "FAIL  empty section: ## Spec issue"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

writeln '## Spec issue' '#7.' '' '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no Ticket breakdown in the handoff" "$st" 1
assert_contains "naming the missing Ticket breakdown" "$out" "missing section: ## Ticket breakdown"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

# A spec handoff written before #1601 still carries Seams and a Spec review
# changelog; neither is required any more, so it advances, filled or empty.
writeln '## Spec issue' '#7.' '' '## Seams' '' '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' '#7.' '' '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances a spec handoff still carrying the old sections" "$st" 0
assert_eq "recording the implement phase" "$("$ORCH" state get phase)" "implement"
state_fixture phase spec

writeln '## Spec issue' '#7.' '' '## Seams' 'At handoff validate.' '' '## Spec review changelog' '' \
        '## Ticket breakdown' '#7.' '' '## Host fallbacks' 'None.' >"$hs2"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances with a filled Seams and an empty Spec review changelog" "$st" 0
assert_eq "recording the implement phase" "$("$ORCH" state get phase)" "implement"
state_fixture phase spec

complete_handoff "$hs2"
"$ORCH" state set issue null
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at spec with no issue recorded" "$st" 1
assert_contains "naming the missing issue" "$out" "no issue recorded"
assert_eq "and leaves the phase at spec" "$("$ORCH" state get phase)" "spec"

"$ORCH" state set issue 7
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances spec to implement with a valid handoff and an issue" "$st" 0
assert_eq "records the implement phase" "$("$ORCH" state get phase)" "implement"
assert_contains "prints the boundary naming the spec handoff" "$out" \
  "Phase spec complete. Handoff written to $hs2."
assert_contains "with the Claude Code Next line" "$out" "Next: /clear, then /orchestrator:next"

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at implement with no implement handoff" "$st" 1
assert_contains "names the missing handoff" "$out" "03-implement.md"
assert_eq "leaves the phase at implement" "$("$ORCH" state get phase)" "implement"

hi2="$("$ORCH" handoff path review)"
complete_handoff "$hi2"
for field in branch base_sha pr; do
  state_fixture branch orch/7-advancing
  state_fixture base_sha abc1234
  state_fixture pr 3
  state_fixture "$field" null
  out="$("$ORCH" phase advance 2>&1)"; st=$?
  assert_status "refuses at implement with no $field recorded" "$st" 1
  case "$field" in
    branch)   want="no branch recorded" ;;
    base_sha) want="no base SHA recorded" ;;
    pr)       want="no PR recorded" ;;
  esac
  assert_contains "naming the missing $field" "$out" "$want"
  assert_eq "and leaves the phase at implement (no $field)" "$("$ORCH" state get phase)" "implement"
done

state_fixture pr 3
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "advances implement to review with a valid handoff and the fields" "$st" 0
assert_eq "records the review phase" "$("$ORCH" state get phase)" "review"
assert_contains "prints the boundary naming the implement handoff" "$out" \
  "Phase implement complete. Handoff written to $hi2."

out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at review" "$st" 1
assert_contains "pointing at review ready" "$out" "review ready"
assert_eq "and leaves the phase at review" "$("$ORCH" state get phase)" "review"

state_fixture phase "done"
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at done" "$st" 1
assert_contains "saying the flow is done" "$out" \
  "orch: the flow is done - there is no phase to advance to"
assert_eq "and leaves the phase at done" "$("$ORCH" state get phase)" "done"

state_fixture phase bogus
out="$("$ORCH" phase advance 2>&1)"; st=$?
assert_status "refuses at a phase outside the table" "$st" 1
assert_contains "naming the phase and doctor --flow" "$out" \
  "orch: not a flow phase: 'bogus' - run orch.sh doctor --flow"
assert_eq "and leaves the phase as it was" "$("$ORCH" state get phase)" "bogus"
state_fixture phase "done"

out="$("$ORCH" phase advance extra 2>&1)"; st=$?
assert_status "advance takes no arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh phase advance"

echo
echo "phase boundary"
state_fixture phase spec
out="$("$ORCH" phase boundary 2>&1)"; st=$?
assert_status "prints at flow start" "$st" 0
assert_eq "names the plan handoff and the Claude Code Next line" "$out" \
  "$(printf 'Phase plan complete. Handoff written to %s.\n\n  Next: /clear, then /orchestrator:next' "$("$ORCH" handoff path spec)")"
state_fixture phase review
out="$(ORCHESTRATOR_HOST=junie "$ORCH" phase boundary 2>&1)"
assert_eq "on Junie names the Junie Next line" "$out" \
  "$(printf 'Phase implement complete. Handoff written to %s.\n\n  Next: /new, then ask for the next phase with /orch-flow' "$hi2")"
out="$(ORCHESTRATOR_HOST=other "$ORCH" phase boundary 2>&1)"
assert_eq "on an unknown host names the fresh-session Next line" "$out" \
  "$(printf 'Phase implement complete. Handoff written to %s.\n\n  Next: a fresh session, then /orchestrator:next (or orch-flow'"'"'s Next phase section)' "$hi2")"
state_fixture phase "done"
out="$("$ORCH" phase boundary 2>&1)"; st=$?
assert_status "refuses once the flow is done" "$st" 1
assert_contains "saying there is no boundary at done" "$out" \
  "orch: no phase boundary at phase: done - the flow is not between phases"
state_fixture phase bogus
out="$("$ORCH" phase boundary 2>&1)"; st=$?
assert_status "refuses at a phase outside the table" "$st" 1
assert_contains "saying there is no boundary at that phase" "$out" \
  "orch: no phase boundary at phase: bogus - the flow is not between phases"
out="$("$ORCH" phase bogus 2>&1)"; st=$?
assert_status "an unknown phase op is an error" "$st" 1
assert_contains "naming the ops it wants" "$out" "advance|boundary"
unset ORCHESTRATOR_HOST
restore_suite_env

# --- phase advance help names handoffs by role (#1066) ----------------------
# The help names each handoff by its role and points at handoff path for the
# file, so renaming a handoff file never leaves the help stale.
echo
echo "phase advance help names handoffs by role"
new_repo >/dev/null
assert_help_names_handoffs_by_role "phase advance"
restore_suite_env

# --- phase advance in an autopilot flow (#1457) -------------------------------
# The handoff is the posted comment, the phase label moves before the recorded
# phase, and the claim is released last.
echo
echo "phase advance in an autopilot flow"
fake_flow autopilot-claims
export ORCHESTRATOR_HOST=claude
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
spec_h="$(mktemp -d)/02-spec.md"
complete_handoff "$spec_h"

out="$(ORCH_AUTOPILOT=1 "$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance with no posted handoff dies" "$st" 1
assert_contains "naming the missing comment" "$out" "no 02-spec handoff comment"
assert_contains "and the hint" "$out" "post it with handoff post before leaving the spec phase"
fake_fail adapter_issue_json "HTTP 504 read"
out="$(ORCH_AUTOPILOT=1 "$ORCH" phase advance 2>&1)"; st=$?
fake_unfail
assert_status "a failed comments read dies" "$st" 1
assert_contains "showing the gh reason" "$out" "HTTP 504 read"
assert_eq "leaving the label" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_eq "and the claim held" "$(fake_claim_held 7)" held

ORCH_AUTOPILOT=1 "$ORCH" handoff post 02-spec "$spec_h" >/dev/null 2>&1
out="$(ORCH_AUTOPILOT=1 "$ORCH" phase advance 2>&1)"; st=$?
assert_status "phase advance in autopilot succeeds on the posted handoff" "$st" 0
assert_eq "moving the phase label" "$(fake_labels_of 7)" "orch:implement ready-for-agent "
assert_eq "releasing the claim" "$(fake_claim_held 7)" free
assert_eq "recording the phase" "$("$ORCH" state get phase)" "implement"
assert_contains "naming the watcher" "$out" "the watcher starts the implement phase"

# a failure partway leaves the claim held and names the writes that landed
fake_issue 7 open ready-for-agent orch:spec orch:running
ORCH_AUTOPILOT=1 "$ORCH" handoff post 02-spec "$spec_h" >/dev/null 2>&1
state_fixture phase spec
fake_claim_seed 7
fake_fail adapter_claim_delete "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" phase advance 2>&1)"; st=$?
assert_status "a failed claim delete dies" "$st" 1
assert_contains "naming the claim ref" "$out" "delete the claim ref"
assert_contains "and the writes that landed" "$out" "moved the phase label to orch:implement, recorded phase implement, removed orch:running"
assert_eq "the claim is still held" "$(fake_claim_held 7)" held
fake_unfail
fake_issue 7 open ready-for-agent orch:spec orch:running
ORCH_AUTOPILOT=1 "$ORCH" handoff post 02-spec "$spec_h" >/dev/null 2>&1
state_fixture phase spec
fake_fail adapter_issue_relabel "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" phase advance 2>&1)"; st=$?
assert_status "a failed label move dies" "$st" 1
assert_eq "recording no phase" "$("$ORCH" state get phase)" "spec"
assert_eq "the claim is still held" "$(fake_claim_held 7)" held
fake_unfail

# an interactive flow touches no label
fake_issue 7 open ready-for-agent
env -u ORCH_AUTOPILOT "$ORCH" phase advance >/dev/null 2>&1
assert_eq "an interactive phase advance touches no label" "$(fake_labels_of 7)" "ready-for-agent "
assert_eq "and no claim" "$(fake_claim_held 7)" held
restore_suite_env
