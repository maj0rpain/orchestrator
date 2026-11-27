# shellcheck shell=bash
# The in-process half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call.
#
# The fake is a file store (#280). Its operations, under the #280 operation
# contract, parse none of gh's flags, only each operation's own arguments - the
# grammar the real ones take (#664), options parsed before fake_failing so a
# bad call exits 2 even where a failure is seeded. Each keeps its state in the
# directory ORCH_GH_FAKE_STORE names, so what one orch.sh process wrote is there
# for the next one a test runs. orch_test.sh's fake_github creates the store,
# and its fake_* helpers seed and read it back. Its layout:
#
#   labels           one label per line,
#                    "<name><TAB><colour><TAB><description>";
#                    absent, the repo has no labels
#   issues/<n>/state  OPEN or CLOSED
#   issues/<n>/labels one label per line
#   issues/<n>/title  the title; absent, an empty one
#   issues/<n>/body   the body, byte for byte; absent, an empty one
#   issues/<n>/reason a closed issue's reason: completed, not planned or
#                     duplicate
#   issues/<n>/duplicate_of
#                     the issue a duplicate close named; absent, none
#   issues/<n>/pull   present, #n is a pull request, not an issue
#   issues/<n>/author, issues/<n>/association, issues/<n>/editor,
#   issues/<n>/renamer
#                     the issue author's login and authorAssociation, the
#                     login of the body's last editor and of the title's
#                     latest renamer; absent, the author is fake-gh as OWNER
#                     and the body is never edited nor the title renamed
#   issues/<n>/comments/<k>/{author,created,body}
#                     the issue's k-th comment
#   next_issue        the number the next created issue takes; absent, one
#                     past the highest the store holds
#   issues/<n>/created_at
#                     the UTC timestamp the issue was created at; absent, the
#                     epoch
#   prs/<n>/state     OPEN, CLOSED or MERGED
#   prs/<n>/head, prs/<n>/base
#                     the head and base branch names
#   prs/<n>/title     the title
#   prs/<n>/body      the body, byte for byte; absent, an empty one
#   prs/<n>/mergeable MERGEABLE, CONFLICTING or UNKNOWN; absent, UNKNOWN
#   prs/<n>/merged_at the UTC timestamp the PR merged at; absent, the epoch
#   prs/<n>/closing   the issue numbers the PR's closingIssuesReferences lists,
#                     one per line; absent, none
#   prs/<n>/draft     present, the PR is a draft
#   prs/<n>/labels    the PR's label names, one per line
#   pr_label_drops    label names, one per line, a PR create never stores -
#                     as a gh whose label mutation did not land
#   prs/<n>/head_oid  the head commit's SHA; absent, forty zeros; empty, as
#                     GitHub's null head
#   prs/<n>/url       the PR's URL; absent, https://github.com/o/r/pull/<n>
#   prs/<n>/commits   the PR's commit SHAs, one per line, oldest first;
#                     absent, the head alone, or none when the head is empty
#   prs/<n>/diff      the PR's diff, byte for byte; absent, an empty one
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
#   comment_reads     one line per issue-comments read the Python fake made
#   default_branch    the answer to the repo's default branch, byte for byte;
#                     absent, gh cannot answer for the repo
#   checks/<n>/<scope>
#                     PR #n's scripted checks answers for a scope, required
#                     or all, one per line - green, failing, cancel,
#                     external, pending, none or boom - consumed one per
#                     call, the last repeating; absent, no checks
#   checks/<n>/<scope>.n
#                     how many calls the script has answered
#                     (this cursor, comment_reads, prs/<n>/evidence_reads and
#                     checks/<n>/reads are read-side bookkeeping:
#                     fake_snapshot in gh.sh's test preamble leaves them out)
#   checks/<n>/reads  one line per read of PR #n's checks, scripted scope or
#                     not; rescripting a scope never resets it
#   job_logs/<job>    the failed-step log of Actions job <job>; absent, the
#                     log cannot be read
#   protection/<branch>
#                     the check contexts classic protection requires on the
#                     branch, one per line; absent, the branch is unprotected
#   rules/<branch>    the type of each ruleset rule on the branch, one per
#                     line; absent, none
#   check_runs, statuses
#                     the refs (SHAs or branch names) that have a check run,
#                     or a commit status, one per line; absent, none do
#   prs/<n>/evidence_reads
#                     one line per adapter_pr_commits_checked read of PR #n
#   prs/<n>/evidence_raw
#                     present, that read's whole answer, printed as stored
#   prs/<n>/no_base_ref
#                     present, that read's base tip answer is empty
#   reruns            the Actions run ids rerun, one per line, in order
#   claims/<issue>    the issue's claim, one TSV line
#                     "<issue><TAB><host><TAB><pid><TAB><phase><TAB><started>";
#                     absent, the issue is unclaimed
#   local_default     gh's own local default repo, as OWNER/REPO; absent,
#                     none is set
#   no_dependency_summary
#                     issue numbers, one per line, whose dependency summary
#                     GitHub leaves off: adapter_issue_open_blockers answers
#                     nothing for them
#   no_sub_issues     present, the sub-issues endpoint refuses every issue
#   no_comment_url    present, the Python fake's issue comment URL post
#                     answers no URL
#   offline           present, every operation fails with a connection error
#   ratelimit         present, every operation but the rate_limit read fails
#                     as a GitHub API rate limit, with the file's contents as
#                     gh's stderr
#   quota             the rate_limit read's answer, one
#                     "<pool><TAB><remaining><TAB><limit><TAB><reset>" line
#                     per pool; absent, full pools
#   noauth            present, gh is not authenticated: every operation fails
#                     as unauthorised (the Python fake's auth status read
#                     fails saying so)

