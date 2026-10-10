#!/usr/bin/env bash
#
# Delivers the planning message once per session when planning starts. One script, two hosts; the tool that asks the closing question
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
# per session. Beside a running flow it still sends the planning rules, with a
# closing that names that flow and states two branches: about that flow, point
# to its next or redo; about anything else, the interviewed-issue step and the
# route question, where only Blueprint runs in this checkout and Start and
# Quick implementation proceed in a side checkout (#640, #729). With no flow,
# a human's request for a side checkout is honoured.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"
# For triage_label_for, so the closing step names this repo's own triage
# labels. The module reads the labels doc at $ROOT/$LABELS_DOC and needs
# only ROOT, set below.
source "$(dirname "${BASH_SOURCE[0]}")/triage-labels.sh"

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

# Beside an active flow (#640): the planning may be re-planning that flow, or a
# different change planned in another terminal on the same checkout. The hook
# cannot tell which - the skill's arguments are free text - so it sends the
# planning rules with a closing that names the flow and states both branches,
# and the model picks one. A done flow is finished work, so planning beside it
# gets the ordinary message.
flow_active=0
if hook_flow_active "$root"; then flow_active=1; fi

ROOT="$root"
ready_label="$(triage_label_for ready-for-agent)"
wontfix_label="$(triage_label_for wontfix)"
human_label="$(triage_label_for ready-for-human)"

# How to run each route, split so that beside an active flow (#640, #729) the
# flow and quick-implementation routes run on their side-checkout route: they
# must not run in a checkout whose branch belongs to the running flow. With no
# active flow, a human's request for a side checkout is honoured instead.
if [ "$host" = junie ]; then
  ask_tool="the ask_user tool"
  ask_step="Call the ask_user tool with
  exactly three options:"
  plugin_root="$(hook_plugin_root)"
  next_redo="the **Next phase** and **Redo** sections of $plugin_root/skills/orch-flow/SKILL.md
    (this host has no plugin commands: read that file and follow the section
    the user picks)"
  run_flow_quick="On \"Start the orchestrator flow\", run the orch-flow skill yourself; on
  \"Quick implementation\", the orch-quick-implement skill. "
  run_blueprint="On \"Blueprint
  only\", run each step of the Blueprint route below as its skill - orch-to-spec for issue #<n>, the interviewed issue, when there is one
  (its rewrite mode), orch-spec-review, and orch-to-tickets. This host has no Skill tool, so read each
  skill's file and follow it verbatim:"
  run_review_rounds="follow orch-spec-review for issue #<n> with --rounds <count>"
  flow_quick_files="
  $plugin_root/skills/orch-flow/SKILL.md,
  $(hook_quick_skill_file),"
  run_flow_quick_side="On \"Start the orchestrator flow\", run the orch-flow skill yourself; on
  \"Quick implementation\", the orch-quick-implement skill - each as asked for a side checkout, so it takes its **Starting in a side checkout** route. "
  side_request="
  If the user asks for a side checkout - a git worktree of its own, opened in
  its own session - honour it: on \"Start the orchestrator flow\" or \"Quick
  implementation\", follow that skill's **Starting in a side checkout** section."
  blueprint_files="
  $plugin_root/skills/orch-to-spec/SKILL.md,
  $plugin_root/skills/orch-spec-review/SKILL.md (its standalone spec review), and
  $plugin_root/skills/orch-to-tickets/SKILL.md."
else
  ask_tool="the AskUserQuestion tool"
  next_redo="/orchestrator:next or /orchestrator:redo"
  ask_step="Call the AskUserQuestion tool with
  exactly three options:"
  run_flow_quick="On \"Start the orchestrator flow\", call the Skill tool with
  \"orchestrator:orch-flow\" yourself. On \"Quick implementation\", call the Skill
  tool with \"orchestrator:orch-quick-implement\" yourself. "
  run_blueprint="On \"Blueprint
  only\", call the Skill tool yourself for each step of the Blueprint route below:
  \"orchestrator:orch-to-spec\", with args set to the interviewed issue's number when there is one
  (its rewrite mode), \"orchestrator:orch-spec-review\" (its standalone spec review),
  and \"orchestrator:orch-to-tickets\". The
  orchestrator's skills are model-invocable: call them, do not hand them to the
  user."
  run_review_rounds="call the Skill tool with \"orchestrator:orch-spec-review\" and args \"<n> --rounds <count>\""
  run_flow_quick_side="On \"Start the orchestrator flow\",
  call the Skill tool with \"orchestrator:orch-flow\" and args \"--side\" yourself.
  On \"Quick implementation\",
  call the Skill tool with \"orchestrator:orch-quick-implement\" and args \"--side\" yourself. "
  side_request="
  If the user asks for a side checkout - a git worktree of its own, opened in
  its own session - honour it: pass args \"--side\" to whichever of those two skills runs."
  flow_quick_files=""
  blueprint_files=""
