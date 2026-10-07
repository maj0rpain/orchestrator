# shellcheck shell=bash
# planning-allowlist.sh - the canonical definition of the planning allowlist
# and of the planning records.
#
# The allowlist holds the files a planning session may legitimately write:
# agent docs (setup configuration the grilling hook itself asks for), tickets
# wayfinder writes under .scratch/ on a local tracker, and the flow's own state
# under .orchestrator/. The records - the glossary and ADRs - are not on it:
# planning records a glossary or ADR change as spec wording, word for word, not
# as an edit, so it lands with the change it describes. The edit guard
# (hook-guard.sh) denies edits outside the allowlist during planning; the
# flow-start working-tree check in orch.sh refuses to start when changes fall
# outside it (ADR-0013). Both use the records list to choose the redirect
# message. Both source this file so they can never disagree, and
# hook-grilling.sh prints the allowlist into the planning message on both hosts.
# Sourced, not executed on its own.

# Entries ending in "/" are directory prefixes; the rest are exact paths.
# All are relative to the repo root.
PLANNING_ALLOWLIST=(docs/agents/ .scratch/ .orchestrator/)

# The planning records: decisions planning never changes in place. Same entry
# format as the allowlist. The glossary is GLOSSARY.md / GLOSSARY-MAP.md,
# following upstream's rename; the legacy CONTEXT.md / CONTEXT-MAP.md names stay
# so repos that have not renamed their glossary yet stay protected.
PLANNING_RECORDS=(GLOSSARY.md GLOSSARY-MAP.md CONTEXT.md CONTEXT-MAP.md docs/adr/)

# planning_list_match <path> <entry>... - succeeds when the path matches one
# of the entries.
planning_list_match() {
  local path="$1" entry
  shift
  for entry in "$@"; do
    case "$entry" in
      */) case "$path" in "$entry"*) return 0 ;; esac ;;
      *) [ "$path" = "$entry" ] && return 0 ;;
    esac
  done
  return 1
}

# planning_allowlisted <repo-relative path> - succeeds when the path is inside
# the planning allowlist.
planning_allowlisted() {
  planning_list_match "$1" "${PLANNING_ALLOWLIST[@]}"
}

# planning_record <repo-relative path> - succeeds when the path is a planning
# record: the glossary or an ADR.
planning_record() {
  planning_list_match "$1" "${PLANNING_RECORDS[@]}"
}

# planning_record_redirect - the sentences that say where a planning record's
# intended wording goes instead, shared by the guard and the flow-start check.
planning_record_redirect() {
  printf '%s' "Write the exact wording you intended - the new or replaced text, and where it goes - into the plan, so the spec carries it verbatim as an Implementation Decision and it lands with the change it describes. For a quick implementation, put it in the linked issue's body."
}

# planning_allowlist_text - prints the allowlist as one comma-separated line,
# for messages that tell the human or model what they may still edit.
planning_allowlist_text() {
  local IFS=,
  printf '%s' "${PLANNING_ALLOWLIST[*]}" | sed 's/,/, /g'
}

# planning_records_text - prints the records the same way, for messages that
# tell the human or model what planning never edits in place.
planning_records_text() {
  local IFS=,
  printf '%s' "${PLANNING_RECORDS[*]}" | sed 's/,/, /g'
}
