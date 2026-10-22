# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

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
