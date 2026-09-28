#!/usr/bin/env bash
#
# Tests for the three hook scripts.
#
# The failure modes worth catching: the grilling hook firing on skills that
# aren't planning, firing twice in one session, or staying silent when it should
# speak; the edit guard blocking the planning artifacts planning legitimately
# writes, or letting a planning record (glossary, ADR) through; and the
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
# The closing question offers exactly two options, never a third (#237):
# count its numbered option lines, not only that each option is present.
count_closing_options() { printf '%s' "$1" | jq -r '.additionalContext' | grep -cE '^ +[0-9]+\. '; }
assert_eq "offers exactly two options" "$(count_closing_options "$out")" "2"
assert_contains "says exactly two options" "$out" "exactly two options"
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
  "docs/agents/, .scratch/, .orchestrator/"

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
# A done flow is finished work, not a running one (ADR-0009): planning in its
# checkout gets the full message, records rule included (#186).
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
out="$(skill_event "grilling" s7 | "$GRILL")"
assert_contains "still injects its context when the flow is done" "$out" "Do NOT offer to implement"
assert_contains "tells planning to write record wording into the plan" \
  "$(printf '%s' "$out" | jq -r '.additionalContext')" \
  "- Glossary and ADR changes (CONTEXT.md, CONTEXT-MAP.md, docs/adr/) are records: never edit them. Write the exact wording you intend into the plan, so the spec carries it verbatim."
rm -rf "$REPO/.orchestrator"

echo
echo "grilling hook on Junie (UserPromptSubmit, #202)"

# Junie has no PostToolUse event, so the same hook runs on UserPromptSubmit and
# matches a grilling entry point in the raw prompt. Junie's payload carries
# the repo in project_path; its cwd is ~/.junie, not the project.
JUNIE_HOME="$(mktemp -d)"
prompt_event() {
  jq -n --arg p "$1" --arg sid "$2" --arg cwd "$JUNIE_HOME" --arg pp "$REPO" \
    '{hook_event_name:"UserPromptSubmit", session_id:$sid, cwd:$cwd, project_path:$pp, prompt:$p}'
}
claude_prompt_event() {
  jq -n --arg p "$1" --arg sid "$2" --arg cwd "$REPO" \
    '{hook_event_name:"UserPromptSubmit", session_id:$sid, cwd:$cwd, prompt:$p}'
}

out="$(prompt_event '$grill-with-docs probe test' j1 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_eq "fires on a \$grill-with-docs prompt, as UserPromptSubmit" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
assert_contains "asks the closing question with Junie's ask_user tool" "$ctx" "Call the ask_user tool"
assert_not_contains "names no Claude question tool on Junie" "$ctx" "AskUserQuestion"
assert_contains "offers starting the flow on Junie" "$ctx" "Start the orchestrator flow"
assert_contains "offers quick implementation on Junie" "$ctx" "Quick implementation"
assert_eq "offers exactly two options on Junie" "$(count_closing_options "$out")" "2"
assert_contains "forbids offering to implement on Junie" "$ctx" "Do NOT offer to implement"
assert_contains "carries the wayfinder caveat on Junie" "$ctx" "whole map is done"
assert_contains "names every planning artifact on Junie" "$ctx" \
  "docs/agents/, .scratch/, .orchestrator/"
assert_contains "points at orch-flow's SKILL.md in this install" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-flow/SKILL.md"
assert_contains "points at orch-quick-implement's SKILL.md in this install" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md"
assert_contains "says Junie has no Skill tool" "$ctx" "no Skill tool"
assert_not_contains "names no Claude tool as the step on Junie" "$ctx" "call the Skill tool"
assert_not_contains "names no Claude-scoped skill on Junie" "$ctx" "orchestrator:orch-"
assert_not_contains "names no Claude-scoped mattpocock skill on Junie" "$ctx" "mattpocock-skills:"

assert_empty "stays silent on the second grilling prompt in one Junie session" \
  "$(prompt_event '$grilling again' j1 | "$GRILL")"

