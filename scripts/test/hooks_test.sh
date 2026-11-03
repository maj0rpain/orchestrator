#!/usr/bin/env bash
#
# Tests for the six hook scripts.
#
# The failure modes worth catching: the grilling hook firing on skills that
# aren't planning, firing twice in one session, or staying silent when it should
# speak; the edit guard blocking the planning artifacts planning legitimately
# writes, or letting a planning record (glossary, ADR) through; and the
# quick-implement hook touching a marker it should leave alone; and the paste
# guard letting a spec review ask before the view is shown, or blocking a
# session that is not mid-review.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=git_env.sh
source "$DIR/test/git_env.sh"
test_git_env_clear || exit 1
# shellcheck source=tally.sh
source "$DIR/test/tally.sh"
# shellcheck source=test_jobs.sh
source "$DIR/test/test_jobs.sh"
GRILL="$DIR/hook-grilling.sh"
GUARD="$DIR/hook-guard.sh"
QUICK="$DIR/hook-quick-implement.sh"
START="$DIR/hook-session-start.sh"
PASTE="$DIR/hook-paste-guard.sh"
STOP="$DIR/hook-paste-stop-guard.sh"
COMMON="$DIR/hook-common.sh"

assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_not_contains() { case "$2" in *"$3"*) bad "$1" "found '$3' in: $2" ;; *) ok "$1" ;; esac; }
# count_of TEXT NEEDLE: how many times the fixed string NEEDLE occurs in TEXT.
count_of() {
  local text="$1" needle="$2" n=0
  while [ -n "$needle" ] && case "$text" in *"$needle"*) true ;; *) false ;; esac; do
    text="${text#*"$needle"}"
    n=$((n + 1))
  done
  printf '%s' "$n"
}
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }
# <kind> is grilling or planning: the marker $TMPDIR/orchestrator-<kind>-<id>.
assert_marker_present() { if [ -e "$TMPDIR/orchestrator-$2-$3" ]; then ok "$1"; else bad "$1" "no orchestrator-$2-$3"; fi; }
assert_marker_absent()  { if [ -e "$TMPDIR/orchestrator-$2-$3" ]; then bad "$1" "orchestrator-$2-$3 exists"; else ok "$1"; fi; }
# Write, or remove, both markers of session <id>.
make_markers()   { : >"$TMPDIR/orchestrator-grilling-$1"; : >"$TMPDIR/orchestrator-planning-$1"; }
remove_markers() { rm -f "$TMPDIR/orchestrator-grilling-$1" "$TMPDIR/orchestrator-planning-$1"; }

