# shellcheck shell=bash
# host.sh - the one host detector, sourced by orch.sh and by hook-common.sh.
#
# Holds only host_detect. Needs nothing from orch.sh, so the hooks can source
# it alone (#281).

# The one host detector. Prints "claude", "junie", or nothing. The mode is
# decided by the argument count, never by whether the argument is empty.
#
# Payload mode - host_detect <payload>, as the hooks call it: reads only the
# hook payload. A non-empty .project_path, which Claude Code's payload never
# carries, prints "junie"; anything else - no key, "", null, an empty payload,
# input that is not JSON - prints "claude", so it never prints nothing.
# ORCHESTRATOR_HOST is ignored here: the hooks must behave identically
# whatever the shell exports, and a stray export in a user's profile must not
# disarm the edit guard.
#
# Environment mode - host_detect with no argument, as orch.sh calls it: reads
# only the environment, and prints nothing when no signal is present (orch.sh
# run by hand in a terminal). ORCHESTRATOR_HOST names the host outright, for a
# shell no signal reaches. Junie has two signals: JUNIE_EXTENSION_ROOT, which
# its docs say it expands for extension hooks, and JUNIE_SHIM_PATH, which
# Junie CLI exports to the agent's shell a skill runs orch.sh from (orch-bench
# run j1), where JUNIE_EXTENSION_ROOT is unset. Of the variables that shell
# gets (JUNIE_DATA, JUNIE_SHIM_PATH, JUNIE_TMPDIR), JUNIE_SHIM_PATH is the one
# least likely to be set in a user's own profile. Junie is checked before
# Claude because a Junie started from inside a Claude Code terminal inherits
# CLAUDECODE. The reverse case is accepted: a Claude Code started from a Junie
# shell that inherits JUNIE_SHIM_PATH is detected as Junie, and
# ORCHESTRATOR_HOST=claude fixes it.
host_detect() {
  if [ "$#" -gt 0 ]; then
    local project
    project="$(printf '%s' "$1" | jq -r '.project_path // ""' 2>/dev/null)"
    if [ -n "$project" ]; then printf 'junie\n'; else printf 'claude\n'; fi
    return 0
  fi
  if [ -n "${ORCHESTRATOR_HOST:-}" ]; then printf '%s\n' "$ORCHESTRATOR_HOST"; return 0; fi
  if [ -n "${JUNIE_EXTENSION_ROOT:-}" ] || [ -n "${JUNIE_SHIM_PATH:-}" ]; then
    printf 'junie\n'; return 0
  fi
  if [ "${CLAUDECODE:-}" = 1 ] || [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then printf 'claude\n'; fi
}