fake_store() {
  printf '%s\n' "${ORCH_GH_FAKE_STORE:?the gh fake has no store - call fake_github}"
}

# fake_need_store: true with the store's path in ORCH_GH_FAKE_STORE; else the
# no-store message on stderr and false. The listed functions use that path
# directly, where fake_store would cost them a command substitution.
fake_need_store() {
  [ -n "${ORCH_GH_FAKE_STORE:-}" ] && return 0
  echo "ORCH_GH_FAKE_STORE: the gh fake has no store - call fake_github" >&2
  return 1
}

# fake_slurp <file>: the file's contents, less trailing newlines as "$(cat)"
# leaves them, in the variable fake_slurped, read in bash; false, with it empty,
# where the file is unreadable.
fake_slurp() {
  fake_slurped=""
  [ -r "$1" ] || return 1
  IFS= read -r -d '' fake_slurped <"$1" || true
  while [[ "$fake_slurped" == *$'\n' ]]; do fake_slurped="${fake_slurped%$'\n'}"; done
  return 0
}

# fake_read_state <file>: the file's first line, in the variable fake_state,
# read in bash; false, with it empty, where the file is missing or empty.
fake_read_state() {
  fake_state=""
  { IFS= read -r fake_state <"$1" || [ -n "$fake_state" ]; } 2>/dev/null
}

# fake_read_lines <file>: the file's lines, in the array fake_lines, read in
# bash; false, with it empty, where the file is unreadable.
fake_read_lines() {
  local l
  fake_lines=()
  [ -r "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    fake_lines+=("$l")
  done <"$1"
  return 0
}

# fake_print_lines <file>: the file's lines on stdout, read in bash; none where
# it is unreadable.
fake_print_lines() {
  local l
  fake_read_lines "$1" || return 0
  for l in ${fake_lines[@]+"${fake_lines[@]}"}; do printf '%s\n' "$l"; done
}

# fake_has_line <file> <line>: true where the file holds that whole line,
# matched literally; read in bash.
fake_has_line() {
  local l
  [ -r "$1" ] || return 1
  while IFS= read -r l || [ -n "$l" ]; do
    [ "$l" = "$2" ] && return 0
  done <"$1"
  return 1
}

# fake_entries_sorted <dir>: the names of the directory's entries, in the
# array fake_entries, in numeric order (as sort -n puts them); a glob lists
# them and an insertion sort orders them, so no command runs. Names are numbers.
fake_entries_sorted() {
  local e i t
  fake_entries=()
  for e in "$1"/*; do
    [ -e "$e" ] || continue
    i=${#fake_entries[@]}
    fake_entries[i]="${e##*/}"
    while [ "$i" -gt 0 ] && [ "$((10#${fake_entries[i-1]}))" -gt "$((10#${fake_entries[i]}))" ]; do
      t="${fake_entries[i-1]}"; fake_entries[i-1]="${fake_entries[i]}"; fake_entries[i]="$t"
      i=$((i - 1))
    done
  done
}

# fake_countdown <file>: true while the count the file holds is above zero,
# counting it down by one; false where the file is absent or at zero.
fake_countdown() {
  local n
  [ -f "$1" ] || return 1
  n="$(cat "$1")"
  [ "${n:-0}" -gt 0 ] || return 1
  printf '%s\n' "$((n - 1))" >"$1"
}

# fake_failing <operation>: false at once, without a subshell, when nothing is
# seeded for the operation (no hold, rate limit, offline or no-auth marker, no
# failure file); else fake_failing_raw, with a failure that is a GitHub
# API rate limit going through the production gh_limit_retry, as the guard's
# own failed calls do (sourced alone, without gh.sh, it is fake_failing_raw's
# own answer): a secondary limit is waited out and retried once, except in a
# call made under GH_LIMIT_COMPOUND (a compound write), which gives up at
# once; and a
# limit given up on leaves the handler's distinct message on stderr in place of
# gh's own. Any other failure is written as it is.
fake_failing() {
  local fs
  fake_need_store || return 1
  fs="$ORCH_GH_FAKE_STORE"
  if [ ! -p "$fs/hold/$1" ] && [ ! -f "$fs/ratelimit" ] && [ ! -f "$fs/offline" ] \
    && [ ! -f "$fs/noauth" ] && [ ! -f "$fs/fail/$1" ]; then
    return 1
  fi
  declare -F gh_limit_retry >/dev/null || { fake_failing_raw "$1"; return; }
  ! gh_limit_retry fake_failing_inverted "$1"
}

# fake_failing_inverted <operation>: fake_failing_raw with its status inverted,
# so a seeded failure is a failed call to gh_limit_retry.
fake_failing_inverted() { ! fake_failing_raw "$1"; }

# fake_failing_raw <operation>: true when fake_fail named the operation, with
# its stderr written. An operation calls `! fake_failing <op> || return 1`
# once it has parsed its own arguments, so a bad call exits 2 even with a
# failure seeded.
fake_failing_raw() {
  local f n s
  s="$(fake_store)" || return 1
  # a fifo at hold/<operation> parks the call: it writes the calling orch.sh's
  # pid to the "held" file and waits until something is written to the fifo
  if [ -p "$s/hold/$1" ]; then
    printf '%s\n' "$$" >"$s/held"
    read -r _ <"$s/hold/$1" || true
  fi
  if [ -f "$s/ratelimit" ] && [ "$1" != adapter_rate_limit ]; then
    cat "$s/ratelimit" >&2
    return 0
  fi
  if [ -f "$s/offline" ]; then
    echo "dial tcp: lookup api.github.com: no such host" >&2
    return 0
  fi
  if [ -f "$s/noauth" ]; then
    echo "HTTP 401: Bad credentials (https://api.github.com/graphql)" >&2
    return 0
  fi
  f="$s/fail/$1"
  [ -f "$f" ] || return 1
  ! fake_countdown "$f.after" || return 1
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
  local f
  f="$(fake_store)/lag/$1" || return 1
  [ -f "$f" ] || return 1
  ! fake_countdown "$f.after" || return 1
  fake_countdown "$f"
}