fi

# The active flow, named by whatever state.json holds: its issue, else its
# slug with "has no issue yet", else neither; plus its phase, where a null
# phase is a flow init just started. Only state that cannot be read as a JSON
# object leaves it unnamed, with no phase claimed.
flow_branches=""
route_here="$side_request"
# The branches stand in place of the route question (#640): beside a flow, the
# question's bullet opens by scoping itself to the second case.
confirm_lead="Before you implement anything"
close_lead="When you reach a shared understanding"
if [ "$flow_active" = 1 ]; then
  state="$root/.orchestrator/state.json"
  flow_readable=0 flow_issue="" flow_slug="" flow_phase=""
  if jq -e 'type == "object"' "$state" >/dev/null 2>&1; then
    flow_readable=1
    flow_issue="$(jq -r '.issue // "" | tostring' "$state")"
    flow_slug="$(jq -r '.slug // "" | tostring' "$state")"
    flow_phase="$(jq -r '.phase // "" | tostring' "$state")"
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
    skip the interviewed-issue step below, since that flow already holds the
    work. The next step is that flow's: point the user to ${next_redo}.
  - Otherwise: run the interviewed-issue step below unchanged, then the route
    question below."
  only_second="Only in the second case above (planning about anything else):"
  confirm_lead="$only_second before you implement anything"
  close_lead="$only_second when you reach a shared understanding"
  route_here="
  Blueprint only is the one route that runs in this checkout, whose branch
  belongs to the running flow: \"Start the orchestrator flow\" and \"Quick implementation\" proceed in a side checkout,
  a git worktree of their own opened in its own session, so run their skills
  only on that route, as above - never in this checkout."
  # Beside a flow, Start and Quick implementation take the side-checkout route.
  run_flow_quick="$run_flow_quick_side"
fi
run_next="- ${run_flow_quick}${run_blueprint}${flow_quick_files}${blueprint_files}"

# The interviewed issue (#571): an open issue the planning was about is
# offered a move to ready-for-agent before the route question, so init
# --issue can adopt it. Its lines are bullets, never numbered: the route
# question's three options are the only numbered lines in the message.
interviewed_step="- At the close, if this planning was about an open issue - named in the
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
      2. Quick implementation - hands-off, for small changes: implement this directly, with no further questions before the PR.
      3. Blueprint only - write the spec (rewriting the interviewed issue, if
         there is one) and its ticket breakdown, then stop; implement later.

${run_next} Do not ask the user to type a command.${route_here}

- On \"Blueprint only\": when the interviewed-issue step settled an
  interviewed issue - the one this planning was about, or the one the user named under \"It's a different issue\" -
  whether the user moved it to its triage label or answered \"Skip\",
  write the spec in rewrite mode on that issue, replacing #<n>'s body instead of publishing a new issue
  (orch-to-spec, handed #<n>). Only with no interviewed issue, publish the spec as a new issue
  (orch-to-spec). Either way, write any glossary or
  ADR wording the planning decided into the issue body verbatim.
  The route's steps run in this order, and one rule covers every step: when a step stops or fails, stop there - run no later step, and report why it stopped.
  orch-to-spec stops when it ends without reporting the issue number. Once it has reported the number,
  ask the user how many spec review rounds to run on it, as one blocking question with ${ask_tool},
  with the options 3 (Recommended), 1, 5, and Other for any other whole number from 0 up,
  where 0 skips the review. 0 is the deliberate lower bound.
  An Other that is not a whole number from 0 up is asked again, naming the range;
  ask every time, never assume.
  On a count of 1 or more, run the standalone orch-spec-review for that many
  rounds: ${run_review_rounds}. Then publish
  its ticket breakdown (orch-to-tickets) against that issue, unless rewrite mode reported the breakdown \`kept\`:
  then skip that step. Rewrite mode reports the breakdown; run no breakdown check of your own.
  If orch-to-tickets fails after rewrite mode retired a breakdown, the report also says that #<n> carries its new body and no ticket breakdown, and needs /orchestrator:to-tickets <n>. Then stop: do not
  implement or edit source. Report the issue number and how to pick it up
  later: /orchestrator:start --issue <n>, or a quick implementation that names
  the issue."

if [ "$plan_confirmed" = 1 ]; then
  hook_emit_context "$event" "The orchestrator plugin is installed in this repo, and the user just
confirmed a plan from a planning session.
${flow_branches:+
$flow_branches}
${interviewed_step}
- ${confirm_lead}, and without editing any file first, ask the
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
${flow_branches:+$flow_branches
}${interviewed_step}
- ${close_lead}, do not close with a scripted line and
  do not decide the next step yourself. ${choice}

If this session runs under a wayfinder skill, \"approved\" means the
whole map is done, not that one ticket resolved. Do not start the flow after a single ticket."

hook_emit_context "$event" "$context"
