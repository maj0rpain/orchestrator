#!/usr/bin/env bash
#
# Stop hook: the paste guard's Stop half (#1421).
#
# A spec review ends its turn on one plain-text reply holding `spec-review
# check`'s view and the batch question (ADR-0051): some hosts hide a long text
# written in the same response as a tool call, so the turn-final reply is
# where the human sees the view. This hook refuses to let the turn end while
# the paste guard is armed unless the final reply holds the view, handing the
# view back with the instruction to end the turn on it and the question in
# plain text.
#
# The arming, disarming, paste matching, re-read window and fail-open cases
# are paste-guard.sh's, shared with the PreToolUse guard, hook-paste-guard.sh.
# Here the paste must be in the final reply: one assistant text block written
# after the later of the last human message and the arming pass line. A view
# pasted in an earlier turn, or before a re-run check's pass line, does not
# count.
#
# - Allows when the payload's stop_hook_active is set: the session is already
#   going on from this guard's refusal, so it cannot loop.
# - Fails open as the PreToolUse guard does: a payload that is not a JSON
#   object, or no transcript_path, allows too.
#
# Junie reads the same hooks file, and a Stop entry has no tool matcher, so
# this may fire there; whether Junie fires Stop is unverified, and on its
# payload or transcript the hook fails open like any unreadable input
# (docs/host-capabilities.md, "Guard the batch question").

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/paste-guard.sh"

hook_read_payload 2>/dev/null
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
[ "$(printf '%s' "$input" | jq -r '.stop_hook_active == true')" = true ] && exit 0
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
paste_guard_check "$transcript" final && exit 0

hook_emit_block "Blocked by the orchestrator: the human has not seen this round's view in your final reply. $(paste_guard_instruction)"