# fake_stale <operation>: the stale answer fake_lag gave the operation, or
# nothing where it gave none.
fake_stale() {
  cat "$(fake_store)/lag/$1.stale" 2>/dev/null || true
}

# fake_label_canon <name>: GitHub's casing rule - the name as the repo's label
# store holds it where it holds it in any casing, else the name as given.
fake_label_canon() {
  local f found=""
  f="$(fake_store)/labels"
  [ ! -f "$f" ] || found="$(awk -F '\t' -v n="$1" '!d && tolower($1) == tolower(n) { print $1; d = 1 }' "$f")"
  printf '%s\n' "${found:-$1}"
}

# fake_labels_add <file> <name>: the label appended to the label file in the
# repo's casing, unless the file already carries it in any casing.
fake_labels_add() {
  grep -qxiF -- "$2" "$1" 2>/dev/null || fake_label_canon "$2" >>"$1"
}

# fake_label_put <name> <colour> <description>: the label stored; one the store
# holds in any casing keeps its name and has its colour and description
# rewritten.
fake_label_put() {
  local f name
  f="$(fake_store)/labels"
  name="$(fake_label_canon "$1")"
  if [ -f "$f" ]; then
    awk -F '\t' -v n="$name" '$1 != n' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
  fi
  printf '%s\t%s\t%s\n' "$name" "$2" "$3" >>"$f"
}

# adapter_label_upsert <name> <colour> <description>: the label, created or
# rewritten, in the store.
adapter_label_upsert() {
  ! fake_failing adapter_label_upsert || return 1
  fake_label_put "$1" "$2" "$3"
}

# adapter_labels_detail <limit>: the stored labels as name, colour and
# description, tab-separated, the first <limit> of them.
adapter_labels_detail() {
  local f
  ! fake_failing adapter_labels_detail || return 1
  f="$(fake_store)/labels"
  [ -f "$f" ] || return 0
  awk -F '\t' -v OFS='\t' -v n="$1" 'NR<=n { print $1, $2, $3 }' "$f"
}

# adapter_rate_limit: the stored quota, one "<pool><TAB><remaining><TAB><limit>
# <TAB><reset>" line per pool; absent, both pools full with a reset an hour on,
# the clock read once. The store's path is used directly.
adapter_rate_limit() {
  local f reset
  ! fake_failing adapter_rate_limit || return 1
  fake_need_store || return 1
  f="$ORCH_GH_FAKE_STORE/quota"
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  reset="$(($(date +%s) + 3600))"
  printf '%s\t5000\t5000\t%s\n' core "$reset" graphql "$reset"
}

# --- issue operations, on the store -------------------------------------------

fake_issue_dir() { printf '%s/issues/%s\n' "$(fake_store)" "$1"; }

# fake_issue_known <n>: true where the store holds issue #n; otherwise gh's
# own error on stderr, as `gh issue view` gives for a number with no issue.
fake_issue_known() {
  [ -d "$(fake_issue_dir "$1")" ] && return 0
  printf 'GraphQL: Could not resolve to an issue or pull request with the number of %s. (repository.issue)\n' "$1" >&2
  return 1
}

# fake_issue_labels <n>: issue #n's stored labels, one per line, read in bash
# from the store's path; none where the file is missing.
fake_issue_labels() {
  fake_need_store || return 1
  fake_print_lines "$ORCH_GH_FAKE_STORE/issues/$1/labels"
}

# fake_issue_labels_counted <n>: issue #n's label count on one line, then its
# labels one per line when there are any.
fake_issue_labels_counted() {
  local l n=0
  fake_need_store || return 1
  fake_read_lines "$ORCH_GH_FAKE_STORE/issues/$1/labels" || true
  for l in ${fake_lines[@]+"${fake_lines[@]}"}; do [ -z "$l" ] || n=$((n + 1)); done
  printf '%s\n' "$n"
  for l in ${fake_lines[@]+"${fake_lines[@]}"}; do [ -z "$l" ] || printf '%s\n' "$l"; done
}

