# shellcheck shell=bash
# pr.sh - orch.sh's pr command: open, publish, release, comment and the
# stateless PR reads and writes, draft and ready among them.
# Its tests: scripts/test/orch/pr.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# Pushing a branch and opening a PR against it has exactly one right answer -
# push, then prefix the body with the issue line - Closes into the default
# branch, so GitHub links the PR as a closer (no agent-chosen wording can leave
# the issue open again), Refs into any other base - then create the PR - so
# pr open (a flow's own, draft, recorded into state) and pr publish (a quick
# implementation's, not a draft, recording nothing) share it rather
# than each hand-rolling the push/issue-line/gh-pr-create idiom.
open_pr() {
  local branch="$1" base="$2" issue="$3" title="$4" body_file="$5" draft="$6" tmp pr err keyword=Closes draft_opt=()
  git push -q -u origin "$branch"
  # GitHub only acts on a closing keyword when the PR merges into the default
  # branch, so a PR into any other base branch refers to its issue instead of
  # claiming to close it - the release PR is what closes it.
  [ "$base" = "$(default_branch)" ] || keyword=Refs
  tmp="$(mktemp)"
  { printf '%s #%s\n\n' "$keyword" "$issue"; cat "$body_file"; } >"$tmp"
  [ "$draft" != true ] || draft_opt=(--draft)
  if ! capture pr err adapter_pr_create "$base" "$branch" "$title" "$tmp" ${draft_opt[@]+"${draft_opt[@]}"}; then
    rm -f "$tmp"
    die "gh could not open the PR for branch $branch (issue #$issue): $(gh_reason "$err")"
  fi
  rm -f "$tmp"
  printf '%s\n' "$pr"
}

