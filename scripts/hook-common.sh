# hook-common.sh - shared payload reading and output writing for the hooks.
#
# Every hook reads the same JSON payload from stdin and, when it decides or
# injects context, writes one JSON object. Hosts differ in both: Junie's
# PreToolUse payload carries neither session_id nor cwd, and Junie reads its
# decision and context from top-level fields where Claude Code reads
# hookSpecificOutput. Sourced by each hook, not executed on its own.

# Reads the raw hook JSON from stdin and sets `input`, `session`, `cwd`, and
# `host` in the caller's shell. A missing session_id leaves `session` empty,
# which means "not guarded": no planning marker can be keyed to it. `cwd`
# prefers Junie's project_path, because Junie's own cwd is ~/.junie, not the
# repo (#202); this also moves where hook-guard.sh resolves a relative path on
# Junie. A payload with neither falls back to the process working directory.
# `host` is junie when the payload carries project_path, which Claude Code's
# never does, else claude. `input` is left set so a caller can extract further
# fields without reading stdin a second time.
hook_read_payload() {
  input="$(cat)"
  session="$(printf '%s' "$input" | jq -r '.session_id // ""')"
  local project
  project="$(printf '%s' "$input" | jq -r '.project_path // ""')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
  if [ -n "$project" ]; then host=junie; cwd="$project"; else host=claude; fi
  [ -n "$cwd" ] || cwd="$PWD"
}

# hook_read_payload, plus `skill`: the skill name out of a Skill tool call.
hook_read_skill_and_session() {
  hook_read_payload
  skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')"
}

# Writes a PreToolUse deny as one JSON object both hosts understand: Claude
# Code reads hookSpecificOutput, Junie reads the top-level decision/reason.
# "block" is Claude Code's legacy top-level value; that Junie accepts it too is
# unverified until the manual Junie acceptance run (#121).
hook_emit_deny() {
  jq -n --arg r "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    },
    decision: "block",
    reason: $r
  }'
}

# Writes injected context as one JSON object both hosts understand: Claude
# Code reads hookSpecificOutput, Junie reads the top-level additionalContext.
# $1 is the hook event name, $2 the context.
hook_emit_context() {
  jq -n --arg e "$1" --arg c "$2" '{
    hookSpecificOutput: {
      hookEventName: $e,
      additionalContext: $c
    },
    additionalContext: $c
  }'
}
