#!/usr/bin/env bash
#
# PreToolUse hook on AskUserQuestion: the paste guard (#1287).
#
# An attended spec review must paste `spec-review check`'s view into chat
# before it asks the human about it, and in later rounds it drifts into asking
# with no view on screen. `check` saves the view it printed to <dir>/view.md
# and names that file in its stderr pass line; this hook reads the session's
# transcript and refuses every ask after such a pass line until the view is
# in chat, handing the view back with the instruction to paste it word for
# word, then ask again (#1350).
#
# - Armed by the latest `check` pass line in a tool result that names a
#   view.md (scripts/orch/spec-review.sh's spec_review_nudge words it).
# - While armed, every AskUserQuestion is refused, an ask unrelated to the
#   spec review too, unless one assistant text block written after that pass
#   line holds every non-blank line of view.md, both compared with their
#   whitespace normalised (runs collapsed to one space, ends trimmed), so a
#   re-wrapped paste counts and a view split across blocks does not. An
#   earlier ask, refused or not, proves nothing.
# - Before refusing, re-reads the transcript for up to PASTE_GUARD_WAIT
#   seconds: Claude Code does not reliably write a response's text block to
#   the transcript by the time PreToolUse fires for that response's tool call
#   (#1294). An ask whose view is already in chat is allowed on the first
#   read. ORCH_PASTE_GUARD_WAIT may shorten the window, for the tests.
# - Disarmed by a later Bash tool_use whose command contains
#   `spec-review apply`, whatever its exit status.
# - Only assistant and user entries count, never a request blob's copies, and
#   a line that is not JSON is skipped.
# - Fails open: an unknown payload, no transcript_path, a missing or
#   unreadable transcript, a view.md deleted or empty, or a transcript with
#   no arming pass line all allow the ask.
#
# Claude Code only: Junie's nudge in the pass line is the whole enforcement
# there (docs/host-capabilities.md, "Guard the batch question").

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

# Seconds the guard keeps re-reading the transcript for the paste before it
# refuses. ORCH_PASTE_GUARD_WAIT, a whole number of seconds no larger, may
# shorten it.
PASTE_GUARD_WAIT=3

hook_read_payload 2>/dev/null
printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || exit 0
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
[ "$tool" = "AskUserQuestion" ] || exit 0
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
[ -n "$transcript" ] && [ -f "$transcript" ] && [ -r "$transcript" ] || exit 0

wait_s="$PASTE_GUARD_WAIT"
case "${ORCH_PASTE_GUARD_WAIT:-}" in
  ''|*[!0-9]*) ;;
  *) [ "$ORCH_PASTE_GUARD_WAIT" -ge "$PASTE_GUARD_WAIT" ] || wait_s="$ORCH_PASTE_GUARD_WAIT" ;;
esac

# Prints the armed view.md's path on its first line, then a JSON array of the
# assistant text blocks written after its pass line - or nothing when the
# guard is not armed: no arming pass line, or an apply after it. One pass
# over the transcript, a line at a time.
paste_guard_scan() {
  jq -nrR '
    def text: if type == "string" then . elif type == "array"
      then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
      else "" end;
    reduce (inputs | fromjson? | select(type == "object")) as $e (
      {view: null, texts: []};
      if $e.type == "user" and ($e.message.content | type) == "array" then
        reduce ($e.message.content[] | select(type == "object" and .type == "tool_result")
                | .content | text | split("\n")[]
                | capture("\\.md passes: .*; it is saved in (?<p>/.*/view\\.md)$")?
                | .p) as $p (.; .view = $p | .texts = [])
      elif $e.type == "assistant" and ($e.message.content | type) == "array" then
        reduce ($e.message.content[] | select(type == "object")) as $b (.;
          if .view == null then .
          elif $b.type == "text" then .texts += [$b.text // "" | tostring]
          elif $b.type == "tool_use" and $b.name == "Bash"
            and (($b.input.command // "") | tostring | contains("spec-review apply"))
            then .view = null | .texts = []
          else . end)
      else . end)
    | if .view != null then .view, (.texts | tojson) else empty end
  ' <"$transcript" 2>/dev/null
}

# Succeeds when one of the text blocks (a JSON array, $1) holds every
# non-blank line of the view file $2, whitespace normalised on both sides. The
# blocks go in on stdin, which no argument length limit caps.
paste_guard_pasted() {
  printf '%s' "$1" | jq -e --rawfile view "$2" '
    def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    [$view | split("\n")[] | norm | select(. != "")] as $lines
    | any(.[] | norm; . as $t | all($lines[]; . as $l | $t | contains($l)))
  ' >/dev/null 2>&1
}

tries=$((wait_s * 4))
while :; do
  scan="$(paste_guard_scan)" || exit 0
  view="${scan%%$'\n'*}"
  [ -n "$view" ] && [ -s "$view" ] && [ -r "$view" ] || exit 0
  paste_guard_pasted "${scan#*$'\n'}" "$view" && exit 0
  [ "$tries" -gt 0 ] || break
  tries=$((tries - 1))
  sleep 0.25
done

hook_emit_deny "Blocked by the orchestrator: the human has not seen this round's view in chat. Paste the view below into chat word for word - every line, composing nothing of your own - then ask again, the paste and the ask in the same response. It is the view \`spec-review check\` printed and saved in $view:

$(cat "$view")"
