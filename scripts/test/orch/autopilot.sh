# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fake_claim_seed <issue> [host] [pid] [started]: seeds a claim on the issue,
# held by this host with pid 1 and a start long past unless given. A claim
# is a ref on origin; the fake keeps it as a line in the store.
fake_claim_seed() {
  mkdir -p "$ORCH_GH_FAKE_STORE/claims"
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "${2:-$(hostname)}" "${3:-1}" spec "${4:-2026-01-01T00:00:00Z}" \
    >"$ORCH_GH_FAKE_STORE/claims/$1"
}

# fake_claim_held <issue>: held or free, whether the store holds a claim on it.
fake_claim_held() { [ -f "$ORCH_GH_FAKE_STORE/claims/$1" ] && echo held || echo free; }

# --- autopilot ---------------------------------------------------------------
# The clone-scoped autopilot settings, the autopilot-session check and the
# host gate tick and watch share.
echo
echo "autopilot"
new_repo >/dev/null
fakebin="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' >"$fakebin/claude"; chmod +x "$fakebin/claude"

out="$("$ORCH" autopilot show 2>&1)"; st=$?
assert_status "autopilot show succeeds with nothing set" "$st" 0
assert_contains "the permission mode has no default" "$out" "orchestrator.autopilot.permission-mode (none) (unset)"
assert_contains "the cap defaults to 3" "$out" "orchestrator.autopilot.cap 3 (default)"
assert_contains "the handle defaults to the repo's owner" "$out" "orchestrator.autopilot.handle o (default)"
assert_contains "the rounds default to 2" "$out" "orchestrator.autopilot.rounds 2 (default)"
assert_contains "the budget defaults to 3" "$out" "orchestrator.autopilot.budget 3 (default)"

out="$(GH_REPO=acme/widgets "$ORCH" autopilot show 2>&1)"
assert_contains "the handle follows GH_REPO's owner" "$out" "orchestrator.autopilot.handle acme (default)"

git config orchestrator.autopilot.permission-mode acceptEdits
git config orchestrator.autopilot.cap 05
git config orchestrator.autopilot.handle octo
git config orchestrator.autopilot.rounds 4
git config orchestrator.autopilot.budget 7
out="$("$ORCH" autopilot show 2>&1)"
assert_contains "a set mode shows with its source" "$out" "orchestrator.autopilot.permission-mode acceptEdits (local)"
assert_contains "a set cap is a plain integer" "$out" "orchestrator.autopilot.cap 5 (local)"
assert_contains "a set handle wins over the owner" "$out" "orchestrator.autopilot.handle octo (local)"
assert_contains "a set rounds shows" "$out" "orchestrator.autopilot.rounds 4 (local)"
assert_contains "a set budget shows" "$out" "orchestrator.autopilot.budget 7 (local)"

for m in default acceptEdits plan dontAsk bypassPermissions; do
  git config orchestrator.autopilot.permission-mode "$m"
  "$ORCH" autopilot show >/dev/null 2>&1; st=$?
  assert_status "permission mode $m is accepted" "$st" 0
done
for kv in permission-mode=yolo permission-mode=Plan cap=0 cap=-1 cap=many rounds=0 rounds=1x budget=0 budget=two; do
  k="${kv%%=*}"; v="${kv#*=}"
  git config orchestrator.autopilot.permission-mode plan
  git config "orchestrator.autopilot.$k" "$v"
  out="$("$ORCH" autopilot show 2>&1)"; st=$?
  assert_status "autopilot show dies on $k=$v" "$st" 1
  assert_contains "naming the key" "$out" "orchestrator.autopilot.$k"
  assert_contains "and the value $v" "$out" "is $v"
  git config --unset-all "orchestrator.autopilot.$k"
done
git config --unset-all orchestrator.autopilot.permission-mode
git config --unset-all orchestrator.autopilot.cap
git config --unset-all orchestrator.autopilot.rounds
git config --unset-all orchestrator.autopilot.budget
git config --unset-all orchestrator.autopilot.handle

out="$("$ORCH" autopilot show extra 2>&1)"; st=$?
assert_status "autopilot show refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh autopilot show"
out="$("$ORCH" autopilot bogus 2>&1)"; st=$?
assert_status "autopilot bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown autopilot op"

ORCH_AUTOPILOT=1 "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 0 under ORCH_AUTOPILOT=1" "$st" 0
env -u ORCH_AUTOPILOT "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 1 without ORCH_AUTOPILOT" "$st" 1
ORCH_AUTOPILOT=0 "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 1 under ORCH_AUTOPILOT=0" "$st" 1

