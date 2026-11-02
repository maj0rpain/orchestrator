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

payload="$(cat)"
hook_bash_poll_deny "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null || exit 0