n=0
for p in '/grilling' '$grill-me x' 'please $wayfinder now' '/improve-codebase-architecture' '/mattpocock-skills:grilling'; do
  n=$((n + 1))
  assert_contains "fires on the entry point in: $p" \
    "$(prompt_event "$p" "jy$n" | "$GRILL")" "additionalContext"
done
for p in 'let us talk about grilling' '$tdd fix it' '$grilling-notes' 'a/grilling b'; do
  n=$((n + 1))
  assert_empty "ignores a prompt with no grilling entry point: $p" \
    "$(prompt_event "$p" "jn$n" | "$GRILL")"
done

# Junie's router sends grilling to its plan agent, which ends on its own
# plan screen and ignores the closing question. Confirming that screen
# submits this fixed prompt to the main agent, so the question is asked there
# instead (#202).
confirm='Implement the suggested plan'
prompt_event '$grill-with-docs x' jc1 | "$GRILL" >/dev/null
out="$(prompt_event "$confirm" jc1 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_eq "fires on plan confirmation, as UserPromptSubmit" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
assert_contains "asks before implementing the confirmed plan" "$ctx" "Before you implement"
assert_contains "asks the closing question at plan confirmation" "$ctx" "Call the ask_user tool"
assert_contains "offers starting the flow at plan confirmation" "$ctx" "Start the orchestrator flow"
assert_contains "offers quick implementation at plan confirmation" "$ctx" "Quick implementation"
assert_eq "offers exactly two options at plan confirmation" "$(count_closing_options "$out")" "2"
assert_contains "points at orch-flow's SKILL.md at plan confirmation" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-flow/SKILL.md"
assert_not_contains "repeats no planning rules at plan confirmation" "$ctx" "Do NOT offer to implement"
assert_contains "asks again on a second plan confirmation" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")" "Before you implement"
assert_empty "stays silent on plan confirmation in a session that never grilled" \
  "$(prompt_event "$confirm" jc2 | "$GRILL")"
assert_empty "stays silent on a prompt that only mentions the confirmation" \
  "$(prompt_event "$confirm now" jc1 | "$GRILL")"

mv "$REPO/docs/agents/issue-tracker.md" "$REPO/docs/agents/.hidden"
assert_contains "reads the repo from project_path for the tracker warning" \
  "$(prompt_event '$grilling' j2 | "$GRILL")" "PRECONDITION NOT MET"
mv "$REPO/docs/agents/.hidden" "$REPO/docs/agents/issue-tracker.md"

mkdir -p "$REPO/.orchestrator"
echo '{"slug":"x","phase":"spec"}' >"$REPO/.orchestrator/state.json"
assert_empty "stays silent on Junie when a flow is already active" \
  "$(prompt_event '$grilling' j3 | "$GRILL")"
assert_empty "stays silent on plan confirmation when a flow is already active" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")"
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
assert_contains "still fires on Junie's \$grilling when the flow is done" \
  "$(prompt_event '$grilling' j4 | "$GRILL")" "Do NOT offer to implement"
assert_contains "still asks at plan confirmation when the flow is done" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")" "Before you implement"
rm -rf "$REPO/.orchestrator"

# Claude Code also fires UserPromptSubmit, but its PostToolUse on Skill already
# delivers the message; its payload has no project_path.
assert_empty "exits silently on Claude Code's UserPromptSubmit" \
  "$(claude_prompt_event '/grilling' c1 | "$GRILL")"
assert_empty "exits silently on plan confirmation on Claude Code" \
  "$(claude_prompt_event "$confirm" c1 | "$GRILL")"
if [ -e "$TMPDIR/orchestrator-grilling-c1" ]; then
  bad "arms no marker from Claude Code's UserPromptSubmit" "a marker was created"
else
  ok "arms no marker from Claude Code's UserPromptSubmit"
fi
rm -rf "$JUNIE_HOME"
assert_contains "hooks.json runs the grilling hook on UserPromptSubmit" \
  "$(jq -r '.hooks.UserPromptSubmit[]?.hooks[]?.command' "$DIR/../hooks/hooks.json")" "hook-grilling.sh"

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