# The gate: host first, then the permission mode.
noclaude_path="$(
  claude_dir="$(PATH="$PATH" command -v claude 2>/dev/null || true)"; claude_dir="${claude_dir%/*}"
  new=""; IFS=:; for d in $PATH; do [ "$d" = "$claude_dir" ] || new="$new:$d"; done; printf '%s' "${new#:}")"
git config orchestrator.autopilot.permission-mode plan
out="$(PATH="$fakebin:$PATH" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate passes with claude on PATH, a mode set and no host signal" "$st" 0
out="$(PATH="$fakebin:$PATH" ORCHESTRATOR_HOST=junie sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses on Junie" "$st" 1
assert_contains "saying autopilot is Claude Code only" "$out" "autopilot is Claude Code only"
out="$(PATH="$noclaude_path" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses with no claude on PATH" "$st" 1
assert_contains "saying autopilot is Claude Code only" "$out" "autopilot is Claude Code only"
git config --unset-all orchestrator.autopilot.permission-mode
out="$(PATH="$fakebin:$PATH" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses with no permission mode set" "$st" 1
assert_contains "naming the key" "$out" "orchestrator.autopilot.permission-mode"

out="$("$ORCH" help 2>&1)"
assert_contains "autopilot show is in the usage text" "$out" "autopilot show"
assert_contains "autopilot active is in the usage text" "$out" "autopilot active"
assert_contains "the CLI conventions' noun table has an autopilot row" \
  "$(grep '^| `autopilot`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`active`'
assert_contains "host-capabilities has the headless-session row" \
  "$(grep '^| Start a headless session' "$PLUGIN_ROOT/docs/host-capabilities.md")" '`claude -p`'
restore_suite_env

# --- autopilot rounds, budget and start ---------------------------------------
# The plan comment's `## Autopilot` block, and the planning close's last step.
echo
echo "autopilot start"
fake_flow autopilot-start
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent
planf="$(mktemp -d)/01-plan.md"
complete_handoff "$planf"
printf '\n## Autopilot\n\nRounds: 4\nBudget: 5\n' >>"$planf"

out="$("$ORCH" autopilot rounds 2>&1)"; st=$?
assert_status "rounds with no plan comment dies" "$st" 1
assert_contains "naming the missing plan" "$out" "no 01-plan handoff"

fake_issue 8 open
out="$("$ORCH" autopilot start 8 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue without ready-for-agent" "$st" 1
assert_contains "naming the label" "$out" "ready-for-agent"
assert_eq "writing nothing" "$(fake_comments_of 8)$(fake_labels_of 8)" ""
fake_issue 9 open ready-for-agent orch:review
out="$("$ORCH" autopilot start 9 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue with a phase label" "$st" 1
assert_contains "naming the label" "$out" "orch:review"
assert_eq "writing nothing" "$(fake_comments_of 9)" ""
fake_issue 9 open ready-for-agent
bad_plan="$(mktemp -d)/01-plan.md"; complete_handoff "$bad_plan"
out="$("$ORCH" autopilot start 9 "$bad_plan" 2>&1)"; st=$?
assert_status "start refuses a plan with no Autopilot block" "$st" 1
assert_contains "naming it" "$out" "## Autopilot"
assert_eq "writing nothing" "$(fake_comments_of 9)$(fake_labels_of 9)" "ready-for-agent "

# a failure after the comment leaves the issue unlabelled and names the comment
fake_fail adapter_issue_relabel "HTTP 502"
out="$("$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
assert_status "a failed label add dies" "$st" 1
assert_contains "naming the comment posted" "$out" "posted the 01-plan comment on issue #7"
assert_eq "leaving the issue without a phase label" "$(fake_labels_of 7)" "ready-for-agent "
assert_eq "the comment is there" "$(fake_comments_of 7 | head -1)" "<!-- orch:handoff 01-plan -->"
fake_unfail

# a re-run on an unlabelled issue posts a newer plan comment, then labels last
sed -i 's/^Rounds: 4/Rounds: 6/' "$planf"
"$ORCH" autopilot start 7 "$planf" >/dev/null 2>&1; st=$?
assert_status "a re-run on an unlabelled issue succeeds" "$st" 0
assert_eq "posting a second plan comment" "$(ls "$ORCH_GH_FAKE_STORE/issues/7/comments" | wc -l | tr -d ' ')" "2"
assert_eq "and adding orch:spec" "$(fake_labels_of 7)" "orch:spec ready-for-agent "
out="$("$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
assert_status "a run on a labelled issue refuses" "$st" 1
assert_contains "naming the label" "$out" "orch:spec"

