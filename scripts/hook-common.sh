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