# fake_comment_append <dir> <author> <created-at> <body-file> [<assoc>]:
# one comment appended to an issue's or PR's comments directory, numbered in
# order, its authorAssociation OWNER unless given. The existing comments are
# counted with a glob, and the comment's directory made in one mkdir.
fake_comment_append() {
  local d="$1" k=1 e
  for e in "$d"/*; do [ -e "$e" ] && k=$((k + 1)); done
  mkdir -p "$d/$k"
  printf '%s\n' "$2" >"$d/$k/author"
  printf '%s\n' "$3" >"$d/$k/created"
  printf '%s\n' "${5:-OWNER}" >"$d/$k/association"
  cat "$4" >"$d/$k/body"
}

# The author and timestamp of every comment the fake's own operations write.
FAKE_COMMENT_AUTHOR=fake-gh
FAKE_COMMENT_CREATED=2026-01-01T00:00:00Z

# fake_comment_write <comments-dir> <body-file>: one comment appended by the
# fake's own author and timestamp.
fake_comment_write() { fake_comment_append "$1" "$FAKE_COMMENT_AUTHOR" "$FAKE_COMMENT_CREATED" "$2"; }

# fake_close_comment <comments-dir> <text>: the text, byte for byte, appended
# as a comment, as a close that carries one writes it.
fake_close_comment() {
  local c
  c="$(mktemp)"
  printf '%s' "$2" >"$c"
  fake_comment_write "$1" "$c"
  rm -f "$c"
}

# adapter_issue_body <n>: the stored body, then a newline, as gh's --jq .body
# prints it.
adapter_issue_body() {
  ! fake_failing adapter_issue_body || return 1
  fake_issue_known "$1" || return 1
  cat "$(fake_issue_dir "$1")/body" 2>/dev/null
  printf '\n'
}

# adapter_issue_json <n>: the stored issue as ISSUE_JSON_JQ's trimmed object -
# its number, title, body byte for byte and label names; no comments.
adapter_issue_json() {
  ! fake_failing adapter_issue_json || return 1
  fake_issue_known "$1" || return 1
  local d body
  d="$(fake_issue_dir "$1")"
  body="$d/body"
  [ -f "$body" ] || body=/dev/null
  jq -cn --argjson n "$1" --arg t "$(cat "$d/title" 2>/dev/null)" \
    --rawfile b "$body" \
    --argjson l "$(fake_issue_labels "$1" | jq -R . | jq -cs .)" \
    '{number: $n, title: $t, body: $b, labels: $l}'
}

# adapter_issue_state_labels <n>: the stored state, then its labels. Lagging
# (fake_lag), it answers the stale answer fake_lag was given, or nothing. The
# state is read in bash from the store's path.
adapter_issue_state_labels() {
  ! fake_failing adapter_issue_state_labels || return 1
  fake_need_store || return 1
  if fake_lagging adapter_issue_state_labels; then
    fake_stale adapter_issue_state_labels
    return 0
  fi
  fake_issue_known "$1" || return 1
  if fake_slurp "$ORCH_GH_FAKE_STORE/issues/$1/state"; then
    printf '%s\n' "$fake_slurped"
  else
    echo "cat: $ORCH_GH_FAKE_STORE/issues/$1/state: No such file or directory" >&2
  fi
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

# adapter_issue_authorship <n>: the stored author login, its association, the
# body's last editor and the title's latest renamer, one per line; fake-gh as
# OWNER, never edited or renamed, for an issue seeded without them. Each is
# read in bash from the store's path.
adapter_issue_authorship() {
  ! fake_failing adapter_issue_authorship || return 1
  fake_need_store || return 1
  fake_issue_known "$1" || return 1
  local d f
  d="$ORCH_GH_FAKE_STORE/issues/$1"
  fake_slurp "$d/author" || fake_slurped="$FAKE_COMMENT_AUTHOR"
  printf '%s\n' "$fake_slurped"
  fake_slurp "$d/association" || fake_slurped=OWNER
  printf '%s\n' "$fake_slurped"
  for f in editor renamer; do
    fake_slurp "$d/$f" || true
    printf '%s\n' "$fake_slurped"
  done
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

# adapter_issue_created_at <n>: the stored created_at of issue #n, the epoch
# where unset.
adapter_issue_created_at() {
  ! fake_failing adapter_issue_created_at || return 1
  fake_issue_known "$1" || return 1
  cat "$(fake_issue_dir "$1")/created_at" 2>/dev/null || echo 1970-01-01T00:00:00Z
}

# fake_open_issues: the numbers of the open issues in the store, newest first,
# as real gh lists them. Each state is read, and each number taken from its
# directory's path, in bash; only sort runs.
fake_open_issues() {
  local d
  fake_need_store || return 1
  for d in "$ORCH_GH_FAKE_STORE"/issues/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    [ ! -f "$d/pull" ] || continue
    fake_read_state "$d/state" || continue
    [ "$fake_state" = OPEN ] || continue
    printf '%s\n' "${d##*/}"
  done | sort -nr
}

# fake_labelled_numbers <all|any> <label>...: the open issues in the store
# carrying every label named (all) or any of them (any), oldest first - the
# first lesser of ISSUE_LIST_LIMIT and 1000 of them, as the search-backed real
# listing is cut, with awk, which reads all of the while loop's output, so the
# loop never takes SIGPIPE under pipefail as it would from head (#1019). Each
# issue's labels file is read once in bash, and a label matches a whole line,
# literally and in any case. The part the labelled listings share; it checks no
# seeded failure.
fake_labelled_numbers() {
  local mode="$1" n l keep line h found
  local -a have
  shift
  fake_need_store || return 1
  fake_open_issues | while read -r n; do
    have=()
    fake_read_lines "$ORCH_GH_FAKE_STORE/issues/$n/labels" || true
    for line in ${fake_lines[@]+"${fake_lines[@]}"}; do have+=("${line,,}"); done
    keep=1
    [ "$mode" = all ] || keep=0
    for l in "$@"; do
      found=0
      for h in ${have[@]+"${have[@]}"}; do [ "$h" = "${l,,}" ] && found=1 && break; done
      if [ "$mode" = all ]; then [ "$found" = 1 ] || keep=0; else [ "$found" = 0 ] || keep=1; fi
    done
    [ "$keep" = 1 ] || continue
    printf "%s\n" "$n"
  done | sort -n | fake_search_cut
}

