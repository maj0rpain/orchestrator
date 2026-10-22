#!/usr/bin/env bash
#
# PreToolUse hook on AskUserQuestion: the paste guard (#1287).
#
# An attended spec review must paste `spec-review check`'s view into chat
# before it asks the human about it, and in later rounds it drifts into asking
# with no view on screen. `check` saves the view it printed to <dir>/view.md
# and names that file in its stderr pass line; this hook reads the session's
# transcript and refuses every ask after such a pass line until the view is
# in chat, handing the view back with the instruction to end the turn on it
# and the batch question in plain text, not the ask tool (#1350, ADR-0051):
# some hosts hide a long text written in the same response as a tool call.
# The short confirmation ask after a near-miss answer passes, its view
# already in the turn-final reply above.
#
# The arming, disarming, paste matching, re-read window and fail-open cases
# are paste-guard.sh's, shared with the Stop guard, hook-paste-stop-guard.sh.
# Here, while armed, every AskUserQuestion is refused, an ask unrelated to the
# spec review too, unless one assistant text block written after the arming
# pass line holds the view; an earlier ask, refused or not, proves nothing.
# An unknown payload, or one with no transcript_path, allows the ask too.
#
# Claude Code only: Junie's nudge in the pass line is the whole enforcement
# there (docs/host-capabilities.md, "Guard the batch question").

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/paste-guard.sh"

paste_guard_payload || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "AskUserQuestion" ] || exit 0
paste_guard_check "$transcript" since && exit 0

hook_emit_deny "Blocked by the orchestrator: the human has not seen this round's view in chat. Do not ask this question with the ask tool. $(paste_guard_instruction)"
