#!/usr/bin/env bash
#
# PostToolUse hook on the Skill tool.
#
# All three planning entry points - grill-me, wayfinder, and
# improve-codebase-architecture - funnel through Skill("grilling"), which makes
# it the one reliable choke point for noticing that planning has begun.
#
# It injects context only. It cannot force compliance, which is why the real
# durability lives in .orchestrator/state.json and the edit guard. Fires once
# per session, and says nothing at all when a flow is already running.

set -euo pipefail

input="$(cat)"
skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')"
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"

# "grilling" only. grill-me and grill-with-docs route through it rather than
# being it, so matching the substring catches them without double-firing.
case "$skill" in *grilling*) ;; *) exit 0 ;; esac

marker="${TMPDIR:-/tmp}/orchestrator-grilling-${session}"
if [ -e "$marker" ]; then exit 0; fi
: >"$marker"

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Mid-flow already: the user is resolving a wayfinder ticket or re-planning
# inside an active flow, and does not need to be told how to start one.
if [ -f "$root/.orchestrator/state.json" ]; then exit 0; fi

warning=""
# Open-coded rather than `orch.sh doctor --env`: this hook is PostToolUse on
# every planning session, so it has to be instant and offline, and doctor costs
# several gh calls and a few seconds. One early warning about the precondition
# that wastes an hour of planning is the whole job here.
if [ ! -f "$root/docs/agents/issue-tracker.md" ]; then
  warning="
PRECONDITION NOT MET: this repo has no docs/agents/issue-tracker.md, so the spec
phase would fail. Tell the user now, before they invest an hour in planning, that
they need to run /mattpocock-skills:setup-matt-pocock-skills first."
fi

context="The orchestrator plugin is installed in this repo. Planning is phase one
of an orchestrated flow: plan -> spec -> implement -> review, where each phase
runs in a fresh session connected by handoff files.

While this planning session is running:

- Do NOT offer to implement, and do NOT write or edit code. Planning artifacts
  (CONTEXT.md, docs/adr/, docs/agents/, .scratch/) are fine; source files are not.
- When you reach a shared understanding, do not close with a scripted line and
  do not decide the next step yourself. Call the AskUserQuestion tool with
  exactly two options:

      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - skip the pipeline and implement this directly.

- On \"Start the orchestrator flow\", call the Skill tool with
  \"orchestrator:flow\" yourself. On \"Quick implementation\", call the Skill
  tool with \"orchestrator:quick-implement\" yourself. Do not ask the user to
  type a command - orchestrator skills are model-invocable, unlike the
  mattpocock ones.

Under /mattpocock-skills:wayfinder, \"approved\" means the whole map is done, not
that one ticket resolved. Do not start the flow after a single ticket.${warning}"

jq -n --arg c "$context" '{
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: $c
  }
}'