# The temp root, created before anything else: TMPDIR is exported as it, so
# every mktemp below lands inside it, and the hooks' markers too. The EXIT trap
# leaves the root, makes it writable again (a run killed while RO_TMP is mode
# 500), removes it, and keeps the exit status. An INT or TERM first stops every
# process below this shell (test_jobs_stop_descendants), then exits 130 through
# that trap.
hooks_root="$(mktemp -d)" || {
  echo "hooks_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$hooks_root"
hooks_remove_root() {
  local status=$?
  cd / || :
  chmod -R u+w "$hooks_root" 2>/dev/null
  rm -rf "$hooks_root"
  exit "$status"
}
trap hooks_remove_root EXIT
trap test_jobs_stop_descendants INT TERM
# The tally file lands in the temp root, removed with it.
tally_init

# >>> checks
REPO="$(mktemp -d)"
git -C "$REPO" init -q
mkdir -p "$REPO/docs/agents" "$REPO/docs/adr"

skill_event() {
  jq -n --arg s "$1" --arg sid "$2" --arg cwd "$REPO" \
    '{hook_event_name:"PostToolUse", tool_name:"Skill", session_id:$sid, cwd:$cwd, tool_input:{skill:$s}}'
}
# edit_event_at <file> <session> <cwd>: an Edit payload, the cwd chosen.
edit_event_at() {
  jq -n --arg f "$1" --arg sid "$2" --arg cwd "$3" \
    '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:$sid, cwd:$cwd, tool_input:{file_path:$f}}'
}
edit_event() { edit_event_at "$1" "$2" "$REPO"; }
# bash_hook_decision OUTPUT: the permissionDecision the hook wrote.
bash_hook_decision() { jq -r '.hookSpecificOutput.permissionDecision' <<<"$1"; }
# write_event <file> <session>: a Write payload for $REPO.
write_event() { edit_event_at "$1" "$2" "$REPO" | jq '.tool_name="Write"'; }

echo "hook tests"
echo
echo "hook-common"

# shellcheck source=../hook-common.sh
source "$COMMON"

# write_flow_state <key> <value>...: writes $REPO's state file as orch.sh
# would, applying the Flow state module's writer (sourced through hook-common)
# to {} once per key and value. The hooks tests' well-formed states (slug,
# phase and issue present) come from here; partial and invalid ones stay raw,
# to prove the hooks tolerate anything on disk. A failed write fails its case.
write_flow_state() {
  local file
  file="$(flow_state_file "$REPO")"
  mkdir -p "${file%/*}"
  echo '{}' >"$file"
  while [ "$#" -gt 1 ]; do
    if ! flow_state_write "$file" "$1" "$2"; then
      bad "writes the flow state $1=$2" "flow_state_write failed on $file"
      return 1
    fi
    shift 2
  done
}

# run_tolerant <name> <hook>: runs <hook> on the payload on stdin and sets
# hook_out to its stdout, asserting it exits 0 with empty stderr - what a hook
# must do whatever state.json holds. Feed it with < <(...), not a pipe, so
# hook_out and the counts survive.
run_tolerant() {
  local errf rc=0
  errf="$(mktemp)"
  hook_out="$("$2" 2>"$errf")" || rc=$?
  assert_eq "$1 exits 0" "$rc" "0"
  assert_empty "$1 writes nothing to stderr" "$(cat "$errf")"
  rm -f "$errf"
}

hook_read_skill_and_session < <(skill_event "mattpocock-skills:grilling" abc123)
assert_eq "extracts skill from tool_input.skill" "$skill" "mattpocock-skills:grilling"
assert_eq "extracts session_id" "$session" "abc123"

hook_read_skill_and_session < <(printf '{}')
assert_eq "defaults skill to empty string when absent" "$skill" ""
assert_eq "defaults session_id to empty when absent" "$session" ""

echo
echo "grilling hook"

PLUGIN_ROOT="$(cd "$DIR/.." && pwd)"
CLOSING_SKILL="$PLUGIN_ROOT/skills/orch-interview/SKILL.md"
# The planning message's pointer to the Closing section (#1980): the absolute
# path of orch-interview's SKILL.md, which must exist and hold the heading.
pointer_text="Read that section by this absolute path"
check_pointer() {
  local where="$1" ctx="$2"
  assert_contains "points at orch-interview's SKILL.md by absolute path $where" "$ctx" "$CLOSING_SKILL"
  assert_contains "tells the agent to read the Closing section $where" "$ctx" "$pointer_text"
}
check_no_pointer() {
  local where="$1" ctx="$2"
  assert_not_contains "carries no Read pointer $where" "$ctx" "$pointer_text"
  assert_not_contains "names no SKILL.md path $where" "$ctx" "$CLOSING_SKILL"
  assert_contains "says the closing rules are in the skill's Closing section $where" "$ctx" \
    "\`## Closing\` section of the orch-interview skill"
}
if [ -f "$CLOSING_SKILL" ] && grep -qx '## Closing' "$CLOSING_SKILL"; then
  ok "the pointer's path names an existing file holding a ## Closing heading"
else
  bad "the pointer's path names an existing file holding a ## Closing heading" "$CLOSING_SKILL"
fi

out="$(skill_event "mattpocock-skills:grilling" s1 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_contains "fires on Skill(grilling)" "$out" "additionalContext"
assert_contains "names the host's ask tool on Claude Code" "$ctx" "AskUserQuestion"
assert_not_contains "names no Junie ask tool on Claude Code" "$ctx" "ask_user"
check_pointer "on grilling" "$ctx"
assert_contains "names the repo's ready-for-agent label" "$ctx" "ready-for-agent is \`ready-for-agent\`"
assert_not_contains "drops the old scripted closing line" "$out" "Plan approved? I'll write the handoff and start the flow."
assert_not_contains "carries no route options (they live in the Closing section)" "$ctx" "Quick implementation"
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

# orch-interview is the plugin's own planning entry point (#330, renamed from
# orch-plan in #373): it arms the same message and the same edit guard as
# grilling, and loads the Closing section in full, so it gets no Read pointer.
out="$(skill_event "orchestrator:orch-interview" p1 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_contains "fires on Skill(orchestrator:orch-interview)" "$out" "Do NOT offer to implement"
check_no_pointer "on the orch-interview entry point" "$ctx"
assert_eq "orch-interview arms the guard, which denies a source edit" \
  "$(bash_hook_decision "$(edit_event "$REPO/src/main.ts" p1 | "$GUARD")")" "deny"
rm -f "$TMPDIR/orchestrator-grilling-p1"
# The old name is removed outright, with no alias.
assert_empty "ignores the removed Skill(orchestrator:orch-plan)" \
  "$(skill_event "orchestrator:orch-plan" p2 | "$GRILL")"

# No setup step: a repo with no issue-tracker.md gets no precondition warning.
out="$(skill_event "grilling" s5 | "$GRILL")"
assert_contains "still fires without issue-tracker.md" "$out" "Do NOT offer to implement"
assert_not_contains "no precondition warning without issue-tracker.md" "$out" "PRECONDITION"

mkdir -p "$REPO/.orchestrator"
# Planning beside an active flow (#640, #649) gets the planning rules, with a
# closing that names the flow and states two branches: about that flow, point
# to its next or redo; otherwise the Closing section's close.
# $1 where, $2 context, $3 the next/redo pointer text expected for the host.
check_flow_variant() {
  local where="$1" ctx="$2" next_redo="$3"
  assert_contains "states the next/redo branch $where" "$ctx" "$next_redo"
  assert_contains "the same-flow branch asks no route question $where" "$ctx" "ask no route question"
  assert_contains "the other branch runs the close unchanged $where" "$ctx" "Otherwise: run the interviewed-issue step and the done-close"
}
cc_next_redo='/orchestrator:next or /orchestrator:redo'
write_flow_state slug x phase spec issue 42
out="$(skill_event "grilling" s6 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_contains "sends the planning rules beside an active flow" "$ctx" "Do NOT offer to implement"
assert_contains "names the active flow's issue and phase" "$ctx" "the flow for #42 is active in this checkout, at phase spec"
assert_contains "the same-flow branch names the flow's issue" "$ctx" "about this flow's issue, #42"
check_flow_variant "on Claude Code" "$ctx" "$cc_next_redo"
check_pointer "beside an active flow" "$ctx"
assert_marker_present "writes the grilling marker beside an active flow" grilling s6
assert_empty "stays silent on a second planning call beside an active flow" \
  "$(skill_event "grilling" s6 | "$GRILL")"
write_flow_state slug my-change phase implement issue null
ctx="$(skill_event "grilling" s6b | "$GRILL" | jq -r '.additionalContext')"
assert_contains "names an issueless flow by slug and phase" "$ctx" \
  "the flow my-change is active in this checkout, at phase implement; it has no issue yet"
assert_contains "the same-flow branch reads about this flow's change" "$ctx" "about this flow's change"
check_flow_variant "for an issueless flow" "$ctx" "$cc_next_redo"
write_flow_state slug x phase null issue null
ctx="$(skill_event "grilling" s6c | "$GRILL" | jq -r '.additionalContext')"
assert_contains "names a freshly started flow by slug as just started" "$ctx" \
  "the flow x is active in this checkout, just started; it has no issue yet"
echo '{"phase":"spec"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the grilling hook on state with only a phase" "$GRILL" < <(skill_event "grilling" s6e)
ctx="$(printf '%s' "$hook_out" | jq -r '.additionalContext')"
assert_contains "states the phase of readable state with no issue or slug" "$ctx" \
  "a flow with no issue or slug is active in this checkout, at phase spec"
echo 'not json' >"$REPO/.orchestrator/state.json"
run_tolerant "the grilling hook on unreadable state" "$GRILL" < <(skill_event "grilling" s6d)
ctx="$(printf '%s' "$hook_out" | jq -r '.additionalContext')"
assert_contains "says a flow is active without naming it for unreadable state" "$ctx" \
  "a flow is active in this checkout"
assert_not_contains "names no flow issue for unreadable state" "$ctx" "the flow for #"
assert_not_contains "names no phase for unreadable state" "$ctx" "at phase"
check_flow_variant "for unreadable state" "$ctx" "$cc_next_redo"
# A done flow is finished work, not a running one (ADR-0009): planning in its
# checkout gets the full message, records rule included (#186).
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the grilling hook on a done flow" "$GRILL" < <(skill_event "grilling" s7)
out="$hook_out"
assert_contains "still injects its context when the flow is done" "$out" "Do NOT offer to implement"
assert_not_contains "a done flow gets the ordinary message, with no flow variant" "$out" "is active in this checkout"
assert_contains "tells planning to write record wording into the plan" \
  "$(printf '%s' "$out" | jq -r '.additionalContext')" \
  "- Glossary and ADR changes (GLOSSARY.md, GLOSSARY-MAP.md, CONTEXT.md, CONTEXT-MAP.md, docs/adr/) are records: never edit them. Write the exact wording you intend into the plan, so the spec carries it verbatim."
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
assert_contains "names Junie's ask_user tool" "$ctx" "the ask_user tool"
assert_not_contains "names no Claude question tool on Junie" "$ctx" "AskUserQuestion"
check_pointer "on a Junie grilling entry point" "$ctx"
assert_contains "forbids offering to implement on Junie" "$ctx" "Do NOT offer to implement"
assert_contains "carries the wayfinder caveat on Junie" "$ctx" "whole map is done"
assert_contains "names every planning artifact on Junie" "$ctx" \
  "docs/agents/, .scratch/, .orchestrator/"
assert_not_contains "names no Claude-scoped skill on Junie" "$ctx" "orchestrator:orch-"
assert_not_contains "names no Claude-scoped mattpocock skill on Junie" "$ctx" "mattpocock-skills:"

assert_empty "stays silent on the second grilling prompt in one Junie session" \
  "$(prompt_event '$grilling again' j1 | "$GRILL")"

# Junie has no plugin commands to load the skill, so /orchestrator:interview
# is pointed at the section; the orch-interview skill itself is not.
ctx="$(prompt_event '/orchestrator:interview x' jo1 | "$GRILL" | jq -r '.additionalContext')"
check_pointer "on Junie's orchestrator:interview" "$ctx"
ctx="$(prompt_event '$orch-interview x' jo2 | "$GRILL" | jq -r '.additionalContext')"
check_no_pointer "on Junie's orch-interview skill" "$ctx"

# On Junie the guard does not arm (ADR-0025): the marker that keeps the
# message to once per session is named so hook-guard.sh never reads it, and a
# Junie-style Edit in the same session, with no project_path, is allowed.
assert_marker_present "a Junie grilling prompt writes the planning marker" planning j1
assert_marker_absent "a Junie grilling prompt writes no guard marker" grilling j1
junie_same_session_edit="$(jq -n --arg f "$REPO/src/main.ts" \
  '{hook_event_name:"PreToolUse", tool_name:"Edit", session_id:"j1", tool_input:{file_path:$f}}')"
assert_empty "a source edit after a Junie grilling prompt is allowed" \
  "$(cd "$REPO" && printf '%s' "$junie_same_session_edit" | "$GUARD")"

n=0
for p in '/grilling' '$grill-me x' 'please $wayfinder now' '/improve-codebase-architecture' '/mattpocock-skills:grilling' \
         '$orch-interview' '/orchestrator:orch-interview' '/orchestrator:interview' '$orchestrator:orch-interview x'; do
  n=$((n + 1))
  assert_contains "fires on the entry point in: $p" \
    "$(prompt_event "$p" "jy$n" | "$GRILL")" "additionalContext"
done
for p in 'let us talk about grilling' '$tdd fix it' '$grilling-notes' 'a/grilling b' \
         'let us plan this' 'plan the orch-plan rollout' '/plan' '$orch-planner' \
         '$orch-plan' '/orchestrator:plan' '/interview' 'let us interview the user' '$orch-interviewer'; do
  n=$((n + 1))
  assert_empty "ignores a prompt with no grilling entry point: $p" \
    "$(prompt_event "$p" "jn$n" | "$GRILL")"
done

# Junie's router sends grilling to its plan agent, which ends on its own
# plan screen and ignores the closing question. Confirming that screen
# submits this fixed prompt to the main agent, so the question is asked there
# instead (#202). It points at the Closing section.
confirm='Implement the suggested plan'
prompt_event '$grill-with-docs x' jc1 | "$GRILL" >/dev/null
out="$(prompt_event "$confirm" jc1 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_eq "fires on plan confirmation, as UserPromptSubmit" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName')" "UserPromptSubmit"
assert_contains "asks before implementing the confirmed plan" "$ctx" "Before you implement"
assert_contains "names Junie's ask tool at plan confirmation" "$ctx" "the ask_user tool"
check_pointer "at plan confirmation" "$ctx"
assert_not_contains "repeats no planning rules at plan confirmation" "$ctx" "Do NOT offer to implement"
assert_contains "asks again on a second plan confirmation" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")" "Before you implement"
assert_empty "stays silent on plan confirmation in a session that never grilled" \
  "$(prompt_event "$confirm" jc2 | "$GRILL")"
assert_empty "stays silent on a prompt that only mentions the confirmation" \
  "$(prompt_event "$confirm now" jc1 | "$GRILL")"

assert_not_contains "no precondition warning on Junie without issue-tracker.md" \
  "$(prompt_event '$grilling' j2 | "$GRILL")" "PRECONDITION"

mkdir -p "$REPO/.orchestrator"
write_flow_state slug x phase review issue 7
junie_next_redo="the **Next phase** and **Redo** sections of $PLUGIN_ROOT/skills/orch-flow/SKILL.md"
ctx="$(prompt_event '$grilling' j3 | "$GRILL" | jq -r '.additionalContext')"
assert_contains "sends the planning rules on Junie beside an active flow" "$ctx" "Do NOT offer to implement"
assert_contains "names the active flow's issue and phase on Junie" "$ctx" \
  "the flow for #7 is active in this checkout, at phase review"
check_flow_variant "on Junie" "$ctx" "$junie_next_redo"
assert_not_contains "names no plugin command on Junie" "$ctx" "/orchestrator:next"
assert_marker_present "writes the planning marker on Junie beside an active flow" planning j3
assert_empty "stays silent on a second Junie planning prompt beside an active flow" \
  "$(prompt_event '$grilling' j3 | "$GRILL")"
ctx="$(prompt_event "$confirm" jc1 | "$GRILL" | jq -r '.additionalContext')"
assert_contains "asks before implementing at plan confirmation beside an active flow" "$ctx" "before you implement anything"
assert_contains "names the active flow at plan confirmation" "$ctx" \
  "the flow for #7 is active in this checkout, at phase review"
check_flow_variant "at Junie's plan confirmation" "$ctx" "$junie_next_redo"
check_pointer "at plan confirmation beside an active flow" "$ctx"
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the grilling hook on Junie on a done flow" "$GRILL" < <(prompt_event '$grilling' j4)
out="$hook_out"
assert_contains "still fires on Junie's \$grilling when the flow is done" "$out" "Do NOT offer to implement"
assert_not_contains "a done flow gets the ordinary message on Junie" "$out" "is active in this checkout"
assert_contains "still asks at plan confirmation when the flow is done" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")" "Before you implement"
rm -rf "$REPO/.orchestrator"

echo
echo "grilling hook's triage labels"

# A repo that renamed its triage labels gets its own names in the message,
# never the canonical ones.
cat >"$REPO/docs/agents/triage-labels.md" <<'DOC'
| Role            | Ours          | Meaning |
| --------------- | ------------- | ------- |
| needs-triage    | triage-me     | x       |
| needs-info      | need-more     | x       |
| ready-for-agent | agent-ready   | x       |
| ready-for-human | human-only    | x       |
| wontfix         | not-planned   | x       |
DOC
check_renamed_labels() {
  local where="$1" event="$2" arg="$3" session="$4" ctx
  ctx="$("$event" "$arg" "$session" | "$GRILL" | jq -r '.additionalContext')"
  assert_contains "names the repo's labels $where" "$ctx" \
    "ready-for-agent is \`agent-ready\`, wontfix is \`not-planned\`, ready-for-human is \`human-only\`"
  assert_not_contains "names no canonical ready-for-agent label $where" "$ctx" "is \`ready-for-agent\`"
}
check_renamed_labels "on Claude Code" skill_event "mattpocock-skills:grilling" ii3
check_renamed_labels "on Junie" prompt_event '$grilling' ii4
check_renamed_labels "at Junie's plan confirmation" prompt_event "$confirm" ii4
rm -f "$REPO/docs/agents/triage-labels.md"

# Size matrix (#1980): Claude Code keeps hook context of 10 KB or more out of
# the conversation. Run the hook through every host, entry point and flow
# state, in a repo whose triage labels map to long non-canonical strings, and
# fail when any additionalContext reaches 8,000 bytes (below 10 KB because the
# plugin root path and the flow slug vary by install).
long="$(printf 'x%.0s' $(seq 1 60))"
cat >"$REPO/docs/agents/triage-labels.md" <<DOC
| Role            | Ours               | Meaning |
| --------------- | ------------------ | ------- |
| needs-triage    | triage-$long       | x       |
| needs-info      | info-$long         | x       |
| ready-for-agent | agent-ready-$long  | x       |
| ready-for-human | human-only-$long   | x       |
| wontfix         | not-planned-$long  | x       |
DOC
mkdir -p "$REPO/.orchestrator"
size_budget=8000
matrix_n=0
# assert_under_budget <label> <bytes>: the context is non-empty and under
# size_budget bytes.
assert_under_budget() {
  if [ "$2" -gt 0 ] && [ "$2" -lt "$size_budget" ]; then
    ok "$1 stays under $size_budget bytes"
  else
    bad "$1 stays under $size_budget bytes" "got $2 bytes"
  fi
}
# $1 flow state label; state is already written by the caller.
run_size_matrix() {
  local flow="$1" entry ev bytes
  local -a events=(
    "cc orch-interview|$(skill_event "orchestrator:orch-interview" mx)"
    "cc grilling|$(skill_event "mattpocock-skills:grilling" mx)"
    "junie orch-interview|$(prompt_event '$orch-interview x' mx)"
    "junie grilling|$(prompt_event '$grill-me x' mx)"
    "junie orchestrator:interview|$(prompt_event '/orchestrator:interview x' mx)"
  )
  for entry in "${events[@]}"; do
    matrix_n=$((matrix_n + 1))
    remove_markers mx
    ev="${entry#*|}"
    bytes="$(printf '%s' "$ev" | "$GRILL" | jq -r '.additionalContext' | wc -c)"
    assert_under_budget "${entry%%|*} ($flow)" "$bytes"
  done
  # Junie's plan-confirmed message needs a grilled session first.
  rm -f "$TMPDIR"/orchestrator-planning-mx
  prompt_event '$grill-me x' mx | "$GRILL" >/dev/null
  bytes="$(prompt_event "$confirm" mx | "$GRILL" | jq -r '.additionalContext' | wc -c)"
  assert_under_budget "junie plan-confirmed ($flow)" "$bytes"
}
run_size_matrix "no flow"
write_flow_state slug "$long" phase spec issue 42
run_size_matrix "flow with an issue"
write_flow_state slug "$long" phase implement issue null
run_size_matrix "flow with only a slug"
write_flow_state slug null phase null issue null
run_size_matrix "flow with neither"
echo 'not json' >"$REPO/.orchestrator/state.json"
run_size_matrix "flow with unreadable state"
rm -rf "$REPO/.orchestrator"
rm -f "$REPO/docs/agents/triage-labels.md"
remove_markers mx
assert_eq "the size matrix ran 25 cases of the five entry points" "$matrix_n" "25"

# Emitter coverage: every hook-*.sh that emits context through
# hook_emit_context must be in the size matrix above. Count call lines, not the
# definition line, so a call added in hook-common.sh counts too.
emitters="$(cd "$DIR" && grep -lE '^[^#]*hook_emit_context( |$)' hook-*.sh | grep -v '^hook-common.sh$' || true)"
common_calls="$(grep -E '^[^#]*hook_emit_context( |$)' "$COMMON" | grep -vcE '^[[:space:]]*hook_emit_context\(\)' || true)"
assert_eq "hook-grilling.sh is the only hook-*.sh calling hook_emit_context" "$emitters" "hook-grilling.sh"
assert_eq "hook-common.sh has no call to hook_emit_context, only its definition" "$common_calls" "0"
# The Bash hooks' code lives in the module of the concept it serves (#2153).
assert_eq "hook-common.sh defines no hook_bash_ function and no HOOK_BASH_SCOPE" \
  "$(grep -cE '^(hook_bash_[a-z_]*\(\)|HOOK_BASH_SCOPE=)' "$COMMON")" 0
assert_eq "bash-walk.sh defines hook_bash_walk and HOOK_BASH_SCOPE" \
  "$(grep -cE '^(hook_bash_walk\(\)|HOOK_BASH_SCOPE=)' "$DIR/bash-walk.sh")" 2
assert_eq "no script names hook_bash_stdin_reader, hook_bash_stdin_hit or hook_bash_poll_hit" \
  "$(grep -rlE 'hook_bash_stdin_reader|hook_bash_stdin_hit|hook_bash_poll_hit' "$DIR" --include='*.sh' --exclude=hooks_test.sh | wc -l | tr -d ' ')" 0

# Claude Code also fires UserPromptSubmit, but its PostToolUse on Skill already
# delivers the message; its payload has no project_path.
assert_empty "exits silently on Claude Code's UserPromptSubmit" \
  "$(claude_prompt_event '/grilling' c1 | "$GRILL")"
assert_empty "exits silently on plan confirmation on Claude Code" \
  "$(claude_prompt_event "$confirm" c1 | "$GRILL")"
assert_marker_absent "arms no marker from Claude Code's UserPromptSubmit" grilling c1
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
  "$(bash_hook_decision "$out")" "deny"
assert_contains "explains what to do instead" "$out" "orchestrator:orch-flow"
assert_contains "names the blocked file" "$out" "src/main.ts"
# One JSON object serves both hosts: Junie reads the top-level decision/reason.
# "block" is Claude Code's legacy top-level value; Junie accepting it is
# unverified (#121).
assert_eq "carries Junie's top-level block decision" \
  "$(printf '%s' "$out" | jq -r '.decision')" "block"
assert_contains "carries Junie's top-level reason" \
  "$(printf '%s' "$out" | jq -r '.reason')" "src/main.ts"

for f in docs/agents/domain.md docs/agents/x.md .scratch/ticket.md .scratch/x.md .orchestrator/handoff/01-plan.md .orchestrator/x; do
  assert_empty "allows planning artifact: $f" "$(edit_event "$REPO/$f" s1 | "$GUARD")"
done

# The flow state and nested checkouts sit under .orchestrator/ but stay guarded.
out="$(write_event "$REPO/.orchestrator/state.json" s1 | "$GUARD")"
assert_eq "denies a write of the flow state file" \
  "$(bash_hook_decision "$out")" "deny"
assert_contains "flow state denial names the path" "$out" ".orchestrator/state.json"
assert_contains "flow state denial says only orch.sh writes it" "$out" "written only by orch.sh"
assert_contains "flow state denial points at orch-flow" "$out" 'call the Skill tool with \"orchestrator:orch-flow\"'
for f in .orchestrator/checkouts/x/src/a.ts .orchestrator/worktrees/t1/src/a.ts; do
  out="$(edit_event "$REPO/$f" s1 | "$GUARD")"
  assert_eq "denies another checkout's file: $f" \
    "$(bash_hook_decision "$out")" "deny"
  assert_contains "other-checkout denial names $f" "$out" "$f"
  assert_contains "other-checkout denial redirects for $f" "$out" "Edit it from a session opened in that checkout"
done

# The glossary and ADRs are planning records: planning never changes them in
# place, and the denial redirects the wording into the plan instead (#186).
# The legacy CONTEXT names stay records for repos not yet renamed (#461).
for f in GLOSSARY.md GLOSSARY-MAP.md CONTEXT.md CONTEXT-MAP.md docs/adr/0001-x.md docs/adr/../adr/x.md; do
  out="$(edit_event "$REPO/$f" s1 | "$GUARD")"
  assert_eq "denies planning record: $f" \
    "$(bash_hook_decision "$out")" "deny"
  assert_contains "gives the records reason for $f" "$(printf '%s' "$out" | jq -r '.reason')" \
    "is a record of decisions, and planning does not change records in place. Write the exact wording you intended - the new or replaced text, and where it goes - into the plan, so the spec carries it verbatim as an Implementation Decision and it lands with the change it describes. For a quick implementation, put it in the linked issue's body."
done
records_reason="$(edit_event "$REPO/GLOSSARY.md" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "records reason names the blocked record" "$records_reason" "'GLOSSARY.md' is a record"
assert_not_contains "records denial does not point at the flow" "$records_reason" "orchestrator:orch-flow"
assert_not_contains "records denial does not list planning artifacts" "$records_reason" "Planning artifacts you may still edit"
source_reason="$(edit_event "$REPO/src/x.ts" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "source denial keeps today's reason" "$source_reason" \
  "this is a planning session and no flow has
started, so 'src/x.ts' should not be edited yet."
assert_contains "source denial still lists planning artifacts" "$source_reason" "Planning artifacts you may still edit"
# The guard arms only on Claude Code (ADR-0025), so the source denial names
# the Skill lift alone, and no Read lift.
assert_contains "source denial names the quick-implement Skill lift" "$source_reason" \
  'call the Skill tool with "orchestrator:orch-quick-implement"'
assert_not_contains "source denial names no SKILL.md" "$source_reason" "SKILL.md"
assert_not_contains "source denial names no Read tool" "$source_reason" "Read tool"

# A repo reached through a symlink is judged by where the write lands (#1919).
SL="$(mktemp -d)"
LINK="$SL/link"
ln -s "$REPO" "$LINK"
OUTSIDE="$(mktemp -d)"
mkdir -p "$REPO/docs/agents" "$REPO/src"
ln -s "$OUTSIDE" "$REPO/src/out"
ln -s ../../src/real.ts "$REPO/docs/agents/toSrc.ts"
ln -s ../../src/notyet.ts "$REPO/docs/agents/dangling.ts"
ln -s loop "$REPO/src/loop"
src_deny='this is a planning session and no flow has'
out="$(edit_event_at "$LINK/src/x.ts" s1 "$LINK" | "$GUARD")"
assert_eq "denies a source edit via a symlinked repo, cwd the link" \
  "$(bash_hook_decision "$out")" "deny"
assert_contains "names the repo-relative path, not the link spelling" \
  "$(printf '%s' "$out" | jq -r '.reason')" "so 'src/x.ts' should not be edited yet"
out="$(edit_event_at "$LINK/src/x.ts" s1 "$REPO" | "$GUARD")"
assert_eq "denies a source edit via a symlinked repo, cwd the physical repo" \
  "$(bash_hook_decision "$out")" "deny"
out="$(edit_event_at "$LINK/nodir/deeper/new.ts" s1 "$LINK" | "$GUARD")"
assert_eq "denies a new file in a missing directory via the link" \
  "$(bash_hook_decision "$out")" "deny"
assert_empty "allows a planning artifact via the link" \
  "$(edit_event_at "$LINK/docs/agents/domain.md" s1 "$LINK" | "$GUARD")"
out="$(edit_event_at "$LINK/docs/adr/0001-x.md" s1 "$LINK" | "$GUARD")"
assert_contains "denies an ADR via the link with the records reason" \
  "$(printf '%s' "$out" | jq -r '.reason')" "is a record of decisions"
assert_empty "allows an edit through an in-repo symlink to outside the repo" \
  "$(edit_event_at "$LINK/src/out/f.ts" s1 "$LINK" | "$GUARD")"
out="$(edit_event_at "$LINK/docs/agents/toSrc.ts" s1 "$LINK" | "$GUARD")"
assert_contains "denies an allowlisted name symlinked to source, as source" \
  "$(printf '%s' "$out" | jq -r '.reason')" "$src_deny"
out="$(edit_event_at "src/x.ts" s1 "$LINK" | "$GUARD")"
assert_eq "denies a relative source path with cwd the link" \
  "$(bash_hook_decision "$out")" "deny"
out="$(edit_event_at "$LINK/src/loop" s1 "$LINK" | "$GUARD")"
assert_contains "denies a symlink loop under src as source" \
  "$(printf '%s' "$out" | jq -r '.reason')" "$src_deny"
out="$(edit_event_at "$LINK/docs/agents/dangling.ts" s1 "$LINK" | "$GUARD")"
assert_contains "denies an allowlisted dangling symlink to missing source as source" \
  "$(printf '%s' "$out" | jq -r '.reason')" "$src_deny"
mkdir -p "$REPO/src/deep"
ln -s ../../src/deep "$REPO/docs/agents/sub"
ln -s ../g.ts "$REPO/src/deep/f.ts"
out="$(edit_event_at "$LINK/docs/agents/sub/f.ts" s1 "$LINK" | "$GUARD")"
assert_contains "denies a file symlink under a directory symlink, its target taken from the physical directory" \
  "$(printf '%s' "$out" | jq -r '.reason')" "$src_deny"
rm -rf "$SL" "$OUTSIDE" "$REPO/src/deep" "$REPO/docs/agents/sub" "$REPO/src/out" "$REPO/src/loop" "$REPO/docs/agents/toSrc.ts" "$REPO/docs/agents/dangling.ts"

# Junie's PreToolUse payload carries no cwd, and its bundled docs show no
# session_id either, though build 3419.7 sends one. No session
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
assert_not_contains "a nested docs/GLOSSARY.md is not a record" \
  "$(edit_event "$REPO/docs/GLOSSARY.md" s1 | "$GUARD" | jq -r '.reason')" "is a record of decisions"

assert_empty "ignores files outside the repo" "$(edit_event "/etc/hosts" s1 | "$GUARD")"

mkdir -p "$REPO/.orchestrator"
echo '{"slug":"x","phase":"implement"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the edit guard on state with no issue" "$GUARD" < <(edit_event "$REPO/src/main.ts" s1)
assert_empty "stops guarding once a flow is running" "$hook_out"
echo '{"slug":"x"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the edit guard on state with no phase" "$GUARD" < <(edit_event "$REPO/src/main.ts" s1)
assert_empty "stands down for a state.json with no phase" "$hook_out"
echo 'not json' >"$REPO/.orchestrator/state.json"
run_tolerant "the edit guard on unreadable state" "$GUARD" < <(edit_event "$REPO/src/main.ts" s1)
assert_empty "stands down for an unreadable state.json" "$hook_out"
# A done flow is no flow: its lingering state.json must not switch the guard
# off for the next planning session (#186, extending ADR-0009 to the hooks).
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
run_tolerant "the edit guard on a done flow" "$GUARD" < <(edit_event "$REPO/CONTEXT.md" s1)
out="$(printf '%s' "$hook_out" | jq -r '.reason')"
assert_contains "denies a legacy-named record with the records reason when the flow is done" "$out" \
  "'CONTEXT.md' is a record of decisions"
out="$(edit_event "$REPO/GLOSSARY.md" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "denies the glossary with the records reason when the flow is done" "$out" \
  "'GLOSSARY.md' is a record of decisions"
out="$(edit_event "$REPO/src/main.ts" s1 | "$GUARD" | jq -r '.reason')"
assert_contains "denies source with the source reason when the flow is done" "$out" \
  "so 'src/main.ts' should not be edited yet"

# End to end, no hand-seeded marker: grilling arms the guard in a checkout
# whose flow is done, and the guard then denies a glossary edit.
rm -f "$TMPDIR/orchestrator-grilling-e2e"
skill_event "mattpocock-skills:grilling" e2e | "$GRILL" >/dev/null
assert_marker_present "grilling arms the marker when the flow is done" grilling e2e
out="$(edit_event "$REPO/GLOSSARY.md" e2e | "$GUARD" | jq -r '.reason')"
assert_contains "the armed guard denies GLOSSARY.md with the records reason" "$out" \
  "'GLOSSARY.md' is a record of decisions, and planning does not change records in place."
rm -rf "$REPO/.orchestrator"

echo
echo "hook-quick-implement"

: >"$TMPDIR/orchestrator-grilling-s1"
out="$(skill_event "orchestrator:orch-quick-implement" s1 | "$QUICK")"
assert_empty "prints nothing" "$out"
assert_marker_absent "deletes the session's marker" grilling s1

: >"$TMPDIR/orchestrator-grilling-s2"
skill_event "mattpocock-skills:tdd" s2 | "$QUICK" >/dev/null
assert_marker_present "leaves another skill's marker alone" grilling s2

skill_event "orchestrator:orch-quick-implement" s3 | "$QUICK" >/dev/null
ok "does not fail when no marker exists for the session"

# ADR-0014 renamed the skill; the old unprefixed name must not lift the guard.
: >"$TMPDIR/orchestrator-grilling-s4"
skill_event "orchestrator:quick-implement" s4 | "$QUICK" >/dev/null
assert_marker_present "ignores the old unprefixed quick-implement name" grilling s4

# The Read lift is gone (ADR-0025): the guard does not arm on Junie, so
# nothing needs lifting there, and a Read of the installed SKILL.md is no
# longer a trigger.
QUICK_SKILL="$(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md"
: >"$TMPDIR/orchestrator-grilling-r1"
jq -n --arg f "$QUICK_SKILL" \
  '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:"r1", tool_input:{file_path:$f}}' \
  | "$QUICK" >/dev/null
assert_marker_present "a PreToolUse Read of the installed SKILL.md leaves the marker" grilling r1
rm -f "$TMPDIR/orchestrator-grilling-r1"

assert_empty "hooks.json has no PreToolUse Read matcher" \
  "$(jq -r '.hooks.PreToolUse[]? | select(.matcher == "Read") | .matcher' "$DIR/../hooks/hooks.json")"

echo
echo "hook-session-start"

# /clear on Claude Code, /new on Junie: SessionStart with source "clear" keeps
# the session ID but wipes the context, so the session's planning markers go
# with it. compact, startup and resume keep them.
start_event() {
  jq -n --arg src "$1" --arg sid "$2" --arg cwd "$REPO" \
    '{hook_event_name:"SessionStart", session_id:$sid, cwd:$cwd, source:$src}'
}
markers_present() {
  local n=0
  [ -e "$TMPDIR/orchestrator-grilling-$1" ] && n=$((n + 1))
  [ -e "$TMPDIR/orchestrator-planning-$1" ] && n=$((n + 1))
  echo "$n"
}

make_markers ss1
out="$(start_event clear ss1 | "$START")"; st=$?
assert_eq "clear exits 0" "$st" 0
assert_empty "clear emits no context" "$out"
assert_eq "clear removes the session's grilling and planning markers" "$(markers_present ss1)" 0

for src in compact startup resume; do
  make_markers "ss-$src"
  out="$(start_event "$src" "ss-$src" | "$START")"; st=$?
  assert_eq "$src exits 0" "$st" 0
  assert_empty "$src emits nothing" "$out"
  assert_eq "$src leaves both markers in place" "$(markers_present "ss-$src")" 2
  remove_markers "ss-$src"
done

# With no session_id the marker path would end in "-": nothing may be removed.
make_markers ""
make_markers ss2
out="$(jq -n --arg cwd "$REPO" '{hook_event_name:"SessionStart", cwd:$cwd, source:"clear"}' | "$START")"; st=$?
assert_eq "no session_id exits 0" "$st" 0
assert_empty "no session_id exits silently" "$out"
assert_eq "no session_id removes no marker" \
  "$(( $(markers_present "") + $(markers_present ss2) ))" 4
remove_markers ""

out="$(start_event clear ss2 | "$START")"
assert_eq "only the named session's markers are removed" "$(markers_present ss1)$(markers_present ss2)" "00"
make_markers ss3
start_event clear ss4 | "$START" >/dev/null
assert_eq "another session's markers stay in place" "$(markers_present ss3)" 2
remove_markers ss3

out="$(start_event clear ss-none | "$START")"; st=$?
assert_eq "clear with no marker present exits 0" "$st" 0
assert_empty "clear with no marker present prints nothing" "$out"

# A marker in a TMPDIR that cannot be written cannot be deleted: still exit 0.
if [ "$(id -u)" -eq 0 ]; then
  ok "a failed deletion still exits 0 (skipped as root)"
else
  RO_TMP="$(mktemp -d)"
  : >"$RO_TMP/orchestrator-grilling-ro1"; : >"$RO_TMP/orchestrator-planning-ro1"
  chmod 500 "$RO_TMP"
  out="$(start_event clear ro1 | TMPDIR="$RO_TMP" "$START" 2>&1)"; st=$?
  chmod 700 "$RO_TMP"
  assert_eq "a failed deletion still exits 0" "$st" 0
  assert_empty "a failed deletion prints nothing" "$out"
  rm -rf "$RO_TMP"
fi

# After a clear, the same session gets the planning message again.
skill_event "mattpocock-skills:grilling" ss5 | "$GRILL" >/dev/null
assert_empty "a second planning call before clear is silent" \
  "$(skill_event "mattpocock-skills:grilling" ss5 | "$GRILL")"
start_event clear ss5 | "$START" >/dev/null
assert_contains "after a clear, a planning skill call gets the planning message again" \
  "$(skill_event "mattpocock-skills:grilling" ss5 | "$GRILL" | jq -r '.additionalContext')" \
  "Do NOT offer to implement"

# Junie: /new fires SessionStart with source clear.
prompt_event '$grill-me probe' ss6 | "$GRILL" >/dev/null
assert_empty "on Junie, the same planning prompt before clear is silent" \
  "$(prompt_event '$grill-me probe' ss6 | "$GRILL")"
jq -n --arg sid ss6 --arg cwd "$JUNIE_HOME" --arg pp "$REPO" \
  '{hook_event_name:"SessionStart", session_id:$sid, cwd:$cwd, project_path:$pp, source:"clear"}' \
  | "$START" >/dev/null
assert_contains "on Junie, after SessionStart clear the planning message is sent again" \
  "$(prompt_event '$grill-me probe' ss6 | "$GRILL" | jq -r '.additionalContext')" \
  "Do NOT offer to implement"

# End to end across the guard: planning arms it, clear disarms it.
skill_event "mattpocock-skills:grilling" ss7 | "$GRILL" >/dev/null
assert_eq "the planning hook arms the guard on a source file" \
  "$(bash_hook_decision "$(edit_event "$REPO/src/main.ts" ss7 | "$GUARD")")" "deny"
start_event clear ss7 | "$START" >/dev/null
assert_empty "after SessionStart clear, the edit guard allows the source edit" \
  "$(edit_event "$REPO/src/main.ts" ss7 | "$GUARD")"
rm -f "$TMPDIR"/orchestrator-*-ss*

assert_eq "hooks.json registers hook-session-start.sh under SessionStart with matcher clear" \
  "$(jq -r '[.hooks.SessionStart[]? | select(.matcher == "clear") | .hooks[]?.command | select(test("hook-session-start\\.sh"))] | length' "$DIR/../hooks/hooks.json")" 1

echo
echo "hook-paste-guard (#1287, #1350)"

# The guard refuses every AskUserQuestion after an arming `spec-review check`
# pass line, until the next `spec-review apply` or human message, unless
# one assistant text block written after the pass line holds every non-blank
# line of the view (hook-paste-guard.sh's header). Fixture transcripts are
# Claude Code's JSONL shape: one entry per content block, a tool result in
# a user entry, a tool_use in an assistant entry. ORCH_PASTE_GUARD_WAIT=0
# drops the re-read window, so a refused case returns at once; the window's
# own cases set it.
export ORCH_PASTE_GUARD_WAIT=0
PG="$(mktemp -d)"
mkdir "$PG/batch" "$PG/full" "$PG/tickets" "$PG/gone" "$PG/empty"
printf '## The batch\n\n1. Fidelity: name the seam\n\n### Minor edits\n\n2. Consistency: one term\n' >"$PG/batch/view.md"
printf '### Item 2 - Consistency\n\n> one term throughout\n' >"$PG/full/view.md"
printf '## Ticket #12\n\nRecommend: apply\n' >"$PG/tickets/view.md"

# pg_entry <transcript> <type> <content-json>: one entry of <type>, its
# message content <content-json>.
pg_entry() {
  jq -nc --arg ty "$2" --argjson c "$3" '{type:$ty, message:{role:(if $ty == "assistant" then "assistant" else "user" end), content:$c}}' >>"$1"
}
# pg_text <transcript> <text>: an assistant text block.
pg_text() { pg_entry "$1" assistant "$(jq -nc --arg t "$2" '[{type:"text", text:$t}]')"; }
# pg_bash <transcript> <id> <command>: an assistant Bash tool_use.
pg_bash() { pg_entry "$1" assistant "$(jq -nc --arg id "$2" --arg c "$3" '[{type:"tool_use", id:$id, name:"Bash", input:{command:$c}}]')"; }
# pg_ask <transcript> <id>: an assistant AskUserQuestion tool_use.
pg_ask() { pg_entry "$1" assistant "$(jq -nc --arg id "$2" '[{type:"tool_use", id:$id, name:"AskUserQuestion", input:{questions:[]}}]')"; }
# pg_result <transcript> <id> <text> [is_error]: a tool result.
pg_result() {
  pg_entry "$1" user "$(jq -nc --arg id "$2" --arg t "$3" --argjson e "${4:-false}" '[{type:"tool_result", tool_use_id:$id, content:$t, is_error:$e}]')"
}
# pg_nudge <view.md>: the pass line's tail naming <view.md>, from the producer
# itself - spec-review.sh's spec_review_nudge, sourced - so a change to its
# wording reaches the guard's cases rather than leaving them on a copy.
pg_nudge() { (source "$DIR/orch/spec-review.sh" && spec_review_nudge "$(dirname "$1")"); }
# pg_pass_line <kind> <view.md>: check's stderr pass line for <kind>, batch or
# tickets, naming <view.md>, ending as spec_review_nudge ends it.
pg_pass_line() {
  printf '%s' "$1.md passes: 2 items, 3 anchors, each matching once, and the all answer applies cleanly$(pg_nudge "$2")"
}
# pg_check <transcript> <id> <kind> <view.md>: a passing check run as Bash -
# <kind> batch or tickets - its result <view.md>'s view then the stderr pass
# line naming <view.md>.
pg_check() {
  pg_bash "$1" "$2" "bash \"\$ORCH\" spec-review check .orchestrator/spec-review/7"
  pg_result "$1" "$2" "$(cat "$4" 2>/dev/null)
$(pg_pass_line "$3" "$4")"
}
# pg_decide <transcript-or-empty> [tool_use_id] [tool_name]: the guard's
# decision on an ask - deny, allow (no output), or the exit status when it is
# not 0 - with the deny reason left in $PG/reason, since the decision is read
# in a subshell.
pg_decide() {
  local out st
  out="$(jq -n --arg t "$1" --arg id "${2:-toolu_now}" --arg n "${3:-AskUserQuestion}" \
    '{hook_event_name:"PreToolUse", session_id:"pg", cwd:"/tmp", transcript_path:$t, tool_use_id:$id, tool_name:$n, tool_input:{questions:[]}}' \
    | "$PASTE" 2>/dev/null)"; st=$?
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' >"$PG/reason" 2>/dev/null
  if [ "$st" -ne 0 ]; then echo "exit $st"
  elif [ -z "$out" ]; then echo allow
  else bash_hook_decision "$out"
  fi
}

T="$PG/armed.jsonl"
pg_text "$T" "Running the lenses."
pg_check "$T" toolu_c1 batch "$PG/batch/view.md"
assert_eq "armed, an ask with no paste after the pass line is refused" "$(pg_decide "$T")" deny
assert_contains "with the view in the reason" "$(cat "$PG/reason")" "$(cat "$PG/batch/view.md")"
assert_contains "and the instruction to end the turn on the view and the question in plain text" "$(cat "$PG/reason")" \
  "End your turn on one plain-text reply, with no tool call: the view below word for word"
assert_contains "not to use the ask tool for it" "$(cat "$PG/reason")" "Do not ask this question with the ask tool"
assert_contains "naming view.md" "$(cat "$PG/reason")" "$PG/batch/view.md"
assert_eq "its top-level decision is block" \
  "$(jq -n --arg t "$T" '{tool_name:"AskUserQuestion", transcript_path:$t, tool_use_id:"x"}' | "$PASTE" | jq -r '.decision')" block

T2="$PG/asked.jsonl"; cp "$T" "$T2"
pg_ask "$T2" toolu_a1
pg_result "$T2" toolu_a1 "Blocked by the orchestrator" true
pg_text "$T2" "Here is the batch."
assert_eq "a second ask with still no paste is refused too" "$(pg_decide "$T2" toolu_a2)" deny
assert_contains "with the view in its reason" "$(cat "$PG/reason")" "$(cat "$PG/batch/view.md")"

T3="$PG/same-response.jsonl"; cp "$T" "$T3"
pg_text "$T3" "$(cat "$PG/batch/view.md")"
pg_ask "$T3" toolu_now
assert_eq "the view pasted in the ask's own response, its tool_use already written: allowed" \
  "$(pg_decide "$T3" toolu_now)" allow

T3b="$PG/earlier-response.jsonl"; cp "$T2" "$T3b"
pg_text "$T3b" "The view:

$(cat "$PG/batch/view.md")

Which way?"
pg_ask "$T3b" toolu_a2
pg_result "$T3b" toolu_a2 "The user wants to clarify these questions." true
pg_text "$T3b" "Understood."
assert_eq "the view pasted in an earlier response after the pass line: allowed" "$(pg_decide "$T3b" toolu_a3)" allow

T3c="$PG/split.jsonl"; cp "$T" "$T3c"
pg_text "$T3c" "## The batch

1. Fidelity: name the seam"
pg_text "$T3c" "### Minor edits

2. Consistency: one term"
assert_eq "a view split across two text blocks is refused" "$(pg_decide "$T3c")" deny

T3d="$PG/rewrapped.jsonl"; cp "$T" "$T3d"
pg_text "$T3d" "  ## The   batch
1. Fidelity:
name	the seam
### Minor edits
2.  Consistency:   one term  "
assert_eq "the view pasted with different whitespace (re-wrapped, extra spaces, a tab): allowed" "$(pg_decide "$T3d")" allow

T3e="$PG/partial.jsonl"; cp "$T" "$T3e"
pg_text "$T3e" "## The batch

1. Fidelity: name the seam

### Minor edits"
assert_eq "the view with one non-blank line missing is refused" "$(pg_decide "$T3e")" deny

T3f="$PG/before.jsonl"
pg_text "$T3f" "$(cat "$PG/batch/view.md")"
pg_check "$T3f" toolu_c1 batch "$PG/batch/view.md"
assert_eq "the view pasted only before the arming pass line is refused" "$(pg_decide "$T3f")" deny

T4="$PG/rearmed.jsonl"; cp "$T3" "$T4"
pg_result "$T4" toolu_now "User has answered your questions: show 2"
pg_check "$T4" toolu_c2 batch "$PG/full/view.md"
assert_eq "a re-arming check --full after a pasted batch view: refused" "$(pg_decide "$T4" toolu_a3)" deny
assert_contains "with the full items' view in the reason" "$(cat "$PG/reason")" "$(cat "$PG/full/view.md")"
assert_not_contains "not the batch view" "$(cat "$PG/reason")" "## The batch"
pg_text "$T4" "$(cat "$PG/full/view.md")"
assert_eq "then allowed once the full view is pasted" "$(pg_decide "$T4" toolu_a3)" allow

T5="$PG/applied.jsonl"; cp "$T" "$T5"
pg_bash "$T5" toolu_p1 "bash \"\$ORCH\" spec-review apply .orchestrator/spec-review/7 recommended"
pg_result "$T5" toolu_p1 "orch: refused" true
assert_eq "a spec-review apply after the check disarms, whatever its exit status" "$(pg_decide "$T5")" allow

T6="$PG/tickets.jsonl"; cp "$T5" "$T6"
pg_check "$T6" toolu_c3 tickets "$PG/tickets/view.md"
assert_eq "an apply then a check --tickets with an affected ticket: refused" "$(pg_decide "$T6")" deny
assert_contains "with the ticket view in the reason" "$(cat "$PG/reason")" "$(cat "$PG/tickets/view.md")"
assert_contains "naming the question generically" "$(cat "$PG/reason")" "then the question, its answer words spelled out"
assert_not_contains "and not the batch question" "$(cat "$PG/reason")" "batch question"

T7="$PG/no-ticket.jsonl"; cp "$T5" "$T7"
pg_bash "$T7" toolu_c4 "bash \"\$ORCH\" spec-review check .orchestrator/spec-review/7 --tickets"
pg_result "$T7" toolu_c4 "No open ticket is affected.
tickets.md passes: no open ticket affected"
assert_eq "a check --tickets with no view does not arm: allowed" "$(pg_decide "$T7")" allow

pg_text "$T6" "$(cat "$PG/tickets/view.md")"
assert_eq "then allowed once the ticket view is pasted" "$(pg_decide "$T6")" allow

T8="$PG/blob.jsonl"; cp "$T" "$T8"
jq -nc --arg v "$(cat "$PG/batch/view.md")" '{type:"api-request-blob", message:{role:"assistant", content:[{type:"text", text:$v},
  {type:"tool_use", id:"toolu_b", name:"Bash", input:{command:"bash \"$ORCH\" spec-review apply .orchestrator/spec-review/7 recommended"}}]}}' >>"$T8"
