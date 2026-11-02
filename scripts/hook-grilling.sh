#!/usr/bin/env bash
#
# Delivers the planning message once per session when planning starts. One
# script, two hosts; the tool that asks the closing question and the sentence on
# how to run the next skill differ between them, and only Junie asks the
# question again when a plan is confirmed.
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
# guard; on Junie, orch.sh init's flow-start working-tree check (ADR-0025).
# Fires once per session. It sends only what depends on the session: the
# planning rules, this repo's triage labels, the host's ask tool, and, beside a
# running flow, that flow and its two cases (about that flow, point to its next
# or redo; about anything else, the close). The fixed closing rules - the
# interviewed-issue step, the done-close (#985), the route question and the
# routes, side checkout included (#640, #729) - live in orch-interview's
# "## Closing" section (#1980), because Claude Code keeps hook context of 10 KB
# or more out of the conversation. Entry points that do not load that skill
# are pointed at the section by absolute path.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"
# For triage_label_for, so the closing step names this repo's own triage
# labels. The module reads the labels doc at $ROOT/$LABELS_DOC and needs
# only ROOT, set below.
source "$(dirname "${BASH_SOURCE[0]}")/triage-labels.sh"

# Prints the regex for a "/" or "$" reference to an entry point, standing as
# its own word: "$grill-me x" matches, "$grilling-notes" and prose do not. $1
# is an alternation of names, each matched under any scope; $2, when given, is
# one more alternative matched only as written, for a command such as
# orchestrator:interview, because a bare /interview is not ours. One grammar
# for both the hook's trigger and its orch-interview test, so they cannot drift.
entry_pattern() {
  local alt="([a-z-]+:)?($1)"
  [ -z "${2:-}" ] || alt="$alt|$2"
  printf '(^|[[:space:]])[/$](%s)([[:space:]]|$)' "$alt"
}

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
  # A planning entry point named in the prompt; see entry_pattern.
  [ "$plan_confirmed" = 1 ] ||
    [[ "$prompt" =~ $(entry_pattern 'grilling|grill-me|grill-with-docs|wayfinder|improve-codebase-architecture|orch-interview' orchestrator:interview) ]] ||
    exit 0
else
  # "grilling" or "orch-interview" only. grill-me and grill-with-docs route
  # through grilling rather than being it, so matching the substring catches
  # them without double-firing.
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

# Beside an active flow (#640): the planning may be re-planning that flow, or a
# different change planned in another terminal on the same checkout. The hook
# cannot tell which - the skill's arguments are free text - so it sends the
# planning rules with a closing that names the flow and states both branches,
# and the model picks one. A done flow is finished work, so planning beside it
# gets the ordinary message.
flow_active=0
state="$(flow_state_file "$root")"
if flow_state_active "$state"; then flow_active=1; fi

ROOT="$root"
ready_label="$(triage_label_for ready-for-agent)"
wontfix_label="$(triage_label_for wontfix)"
human_label="$(triage_label_for ready-for-human)"

# The fixed closing rules live in orch-interview's SKILL.md, under "## Closing"
# (#1980): Claude Code keeps hook context of 10 KB or more out of the
# conversation, so this message carries only what depends on the session.
plugin_root="$(hook_plugin_root)"
closing_skill="$plugin_root/skills/orch-interview/SKILL.md"
orch_path="$plugin_root/scripts/orch.sh"
if [ "$host" = junie ]; then
  ask_tool="the ask_user tool"
  next_redo="the **Next phase** and **Redo** sections of $plugin_root/skills/orch-flow/SKILL.md
    (this host has no plugin commands: read that file and follow the section
    the user picks)"
else
  ask_tool="the AskUserQuestion tool"
  next_redo="/orchestrator:next or /orchestrator:redo"
fi

# The orch-interview skill loads in full, so its entry point needs no pointer.
# Every other entry point, and Junie's plan-confirmed prompt, reads the section.
point_to_closing=1
if [ "$plan_confirmed" = 1 ]; then
  :
