#!/usr/bin/env bash
#
# Tests for the three hook scripts.
#
# The failure modes worth catching: the grilling hook firing on skills that
# aren't planning, firing twice in one session, or staying silent when it should
# speak; the edit guard blocking the planning artifacts that
# improve-codebase-architecture and domain-modeling legitimately write; and the
# quick-implement hook touching a marker it should leave alone.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRILL="$DIR/hook-grilling.sh"
GUARD="$DIR/hook-guard.sh"
QUICK="$DIR/hook-quick-implement.sh"
COMMON="$DIR/hook-common.sh"
PASS=0
FAIL=0

ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

REPO="$(mktemp -d)"
git -C "$REPO" init -q
mkdir -p "$REPO/docs/agents" "$REPO/docs/adr"
echo "# tracker" >"$REPO/docs/agents/issue-tracker.md"

export TMPDIR="$(mktemp -d)"

skill_event() {
  jq -n --arg s "$1" --arg sid "$2" --arg cwd "$REPO" \
    '{hook_event_name:"PostToolUse", tool_name:"Skill", session_id:$sid, cwd:$cwd, tool_input:{skill:$s}}'
}
edit_event() {
  jq -n --arg f "$1" --arg sid "$2" --arg cwd "$REPO" \
    '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$f}}'
}

echo "hook tests"
echo
echo "hook-common"

source "$COMMON"

hook_read_skill_and_session < <(skill_event "mattpocock-skills:grilling" abc123)
assert_eq "extracts skill from tool_input.skill" "$skill" "mattpocock-skills:grilling"
assert_eq "extracts session_id" "$session" "abc123"

hook_read_skill_and_session < <(printf '{}')
assert_eq "defaults skill to empty string when absent" "$skill" ""
assert_eq "defaults session_id to empty when absent" "$session" ""

echo
echo "grilling hook"

out="$(skill_event "mattpocock-skills:grilling" s1 | "$GRILL")"
assert_contains "fires on Skill(grilling)" "$out" "additionalContext"
assert_contains "replaces the scripted closing line with a structured choice" "$out" "AskUserQuestion"
assert_not_contains "drops the old scripted closing line" "$out" "Plan approved? I'll write the handoff and start the flow."
assert_contains "offers starting the flow as an option" "$out" "Start the orchestrator flow"
assert_contains "offers quick implementation as an option" "$out" "Quick implementation"
assert_contains "tells the model to invoke the flow skill itself" "$out" "orchestrator:orch-flow"
assert_contains "tells the model to invoke the quick-implement skill itself" "$out" "orchestrator:orch-quick-implement"
assert_contains "forbids offering to implement" "$out" "Do NOT offer to implement"
assert_contains "carries the wayfinder caveat" "$out" "whole map is done"
assert_eq "emits valid JSON" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "PostToolUse"
assert_contains "carries Junie's top-level additionalContext" \
  "$(printf '%s' "$out" | jq -r '.additionalContext')" "Do NOT offer to implement"
assert_eq "top-level context matches Claude's" \
  "$(printf '%s' "$out" | jq -r '.additionalContext == .hookSpecificOutput.additionalContext')" "true"
assert_contains "names every planning artifact from the shared allowlist" \
  "$(printf '%s' "$out" | jq -r '.additionalContext')" \
  "CONTEXT.md, CONTEXT-MAP.md, docs/adr/, docs/agents/, .scratch/, .orchestrator/"

out="$(skill_event "mattpocock-skills:grilling" s1 | "$GRILL")"
assert_empty "stays silent on the second call in one session" "$out"

out="$(skill_event "mattpocock-skills:grilling" s2 | "$GRILL")"
assert_contains "fires again in a different session" "$out" "additionalContext"

