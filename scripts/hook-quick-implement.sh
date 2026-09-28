#!/usr/bin/env bash
#
# PostToolUse hook on the Skill tool, same matcher as hook-grilling.sh, and
# PreToolUse hook on the Read tool.
#
# A human choosing "quick implementation" at hook-grilling.sh's closing
# question calls Skill("orchestrator:orch-quick-implement"), which is the one
# reliable choke point for noticing that the marker no longer applies. This
# hook deletes it, so hook-guard.sh's edit guard lifts without hook-guard.sh
# itself changing at all - see
# docs/adr/0006-quick-implementation-unblocks-the-edit-guard-by-deleting-the-planning-marker.md.
#
# A host with no Skill tool (Junie) runs the skill by reading its SKILL.md,
# the path hook-grilling.sh hands it, so a Read of exactly this install's
# copy is the same choke point there - see
# docs/adr/0023-quick-implementation-lifts-the-edit-guard-on-a-read-of-its-skill-file.md.
# No host gate: Junie's PreToolUse may lack project_path, which is how
# hook_read_payload tells the hosts apart, so the exact installed path is the
# whole condition. Reading a repo checkout's copy, as when working on this
# plugin, does not lift it.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

hook_read_skill_and_session

# Either trigger lifts it; hooks.json scopes which events reach this hook, so
# neither branch leans on a tool_name Junie's payload may not carry.
plugin_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$skill" in
  orch-quick-implement|*:orch-quick-implement) ;;
  *) [ "$(hook_tool_path)" = "$plugin_root/skills/orch-quick-implement/SKILL.md" ] || exit 0 ;;
esac

[ -n "$session" ] || exit 0
rm -f "${TMPDIR:-/tmp}/orchestrator-grilling-${session}"
