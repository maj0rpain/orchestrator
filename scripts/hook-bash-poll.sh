#!/usr/bin/env bash
#
# PreToolUse hook on Bash: denies a plugin subagent's or an autopilot
# session's Bash call that holds an unquoted pgrep or pkill word (#2085).
#
# `pgrep -f x` in a wait loop matches the polling shell's own command line, so
# the loop never ends; `pkill -f x` kills that shell. The deny applies under
# every permission mode, bypassPermissions included, and relies on the host
# ranking a deny above hook-bash-stdin.sh's allow-with-rewrite.
#
# In scope: an agent_type starting `orchestrator:orch-` or `orch-`, or
# ORCH_AUTOPILOT=1 in the hook's environment. Everything else, a payload with
# no tool_input.command, and a payload that is not JSON, passes through with
# no output.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/bash-walk.sh"

# Succeeds when the unquoted text $2 of a command part holds a word equal to
# pgrep or pkill, or a path ending in /pgrep or /pkill (#2085). Words split on
# whitespace and on `;`, `&`, `|`, `(`, `)`, `$` and backtick. $1, the part
# itself, is unused: this test is a hook_bash_walk callback, printing "hit"
# when it succeeds.
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

# Writes the PreToolUse deny for an in-scope Bash call holding an unquoted
# pgrep or pkill word, under every permission mode, or nothing (#2085). $1 is
# the raw payload, $2 the ORCH_AUTOPILOT value. A command over 8 KB is not
# scanned.
hook_bash_poll_deny() {
  local cmd
  cmd="$(printf '%s' "$1" | jq -er --arg auto "$2" "$HOOK_BASH_SCOPE"'$c' 2>/dev/null)" || return 1
  [ -n "$(hook_bash_walk "$cmd" hook_bash_poll_print_if_pgrep)" ] || return 1
  hook_emit_deny "This Bash call holds an unquoted pgrep or pkill word. pgrep and pkill match this shell's own command line, so a poll never ends and a kill kills this shell. To wait for a long command, rerun it in the foreground with timeout: 600000; if the host moves it to the background, wait for its completion notice and use its exit code (host capability *Run a long command*). If the word is only an argument, such as a grep pattern, quote it."
}

payload="$(cat)"
hook_bash_poll_deny "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null || exit 0