jq -nc --arg v "$(cat "$PG/batch/view.md")" '{type:"assistant", message:{content:[{type:"text", text:$v}]}}' | cut -c2- >>"$T8"
assert_eq "a request blob's copy of the paste and the apply, and a line that is not JSON, do not count: refused" \
  "$(pg_decide "$T8")" deny
pg_text "$T8" "$(cat "$PG/batch/view.md")"
assert_eq "a paste after a line that is not JSON still counts: allowed" "$(pg_decide "$T8")" allow

T8b="$PG/unrelated-ask.jsonl"; cp "$T" "$T8b"
pg_text "$T8b" "Before the batch: which branch should this land on?"
assert_eq "an ask unrelated to the spec review, made while armed, is refused like any other" "$(pg_decide "$T8b")" deny

assert_eq "a tool other than AskUserQuestion is allowed" "$(pg_decide "$T" toolu_now Bash)" allow

# Fail open.
assert_eq "a missing transcript allows" "$(pg_decide "$PG/none.jsonl")" allow
assert_eq "no transcript_path allows" "$(pg_decide "")" allow
assert_eq "a payload that is not JSON allows" "$(printf 'not json' | "$PASTE" 2>/dev/null; echo "exit $?")" "exit 0"
assert_eq "a JSON payload that is not an object allows" "$(printf '[1]' | "$PASTE" 2>/dev/null; echo "exit $?")" "exit 0"
if [ "$(id -u)" -eq 0 ]; then
  ok "an unreadable transcript allows (skipped as root)"
