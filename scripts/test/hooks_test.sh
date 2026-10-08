#!/usr/bin/env bash
#
# Tests for the four hook scripts.
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
START="$DIR/hook-session-start.sh"
COMMON="$DIR/hook-common.sh"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines,
# section headers and the summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
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

# The temp root, created before anything else: TMPDIR is exported as it, so
# every mktemp below lands inside it, and the hooks' markers too. The EXIT trap
# leaves the root, makes it writable again (a run killed while RO_TMP is mode
# 500), removes it, and keeps the exit status. An INT or TERM exits 130 through
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
trap 'exit 130' INT TERM

# >>> checks
REPO="$(mktemp -d)"
git -C "$REPO" init -q
mkdir -p "$REPO/docs/agents" "$REPO/docs/adr"

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

# shellcheck source=../hook-common.sh
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
assert_contains "offers Blueprint only as an option" "$out" "Blueprint only"
# The closing question offers exactly three options (#237, #330): count its
# numbered option lines, not only that each option is present.
count_closing_options() { printf '%s' "$1" | jq -r '.additionalContext' | grep -cE '^ +[0-9]+\. '; }
assert_eq "offers exactly three options" "$(count_closing_options "$out")" "3"
assert_contains "says exactly three options" "$out" "exactly three options"
assert_contains "tells the model to invoke the flow skill itself" "$out" "orchestrator:orch-flow"
assert_contains "tells the model to invoke the quick-implement skill itself" "$out" "orchestrator:orch-quick-implement"
# With no active flow, a human's request for a side checkout is honoured
# (#729): the skill runs on its side-checkout route.
side_request='If the user asks for a side checkout'
assert_contains "honours a request for a side checkout with no active flow" "$out" "$side_request"
assert_contains "a requested side checkout passes --side on Claude Code" "$out" \
  'pass args \"--side\" to whichever of those two skills runs'
# Blueprint only publishes the spec, offers a review, publishes the tickets,
# then stops; the run-next sentence names all three skills by their Claude name.
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
for s in orch-to-spec orch-spec-review orch-to-tickets; do
  assert_contains "Blueprint names orchestrator:$s on Claude Code" "$ctx" "\"orchestrator:$s\""
