# shellcheck shell=bash
# The in-process half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call.
#
# The fake is a file store (#280). Its operations, under the #280 operation
# contract, parse no arguments: each keeps its state in the directory
# ORCH_GH_FAKE_STORE names, so what one orch.sh process wrote is there for the
# next one a test runs. orch_test.sh's fake_github creates the store, and its
# fake_* helpers seed and read it back. Its layout:
#
#   labels           one label per line, "<name><TAB><colour><TAB><description>";
#                    absent, the repo has no labels
#   issues/<n>/state  OPEN or CLOSED
#   issues/<n>/labels one label per line
#   issues/<n>/title  the title; absent, an empty one
#   issues/<n>/body   the body, byte for byte; absent, an empty one
#   issues/<n>/reason a closed issue's reason: completed or not planned
#   issues/<n>/pull   present, #n is a pull request, not an issue
#   issues/<n>/comments/<k>/{author,created,body}
#                     the issue's k-th comment
#   next_issue        the number the next created issue takes; absent, one
#                     past the highest the store holds
#   prs/<n>/state     OPEN, CLOSED or MERGED
#   prs/<n>/head, prs/<n>/base
#                     the head and base branch names
#   prs/<n>/title     the title
#   prs/<n>/body      the body, byte for byte; absent, an empty one
#   prs/<n>/draft     present, the PR is a draft
#   prs/<n>/head_oid  the head commit's SHA; absent, forty zeros
#   prs/<n>/commits   the PR's commit SHAs, one per line, oldest first;
#                     absent, the head alone
#   prs/<n>/comments/<k>/{author,created,body}
#                     the PR's k-th comment
#   next_pr           the number the next opened PR takes; absent, one past
#                     the highest issue or PR number the store holds
#   subs/<parent>     the parent's sub-issues, one number per line, in the
#                     order they were linked
#   blocked_by/<n>    the issues #n is blocked by, one number per line, in the
#                     order the edges were added
#   fail/<operation>  present, every call of that operation fails, non-zero,
#                     with the file's contents as gh's stderr
#   fail/<operation>.after
#                     a countdown: while above zero, each call of that
#                     operation succeeds despite fail/<operation> and counts it
#                     down
#   fail/<operation>.times
#                     a countdown: each failing call counts it down, and the
#                     call that reaches zero lifts fail/<operation> - a
#                     transient failure that clears on its own
#   lag/<operation>   a countdown: while above zero, each call of that
#                     operation answers stale and counts it down
#   lag/<operation>.after
#                     a countdown: while above zero, each call of that
#                     operation answers current, before its lag starts, and
#                     counts it down
#   lag/<operation>.stale
#                     the stale answer, where the operation takes one
#   default_branch    the answer to the repo's default branch, byte for byte;
#                     absent, gh cannot answer for the repo
#   checks/<n>/<scope>
#                     PR #n's scripted checks answers for a scope, required
#                     or all, one per line - green, failing, cancel,
#                     external, pending, none or boom - consumed one per
#                     call, the last repeating; absent, no checks
#   checks/<n>/<scope>.n
#                     how many calls the script has answered
#   protection/<branch>
#                     the check contexts classic protection requires on the
#                     branch, one per line; absent, the branch is unprotected
#   rules/<branch>    the type of each ruleset rule on the branch, one per
#                     line; absent, none
#   check_runs, statuses
#                     the refs (SHAs or branch names) that have a check run,
#                     or a commit status, one per line; absent, none do
#   unreadable_refs   refs whose check-run and status reads both fail
#   reruns            the Actions run ids rerun, one per line, in order
#   local_default     gh's own local default repo, as OWNER/REPO; absent,
#                     none is set
#   no_sub_issues     present, the sub-issues endpoint refuses every issue
#   offline           present, every operation fails with a connection error
#   noauth            present, gh is not authenticated: the auth status fails
#                     saying so, every other operation as unauthorised

fake_store() {
  printf '%s\n' "${ORCH_GH_FAKE_STORE:?the gh fake has no store - call fake_github}"
}