# A payload with no session_id cannot key a marker, so it must not arm the
# guard under a defaulted id that every other session-less payload would share.
nosess="$(jq -n --arg cwd "$REPO" '{hook_event_name:"PostToolUse", tool_name:"Skill", cwd:$cwd, tool_input:{skill:"grilling"}}')"
out="$(printf '%s' "$nosess" | "$GRILL")"
assert_contains "still injects context without a session_id" "$out" "additionalContext"
if ls "$TMPDIR"/orchestrator-grilling-unknown "$TMPDIR"/orchestrator-grilling- >/dev/null 2>&1; then
  bad "arms no marker without a session_id" "a marker was created"
else
  ok "arms no marker without a session_id"
fi

assert_empty "ignores an unrelated skill" "$(skill_event "mattpocock-skills:tdd" s3 | "$GRILL")"
assert_empty "ignores research"           "$(skill_event "mattpocock-skills:research" s4 | "$GRILL")"

# The precondition warning has to land while planning is cheap to abandon.
mv "$REPO/docs/agents/issue-tracker.md" "$REPO/docs/agents/.hidden"
out="$(skill_event "grilling" s5 | "$GRILL")"
assert_contains "warns early when the tracker is unconfigured" "$out" "PRECONDITION NOT MET"
mv "$REPO/docs/agents/.hidden" "$REPO/docs/agents/issue-tracker.md"

mkdir -p "$REPO/.orchestrator"
echo '{"slug":"x","phase":"spec"}' >"$REPO/.orchestrator/state.json"
assert_empty "stays silent when a flow is already active" "$(skill_event "grilling" s6 | "$GRILL")"
rm -rf "$REPO/.orchestrator"

echo
echo "edit guard"

assert_empty "ignores sessions that were never planning" \
  "$(edit_event "$REPO/src/main.ts" never-planned | "$GUARD")"

# Regression check for the quick-implement change: hook-guard.sh itself is
# untouched by it, so it must still block on the marker exactly as before.
: >"$TMPDIR/orchestrator-grilling-s1"
out="$(edit_event "$REPO/src/main.ts" s1 | "$GUARD")"
assert_eq "denies a source edit during planning" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
assert_contains "explains what to do instead" "$out" "orchestrator:orch-flow"
assert_contains "names the blocked file" "$out" "src/main.ts"
# One JSON object serves both hosts: Junie reads the top-level decision/reason.
# "block" is Claude Code's legacy top-level value; Junie accepting it is unverified (#121).
assert_eq "carries Junie's top-level block decision" \
  "$(printf '%s' "$out" | jq -r '.decision')" "block"
assert_contains "carries Junie's top-level reason" \
  "$(printf '%s' "$out" | jq -r '.reason')" "src/main.ts"

for f in CONTEXT.md CONTEXT-MAP.md docs/adr/0001-x.md docs/agents/domain.md .scratch/ticket.md .orchestrator/handoff/01-plan.md; do
  assert_empty "allows planning artifact: $f" "$(edit_event "$REPO/$f" s1 | "$GUARD")"
done

# Junie's PreToolUse payload carries neither session_id nor cwd. No session
# means "not guarded", even if a stale marker for a defaulted id exists.
: >"$TMPDIR/orchestrator-grilling-unknown"
: >"$TMPDIR/orchestrator-grilling-"
junie_edit='{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"'"$REPO"'/src/main.ts"}}'
out="$(cd "$REPO" && printf '%s' "$junie_edit" | "$GUARD")"; rc=$?
assert_eq "exits cleanly on a payload with no session_id or cwd" "$rc" "0"
assert_empty "does not deny without a session_id" "$out"
rm -f "$TMPDIR/orchestrator-grilling-unknown" "$TMPDIR/orchestrator-grilling-"

# Junie's Edit/Write input may name the file under `path` rather than
# `file_path`, and may give it relative to the working directory.
path_edit="$(jq -n --arg f "$REPO/src/main.ts" --arg cwd "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Write", session_id:"s1", cwd:$cwd, tool_input:{path:$f}}')"
assert_eq "denies a source edit named under tool_input.path" \
  "$(printf '%s' "$path_edit" | "$GUARD" | jq -r '.decision')" "block"
