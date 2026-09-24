# hook-common.sh - shared stdin extraction for the Skill-matcher hooks.
#
# hook-grilling.sh and hook-quick-implement.sh are both PostToolUse hooks on
# the Skill tool, and both need the invoked skill name and the session id out
# of the same JSON payload, with the same defaults. Sourced by each, not
# executed on its own.

# Reads the raw hook JSON from stdin and sets `input`, `skill`, and `session`
# in the caller's shell. `input` is left set afterward so a caller that needs
# another field from the same payload (e.g. hook-grilling.sh's `cwd`) can
# extract it without reading stdin a second time.
hook_read_skill_and_session() {
  input="$(cat)"
  skill="$(printf '%s' "$input" | jq -r '.tool_input.skill // ""')"
  session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
}

# Writes a PreToolUse deny as one JSON object both hosts understand: Claude
# Code reads hookSpecificOutput, Junie reads the top-level decision/reason.
# "block" is the one top-level decision value both hosts accept.
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