# fake_failing <operation>: true when fake_fail named the operation, with its
# stderr written, so an operation opens with `! fake_failing <op> || return 1`.
fake_failing() {
  local f n s
  s="$(fake_store)" || return 1
  if [ -f "$s/offline" ]; then
    echo "dial tcp: lookup api.github.com: no such host" >&2
    return 0
  fi
  if [ -f "$s/noauth" ]; then
    if [ "$1" = adapter_auth_status ]; then
      echo "You are not logged into any GitHub hosts. To log in, run: gh auth login" >&2
    else
      echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2
    fi
    return 0
  fi
  f="$s/fail/$1"
  [ -f "$f" ] || return 1
  if [ -f "$f.after" ]; then
    n="$(cat "$f.after")"
    if [ "${n:-0}" -gt 0 ]; then
      printf '%s\n' "$((n - 1))" >"$f.after"
      return 1
    fi
  fi
  if [ -f "$f.times" ]; then
    n="$(cat "$f.times")"
    if [ "${n:-0}" -le 1 ]; then
      cat "$f" >&2
      rm -f "$f" "$f.times"
      return 0
    fi
    printf '%s\n' "$((n - 1))" >"$f.times"
  fi
  cat "$f" >&2
}

# fake_lagging <operation>: true while the operation's lag countdown is above
# zero, counting it down by one, so an operation answers stale for exactly the
# calls fake_lag asked for.
fake_lagging() {
  local f n
  f="$(fake_store)/lag/$1" || return 1
  [ -f "$f" ] || return 1
  if [ -f "$f.after" ]; then
    n="$(cat "$f.after")"
    if [ "${n:-0}" -gt 0 ]; then
      printf '%s\n' "$((n - 1))" >"$f.after"
      return 1
    fi
  fi
  n="$(cat "$f")"
  [ "${n:-0}" -gt 0 ] || return 1
  printf '%s\n' "$((n - 1))" >"$f"
}

# fake_stale <operation>: the stale answer fake_lag gave the operation, or
# nothing where it gave none.
fake_stale() {
  cat "$(fake_store)/lag/$1.stale" 2>/dev/null || true
}

fake_label_exists() {
  local f
  f="$(fake_store)/labels"
  [ -f "$f" ] && cut -f1 "$f" | grep -qxF -- "$1"
}

fake_label_put() {
  local f
  f="$(fake_store)/labels"
  if [ -f "$f" ]; then
    awk -F '\t' -v n="$1" '$1 != n' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  fi
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$f"
}

# adapter_label_upsert <name> <colour> <description>: the label, created or
# rewritten, in the store.
adapter_label_upsert() {
  ! fake_failing adapter_label_upsert || return 1
  fake_label_put "$1" "$2" "$3"
}

# adapter_label_create <name> <colour> <description>: the label added to the
# store where it has none of that name; one it has fails the call, as gh does,
# and is left as it is.
adapter_label_create() {
  ! fake_failing adapter_label_create || return 1
  if fake_label_exists "$1"; then
    printf 'label with name "%s" already exists; use `--force` to update its color and description\n' "$1" >&2
    return 1
  fi
  fake_label_put "$1" "$2" "$3"
}

# adapter_labels <limit>: the stored label names, the first <limit> of them.
adapter_labels() {
  local f
  ! fake_failing adapter_labels || return 1
  f="$(fake_store)/labels"
  [ -f "$f" ] || return 0
  cut -f1 "$f" | head -n "$1"
}

# --- issue operations, on the store ---------------------------------------------

fake_issue_dir() { printf '%s/issues/%s\n' "$(fake_store)" "$1"; }

# fake_issue_known <n>: true where the store holds issue #n; otherwise gh's
# own error on stderr, as `gh issue view` gives for a number with no issue.
fake_issue_known() {
  [ -d "$(fake_issue_dir "$1")" ] && return 0
  printf 'GraphQL: Could not resolve to an issue or pull request with the number of %s. (repository.issue)\n' "$1" >&2
  return 1
}

fake_issue_labels() { cat "$(fake_issue_dir "$1")/labels" 2>/dev/null || true; }

# fake_comment_append <comments-dir> <author> <created-at> <body-file>: one
# comment appended to an issue's or PR's comments directory, numbered in order.
fake_comment_append() {
  local d="$1" k
  mkdir -p "$d"
  k=$(( $(find "$d" -mindepth 1 -maxdepth 1 | wc -l) + 1 ))
  mkdir "$d/$k"
  printf '%s\n' "$2" >"$d/$k/author"
  printf '%s\n' "$3" >"$d/$k/created"
  cat "$4" >"$d/$k/body"
}

