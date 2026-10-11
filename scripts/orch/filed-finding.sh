# shellcheck shell=bash
# filed-finding.sh - the Filed finding module: a concept module with no orch.sh
# noun of its own, holding what a filed finding is - its severities, each
# severity's label colour and description, its label rules, and its issue
# body, rendered from its parts and parsed back - that review file, finding
# triage and issue triage read. Its tests:
# scripts/test/orch/filed-finding.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The severities a filed finding carries as review:<severity> - the ones
# `review file` files. Blocking is always fixed in the loop, never filed.
readonly FILED_SEVERITIES="major nit"

# filed_severity_label <sev> <colour_var> <desc_var>: the severity table. Writes
# the review:<sev> label's colour and description into the named variables;
# returns 1, writing neither, for a severity with no entry. Every member of
# FILED_SEVERITIES has one, so adding a severity edits this module only.
filed_severity_label() {
  local __fsl_colour
  case "$1" in
    major) __fsl_colour=d93f0b ;;
    nit)   __fsl_colour=c5def5 ;;
    *) return 1 ;;
  esac
  printf -v "$2" '%s' "$__fsl_colour"
  printf -v "$3" 'Review finding filed at %s severity' "$1"
}

# Whether <sev> is a filed severity: the one membership check over
# FILED_SEVERITIES, so adding a severity edits the constant and its table
# entry, not every membership check.
is_filed_severity() {
  local s
  for s in $FILED_SEVERITIES; do [ "$1" != "$s" ] || return 0; done
  return 1
}

# review_labels <labels>: each label in the newline-separated list that marks
# a review finding - review: followed by at least one character. The one scan
# the two checks below share.
review_labels() {
  printf '%s\n' "$1" | grep '^review:.' || true
}

# has_review_label <labels>: whether any label marks a review finding, at any
# severity - filed today or not.
has_review_label() {
  [ -n "$(review_labels "$1")" ]
}

# has_filed_severity_label <labels>: whether some review label carries a
# filed severity.
has_filed_severity_label() {
  local label
  while IFS= read -r label; do
    [ -n "$label" ] || continue
    ! is_filed_severity "${label#review:}" || return 0
  done <<<"$(review_labels "$1")"
  return 1
}

# The severity label a filed finding carries, so triage can filter on it. It is
# this plugin's own, so overwriting it is safe: adapter_label_upsert updates a
# label that exists rather than failing on it, and filing works on a repo that
# has never seen the label and on one that has, with no listing step in between.
severity_label_ensure() {
  gh_or_die "create label $1" adapter_label_upsert "$1" "$2" "$3"
}

# The triage label is the repo's, not ours: created only where it is missing,
# and never rewritten, because a maintainer's colour and description on it are
# theirs to keep. A create that fails because the label exists is the common
# case and is ignored; one that fails for any other reason surfaces two lines
# later, when `gh issue create` cannot apply the label.
triage_label_ensure() {
  adapter_label_create "$1" e4e669 "Not yet triaged" 2>/dev/null || true
}

# category_for_axis <axis>: the category a finding filed on that review axis
# starts in, whatever the axis's case. A Spec finding misses what was asked
# for, so it is a bug; a Standards finding improves how it was built. Prints
# nothing and fails for any other axis; the caller words its own error.
category_for_axis() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    spec)      printf 'bug\n' ;;
    standards) printf 'enhancement\n' ;;
    *) return 1 ;;
  esac
}

# category_other <category>: the opposite category - the one a finding loses
# when triage settles on <category>. Prints nothing and fails for anything but
# bug or enhancement.
category_other() {
  case "$1" in
    bug)         printf 'enhancement\n' ;;
    enhancement) printf 'bug\n' ;;
    *) return 1 ;;
  esac
}

# The category label - bug or enhancement - is the repo's too, like the triage
# label: created only where missing, never overwritten, with GitHub's own
# default colour and description, and a failed create ignored for the same
# reason.
category_label_ensure() {
  case "$1" in
    bug)         adapter_label_create bug d73a4a "Something isn't working" 2>/dev/null || true ;;
    enhancement) adapter_label_create enhancement a2eeef "New feature or request" 2>/dev/null || true ;;
  esac
}

# finding_body_render <finding-file> <axis> <severity> <reason> <file> <line>
# <sha> <pr-url> <why> [<question>]: prints a filed finding's issue body - the
# finding text, its trailing newlines stripped, a blank line, then each
# labelled line followed by a blank line, so GitHub shows each as its own
# paragraph. The labelled lines are the closer's, byte for byte, so a body
# filed before rendering existed parses as one rendered now does.
finding_body_render() {
  local axis
  axis="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  axis="$(printf '%s' "${axis:0:1}" | tr '[:lower:]' '[:upper:]')${axis:1}"
  printf '%s\n\n' "$(cat "$1")" \
    "**Axis:** $axis" \
    "**Severity:** $3 - $4" \
    "**Location:** \`$5:$6\` at $7" \
    "**PR:** $8" \
    "**Why not fixed in the loop:** $9"
  [ -z "${10:-}" ] || printf '%s\n\n' "**Spec question:** ${10}"
}

