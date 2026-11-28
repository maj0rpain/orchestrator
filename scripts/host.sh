# shellcheck shell=bash
# host.sh - the one bash host detector, sourced by hook-common.sh.
#
# Holds only host_detect and host_from_project_path. Needs nothing from
# orch.sh, so the hooks can source it alone (#281).

# The one home of the payload host rule: host_from_project_path <project_path>,
# the payload's project_path as the hook reader already read it. Prints "junie"
# for a non-empty value, which Claude Code's payload never carries, and "claude"
# otherwise (no key, "", null, an empty or unreadable payload), so it never
# prints nothing. ORCHESTRATOR_HOST is ignored: the hooks must behave
# identically whatever the shell exports, and a stray export in a user's
# profile must not disarm the edit guard.
host_from_project_path() {
  if [ -n "${1:-}" ]; then printf 'junie\n'; else printf 'claude\n'; fi
}

# The environment host detector, as orch.sh called it before orch/host.py
# took the rule over; only its own test section calls it now. Prints "claude",
# "junie", "antigravity", or nothing when no signal is present (orch.sh run
# by hand in a terminal). ORCHESTRATOR_HOST names the host outright, for a
# shell no signal reaches. Antigravity CLI exports ANTIGRAVITY_AGENT and
# ANTIGRAVITY_CONVERSATION_ID to run_command shells, where PLUGIN_ROOT is
# unset. Junie has two signals: JUNIE_EXTENSION_ROOT, which its docs say it
# expands for extension hooks, and JUNIE_SHIM_PATH, which Junie CLI exports
# to the agent's shell a skill runs orch.sh from (orch-bench run j1), where
# JUNIE_EXTENSION_ROOT is unset. Of the variables that shell gets
# (JUNIE_DATA, JUNIE_SHIM_PATH, JUNIE_TMPDIR), JUNIE_SHIM_PATH is the one
# least likely to be set in a user's own profile. Antigravity and Junie are
# checked before Claude because a session started from inside a Claude Code
# terminal inherits CLAUDECODE. The reverse case is accepted, and
# ORCHESTRATOR_HOST=claude fixes it.
host_detect() {
  if [ -n "${ORCHESTRATOR_HOST:-}" ]; then printf '%s\n' "$ORCHESTRATOR_HOST"; return 0; fi
  if [ -n "${ANTIGRAVITY_AGENT:-}" ] || [ -n "${ANTIGRAVITY_CONVERSATION_ID:-}" ]; then
    printf 'antigravity\n'; return 0
  fi
  if [ -n "${JUNIE_EXTENSION_ROOT:-}" ] || [ -n "${JUNIE_SHIM_PATH:-}" ]; then
    printf 'junie\n'; return 0
  fi
  if [ "${CLAUDECODE:-}" = 1 ] || [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf 'claude\n'; fi
}