# fake_labelled_field <state|state-title> <n>: issue #n's stored state as one
# line, or with state-title its state and stored title joined by a tab, as the
# gh adapter prints them; empty where missing.
fake_labelled_field() {
  fake_read_state "$ORCH_GH_FAKE_STORE/issues/$2/state" || true
  if [ "$1" = state-title ]; then
    fake_slurp "$ORCH_GH_FAKE_STORE/issues/$2/title" || true
    printf '%s\t%s\n' "$fake_state" "$fake_slurped"
  else
    printf '%s\n' "$fake_state"
  fi
}

# fake_labelled_rows <op> <all|any> <state|state-title> <label>...: the issues
# fake_labelled_numbers lists, each as the count-marked record the gh adapter
# prints: number, the stored state, or the state and stored title tab-joined,
# label count, labels. Lagging (fake_lag) for <op>, it answers the stale
# answer fake_lag was given, or nothing - a listing served late.
fake_labelled_rows() {
  local op="$1" mode="$2" field="$3" n nums
  shift 3
  ! fake_failing "$op" || return 1
  fake_need_store || return 1
  if fake_lagging "$op"; then
    fake_stale "$op"
    return 0
  fi
  nums="$(fake_labelled_numbers "$mode" "$@")" || return 1
  for n in $nums; do
    printf '%s\n' "$n"
    fake_labelled_field "$field" "$n"
    fake_issue_labels_counted "$n"
  done
}

# adapter_issues_labelled_rows <label>...: the open issues carrying every label.
adapter_issues_labelled_rows() {
  fake_labelled_rows adapter_issues_labelled_rows all state "$@"
}

# adapter_issues_any_labelled_rows <label>...: the open issues carrying any of
# the labels, as adapter_issues_labelled_rows lists them, one cut across all.
adapter_issues_any_labelled_rows() {
  fake_labelled_rows adapter_issues_any_labelled_rows any state "$@"
}

# adapter_issues_open_rows: every open issue, as adapter_issues_labelled_rows
# lists them with no label named: oldest first, cut at the limit.
adapter_issues_open_rows() {
  fake_labelled_rows adapter_issues_open_rows all state
}

# adapter_issues_titled_rows <label>: the open issues carrying the label, oldest
# first and cut at the limit, each as the count-marked record the gh adapter
# prints: number, state and stored title tab-joined, label count, labels.
adapter_issues_titled_rows() {
  fake_labelled_rows adapter_issues_titled_rows all state-title "$@"
}

# fake_search_cut: the first lesser of ISSUE_LIST_LIMIT and ISSUE_SEARCH_CAP
# lines of stdin, as a search-backed real listing is cut.
fake_search_cut() {
  awk -v n="$ISSUE_LIST_LIMIT" -v cap="$ISSUE_SEARCH_CAP" 'BEGIN{if(n>cap)n=cap} NR<=n'
}

# adapter_issues_open_titles: every open issue in the store, one per line as
# <number><TAB><title>, newest first, as gh lists them - not cut at
# ISSUE_LIST_LIMIT.
adapter_issues_open_titles() {
  local n t
  ! fake_failing adapter_issues_open_titles || return 1
  fake_open_issues | while read -r n; do
    t="$(cat "$(fake_issue_dir "$n")/title" 2>/dev/null)"
    printf "%s\t%s\n" "$n" "$t"
  done
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

# fake_take_number <next_issue|next_pr>: the number a new issue or PR takes -
# the counter's, or fake_next_number's where it is unset - printed, and the
# counter advanced past it.
fake_take_number() {
  local f n
  f="$(fake_store)/$1" || return 1
  n="$(cat "$f" 2>/dev/null)"
  [ -n "$n" ] || n="$(fake_next_number)"
  printf '%s\n' "$((n + 1))" >"$f"
  printf '%s\n' "$n"
}

# adapter_issue_body_edit <n> <file>: the file's contents as the stored body.
adapter_issue_body_edit() {
  ! fake_failing adapter_issue_body_edit || return 1
  fake_issue_known "$1" || return 1
  cat "$2" >"$(fake_issue_dir "$1")/body"
}

# fake_option_value <operation> <option-names> <option> [value...]: true where
# <option> is followed by a value that is neither empty nor one of
# <option-names>, a space-separated list each compared whole; otherwise says so
# on stderr and returns 2, as the real adapter's option_value does.
fake_option_value() {
  local value="${4:-}" refused="" name names
  read -r -a names <<<"$2"
  [ -n "$value" ] || refused=1
  for name in "${names[@]}"; do [ "$value" != "$name" ] || refused=1; done
  [ -n "$refused" ] || return 0
  printf 'fake gh: %s: %s needs a value\n' "$1" "$3" >&2
  return 2
}

# fake_unknown_option <operation> <argument>: refuses an argument the
# operation does not take, on stderr, with status 2.
fake_unknown_option() {
  printf "fake gh: %s: unknown option '%s'\n" "$1" "$2" >&2
  return 2
}

# adapter_issue_relabel <n> [--add <label>]... [--remove <label>]...: the
# labels named removed from, then added to, the stored labels, each once.
adapter_issue_relabel() {
  local n="$1" f l adds=() removes=() options="--add --remove"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --add)    fake_option_value adapter_issue_relabel "$options" "$@" || return; adds+=("$2"); shift 2 ;;
      --remove) fake_option_value adapter_issue_relabel "$options" "$@" || return; removes+=("$2"); shift 2 ;;
      *) fake_unknown_option adapter_issue_relabel "$1"; return ;;
    esac
  done
  # With nothing named, the real one makes no gh call, so nothing can fail.
  [ ${#adds[@]} -gt 0 ] || [ ${#removes[@]} -gt 0 ] || return 0
  ! fake_failing adapter_issue_relabel || return 1
  fake_issue_known "$n" || return 1
  f="$(fake_issue_dir "$n")/labels"
  for l in ${removes[@]+"${removes[@]}"}; do
    { grep -vxiF -- "$l" "$f" || true; } >"$f.tmp"; mv "$f.tmp" "$f"
  done
  for l in ${adds[@]+"${adds[@]}"}; do
    fake_labels_add "$f" "$l"
  done
}

# adapter_issue_close <n> [--reason <r>] [--comment <c>]: the stored issue
# CLOSED, its reason (completed where none is given, as GitHub defaults) in
# reason, and the comment, where given, appended by fake-gh - except as GitHub
# behaves: closing an issue already CLOSED succeeds and leaves it as it is,
# with no comment and its reason unchanged.
adapter_issue_close() {
  local n="$1" reason=completed comment="" d options="--reason --comment"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)  fake_option_value adapter_issue_close "$options" "$@" || return; reason="$2"; shift 2 ;;
      --comment) fake_option_value adapter_issue_close "$options" "$@" || return; comment="$2"; shift 2 ;;
      *) fake_unknown_option adapter_issue_close "$1"; return ;;
    esac
  done
  # compound, as the real operation is, when a comment is given
  ! GH_LIMIT_COMPOUND=${comment:+1} fake_failing adapter_issue_close || return 1
  fake_issue_known "$n" || return 1
  d="$(fake_issue_dir "$n")"
  [ "$(cat "$d/state" 2>/dev/null)" != CLOSED ] || return 0
  [ -z "$comment" ] || fake_close_comment "$d/comments" "$comment"
  printf 'CLOSED\n' >"$d/state"
  printf '%s\n' "$reason" >"$d/reason"
}