assert_eq "autopilot rounds prints the newest plan comment's Rounds" "$("$ORCH" autopilot rounds)" "6"
assert_eq "autopilot budget prints its Budget" "$("$ORCH" autopilot budget)" "5"
out="$("$ORCH" autopilot start 7 2>&1)"; st=$?
assert_contains "start's usage line" "$out" "usage: orch.sh autopilot start <issue> <plan-file>"
restore_suite_env

# --- autopilot claims ---------------------------------------------------------
# phase advance, spec pause --round, autopilot ask and answer, claim release (#1457).
echo
echo "autopilot claims"
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

# spec pause --round releases the claim
state_fixture phase spec
fake_issue 7 open ready-for-agent orch:spec orch:running
ORCH_AUTOPILOT=1 "$ORCH" spec pause --round 1/2 >/dev/null 2>&1; st=$?
assert_status "spec pause --round in autopilot succeeds" "$st" 0
assert_eq "dropping orch:running" "$(fake_labels_of 7)" "orch:spec ready-for-agent "
assert_eq "releasing the claim" "$(fake_claim_held 7)" free

# ask and answer
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
q="$(mktemp)"; printf '1. Keep it? Recommended: yes\n\nReply like `1: A`.\n' >"$q"
ORCH_AUTOPILOT=1 "$ORCH" autopilot ask spec "$q" >/dev/null 2>&1; st=$?
assert_status "autopilot ask succeeds" "$st" 0
assert_eq "the question is tagged and mentions the handle" "$(fake_comments_of 7 | head -2 | tr '\n' ' ')" "<!-- orch:question spec --> @o "
assert_contains "carrying the question" "$(fake_comments_of 7)" "1. Keep it?"
assert_eq "adding needs-human, dropping orch:running" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_eq "and releasing the claim" "$(fake_claim_held 7)" free
ans="$(mktemp)"
out="$("$ORCH" autopilot answer spec "$ans" 2>&1)"; st=$?
assert_status "answer with no reply exits 1" "$st" 1
assert_contains "saying so" "$out" "no reply"
fake_comment 7 o 2026-01-02T00:00:00Z "1: A"
fake_comment 7 o 2026-01-03T00:00:00Z "thanks"
"$ORCH" autopilot answer spec "$ans" >/dev/null 2>&1; st=$?
assert_status "answer with a reply succeeds" "$st" 0
assert_contains "writing the question" "$(cat "$ans")" "1. Keep it?"
assert_contains "and the reply" "$(cat "$ans")" "1: A"
assert_contains "and every later comment" "$(cat "$ans")" "thanks"
out="$("$ORCH" autopilot answer implement "$ans" 2>&1)"; st=$?
assert_status "answer for a phase never asked dies" "$st" 1
# a failed label add leaves the claim held and names the comment
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
fake_fail adapter_issue_relabel "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" autopilot ask spec "$q" 2>&1)"; st=$?
assert_status "a failed needs-human add dies" "$st" 1
assert_contains "naming the comment that landed" "$out" "posted the spec question comment"
assert_eq "the claim stays held" "$(fake_claim_held 7)" held
fake_unfail
restore_suite_env

# --- autopilot review ready ---------------------------------------------------
echo
echo "autopilot review ready"
review_flow autopilot-ready
state_fixture issue 7
state_fixture pr 9
fake_github
fake_pr 9 open
fake_issue 7 open ready-for-agent orch:review orch:running
fake_claim_seed 7
out="$(ORCH_AUTOPILOT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "review ready in autopilot succeeds" "$st" 0
assert_eq "moving the label to orch:done" "$(fake_labels_of 7)" "orch:done ready-for-agent "
assert_eq "releasing the claim" "$(fake_claim_held 7)" free
restore_suite_env

# --- autopilot doctor ---------------------------------------------------------
echo
echo "autopilot doctor"
fake_flow autopilot-doctor
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent orch:implement
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "doctor flags a label that disagrees with the recorded phase" "$out" "is labelled orch:implement, but this checkout last moved to phase spec"
fake_issue 7 open ready-for-agent orch:spec
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an agreeing label is ok" "$out" "phase label: orch:spec"
fake_issue 7 open ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_not_contains "an interactive flow's missing label is not mentioned" "$out" "phase label"
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow refuses an autopilot session with no phase label" "$st" 1
assert_contains "naming it" "$out" "carries no phase label"
fake_claim_seed 7 otherhost 5 2020-01-01T00:00:00Z
fake_claim_seed 8 otherhost 5 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fake_claim_seed 9 "$(hostname)" 5 2020-01-01T00:00:00Z
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "doctor lists another host's old claim" "$out" "issue #7 has been claimed by otherhost"
assert_not_contains "not a fresh one" "$out" "issue #8"
assert_not_contains "nor this host's own" "$out" "issue #9"
restore_suite_env
