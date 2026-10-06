#!/usr/bin/env bash
#
# Delivers the planning message once per session when planning starts with no
# flow active. One script, two hosts; the tool that asks the closing question
# and the sentence on how to run the next skill differ between them, and only
# Junie asks the question again when a plan is confirmed.
#
# Claude Code: PostToolUse on the Skill tool. Two skills mark that planning
# has begun: the plugin's own orch-interview, and, when mattpocock-skills is
# installed, its grilling, through which grill-me, grill-with-docs,
# wayfinder, and improve-codebase-architecture all funnel.
#
# Junie CLI: UserPromptSubmit (#202). Junie has no PostToolUse event and no
# Skill tool, so the hook matches a planning entry point named in the raw
# prompt (Junie rewrites a typed /<skill> into $<skill>). Accepted gap: when
# Junie picks grilling on its own, no prompt names it and nothing is sent.
# Junie's router sends grilling to its plan agent, which ends on its own
# plan screen, so on Junie the closing question is asked again when that
# screen is confirmed. hook_read_payload tells the hosts apart; Claude Code's
# own UserPromptSubmit exits here silently.
#
# It injects context only. It cannot force compliance, which is why the real
# durability lives in .orchestrator/state.json and, on Claude Code, the edit
# guard; on Junie, orch.sh init's flow-start working-tree check (ADR-0025). Fires once
# per session, and says nothing at all when a flow is already running.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"
# For triage_label_for, so the closing step names this repo's own triage
# labels. doctor.sh reads the labels doc at $ROOT/$LABELS_DOC, the path
# orch.sh sets too.
source "$(dirname "${BASH_SOURCE[0]}")/doctor.sh"

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
  # orch-interview matches under any scope; its command, interview, only
  # under orchestrator:, because a bare /interview is not ours.
  entry='(^|[[:space:]])[/$](([a-z-]+:)?(grilling|grill-me|grill-with-docs|wayfinder|improve-codebase-architecture|orch-interview)|orchestrator:interview)([[:space:]]|$)'
  [ "$plan_confirmed" = 1 ] || [[ "$prompt" =~ $entry ]] || exit 0
else
  # "grilling" or "orch-interview" only. grill-me and grill-with-docs route through
  # grilling rather than being it, so matching the substring catches them
  # without double-firing.
  case "$skill" in *grilling*|*orch-interview*) ;; *) exit 0 ;; esac
fi

# No session_id, no marker: there is nothing to key the guard to, so it stays
# unarmed and the once-per-session check cannot apply. On Claude Code the
# marker also arms the edit guard. On Junie it does not (ADR-0025): the marker
# is named orchestrator-planning-<session>, a name hook-guard.sh never reads,
# and only keeps the message to once per session and gates the plan
# confirmation. The guard cannot skip Junie itself, because Junie's PreToolUse
# may lack project_path.
# A plan confirmation counts only in a session that grilled, so it needs the
# marker rather than being stopped by it, and asks on every confirmation.
marker_kind=grilling
[ "$host" != junie ] || marker_kind=planning
marker=""
[ -z "$session" ] || marker="$(hook_marker_path "$marker_kind")"
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

ROOT="$root"
LABELS_DOC="docs/agents/triage-labels.md"
ready_label="$(triage_label_for ready-for-agent)"
wontfix_label="$(triage_label_for wontfix)"
human_label="$(triage_label_for ready-for-human)"

if [ "$host" = junie ]; then
  ask_tool="the ask_user tool"
  ask_step="Call the ask_user tool with
  exactly three options:"
  plugin_root="$(hook_plugin_root)"
  run_next="- On \"Start the orchestrator flow\", run the orch-flow skill yourself; on
  \"Quick implementation\", the orch-quick-implement skill; on \"Blueprint
  only\", the orch-to-spec skill, then orch-spec-review if the user wants a
  review, then orch-to-tickets. This host has no Skill tool, so read each
  skill's file and follow it verbatim:
  $plugin_root/skills/orch-flow/SKILL.md,
  $(hook_quick_skill_file),
  $plugin_root/skills/orch-to-spec/SKILL.md,
  $plugin_root/skills/orch-spec-review/SKILL.md (its standalone spec review), or
  $plugin_root/skills/orch-to-tickets/SKILL.md."
else
  ask_tool="the AskUserQuestion tool"
  ask_step="Call the AskUserQuestion tool with
  exactly three options:"
  run_next="- On \"Start the orchestrator flow\", call the Skill tool with
  \"orchestrator:orch-flow\" yourself. On \"Quick implementation\", call the Skill
  tool with \"orchestrator:orch-quick-implement\" yourself. On \"Blueprint
  only\", call the Skill tool with \"orchestrator:orch-to-spec\", then with
  \"orchestrator:orch-spec-review\" (its standalone spec review) if the user
  wants a review, then with \"orchestrator:orch-to-tickets\", yourself. The
  orchestrator's skills are model-invocable: call them, do not hand them to the
  user."
fi

# The interviewed issue (#571): an open issue the planning was about is
# offered a move to ready-for-agent before the route question, so init
# --issue can adopt it. Its lines are bullets, never numbered: the route
# question's three options are the only numbered lines in the message.
interviewed_step="- At the close, if this planning was about an existing open issue - named in the
  interview's arguments or its conversation - that is the interviewed issue,
  and this step comes before the route question below.
  With no interviewed issue, skip this step entirely.
  Otherwise ask one blocking question with ${ask_tool}, naming its number:
  \"Move #<n> to \`${ready_label}\`\", \"Skip\", or \"It's a different issue\"
  (the user names it, and you use that one).
  On \"Skip\", go straight to the route question. On a move, run
  bash \"$(hook_plugin_root)/scripts/orch.sh\" issue triage <n>
  through that path - never a raw gh call. If it exits 2, the issue carries
  \`${wontfix_label}\` or \`${human_label}\` and it printed which: ask the user
  whether to override that label; on a yes, rerun it with --override;
  on a no, skip the relabel. On any other failure, warn the user that init --issue will refuse #<n> until it carries \`${ready_label}\`, and continue to the route question."

choice="${ask_step}

      1. Start the orchestrator flow - the full plan -> spec -> implement ->
         review pipeline, with its own handoff and review loop.
      2. Quick implementation - skip the pipeline and implement this directly.
      3. Blueprint only - publish the spec and its ticket breakdown, then
         stop; implement later.

${run_next} Do not ask the user to type a command.

- On \"Blueprint only\": publish the spec (orch-to-spec), with any glossary or
  ADR wording the planning decided written into the issue body verbatim. Then
  ask the user whether to run a spec review on it - ask every time, never
  assume - and run the standalone orch-spec-review only on a yes. Then publish
  its ticket breakdown (orch-to-tickets) against that issue. Then stop: do not
  implement or edit source. Report the issue number and how to pick it up
  later: /orchestrator:start --issue <n>, or a quick implementation that names
  the issue."

if [ "$plan_confirmed" = 1 ]; then
  hook_emit_context "$event" "The orchestrator plugin is installed in this repo, and the user just
confirmed a plan from a planning session.

${interviewed_step}
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
${interviewed_step}
- When you reach a shared understanding, do not close with a scripted line and
  do not decide the next step yourself. ${choice}

If this session runs under a wayfinder skill, \"approved\" means the
whole map is done, not that one ticket resolved. Do not start the flow after a single ticket."

hook_emit_context "$event" "$context"