else
  cp "$T" "$PG/unreadable.jsonl"; chmod 000 "$PG/unreadable.jsonl"
  assert_eq "an unreadable transcript allows" "$(pg_decide "$PG/unreadable.jsonl")" allow
  chmod 600 "$PG/unreadable.jsonl"
fi
T9="$PG/deleted.jsonl"
pg_check "$T9" toolu_c5 batch "$PG/gone/view.md"
assert_eq "a pass line naming a deleted view.md allows" "$(pg_decide "$T9")" allow
: >"$PG/empty/view.md"
T10="$PG/empty.jsonl"
pg_check "$T10" toolu_c6 batch "$PG/empty/view.md"
assert_eq "a pass line naming an empty view.md allows" "$(pg_decide "$T10")" allow
T11="$PG/unrelated.jsonl"
pg_text "$T11" "Which approach do you prefer?"
pg_bash "$T11" toolu_u1 "git status"
pg_result "$T11" toolu_u1 "nothing to commit"
assert_eq "a transcript with no spec-review activity allows" "$(pg_decide "$T11")" allow
if [ "$(id -u)" -eq 0 ]; then
  ok "a pass line naming an unreadable view.md allows (skipped as root)"
else
  mkdir "$PG/locked"; cp "$PG/batch/view.md" "$PG/locked/view.md"
  T13="$PG/locked.jsonl"
  pg_check "$T13" toolu_c8 batch "$PG/locked/view.md"
  chmod 000 "$PG/locked/view.md"
  assert_eq "a pass line naming an unreadable view.md allows" "$(pg_decide "$T13")" allow
  chmod 600 "$PG/locked/view.md"
