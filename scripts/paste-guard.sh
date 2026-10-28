# shellcheck shell=bash
# paste-guard.sh - the transcript scan and paste check shared by the two
# paste guards: hook-paste-guard.sh (PreToolUse on AskUserQuestion, #1287) and
# hook-paste-stop-guard.sh (Stop, #1421). Sourced by each, not executed on its
# own. Both arm on the same `spec-review check` pass line, disarm on the same
# `spec-review apply`, match the paste the same way and re-read over the same
# window; they differ only in which text blocks may hold the paste.
#
# - Armed by the latest `check` pass line in a tool result that names a
#   view.md (scripts/orch/spec-review.sh's spec_review_nudge words it). An
#   unattended check's pass line carries no such tail, so it never arms.
# - Disarmed by a later Bash tool_use whose command contains
#   `spec-review apply`, whatever its exit status. The apply wins within its
#   own call: a tool_result answering such a tool_use (by tool_use_id) never
#   arms, so a combined `check && apply` call leaves the guard disarmed. A
#   result with no tool_use_id, or another id, arms as usual.
# - A paste is one assistant text block holding every non-blank line of
#   view.md, both compared with their whitespace normalised (runs collapsed to
#   one space, ends trimmed), so a re-wrapped paste counts and a view split
#   across blocks does not.
# - Only assistant and user entries count, never a request blob's copies, and
#   a line that is not JSON is skipped.
# - A human message is a user entry not marked isMeta whose content is a
#   string, or an array holding a text block and no tool_result. Tool results
#   and isMeta entries (skill-load bodies, command caveats) are not.
# - Re-reads the transcript for up to PASTE_GUARD_WAIT seconds before it
#   refuses: Claude Code does not reliably write a response's text block to the
#   transcript by the time a hook fires (#1294). A paste already written is
#   seen on the first read. ORCH_PASTE_GUARD_WAIT may shorten the window, for
#   the tests.
# - Fails open: a missing or unreadable transcript, a view.md deleted, empty
#   or unreadable, a transcript with no arming pass line, or a mode other than
#   since or final all allow.

# Seconds the guards keep re-reading the transcript for the paste before they
# refuse. ORCH_PASTE_GUARD_WAIT, a whole number of seconds no larger, may
# shorten it.
PASTE_GUARD_WAIT=3

# paste_guard_payload: reads the hook payload on stdin (hook_read_payload, so
# `input` holds it) and sets `transcript` to its transcript_path, or empty when
# it names none; fails - the guard allows - when the payload is not a JSON
# object.
paste_guard_payload() {
  hook_read_payload 2>/dev/null
  # shellcheck disable=SC2154 # input is set by hook_read_payload, in hook-common.sh
  printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
  # shellcheck disable=SC2034 # transcript is read by the hook that sourced this file
  transcript="$(printf '%s' "$input" | jq -r '.transcript_path // ""')"
}

# paste_guard_scan <transcript>: prints the armed view.md's path on its first
# line, then a JSON array of the assistant text blocks written after its pass
# line, then a JSON array of those written after the later of that pass line
# and the last human message - or nothing when the guard is not armed: no
# arming pass line, or an apply after it. One pass over the transcript, a
# line at a time.
paste_guard_scan() {
  jq -nrR '
    def text: if type == "string" then . elif type == "array"
      then map(select(type == "object" and .type == "text") | .text // "") | join("\n")
      else "" end;
    def human: .type == "user" and (.isMeta != true)
      and (.message.content | (type == "string") or (type == "array"
        and any(.[]; type == "object" and .type == "text")
        and (any(.[]; type == "object" and .type == "tool_result") | not)));
    reduce (inputs | fromjson? | select(type == "object")) as $e (
      {view: null, texts: [], final: [], applied: []};
      if ($e | human) then .final = []
      elif $e.type == "user" and ($e.message.content | type) == "array" then
        . as $st
        | reduce ($e.message.content[] | select(type == "object" and .type == "tool_result")
                | select(((.tool_use_id // null) as $id | $id != null and ($st.applied | index($id) != null)) | not)
                | .content | text | split("\n")[]
                | capture("\\.md passes: .*; it is saved in (?<p>/.*/view\\.md)$")?
                | .p) as $p (.; .view = $p | .texts = [] | .final = [])
      elif $e.type == "assistant" and ($e.message.content | type) == "array" then
        reduce ($e.message.content[] | select(type == "object")) as $b (.;
          if $b.type == "tool_use" and $b.name == "Bash"
            and (($b.input.command // "") | tostring | contains("spec-review apply"))
            then .applied += [$b.id // ""] | .view = null | .texts = [] | .final = []
          elif .view == null then .
          elif $b.type == "text" then ($b.text // "" | tostring) as $t | .texts += [$t] | .final += [$t]
          else . end)
      else . end)
    | if .view != null then .view, (.texts | tojson), (.final | tojson) else empty end
  ' <"$1" 2>/dev/null
}

# paste_guard_pasted <blocks> <view.md>: succeeds when one of the text blocks
# (a JSON array) holds every non-blank line of the view file, whitespace
# normalised on both sides. The blocks go in on stdin, which no argument
# length limit caps.
paste_guard_pasted() {
  printf '%s' "$1" | jq -e --rawfile view "$2" '
    def norm: gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "");
    [$view | split("\n")[] | norm | select(. != "")] as $lines
    | any(.[] | norm; . as $t | all($lines[]; . as $l | $t | contains($l)))
  ' >/dev/null 2>&1
}

# paste_guard_check <transcript> <blocks>: succeeds - allow - when the guard is
# not armed, fails open, or finds the paste within the re-read window; fails -
# refuse - otherwise, with `paste_guard_view` set in the caller's shell to the
# armed view.md (pass it to paste_guard_instruction). <blocks> picks the text
# blocks that may hold the paste: since, those after the arming pass line;
# final, the final reply. Any other mode allows.
paste_guard_check() {
  local wait_s tries scan rest blocks
  wait_s="$PASTE_GUARD_WAIT"
  case "${ORCH_PASTE_GUARD_WAIT:-}" in
    ''|*[!0-9]*) ;;
    *) [ "$ORCH_PASTE_GUARD_WAIT" -ge "$PASTE_GUARD_WAIT" ] || wait_s="$ORCH_PASTE_GUARD_WAIT" ;;
  esac
  [ -n "$1" ] && [ -f "$1" ] && [ -r "$1" ] || return 0
  tries=$((wait_s * 4))
  while :; do
    scan="$(paste_guard_scan "$1")" || return 0
    paste_guard_view="${scan%%$'\n'*}"
    [ -n "$paste_guard_view" ] && [ -s "$paste_guard_view" ] && [ -r "$paste_guard_view" ] || return 0
    rest="${scan#*$'\n'}"
    case "$2" in
      since) blocks="${rest%%$'\n'*}" ;;
      final) blocks="${rest#*$'\n'}" ;;
      *) return 0 ;;
    esac
    paste_guard_pasted "$blocks" "$paste_guard_view" && return 0
    [ "$tries" -gt 0 ] || return 1
    tries=$((tries - 1))
    sleep 0.25
  done
}

# paste_guard_instruction <view.md>: the instruction both guards hand back on
# refusing, naming <view.md> and ending on its contents.
paste_guard_instruction() {
  printf '%s' "End your turn on one plain-text reply, with no tool call: the view below word for word - every line, composing nothing of your own - then the question, its answer words spelled out; the human's next message is the answer. It is the view \`spec-review check\` printed and saved in $1:

$(cat "$1")"
}
