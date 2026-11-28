# shellcheck shell=bash
# host.sh - the hooks' host detector, sourced by hook-common.sh.
#
# Holds only host_from_project_path; the environment detector, host_detect, is
# orch/host.py's. Needs nothing from orch.sh, so the hooks can source it alone
# (#281).

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