# adapter_issue_reopen <n>: the stored issue OPEN again.
adapter_issue_reopen() {
  ! fake_failing adapter_issue_reopen || return 1
  fake_issue_known "$1" || return 1
  printf 'OPEN\n' >"$(fake_issue_dir "$1")/state"
  rm -f "$(fake_issue_dir "$1")/reason" "$(fake_issue_dir "$1")/duplicate_of"
}

# --- pr operations, on the store ----------------------------------------------

fake_pr_dir() { printf '%s/prs/%s\n' "$(fake_store)" "$1"; }

# fake_pr_known <n>: true where the store holds PR #n; otherwise gh's own
# error on stderr, as `gh pr view` gives for a number with no PR.
fake_pr_known() {
  [ -d "$(fake_pr_dir "$1")" ] && return 0
  printf 'GraphQL: Could not resolve to a PullRequest with the number of %s. (repository.pullRequest)\n' "$1" >&2
  return 1
}

# adapter_pr_create <base> <head> <title> <body-file> [--draft]
# [--label <name>]...: a new open PR in the store, numbered as next_pr set
# (default one past the highest issue or PR number the store holds, the two
# sharing GitHub's numbering), a draft under --draft, carrying each label named
# but those pr_label_drops lists, its number printed.
adapter_pr_create() {
  local base="$1" head="$2" title="$3" body="$4" draft=false labels=() n d l options="--draft --label"
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) draft=true; shift ;;
      --label) fake_option_value adapter_pr_create "$options" "$@" || return; labels+=("$2"); shift 2 ;;
      *) fake_unknown_option adapter_pr_create "$1"; return ;;
    esac
  done
  # compound, as the real operation is, when a label is given
  ! GH_LIMIT_COMPOUND=${labels[*]:+1} fake_failing adapter_pr_create || return 1
  n="$(fake_take_number next_pr)" || return 1
  d="$(fake_pr_dir "$n")"
  mkdir -p "$d"
  printf 'OPEN\n' >"$d/state"
  printf '%s\n' "$base" >"$d/base"
  printf '%s\n' "$head" >"$d/head"
  printf '%s\n' "$title" >"$d/title"
  cat "$body" >"$d/body"
  [ "$draft" != true ] || : >"$d/draft"
  : >"$d/labels"
  for l in ${labels[@]+"${labels[@]}"}; do
    grep -qxiF -- "$l" "$(fake_store)/pr_label_drops" 2>/dev/null || fake_labels_add "$d/labels" "$l"
  done
  printf '%s\n' "$n"
}

# adapter_pr_labels <n>: the stored label names, one per line.
adapter_pr_labels() {
  ! fake_failing adapter_pr_labels || return 1
  fake_pr_known "$1" || return 1
  cat "$(fake_pr_dir "$1")/labels" 2>/dev/null || true
}

# adapter_pr_body <n>: the stored body, then a newline, as gh's --jq .body
# prints it.
adapter_pr_body() {
  ! fake_failing adapter_pr_body || return 1
  fake_pr_known "$1" || return 1
  cat "$(fake_pr_dir "$1")/body" 2>/dev/null
  printf '\n'
}

# adapter_pr_refs <n>: the stored head SHA (default forty zeros, a SHA no
# reflog or object store holds), head branch and base branch.
adapter_pr_refs() {
  local d oid
  ! fake_failing adapter_pr_refs || return 1
  fake_pr_known "$1" || return 1
  d="$(fake_pr_dir "$1")"
  oid="$(fake_pr_head_oid "$d")"
  printf '%s\n' "$oid"
  cat "$d/head" "$d/base"
}