# fake_comment_add <n> <author> <created-at> <body-file>: one comment appended
# to issue #n.
fake_comment_add() { fake_comment_append "$(fake_issue_dir "$1")/comments" "$2" "$3" "$4"; }

# fake_comments_print <comments-dir>: the directory's comments in COMMENTS_JQ's
# shape - each opened by its marker line, one blank line between, a newline
# after the last; nothing at all for none.
fake_comments_print() {
  local d="$1" k first=1
  [ -d "$d" ] || return 0
  for k in $(ls "$d" | sort -n); do
    [ "$first" = 1 ] || printf '\n\n'
    first=0
    printf '<!-- comment @%s %s -->\n' "$(cat "$d/$k/author")" "$(cat "$d/$k/created")"
    cat "$d/$k/body"
  done
  printf '\n'
}

# adapter_issue_body <n>: the stored body, then a newline, as gh's --jq .body
# prints it.
adapter_issue_body() {
  ! fake_failing adapter_issue_body || return 1
  fake_issue_known "$1" || return 1
  cat "$(fake_issue_dir "$1")/body" 2>/dev/null
  printf '\n'
}

# adapter_issue_comments <n>: the stored comments in COMMENTS_JQ's shape -
# each opened by its marker line, one blank line between, a newline after the
# last; nothing at all for none.
adapter_issue_comments() {
  ! fake_failing adapter_issue_comments || return 1
  fake_issue_known "$1" || return 1
  fake_comments_print "$(fake_issue_dir "$1")/comments"
}

# adapter_issue_json <n>: the stored issue as ISSUE_JSON_JQ's trimmed object -
# its number, title, body byte for byte, label names, and each comment's
# author, date and body.
adapter_issue_json() {
  ! fake_failing adapter_issue_json || return 1
  fake_issue_known "$1" || return 1
  local d k comments="[]" body
  d="$(fake_issue_dir "$1")"
  body="$d/body"
  [ -f "$body" ] || body=/dev/null
  if [ -d "$d/comments" ]; then
    for k in $(ls "$d/comments" | sort -n); do
      comments="$(jq -c --arg a "$(cat "$d/comments/$k/author")" \
        --arg c "$(cat "$d/comments/$k/created")" --rawfile b "$d/comments/$k/body" \
        '. + [{author: $a, createdAt: $c, body: $b}]' <<<"$comments")"
    done
  fi
  jq -cn --argjson n "$1" --arg t "$(cat "$d/title" 2>/dev/null)" \
    --rawfile b "$body" \
    --argjson l "$(fake_issue_labels "$1" | jq -R . | jq -cs .)" \
    --argjson c "$comments" \
    '{number: $n, title: $t, body: $b, labels: $l, comments: $c}'
}

# adapter_issue_state_labels <n>: the stored state, then its labels. Lagging
# (fake_lag), it answers the stale answer fake_lag was given, or nothing.
adapter_issue_state_labels() {
  ! fake_failing adapter_issue_state_labels || return 1
  if fake_lagging adapter_issue_state_labels; then
    fake_stale adapter_issue_state_labels
    return 0
  fi
  fake_issue_known "$1" || return 1
  cat "$(fake_issue_dir "$1")/state"
  fake_issue_labels "$1"
}

# adapter_issue_title_labels <n>: the stored title, then its labels. Lagging
# (fake_lag), it answers the stale answer fake_lag was given, or an empty
# title and no labels.
adapter_issue_title_labels() {
  ! fake_failing adapter_issue_title_labels || return 1
  if fake_lagging adapter_issue_title_labels; then
    fake_stale adapter_issue_title_labels
    return 0
  fi
  fake_issue_known "$1" || return 1
  printf '%s\n' "$(cat "$(fake_issue_dir "$1")/title" 2>/dev/null)"
  fake_issue_labels "$1"
}

# adapter_issue_state <n>: PULL for a PR the store holds or a number fake_pull
# seeded, the stored state otherwise.
adapter_issue_state() {
  ! fake_failing adapter_issue_state || return 1
  if [ -d "$(fake_store)/prs/$1" ]; then printf 'PULL\n'; return 0; fi
  fake_issue_known "$1" || return 1
  if [ -f "$(fake_issue_dir "$1")/pull" ]; then printf 'PULL\n'; return 0; fi
  cat "$(fake_issue_dir "$1")/state"
}

