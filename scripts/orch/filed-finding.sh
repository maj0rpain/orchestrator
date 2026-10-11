# shellcheck shell=bash
# filed-finding.sh - the Filed finding module: a concept module with no orch.sh
# noun of its own, holding what a filed finding is - its severities, each
# severity's label colour and description, and its label rules - that review
# file, finding triage and issue triage read. Its tests:
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
