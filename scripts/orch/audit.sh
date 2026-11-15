# shellcheck shell=bash
# audit.sh - orch.sh's audit command: audit file, which files one audit
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

# audit_drift_line <body>: for an audit-filed body, prints the one line saying
# which of the cited files changed since the audited commit: `cited files
# changed since <sha>: none`, or the changed files joined by `, `, in body
# order, each once. An audit-filed body has exactly one **Audited at:** line,
# its value hexadecimal, and at least one well-formed **Location:** line; any
# other body prints nothing. The audited commit's tree is compared with HEAD's
# in one `git diff` for all files, so no ancestry is needed, uncommitted
# changes are not counted, and renames are not detected (a renamed file is
# listed as the path the body cites). Paths are literal and from the top level,
# so the working directory changes nothing. A comparison that cannot be made
# prints `unknown (<reason>)`, the reason one of three fixed phrases, and still
# returns 0. The body is untrusted: only a hexadecimal value reaches git as the
# commit, and every path is a literal pathspec after `--`.
audit_drift_line() {
  local locs shas loc file line sha pathspecs=() cited=() changed=() p tmp
  local re_line='^[0-9]+(-[0-9]+)?$'
  audit_body_parse "$1" locs shas
  [[ $shas =~ ^[0-9a-fA-F]+$'\n'$ ]] || return 0
  sha="${shas%$'\n'}"
  local -A cited_set=() changed_set=()
  while IFS= read -r loc; do
    file="${loc%:*}" line="${loc##*:}"
    [[ $loc == *:* && -n $file && $line =~ $re_line ]] || continue
    [ -z "${cited_set[$file]:-}" ] || continue
    cited_set[$file]=1
    cited+=("$file")
    pathspecs+=(":(top,literal)$file")
  done <<<"$locs"
  [ "${#cited[@]}" -gt 0 ] || return 0

  local head="cited files changed since $sha:" reason=""
  temp_file_make tmp || reason="git comparison failed"
  if [ -z "$reason" ]; then
    if git diff --name-only -z --no-renames --no-ext-diff --no-relative "$sha" HEAD -- "${pathspecs[@]}" >"$tmp" 2>/dev/null; then
      while IFS= read -r -d '' p; do changed_set[$p]=1; done <"$tmp"
    elif ! git rev-parse --verify -q 'HEAD^{commit}' >/dev/null 2>&1; then
      reason="no commit on HEAD"
    elif ! git cat-file -e "$sha^{commit}" >/dev/null 2>&1; then
      reason="commit not in this clone"
    else
      reason="git comparison failed"
    fi
    rm -f "$tmp"
  fi
  if [ -n "$reason" ]; then
    note "$head unknown ($reason)"
    return 0
  fi
  for file in "${cited[@]}"; do
    [ -z "${changed_set[$file]:-}" ] || changed+=("$file")
  done
  if [ "${#changed[@]}" -eq 0 ]; then
    note "$head none"
  else
    local joined
    printf -v joined '%s, ' "${changed[@]}"
    note "$head ${joined%, }"
  fi
}

# audit_file_usage: the usage line, its categories read from the Filed finding
# module's list. A function, not a variable: filed-finding.sh may not be loaded
# when audit.sh is, so a string built at source time could not read the list.
audit_file_usage() {
  orch_load filed-finding
  local cats="${FILED_CATEGORIES// /|}"
  printf 'usage: orch.sh audit file <title> --category <%s> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n' "$cats"
}

# audit_file <title> --category <c> --finding-file <f> --location <loc>...:
# files one finding as a GitHub issue and prints its number. Every check - the
# title, the finding file, the category, the locations, HEAD's SHA and the
# round trip of the rendered body - comes before any GitHub read or write. An
# open issue with exactly the title files nothing: its number is printed, with
# the already-open line on stderr, and the exit is 0.
audit_file() {
  [ $# -ge 1 ] || die "$(audit_file_usage)"
  local title="$1" finding="" category="" locations=() i
  shift
  finding_flags_parse "$(audit_file_usage)" "--category --finding-file --location" "$@"
  for i in "${!FINDING_FLAGS[@]}"; do
    case "${FINDING_FLAGS[i]}" in
      --category)
        [ -z "$category" ] || die "$(audit_file_usage)"
        category="${FINDING_VALUES[i]}" ;;
      --finding-file)
        [ -z "$finding" ] || die "$(audit_file_usage)"
        finding="${FINDING_VALUES[i]}" ;;
      --location) locations+=("${FINDING_VALUES[i]}") ;;
    esac
  done
  [ -n "$finding" ] && [ -n "$category" ] && [ "${#locations[@]}" -gt 0 ] || die "$(audit_file_usage)"

  is_filed_category "$category" || die "$(audit_file_usage)"
  local loc sha body_file n err existing existing_n existing_title triage
  finding_input_check "$title" "$finding"
  for loc in "${locations[@]}"; do
    finding_location_check "$loc"
  done
  sha="$(git rev-parse --verify HEAD 2>/dev/null)" || die "cannot read the HEAD commit"

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
  gh_capture existing err adapter_issues_open_titles \
    || gh_die "list the open issues" "$err"
  while IFS=$'\t' read -r existing_n existing_title; do
    [ -n "$existing_n" ] || continue
    if [ "$existing_title" = "$title" ]; then
      warn "#$existing_n is already open with this title; nothing filed"
      note "$existing_n"
      return 0
    fi
  done <<<"$existing"

  triage_label_into triage needs-triage
  triage_label_ensure "$triage"
  category_label_ensure "$category"
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body_file" "$triage" "$category"
  note "$n"
}

cmd_audit() {
  local op="${1:-}"
  shift || true
  case "$op" in
    file) audit_file "$@" ;;
    *) die "$(audit_file_usage)" ;;
  esac
}
