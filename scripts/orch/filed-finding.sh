# shellcheck shell=bash
# filed-finding.sh - the Filed finding module: a concept module with no orch.sh
# noun of its own, holding what a filed finding is - its severities, each
# severity's label colour and description, its label rules, and its issue
# body, rendered from its parts and parsed back - that review file, finding
# triage and issue triage read. Its tests:
# scripts/test/orch/filed-finding.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The severity table: each severity a filed finding carries as
# review:<severity> - the ones `review file` files - paired with its label's
# colour, as <severity>:<colour>, in order. Blocking is always fixed in the
# loop, never filed. Adding a severity is one entry here.
readonly FILED_SEVERITY_TABLE="major:d93f0b nit:c5def5"

# The filed severities alone, in the table's order, for usage lines, messages
# and loops over them. The loop runs in the substitution's subshell, so its
# variable never reaches the caller.
FILED_SEVERITIES="$(for entry in $FILED_SEVERITY_TABLE; do printf '%s ' "${entry%%:*}"; done)"
readonly FILED_SEVERITIES="${FILED_SEVERITIES% }"

# The axis table: each review axis a finding is filed on, paired with the
# category a finding filed on it starts in, as <axis>:<category>, in order. A
# Spec finding misses what was asked for, so it is a bug; a Standards finding
# improves how it was built, and so does a suite-cost one. Adding an axis is one
# entry here.
readonly FILED_AXIS_TABLE="spec:bug standards:enhancement suite-cost:enhancement"

# The review axes alone, in the table's order, for usage lines, messages and
# loops over them.
FILED_AXES="$(for entry in $FILED_AXIS_TABLE; do printf '%s ' "${entry%%:*}"; done)"
readonly FILED_AXES="${FILED_AXES% }"

# filed_severity_label <sev> <colour_var> <desc_var>: writes the review:<sev>
# label's colour, from the severity table, and description into the named
# variables; returns 1, writing neither, for a severity with no entry.
filed_severity_label() {
  local __fsl_entry
  for __fsl_entry in $FILED_SEVERITY_TABLE; do
    [ "$1" = "${__fsl_entry%%:*}" ] || continue
    printf -v "$2" '%s' "${__fsl_entry#*:}"
    printf -v "$3" 'Review finding filed at %s severity' "$1"
    return 0
  done
  return 1
}

# Whether <sev> is a filed severity: the one membership check, over
# FILED_SEVERITIES as derived from the severity table.
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
# starts in, from the axis table, whatever the axis's case. Prints nothing and
# fails for any other axis; the caller words its own error.
category_for_axis() {
  local entry
  for entry in $FILED_AXIS_TABLE; do
    [ "${1,,}" = "${entry%%:*}" ] || continue
    printf '%s\n' "${entry#*:}"
    return 0
  done
  return 1
}

# The location a suite-cost finding names: the suite as a whole, with no line.
readonly SUITE_LOCATION=suite

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
# filed before rendering existed parses as one rendered now does. An empty
# <line> renders the file alone, as a suite-cost finding's `suite` is.
finding_body_render() {
  local axis="${2,,}"
  local display_axis="${axis^}"
  printf '%s\n\n' "$(cat "$1")" \
    "**Axis:** $display_axis" \
    "**Severity:** $3 - $4" \
    "**Location:** \`$5${6:+:$6}\` at $7" \
    "**PR:** $8" \
    "**Why not fixed in the loop:** $9"
  [ -z "${10:-}" ] || printf '%s\n\n' "**Spec question:** ${10}"
}

