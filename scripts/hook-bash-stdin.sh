#!/usr/bin/env bash
#
# PreToolUse hook on Bash: closes stdin for a plugin subagent's or an
# autopilot session's Bash calls (#2001).
#
# A stray stdin read such as `cat; echo done` hangs a Bash call that nothing
# will ever feed. Under bypassPermissions the hook rewrites the command to
# `exec </dev/null`, a newline, then the original, so the read gets
# end-of-file at once; heredocs and here-strings inside the command still feed
# their readers, as they redirect after the exec, and a pipe feeds only the
# commands after it, never the head of its pipeline.
#
# Under any other permission mode an in-scope call whose command holds a
# plain stdin read (hook_bash_stdin_is_reader) is denied with a reason
# instead (#2002).
#
# In scope: an agent_type starting `orchestrator:orch-` or `orch-`, or
# ORCH_AUTOPILOT=1 in the hook's environment. Everything else, any other
# permission mode, a payload with no tool_input.command, and a payload that is
# not JSON, passes through with no output. An already-prefixed command is
# returned unchanged, still allowed. The bypass path is one jq call; the
# other modes run up to three (rewrite, command read, deny emit).

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/bash-walk.sh"

# Writes the PreToolUse allow that closes a Bash call's stdin (#2001), or
# nothing. $1 is the raw payload, $2 the ORCH_AUTOPILOT value. In scope under
# bypassPermissions only (see hook-bash-stdin.sh), it prints
# hookSpecificOutput with updatedInput - the whole tool_input, only command
# prefixed with `exec </dev/null` and a newline, unless it already is - and
# permissionDecision "allow". Fails, printing nothing, on a payload that is
# not JSON.
hook_bash_stdin_rewrite() {
  printf '%s' "$1" | jq -e --arg auto "$2" "$HOOK_BASH_SCOPE"'
    select(.permission_mode == "bypassPermissions")
    | "exec </dev/null\n" as $p
    | {hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: (.tool_input
          | .command = (if ($c | startswith($p)) then $c else $p + $c end))
      }}' 2>/dev/null
}

# Prints the part $1 with leading whitespace trimmed and succeeds when its head
# $3 is a plain stdin read; else fails printing nothing. A hook_bash_walk
# callback; $2, the unquoted text, is unused.
hook_bash_stdin_print_if_reader() {
  hook_bash_stdin_is_reader "$3" || return 1
  printf '%s' "${1#"${1%%[![:space:]]*}"}"
}

# Succeeds when every argument is an option (-x, --long) or a lone -, so no
# file is named. No arguments succeeds too.
hook_bash_stdin_only_options() {
  local a
  for a in "$@"; do [[ "$a" == -* ]] || return 1; done
}

# Succeeds when any ARG ($2...) is an info option of the command word $1: an
# option that makes the program print and exit without reading stdin.
hook_bash_stdin_has_info_option() {
  local cmd="$1" a
  shift
  for a in "$@"; do
    case "$cmd:$a" in
      cat:--help|cat:--version) return 0 ;;
      python:-h|python:-V|python:--help|python:--version) return 0 ;;
      python3:-h|python3:-V|python3:--help|python3:--version) return 0 ;;
      node:-h|node:-v|node:--help|node:--version) return 0 ;;
    esac
  done
  return 1
}

# Succeeds when an interpreter's arguments name no script: none at all, options
# only, or `-` as the script (the first argument that is not an option, a lone
# - counting as the script). A word after an option that takes a value
# (-c code, -m mod) counts as naming a script (a false negative, accepted).
hook_bash_stdin_script_is_stdin() {
  local a
  for a in "$@"; do
    [ "$a" = - ] && return 0
    [[ "$a" == -* ]] || return 1
  done
  return 0
}

# Succeeds when the pipeline head $1 is a plain stdin read (#2002). $1 is the
# head hook_bash_walk hands its callback: a part's text before its first
# unquoted `|`,
# or the whole part. A head is a plain read when its first word, after
# leading VAR=value words, is `cat` with no file argument (only options other
# than its info options, or `-`), `read`, `python`, `python3` or `node` with
# options only or `-` as its script, unless an info option is present, or
# `bash`/`sh` with `-s` first - and the head holds no `<`, which would feed it.
# A `|` feeds only the commands after it, so only the head is judged.
# First-word matching only.
hook_bash_stdin_is_reader() {
  local -a raw words=()
  local x skip=0
  case "$1" in *'<'*) return 1 ;; esac
  read -ra raw <<<"$1"
  # An empty head has nothing to read; "${raw[@]}" of an empty array is an
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
  local cmd_word="${words[k]:-}"
  case "$cmd_word" in
    cat) hook_bash_stdin_only_options ${rest[@]+"${rest[@]}"} && ! hook_bash_stdin_has_info_option cat ${rest[@]+"${rest[@]}"} ;;
    python|python3|node) hook_bash_stdin_script_is_stdin ${rest[@]+"${rest[@]}"} && ! hook_bash_stdin_has_info_option "$cmd_word" ${rest[@]+"${rest[@]}"} ;;
    read) return 0 ;;
    bash|sh) [ "${rest[0]:-}" = -s ] ;;
    *) return 1 ;;
  esac
}

# Writes the PreToolUse deny for an in-scope Bash call holding a plain stdin
# read under a mode other than bypassPermissions, or nothing (#2002). $1 is
# the raw payload, $2 the ORCH_AUTOPILOT value.
hook_bash_stdin_deny() {
  local cmd part
  cmd="$(printf '%s' "$1" | jq -er --arg auto "$2" "$HOOK_BASH_SCOPE"'
    select(.permission_mode != "bypassPermissions") | $c' 2>/dev/null)" || return 1
  part="$(hook_bash_walk "$cmd" hook_bash_stdin_print_if_reader)"
  [ -n "$part" ] || return 1
  hook_emit_deny "This Bash call reads stdin, which nothing will feed, so it would hang: '$part'. Supply input with a heredoc, <<<, a pipe or </dev/null."
}

payload="$(cat)"
hook_bash_stdin_rewrite "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null && exit 0
hook_bash_stdin_deny "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null || exit 0