done
assert_contains "Blueprint asks about a spec review every time" "$ctx" "every time"
assert_contains "Blueprint says how to pick the issue up" "$ctx" "/orchestrator:start --issue"
assert_contains "Blueprint puts glossary/ADR wording into the issue verbatim" "$ctx" "into the issue body verbatim"
# Blueprint rewrites the interviewed issue (#707): rewrite mode on it whenever
# one was settled - moved, skipped, or named under "It's a different issue" -
# and a new issue only without one; the number is handed to orch-to-spec, and
# orch-to-tickets runs unless rewrite mode reported the breakdown kept.
# $1 where, $2 context, $3 host (claude|junie).
check_blueprint_rewrite() {
  local where="$1" ctx="$2" host="$3"
  assert_contains "Blueprint rewrites the interviewed issue $where" "$ctx" \
    "write the spec in rewrite mode on that issue, replacing #<n>'s body instead of publishing a new issue"
  assert_contains "Blueprint publishes a new issue only without one $where" "$ctx" \
    "Only with no interviewed issue, publish the spec as a new issue"
  assert_contains "rewrite applies whether moved or skipped $where" "$ctx" \
    "whether the user moved it to its triage label or answered \"Skip\""
  assert_contains "rewrite applies to the issue named under a different issue $where" "$ctx" \
    "or the one the user named under \"It's a different issue\""
  assert_contains "skips orch-to-tickets when rewrite mode reports kept $where" "$ctx" \
    "unless rewrite mode reported the breakdown \`kept\`"
  assert_contains "runs no breakdown check of its own $where" "$ctx" "run no breakdown check of your own"
  assert_contains "one stop rule covers every step $where" "$ctx" \
    "The route's steps run in this order, and one rule covers every step: when a step stops or fails, stop there - run no later step, and report why it stopped."
  assert_contains "orch-to-spec stops without an issue number $where" "$ctx" \
    "orch-to-spec stops when it ends without reporting the issue number."
  assert_contains "reports a retire with no breakdown $where" "$ctx" \
    "If orch-to-tickets fails after rewrite mode retired a breakdown, the report also says that #<n> carries its new body and no ticket breakdown, and needs /orchestrator:to-tickets <n>"
  assert_contains "runs the spec review only on a yes $where" "$ctx" \
    "run the standalone orch-spec-review only on a yes"
  assert_contains "asks about a spec review every time $where" "$ctx" "ask every time, never"
  # One copy of the order and stop rules (#730), none per host.
  assert_eq "states the kept skip once $where" \
    "$(count_of "$ctx" "unless rewrite mode reported")" 1
  assert_eq "states the stop rule once $where" \
    "$(count_of "$ctx" "when a step stops or fails")" 1
  local old
  for old in "call nothing after it" "run nothing after it" \
    "If orch-to-spec stops without reporting the issue number"; do
    assert_not_contains "drops the old stop clause '$old' $where" "$ctx" "$old"
  done
  if [ "$host" = claude ]; then
    assert_contains "calls the Skill tool for each step $where" "$ctx" \
      "call the Skill tool yourself for each step of the Blueprint route below:"
    assert_contains "hands the issue number as the Skill tool's args $where" "$ctx" \
      "\"orchestrator:orch-to-spec\", with args set to the interviewed issue's number when there is one"
    assert_contains "names the standalone spec review by Skill tool $where" "$ctx" \
      "\"orchestrator:orch-spec-review\" (its standalone spec review)"
    assert_contains "names orch-to-tickets by Skill tool $where" "$ctx" \
      "and \"orchestrator:orch-to-tickets\""
  else
    assert_contains "follows each step's skill, for issue #<n>, on Junie $where" "$ctx" \
      "run each step of the Blueprint route below as its skill - orch-to-spec for issue #<n>, the interviewed issue, when there is one"
    assert_contains "names the review and tickets skills on Junie $where" "$ctx" \
      "orch-spec-review, and orch-to-tickets. This host has no Skill tool"
    local s
    for s in orch-to-spec orch-spec-review orch-to-tickets; do
      assert_contains "lists $s's SKILL.md on Junie $where" "$ctx" "$(cd "$DIR/.." && pwd)/skills/$s/SKILL.md"
    done
  fi
}
check_blueprint_rewrite "on Claude Code" "$ctx" claude
assert_not_contains "no route tells the model to delete the marker" "$ctx" "marker"
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
# grilling.
out="$(skill_event "orchestrator:orch-interview" p1 | "$GRILL")"
assert_contains "fires on Skill(orchestrator:orch-interview)" "$out" "Do NOT offer to implement"
assert_eq "orch-interview arms the guard, which denies a source edit" \
  "$(edit_event "$REPO/src/main.ts" p1 | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
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
# to its next or redo; otherwise the interviewed-issue step and the route
# question, where only Blueprint runs in this checkout and Start and Quick
# implementation proceed in a side checkout (#729).
side_route='"Start the orchestrator flow" and "Quick implementation" proceed in a side checkout'
# $1 where, $2 context, $3 the next/redo pointer text expected for the host,
# $4 host (claude|junie), default claude.
check_flow_variant() {
  local where="$1" ctx="$2" next_redo="$3" host="${4:-claude}"
  check_blueprint_rewrite "beside an active flow $where" "$ctx" "$host"
  assert_contains "states the next/redo branch $where" "$ctx" "$next_redo"
  assert_contains "the same-flow branch asks no route question $where" "$ctx" "ask no route question"
  assert_contains "routes Start and Quick implementation to a side checkout $where" "$ctx" "$side_route"
  assert_not_contains "no longer says separate checkout $where" "$ctx" "separate checkout"
  assert_contains "keeps Blueprint only as the route that runs here $where" "$ctx" \
    "Blueprint only is the one route that runs in this checkout"
  assert_contains "keeps the interviewed-issue step $where" "$ctx" "With no interviewed issue, skip this step entirely"
  assert_contains "keeps the route question $where" "$ctx" "$route_block"
  # The branches stand in place of the route question (#640): its bullet asks
  # only in the second case, so the same-flow branch is not contradicted.
  assert_contains "asks the route question only in the second case $where" "$ctx" \
    "- Only in the second case above (planning about anything else): "
  # Only Blueprint runs here (#640, story 6): Start and Quick implementation
  # run their skills only on the side-checkout route (#729), never in this
  # checkout, whose branch belongs to the running flow.
  if [ "$host" = junie ]; then
    assert_contains "runs both skills on their side-checkout route $where" "$ctx" \
      "each as asked for a side checkout, so it takes its **Starting in a side checkout** route"
    assert_contains "points at orch-quick-implement's SKILL.md $where" "$ctx" \
      "$(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md"
  else
    assert_contains "runs the flow skill with --side $where" "$ctx" \
      'call the Skill tool with "orchestrator:orch-flow" and args "--side" yourself'
    assert_contains "runs the quick-implement skill with --side $where" "$ctx" \
      'call the Skill tool with "orchestrator:orch-quick-implement" and args "--side" yourself'
  fi
  assert_not_contains "never runs a skill without the side route $where" "$ctx" \
    "orch-quick-implement\" yourself"
  assert_not_contains "repeats no side-checkout request clause beside a flow $where" "$ctx" "$side_request"
}
route_block='      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - hands-off, for small changes: implement this directly, with no further questions before the PR.
      3. Blueprint only - write the spec (rewriting the interviewed issue, if
         there is one) and its ticket breakdown, then stop; implement later.'
