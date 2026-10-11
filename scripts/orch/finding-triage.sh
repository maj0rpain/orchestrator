# shellcheck shell=bash
# finding-triage.sh - orch.sh's finding-triage command: scan, apply and bundle.
# Its tests: scripts/test/orch/finding-triage.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The plugin's own label on a bundle issue - one ordinary issue that several
# filed findings are closed into as duplicates (finding-triage bundle).
readonly BUNDLE_LABEL="finding-bundle"

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

# finding_location <body>: "<file>\t<line>\t<sha>" from a filed body's
# **Location:** line - the first backticked <file>:<line> on it, the line
# alone or a range, and the SHA after its last "at" - or nothing when the
# line is missing or does not parse.
finding_location() {
  printf '%s\n' "$1" | awk '
    /^\*\*Location:\*\*/ {
      if (!match($0, /`[^`:]+:[0-9]+(-[0-9]+)?`/)) exit
      loc = substr($0, RSTART + 1, RLENGTH - 2)
      rest = $0; sha = ""
      while (match(rest, / at [0-9a-fA-F]+/)) { sha = substr(rest, RSTART + 4, RLENGTH - 4); rest = substr(rest, RSTART + RLENGTH) }
      if (sha == "") exit
      i = match(loc, /:[0-9]+(-[0-9]+)?$/)
      printf "%s\t%s\t%s\n", substr(loc, 1, i - 1), substr(loc, i + 1), sha
      exit
    }'
}

# finding_pr <body>: the PR number - the trailing number of the **PR:** line's
# URL - or nothing.
finding_pr() {
  printf '%s\n' "$1" | sed -n 's|^\*\*PR:\*\*.*/pull/\([0-9][0-9]*\)/*[[:space:]]*$|\1|p' | sed -n 1p
}

# map_line <old sha> <new ref> <file> <line>: where <line> of <file> at <old
# sha> sits at <new ref>, read off the zero-context diff between them. A line
# inside a changed hunk maps to that hunk's start. The awk exits as soon as it
# knows the answer; under pipefail, git diff's SIGPIPE must not fail the call.
map_line() {
  { git diff -U0 "$1" "$2" -- "$3" 2>/dev/null || true; } | awk -v L="$4" '
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      a = substr(o[1], 2) + 0; b = (2 in o) ? o[2] + 0 : 1
      c = substr(n[1], 2) + 0; d = (2 in n) ? n[2] + 0 : 1
      if (b > 0 && a <= L && L <= a + b - 1) { done = 1; print (c > 0 ? c : 1); exit }
      if ((b > 0 && a + b - 1 < L) || (b == 0 && a < L)) off += d - b
      else exit
    }
    END { if (!done) print L + off }'
}

# deleted_ranges <old sha> <new ref> <file> <start> <end>: the parts of lines
# <start>-<end> of <file> at <old sha> that the zero-context diff to <new ref>
# deletes outright - inside a hunk whose new count is 0 - one "<from>,<to>"
# per part, or nothing. A line a hunk replaces is not deleted by this rule.
deleted_ranges() {
  { git diff -U0 "$1" "$2" -- "$3" 2>/dev/null || true; } | awk -v S="$4" -v E="$5" '
    /^@@ / {
      split($2, o, ","); split($3, n, ",")
      a = substr(o[1], 2) + 0; b = (2 in o) ? o[2] + 0 : 1
      d = (2 in n) ? n[2] + 0 : 1
      if (a > E) exit
      if (b > 0 && d == 0) {
        lo = (a > S) ? a : S; hi = (a + b - 1 < E) ? a + b - 1 : E
        if (lo <= hi) print lo "," hi
      }
    }'
}

# range_lines <ranges>: each line number the newline-separated "<from>,<to>"
# ranges cover, one per line.
range_lines() {
  local range
  for range in $1; do seq "${range%,*}" "${range#*,}"; done
}

# squash_deleting_commit <old sha> <ref> <file> <ranges>: the commit on
# <ref>'s first-parent line that deleted the newest of the <ranges> - lines of
# <file> at <old sha>, a commit off <ref>, deleted by <ref> - or nothing. Off
# the default branch, the lines reached it through a squash commit, so the
# deleting commit is the newest one since which every line stays deleted:
# walking back, the one after the first commit that still holds one of them.
squash_deleting_commit() {
  local old="$1" ref="$2" file="$3" ranges="$4" commits commit start end held after=""
  # The first range's start, read without a pipe: head would leave
  # range_lines' seq to SIGPIPE under pipefail on a large deletion (#1019).
  start="${ranges%%$'\n'*}"; start="${start%%,*}"
  end="$(range_lines "$ranges" | tail -n 1)"
  commits="$(git log --first-parent --format=%H "$ref" "^$old" -- "$file" 2>/dev/null)" || return 0
  for commit in $commits; do
    held="$(comm -23 <(range_lines "$ranges" | sort) \
      <(range_lines "$(deleted_ranges "$old" "$commit" "$file" "$start" "$end")" | sort))"
    if [ -n "$held" ]; then printf '%s\n' "$after"; return 0; fi
    after="$commit"
  done
}

# deleting_commit <old sha> <ref> <file> <ranges>: the commit that deleted
# the <ranges>, lines of <file> at <old sha> that <ref> no longer has - the
# newest such commit when they were deleted by several - or nothing when the
# exact lookup fails. A reverse blame names, for each line, the commit C it
# last existed in, and its deleting commit is the oldest since C to touch the
# file.
deleting_commit() {
  local old="$1" ref="$2" file="$3" ranges="$4" ref_sha range blame_out last_seen last since_last deleter deleters="" commit off_branch=false
  ref_sha="$(git rev-parse --verify -q "$ref^{commit}")" || return 0
  for range in $ranges; do
    blame_out="$(git blame --reverse --porcelain -L "$range" "$old..$ref" -- "$file" 2>/dev/null)" || return 0
    last_seen="$(printf '%s\n' "$blame_out" | grep -E '^[0-9a-f]{40} [0-9]' | cut -d' ' -f1 | sort -u)" || true
    [ -n "$last_seen" ] || return 0
    for last in $last_seen; do
      [ "$last" != "$ref_sha" ] || return 0
      if ! git merge-base --is-ancestor "$last" "$ref" 2>/dev/null; then off_branch=true; continue; fi
      since_last="$(git log --reverse --format=%H "$ref" "^$last" -- "$file" 2>/dev/null)" || return 0
      deleter="${since_last%%$'\n'*}"
      [ -n "$deleter" ] || return 0
      deleters="$deleters $deleter"
    done
  done
  if $off_branch; then
    deleter="$(squash_deleting_commit "$old" "$ref" "$file" "$ranges")"
    [ -n "$deleter" ] || return 0
    deleters="$deleters $deleter"
  fi
  for commit in $(git log --format=%H "$ref" "^$old" -- "$file" 2>/dev/null); do
    case " $deleters " in *" $commit "*) printf '%s\n' "$commit"; return 0 ;; esac
  done
}

# scan_line <file:lines> <result> <detail>: the scan's one line, in the
# columns `finding-triage scan` prints. Local to finding_scan_one in effect: it
# reads the issue and PR number and the triage state, n, pr and roles, from
# that call's locals, through bash's dynamic scope, and prints - for an empty
# PR or detail.
scan_line() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "${pr:--}" "$1" "$2" "${3:--}" "$roles"
}

# triage_state <labels>: the triage-role labels among the newline-separated
# <labels>, each by the repo's label for its role, comma-joined in
# TRIAGE_ROLES order - or - for none.
triage_state() {
  local role label out=""
  for role in $TRIAGE_ROLES; do
    label="$(triage_label_for "$role")"
    labels_have "$1" "$label" && out="${out:+$out,}$label"
  done
  printf '%s\n' "${out:--}"
}

# finding_scan_one <issue> <body> <default ref> <triage state>: the scan's one
# line for one finding.
finding_scan_one() {
  local n="$1" body="$2" ref="$3" roles="$4" loc pr file lines sha resolved_sha start end new_start new_end detail file_commit log_out deleted
  pr="$(finding_pr "$body")"
  loc="$(finding_location "$body")"
  if [ -z "$loc" ]; then
    scan_line - unknown 'body does not parse: no **Location:** line naming `<file>:<line>` at <SHA>'
    return
  fi
  IFS=$'\t' read -r file lines sha <<<"$loc"
  if [ -z "$pr" ]; then
    scan_line "$file:$lines" unknown 'body does not parse: no **PR:** line ending in a pull request URL'
    return
  fi
  # A squash merge leaves the PR's head commit off every branch: the PR's own
  # head ref still holds it.
  if ! resolved_sha="$(git rev-parse --verify -q "$sha^{commit}")"; then
    git fetch -q origin "refs/pull/$pr/head" >/dev/null 2>&1 || true
    if ! resolved_sha="$(git rev-parse --verify -q "$sha^{commit}")"; then
      scan_line "$file:$lines" unknown "head SHA $sha is unreachable, even after fetching refs/pull/$pr/head"
      return
    fi
  fi
  if ! git cat-file -e "$ref:$file" 2>/dev/null; then
    scan_line "$file:$lines" gone ""
    return
  fi
  if git diff --quiet "$resolved_sha" "$ref" -- "$file" 2>/dev/null; then
    scan_line "$file:$lines" unchanged ""
    return
  fi
  start="${lines%%-*}"; end="${lines#*-}"
  new_start="$(map_line "$resolved_sha" "$ref" "$file" "$start")"
  new_end="$(map_line "$resolved_sha" "$ref" "$file" "$end")"
  [ "$new_end" -ge "$new_start" ] || new_end="$new_start"
  # The newest commit since the filing that touched the file. None at all: the
  # difference is the PR's own commits, never on the default branch, and any
  # older commit would predate the filing.
  file_commit="$(git log -1 --format=%H "$ref" "^$resolved_sha" -- "$file" 2>/dev/null)" || true
  if [ -z "$file_commit" ]; then
    scan_line "$file:$lines" unknown "no commit on the default branch since $sha touched $file - the difference is commits that never reached it"
    return
  fi
  # Filed lines deleted outright are changed, whatever the lines around them
  # say: named by the commit that deleted them, or, when that lookup fails,
  # by the newest commit touching the file.
  deleted="$(deleted_ranges "$resolved_sha" "$ref" "$file" "$start" "$end")"
  if [ -n "$deleted" ]; then
    detail="$(deleting_commit "$resolved_sha" "$ref" "$file" "$deleted")"
    scan_line "$file:$lines" changed "${detail:-$file_commit}"
    return
  fi
  # The newest commit since the filing that touched the finding's lines. The
  # output is captured whole before filtering and given to grep -m1 as a
  # herestring: piping it into grep -m1 or head could SIGPIPE the writer and
  # pass for a failure under pipefail.
  if log_out="$(git log -1 --format=%H -L "$new_start,$new_end:$file" "$ref" "^$resolved_sha" 2>/dev/null)"; then
    detail="$(grep -m1 -Ex '[0-9a-f]{40}' <<<"$log_out")" || true
    # The lines were followed and nothing since the filing touched them: the
    # file changed only elsewhere.
    if [ -z "$detail" ]; then
      scan_line "$file:$lines" unchanged ""
      return
    fi
  else
    # A range starting past the file's end can't be followed: the newest
    # commit touching the file stands in.
    detail="$file_commit"
  fi
  scan_line "$file:$lines" changed "$detail"
}

# finding-triage scan [--all] [<issue> | --pr <n>]: read-only. Sorts each open
# filed finding still in needs-triage - or, with --all, whatever its triage
# label - against origin/<default>, one tab-separated line apiece: <issue>
# <pr> <file>:<line> <result> <detail> <triage state>.
cmd_finding_triage_scan() {
  local usage="usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]"
  local all=false issue="" pr_filter="" triage sev nums="" n out state labels body default ref gh_err err
  local args=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --all) ! $all || die "$usage"; all=true ;;
      --pr) [ -z "$pr_filter" ] && [ -n "${2:-}" ] || die "$usage"; pr_filter="$2"; shift ;;
      *) args+=("$1") ;;
    esac
    shift
  done
  case "${#args[@]}" in
    0) ;;
    1) [ -z "$pr_filter" ] && [ -n "${args[0]}" ] || die "$usage"; issue="${args[0]}" ;;
    *) die "$usage" ;;
  esac
  case "$issue$pr_filter" in *[!0-9]*) die "$usage" ;; esac
  triage="$(triage_label_for needs-triage)"
  # Each finding is read once, state, labels and body together: an explicit
  # one here, where it is checked, a listed one in the loop below.
  if [ -n "$issue" ]; then
    issue_state_labels_body_read "$issue" state labels body gh_err \
      || die "gh could not read issue #$issue: $(gh_reason "$gh_err")"
    [ "$state" = OPEN ] || die "issue #$issue is not open - finding triage takes open filed findings only"
    has_filed_severity_label "$labels" \
      || die "issue #$issue is not a filed finding - it carries no review:<severity> label for a filed severity (review:${FILED_SEVERITIES// / or review:})"
    $all || labels_have "$labels" "$triage" \
      || die "issue #$issue is not in triage - it carries no '$triage' label"
    nums="$issue"
  else
    for sev in $FILED_SEVERITIES; do
      if $all; then capture out err adapter_issues_labelled "review:$sev"
      else capture out err adapter_issues_labelled "review:$sev" "$triage"; fi \
        || die "gh could not list the review:$sev findings: $(gh_reason "$err")"
      if [ "$(printf '%s\n' $out | grep -c .)" -ge "$ISSUE_LIST_LIMIT" ]; then
        warn "review:$sev findings reached the issue-list limit of $ISSUE_LIST_LIMIT - any past it are missing from this scan"
      fi
      nums="$nums $out"
    done
  fi
  default="$(default_branch)"
  ref="refs/remotes/origin/$default"
  git fetch -q origin "+refs/heads/$default:$ref" >/dev/null 2>&1 \
    || die "could not fetch origin/$default"
  for n in $(printf '%s\n' $nums | sort -nu); do
    if [ -z "$issue" ]; then
      issue_state_labels_body_read "$n" state labels body gh_err \
        || die "gh could not read issue #$n: $(gh_reason "$gh_err")"
    fi
    if [ -n "$pr_filter" ] && [ "$(finding_pr "$body")" != "$pr_filter" ]; then continue; fi
    finding_scan_one "$n" "$body" "$ref" "$(triage_state "$labels")"
  done
}

# triage_comment_post <issue> <file>: posts <file> on the issue under the AI
# disclaimer every comment finding triage writes carries. Fails as the
# comment's adapter call does; the caller words its own error.
triage_comment_post() {
  local tmp rc=0
  tmp="$(mktemp)"
  { printf '%s\n\n' '> *This was generated by AI during triage.*'; cat "$2"; } >"$tmp"
  adapter_issue_comment "$1" "$tmp" || rc=$?
  rm -f "$tmp"
  return "$rc"
}

# finding-triage apply <issue> <outcome> [--category <bug|enhancement>]
# --comment-file <file>: finding triage's one write to GitHub. Posts the
# comment under the AI disclaimer, removes every triage-role label the issue
# carries other than the one the outcome sets, and either closes it
# (close-fixed: completed; wontfix: not planned, labelled wontfix) or labels it
# with its state, keeping review:<severity> and leaving exactly the one
# category asked for. Every state label is the repo's name for
# the role. Only a failed category-label create is forgiven; any other failed
# gh call dies.
cmd_finding_triage_apply() {
  local usage="usage: orch.sh finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
       orch.sh finding-triage apply <issue> <ready-for-agent|ready-for-human> --category <bug|enhancement> --comment-file <file>"
  local issue="${1:-}" outcome="${2:-}" category="" file="" state labels role label stale_category gh_err err
  # The relabel's --remove options, possibly none: close-fixed, where they are
  # the whole relabel, then makes no edit at all.
  local remove_opts=()
  [ $# -ge 2 ] || die "$usage"
  shift 2
  while [ $# -gt 0 ]; do
    case "$1" in
      --category)     [ $# -ge 2 ] || die "$usage"; category="$2"; shift 2 ;;
      --comment-file) [ $# -ge 2 ] || die "$usage"; file="$2"; shift 2 ;;
      *) die "$usage" ;;
    esac
  done
  case "$issue" in ''|*[!0-9]*) die "$usage" ;; esac
  case "$outcome" in
    close-fixed|wontfix)
      [ -z "$category" ] || die "--category is for an outcome that stays open, not $outcome" ;;
    ready-for-agent|ready-for-human)
      [ -n "$category" ] || die "$outcome needs --category <bug|enhancement>"
      stale_category="$(category_other "$category")" \
        || die "unknown --category '$category' - expected bug or enhancement" ;;
    *) die "$usage" ;;
  esac
  [ -n "$file" ] || die "$usage"
  [ -f "$file" ] || die "comment file not found: $file"

  # Only the labels are wanted: the state is the read's throwaway half, rather
  # than a third, near-identical label read added beside
  # adapter_issue_state_labels and adapter_issue_title_labels.
  issue_state_labels_read "$issue" state labels gh_err \
    || die "gh could not read issue #$issue: $(gh_reason "$gh_err")"
  # Every triage-role label the issue carries but the outcome does not set
  # goes, so an already-triaged finding ends in the one state the outcome
  # sets. Remove only what the issue carries: gh refuses to remove a label the
  # repo does not have at all.
  for role in $TRIAGE_ROLES; do
    [ "$role" != "$outcome" ] || continue
    label="$(triage_label_for "$role")"
    if labels_have "$labels" "$label"; then remove_opts+=(--remove "$label"); fi
  done

  capture_err err triage_comment_post "$issue" "$file" \
    || die "gh could not comment on issue #$issue: $(gh_reason "$err")"

  case "$outcome" in
    close-fixed)
      capture_err err adapter_issue_relabel "$issue" ${remove_opts[@]+"${remove_opts[@]}"} \
        || die "gh could not relabel issue #$issue: $(gh_reason "$err")"
      capture_err err adapter_issue_close "$issue" --reason completed \
        || die "gh could not close issue #$issue: $(gh_reason "$err")" ;;
    wontfix)
      capture_err err adapter_issue_relabel "$issue" --add "$(triage_label_for wontfix)" \
        ${remove_opts[@]+"${remove_opts[@]}"} \
        || die "gh could not relabel issue #$issue: $(gh_reason "$err")"
      capture_err err adapter_issue_close "$issue" --reason "not planned" \
        || die "gh could not close issue #$issue: $(gh_reason "$err")" ;;
    *)
      category_label_ensure "$category"
      if labels_have "$labels" "$stale_category"; then remove_opts+=(--remove "$stale_category"); fi
      capture_err err adapter_issue_relabel "$issue" --add "$(triage_label_for "$outcome")" --add "$category" \
        ${remove_opts[@]+"${remove_opts[@]}"} \
        || die "gh could not relabel issue #$issue: $(gh_reason "$err")" ;;
  esac
}

# bundle_member_check <issue> <labels_var>: dies unless issue #<issue> can be
# a bundle's member - open, carrying a filed-severity review:<severity> label,
# exactly one of the repo's ready-for-agent and ready-for-human labels and none
# of its needs-triage, needs-info and wontfix - naming the issue and why.
# Writes its labels into the caller-named variable, for the caller's own
# checks.
bundle_member_check() {
  local __bmc_state __bmc_labels __bmc_err __bmc_role __bmc_label __bmc_ready=""
  issue_state_labels_read "$1" __bmc_state __bmc_labels __bmc_err \
    || die "gh could not read issue #$1: $(gh_reason "$__bmc_err")"
  [ "$__bmc_state" = OPEN ] || die "issue #$1 is not open - a bundle takes open filed findings only"
  has_filed_severity_label "$__bmc_labels" \
    || die "issue #$1 is not a filed finding - it carries no review:<severity> label for a filed severity (review:${FILED_SEVERITIES// / or review:})"
  for __bmc_role in needs-triage needs-info wontfix; do
    __bmc_label="$(triage_label_for "$__bmc_role")"
    ! labels_have "$__bmc_labels" "$__bmc_label" \
      || die "issue #$1 carries '$__bmc_label' - a bundle takes findings already triaged to ready-for-agent or ready-for-human only"
  done
  for __bmc_role in ready-for-agent ready-for-human; do
    __bmc_label="$(triage_label_for "$__bmc_role")"
    labels_have "$__bmc_labels" "$__bmc_label" || continue
    [ -z "$__bmc_ready" ] \
      || die "issue #$1 carries both '$__bmc_ready' and '$__bmc_label' - a member carries exactly one"
    __bmc_ready="$__bmc_label"
  done
  [ -n "$__bmc_ready" ] \
    || die "issue #$1 carries neither '$(triage_label_for ready-for-agent)' nor '$(triage_label_for ready-for-human)' - triage it with $(finding_triage_cmd) first"
  printf -v "$2" '%s' "$__bmc_labels"
}

# finding-triage bundle --title <t> --body-file <f> --state <ready-for-agent|
# ready-for-human> --category <bug|enhancement> <member>...: creates one
# bundle issue - the title and body as given, labelled finding-bundle, the
# repo's label for the state and the category, never a review: label - prints
# its number, then comments each member `Bundled into #B` under the AI
# disclaimer and closes it as a duplicate of the bundle, keeping its labels,
# reading its state back. Every member is checked before any write. The
# state and category may be stricter than the members', never looser.
# --into <B> <member>... is the resume form: it checks the members the same
# way (one is enough) and that B is an open issue labelled finding-bundle,
# then only comments, closes and reads back - it never edits B. Any member
# failure dies naming the bundle and the members left open, with the --into
# command that resumes.
cmd_finding_triage_bundle() {
  local usage="usage: orch.sh finding-triage bundle --title <t> --body-file <f> --state <ready-for-agent|ready-for-human> --category <bug|enhancement> <member>...
       orch.sh finding-triage bundle --into <B> <member>..."
  local title="" file="" state="" category="" into="" have_title=false m labels human_label b err
  local members=() seen=" "
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     [ $# -ge 2 ] || die "$usage"; title="$2"; have_title=true; shift 2 ;;
      --body-file) [ $# -ge 2 ] || die "$usage"; file="$2"; shift 2 ;;
      --state)     [ $# -ge 2 ] || die "$usage"; state="$2"; shift 2 ;;
      --category)  [ $# -ge 2 ] || die "$usage"; category="$2"; shift 2 ;;
      --into)      [ $# -ge 2 ] || die "$usage"; into="$2"; shift 2 ;;
      *) members+=("$1"); shift ;;
    esac
  done
  [ ${#members[@]} -gt 0 ] || die "$usage"
  for m in "${members[@]}"; do
    case "$m" in ''|*[!0-9]*) die "$usage" ;; esac
  done
  if [ -n "$into" ]; then
    case "$into" in *[!0-9]*) die "$usage" ;; esac
    ! $have_title && [ -z "$file$state$category" ] || die "$usage"
    local b_state b_labels b_err
    issue_state_labels_read "$into" b_state b_labels b_err \
      || die "gh could not read issue #$into: $(gh_reason "$b_err")"
    [ "$b_state" = OPEN ] || die "bundle #$into is not open - --into resumes an open bundle only"
    labels_have "$b_labels" "$BUNDLE_LABEL" \
      || die "issue #$into carries no '$BUNDLE_LABEL' label - --into resumes a bundle only"
  else
    $have_title && [ -n "$title" ] && [ -n "$file" ] && [ -n "$state" ] && [ -n "$category" ] || die "$usage"
    case "$state" in ready-for-agent|ready-for-human) ;; *) die "$usage" ;; esac
    category_other "$category" >/dev/null || die "unknown --category '$category' - expected bug or enhancement"
    [ -f "$file" ] || die "body file not found: $file"
    [ ${#members[@]} -ge 2 ] || die "a new bundle needs at least 2 members - got #${members[0]} alone"
    human_label="$(triage_label_for ready-for-human)"
  fi

  for m in "${members[@]}"; do
    case "$seen" in *" $m "*) die "issue #$m is named twice" ;; esac
    seen="$seen$m "
    bundle_member_check "$m" labels
    if [ -z "$into" ]; then
      [ "$state" != ready-for-agent ] || ! labels_have "$labels" "$human_label" \
        || die "--state ready-for-agent, but issue #$m carries '$human_label' - a bundle is ready-for-human whenever any member is"
      [ "$category" != enhancement ] || ! labels_have "$labels" bug \
        || die "--category enhancement, but issue #$m carries 'bug' - a bundle is a bug whenever any member is"
    fi
  done

  if [ -n "$into" ]; then
    bundle_members_close "$into" "${members[@]}"
    return
  fi

  # The finding-bundle label is the plugin's, but created only where missing,
  # as the triage labels are: a failed create is forgiven, and a truly missing
  # label then fails the issue create.
  adapter_label_create "$BUNDLE_LABEL" c5def5 "Several filed findings worked as one" 2>/dev/null || true
  category_label_ensure "$category"
  capture b err adapter_issue_create "$title" "$file" "$BUNDLE_LABEL" "$(triage_label_for "$state")" "$category" \
    || die "gh could not create the bundle issue: $(gh_reason "$err") - no member was touched"
  printf '%s\n' "$b"
  bundle_members_close "$b" "${members[@]}"
}

# bundle_members_close <B> <member>...: closes each member into bundle #B, in
# order - reads its comments and, unless one already holds `Bundled into #B`,
# posts that under the AI disclaimer; closes it as a duplicate of B; reads its
# state back as CLOSED. The first member that fails dies naming the bundle,
# what failed, the members left open - that one and every one after it - and
# the --into command that resumes.
bundle_members_close() {
  local b="$1" comment_file m i=0 comments state why left err
  shift
  local members=("$@")
  comment_file="$(mktemp)"
  printf 'Bundled into #%s\n' "$b" >"$comment_file"
  for m in "${members[@]}"; do
    why=""
    if ! capture comments err adapter_issue_comments "$m"; then
      why="gh could not read member #$m's comments: $(gh_reason "$err")"
    elif ! grep -qE "Bundled into #$b([^0-9]|\$)" <<<"$comments" \
      && ! capture_err err triage_comment_post "$m" "$comment_file"; then
      why="gh could not comment on member #$m: $(gh_reason "$err")"
    elif ! capture_err err adapter_issue_close "$m" --duplicate-of "$b"; then
      why="gh could not close member #$m as a duplicate: $(gh_reason "$err") - --duplicate-of needs gh 2.102 or newer"
    elif ! capture state err adapter_issue_state "$m"; then
      why="gh could not read member #$m's state back: $(gh_reason "$err")"
    elif [ "$state" != CLOSED ]; then
      why="member #$m did not read back as closed"
    fi
    if [ -n "$why" ]; then
      rm -f "$comment_file"
      left="${members[*]:$i}"
      die "bundle #$b: $why - members left open: #${left// / #}; resume with: orch.sh finding-triage bundle --into $b $left"
    fi
    i=$((i + 1))
  done
  rm -f "$comment_file"
}

cmd_finding_triage() {
  local op="${1:-}"
  shift || true
  case "$op" in
    scan) cmd_finding_triage_scan "$@" ;;
    apply) cmd_finding_triage_apply "$@" ;;
    bundle) cmd_finding_triage_bundle "$@" ;;
    *) die "usage: orch.sh finding-triage <scan|apply|bundle> ..." ;;
  esac
}