# finding_body_trim <var> <text>: <text> with whitespace stripped from both
# ends, written into <var>.
finding_body_trim() {
  local __fbt="$2"
  __fbt="${__fbt#"${__fbt%%[![:space:]]*}"}"
  __fbt="${__fbt%"${__fbt##*[![:space:]]}"}"
  printf -v "$1" '%s' "$__fbt"
}

# finding_body_parse <body> <prefix>: reads every labelled line of a filed
# finding's body into <prefix>_<field> - axis (lowercased), severity, reason,
# file, line (N or N-M), sha, pr (the URL), pr_number, why and question. Each
# comes from the first line that carries it, as finding triage always read
# them: Location from the first line starting with its label, with no
# fallback when that one does not parse - the first backticked <file>:<line>,
# the file free of backticks and colons, and the hex run of the line's last
# " at <hex>"; PR from the first line ending in a URL whose last segment after
# /pull/ is a number; the rest from the first line starting with their label,
# as the rest of it, trimmed. Severity splits at the first " - ". A field whose
# line is missing or does not parse is left empty. Never dies, never prints:
# each caller decides which fields it requires.
finding_body_parse() {
  local __fbp_line __fbp_rest __fbp_v __fbp_k
  local __fbp_axis="" __fbp_severity="" __fbp_reason="" __fbp_file="" __fbp_lineno="" \
    __fbp_sha="" __fbp_pr="" __fbp_pr_number="" __fbp_why="" __fbp_question=""
  local __fbp_seen_axis="" __fbp_seen_sev="" __fbp_seen_loc="" __fbp_seen_pr="" \
    __fbp_seen_why="" __fbp_seen_q=""
  local __fbp_loc_re='`([^`:]+):([0-9]+(-[0-9]+)?)`' __fbp_at_re=' at ([0-9a-fA-F]+)'
  local __fbp_pr_re='/pull/([0-9]+)/*[[:space:]]*$'
  while IFS= read -r __fbp_line; do
    case "$__fbp_line" in
      '**Axis:**'*)
        [ -z "$__fbp_seen_axis" ] || continue
        __fbp_seen_axis=1
        finding_body_trim __fbp_v "${__fbp_line#'**Axis:**'}"
        __fbp_axis="$(printf '%s' "$__fbp_v" | tr '[:upper:]' '[:lower:]')"
        ;;
      '**Severity:**'*)
        [ -z "$__fbp_seen_sev" ] || continue
        __fbp_seen_sev=1
        finding_body_trim __fbp_v "${__fbp_line#'**Severity:**'}"
        case "$__fbp_v" in
          *' - '*)
            finding_body_trim __fbp_severity "${__fbp_v%%' - '*}"
            finding_body_trim __fbp_reason "${__fbp_v#*' - '}"
            ;;
          *) __fbp_severity="$__fbp_v" ;;
        esac
        ;;
      '**Location:**'*)
        [ -z "$__fbp_seen_loc" ] || continue
        __fbp_seen_loc=1
        [[ $__fbp_line =~ $__fbp_loc_re ]] || continue
        __fbp_k="${BASH_REMATCH[1]}"; __fbp_v="${BASH_REMATCH[2]}"
        __fbp_rest="$__fbp_line" __fbp_sha=""
        while [[ $__fbp_rest =~ $__fbp_at_re ]]; do
          __fbp_sha="${BASH_REMATCH[1]}"
          __fbp_rest="${__fbp_rest#*"${BASH_REMATCH[0]}"}"
        done
        [ -n "$__fbp_sha" ] || continue
        __fbp_file="$__fbp_k" __fbp_lineno="$__fbp_v"
        ;;
      '**Why not fixed in the loop:**'*)
        [ -z "$__fbp_seen_why" ] || continue
        __fbp_seen_why=1
        finding_body_trim __fbp_why "${__fbp_line#'**Why not fixed in the loop:**'}"
        ;;
      '**Spec question:**'*)
        [ -z "$__fbp_seen_q" ] || continue
        __fbp_seen_q=1
        finding_body_trim __fbp_question "${__fbp_line#'**Spec question:**'}"
        ;;
    esac
    # PR is read apart from the case above: a **PR:** line that does not end
    # in a pull request URL is skipped, and a later one may still match.
    if [ -z "$__fbp_seen_pr" ] && [[ $__fbp_line == '**PR:**'* ]] && [[ $__fbp_line =~ $__fbp_pr_re ]]; then
      __fbp_seen_pr=1
      __fbp_pr_number="${BASH_REMATCH[1]}"
      finding_body_trim __fbp_pr "${__fbp_line#'**PR:**'}"
    fi
  done <<<"$1"
  printf -v "$2_axis" '%s' "$__fbp_axis"
  printf -v "$2_severity" '%s' "$__fbp_severity"
  printf -v "$2_reason" '%s' "$__fbp_reason"
  printf -v "$2_file" '%s' "$__fbp_file"
  printf -v "$2_line" '%s' "$__fbp_lineno"
  printf -v "$2_sha" '%s' "$__fbp_sha"
  printf -v "$2_pr" '%s' "$__fbp_pr"
  printf -v "$2_pr_number" '%s' "$__fbp_pr_number"
  printf -v "$2_why" '%s' "$__fbp_why"
  printf -v "$2_question" '%s' "$__fbp_question"
}
