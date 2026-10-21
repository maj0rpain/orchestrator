# shellcheck shell=bash
# review-pass.sh - orch.sh's review-pass command: a review pass's start.
# Its tests: scripts/test/orch/review-pass.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A review pass's start, for a quick implementation's step 6 and a standalone
# review pass alike: the guard and the numbered report prefix each have one
# right answer, so they live here rather than in skill prose. Needs no flow
# state and may run where init never did, so it excludes the orchestrator
# directories itself. It reads state.json only when one exists, never through
# require_state, and never writes it: a branch or issue an active flow holds
# belongs to that flow (ADR-0029). Never wipes - each pass takes the next
# number, so a second pass on a branch never overwrites the first.
#
# review-pass known-items builds the pass's known-items file, also with no
# flow state: see review_pass_known_items.
cmd_review_pass() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) review_pass_begin "$@" ;;
    known-items) review_pass_known_items "$@" ;;
    *) die "unknown review-pass op: ${op:-<none>} (want begin|known-items)" ;;
  esac
}

review_pass_begin() {
  [ $# -eq 1 ] || die "usage: orch.sh review-pass begin <issue>"
  local issue="$1" branch
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  current_branch_or_die
  [ "$branch" != "$(recorded_base "$branch")" ] \
    || die "$branch is the base branch - a review pass reviews a branch's change against it; check out the change's branch"
  local phase held rc=0
  phase="$(flow_holding_phase "$branch" "$issue")" || rc=$?
  case "$rc" in
    0)
      held="$(state_get issue)"
      case "$phase" in
        implement|review)
          die "the active flow holds issue #$held at phase $phase - this change belongs to that flow's review loop; run $(flow_cmd next)" ;;
        spec)
          die "the active flow holds issue #$held at phase spec - its change has not been built yet; run $(flow_cmd next)" ;;
        *)
          die "the active flow holds issue #$held at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
      esac ;;
    1) ;;
    *) die "state.json cannot be read - run orch.sh doctor --flow" ;;
  esac
  exclude_orch_dirs
  local dir="$ORCH/review-pass/$branch" f n max=0
  mkdir -p "$dir"
  for f in "$dir"/iteration-[0-9][0-9]-*; do
    [ -e "$f" ] || continue
    n="${f##*/iteration-}"
    n="${n%%-*}"
    [ "$((10#$n))" -le "$max" ] || max="$((10#$n))"
  done
  printf '%s/iteration-%02d\n' "$dir" "$((max + 1))"
}

# A review pass's earlier pass, as standalone step 2 recognises one: a text
# carrying both a Review and a Host fallbacks heading.
REVIEW_PASS_HEADINGS=('## Review' '## Host fallbacks')

# The entries of an issue's Spec ruling comments, one per line, from the
# issue's structured read: each comment whose body begins `Spec ruling:`, the
# prefix stripped and its lines trimmed and joined by single spaces.
SPEC_RULING_ENTRIES_JQ='.comments[].body | gsub("\r"; "") | select(startswith("Spec ruling:"))
  | ltrimstr("Spec ruling:") | split("\n") | map(gsub("^\\s+|\\s+$"; ""))
  | map(select(length > 0)) | join(" ")'

# has_headings <file> <heading>...: true when <file> has every <heading> as a
# line of its own.
has_headings() {
  local file="$1" h
  shift
  for h in "$@"; do grep -qxF -- "$h" "$file" || return 1; done
}

# review_pass_known_items <issue> <path> [--deviations <file>]: writes the
# pass's known-items file to <path>, overwriting it - `## Deviations`, the
# PR body's Deviations or the --deviations file's entries in their place,
# then `## Known items`: the declines under Review in the PR body and in each
# PR comment that is an earlier pass's (REVIEW_PASS_HEADINGS), tagged
# declined, then the Spec rulings lines of every PR comment and each spec
# issue comment whose body begins `Spec ruling:` - that prefix stripped and
# the comment joined into one entry - tagged spec ruling. With no open PR,
# only the issue's rulings and the --deviations file are read. A heading with
# no entry reads None. Every refusal comes before the write, and the file is
# built aside and moved into place, so a refused run leaves <path> as it was.
review_pass_known_items() {
  local usage="usage: orch.sh review-pass known-items <issue> <path> [--deviations <file>]"
  [ $# -ge 2 ] || die "$usage"
  local issue="$1" path="$2" devfile="" pr st
  shift 2
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --deviations)
        [ -n "${2-}" ] || die "--deviations needs a file - $usage"
        devfile="$2"; shift 2 ;;
      *) die "unknown argument: $1 - $usage" ;;
    esac
  done
  if [ -n "$devfile" ]; then
    [ -f "$devfile" ] || die "deviations file not found: $devfile"
    [ -r "$devfile" ] || die "deviations file not readable: $devfile"
  fi

  local work
  work="$(mktemp -d)" || die "could not create a temp directory"
  # shellcheck disable=SC2064 # expanded now: $work is local, gone by exit
  trap "rm -rf $(printf '%q' "$work")" EXIT

  local k entry comment issue_json issue_rulings deviations="" declined="" rulings=""
  # A subshell's die has already said why; 1 alone means no open PR.
  pr="$(current_open_pr)" && st=0 || st=$?
  [ "$st" -le 1 ] || exit 1
  if [ "$st" -eq 0 ]; then
    gh_or_die --file "$work/body.raw" "read the body of PR #$pr" adapter_pr_body "$pr"
    gh_or_die --file "$work/comments.raw" "read the comments of PR #$pr" adapter_pr_comments "$pr"
    tr -d '\r' <"$work/body.raw" >"$work/body"
    tr -d '\r' <"$work/comments.raw" >"$work/comments"
    mkdir "$work/c"
    comments_split "$work/comments" "$work/c"
    [ -n "$devfile" ] || entries_append deviations "$work/body" '## Deviations'
    entries_append declined "$work/body" '## Review' declined
    for ((k = 1; ; k++)); do
      comment="$work/c/$k"
      [ -f "$comment" ] || break
      if has_headings "$comment" "${REVIEW_PASS_HEADINGS[@]}"; then
        entries_append declined "$comment" '## Review' declined
      fi
      entries_append rulings "$comment" '## Spec rulings' 'spec ruling'
    done
  fi
  if [ -n "$devfile" ]; then
    tr -d '\r' <"$devfile" >"$work/deviations"
    entries_append deviations "$work/deviations" ''
  fi
  gh_or_die --out issue_json "read the comments of issue #$issue" adapter_issue_json "$issue"
  issue_rulings="$(jq -r "$SPEC_RULING_ENTRIES_JQ" <<<"$issue_json")" \
    || die "could not read the comments of issue #$issue"
  while IFS= read -r entry; do
    [ -z "$entry" ] || rulings+="- $entry - spec ruling"$'\n'
  done <<<"$issue_rulings"
  known_items_write "$path" "$deviations" "$declined$rulings"
}
