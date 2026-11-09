# shellcheck shell=bash
# audit.sh - orch.sh's audit command: audit file, which files one docs-audit
# finding as a GitHub issue, its body rendered from the finding file, its
# locations and the HEAD it was audited at, and parsed back before any write.
# Its tests: scripts/test/orch/audit.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# audit_body_render <finding-file> <sha> <location>...: prints the issue body -
# the finding text, its trailing newlines stripped, a blank line, one
# **Location:** line per location in the order given, then the **Audited at:**
# line, each line followed by a blank line.
audit_body_render() {
  local file="$1" sha="$2" l
  shift 2
  printf '%s\n\n' "$(cat "$file")"
  for l in "$@"; do printf '%s\n\n' "**Location:** \`$l\`"; done
  printf '%s\n\n' "**Audited at:** $sha"
}

# audit_body_parse <body> <locations_var> <sha_var>: reads every **Location:**
# line's backticked location, newline-joined in order, into the first variable,
# and every **Audited at:** line's text, newline-joined, into the second. A
# line carrying no backticked location contributes an empty entry, so it
# shows up as a mismatch.
audit_body_parse() {
  local __abp_line __abp_locs="" __abp_shas="" __abp_re='^\*\*Location:\*\* `([^`]*)`$'
  while IFS= read -r __abp_line; do
    case "$__abp_line" in
      '**Location:**'*)
        if [[ $__abp_line =~ $__abp_re ]]; then
          __abp_locs+="${BASH_REMATCH[1]}"$'\n'
        else
          __abp_locs+=$'\n'
        fi
        ;;
      '**Audited at:**'*)
        __abp_shas+="$(trim "${__abp_line#'**Audited at:**'}")"$'\n'
        ;;
    esac
  done <<<"$1"
  printf -v "$2" '%s' "$__abp_locs"
  printf -v "$3" '%s' "$__abp_shas"
}

# audit_file <title> --finding-file <f> --location <loc>...: files one finding
# as a GitHub issue and prints its number. Every check - the title, the
# finding file, the locations, HEAD's SHA and the round trip of the rendered
# body - comes before any GitHub read or write. An open issue with exactly the
# title files nothing: its number is printed, with the already-open line on
# stderr, and the exit is 0.
audit_file() {
  local usage="usage: orch.sh audit file <title> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
  [ $# -ge 1 ] || die "$usage"
  local title="$1" finding="" locations=() i
  shift
  finding_flags_parse "$usage" "--finding-file --location" "$@"
  for i in "${!FINDING_FLAGS[@]}"; do
    case "${FINDING_FLAGS[i]}" in
      --finding-file)
        [ -z "$finding" ] || die "$usage"
        finding="${FINDING_VALUES[i]}" ;;
      --location) locations+=("${FINDING_VALUES[i]}") ;;
    esac
  done
  [ -n "$finding" ] && [ "${#locations[@]}" -gt 0 ] || die "$usage"

  local loc sha body_file n err existing existing_n existing_title triage
  finding_input_check "$title" "$finding"
  for loc in "${locations[@]}"; do
    finding_location_check "$loc" "<file>:<line> or <file>:<start>-<end>"
  done
  sha="$(git rev-parse --verify HEAD 2>/dev/null)" || die "cannot read the HEAD commit"
  [[ $sha =~ ^[0-9a-fA-F]+$ ]] || die "not a sha: $sha (want a hex commit SHA)"

  finding_body_file_new body_file
  audit_body_render "$finding" "$sha" "${locations[@]}" >"$body_file"
  local got_locs got_shas want_locs
  audit_body_parse "$(cat "$body_file")" got_locs got_shas
  want_locs="$(printf '%s\n' "${locations[@]}")"$'\n'
  [ "$got_locs" = "$want_locs" ] \
    || die "the rendered body does not parse back: locations (given '${want_locs%$'\n'}', parsed '${got_locs%$'\n'}')"
  [ "$got_shas" = "$sha"$'\n' ] \
    || die "the rendered body does not parse back: audited at (given '$sha', parsed '${got_shas%$'\n'}')"

  # An open issue with this exact title is the finding already filed.
  capture existing err adapter_issues_open_titles \
    || gh_die "list the open issues" "$err"
  while IFS=$'\t' read -r existing_n existing_title; do
    [ -n "$existing_n" ] || continue
    if [ "$existing_title" = "$title" ]; then
      warn "#$existing_n is already open with this title; nothing filed"
      note "$existing_n"
      return 0
    fi
  done <<<"$existing"

  triage="$(triage_label_for needs-triage)"
  triage_label_ensure "$triage"
  adapter_label_create documentation 0075ca "Improvements or additions to documentation" 2>/dev/null || true
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body_file" "$triage" documentation
  note "$n"
}

cmd_audit() {
  local op="${1:-}"
  shift || true
  case "$op" in
    file) audit_file "$@" ;;
    *) die "usage: orch.sh audit file <title> --finding-file <f> --location <loc>..." ;;
  esac
}