# adapter_issues_labelled <label>...: the open issues in the store carrying
# every label named, in number order - the first ISSUE_LIST_LIMIT of them, as
# gh's --limit cuts the list.
adapter_issues_labelled() {
  local d n l keep
  ! fake_failing adapter_issues_labelled || return 1
  for d in "$(fake_store)"/issues/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    [ ! -f "$d/pull" ] && [ "$(cat "$d/state")" = OPEN ] || continue
    keep=1
    for l in "$@"; do grep -qxF -- "$l" "$d/labels" 2>/dev/null || keep=0; done
    [ "$keep" = 1 ] && printf '%s\n' "$n"
  done | sort -n | head -n "$ISSUE_LIST_LIMIT"
}

# fake_next_number: one past the highest issue or PR number the store holds,
# the two sharing GitHub's numbering - where a new issue or PR is numbered
# when no next number was set.
fake_next_number() {
  local n
  # shellcheck disable=SC2010 # the store names its files by issue number, so no name needs a glob-safe walk
  n="$(ls "$(fake_store)/issues" "$(fake_store)/prs" 2>/dev/null | grep -x '[0-9][0-9]*' | sort -n | tail -n 1)"
  printf '%s\n' "$(( ${n:-0} + 1 ))"
}

# adapter_issue_create <title> <body-file> [label...]: a new open issue in the
# store, numbered as fake_next_issue set (default one past the highest issue
# or PR number the store holds), its number printed.
adapter_issue_create() {
  local title="$1" body="$2" n d
  shift 2
  ! fake_failing adapter_issue_create || return 1
  n="$(cat "$(fake_store)/next_issue" 2>/dev/null)"
  [ -n "$n" ] || n="$(fake_next_number)"
  printf '%s\n' "$((n + 1))" >"$(fake_store)/next_issue"
  d="$(fake_issue_dir "$n")"
  mkdir -p "$d"
  printf 'OPEN\n' >"$d/state"
  printf '%s\n' "$title" >"$d/title"
  cat "$body" >"$d/body"
  : >"$d/labels"
  [ $# -eq 0 ] || printf '%s\n' "$@" >"$d/labels"
  printf '%s\n' "$n"
}

# adapter_issue_body_edit <n> <file>: the file's contents as the stored body.
adapter_issue_body_edit() {
  ! fake_failing adapter_issue_body_edit || return 1
  fake_issue_known "$1" || return 1
  cat "$2" >"$(fake_issue_dir "$1")/body"
}

# adapter_issue_comment <n> <file>: the file's contents appended as a comment,
# by fake-gh.
adapter_issue_comment() {
  ! fake_failing adapter_issue_comment || return 1
  fake_issue_known "$1" || return 1
  fake_comment_add "$1" fake-gh 2026-01-01T00:00:00Z "$2"
}

# adapter_issue_relabel <n> <add> <remove>: the comma-separated labels removed
# from, then added to, the stored labels, each once.
adapter_issue_relabel() {
  local f l add=() remove=()
  ! fake_failing adapter_issue_relabel || return 1
  fake_issue_known "$1" || return 1
  f="$(fake_issue_dir "$1")/labels"
  [ -z "$2" ] || IFS=, read -r -a add <<<"$2"
  [ -z "$3" ] || IFS=, read -r -a remove <<<"$3"
  for l in ${remove[@]+"${remove[@]}"}; do
    { grep -vxF -- "$l" "$f" || true; } >"$f.tmp"; mv "$f.tmp" "$f"
  done
  for l in ${add[@]+"${add[@]}"}; do
    grep -qxF -- "$l" "$f" || printf '%s\n' "$l" >>"$f"
  done
}

# adapter_issue_close <n> [reason] [comment]: the stored issue CLOSED, its
# reason (completed where none is given, as GitHub defaults) in reason, and
# the comment, where given, appended by fake-gh.
adapter_issue_close() {
  local d c
  ! fake_failing adapter_issue_close || return 1
  fake_issue_known "$1" || return 1
  d="$(fake_issue_dir "$1")"
  if [ -n "${3:-}" ]; then
    c="$(mktemp)"
    printf '%s' "$3" >"$c"
    fake_comment_add "$1" fake-gh 2026-01-01T00:00:00Z "$c"
    rm -f "$c"
  fi
  printf 'CLOSED\n' >"$d/state"
  printf '%s\n' "${2:-completed}" >"$d/reason"
}

# adapter_issue_reopen <n>: the stored issue OPEN again.
adapter_issue_reopen() {
  ! fake_failing adapter_issue_reopen || return 1
  fake_issue_known "$1" || return 1
  printf 'OPEN\n' >"$(fake_issue_dir "$1")/state"
  rm -f "$(fake_issue_dir "$1")/reason"
}

# --- pr operations, on the store ------------------------------------------------

fake_pr_dir() { printf '%s/prs/%s\n' "$(fake_store)" "$1"; }

# fake_pr_known <n>: true where the store holds PR #n; otherwise gh's own
# error on stderr, as `gh pr view` gives for a number with no PR.
fake_pr_known() {
  [ -d "$(fake_pr_dir "$1")" ] && return 0
  printf 'GraphQL: Could not resolve to a PullRequest with the number of %s. (repository.pullRequest)\n' "$1" >&2
  return 1
}

# adapter_pr_create <base> <head> <title> <body-file> [draft]: a new open PR in
# the store, numbered as next_pr set (default one past the highest issue or PR
# number the store holds, the two sharing GitHub's numbering), its number
# printed.
adapter_pr_create() {
  local n d
  ! fake_failing adapter_pr_create || return 1
  n="$(cat "$(fake_store)/next_pr" 2>/dev/null)"
  [ -n "$n" ] || n="$(fake_next_number)"
  printf '%s\n' "$((n + 1))" >"$(fake_store)/next_pr"
  d="$(fake_pr_dir "$n")"
  mkdir -p "$d"
  printf 'OPEN\n' >"$d/state"
  printf '%s\n' "$1" >"$d/base"
  printf '%s\n' "$2" >"$d/head"
  printf '%s\n' "$3" >"$d/title"
  cat "$4" >"$d/body"
  [ "${5:-false}" != true ] || : >"$d/draft"
  printf '%s\n' "$n"
}

# adapter_pr_body <n>: the stored body, then a newline, as gh's --jq .body
# prints it.
adapter_pr_body() {
  ! fake_failing adapter_pr_body || return 1
  fake_pr_known "$1" || return 1
  cat "$(fake_pr_dir "$1")/body" 2>/dev/null
  printf '\n'
}

# adapter_pr_comments <n>: the stored comments in COMMENTS_JQ's shape, as
# adapter_issue_comments prints an issue's.
adapter_pr_comments() {
  ! fake_failing adapter_pr_comments || return 1
  fake_pr_known "$1" || return 1
  fake_comments_print "$(fake_pr_dir "$1")/comments"
}

# adapter_pr_refs <n>: the stored head SHA (default forty zeros, a SHA no
# reflog or object store holds), head branch and base branch, then the stored
# commits (default the head alone, a single-commit PR).
adapter_pr_refs() {
  local d oid
  ! fake_failing adapter_pr_refs || return 1
  fake_pr_known "$1" || return 1
  d="$(fake_pr_dir "$1")"
  oid="$(cat "$d/head_oid" 2>/dev/null)"
  oid="${oid:-0000000000000000000000000000000000000000}"
  printf '%s\n' "$oid"
  cat "$d/head" "$d/base"
  if [ -f "$d/commits" ]; then cat "$d/commits"; else printf '%s\n' "$oid"; fi
}

# adapter_pr_ready <n>: the stored PR no longer a draft.
adapter_pr_ready() {
  ! fake_failing adapter_pr_ready || return 1
  fake_pr_known "$1" || return 1
  rm -f "$(fake_pr_dir "$1")/draft"
}

# adapter_prs_open <head> [base]: the open PRs in the store from the head
# branch, into the base where one is named, newest first.
adapter_prs_open() {
  local d
  ! fake_failing adapter_prs_open || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = OPEN ] && [ "$(cat "$d/head")" = "$1" ] || continue
    [ -z "${2:-}" ] || [ "$(cat "$d/base")" = "$2" ] || continue
    basename "$d"
  done | sort -rn
}