fi
# The module seam: paste_guard_instruction's view argument, with the module
# sourced in a subshell.
pg_instr="$( (source "$DIR/paste-guard.sh"; unset view paste_guard_view; paste_guard_instruction "$PG/tickets/view.md") )"
assert_contains "paste_guard_instruction names the view.md it is given" "$pg_instr" "$PG/tickets/view.md"
pg_vw="$(cat "$PG/tickets/view.md")"
assert_eq "and ends on its contents" "${pg_instr: -${#pg_vw}}" "$pg_vw"
# The re-read window, with a `sleep` stub on PATH in place of the wall clock:
# the hook sleeps between reads, so the stub runs where Claude Code would be
# writing a response's text block after PreToolUse fires. In the first case
# the stub appends the paste on its first call, so it lands between two reads,
# and with the window at its full length the ask is allowed. In the second, an
# ask whose view is already in chat is allowed on the first read: the stub
# records each call, and is never called.
mkdir "$PG/stub"
cat >"$PG/stub/sleep" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$PG_SLEEP_LOG"
if [ -n "${PG_SLEEP_PASTE:-}" ] && [ ! -e "$PG_SLEEP_PASTE.done" ]; then
  cat "$PG_SLEEP_PASTE" >>"$PG_SLEEP_INTO"; : >"$PG_SLEEP_PASTE.done"