rel_edit="$(jq -n --arg cwd "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", cwd:$cwd, tool_input:{path:"src/main.ts"}}')"
assert_eq "denies a source edit given as a relative path" \
  "$(printf '%s' "$rel_edit" | "$GUARD" | jq -r '.decision')" "block"
rel_ok="$(jq -n --arg cwd "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", cwd:$cwd, tool_input:{path:"docs/adr/0002-y.md"}}')"
assert_empty "allows a planning artifact given as a relative path" \
  "$(printf '%s' "$rel_ok" | "$GUARD")"
# A ".." climbing out of an allowlisted directory lands in source, and must
# be judged by where it lands, not by the prefix it starts with.
dotdot="$(jq -n --arg cwd "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", cwd:$cwd, tool_input:{path:"docs/adr/../../src/main.ts"}}')"
assert_eq "denies a source edit reached through .. from an allowlisted dir" \
  "$(printf '%s' "$dotdot" | "$GUARD" | jq -r '.decision')" "block"
dotdot_abs="$(edit_event "$REPO/.scratch/../src/main.ts" s1 | "$GUARD" | jq -r '.decision')"
assert_eq "denies an absolute source path reached through .." "$dotdot_abs" "block"
outside="$(jq -n --arg cwd "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", cwd:$cwd, tool_input:{path:"../sibling/x.ts"}}')"
assert_empty "ignores a relative path that climbs out of the repo" \
  "$(printf '%s' "$outside" | "$GUARD")"
no_cwd="$(jq -n --arg f "$REPO/src/main.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", tool_input:{file_path:$f}}')"
assert_eq "falls back to the process working directory without cwd" \
  "$(cd "$REPO" && printf '%s' "$no_cwd" | "$GUARD" | jq -r '.decision')" "block"

assert_contains "lists every allowlisted planning artifact" \
  "$(edit_event "$REPO/src/main.ts" s1 | "$GUARD" | jq -r '.reason')" \
  "CONTEXT.md, CONTEXT-MAP.md, docs/adr/, docs/agents/, .scratch/, .orchestrator/"
assert_not_contains "does not allow a lookalike of an allowlisted file" \
  "$(edit_event "$REPO/docs/CONTEXT.md" s1 | "$GUARD" | jq -r '.decision')" "null"

assert_empty "ignores files outside the repo" "$(edit_event "/etc/hosts" s1 | "$GUARD")"

mkdir -p "$REPO/.orchestrator"
echo '{"slug":"x","phase":"implement"}' >"$REPO/.orchestrator/state.json"
assert_empty "stops guarding once a flow is running" \
  "$(edit_event "$REPO/src/main.ts" s1 | "$GUARD")"
rm -rf "$REPO/.orchestrator"

echo
echo "hook-quick-implement"

: >"$TMPDIR/orchestrator-grilling-s1"
out="$(skill_event "orchestrator:orch-quick-implement" s1 | "$QUICK")"
assert_empty "prints nothing" "$out"
if [ -e "$TMPDIR/orchestrator-grilling-s1" ]; then
  bad "deletes the session's marker" "marker still present"
else
  ok "deletes the session's marker"
fi

: >"$TMPDIR/orchestrator-grilling-s2"
skill_event "mattpocock-skills:tdd" s2 | "$QUICK" >/dev/null
if [ -e "$TMPDIR/orchestrator-grilling-s2" ]; then
  ok "leaves another skill's marker alone"
else
  bad "leaves another skill's marker alone" "marker was deleted"
fi

skill_event "orchestrator:orch-quick-implement" s3 | "$QUICK" >/dev/null
ok "does not fail when no marker exists for the session"

# ADR-0014 renamed the skill; the old unprefixed name must not lift the guard.
: >"$TMPDIR/orchestrator-grilling-s4"
skill_event "orchestrator:quick-implement" s4 | "$QUICK" >/dev/null
if [ -e "$TMPDIR/orchestrator-grilling-s4" ]; then
  ok "ignores the old unprefixed quick-implement name"
else
  bad "ignores the old unprefixed quick-implement name" "marker was deleted"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
