#!/usr/bin/env bash
#
# PreToolUse hook on Bash: the one decision for a plugin subagent's or an
# autopilot session's Bash call (#2001, #2002, #2085, #2567).
#
# In scope: an agent_type starting `orchestrator:orch-` or `orch-`, or
# ORCH_AUTOPILOT=1 in the hook's environment, and a string tool_input.command.
# Everything else, a payload with no command, and a payload that is not JSON,
# passes through with no output, after one jq call and no walk.
#
# The hook reads the payload once, walks the command at most once, and emits
# exactly one decision, in this order:
#   1. deny, when the command holds an unquoted pgrep or pkill word, under
#      every permission mode. `pgrep -f x` in a wait loop matches the polling
#      shell's own command line, so the loop never ends; `pkill -f x` kills
#      that shell. The walk goes on past a stdin reader looking for one.
#   2. else deny, when a part is a plain stdin read
#      (hook_bash_stdin_is_reader), naming the first such part, under any mode
#      but bypassPermissions: nothing will feed it, so it would hang.
#   3. else, under bypassPermissions, allow with the command rewritten to
#      `exec </dev/null`, a newline, then the original, so a stray read gets
#      end-of-file at once; heredocs and here-strings inside the command still
#      feed their readers, as they redirect after the exec, and a pipe feeds
#      only the commands after it. An already-prefixed command is returned
#      unchanged, still allowed. Under bypassPermissions the walk looks only
#      for a pgrep or pkill word.
#   4. else no output.
# Cost: one jq call reads scope, mode and command; a decision costs at most
# one more.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/bash-walk.sh"

# The jq prefix of the hook's filter: binds $c to the command string and keeps
# only an in-scope payload ($auto is the ORCH_AUTOPILOT value).
HOOK_BASH_SCOPE='
  (.tool_input.command? // null) as $c
  | select(($c | type) == "string")
  | select($auto == "1" or ((.agent_type? // "") | type == "string"
      and (startswith("orchestrator:orch-") or startswith("orch-"))))
  | '

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

# Succeeds when the unquoted text $2 of a command part holds a word equal to
# pgrep or pkill, or a path ending in /pgrep or /pkill (#2085). Words split on
# whitespace and on `;`, `&`, `|`, `(`, `)`, `$` and backtick. $1, the part
# itself, is unused. Prints "hit" when it succeeds.
hook_bash_poll_print_if_pgrep() {
  local -a words
  local w
  read -ra words <<<"${2//[;&|()\$\`]/ }"
  [ "${#words[@]}" -gt 0 ] || return 1
  for w in "${words[@]}"; do
    case "$w" in pgrep|pkill|*/pgrep|*/pkill) printf hit; return 0 ;; esac
  done
  return 1
}

# The hook_bash_walk callback: $1 is the part, $2 its unquoted text, $3 its
# head. Succeeds, ending the walk, on a pgrep or pkill word (hook_bash_pgrep=1).
# Otherwise, when hook_bash_reader_wanted is 1 and no reader is recorded yet,
# records the part, leading whitespace trimmed, in hook_bash_reader if its head
# is a plain stdin read; fails.
hook_bash_scan_part() {
  if hook_bash_poll_print_if_pgrep "$1" "$2" >/dev/null; then
    hook_bash_pgrep=1
    return 0
  fi
  if [ "$hook_bash_reader_wanted" = 1 ] && [ -z "$hook_bash_reader" ] && hook_bash_stdin_is_reader "$3"; then
    hook_bash_reader="${1#"${1%%[![:space:]]*}"}"
  fi
  return 1
}

# Writes the PreToolUse allow that closes a Bash call's stdin: hookSpecificOutput
# with updatedInput - the whole tool_input, only command prefixed with
# `exec </dev/null` and a newline, unless it already is - and
# permissionDecision "allow". $1 is the raw payload.
hook_bash_stdin_rewrite() {
  printf '%s' "$1" | jq '
    "exec </dev/null\n" as $p
    | .tool_input.command as $c
    | {hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        updatedInput: (.tool_input
          | .command = (if ($c | startswith($p)) then $c else $p + $c end))
      }}'
}

payload="$(cat)"
# One jq call: the permission mode on the first line, the command after it.
scoped="$(printf '%s' "$payload" | jq -er --arg auto "${ORCH_AUTOPILOT:-}" "$HOOK_BASH_SCOPE"'
  ((.permission_mode? // "") | tostring), $c' 2>/dev/null)" || exit 0
mode="${scoped%%$'\n'*}"
cmd=""
case "$scoped" in *$'\n'*) cmd="${scoped#*$'\n'}" ;; esac

hook_bash_pgrep=0
hook_bash_reader=""
hook_bash_reader_wanted=1
[ "$mode" != bypassPermissions ] || hook_bash_reader_wanted=0
hook_bash_walk "$cmd" hook_bash_scan_part

if [ "$hook_bash_pgrep" = 1 ]; then
  hook_emit_deny "This Bash call holds an unquoted pgrep or pkill word. pgrep and pkill match this shell's own command line, so a poll never ends and a kill kills this shell. To wait for a long command, rerun it in the foreground with timeout: 600000; if the host moves it to the background, wait for its completion notice and use its exit code (host capability *Run a long command*). If the word is only an argument, such as a grep pattern, quote it."
elif [ -n "$hook_bash_reader" ]; then
  hook_emit_deny "This Bash call reads stdin, which nothing will feed, so it would hang: '$hook_bash_reader'. Supply input with a heredoc, <<<, a pipe or </dev/null."
elif [ "$mode" = bypassPermissions ]; then
  hook_bash_stdin_rewrite "$payload"
fi
exit 0