# adapter_prs_merged <head> <base>: the merged PRs in the store from the head
# branch into the base, newest first.
adapter_prs_merged() {
  local d
  ! fake_failing adapter_prs_merged || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = MERGED ] && [ "$(cat "$d/head")" = "$1" ] \
      && [ "$(cat "$d/base")" = "$2" ] || continue
    basename "$d"
  done | sort -rn
}

# adapter_prs_merged_bodies <base>: the stored body of every merged PR into the
# base, each followed by a newline, newest first.
adapter_prs_merged_bodies() {
  local n d
  ! fake_failing adapter_prs_merged_bodies || return 1
  for n in $(ls "$(fake_store)/prs" 2>/dev/null | sort -rn); do
    d="$(fake_pr_dir "$n")"
    [ "$(cat "$d/state")" = MERGED ] && [ "$(cat "$d/base")" = "$1" ] || continue
    cat "$d/body" 2>/dev/null
    printf '\n'
  done
}

# adapter_pr_close <n> <comment>: the stored PR CLOSED, the comment appended
# by fake-gh.
adapter_pr_close() {
  local c
  ! fake_failing adapter_pr_close || return 1
  fake_pr_known "$1" || return 1
  c="$(mktemp)"
  printf '%s' "$2" >"$c"
  fake_comment_append "$(fake_pr_dir "$1")/comments" fake-gh 2026-01-01T00:00:00Z "$c"
  rm -f "$c"
  printf 'CLOSED\n' >"$(fake_pr_dir "$1")/state"
}

