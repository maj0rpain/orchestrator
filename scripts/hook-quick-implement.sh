#!/usr/bin/env bash
#
# PostToolUse hook on the Skill tool, same matcher as hook-grilling.sh.
#
# A human choosing "quick implementation" at hook-grilling.sh's closing
# question calls Skill("orchestrator:quick-implement"), which is the one
# reliable choke point for noticing that the marker no longer applies. This
# hook deletes it, so hook-guard.sh's edit guard lifts without hook-guard.sh
# itself changing at all - see
# docs/adr/0006-quick-implementation-unblocks-the-edit-guard-by-deleting-the-planning-marker.md.

set -euo pipefail

input="$(cat)"
skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')"
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"

case "$skill" in *quick-implement*) ;; *) exit 0 ;; esac

rm -f "${TMPDIR:-/tmp}/orchestrator-grilling-${session}"
