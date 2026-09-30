# hook-common.sh - shared payload reading and output writing for the hooks.
#
# Every hook reads the same JSON payload from stdin and, when it decides or
# injects context, writes one JSON object. Hosts differ in both: Junie's
# PreToolUse payload carries no cwd (its session_id, missing from Junie's
# bundled docs, is there from build 3419.7), and Junie reads its
# decision and context from top-level fields where Claude Code reads
# hookSpecificOutput. Sourced by each hook, not executed on its own.

# Reads the raw hook JSON from stdin and sets `input`, `session`, `cwd`, and
# `host` in the caller's shell. A missing session_id leaves `session` empty,
# which means "not guarded": no planning marker can be keyed to it. `cwd`
# prefers Junie's project_path, because Junie's own cwd is ~/.junie, not the
# repo (#202); this also moves where hook_tool_path resolves a relative path
# on Junie. A payload with neither falls back to the process working directory.
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

# Prints the path a tool call names, absolute and normalized, or nothing when
# it names none. Call after hook_read_payload. Claude Code names the file under
# file_path; Junie's tool input may use path instead, and may give it relative
# to the working directory, so a relative path is resolved against `cwd`.
hook_tool_path() {
  local file
  file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // ""')"
  [ -n "$file" ] || return 0
  case "$file" in /*) ;; *) file="$cwd/$file" ;; esac
  hook_normalize_path "$file"
}

# Collapses "." and ".." segments lexically, so a path is judged by where it
# lands: docs/adr/../../src/x.ts is source, not an ADR. Lexical, not
# realpath, because the file being written may not exist yet.
hook_normalize_path() {
  local seg out="" parts
  IFS=/ read -ra parts <<<"$1"
  for seg in "${parts[@]}"; do
    case "$seg" in
      ''|.) ;;
      ..) out="${out%/*}" ;;
      *) out="$out/$seg" ;;
    esac
  done
  printf '%s' "${out:-/}"
}

# Prints the session's marker of the given kind: grilling, the marker that
# arms the edit guard, or planning, Junie's marker the guard never reads
# (ADR-0025). Every hook that names a marker goes through here, so a rename
# cannot silently re-arm or disarm the guard. Call after hook_read_payload,
# with a non-empty `session`.
hook_marker_path() {
  printf '%s/orchestrator-%s-%s' "${TMPDIR:-/tmp}" "$1" "$session"
}

# Prints this install's plugin root: the directory above scripts/, as the
# logical path the hooks hand the model, not a symlink-resolved one.
hook_plugin_root() {
  (cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
}

# Prints the installed orch-quick-implement SKILL.md. A host with no Skill tool
# is told to read this file.
hook_quick_skill_file() {
  printf '%s/skills/orch-quick-implement/SKILL.md' "$(hook_plugin_root)"
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

# True when the repo at $1 has a flow running. A state.json at phase exactly
# "done" is finished work waiting for the next init to archive it (ADR-0009),
# so it counts as no flow and planning keeps its protections (#186). Any other
# state.json - unreadable, or with no phase - still counts as a running flow.
hook_flow_active() {
  local state="$1/.orchestrator/state.json"
  [ -f "$state" ] || return 1
  [ "$(jq -r '.phase // ""' "$state" 2>/dev/null)" != "done" ]
}