# adapter_pr_comment <n> <file>: the file's contents appended as a comment, by
# fake-gh.
adapter_pr_comment() {
  ! fake_failing adapter_pr_comment || return 1
  fake_pr_known "$1" || return 1
  fake_comment_append "$(fake_pr_dir "$1")/comments" fake-gh 2026-01-01T00:00:00Z "$2"
}

# adapter_pr_body_edit <n> <file>: the file's contents as the stored body.
adapter_pr_body_edit() {
  ! fake_failing adapter_pr_body_edit || return 1
  fake_pr_known "$1" || return 1
  cat "$2" >"$(fake_pr_dir "$1")/body"
}

# adapter_pr_state_draft <n>: the stored state, then true for a draft, false
# otherwise.
adapter_pr_state_draft() {
  ! fake_failing adapter_pr_state_draft || return 1
  fake_pr_known "$1" || return 1
  cat "$(fake_pr_dir "$1")/state"
  if [ -f "$(fake_pr_dir "$1")/draft" ]; then echo true; else echo false; fi
}

# --- sub-issue and dependency operations, on the store --------------------------

# fake_open_blockers <n>: how many of #n's stored blockers are still open.
fake_open_blockers() {
  local b c=0
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    [ "$(cat "$(fake_issue_dir "$b")/state" 2>/dev/null)" = OPEN ] && c=$((c + 1))
  done < <(cat "$(fake_store)/blocked_by/$1" 2>/dev/null)
  printf '%s\n' "$c"
}

# fake_lines_drop <file> <line>: the file without that line, where it exists.
fake_lines_drop() {
  [ -f "$1" ] || return 0
  { grep -vxF -- "$2" "$1" || true; } >"$1.tmp"
  mv "$1.tmp" "$1"
}

# adapter_sub_issues <parent>: the stored sub-issues, in link order, each with
# its stored state and its count of open blockers. Lagging (fake_lag), it
# answers the stale answer fake_lag was given, or none.
adapter_sub_issues() {
  local n
  ! fake_failing adapter_sub_issues || return 1
  if fake_lagging adapter_sub_issues; then
    fake_stale adapter_sub_issues
    return 0
  fi
  fake_issue_known "$1" || return 1
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    printf '%s\t%s\t%s\n' "$n" "$(cat "$(fake_issue_dir "$n")/state")" "$(fake_open_blockers "$n")"
  done < <(cat "$(fake_store)/subs/$1" 2>/dev/null)
}