# finding_body_parse <body> <array>: reads every labelled line of a filed
# finding's body into the caller's associative array <array>, keyed by field -
# axis (lowercased), severity, reason, file, line (N or N-M), sha, pr (the
# URL), pr_number, why and question. Every key is written on every call, so an
# array reused across bodies never keeps a previous body's value. Each
# comes from the first line that carries it, as finding triage always read
# them: Location from the first line starting with its label, with no
# fallback when that one does not parse - the first backticked <file>:<line>,
# the file free of backticks and colons, or else a backticked `suite`, a
# suite-cost finding's location, with an empty line, and the hex run of the
# line's last " at <hex>"; PR from the first line ending in a URL whose last
# segment after /pull/ is a number; the rest from the first line starting with
# their label, as the rest of it, trimmed. Severity splits at the first " - ". A
# field whose line is missing or does not parse is left empty. Never dies on a
# body, and never prints on success: each caller decides which fields it
# requires. Dies when <array> is not a declared associative array - a caller's
# programming error, which would otherwise write a global. Bash 4.0: each key is
# assigned by eval on the name the guard validated, its value passed by
# reference, never interpolated - printf -v into an array element needs 4.1.
finding_body_parse() {
  [[ $2 =~ ^[A-Za-z_][A-Za-z0-9_]*$ && $2 != __fbp_* \
    && $(declare -p "$2" 2>/dev/null) =~ ^declare\ -[A-Za-z]*A ]] \
    || die "finding_body_parse: $2 is not a declared associative array"
  local __fbp_line __fbp_rest __fbp_v __fbp_loc_file __fbp_loc_line
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
        trim_split "${__fbp_line#'**Axis:**'}" __fbp_v
        __fbp_axis="${__fbp_v,,}"
        ;;
      '**Severity:**'*)
        [ -z "$__fbp_seen_sev" ] || continue
        __fbp_seen_sev=1
        trim_split "${__fbp_line#'**Severity:**'}" __fbp_v
        case "$__fbp_v" in
          *' - '*)
            trim_split "${__fbp_v%%' - '*}" __fbp_severity
            trim_split "${__fbp_v#*' - '}" __fbp_reason
            ;;
          *) __fbp_severity="$__fbp_v" ;;
        esac
        ;;
      '**Location:**'*)
        [ -z "$__fbp_seen_loc" ] || continue
        __fbp_seen_loc=1
        if [[ $__fbp_line =~ $__fbp_loc_re ]]; then
          __fbp_loc_file="${BASH_REMATCH[1]}"; __fbp_loc_line="${BASH_REMATCH[2]}"
        elif [[ $__fbp_line == *"\`$SUITE_LOCATION\`"* ]]; then
          __fbp_loc_file="$SUITE_LOCATION"; __fbp_loc_line=""
        else
          continue
        fi
        __fbp_rest="$__fbp_line" __fbp_sha=""
        while [[ $__fbp_rest =~ $__fbp_at_re ]]; do
          __fbp_sha="${BASH_REMATCH[1]}"
          __fbp_rest="${__fbp_rest#*"${BASH_REMATCH[0]}"}"
        done
        [ -n "$__fbp_sha" ] || continue
        __fbp_file="$__fbp_loc_file" __fbp_lineno="$__fbp_loc_line"
        ;;
      '**Why not fixed in the loop:**'*)
        [ -z "$__fbp_seen_why" ] || continue
        __fbp_seen_why=1
        trim_split "${__fbp_line#'**Why not fixed in the loop:**'}" __fbp_why
        ;;
      '**Spec question:**'*)
        [ -z "$__fbp_seen_q" ] || continue
        __fbp_seen_q=1
        trim_split "${__fbp_line#'**Spec question:**'}" __fbp_question
        ;;
    esac
    # PR is read apart from the case above: a **PR:** line that does not end
    # in a pull request URL is skipped, and a later one may still match.
    if [ -z "$__fbp_seen_pr" ] && [[ $__fbp_line == '**PR:**'* ]] && [[ $__fbp_line =~ $__fbp_pr_re ]]; then
      __fbp_seen_pr=1
      __fbp_pr_number="${BASH_REMATCH[1]}"
      trim_split "${__fbp_line#'**PR:**'}" __fbp_pr
    fi
  done <<<"$1"
  eval "$2[line]=\$__fbp_lineno"
  for __fbp_v in axis severity reason file sha pr pr_number why question; do
    eval "$2[\$__fbp_v]=\$__fbp_$__fbp_v"
  done
}