cmd_pr_open() {
  require_state
  [ $# -eq 2 ] || die "usage: orch.sh pr open <title> <body-file>"
  local title="$1" body_file="$2" issue branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  require_issue issue
  require_branch branch
  # Draft is the honest signal: the review loop has not run yet, so marking it
  # ready is the loop's success condition rather than a comment nobody reads.
  pr="$(open_pr "$branch" "$(flow_base)" "$issue" "$title" "$body_file" true)"
  state_write pr "$pr"
  note "$pr"
}

# The PR-opening boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - the same reason `issue publish` owns its own
# `gh issue create` rather than leaving it to skill prose. Stateless like
# branch off and issue publish: the caller has no flow to record into, and no
# draft to promote later, since a quick implementation's review pass already
# ran before this is called - unless that pass met a spec question (#967):
# --draft then opens it as a draft, held until a human rules on the question.
cmd_pr_publish() {
  local usage="usage: orch.sh pr publish <issue> <title> <body-file> [--draft]" draft=false
  [ $# -eq 3 ] || [ $# -eq 4 ] || die "$usage"
  if [ $# -eq 4 ]; then
    [ "$4" = --draft ] || die "unknown option: $4 - $usage"
    draft=true
  fi
  local issue="$1" title="$2" body_file="$3" branch base pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  base="$(recorded_base "$branch")"
  pr="$(open_pr "$branch" "$base" "$issue" "$title" "$body_file" "$draft")"
  note "$pr"
}

# The release PR: carries the base branch in effect back into the default
# branch. Stateless like pr publish, and pushes nothing - the base branch is
# already on origin.
cmd_pr_release() {
  local usage="usage: orch.sh pr release [--force] <title> <body-file>" force=false
  if [ "${1:-}" = --force ]; then force=true; shift; fi
  [ $# -eq 2 ] || die "$usage"
  local title="$1" body_file="$2" base default
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  base="$(base_branch)"
  default="$(default_branch)"
  [ "$base" != "$default" ] ||
    die "the base branch is the default branch ($default) - there is nothing to release; set another with base set"
  local open err
  capture open err adapter_prs_open "$base" "$default" ||
    die "gh could not list the open PRs from $base into $default: $(gh_reason "$err")"
  [ -z "$open" ] || die "a release PR from $base into $default is already open: #${open%%$'\n'*}"
  # Read from the merged PRs' bodies rather than GitHub's closing-issue links:
  # GitHub only links closing keywords on PRs into the default branch, and a
  # Refs line never links at all. Refs, Closes, Fixes and Resolves count, in
  # any case and anywhere in the body - not every closing form GitHub knows,
  # so prose such as "a quick fix #12" is never mistaken for a reference.
  local bodies refs n state issues="" tmp pr
  capture bodies err adapter_prs_merged_bodies "$base" ||
    die "gh could not list the PRs merged into $base: $(gh_reason "$err")"
  refs="$(printf '%s\n' "$bodies" |
    grep -ioE '(^|[^[:alnum:]_])(refs|closes|fixes|resolves):?[[:space:]]+#[0-9]+' |
    grep -oE '[0-9]+$' | sort -nu)" || true
  # gh issue view answers for a PR number too, so a reference to a PR reads
  # as PULL and is dropped - only still-open issues get a Closes line.
  for n in $refs; do
    capture state err adapter_issue_state "$n" ||
      die "gh could not read the state of issue #$n: $(gh_reason "$err")"
    [ "$state" != OPEN ] || issues="$issues $n"
  done
  [ -n "$issues" ] || [ "$force" = true ] ||
    die "nothing to close: no PR merged into $base refers to a still-open issue - pass --force to release anyway"
  tmp="$(mktemp)"
  {
    for n in $issues; do printf 'Closes #%s\n' "$n"; done
    [ -z "$issues" ] || printf '\n'
    cat "$body_file"
  } >"$tmp"
  # Not a draft: nothing after this would ever mark it ready.
  if ! capture pr err adapter_pr_create "$default" "$base" "$title" "$tmp"; then
    rm -f "$tmp"
    die "gh could not open the release PR from $base into $default: $(gh_reason "$err")"
  fi
  rm -f "$tmp"
  note "$pr"
}

# A stateless post on the current branch's open PR, the PR counterpart of
# issue comment - for a standalone review pass, which records its declines
# there. Three outcomes: 0 posted (printing the PR number), 1 only when the
# branch has no open PR, and 2 for everything else - GitHub unreadable, a
# failed post, a usage error, a missing file, a detached HEAD. The exit-2
# cases go through die2, since die exits 1 and a caller reading 1 would take
# a failure for "no PR". The GitHub-unreadable and usage-error rules are
# shared with ticket exists: a GitHub that cannot be read, or a usage error,
# exits 2, never 1.
cmd_pr_comment() {
  [ $# -eq 1 ] || die2 "usage: orch.sh pr comment <file>"
  local file="$1" pr err
  [ -f "$file" ] || die2 "body file not found: $file"
  pr="$(current_open_pr)" || return $?
  capture_err err adapter_pr_comment "$pr" "$file" \
    || die2 "gh could not comment on PR #$pr: $(gh_reason "$err")"
  printf '%s\n' "$pr"
}

# pr draft and pr ready (#967): the current branch's open PR turned into a
# draft, or marked ready, for a standalone review pass whose spec questions
# hold the PR or no longer do. Stateless, with pr comment's exit codes: 0 done,
# a PR already in that state included, saying so - so the caller reads no draft
# state; 1 only when the branch has no open PR; 2 for everything else, a
# refusal included. A branch an active flow holds is refused: its PR changes
# state only through the review loop (review ready and its Ready conditions).
cmd_pr_draft() {
  [ $# -eq 0 ] || die2 "usage: orch.sh pr draft"
  local out pr is_draft err
  out="$(open_pr_draft_flag)" || exit $?
  lines_split "$out" pr is_draft
  if [ "$is_draft" = true ]; then
    note "PR #$pr is already a draft"
    return 0
  fi
  capture_err err adapter_pr_draft "$pr" \
    || die2 "gh could not turn PR #$pr into a draft: $(gh_reason "$err")"
  note "PR #$pr is now a draft"
}

cmd_pr_ready() {
  [ $# -eq 0 ] || die2 "usage: orch.sh pr ready"
  local out pr is_draft err
  out="$(open_pr_draft_flag)" || exit $?
  lines_split "$out" pr is_draft
  if [ "$is_draft" != true ]; then
    note "PR #$pr is already ready"
    return 0
  fi
  capture_err err adapter_pr_ready "$pr" \
    || die2 "gh could not mark PR #$pr ready: $(gh_reason "$err")"
  note "PR #$pr is now ready"
}

# pr draft's and pr ready's shared front: refuses a branch an active flow
# holds, then prints the current branch's open PR number and its draft flag
# (true or false), one per line. Returns 1, printing nothing, when the branch
# has no open PR, as current_open_pr does.
open_pr_draft_flag() {
  local branch phase pr state_draft _pr_state is_draft _rest err
  branch="$(git symbolic-ref --quiet --short HEAD)" \
    || die2 "not on a branch (detached HEAD)"
  if phase="$(flow_holding_phase "$branch")"; then
    die2 "the active flow holds $branch at phase $phase - its PR changes state only through the review loop"
  fi
  pr="$(current_open_pr)" || return $?
  capture state_draft err adapter_pr_state_draft "$pr" \
    || die2 "gh could not read PR #$pr: $(gh_reason "$err")"
  lines_split "$state_draft" _pr_state is_draft _rest
  [ "$is_draft" = true ] || is_draft=false
  printf '%s\n%s\n' "$pr" "$is_draft"
}

# The current branch's open PR number, for pr comment, pr comments, pr fetch
# and pr update.
# Returns 1, printing nothing, when the branch has no open PR; every other
# failure - a detached HEAD, a GitHub that cannot be read - goes through die2,
# so a caller in a subshell can tell "no PR" apart from an error and map each
# to its own exit code.
current_open_pr() {
  local branch open err
  branch="$(git symbolic-ref --quiet --short HEAD)" \
    || die2 "not on a branch (detached HEAD)"
  capture open err adapter_prs_open "$branch" \
    || die2 "gh could not list the open PRs from $branch: $(gh_reason "$err")"
  [ -n "$open" ] || return 1
  printf '%s\n' "${open%%$'\n'*}"
}

# The PR pr fetch and pr update work on. Unlike pr comment, no open PR is an
# ordinary failure here, since both run where a PR is known to exist; a caller
# maps every failure to exit 1.
required_open_pr() {
  current_open_pr \
    || die "no open PR for branch $(git symbolic-ref --quiet --short HEAD)"
}

# The PR counterpart of issue fetch.
cmd_pr_fetch() {
  [ $# -eq 1 ] || die "usage: orch.sh pr fetch <file>"
  local file="$1" pr
  pr="$(required_open_pr)" || exit 1
  fetch_into "$file" "the body of PR #$pr" \
    adapter_pr_body "$pr"
}

# The PR counterpart of issue comments (issue #418), so a standalone review
# pass reads earlier passes' declines. Exits as pr comment does: 1, writing
# nothing, only when the branch has no open PR, and 2 for everything else -
# GitHub unreadable, a usage error, a detached HEAD - with the file untouched.
cmd_pr_comments() {
  [ $# -eq 1 ] || die2 "usage: orch.sh pr comments <file>"
  local file="$1" pr
  pr="$(current_open_pr)" || return $?
  ( fetch_into "$file" "the comments of PR #$pr" \
      adapter_pr_comments "$pr" ) || exit 2
}

# The PR counterpart of issue update, with one guard issue update has no need
# for: the body's first line is the Closes/Refs line open_pr wrote, and a
# correction must never drop or change it, so a file that does not open with
# exactly that line is refused and the body left as it was.
cmd_pr_update() {
  [ $# -eq 1 ] || die "usage: orch.sh pr update <file>"
  local file="$1" pr current line err
  [ -f "$file" ] || die "body file not found: $file"
  pr="$(required_open_pr)" || exit 1
  capture current err adapter_pr_body "$pr" \
    || die "gh could not read the body of PR #$pr: $(gh_reason "$err")"
  line="$(printf '%s\n' "$current" | sed -n '1{s/\r$//;p;}')"
  grep -qE '^(Closes|Refs) #[0-9]+$' <<<"$line" \
    || die "PR #$pr's body does not open with a Closes/Refs #<issue> line, so there is no issue line to keep - refusing to replace it"
  [ "$(sed -n '1{s/\r$//;p;}' "$file")" = "$line" ] \
    || die "$file must open with PR #$pr's issue line, '$line' - refusing to replace the body"
  capture_err err adapter_pr_body_edit "$pr" "$file" \
    || die "gh could not replace the body of PR #$pr: $(gh_reason "$err")"
}

cmd_pr() {
  local op="${1:-}"
  shift || true
  case "$op" in
    open)    cmd_pr_open "$@" ;;
    publish) cmd_pr_publish "$@" ;;
    release) cmd_pr_release "$@" ;;
    comment) cmd_pr_comment "$@" ;;
    comments) cmd_pr_comments "$@" ;;
    fetch)   cmd_pr_fetch "$@" ;;
    update)  cmd_pr_update "$@" ;;
    draft)   cmd_pr_draft "$@" ;;
    ready)   cmd_pr_ready "$@" ;;
    *) die "unknown pr op: ${op:-<none>} (want open|publish|release|comment|comments|fetch|update|draft|ready)" ;;
  esac
}