# adapter_sub_issue_link <parent> <child>: the child appended to the parent's
# stored sub-issues, once.
adapter_sub_issue_link() {
  local f
  ! fake_failing adapter_sub_issue_link || return 1
  fake_issue_known "$1" && fake_issue_known "$2" || return 1
  mkdir -p "$(fake_store)/subs"
  f="$(fake_store)/subs/$1"
  grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >>"$f"
}

# adapter_sub_issue_unlink <parent> <child>: the child dropped from the
# parent's stored sub-issues.
adapter_sub_issue_unlink() {
  ! fake_failing adapter_sub_issue_unlink || return 1
  fake_issue_known "$1" && fake_issue_known "$2" || return 1
  fake_lines_drop "$(fake_store)/subs/$1" "$2"
}

# adapter_issue_parent <n>: the parent whose stored sub-issues hold #n, or
# nothing.
adapter_issue_parent() {
  local f
  ! fake_failing adapter_issue_parent || return 1
  fake_issue_known "$1" || return 1
  for f in "$(fake_store)"/subs/*; do
    [ -f "$f" ] || continue
    if grep -qxF -- "$1" "$f"; then basename "$f"; return 0; fi
  done
}

# adapter_blockers <n>: #n's stored blockers, in the order they were added.
# Lagging (fake_lag), it answers the stale answer fake_lag was given, or none.
adapter_blockers() {
  ! fake_failing adapter_blockers || return 1
  if fake_lagging adapter_blockers; then
    fake_stale adapter_blockers
    return 0
  fi
  fake_issue_known "$1" || return 1
  cat "$(fake_store)/blocked_by/$1" 2>/dev/null || true
}

# adapter_blocker_add <n> <blocker>: the blocker appended to #n's stored
# blockers, once - GitHub stores an edge once however often it is asked for.
adapter_blocker_add() {
  local f
  ! fake_failing adapter_blocker_add || return 1
  fake_issue_known "$1" && fake_issue_known "$2" || return 1
  mkdir -p "$(fake_store)/blocked_by"
  f="$(fake_store)/blocked_by/$1"
  grep -qxF -- "$2" "$f" 2>/dev/null || printf '%s\n' "$2" >>"$f"
}

# adapter_blocker_remove <n> <blocker>: the blocker dropped from #n's stored
# blockers.
adapter_blocker_remove() {
  ! fake_failing adapter_blocker_remove || return 1
  fake_issue_known "$1" && fake_issue_known "$2" || return 1
  fake_lines_drop "$(fake_store)/blocked_by/$1" "$2"
}

# adapter_sub_issues_supported: nothing where the store holds no issue; no
# where no_sub_issues is present; yes otherwise.
adapter_sub_issues_supported() {
  ! fake_failing adapter_sub_issues_supported || return 1
  [ -n "$(ls "$(fake_store)/issues" 2>/dev/null)" ] || return 0
  if [ -f "$(fake_store)/no_sub_issues" ]; then echo no; else echo yes; fi
}

# --- repo operations, on the store ----------------------------------------------

# adapter_repo_default_branch <repo>: the stored default_branch answer, as is.
# A store with none fails it, as gh does for a repo it cannot resolve. Failing
# (fake_fail), it still prints the stored answer first, as a tool manager's
# shim around a failed gh can (#465).
adapter_repo_default_branch() {
  local f
  f="$(fake_store)/default_branch"
  [ ! -f "$f" ] || cat "$f"
  ! fake_failing adapter_repo_default_branch || return 1
  [ -f "$f" ] || { printf "GraphQL: Could not resolve to a Repository with the name '%s'. (repository)\n" "$1" >&2; return 1; }
}

# adapter_repo_local_default: the stored local_default; nothing where none
# is set.
adapter_repo_local_default() {
  ! fake_failing adapter_repo_local_default || return 1
  cat "$(fake_store)/local_default" 2>/dev/null || true
}

# adapter_auth_status: gh's report of a login - failing, as every operation
# does, under offline or noauth.
adapter_auth_status() {
  ! fake_failing adapter_auth_status || return 1
  echo "Logged in to github.com account fake-gh"
}

# --- ci operations, on the store ------------------------------------------------

# fake_checks_answer <answer>: the checks one scripted answer stands for, in
# adapter_pr_checks's TSV shape - or, for boom, a connection error.
fake_checks_answer() {
  local runs=https://github.com/acme/widgets/actions/runs
  case "$1" in
    green)    printf 'pass\tbuild\t%s/1/job/1\n' "$runs" ;;
    failing)  printf 'fail\tbuild\t%s/4242/job/77\npass\tlint\t%s/1/job/1\n' "$runs" "$runs" ;;
    cancel)   printf 'cancel\tbuild\t%s/5150/job/9\n' "$runs" ;;
    # A failing check that is no Actions run - a commit status from an outside
    # CI - listed first, ahead of a failing Actions run.
    external) printf 'pass\tlint\t%s/1/job/1\nfail\text-ci\thttps://ci.example.com/build/9\nfail\tbuild\t%s/4242/job/77\n' "$runs" "$runs" ;;
    # A failing check whose Actions link carries no numeric run id.
    badrunid) printf 'fail\tbuild\t%s/12abc\n' "$runs" ;;
    pending)  printf 'pending\tbuild\t\n' ;;
    # The fake records no head branch, so gh's no-checks line names a fixed one.
    none)     fake_no_checks ;;
    # gh's empty list, `[]`: nothing on stdout, nothing on stderr, exit 0.
    empty)    ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    # Without this arm a mistyped answer prints nothing and succeeds, which
    # ci_probe reads as a repo with no checks - a test that passes while
    # asserting nothing.
    *)        echo "gh fake: no checks answer named '$1'" >&2; return 99 ;;
  esac
}

# fake_no_checks: gh's "no checks" answer - nothing on stdout, its line on
# stderr, exit 0 - as adapter_pr_checks passes it on.
fake_no_checks() { echo "no checks reported on the 'topic' branch" >&2; }

# adapter_pr_checks <n> <required|all>: the next answer of the script
# fake_checks seeded for the PR and scope - one per call, the last repeating
# once the script runs out. An unseeded scope has no checks.
adapter_pr_checks() {
  local d f i answer
  ! fake_failing adapter_pr_checks || return 1
  d="$(fake_store)/checks/$1"
  f="$d/$2"
  [ -f "$f" ] || { fake_no_checks; return 0; }
  i=$(( $(cat "$f.n" 2>/dev/null || echo 0) + 1 ))
  printf '%s\n' "$i" >"$f.n"
  answer="$(sed -n "${i}p" "$f")"
  [ -n "$answer" ] || answer="$(tail -n 1 "$f")"
  fake_checks_answer "$answer"
}

# fake_ref_unreadable <ref>: true, with a server error on stderr, where
# fake_unreadable_ref named the ref, so both commit reads of it fail.
fake_ref_unreadable() {
  grep -qxF -- "$1" "$(fake_store)/unreadable_refs" 2>/dev/null || return 1
  echo "gh: Server Error (HTTP 502)" >&2
}

# adapter_branch_required_checks <branch>: the stored contexts the branch
# requires; nothing for an unprotected branch.
adapter_branch_required_checks() {
  ! fake_failing adapter_branch_required_checks || return 1
  cat "$(fake_store)/protection/$1" 2>/dev/null || true
}

# adapter_branch_rules <branch>: the stored rule types the branch's rulesets
# apply; nothing for none.
adapter_branch_rules() {
  ! fake_failing adapter_branch_rules || return 1
  cat "$(fake_store)/rules/$1" 2>/dev/null || true
}

# adapter_commit_has_check_runs <ref>: yes where the ref is listed in
# check_runs, no otherwise.
adapter_commit_has_check_runs() {
  ! fake_failing adapter_commit_has_check_runs || return 1
  ! fake_ref_unreadable "$1" || return 1
  if grep -qxF -- "$1" "$(fake_store)/check_runs" 2>/dev/null; then echo yes; else echo no; fi
}

# adapter_commit_has_statuses <ref>: yes where the ref is listed in statuses,
# no otherwise.
adapter_commit_has_statuses() {
  ! fake_failing adapter_commit_has_statuses || return 1
  ! fake_ref_unreadable "$1" || return 1
  if grep -qxF -- "$1" "$(fake_store)/statuses" 2>/dev/null; then echo yes; else echo no; fi
}

# adapter_run_rerun <run>: the run appended to reruns.
adapter_run_rerun() {
  ! fake_failing adapter_run_rerun || return 1
  printf '%s\n' "$1" >>"$(fake_store)/reruns"
}