cc_next_redo='/orchestrator:next or /orchestrator:redo'
echo '{"slug":"x","phase":"spec","issue":42}' >"$REPO/.orchestrator/state.json"
out="$(skill_event "grilling" s6 | "$GRILL")"
ctx="$(printf '%s' "$out" | jq -r '.additionalContext')"
assert_contains "sends the planning rules beside an active flow" "$ctx" "Do NOT offer to implement"
assert_contains "names the active flow's issue and phase" "$ctx" "the flow for #42 is active in this checkout, at phase spec"
assert_contains "the same-flow branch names the flow's issue" "$ctx" "about this flow's issue, #42"
check_flow_variant "on Claude Code" "$ctx" "$cc_next_redo"
assert_eq "offers exactly three options beside an active flow" "$(count_closing_options "$out")" "3"
if [ -e "$TMPDIR/orchestrator-grilling-s6" ]; then
  ok "writes the grilling marker beside an active flow"
else
  bad "writes the grilling marker beside an active flow" "no orchestrator-grilling-s6"
fi
assert_empty "stays silent on a second planning call beside an active flow" \
  "$(skill_event "grilling" s6 | "$GRILL")"
echo '{"slug":"my-change","phase":"implement","issue":null}' >"$REPO/.orchestrator/state.json"
ctx="$(skill_event "grilling" s6b | "$GRILL" | jq -r '.additionalContext')"
assert_contains "names an issueless flow by slug and phase" "$ctx" \
  "the flow my-change is active in this checkout, at phase implement; it has no issue yet"
assert_contains "the same-flow branch reads about this flow's change" "$ctx" "about this flow's change"
check_flow_variant "for an issueless flow" "$ctx" "$cc_next_redo"
echo '{"slug":"x","phase":null,"issue":null}' >"$REPO/.orchestrator/state.json"
ctx="$(skill_event "grilling" s6c | "$GRILL" | jq -r '.additionalContext')"
assert_contains "names a freshly started flow by slug as just started" "$ctx" \
  "the flow x is active in this checkout, just started; it has no issue yet"
echo '{"phase":"spec"}' >"$REPO/.orchestrator/state.json"
ctx="$(skill_event "grilling" s6e | "$GRILL" | jq -r '.additionalContext')"
assert_contains "states the phase of readable state with no issue or slug" "$ctx" \
  "a flow with no issue or slug is active in this checkout, at phase spec"