fi
STUB
chmod +x "$PG/stub/sleep"
T12="$PG/late.jsonl"; cp "$T" "$T12"
pg_text "$PG/paste.jsonl" "$(cat "$PG/batch/view.md")"
assert_eq "a paste appended within the window is seen: allowed" \
  "$(PATH="$PG/stub:$PATH" PG_SLEEP_LOG="$PG/sleep-late.log" PG_SLEEP_PASTE="$PG/paste.jsonl" PG_SLEEP_INTO="$T12" \
    ORCH_PASTE_GUARD_WAIT='' pg_decide "$T12")" allow
assert_eq "with the full window, an ask whose view is already in chat is allowed" \
  "$(PATH="$PG/stub:$PATH" PG_SLEEP_LOG="$PG/sleep-first.log" ORCH_PASTE_GUARD_WAIT='' pg_decide "$T3")" allow
if [ -e "$PG/sleep-first.log" ]; then bad "and on the first read" "slept: $(tr '\n' ' ' <"$PG/sleep-first.log")"
else ok "and on the first read"; fi

assert_eq "hooks.json registers hook-paste-guard.sh under PreToolUse with matcher AskUserQuestion" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "AskUserQuestion") | .hooks[]?.command | select(test("hook-paste-guard\\.sh"))] | length' "$DIR/../hooks/hooks.json")" 1

echo
echo "hook-paste-stop-guard (#1421)"

# The Stop guard refuses to end the turn while the paste guard is armed,
# unless one assistant text block written after the arming pass line - the same
# window as the paste guard's - holds every non-blank line of the view
# (hook-paste-stop-guard.sh's header). It reuses the paste guard's fixture
# transcripts and helpers above; ORCH_PASTE_GUARD_WAIT=0 still holds.

# sg_human <transcript> <content-json> [isMeta]: a user entry of <content-json>,
# marked isMeta when the third argument is true.
sg_human() {
  jq -nc --argjson c "$2" --argjson m "${3:-false}" '{type:"user", message:{role:"user", content:$c}} + (if $m then {isMeta:true} else {} end)' >>"$1"
}
# sg_decide <transcript-or-empty> [stop_hook_active]: the Stop guard's
# decision - block, allow (no output), or the exit status when it is not 0 -
# with the block reason left in $PG/reason.
sg_decide() {
  local out st
  out="$(jq -n --arg t "$1" --argjson a "${2:-false}" \
    '{hook_event_name:"Stop", session_id:"sg", cwd:"/tmp", transcript_path:$t, stop_hook_active:$a}' \
    | "$STOP" 2>/dev/null)"; st=$?
  printf '%s' "$out" | jq -r '.reason // ""' >"$PG/reason" 2>/dev/null
  if [ "$st" -ne 0 ]; then echo "exit $st"
  elif [ -z "$out" ]; then echo allow
  else printf '%s' "$out" | jq -r '.decision'
  fi
}

assert_eq "armed, a final reply without the view is refused" "$(sg_decide "$T")" block
assert_contains "with the view in the reason" "$(cat "$PG/reason")" "$(cat "$PG/batch/view.md")"
assert_contains "and the instruction to end the turn on the view and the question in plain text" "$(cat "$PG/reason")" \
  "End your turn on one plain-text reply, with no tool call: the view below word for word"
assert_contains "naming view.md" "$(cat "$PG/reason")" "$PG/batch/view.md"
assert_eq "its output names no PreToolUse decision" \
  "$(jq -n --arg t "$T" '{transcript_path:$t}' | "$STOP" | jq -r '.hookSpecificOutput // "none"')" none

# A human message after the arming pass line disarms both guards; a re-run
# check arms them again (#1917).
D1="$PG/disarm-unpasted.jsonl"; cp "$T" "$D1"
sg_human "$D1" '"recommended but not 4"'
pg_text "$D1" "Apply as recommended, except item 4 declined?"
assert_eq "the view never pasted, then a near-miss answer, then the confirmation ask: allowed" "$(pg_decide "$D1")" allow
D1b="$PG/disarm-blocks.jsonl"; cp "$T" "$D1b"
sg_human "$D1b" '[{"type":"text","text":"what does item 2 change?"}]'
pg_text "$D1b" "Item 2 makes the term consistent."
assert_eq "the view never pasted, then a human message of text blocks, then an unrelated ask: allowed" "$(pg_decide "$D1b")" allow
assert_eq "and the Stop guard allows" "$(sg_decide "$D1b")" allow
D0="$PG/disarm-midturn.jsonl"; cp "$T" "$D0"
sg_human "$D0" '"never mind, drop it"'
assert_eq "mid-turn fail-open: a pass line, a human message, then Stop with no paste: the Stop guard allows" "$(sg_decide "$D0")" allow
D2="$PG/disarm-rerun.jsonl"; cp "$D1" "$D2"
pg_check "$D2" toolu_d2 batch "$PG/batch/view.md"
assert_eq "a check re-run after the human message arms again: an ask without a paste is refused" "$(pg_decide "$D2")" deny
assert_eq "and the Stop guard blocks" "$(sg_decide "$D2")" block
D3="$PG/disarm-slash.jsonl"; cp "$T" "$D3"
sg_human "$D3" '"<command-name>/orchestrator:abort</command-name>"'
pg_text "$D3" "Aborted."
assert_eq "a slash-command entry after the pass line: an unrelated ask is allowed" "$(pg_decide "$D3")" allow
assert_eq "and the Stop guard allows" "$(sg_decide "$D3")" allow
D4="$PG/disarm-not-human.jsonl"; cp "$T" "$D4"
pg_bash "$D4" toolu_d4 "git status"
pg_result "$D4" toolu_d4 "nothing to commit"
sg_human "$D4" '"Base directory for this skill: /plugin/skills/orch-spec-review"' true
sg_human "$D4" '[{"type":"text","text":"<local-command-caveat>Caveat</local-command-caveat>"}]' true
pg_entry "$D4" user '[{"type":"tool_result","tool_use_id":"toolu_d4","content":"ok"},{"type":"text","text":"note"}]'
pg_entry "$D4" user '[{"type":"image","source":{"type":"base64","media_type":"image/png","data":"AA=="}}]'
pg_text "$D4" "Working."
assert_eq "none of a tool result, an isMeta string or text-block entry, a tool_result with text, or a non-text-only array after the pass line disarms: an ask is refused" "$(pg_decide "$D4")" deny
assert_eq "and the Stop guard blocks" "$(sg_decide "$D4")" block

assert_eq "a final reply holding the view only split across two text blocks: refused" "$(sg_decide "$T3c")" block

S5="$PG/stop-rerun.jsonl"; cp "$T" "$S5"
pg_text "$S5" "$(cat "$PG/batch/view.md")"
pg_check "$S5" toolu_c7 batch "$PG/batch/view.md"
assert_eq "the view pasted before a re-run check's pass line, none after: refused" "$(sg_decide "$S5")" block

assert_eq "stop_hook_active set: allowed" "$(sg_decide "$T" true)" allow