for f in docs/agents/domain.md docs/agents/x.md .scratch/ticket.md .scratch/x.md .orchestrator/handoff/01-plan.md .orchestrator/x; do
  assert_empty "allows planning artifact: $f" "$(edit_event "$REPO/$f" s1 | "$GUARD")"
done

# The glossary and ADRs are planning records: planning never changes them in
# place, and the denial redirects the wording into the plan instead (#186).
for f in CONTEXT.md CONTEXT-MAP.md docs/adr/0001-x.md docs/adr/../adr/x.md; do
  out="$(edit_event "$REPO/$f" s1 | "$GUARD")"
  assert_eq "denies planning record: $f" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
  assert_contains "gives the records reason for $f" "$(printf '%s' "$out" | jq -r '.reason')" \
    "is a record of decisions, and planning does not change records in place. Write the exact wording you intended - the new or replaced text, and where it goes - into the plan, so the spec carries it verbatim as an Implementation Decision and it lands with the change it describes. For a quick implementation, put it in the linked issue's body."
done
records_reason="$(edit_event "$REPO/CONTEXT.md" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "records reason names the blocked record" "$records_reason" "'CONTEXT.md' is a record"
assert_not_contains "records denial does not point at the flow" "$records_reason" "orchestrator:orch-flow"
assert_not_contains "records denial does not list planning artifacts" "$records_reason" "Planning artifacts you may still edit"
source_reason="$(edit_event "$REPO/src/x.ts" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "source denial keeps today's reason" "$source_reason" \
  "this is a planning session and no flow has
started, so 'src/x.ts' should not be edited yet."
assert_contains "source denial still lists planning artifacts" "$source_reason" "Planning artifacts you may still edit"
# Host detection is not reliable on Junie's PreToolUse, so the source denial
# names both quick-implementation lifts on every host - ADR-0023.
assert_contains "source denial names the quick-implement Skill lift" "$source_reason" \
  'call the Skill tool with "orchestrator:orch-quick-implement"'
assert_contains "source denial names the Read lift of the installed SKILL.md" "$source_reason" \
  "read $(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md with the Read tool"

# Junie's PreToolUse payload carries no cwd, and its bundled docs show no
# session_id either, though build 3419.7 sends one (ADR-0023). No session
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
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"s1", cwd:$cwd, tool_input:{path:".scratch/y.md"}}')"
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
  "docs/agents/, .scratch/, .orchestrator/"
assert_not_contains "does not allow a lookalike of an allowlisted file" \
  "$(edit_event "$REPO/docs/CONTEXT.md" s1 | "$GUARD" | jq -r '.decision')" "null"

assert_empty "ignores files outside the repo" "$(edit_event "/etc/hosts" s1 | "$GUARD")"

mkdir -p "$REPO/.orchestrator"
echo '{"slug":"x","phase":"implement"}' >"$REPO/.orchestrator/state.json"
assert_empty "stops guarding once a flow is running" \
  "$(edit_event "$REPO/src/main.ts" s1 | "$GUARD")"
echo '{"slug":"x"}' >"$REPO/.orchestrator/state.json"
assert_empty "stands down for a state.json with no phase" \
  "$(edit_event "$REPO/src/main.ts" s1 | "$GUARD")"
echo 'not json' >"$REPO/.orchestrator/state.json"
assert_empty "stands down for an unreadable state.json" \
  "$(edit_event "$REPO/src/main.ts" s1 | "$GUARD")"
# A done flow is no flow: its lingering state.json must not switch the guard
# off for the next planning session (#186, extending ADR-0009 to the hooks).
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
out="$(edit_event "$REPO/CONTEXT.md" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "denies a record with the records reason when the flow is done" "$out" \
  "'CONTEXT.md' is a record of decisions"
out="$(edit_event "$REPO/src/main.ts" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "denies source with the source reason when the flow is done" "$out" \
  "so 'src/main.ts' should not be edited yet"

