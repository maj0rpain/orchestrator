# planning-allowlist.sh - the one definition of the planning allowlist.
#
# The files a planning session may legitimately write: improve-codebase-
# architecture and domain-modeling update CONTEXT.md and ADRs inline, wayfinder
# writes tickets under .scratch/ on a local tracker, and the flow keeps its own
# state under .orchestrator/. The edit guard (hook-guard.sh) denies edits
# outside it during planning; the flow-start working-tree check in orch.sh
# refuses to start when changes fall outside it (ADR-0013). Both source this
# file so they can never disagree. Sourced, not executed on its own.

# Entries ending in "/" are directory prefixes; the rest are exact paths.
# All are relative to the repo root.
PLANNING_ALLOWLIST=(CONTEXT.md CONTEXT-MAP.md docs/adr/ docs/agents/ .scratch/ .orchestrator/)

# planning_allowlisted <repo-relative path> - succeeds when the path is inside
# the planning allowlist.
planning_allowlisted() {
  local entry
  for entry in "${PLANNING_ALLOWLIST[@]}"; do
    case "$entry" in
      */) case "$1" in "$entry"*) return 0 ;; esac ;;
      *) [ "$1" = "$entry" ] && return 0 ;;
    esac
  done
  return 1
}

# planning_allowlist_text - prints the allowlist as one comma-separated line,
# for messages that tell the human or model what they may still edit.
planning_allowlist_text() {
  local IFS=,
  printf '%s' "${PLANNING_ALLOWLIST[*]}" | sed 's/,/, /g'
}