assert_eq "a final reply holding the view re-wrapped, whitespace normalised: allowed" "$(sg_decide "$T3d")" allow
assert_eq "a spec-review apply after the check disarms: allowed" "$(sg_decide "$T5")" allow
# One Bash call that runs check then apply (#1671): the apply wins within its
# own call, so its pass-line result does not arm.
pg_combined() {
  pg_bash "$1" "$2" "bash \"\$ORCH\" spec-review check .orchestrator/spec-review/7 >/dev/null && bash \"\$ORCH\" spec-review apply .orchestrator/spec-review/7 recommended --unattended"
  pg_result "$1" "$2" "$(cat "$PG/batch/view.md")
$(pg_pass_line batch "$PG/batch/view.md")"
}
TC1="$PG/combined.jsonl"
pg_text "$TC1" "Running the lenses."
pg_combined "$TC1" toolu_k1
pg_text "$TC1" "Done."
assert_eq "a check and apply in one call, no earlier arming: the ask is allowed" "$(pg_decide "$TC1")" allow
assert_eq "and the Stop guard allows" "$(sg_decide "$TC1")" allow
TC2="$PG/combined-after-check.jsonl"; cp "$T" "$TC2"
pg_combined "$TC2" toolu_k2
pg_text "$TC2" "Done."
assert_eq "a check and apply in one call after an arming check: the ask is allowed" "$(pg_decide "$TC2")" allow
assert_eq "and the Stop guard allows" "$(sg_decide "$TC2")" allow
TC3="$PG/combined-then-check.jsonl"; cp "$TC2" "$TC3"
pg_check "$TC3" toolu_k3 batch "$PG/batch/view.md"
assert_eq "a later separate check re-arms: the ask is refused" "$(pg_decide "$TC3")" deny
assert_eq "and the Stop guard blocks" "$(sg_decide "$TC3")" block
TC4="$PG/combined-other-id.jsonl"; cp "$TC2" "$TC4"
pg_result "$TC4" toolu_other "$(pg_pass_line batch "$PG/batch/view.md")"
assert_eq "a pass-line result with another tool_use_id arms" "$(pg_decide "$TC4")" deny
TC5="$PG/combined-no-id.jsonl"; cp "$TC2" "$TC5"
pg_entry "$TC5" user "$(jq -nc --arg t "$(pg_pass_line batch "$PG/batch/view.md")" '[{type:"tool_result", content:$t}]')"
assert_eq "a pass-line result with no tool_use_id arms" "$(pg_decide "$TC5")" deny


# The re-read window, with the paste guard's `sleep` stub: it appends the
# final reply on its first call, between two reads.
S6="$PG/stop-late.jsonl"; cp "$T" "$S6"
pg_text "$PG/stop-paste.jsonl" "$(cat "$PG/batch/view.md")"
assert_eq "a final reply holding the view written within the window: allowed" \
  "$(PATH="$PG/stub:$PATH" PG_SLEEP_LOG="$PG/sleep-stop.log" PG_SLEEP_PASTE="$PG/stop-paste.jsonl" PG_SLEEP_INTO="$S6" \
    ORCH_PASTE_GUARD_WAIT='' sg_decide "$S6")" allow

# Fail open.
assert_eq "a payload that is not JSON allows" "$(printf 'not json' | "$STOP" 2>/dev/null; echo "exit $?")" "exit 0"
assert_eq "a transcript with no arming pass line allows" "$(sg_decide "$T11")" allow
unset ORCH_PASTE_GUARD_WAIT
rm -rf "$PG"

assert_eq "hooks.json registers hook-paste-stop-guard.sh under Stop" \
  "$(jq -r '[.hooks.Stop[]? | .hooks[]?.command | select(test("hook-paste-stop-guard\\.sh"))] | length' "$DIR/../hooks/hooks.json")" 1

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

# --- edit width hook (scripts/dev/hook-edit-width.sh)
EDIT_HOOK="$ROOT/scripts/dev/hook-edit-width.sh"
EW="$(mktemp -d)"
# wide is 81 columns, one past the rule; edge is 80, the widest a line may be.
wide="$(printf 'word %.0s' $(seq 1 16))x"
edge="$(printf 'word %.0s' $(seq 1 16))"
git -C "$EW" init -q
mkdir -p "$EW/docs" "$EW/other" "$EW/scripts"
printf '# T\n\n%s\n' "$wide" >"$EW/docs/wide.md"
printf '# T\n\n%s\n' "$edge" >"$EW/docs/ok.md"
printf '%s\n' "$wide" >"$EW/other/wide.md"
printf '#!/usr/bin/env bash\nunused=1\necho hi\n' >"$EW/scripts/warn.sh"
printf '#!/usr/bin/env bash\necho ok\n' >"$EW/scripts/ok.sh"
# run_edit_hook FILE [PATH]: the hook on an edit of FILE; sets ew_rc, ew_out.
run_edit_hook() {
  ew_out="$(jq -n --arg f "$1" '{tool_input:{file_path:$f}}' \
    | PATH="${2:-$PATH}" bash "$EDIT_HOOK" 2>&1)"
  ew_rc=$?
}
run_edit_hook "$EW/docs/wide.md"
assert_eq "edit hook: wide covered md exits 2" "$ew_rc" 2
assert_contains "edit hook: names file:line" "$ew_out" "docs/wide.md:3"
run_edit_hook "$EW/docs/ok.md"
assert_eq "edit hook: clean covered md exits 0" "$ew_rc" 0
assert_empty "edit hook: clean covered md is silent" "$ew_out"
run_edit_hook "$EW/other/wide.md"
assert_eq "edit hook: uncovered wide md exits 0" "$ew_rc" 0
assert_empty "edit hook: uncovered md is silent" "$ew_out"
if command -v shellcheck >/dev/null 2>&1; then
  run_edit_hook "$EW/scripts/warn.sh"
  assert_eq "edit hook: shellcheck warning exits 2" "$ew_rc" 2
  assert_contains "edit hook: names the warning" "$ew_out" "SC2034"
  run_edit_hook "$EW/scripts/ok.sh"
  assert_eq "edit hook: clean sh exits 0" "$ew_rc" 0
elif [ -n "${CI:-}" ]; then
  bad "edit hook: shellcheck cases" "shellcheck is not on PATH under CI"
else
  skip "edit hook: shellcheck cases" "shellcheck is not on PATH"
fi
# PATH without shellcheck: symlink only what the hook needs. The case itself
# needs no shellcheck, so it runs on every machine.
NOSC="$(mktemp -d)"
for t in bash jq git awk sed cat dirname basename env grep tr sort wc find head cut; do
  p="$(command -v "$t")" && ln -s "$p" "$NOSC/$t"
done
run_edit_hook "$EW/scripts/warn.sh" "$NOSC"
assert_eq "edit hook: no shellcheck exits 0" "$ew_rc" 0
assert_empty "edit hook: no shellcheck is silent" "$ew_out"
NOREPO="$(mktemp -d)"
mkdir -p "$NOREPO/docs"
printf '%s\n' "$wide" >"$NOREPO/docs/wide.md"
run_edit_hook "$NOREPO/docs/wide.md"
assert_eq "edit hook: file outside a repo exits 0" "$ew_rc" 0
assert_empty "edit hook: file outside a repo is silent" "$ew_out"
run_edit_hook "$EW/docs/missing.md"
assert_eq "edit hook: missing file exits 0" "$ew_rc" 0
ew_out="$(printf 'not json' | bash "$EDIT_HOOK" 2>&1)"; ew_rc=$?
assert_eq "edit hook: malformed stdin exits 0" "$ew_rc" 0
assert_empty "edit hook: malformed stdin is silent" "$ew_out"
ew_out="$(printf '{"tool_input":{}}' | bash "$EDIT_HOOK" 2>&1)"; ew_rc=$?
assert_eq "edit hook: no file_path exits 0" "$ew_rc" 0
assert_empty "edit hook: no file_path is silent" "$ew_out"
# A file in a second repo is judged by its own root, from another repo's cwd.
EW2="$(mktemp -d)"
git -C "$EW2" init -q
mkdir -p "$EW2/docs"
printf '%s\n' "$wide" >"$EW2/docs/wide.md"
ew_out="$(cd "$EW" && jq -n --arg f "$EW2/docs/wide.md" \
  '{tool_input:{file_path:$f}}' | bash "$EDIT_HOOK" 2>&1)"; ew_rc=$?
assert_eq "edit hook: second repo's docs wide exits 2" "$ew_rc" 2
# Registration.
SETTINGS="$ROOT/.claude/settings.json"
reg="$(jq -r '.hooks.PostToolUse[]? | select(.matcher == "Edit|Write|MultiEdit")
  | .hooks[].command' "$SETTINGS" 2>/dev/null)"
assert_contains "edit hook: registered as PostToolUse Edit|Write|MultiEdit" \
  "$reg" 'scripts/dev/hook-edit-width.sh'
assert_contains "edit hook: runs through CLAUDE_PROJECT_DIR" "$reg" 'CLAUDE_PROJECT_DIR'
assert_not_contains "edit hook: absent from hooks/hooks.json" \
  "$(cat "$ROOT/hooks/hooks.json")" 'hook-edit-width'

# --- bash stdin hook (scripts/hook-bash-stdin.sh, #2001)
BSTDIN="$DIR/hook-bash-stdin.sh"
# bash_hook_event MODE AGENT_TYPE COMMAND: a Bash PreToolUse payload; an empty
# AGENT_TYPE leaves the field out.
bash_hook_event() {
  jq -n --arg m "$1" --arg a "$2" --arg c "$3" \
    '{hook_event_name:"PreToolUse", tool_name:"Bash", permission_mode:$m, tool_input:{command:$c, timeout:5000, description:"d"}}
     + (if $a == "" then {} else {agent_type:$a} end)'
}
# bash_hook_run SCRIPT AUTOPILOT: the Bash hook SCRIPT on stdin with
# ORCH_AUTOPILOT set to AUTOPILOT (empty: unset).
bash_hook_run() {
  if [ -n "$2" ]; then ORCH_AUTOPILOT="$2" bash "$1"; else env -u ORCH_AUTOPILOT bash "$1"; fi
}
# bash_hook_scan SCRIPT MODE COMMAND: the hook's output for COMMAND from an
# in-scope agent under MODE.
bash_hook_scan() { bash_hook_event "$2" orch-implementer "$3" | bash_hook_run "$1" ""; }
BS_PREFIX=$'exec </dev/null\n'
for scope in "orchestrator:orch-implementer|" "orch-implementer|" "|1"; do
  bs_agent="${scope%|*}"; bs_auto="${scope#*|}"
  bs_label="agent_type '$bs_agent' autopilot '$bs_auto'"
  bs_out="$(bash_hook_event bypassPermissions "$bs_agent" 'cat; echo done' | bash_hook_run "$BSTDIN" "$bs_auto")"
  assert_eq "bash stdin hook: $bs_label rewrites the command" \
    "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$bs_out")" "${BS_PREFIX}cat; echo done"
  assert_eq "bash stdin hook: $bs_label keeps the other tool_input fields" \
    "$(jq -c '.hookSpecificOutput.updatedInput | del(.command)' <<<"$bs_out")" '{"timeout":5000,"description":"d"}'
  assert_eq "bash stdin hook: $bs_label allows" \
    "$(bash_hook_decision "$bs_out")" allow