echo 'not json' >"$REPO/.orchestrator/state.json"
ctx="$(skill_event "grilling" s6d | "$GRILL" | jq -r '.additionalContext')"
assert_contains "says a flow is active without naming it for unreadable state" "$ctx" \
  "a flow is active in this checkout"
assert_not_contains "names no flow issue for unreadable state" "$ctx" "the flow for #"
assert_not_contains "names no phase for unreadable state" "$ctx" "at phase"
check_flow_variant "for unreadable state" "$ctx" "$cc_next_redo"
# A done flow is finished work, not a running one (ADR-0009): planning in its
# checkout gets the full message, records rule included (#186).
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
out="$(skill_event "grilling" s7 | "$GRILL")"
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
assert_contains "asks the closing question with Junie's ask_user tool" "$ctx" "Call the ask_user tool"
assert_not_contains "names no Claude question tool on Junie" "$ctx" "AskUserQuestion"
assert_contains "offers starting the flow on Junie" "$ctx" "Start the orchestrator flow"
assert_contains "offers quick implementation on Junie" "$ctx" "Quick implementation"
assert_contains "offers Blueprint only on Junie" "$ctx" "Blueprint only"
assert_eq "offers exactly three options on Junie" "$(count_closing_options "$out")" "3"
check_blueprint_rewrite "on Junie" "$ctx" junie
assert_not_contains "no route tells the model to delete the marker on Junie" "$ctx" "marker"
assert_contains "forbids offering to implement on Junie" "$ctx" "Do NOT offer to implement"
assert_contains "carries the wayfinder caveat on Junie" "$ctx" "whole map is done"
assert_contains "names every planning artifact on Junie" "$ctx" \
  "docs/agents/, .scratch/, .orchestrator/"
assert_contains "points at orch-flow's SKILL.md in this install" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-flow/SKILL.md"
assert_contains "points at orch-quick-implement's SKILL.md in this install" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md"
assert_contains "says Junie has no Skill tool" "$ctx" "no Skill tool"
assert_contains "honours a request for a side checkout on Junie" "$ctx" "$side_request"
assert_contains "a requested side checkout takes the skill's side route on Junie" "$ctx" \
  "follow that skill's **Starting in a side checkout** section"
assert_not_contains "routes nothing to a side checkout unasked on Junie" "$ctx" "$side_route"
assert_not_contains "names no Claude tool as the step on Junie" "$ctx" "call the Skill tool"
assert_not_contains "names no Claude-scoped skill on Junie" "$ctx" "orchestrator:orch-"
assert_not_contains "names no Claude-scoped mattpocock skill on Junie" "$ctx" "mattpocock-skills:"

assert_empty "stays silent on the second grilling prompt in one Junie session" \
  "$(prompt_event '$grilling again' j1 | "$GRILL")"

# On Junie the guard does not arm (ADR-0025): the marker that keeps the
# message to once per session is named so hook-guard.sh never reads it, and a
# Junie-style Edit in the same session, with no project_path, is allowed.
if [ -e "$TMPDIR/orchestrator-planning-j1" ]; then
  ok "a Junie grilling prompt writes the planning marker"
else
  bad "a Junie grilling prompt writes the planning marker" "no orchestrator-planning-j1"
fi
if [ -e "$TMPDIR/orchestrator-grilling-j1" ]; then
  bad "a Junie grilling prompt writes no guard marker" "orchestrator-grilling-j1 exists"
else
  ok "a Junie grilling prompt writes no guard marker"