# End to end, no hand-seeded marker: grilling arms the guard in a checkout
# whose flow is done, and the guard then denies a glossary edit.
rm -f "$TMPDIR/orchestrator-grilling-e2e"
skill_event "mattpocock-skills:grilling" e2e | "$GRILL" >/dev/null
if [ -e "$TMPDIR/orchestrator-grilling-e2e" ]; then
  ok "grilling arms the marker when the flow is done"
else
  bad "grilling arms the marker when the flow is done" "no marker"
fi
out="$(edit_event "$REPO/CONTEXT.md" e2e | "$GUARD" | jq -r '.reason')"
assert_contains "the armed guard denies CONTEXT.md with the records reason" "$out" \
  "'CONTEXT.md' is a record of decisions, and planning does not change records in place."
rm -rf "$REPO/.orchestrator"

echo
echo "hook-quick-implement"

assert_marker_gone() {
  if [ -e "$TMPDIR/orchestrator-grilling-$2" ]; then bad "$1" "marker still present"; else ok "$1"; fi
}
assert_marker_kept() {
  if [ -e "$TMPDIR/orchestrator-grilling-$2" ]; then ok "$1"; else bad "$1" "marker was deleted"; fi
}

: >"$TMPDIR/orchestrator-grilling-s1"
out="$(skill_event "orchestrator:orch-quick-implement" s1 | "$QUICK")"
assert_empty "prints nothing" "$out"
assert_marker_gone "deletes the session's marker" s1

: >"$TMPDIR/orchestrator-grilling-s2"
skill_event "mattpocock-skills:tdd" s2 | "$QUICK" >/dev/null
assert_marker_kept "leaves another skill's marker alone" s2

skill_event "orchestrator:orch-quick-implement" s3 | "$QUICK" >/dev/null
ok "does not fail when no marker exists for the session"

# ADR-0014 renamed the skill; the old unprefixed name must not lift the guard.
: >"$TMPDIR/orchestrator-grilling-s4"
skill_event "orchestrator:quick-implement" s4 | "$QUICK" >/dev/null
assert_marker_kept "ignores the old unprefixed quick-implement name" s4

# On a host with no Skill tool (Junie), the model runs orch-quick-implement by
# reading its SKILL.md, so a PreToolUse Read of the installed copy lifts the
# guard too - ADR-0023. Junie's PreToolUse may or may not carry project_path.
PLUGIN_ROOT="$(cd "$DIR/.." && pwd)"
QUICK_SKILL="$PLUGIN_ROOT/skills/orch-quick-implement/SKILL.md"
read_event() {
  jq -n --arg f "$1" --arg sid "$2" --arg k "${3:-file_path}" \
    '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:$sid, tool_input:{($k):$f}}'
}

: >"$TMPDIR/orchestrator-grilling-r1"
out="$(read_event "$QUICK_SKILL" r1 | "$QUICK")"
assert_empty "prints nothing on a Read" "$out"
assert_marker_gone "a Read of the installed SKILL.md via file_path deletes the marker" r1

: >"$TMPDIR/orchestrator-grilling-r2"
read_event "$QUICK_SKILL" r2 path | "$QUICK" >/dev/null
assert_marker_gone "a Read of the installed SKILL.md via path deletes the marker" r2

# With project_path present, a relative path resolves against it, and ".."
# segments are judged by where they land.
: >"$TMPDIR/orchestrator-grilling-r3"
jq -n --arg p "$PLUGIN_ROOT/skills" \
  '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:"r3", project_path:$p,
    tool_input:{path:"x/../orch-quick-implement/SKILL.md"}}' | "$QUICK" >/dev/null
assert_marker_gone "a relative Read resolved against the working directory deletes the marker" r3

: >"$TMPDIR/orchestrator-grilling-r7"
jq -n --arg f "$QUICK_SKILL" --arg p "$REPO" \
  '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:"r7", project_path:$p,
    tool_input:{file_path:$f}}' | "$QUICK" >/dev/null
assert_marker_gone "an absolute Read with project_path present deletes the marker" r7

