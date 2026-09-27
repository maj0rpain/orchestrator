#!/usr/bin/env bash
#
# Delivers the planning message once per session when grilling starts with no
# flow active. One script, two hosts; only the sentence on how to run the
# next skill differs between them.
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
# hook_read_payload tells the hosts apart; Claude Code's own UserPromptSubmit
# exits here silently.
#
# It injects context only. It cannot force compliance, which is why the real
# durability lives in .orchestrator/state.json and the edit guard. Fires once
# per session, and says nothing at all when a flow is already running.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

hook_read_skill_and_session

event="$(printf '%s' "$input" | jq -r '.hook_event_name // "PostToolUse"')"
if [ "$event" = "UserPromptSubmit" ]; then
  [ "$host" = junie ] || exit 0
  prompt="$(printf '%s' "$input" | jq -r '.prompt // ""')"
  # A "/" or "$" reference to an entry point, optionally scoped, standing as
  # its own word: "$grill-me x" matches, "$grilling-notes" and prose do not.
  entry='(^|[[:space:]])[/$]([a-z-]+:)?(grilling|grill-me|grill-with-docs|wayfinder|improve-codebase-architecture)([[:space:]]|$)'
  [[ "$prompt" =~ $entry ]] || exit 0
else
  # "grilling" only. grill-me and grill-with-docs route through it rather than
  # being it, so matching the substring catches them without double-firing.
  case "$skill" in *grilling*) ;; *) exit 0 ;; esac
fi

# No session_id, no marker: there is nothing to key the guard to, so it stays
# unarmed and the once-per-session check cannot apply. On Junie the marker only
# keeps the message to once per session: Junie's PreToolUse carries no
# session_id, so the edit guard never reads it there (ADR-0013).
if [ -n "$session" ]; then
  marker="${TMPDIR:-/tmp}/orchestrator-grilling-${session}"
  if [ -e "$marker" ]; then exit 0; fi
  : >"$marker"
fi

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# Mid-flow already: the user is resolving a wayfinder ticket or re-planning
# inside an active flow, and does not need to be told how to start one.
if [ -f "$root/.orchestrator/state.json" ]; then exit 0; fi

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
  plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  run_next="- On \"Start the orchestrator flow\", run the orch-flow skill yourself; on
  \"Quick implementation\", the orch-quick-implement skill. This host has
  no Skill tool, so read the skill's file and follow it verbatim:
  $plugin_root/skills/orch-flow/SKILL.md or
  $plugin_root/skills/orch-quick-implement/SKILL.md."
else
  run_next="- On \"Start the orchestrator flow\", call the Skill tool with
  \"orchestrator:orch-flow\" yourself. On \"Quick implementation\", call the Skill
  tool with \"orchestrator:orch-quick-implement\" yourself. Orchestrator skills
  are model-invocable, unlike the mattpocock ones."
fi

context="The orchestrator plugin is installed in this repo. Planning is phase one
of an orchestrated flow: plan -> spec -> implement -> review, where each phase
runs in a fresh session connected by handoff files.

While this planning session is running:

- Do NOT offer to implement, and do NOT write or edit code. Planning artifacts
  ($(planning_allowlist_text)) are fine; source files are not.
- When you reach a shared understanding, do not close with a scripted line and
  do not decide the next step yourself. Call the AskUserQuestion tool with
  exactly two options:

      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - skip the pipeline and implement this directly.

${run_next} Do not ask the user to type a command.

Under the mattpocock-skills wayfinder skill, \"approved\" means the whole map is done, not
that one ticket resolved. Do not start the flow after a single ticket.${warning}"

hook_emit_context "$event" "$context"