fi
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
assert_eq "offers exactly three options at plan confirmation" "$(count_closing_options "$out")" "3"
assert_contains "offers Blueprint only at plan confirmation" "$ctx" "Blueprint only"
check_blueprint_rewrite "at Junie's plan confirmation" "$ctx" junie
assert_contains "points at orch-flow's SKILL.md at plan confirmation" "$ctx" "$(cd "$DIR/.." && pwd)/skills/orch-flow/SKILL.md"
assert_contains "honours a request for a side checkout at plan confirmation" "$ctx" "$side_request"
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
echo '{"slug":"x","phase":"review","issue":7}' >"$REPO/.orchestrator/state.json"
junie_next_redo="the **Next phase** and **Redo** sections of $(cd "$DIR/.." && pwd)/skills/orch-flow/SKILL.md"
ctx="$(prompt_event '$grilling' j3 | "$GRILL" | jq -r '.additionalContext')"
assert_contains "sends the planning rules on Junie beside an active flow" "$ctx" "Do NOT offer to implement"
assert_contains "names the active flow's issue and phase on Junie" "$ctx" \
  "the flow for #7 is active in this checkout, at phase review"
check_flow_variant "on Junie" "$ctx" "$junie_next_redo" junie
assert_not_contains "names no plugin command on Junie" "$ctx" "/orchestrator:next"
if [ -e "$TMPDIR/orchestrator-planning-j3" ]; then
  ok "writes the planning marker on Junie beside an active flow"
else
  bad "writes the planning marker on Junie beside an active flow" "no orchestrator-planning-j3"
fi
assert_empty "stays silent on a second Junie planning prompt beside an active flow" \
  "$(prompt_event '$grilling' j3 | "$GRILL")"
ctx="$(prompt_event "$confirm" jc1 | "$GRILL" | jq -r '.additionalContext')"
assert_contains "asks before implementing at plan confirmation beside an active flow" "$ctx" "before you implement anything"
assert_contains "names the active flow at plan confirmation" "$ctx" \
  "the flow for #7 is active in this checkout, at phase review"
check_flow_variant "at Junie's plan confirmation" "$ctx" "$junie_next_redo" junie
echo '{"slug":"x","phase":"done"}' >"$REPO/.orchestrator/state.json"
out="$(prompt_event '$grilling' j4 | "$GRILL")"
assert_contains "still fires on Junie's \$grilling when the flow is done" "$out" "Do NOT offer to implement"
assert_not_contains "a done flow gets the ordinary message on Junie" "$out" "is active in this checkout"
assert_contains "still asks at plan confirmation when the flow is done" \
  "$(prompt_event "$confirm" jc1 | "$GRILL")" "Before you implement"
rm -rf "$REPO/.orchestrator"

echo
echo "grilling hook's interviewed-issue step (#573)"

# When a planning interview was about an open issue, the close
# offers to move it to ready-for-agent before the route question, through
# orch.sh issue triage. Checked on every message that carries the route
# question: the start-of-session message on both hosts, and Junie's
# plan-confirmed message (Claude Code has none, ADR-0025).
ORCH_PATH="$(cd "$DIR/.." && pwd)/scripts/orch.sh"
route_block='      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - hands-off, for small changes: implement this directly, with no further questions before the PR.
      3. Blueprint only - write the spec (rewriting the interviewed issue, if
         there is one) and its ticket breakdown, then stop; implement later.'