# adapter_pr_draft <n>: the stored PR a draft.
adapter_pr_draft() {
  ! fake_failing adapter_pr_draft || return 1
  fake_pr_known "$1" || return 1
  : >"$(fake_pr_dir "$1")/draft"
}

# fake_pr_cross_of <pr-dir>: prints the stored PR's cross_repository flag -
# its cross_repository file, or false where unset.
fake_pr_cross_of() {
  cat "$1/cross_repository" 2>/dev/null || echo false
}

# adapter_prs_open <head> [base]: the open PRs in the store from the head
# branch, into the base where one is named, newest first, each as
# `<number>\t<flag>`, the flag the PR's stored cross_repository file (false
# where unset), printed as stored.
adapter_prs_open() {
  local d
  ! fake_failing adapter_prs_open || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = OPEN ] && [ "$(cat "$d/head")" = "$1" ] || continue
    [ -z "${2:-}" ] || [ "$(cat "$d/base")" = "$2" ] || continue
    printf '%s\t%s\n' "$(basename "$d")" "$(fake_pr_cross_of "$d")"
  done | sort -rn
}

# adapter_prs_open_bodies: every open PR in the store, newest first, each as
# `<number>\t<body>\t<flag>`, the body its stored body JSON-encoded (an empty
# string where unset), the flag as adapter_prs_open prints it.
adapter_prs_open_bodies() {
  local d
  ! fake_failing adapter_prs_open_bodies || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = OPEN ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$d")" \
      "$(if [ -f "$d/body" ]; then jq -Rs . <"$d/body"; else echo '""'; fi)" \
      "$(fake_pr_cross_of "$d")"
  done | sort -rn
}

# adapter_prs_open_mergeability: every open PR in the store, newest first, each
# as `<number>\t<head>\t<mergeable>\t<flag>`, the mergeable value the PR's
# stored mergeable file (UNKNOWN where unset), the flag as adapter_prs_open
# prints it.
adapter_prs_open_mergeability() {
  local d
  ! fake_failing adapter_prs_open_mergeability || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = OPEN ] || continue
    printf '%s\t%s\t%s\t%s\n' "$(basename "$d")" "$(cat "$d/head")" \
      "$(cat "$d/mergeable" 2>/dev/null || echo UNKNOWN)" "$(fake_pr_cross_of "$d")"
  done | sort -rn
}

# adapter_pr_diff <n>: the stored diff, byte for byte.
adapter_pr_diff() {
  ! fake_failing adapter_pr_diff || return 1
  fake_pr_known "$1" || return 1
  cat "$(fake_pr_dir "$1")/diff" 2>/dev/null
  return 0
}

# fake_pr_head_oid <pr-dir>: prints the stored PR's head SHA - its head_oid
# file as stored, empty included (GitHub's null head), or forty zeros when that
# is absent - the store's one head rule, which every reader goes through.
fake_pr_head_oid() {
  if [ -f "$1/head_oid" ]; then
    printf '%s\n' "$(cat "$1/head_oid")"
  else
    printf '%s\n' 0000000000000000000000000000000000000000
  fi
}

# adapter_prs_merged <head> <base>: the merged PRs in the store from the head
# branch into the base, newest first: number, head SHA and the PR's stored
# cross_repository flag (false where unset), tab-separated, printed as stored.
adapter_prs_merged() {
  local d
  ! fake_failing adapter_prs_merged || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = MERGED ] && [ "$(cat "$d/head")" = "$1" ] \
      && [ "$(cat "$d/base")" = "$2" ] || continue
    printf '%s\t%s\t%s\n' "$(basename "$d")" "$(fake_pr_head_oid "$d")" \
      "$(fake_pr_cross_of "$d")"
  done | sort -rn
}