# The same file reached through a symlinked plugin root is the same file: a
# host that hands over, or resolves to, the other spelling still lifts it.
ln -s "$PLUGIN_ROOT" "$TMPDIR/linked-root"
: >"$TMPDIR/orchestrator-grilling-r8"
read_event "$TMPDIR/linked-root/skills/orch-quick-implement/SKILL.md" r8 | "$QUICK" >/dev/null
assert_marker_gone "a Read of the installed SKILL.md through a symlink deletes the marker" r8
rm -f "$TMPDIR/linked-root"

: >"$TMPDIR/orchestrator-grilling-r4"
read_event "$PLUGIN_ROOT/skills/orch-flow/SKILL.md" r4 | "$QUICK" >/dev/null
assert_marker_kept "a Read of another skill's SKILL.md leaves the marker" r4

# A repo checkout of this plugin carries its own copy; reading that while
# working on the plugin must not lift the guard.
mkdir -p "$REPO/skills/orch-quick-implement"
: >"$REPO/skills/orch-quick-implement/SKILL.md"
: >"$TMPDIR/orchestrator-grilling-r5"
read_event "$REPO/skills/orch-quick-implement/SKILL.md" r5 | "$QUICK" >/dev/null
assert_marker_kept "a Read of a repo checkout's quick-implement SKILL.md leaves the marker" r5
rm -rf "$REPO/skills"

: >"$TMPDIR/orchestrator-grilling-"
out="$(jq -n --arg f "$QUICK_SKILL" '{hook_event_name:"PreToolUse", tool_name:"Read", tool_input:{file_path:$f}}' | "$QUICK")"; rc=$?
assert_eq "exits cleanly on a Read with no session_id" "$rc" "0"
assert_marker_kept "a Read with no session_id touches no marker" ""
rm -f "$TMPDIR/orchestrator-grilling-"

: >"$TMPDIR/orchestrator-grilling-r6"
read_event "" r6 | "$QUICK" >/dev/null
assert_marker_kept "a Read naming no path leaves the marker" r6

assert_contains "hooks.json runs the quick-implement hook on PreToolUse Read" \
  "$(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Read") | .hooks[]?.command' "$DIR/../hooks/hooks.json")" "hook-quick-implement.sh"

echo
echo "execute bit (docs/host-capabilities.md, \"Execute bit\")"

ROOT="$(cd "$DIR/.." && pwd)"
EXEC_BIT_DOC="see docs/host-capabilities.md, \"Execute bit\""

bare_hooks="$(jq -r '.. | objects | select(.type? == "command") | .command | select(startswith("bash ") | not)' "$ROOT/hooks/hooks.json")"
if [ -z "$bare_hooks" ]; then
  ok "every hooks.json command runs through bash"
else
  bad "every hooks.json command runs through bash" "not run through bash ($EXEC_BIT_DOC): $bare_hooks"
fi

# A host that drops the execute bit leaves the scripts at 644. Run each
# hooks.json command, as written, against such a copy.
PLUGIN_644="$(mktemp -d)"
cp -r "$ROOT/scripts" "$PLUGIN_644/scripts"
find "$PLUGIN_644/scripts" -name '*.sh' -exec chmod 644 {} +
while IFS= read -r cmd; do
  name="${cmd##*/}"; name="${name%\"}"
  case "$name" in
    hook-guard.sh) event="$(edit_event "$REPO/src/x.ts" exec644)" ;;
    *)             event="$(skill_event "mattpocock-skills:tdd" exec644)" ;;
  esac
  printf '%s' "$event" | CLAUDE_PLUGIN_ROOT="$PLUGIN_644" sh -c "$cmd" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -eq 0 ]; then
    ok "$name runs with its script at mode 644"
  else
    bad "$name runs with its script at mode 644" "exit $rc ($EXEC_BIT_DOC)"
  fi
done < <(jq -r '.. | objects | select(.type? == "command") | .command' "$ROOT/hooks/hooks.json")
rm -rf "$PLUGIN_644"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
