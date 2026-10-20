#!/usr/bin/env bash
#
# PreToolUse hook on AskUserQuestion: the paste guard (#1287).
#
# An attended spec review must paste `spec-review check`'s view into chat
# before it asks the human about it, and in later rounds it drifts into asking
# with no view on screen. `check` saves the view it printed to <dir>/view.md
# and names that file in its stderr pass line; this hook reads the session's
# transcript and refuses the first ask after such a pass line, handing the
# view back with the instruction to paste it word for word, then ask again.
#
# The fallback form, refusing the first ask once rather than checking the
# chat for the paste: Claude Code does not reliably write a response's text
# block to the transcript by the time PreToolUse fires for that response's
# tool call (observed on #1294), so a paste in the same response as the ask
# cannot be seen. The first ask is told apart from the next by the transcript
# alone: an AskUserQuestion tool_use after the arming pass line, other than
# this call's own, means it was made.
#
# - Armed by the latest `check` pass line in a tool result that names a
#   view.md (scripts/orch/spec-review.sh's spec_review_nudge words it).
# - Disarmed by a later Bash tool_use whose command contains
#   `spec-review apply`, whatever its exit status.
# - Fails open: an unknown payload, no transcript_path, a missing or
#   unreadable transcript, a view.md deleted or empty, or a transcript with
#   no arming pass line all allow the ask.
#
# Claude Code only: Junie's nudge in the pass line is the whole enforcement
# there (docs/host-capabilities.md, "Guard the batch question").

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

input="$(cat)"
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "AskUserQuestion" ] || exit 0
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
self="$(printf '%s' "$input" | jq -r '.tool_use_id // ""')"
[ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || exit 0

# One pass over the transcript, a line at a time, any line that is not JSON
# skipped. Prints the armed view.md's path, or nothing when the guard is not
# armed: no arming pass line, an apply after it, or an ask already made after
# it. Only assistant and user entries count, never a request blob's copies.
view="$(jq -nrR --arg self "$self" '
  def text: if type == "string" then . elif type == "array"
    then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
    else "" end;
  reduce (inputs | fromjson? | select(type == "object")) as $e (
    {view: null, done: false};
    if $e.type == "user" and ($e.message.content | type) == "array" then
      reduce ($e.message.content[] | select(type == "object" and .type == "tool_result")
              | .content | text | split("\n")[]
              | capture("\\.md passes: .*; it is saved in (?<p>/.*/view\\.md)$")?
              | .p) as $p (.; .view = $p | .done = false)
    elif $e.type == "assistant" and ($e.message.content | type) == "array" then
      reduce ($e.message.content[] | select(type == "object" and .type == "tool_use")) as $u (.;
        if .view == null then .
        elif $u.name == "Bash" and (($u.input.command // "") | tostring | contains("spec-review apply")) then .done = true
        elif $u.name == "AskUserQuestion" and ($u.id // "") != $self then .done = true
        else . end)
    else . end)
  | if .view != null and (.done | not) then .view else empty end
' <"$transcript" 2>/dev/null)" || exit 0
[ -n "$view" ] && [ -s "$view" ] && [ -r "$view" ] || exit 0

hook_emit_deny "Blocked by the orchestrator: the human has not seen this round's view in chat. Paste the view below into chat word for word - every line, composing nothing of your own - then ask again, the paste and the ask in the same response. It is the view \`spec-review check\` printed and saved in $view:

$(cat "$view")"
