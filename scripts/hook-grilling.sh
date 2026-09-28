#!/usr/bin/env bash
#
# Delivers the planning message once per session when grilling starts with no
# flow active. One script, two hosts; the tool that asks the closing question
# and the sentence on how to run the next skill differ between them, and only
# Junie asks the question again when a plan is confirmed.
#
# Claude Code: PostToolUse on the Skill tool. All three planning entry points
# - grill-me, wayfinder, and improve-codebase-architecture - funnel through
# Skill("grilling"), which makes it the one reliable choke point for noticing
# that planning has begun.
#
# Junie CLI: UserPromptSubmit (#202). Junie has no PostToolUse event and no
# Skill tool, so the hook matches a grilling entry point named in the raw
# prompt (Junie rewrites a typed /<skill> into $<skill>). Accepted gap: when
# Junie picks grilling on its own, no prompt names it and nothing is sent.
# Junie's router sends grilling to its plan agent, which ends on its own
# plan screen, so on Junie the closing question is asked again when that
# screen is confirmed. hook_read_payload tells the hosts apart; Claude Code's
# own UserPromptSubmit exits here silently.
#
# It injects context only. It cannot force compliance, which is why the real
# durability lives in .orchestrator/state.json and the edit guard. Fires once
# per session, and says nothing at all when a flow is already running.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

hook_read_skill_and_session

event="$(printf '%s' "$input" | jq -r '.hook_event_name // "PostToolUse"')"
plan_confirmed=0
if [ "$event" = "UserPromptSubmit" ]; then
  [ "$host" = junie ] || exit 0
  prompt="$(printf '%s' "$input" | jq -r '.prompt // ""')"
  # Junie's router sends grilling to its plan agent, which ends on its own
  # plan screen without asking the closing question. Confirming that
  # screen submits this fixed prompt to the main agent, which asks it instead.
  if [ "$prompt" = "Implement the suggested plan" ]; then plan_confirmed=1; fi
  # A "/" or "$" reference to an entry point, optionally scoped, standing as
  # its own word: "$grill-me x" matches, "$grilling-notes" and prose do not.
  entry='(^|[[:space:]])[/$]([a-z-]+:)?(grilling|grill-me|grill-with-docs|wayfinder|improve-codebase-architecture)([[:space:]]|$)'
  [ "$plan_confirmed" = 1 ] || [[ "$prompt" =~ $entry ]] || exit 0
else
  # "grilling" only. grill-me and grill-with-docs route through it rather than
  # being it, so matching the substring catches them without double-firing.
  case "$skill" in *grilling*) ;; *) exit 0 ;; esac
fi

# No session_id, no marker: there is nothing to key the guard to, so it stays
# unarmed and the once-per-session check cannot apply. On Junie the marker
# arms the edit guard too: its PreToolUse carries session_id from build 3419.7
# (ADR-0023).
# A plan confirmation counts only in a session that grilled, so it needs the
# marker rather than being stopped by it, and asks on every confirmation.
marker=""
[ -z "$session" ] || marker="${TMPDIR:-/tmp}/orchestrator-grilling-${session}"
if [ "$plan_confirmed" = 1 ]; then
  [ -n "$marker" ] && [ -e "$marker" ] || exit 0
elif [ -n "$marker" ]; then
  if [ -e "$marker" ]; then exit 0; fi
  : >"$marker"
fi

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Mid-flow already: the user is resolving a wayfinder ticket or re-planning
# inside an active flow, and does not need to be told how to start one. A done
# flow is finished work, so planning beside it gets the full message.
if hook_flow_active "$root"; then exit 0; fi

warning=""
# Open-coded rather than `orch.sh doctor --env`: this hook runs on every
# planning session, so it has to be instant and offline, and doctor costs
# several gh calls and a few seconds. One early warning about the precondition
# that wastes an hour of planning is the whole job here.
if [ ! -f "$root/docs/agents/issue-tracker.md" ]; then
  warning="
PRECONDITION NOT MET: this repo has no docs/agents/issue-tracker.md, so the spec
phase would fail. Tell the user now, before they invest an hour in planning, that
they need to run the mattpocock-skills setup-matt-pocock-skills skill first."
fi

if [ "$host" = junie ]; then
  ask_step="Call the ask_user tool with
  exactly two options:"
  plugin_root="$(hook_plugin_root)"
  run_next="- On \"Start the orchestrator flow\", run the orch-flow skill yourself; on
  \"Quick implementation\", the orch-quick-implement skill. This host has
  no Skill tool, so read the skill's file and follow it verbatim:
  $plugin_root/skills/orch-flow/SKILL.md or
  $(hook_quick_skill_file)."
else
  ask_step="Call the AskUserQuestion tool with
  exactly two options:"
  run_next="- On \"Start the orchestrator flow\", call the Skill tool with
  \"orchestrator:orch-flow\" yourself. On \"Quick implementation\", call the Skill
  tool with \"orchestrator:orch-quick-implement\" yourself. Orchestrator skills
  are model-invocable, unlike the mattpocock ones."
fi

choice="${ask_step}

      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - skip the pipeline and implement this directly.

${run_next} Do not ask the user to type a command."

if [ "$plan_confirmed" = 1 ]; then
  hook_emit_context "$event" "The orchestrator plugin is installed in this repo, and the user just
confirmed a plan from a planning session.

- Before you implement anything, and without editing any file first, ask the
  user how to carry the plan out. ${choice}"
  exit 0
fi

context="The orchestrator plugin is installed in this repo. Planning is phase one
of an orchestrated flow: plan -> spec -> implement -> review, where each phase
runs in a fresh session connected by handoff files.

While this planning session is running:

- Do NOT offer to implement, and do NOT write or edit code. Planning artifacts
  ($(planning_allowlist_text)) are fine; source files are not.
- Glossary and ADR changes ($(planning_records_text)) are records: never edit them. Write the exact wording you intend into the plan, so the spec carries it verbatim.
- When you reach a shared understanding, do not close with a scripted line and
  do not decide the next step yourself. ${choice}

Under the mattpocock-skills wayfinder skill, \"approved\" means the whole map is done, not
that one ticket resolved. Do not start the flow after a single ticket.${warning}"

hook_emit_context "$event" "$context"
