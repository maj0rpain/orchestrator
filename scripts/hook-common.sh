# shellcheck shell=bash
# hook-common.sh - shared payload reading and output writing for the hooks.
#
# Every hook reads the same JSON payload from stdin and, when it decides or
# injects context, writes one JSON object. Hosts differ in both: Junie's
# PreToolUse payload carries no cwd (its session_id, missing from Junie's
# bundled docs, is there from build 3419.7), and Junie reads its
# decision and context from top-level fields where Claude Code reads
# hookSpecificOutput. Sourced by each hook, not executed on its own.

# The one host detector, shared with orch.sh (#281).
source "$(dirname "${BASH_SOURCE[0]}")/host.sh"
# The one owner of the flow state format, shared with orch.sh (#1023): the
# hooks read state.json and decide whether a flow is active through it alone.
source "$(dirname "${BASH_SOURCE[0]}")/flow-state.sh"

# Reads the raw hook JSON from stdin and sets `input`, `session`, `cwd`, and
# `host` in the caller's shell. A missing session_id leaves `session` empty,
# which means "not guarded": no planning marker can be keyed to it. `cwd`
# prefers Junie's project_path, because Junie's own cwd is ~/.junie, not the
# repo (#202); this also moves where hook_tool_path resolves a relative path
# on Junie. A payload with neither falls back to the process working directory.
# `host` comes from host.sh's host_detect in payload mode: junie when the
# payload carries a non-empty project_path, which Claude Code's never does,
# else claude. `input` is left set so a caller can extract further
# fields without reading stdin a second time.
hook_read_payload() {
  input="$(cat)"
  session="$(printf '%s' "$input" | jq -r '.session_id // ""')"
  local project
  project="$(printf '%s' "$input" | jq -r '.project_path // ""')"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
  # shellcheck disable=SC2034 # host is read by the hook that sourced this file
  host="$(host_detect "$input")"
  [ -z "$project" ] || cwd="$project"
  [ -n "$cwd" ] || cwd="$PWD"
}