done
bs_out="$(bash_hook_event bypassPermissions orch-implementer "${BS_PREFIX}cat; echo done" | bash_hook_run "$BSTDIN" "")"
assert_eq "bash stdin hook: an already-prefixed command is not prefixed twice" \
  "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$bs_out")" "${BS_PREFIX}cat; echo done"
assert_eq "bash stdin hook: an already-prefixed command is still allowed" \
  "$(bash_hook_decision "$bs_out")" allow
for mode in bypassPermissions default; do
  for bs_agent in "" Explore; do
    bs_out="$(bash_hook_event "$mode" "$bs_agent" cat | bash_hook_run "$BSTDIN" "")"; bs_rc=$?
    assert_empty "bash stdin hook: out of scope '$bs_agent' under $mode prints nothing" "$bs_out"
    assert_eq "bash stdin hook: out of scope '$bs_agent' under $mode exits 0" "$bs_rc" 0
  done
done
# Deny of plain stdin reads under a non-bypass mode (#2002).
for bs_cmd in 'cat' 'cat -' 'read x' 'python' 'python3' 'python3 -' 'node' 'node -' 'bash -s' 'sh -s' \
  'python3 - x' 'node - --flag' 'python3 -u' 'node --input-type=module' 'python3 -v' 'cat -n' 'FOO=1 cat' 'echo a; cat' 'true && cat' 'false || read x' $'echo a\ncat' \
  'cat >out' 'cat > f' 'cat 2>/dev/null' 'python3 >log' 'cat &>o' 'cat >> f' '>o cat' 'cat >& out' 'cat 2>& f' \
  $'\ncat' $'cd x &&\ncat' $'echo a;\n\ncat' 'cat;' '>o; cat'; do
  bs_out="$(bash_hook_scan "$BSTDIN" default "$bs_cmd")"
  assert_eq "bash stdin hook: default denies '${bs_cmd//$'\n'/\\n}'" \
    "$(bash_hook_decision "$bs_out")" deny
done
bs_out="$(bash_hook_scan "$BSTDIN" acceptEdits cat)"
assert_eq "bash stdin hook: acceptEdits denies 'cat'" \
  "$(bash_hook_decision "$bs_out")" deny
bs_out="$(bash_hook_scan "$BSTDIN" default 'echo a; cat -')"
assert_contains "bash stdin hook: the deny reason names the matched part" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$bs_out")" "'cat -'"
assert_contains "bash stdin hook: the deny reason says how to supply input" \
  "$(jq -r '.reason' <<<"$bs_out")" 'heredoc, <<<, a pipe or </dev/null'
for bs_cmd in $'cat <<EOF\nx\nEOF' 'cat <<< x' 'echo x | cat' 'cat | grep x' 'cat < f' 'cat file' \
  'python3 script.py' $'cat <<EOF\ncat\nread x\nEOF' $'echo "a\ncat\nb"' 'echo "a; cat"' \
  "git commit -m 'x && read'" 'git status' 'read x </dev/null' 'echo a # ; cat' 'cat file -n' $'echo a \\\n  cat' \
  $'echo x |\n  cat' $'git log |\n  read x' 'cat >out file' $'cat <<\\EOF\ncat\nEOF' 'cat --help' 'cat --version' 'cat -n --help' \
  'python3 -h' 'python3 -V' 'python3 --help' 'python3 --version' 'node -h' 'node -v' 'node --help' 'node --version' \
  "python3 -c 'print(1)'" 'python3 -m json.tool f'; do
  bs_out="$(bash_hook_scan "$BSTDIN" default "$bs_cmd")"
  assert_empty "bash stdin hook: default passes '${bs_cmd//$'\n'/\\n}'" "$bs_out"
done
bs_out="$(bash_hook_event default "" cat | bash_hook_run "$BSTDIN" 1)"
assert_eq "bash stdin hook: autopilot 'cat' under default is denied" \
  "$(bash_hook_decision "$bs_out")" deny
bs_out="$(bash_hook_event bypassPermissions orch-implementer cat | jq 'del(.tool_input.command)' | bash_hook_run "$BSTDIN" "")"; bs_rc=$?
assert_empty "bash stdin hook: no command prints nothing" "$bs_out"
assert_eq "bash stdin hook: no command exits 0" "$bs_rc" 0
bs_out="$(echo 'not json {' | bash_hook_run "$BSTDIN" 1)"; bs_rc=$?
assert_empty "bash stdin hook: a non-JSON payload prints nothing" "$bs_out"
assert_eq "bash stdin hook: a non-JSON payload exits 0" "$bs_rc" 0
# Seam 2: the rewritten command, run by bash with stdin held open.
# bs_rewritten COMMAND: the command the hook rewrites COMMAND into.
bs_rewritten() {
  bash_hook_event bypassPermissions orch-implementer "$1" | bash_hook_run "$BSTDIN" "" | jq -r '.hookSpecificOutput.updatedInput.command'
}
# bs_run_rewritten COMMAND: prints the rewrite of COMMAND run under timeout 3
# with stdin held open on the section's FIFO; leaves bash's exit status.
bs_fifo="$TMPDIR/bs-open.fifo"; mkfifo "$bs_fifo"
bs_run_rewritten() { timeout 3 bash -c "$(bs_rewritten "$1")" <>"$bs_fifo"; }
bs_run_out="$(bs_run_rewritten 'cat; echo done')"; bs_rc=$?
assert_eq "bash stdin hook: rewritten 'cat; echo done' returns with stdin held open" "$bs_rc" 0
assert_eq "bash stdin hook: rewritten 'cat; echo done' prints done" "$bs_run_out" "done"
assert_eq "bash stdin hook: a heredoc still reaches cat" "$(bs_run_rewritten $'cat <<EOT\nheredoc\nEOT')" heredoc
assert_eq "bash stdin hook: a here-string still reaches cat" "$(bs_run_rewritten 'cat <<<here-string')" here-string
assert_eq "bash stdin hook: piped input still reaches cat" "$(bs_run_rewritten 'echo piped | cat')" piped
assert_eq "hooks.json registers hook-bash-stdin.sh under PreToolUse with matcher Bash" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command | select(test("^bash .*hook-bash-stdin\\.sh"))] | length' "$ROOT/hooks/hooks.json")" 1

# --- bash poll hook (scripts/hook-bash-poll.sh, #2085)
BPOLL="$DIR/hook-bash-poll.sh"
bp_poll='until ! pgrep -f x; do sleep 5; done'
for mode in default acceptEdits plan dontAsk bypassPermissions; do
  bp_out="$(bash_hook_scan "$BPOLL" "$mode" "$bp_poll")"
  assert_eq "bash poll hook: $mode denies a pgrep poll" "$(bash_hook_decision "$bp_out")" deny
done
bp_out="$(bash_hook_event default orch-implementer "$bp_poll" | jq 'del(.permission_mode)' | bash_hook_run "$BPOLL" "")"
assert_eq "bash poll hook: no permission_mode denies a pgrep poll" "$(bash_hook_decision "$bp_out")" deny
for bp_cmd in 'pkill -f y' 'echo $(pgrep x)' 'echo `pgrep x`' 'ls | xargs pkill' 'timeout 5 pkill y' \
  'while pgrep x; do sleep 5; done' 'true|pgrep x' '/usr/bin/pgrep x' '/usr/local/bin/pkill x' 'grep -n pgrep file' \
  $'echo a\npgrep x' 'pgrep'; do
  bp_out="$(bash_hook_scan "$BPOLL" default "$bp_cmd")"
  assert_eq "bash poll hook: denies '${bp_cmd//$'\n'/\\n}'" "$(bash_hook_decision "$bp_out")" deny
done
bp_out="$(bash_hook_event default orchestrator:orch-implementer 'pgrep x' | bash_hook_run "$BPOLL" "")"
assert_eq "bash poll hook: agent_type 'orchestrator:orch-implementer' is denied" "$(bash_hook_decision "$bp_out")" deny
bp_out="$(bash_hook_event default "" 'pgrep x' | bash_hook_run "$BPOLL" 1)"
assert_eq "bash poll hook: autopilot with an empty agent_type is denied" "$(bash_hook_decision "$bp_out")" deny
bp_out="$(bash_hook_scan "$BPOLL" default 'pgrep x')"
assert_contains "bash poll hook: the reason gives the foreground rerun" \
  "$(jq -r '.hookSpecificOutput.permissionDecisionReason' <<<"$bp_out")" 'timeout: 600000'
assert_contains "bash poll hook: the reason names the completion notice" \
  "$(jq -r '.reason' <<<"$bp_out")" 'completion notice'
for bp_agent in "" Explore; do
  bp_out="$(bash_hook_event default "$bp_agent" 'pgrep x' | bash_hook_run "$BPOLL" "")"; bp_rc=$?
  assert_empty "bash poll hook: out of scope '$bp_agent' prints nothing" "$bp_out"
  assert_eq "bash poll hook: out of scope '$bp_agent' exits 0" "$bp_rc" 0
done
for bp_cmd in 'grep "pgrep -f" file' $'cat <<EOF\npgrep x\nEOF' 'ls -l' 'killall x' "bash -c 'pgrep x'" \
  '[ -n "$(pgrep -f x)" ]' '[ -n "`pgrep -f x`" ]' 'sleep 5 # pgrep'; do
  bp_out="$(bash_hook_scan "$BPOLL" default "$bp_cmd")"; bp_rc=$?
  assert_empty "bash poll hook: passes '${bp_cmd//$'\n'/\\n}'" "$bp_out"
  assert_eq "bash poll hook: '${bp_cmd//$'\n'/\\n}' exits 0" "$bp_rc" 0
done
bp_out="$(bash_hook_scan "$BPOLL" default "$(printf 'echo %9000s; pgrep x' '')")"; bp_rc=$?
assert_empty "bash poll hook: a command over 8 KB is not scanned" "$bp_out"
assert_eq "bash poll hook: a command over 8 KB exits 0" "$bp_rc" 0
bp_out="$(bash_hook_event default orch-implementer pgrep | jq 'del(.tool_input.command)' | bash_hook_run "$BPOLL" "")"; bp_rc=$?
assert_empty "bash poll hook: no command prints nothing" "$bp_out"
assert_eq "bash poll hook: no command exits 0" "$bp_rc" 0
bp_out="$(echo 'not json {' | bash_hook_run "$BPOLL" 1)"; bp_rc=$?
assert_empty "bash poll hook: a non-JSON payload prints nothing" "$bp_out"
assert_eq "bash poll hook: a non-JSON payload exits 0" "$bp_rc" 0
assert_eq "hooks.json registers hook-bash-poll.sh under PreToolUse with matcher Bash" \
  "$(jq -r '[.hooks.PreToolUse[]? | select(.matcher == "Bash") | .hooks[]?.command | select(test("^bash .*hook-bash-poll\\.sh"))] | length' "$ROOT/hooks/hooks.json")" 1

# >>> summary
tally_summary