# True when $2 occurs in $1 before $3 does, both present.
occurs_before() {
  case "$1" in *"$2"*) ;; *) return 1 ;; esac
  case "$1" in *"$3"*) ;; *) return 1 ;; esac
  local a="${1%%"$2"*}" b="${1%%"$3"*}"
  [ "${#a}" -lt "${#b}" ]
}
check_interviewed_step() {
  local where="$1" ctx="$2" tool="$3"
  assert_contains "names the interviewed issue $where" "$ctx" "interviewed issue"
  assert_contains "the step is conditional on an interviewed issue $where" "$ctx" \
    "With no interviewed issue, skip this step entirely"
  assert_contains "asks the move question with the host's tool $where" "$ctx" \
    "ask one blocking question with $tool"
  assert_contains "the question names the issue number $where" "$ctx" "Move #<n> to \`ready-for-agent\`"
  assert_contains "offers skip $where" "$ctx" "\"Skip\""
  assert_contains "offers a different issue $where" "$ctx" "\"It's a different issue\""
  assert_contains "skip continues to the route question $where" "$ctx" \
    "On \"Skip\", go straight to the route question"
  assert_contains "runs orch.sh issue triage via the resolved path $where" "$ctx" \
    "bash \"$ORCH_PATH\" issue triage <n>"
  assert_contains "forbids a raw gh call $where" "$ctx" "never a raw gh call"
  assert_not_contains "carries no raw gh issue call $where" "$ctx" "gh issue"
  assert_contains "asks to override on exit 2 $where" "$ctx" "If it exits 2"
  assert_contains "reruns with --override on a yes $where" "$ctx" "on a yes, rerun it with --override"
  assert_contains "skips the relabel on a no $where" "$ctx" "on a no, skip the relabel"
  assert_contains "warns and continues on any other failure $where" "$ctx" \
    "On any other failure, warn the user that init --issue will refuse #<n> until it carries \`ready-for-agent\`, and continue to the route question"
  assert_contains "keeps the route question's text unchanged $where" "$ctx" "$route_block"
  if occurs_before "$ctx" "issue triage <n>" "$route_block"; then
    ok "puts the interviewed-issue step before the route question $where"
  else
    bad "puts the interviewed-issue step before the route question $where" "step not before route question"
  fi
}
# The step names a repo's renamed triage labels, never the canonical ones.
check_renamed_labels() {
  local where="$1" event="$2" arg="$3" session="$4" ctx
  ctx="$("$event" "$arg" "$session" | "$GRILL" | jq -r '.additionalContext')"
  assert_contains "names the repo's ready-for-agent label $where" "$ctx" "Move #<n> to \`agent-ready\`"
  assert_contains "warns with the repo's ready-for-agent label $where" "$ctx" "until it carries \`agent-ready\`"
  assert_contains "names the repo's wontfix and ready-for-human labels $where" "$ctx" "\`not-planned\` or \`human-only\`"
  assert_not_contains "names no canonical ready-for-agent label $where" "$ctx" "ready-for-agent"
}

ctx="$(skill_event "mattpocock-skills:grilling" ii1 | "$GRILL" | jq -r '.additionalContext')"
check_interviewed_step "on Claude Code" "$ctx" "the AskUserQuestion tool"
ctx="$(prompt_event '$grilling' ii2 | "$GRILL" | jq -r '.additionalContext')"
check_interviewed_step "on Junie" "$ctx" "the ask_user tool"
ctx="$(prompt_event "$confirm" ii2 | "$GRILL" | jq -r '.additionalContext')"
check_interviewed_step "at Junie's plan confirmation" "$ctx" "the ask_user tool"

# A repo that renamed its triage labels gets its own names in the step.
cat >"$REPO/docs/agents/triage-labels.md" <<'DOC'
| Role            | Ours          | Meaning |
| --------------- | ------------- | ------- |
| needs-triage    | triage-me     | x       |
| needs-info      | need-more     | x       |
| ready-for-agent | agent-ready   | x       |
| ready-for-human | human-only    | x       |
| wontfix         | not-planned   | x       |
DOC
check_renamed_labels "on Claude Code" skill_event "mattpocock-skills:grilling" ii3
check_renamed_labels "on Junie" prompt_event '$grilling' ii4
check_renamed_labels "at Junie's plan confirmation" prompt_event "$confirm" ii4
rm -f "$REPO/docs/agents/triage-labels.md"

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
# The legacy CONTEXT names stay records for repos not yet renamed (#461).
for f in GLOSSARY.md GLOSSARY-MAP.md CONTEXT.md CONTEXT-MAP.md docs/adr/0001-x.md docs/adr/../adr/x.md; do
  out="$(edit_event "$REPO/$f" s1 | "$GUARD")"
  assert_eq "denies planning record: $f" \
    "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
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
if [ -e "$TMPDIR/orchestrator-grilling-e2e" ]; then
  ok "grilling arms the marker when the flow is done"
else
  bad "grilling arms the marker when the flow is done" "no marker"