# hook_read_payload, plus `skill`: the skill name out of a Skill tool call.
hook_read_skill_and_session() {
  hook_read_payload
  # shellcheck disable=SC2034 # skill is read by the hook that sourced this file
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

# Writes a Stop refusal: the top-level decision "block" with its reason, which
# Claude Code hands the session as the instruction to go on, not ending the
# turn. Stop has no hookSpecificOutput decision; that Junie reads it is
# unverified (docs/host-capabilities.md, "Guard the batch question").
hook_emit_block() {
  jq -n --arg r "$1" '{decision: "block", reason: $r}'
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

# The jq prefix both Bash stdin filters share: binds $c to the command string
# and keeps only an in-scope payload ($auto is the ORCH_AUTOPILOT value).
HOOK_BASH_STDIN_SCOPE='
  (.tool_input.command? // null) as $c
  | select(($c | type) == "string")
  | select($auto == "1" or ((.agent_type? // "") | type == "string"
      and (startswith("orchestrator:orch-") or startswith("orch-"))))
  | '

# Writes the PreToolUse allow that closes a Bash call's stdin (#2001), or
# nothing. $1 is the raw payload, $2 the ORCH_AUTOPILOT value. In scope under
# bypassPermissions only (see hook-bash-stdin.sh), it prints
# hookSpecificOutput with updatedInput - the whole tool_input, only command
# prefixed with `exec </dev/null` and a newline, unless it already is - and
# permissionDecision "allow". Fails, printing nothing, on a payload that is
# not JSON.
hook_bash_stdin_rewrite() {
  printf '%s' "$1" | jq -e --arg auto "$2" "$HOOK_BASH_STDIN_SCOPE"'
    select(.permission_mode == "bypassPermissions")
    | "exec </dev/null\n" as $p
    | {hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: (.tool_input
          | .command = (if ($c | startswith($p)) then $c else $p + $c end))
      }}' 2>/dev/null
}

# Prints the first part of a Bash command that is a plain stdin read, or
# nothing (#2002). $1 is the command. Parts split on `;`, `&&`, `||` and
# newlines, outside single and double quotes and outside heredoc bodies; an
# unquoted `#` at a word start ends its line. A part is a plain read when its
# first word, after leading VAR=value words, is `cat` with no file argument
# (only options other than `--help` and `--version`, or `-`), `read`,
# `python`, `python3` or `node` with no argument or `-` as its script, or
# `bash`/`sh` with `-s` first - and the part
# holds no `<` and no `|`, which would feed it. First-word matching only. A
# command over 8 KB is not scanned (a false negative), to stay fast.
hook_bash_stdin_reader() {
  local cmd="$1" line part="" quote="" heredoc_end="" heredoc_strip_tabs=0 continued=0 i c n rest re
  [ "${#cmd}" -le 8192 ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$heredoc_end" ]; then
      [ "$heredoc_strip_tabs" = 1 ] && line="${line#"${line%%[!$'\t']*}"}"
      [ "$line" = "$heredoc_end" ] && heredoc_end=""
      continue
    fi
    n=${#line}; i=0; continued=0
    while [ "$i" -lt "$n" ]; do
      rest="${line:i}"
      if [ -z "$quote" ]; then re='^[^'"'"'"\\#;&|<]+'
      elif [[ "$quote" == "'" ]]; then re="^[^']+"
      else re='^[^"\\]+'; fi
      if [[ "$rest" =~ $re ]]; then part+="${BASH_REMATCH[0]}"; i=$((i + ${#BASH_REMATCH[0]})); continue; fi
      c="${rest::1}"
      if [ -n "$quote" ]; then
        if [ "$quote" = '"' ] && [ "$c" = '\' ]; then
          part+="$c${line:i+1:1}"; i=$((i + 2)); continue
        fi
        [ "$c" = "$quote" ] && quote=""
        part+="$c"
      else
        case "$c" in
          "'"|'"') quote="$c"; part+="$c" ;;
          '\')
            if [ "$((i + 1))" -ge "$n" ]; then continued=1; i=$((i + 2)); continue; fi
            part+="$c${line:i+1:1}"; i=$((i + 2)); continue ;;
          '#')
            if [ -z "$part" ] || [[ "${part: -1}" == [[:space:]] ]]; then break; fi
            part+="$c" ;;
          ';') hook_bash_stdin_hit "$part" && return 0; part="" ;;
          '&'|'|')
            if [ "${line:i+1:1}" = "$c" ]; then
              hook_bash_stdin_hit "$part" && return 0
              part=""; i=$((i + 2)); continue
            fi
            part+="$c" ;;
          '<')
            if [ "${line:i:3}" = '<<<' ]; then part+='<<<'; i=$((i + 3)); continue; fi
            if [[ "$rest" =~ ^\<\<(-?)[[:space:]]*\\?[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
              heredoc_end="${BASH_REMATCH[2]}"; heredoc_strip_tabs=0; [ -n "${BASH_REMATCH[1]}" ] && heredoc_strip_tabs=1
            fi
            part+="$c" ;;
          *) part+="$c" ;;
        esac
      fi
      i=$((i + 1))
    done
    if [ "$continued" = 1 ]; then
      :
    elif [ -z "$quote" ] && [[ "$part" =~ \|[[:space:]]*$ ]]; then
      :  # a trailing lone | continues the pipeline on the next line
    elif [ -z "$quote" ]; then
      hook_bash_stdin_hit "$part" && return 0
      part=""
    else
      part+=$'\n'
    fi
  done <<<"$cmd"
  hook_bash_stdin_hit "$part"
  return 0
}

# Prints the part $1 with leading whitespace trimmed and succeeds when it is a
# plain stdin read; else fails printing nothing.
hook_bash_stdin_hit() {
  hook_bash_stdin_is_reader "$1" || return 1
  printf '%s' "${1#"${1%%[![:space:]]*}"}"
}

# Succeeds when every argument is an option (-x, --long) or a lone -, so no
# file is named. No arguments succeeds too.
hook_bash_stdin_only_options() {
  local a
  for a in "$@"; do [[ "$a" == -* ]] || return 1; done
}

# Succeeds when any argument is --help or --version, which make a command print
# and exit without reading stdin.
hook_bash_stdin_has_info_option() {
  local a
  for a in "$@"; do [[ "$a" == --help || "$a" == --version ]] && return 0; done
  return 1
}

# Succeeds when an interpreter's arguments name no script (none at all) or name
# `-` as the script: the first argument that is not an option, a lone - counting
# as the script. Options alone do not succeed (a false negative, accepted).
hook_bash_stdin_script_is_stdin() {
  local a
  [ "$#" -eq 0 ] && return 0
  for a in "$@"; do
    [ "$a" = - ] && return 0
    [[ "$a" == -* ]] || return 1
  done
  return 1
}

# Succeeds when the one part $1 is a plain stdin read; see
# hook_bash_stdin_reader.
hook_bash_stdin_is_reader() {
  local -a raw words=()
  local x skip=0
  case "$1" in *'<'*|*'|'*) return 1 ;; esac
  read -ra raw <<<"$1"
  # An empty part has nothing to read; "${raw[@]}" of an empty array is an
  # unbound variable under set -u on bash before 4.4.
  [ "${#raw[@]}" -gt 0 ] || return 1
  # Drop output redirections (>f, 2>&1, &>f, >> f, a lone > and its target):
  # they feed nothing to stdin, so they name no file argument.
  for x in "${raw[@]}"; do
    if [ "$skip" = 1 ]; then skip=0; continue; fi
    if [[ "$x" =~ ^([0-9]*|&)\>(\>|&)?$ ]]; then skip=1; continue; fi
    [[ "$x" =~ ^([0-9]*|&)\> ]] || words+=("$x")
  done
  [ "${#words[@]}" -gt 0 ] || return 1
  local k=0
  while [ "$k" -lt "${#words[@]}" ] && [[ "${words[k]}" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do k=$((k + 1)); done
  local -a rest=()
  [ "${#words[@]}" -gt "$((k + 1))" ] && rest=("${words[@]:k+1}")
  local cmd_word="${words[k]:-}" first_arg="${words[k+1]:-}"
  case "$cmd_word" in
    cat) hook_bash_stdin_only_options ${rest[@]+"${rest[@]}"} && ! hook_bash_stdin_has_info_option ${rest[@]+"${rest[@]}"} ;;
    python|python3|node) hook_bash_stdin_script_is_stdin ${rest[@]+"${rest[@]}"} ;;
    read) return 0 ;;
    bash|sh) [ "$first_arg" = -s ] ;;
    *) return 1 ;;
  esac
}

# Writes the PreToolUse deny for an in-scope Bash call holding a plain stdin
# read under a mode other than bypassPermissions, or nothing (#2002). $1 is
# the raw payload, $2 the ORCH_AUTOPILOT value.
hook_bash_stdin_deny() {
  local cmd part
  cmd="$(printf '%s' "$1" | jq -er --arg auto "$2" "$HOOK_BASH_STDIN_SCOPE"'
    select(.permission_mode != "bypassPermissions") | $c' 2>/dev/null)" || return 1
  part="$(hook_bash_stdin_reader "$cmd")"
  [ -n "$part" ] || return 1
  hook_emit_deny "This Bash call reads stdin, which nothing will feed, so it would hang: '$part'. Supply input with a heredoc, <<<, a pipe or </dev/null."
}