# adapter_prs_merged_closing <base> <since>: the merged PRs in the store into
# the base merged at or after <since>, newest first, each as
# `<number>\t<head>\t<mergedAt>\t<closing>\t<flag>` -
# the stored merged_at (the epoch where unset), the stored closing numbers
# comma-joined, the flag as adapter_prs_open prints it.
adapter_prs_merged_closing() {
  local d merged_at
  ! fake_failing adapter_prs_merged_closing || return 1
  for d in "$(fake_store)"/prs/*/; do
    [ -d "$d" ] || continue
    [ "$(cat "$d/state")" = MERGED ] && [ "$(cat "$d/base")" = "$1" ] || continue
    merged_at="$(cat "$d/merged_at" 2>/dev/null || echo 1970-01-01T00:00:00Z)"
    [[ "$merged_at" < "$2" ]] && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$d")" "$(cat "$d/head")" \
      "$merged_at" \
      "$(paste -sd, "$d/closing" 2>/dev/null)" "$(fake_pr_cross_of "$d")"
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
# by fake-gh - except as GitHub behaves: closing a PR already CLOSED, or an
# OPEN one whose head branch is gone from a readable origin (GitHub closed it
# itself when the branch was deleted), succeeds and appends no comment. The
# origin is read with git ls-remote in the working directory; only exit 2 (no
# such ref) counts as gone, any other failure closes with the comment.
adapter_pr_close() {
  local d head st
  ! GH_LIMIT_COMPOUND=1 fake_failing adapter_pr_close || return 1
  fake_pr_known "$1" || return 1
  d="$(fake_pr_dir "$1")"
  st="$(cat "$d/state" 2>/dev/null)"
  [ "$st" != CLOSED ] || return 0
  head="$(cat "$d/head" 2>/dev/null)"
  git ls-remote --exit-code origin "refs/heads/$head" >/dev/null 2>&1
  [ $? -eq 2 ] || fake_close_comment "$d/comments" "$2"
  printf 'CLOSED\n' >"$d/state"
}

# adapter_pr_comment <n> <file>: the file's contents appended as a comment, by
# fake-gh.
adapter_pr_comment() {
  ! fake_failing adapter_pr_comment || return 1
  fake_pr_known "$1" || return 1
  fake_comment_write "$(fake_pr_dir "$1")/comments" "$2"
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

# adapter_pr_title_edit <n> <title>: the title as the stored one.
adapter_pr_title_edit() {
  ! fake_failing adapter_pr_title_edit || return 1
  fake_pr_known "$1" || return 1
  printf '%s\n' "$2" >"$(fake_pr_dir "$1")/title"
}

# adapter_pr_label_add <n> <label>: the label appended to the stored ones.
adapter_pr_label_add() {
  ! fake_failing adapter_pr_label_add || return 1
  fake_pr_known "$1" || return 1
  fake_labels_add "$(fake_pr_dir "$1")/labels" "$2"
}

# --- sub-issue and dependency operations, on the store ------------------------

# fake_blockers_count <n>: how many of #n's stored blockers are still open, in
# the variable fake_open_count, read in bash from the store's path. A blocker
# whose state cannot be read does not count.
fake_blockers_count() {
  local b
  fake_open_count=0
  fake_need_store || return 1
  [ -r "$ORCH_GH_FAKE_STORE/blocked_by/$1" ] || return 0
  while IFS= read -r b || [ -n "$b" ]; do
    [ -n "$b" ] || continue
    fake_read_state "$ORCH_GH_FAKE_STORE/issues/$b/state" || continue
    [ "$fake_state" = OPEN ] && fake_open_count=$((fake_open_count + 1))
  done <"$ORCH_GH_FAKE_STORE/blocked_by/$1"
  return 0
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
  local n st
  ! fake_failing adapter_sub_issues || return 1
  fake_need_store || return 1
  if fake_lagging adapter_sub_issues; then
    fake_stale adapter_sub_issues
    return 0
  fi
  fake_issue_known "$1" || return 1
  [ -r "$ORCH_GH_FAKE_STORE/subs/$1" ] || return 0
  while IFS= read -r n || [ -n "$n" ]; do
    [ -n "$n" ] || continue
    fake_read_state "$ORCH_GH_FAKE_STORE/issues/$n/state" || fake_state=""
    st="$fake_state"
    fake_blockers_count "$n"
    printf '%s\t%s\t%s\n' "$n" "$st" "$fake_open_count"
  done <"$ORCH_GH_FAKE_STORE/subs/$1"
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
# nothing. The store's path is used directly, each file's lines read and its
# name taken from its path in bash.
adapter_issue_parent() {
  local f
  ! fake_failing adapter_issue_parent || return 1
  fake_need_store || return 1
  fake_issue_known "$1" || return 1
  for f in "$ORCH_GH_FAKE_STORE"/subs/*; do
    [ -f "$f" ] || continue
    if fake_has_line "$f" "$1"; then printf '%s\n' "${f##*/}"; return 0; fi
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

# adapter_issue_open_blockers <n>: the count of #n's stored blockers still open,
# or nothing where no_dependency_summary lists #n.
adapter_issue_open_blockers() {
  ! fake_failing adapter_issue_open_blockers || return 1
  fake_need_store || return 1
  fake_issue_known "$1" || return 1
  ! fake_has_line "$ORCH_GH_FAKE_STORE/no_dependency_summary" "$1" || return 0
  fake_blockers_count "$1"
  printf '%s\n' "$fake_open_count"
}

# adapter_blockers_states <n>: #n's stored blockers, in the order they were
# added, each with its stored state, as the gh adapter prints them.
adapter_blockers_states() {
  local b
  ! fake_failing adapter_blockers_states || return 1
  fake_need_store || return 1
  fake_issue_known "$1" || return 1
  [ -r "$ORCH_GH_FAKE_STORE/blocked_by/$1" ] || return 0
  while IFS= read -r b || [ -n "$b" ]; do
    [ -n "$b" ] || continue
    fake_read_state "$ORCH_GH_FAKE_STORE/issues/$b/state" || fake_state=""
    printf '%s\t%s\n' "$b" "$fake_state"
  done <"$ORCH_GH_FAKE_STORE/blocked_by/$1"
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

# --- repo operations, on the store --------------------------------------------

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

# adapter_claim_create <issue> <phase> <pid> <host>: the claim stored as one
# line, the host and the start time beside the arguments; status 2 where the
# issue is already claimed, as the real operation's lost race.
adapter_claim_create() {
  ! fake_failing adapter_claim_create || return 1
  local f
  f="$(fake_store)/claims/$1"
  mkdir -p "$(fake_store)/claims"
  [ ! -e "$f" ] || return 2
  printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$4" "$3" "$2" "$(now)" >"$f"
}

# adapter_claim_delete <issue>: the claim removed; none there is freed all the
# same.
adapter_claim_delete() {
  ! fake_failing adapter_claim_delete || return 1
  rm -f "$(fake_store)/claims/$1"
}

# adapter_claim_list: every stored claim's line, by issue number. The claims
# are listed and ordered, and each read, in bash from the store's path.
adapter_claim_list() {
  ! fake_failing adapter_claim_list || return 1
  fake_need_store || return 1
  local f
  fake_entries_sorted "$ORCH_GH_FAKE_STORE/claims"
  for f in ${fake_entries[@]+"${fake_entries[@]}"}; do
    fake_print_lines "$ORCH_GH_FAKE_STORE/claims/$f"
  done
}
