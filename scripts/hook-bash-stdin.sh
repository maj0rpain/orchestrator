#!/usr/bin/env bash
#
# PreToolUse hook on Bash: closes stdin for a plugin subagent's or an
# autopilot session's Bash calls (#2001).
#
# A stray stdin read such as `cat; echo done` hangs a Bash call that nothing
# will ever feed. Under bypassPermissions the hook rewrites the command to
# `exec </dev/null`, a newline, then the original, so the read gets
# end-of-file at once; heredocs, here-strings and pipes inside the command
# still feed their readers, as they redirect after the exec.
#
# Under any other permission mode an in-scope call whose command holds a plain
# stdin read (hook_bash_stdin_reader) is denied with a reason instead (#2002).
#
# In scope: an agent_type starting `orchestrator:orch-` or `orch-`, or
# ORCH_AUTOPILOT=1 in the hook's environment. Everything else, any other
# permission mode, a payload with no tool_input.command, and a payload that is
# not JSON, passes through with no output. An already-prefixed command is
# returned unchanged, still allowed. One jq call decides, to stay fast.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

payload="$(cat)"
hook_bash_stdin_rewrite "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null && exit 0
hook_bash_stdin_deny "$payload" "${ORCH_AUTOPILOT:-}" 2>/dev/null || exit 0