elif [ "$event" = UserPromptSubmit ]; then
  if [[ "$prompt" =~ $(entry_pattern orch-interview) ]]; then point_to_closing=0; fi
else
  case "$skill" in *orch-interview*) point_to_closing=0 ;; esac
fi
if [ "$point_to_closing" = 1 ]; then
  closing_line="- The rules for closing this planning are in the \`## Closing\` section of
  $closing_skill. Read that section by this absolute path before the close, with
  \$ORCH there being $orch_path."
else
  closing_line="- The rules for closing this planning are in the \`## Closing\` section of the orch-interview skill."
fi

# The active flow, named by whatever state.json holds: its issue, else its
# slug with "has no issue yet", else neither; plus its phase, where a null
# phase is a flow init just started. Only state that cannot be read as a JSON
# object leaves it unnamed, with no phase claimed.
flow_branches=""
confirm_lead="Before you implement anything"
if [ "$flow_active" = 1 ]; then
  flow_readable=0 flow_issue="" flow_slug="" flow_phase=""
  if flow_state_readable "$state"; then
    flow_readable=1
    flow_issue="$(flow_state_get "$state" issue)"
    flow_slug="$(flow_state_get "$state" slug)"
    flow_phase="$(flow_state_get "$state" phase)"
  fi
  if [ -n "$flow_phase" ]; then flow_at="at phase $flow_phase"; else flow_at="just started"; fi
  if [ "$flow_readable" = 0 ]; then
    flow_named="a flow is active in this checkout"
    flow_subject="that flow's own work"
  elif [ -n "$flow_issue" ]; then
    flow_named="the flow for #$flow_issue is active in this checkout, $flow_at"
    flow_subject="this flow's issue, #$flow_issue"
  elif [ -n "$flow_slug" ]; then
    flow_named="the flow $flow_slug is active in this checkout, $flow_at; it has no issue yet"
    flow_subject="this flow's change"
  else
    flow_named="a flow with no issue or slug is active in this checkout, $flow_at"
    flow_subject="this flow's change"
  fi
  flow_branches="- Beside this planning session, ${flow_named}. At the close, decide
  from this planning session's conversation which of two cases applies:
  - If this planning was about ${flow_subject}: ask no route question and
    skip the interviewed-issue step and the done-close, since that flow already holds the
    work. The next step is that flow's: point the user to ${next_redo}.
  - Otherwise: run the interviewed-issue step and the done-close
    unchanged, then the route question unless the done-close applies."
  confirm_lead="Only in the second case above (planning about anything else): before you implement anything"
fi

session_facts="- This repo's triage labels: ready-for-agent is \`${ready_label}\`, wontfix is \`${wontfix_label}\`, ready-for-human is \`${human_label}\`.
- Ask the closing questions with ${ask_tool}."

if [ "$plan_confirmed" = 1 ]; then
  hook_emit_context "$event" "The orchestrator plugin is installed in this repo, and the user just
confirmed a plan from a planning session.
${flow_branches:+
$flow_branches}
${closing_line}
${session_facts}
- ${confirm_lead}, and without editing any file first, ask the
  user how to carry the plan out, by the Closing section's route question."
  exit 0
fi

context="The orchestrator plugin is installed in this repo. Planning is phase one
of an orchestrated flow: plan -> spec -> implement -> review, where each phase
runs in a fresh session connected by handoff files.

While this planning session is running:

- Do NOT offer to implement, and do NOT write or edit code. Planning artifacts
  ($(planning_allowlist_text)) are fine; source files are not.
- Glossary and ADR changes ($(planning_records_text)) are records: never edit them. Write the exact wording you intend into the plan, so the spec carries it verbatim.
${flow_branches:+$flow_branches
}${closing_line}
${session_facts}
- When you reach a shared understanding, do not close with a scripted line and
  do not decide the next step yourself: close as the Closing section says.

If this session runs under a wayfinder skill, \"approved\" means the
whole map is done, not that one ticket resolved. Do not start the flow after a single ticket."

hook_emit_context "$event" "$context"
