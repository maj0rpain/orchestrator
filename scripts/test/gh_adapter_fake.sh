# The in-memory half of the ORCH_GH_ADAPTER seam.
#
# Sourced into orch.sh's own process via ORCH_GH_ADAPTER, this redefines the
# adapter functions orch.sh calls instead of shelling out to `gh` - so a test
# exercises orch.sh's decision logic without spawning a subprocess for every
# GitHub call. Parameterized by the same GH_STUB_* vocabulary orch_test.sh's
# subprocess fake (`stub_gh`) already answers to, so a test switches between
# the two fakes without learning a second vocabulary, and an assertion written
# against one reads the other's output too.
#
# The fake is moving onto a file store (#280). An operation under the #280
# operation contract parses no arguments: it keeps its state in the directory
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
#   fail/<operation>  present, every call of that operation fails, non-zero,
#                     with the file's contents as gh's stderr
#   lag/<operation>   a countdown: while above zero, each call of that
#                     operation answers stale and counts it down
#   lag/<operation>.stale
#                     the stale answer, where the operation takes one
#
# The CI operations, not yet moved onto the store, keep mirroring the
# GH_STUB_* vocabulary stub_gh answers to, below.

fake_store() {
  printf '%s\n' "${ORCH_GH_FAKE_STORE:?the gh fake has no store - call fake_github}"
}

# fake_failing <operation>: true when fake_fail named the operation, with its
# stderr written, so an operation opens with `! fake_failing <op> || return 1`.
fake_failing() {
  local f
  f="$(fake_store)/fail/$1" || return 1
  [ -f "$f" ] || return 1
  cat "$f" >&2
}

# fake_lagging <operation>: true while the operation's lag countdown is above
# zero, counting it down by one, so an operation answers stale for exactly the
# calls fake_lag asked for.
fake_lagging() {
  local f n
  f="$(fake_store)/lag/$1" || return 1
  [ -f "$f" ] || return 1
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

# adapter_issue_state_labels <n>: the stored state, then its labels.
adapter_issue_state_labels() {
  ! fake_failing adapter_issue_state_labels || return 1
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
# every label named, in number order.
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
  done | sort -n
}

# adapter_issue_create <title> <body-file> [label...]: a new open issue in the
# store, numbered as fake_next_issue set (default one past the highest the
# store holds), its number printed.
adapter_issue_create() {
  local title="$1" body="$2" n d
  shift 2
  ! fake_failing adapter_issue_create || return 1
  n="$(cat "$(fake_store)/next_issue" 2>/dev/null)"
  if [ -z "$n" ]; then
    n="$(ls "$(fake_store)/issues" 2>/dev/null | sort -n | tail -n 1)"
    n=$(( ${n:-0} + 1 ))
  fi
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
  if [ -z "$n" ]; then
    n="$(ls "$(fake_store)/issues" "$(fake_store)/prs" 2>/dev/null | grep -x '[0-9][0-9]*' | sort -n | tail -n 1)"
    n=$(( ${n:-0} + 1 ))
  fi
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

# --- ci operations, still on the GH_STUB_* knobs ---------------------------------

# review ci's CI-evidence reads (issue #476). The fakes default to exactly one
# signal present - a check-run on the base branch tip - so a grace test that
# says nothing about evidence keeps the grace; a test opts into each absence.
#
# adapter_branch_protection - the base branch's classic required status
# checks. GH_STUB_PROTECTION picks gh api's answer: none (default) is the 404
# `Branch not protected` GitHub gives an unprotected branch, required a 200
# naming one context, notfound the bare 404 `Not Found` of a token without
# access, boom a failed round trip.
adapter_branch_protection() {
  case "${GH_STUB_PROTECTION:-none}" in
    none)     printf '%s\n' '{"message":"Branch not protected","status":"404"}'
              echo "gh: Branch not protected (HTTP 404)" >&2; return 1 ;;
    required) printf '%s\n' '{"strict":false,"contexts":["build"],"checks":[{"context":"build","app_id":null}]}' ;;
    notfound) printf '%s\n' '{"message":"Not Found","status":"404"}'
              echo "gh: Not Found (HTTP 404)" >&2; return 1 ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no protection named '$GH_STUB_PROTECTION'" >&2; return 99 ;;
  esac
}