fi
out="$(edit_event "$REPO/GLOSSARY.md" e2e | "$GUARD" | jq -r '.reason')"
assert_contains "the armed guard denies GLOSSARY.md with the records reason" "$out" \
  "'GLOSSARY.md' is a record of decisions, and planning does not change records in place."
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

# The Read lift is gone (ADR-0025): the guard does not arm on Junie, so
# nothing needs lifting there, and a Read of the installed SKILL.md is no
# longer a trigger.
QUICK_SKILL="$(cd "$DIR/.." && pwd)/skills/orch-quick-implement/SKILL.md"
: >"$TMPDIR/orchestrator-grilling-r1"
jq -n --arg f "$QUICK_SKILL" \
  '{hook_event_name:"PreToolUse", tool_name:"Read", session_id:"r1", tool_input:{file_path:$f}}' \
  | "$QUICK" >/dev/null
assert_marker_kept "a PreToolUse Read of the installed SKILL.md leaves the marker" r1
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

: >"$TMPDIR/orchestrator-grilling-ss1"; : >"$TMPDIR/orchestrator-planning-ss1"
out="$(start_event clear ss1 | "$START")"; st=$?
assert_eq "clear exits 0" "$st" 0
assert_empty "clear emits no context" "$out"
assert_eq "clear removes the session's grilling and planning markers" "$(markers_present ss1)" 0

for src in compact startup resume; do
  : >"$TMPDIR/orchestrator-grilling-ss-$src"; : >"$TMPDIR/orchestrator-planning-ss-$src"
  out="$(start_event "$src" "ss-$src" | "$START")"; st=$?
  assert_eq "$src exits 0" "$st" 0
  assert_empty "$src emits nothing" "$out"
  assert_eq "$src leaves both markers in place" "$(markers_present "ss-$src")" 2
  rm -f "$TMPDIR/orchestrator-grilling-ss-$src" "$TMPDIR/orchestrator-planning-ss-$src"
done

# With no session_id the marker path would end in "-": nothing may be removed.
: >"$TMPDIR/orchestrator-grilling-"; : >"$TMPDIR/orchestrator-planning-"
: >"$TMPDIR/orchestrator-grilling-ss2"; : >"$TMPDIR/orchestrator-planning-ss2"
out="$(jq -n --arg cwd "$REPO" '{hook_event_name:"SessionStart", cwd:$cwd, source:"clear"}' | "$START")"; st=$?
assert_eq "no session_id exits 0" "$st" 0
assert_empty "no session_id exits silently" "$out"
assert_eq "no session_id removes no marker" \
  "$(( $(markers_present "") + $(markers_present ss2) ))" 4
rm -f "$TMPDIR/orchestrator-grilling-" "$TMPDIR/orchestrator-planning-"

out="$(start_event clear ss2 | "$START")"
assert_eq "only the named session's markers are removed" "$(markers_present ss1)$(markers_present ss2)" "00"
: >"$TMPDIR/orchestrator-grilling-ss3"; : >"$TMPDIR/orchestrator-planning-ss3"
start_event clear ss4 | "$START" >/dev/null
assert_eq "another session's markers stay in place" "$(markers_present ss3)" 2
rm -f "$TMPDIR/orchestrator-grilling-ss3" "$TMPDIR/orchestrator-planning-ss3"

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
  "$(edit_event "$REPO/src/main.ts" ss7 | "$GUARD" | jq -r '.hookSpecificOutput.permissionDecision')" "deny"
start_event clear ss7 | "$START" >/dev/null
assert_empty "after SessionStart clear, the edit guard allows the source edit" \
  "$(edit_event "$REPO/src/main.ts" ss7 | "$GUARD")"
rm -f "$TMPDIR"/orchestrator-*-ss*

assert_eq "hooks.json registers hook-session-start.sh under SessionStart with matcher clear" \
  "$(jq -r '[.hooks.SessionStart[]? | select(.matcher == "clear") | .hooks[]?.command | select(test("hook-session-start\\.sh"))] | length' "$DIR/../hooks/hooks.json")" 1

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

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