# adapter_branch_rules - the rules every ruleset applies to the base branch.
# GH_STUB_RULES: none (default) is the `[]` of a branch no ruleset touches,
# required a required_status_checks rule, other a ruleset rule that requires
# no checks, boom a failed round trip.
adapter_branch_rules() {
  case "${GH_STUB_RULES:-none}" in
    none)     printf '%s\n' '[]' ;;
    required) printf '%s\n' '[{"type":"required_status_checks","parameters":{"required_status_checks":[{"context":"build"}]}}]' ;;
    other)    printf '%s\n' '[{"type":"deletion"}]' ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no rules named '$GH_STUB_RULES'" >&2; return 99 ;;
  esac
}

# adapter_commit_check_runs / adapter_commit_statuses - the check-runs and
# the combined commit status of one ref (a SHA, or the base branch's name for
# its tip). GH_STUB_CHECKED_REFS (default main, the base tip) and
# GH_STUB_STATUSED_REFS (default none) are space-separated lists of the refs
# that have one; a ref in GH_STUB_REF_READ_FAIL fails both reads.
fake_ref_in() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }
adapter_commit_check_runs() {
  if fake_ref_in "$1" "${GH_STUB_REF_READ_FAIL:-}"; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
  if fake_ref_in "$1" "${GH_STUB_CHECKED_REFS-main}"; then
    printf '%s\n' '{"total_count":1,"check_runs":[{"name":"build"}]}'
  else
    printf '%s\n' '{"total_count":0,"check_runs":[]}'
  fi
}
adapter_commit_statuses() {
  if fake_ref_in "$1" "${GH_STUB_REF_READ_FAIL:-}"; then echo "gh: Server Error (HTTP 502)" >&2; return 1; fi
  if fake_ref_in "$1" "${GH_STUB_STATUSED_REFS:-}"; then
    printf '%s\n' '{"state":"success","total_count":1,"statuses":[{"context":"ci/legacy"}]}'
  else
    printf '%s\n' '{"state":"pending","total_count":0,"statuses":[]}'
  fi
}

# adapter_pr_checks - mirrors stub_gh's `pr checks` branch, the trickiest one
# to replicate faithfully in-memory: ci_probe calls this once per poll tick,
# many times within the same process, so a plain shell variable counter would
# not match stub_gh's cross-subprocess behaviour where GH_STUB_CHECKS_N /
# GH_STUB_REQUIRED_N name a file the count is persisted to. This fake reads
# and writes the same file, so a test that sets GH_STUB_REQUIRED_N to advance
# a script across separate `orch.sh` invocations behaves identically whichever
# adapter is in play.
#
# GH_STUB_REQUIRED (when --required is among the arguments) or GH_STUB_CHECKS
# otherwise is a `|`-separated script of answers - green, failing, cancel,
# pending, pending0, garbage, none, boom - consumed one per call with the last
# one repeating once the script runs out.
#
# `pending` returns exit 8 with a pending bucket in its JSON, the real gh
# pr checks documents but that our JSON-asking calls never actually take
# (ci_probe's `8)` arm exists only against that documented case); `pending0`
# is the path real `gh pr checks --json` actually takes - exit 0 with the
# pending bucket carrying the answer instead. Getting the two exits right is
# what proves ci_probe's own bucket classification, not just its exit-status
# read, still drives the verdict.
adapter_pr_checks() {
  local a req=0 script counter i answer
  for a in "$@"; do
    if [ "$a" = --required ]; then req=1; fi
  done
  if [ "$req" = 1 ]; then
    script="${GH_STUB_REQUIRED:-none}"; counter="${GH_STUB_REQUIRED_N:-}"
  else
    script="${GH_STUB_CHECKS:-green}"; counter="${GH_STUB_CHECKS_N:-}"
  fi
  i=1
  if [ -n "$counter" ]; then
    i=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$i" >"$counter"
  fi
  answer="$(printf '%s' "$script" | awk -F'|' -v i="$i" '{ print (i <= NF) ? $i : $NF }')"
  case "$answer" in
    green)    printf '%s\n' '[{"bucket":"pass","name":"build","state":"SUCCESS"}]' ;;
    failing)  printf '%s\n' '[{"bucket":"fail","name":"build","state":"FAILURE"},{"bucket":"pass","name":"lint","state":"SUCCESS"}]' ;;
    cancel)   printf '%s\n' '[{"bucket":"cancel","name":"build","state":"CANCELLED"}]' ;;
    pending)  printf '%s\n' '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]'; return 8 ;;
    pending0) printf '%s\n' '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]' ;;
    garbage)  printf '%s\n' 'not json at all' ;;
    none)     echo "no checks reported on the 'topic' branch" >&2; return 1 ;;
    boom)     echo "dial tcp: lookup api.github.com: no such host" >&2; return 1 ;;
    *)        echo "gh stub: no script named '$answer'" >&2; return 99 ;;
  esac
  return 0
}
