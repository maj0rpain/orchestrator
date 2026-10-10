# shellcheck shell=bash
# gh.sh - the gh adapter layer (ADR-0033): gh(), the guard every GitHub call
# goes through, every adapter_* operation and the JQ constants they read.
# It stays whole, whoever calls each operation, and ends with the
# ORCH_GH_ADAPTER hook, so a test adapter overrides the real operations.
# Its tests: scripts/test/orch/gh.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The guard every GitHub call in orch.sh and its modules goes through by name
# (#520): `gh` itself, defined ahead of the ORCH_GH_ADAPTER seam so a test
# adapter picks it up. On first use it resolves the repo
# and exports it as GH_REPO for the rest of the run - with GH_HOST beside it for
# a host other than github.com - so every later call - `gh api`'s
# {owner}/{repo} placeholders and host included - is pinned to it, never to
# gh's own default repo, which in a fork is the upstream. With no repo it dies
# naming GH_REPO. Inside a command substitution `die` would end only that
# subshell, and its message could land in a 2>/dev/null, so there it signals
# the main shell, whose USR1 trap dies with the remedy instead. Its last line is
# the only call to the real gh binary in orch.sh and its modules.
gh() {
  if ! repo_pin; then
    if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then kill -USR1 "$$"; exit 1; fi
    die "$REPO_REMEDY"
  fi
  command gh "$@"
}

# --- gh adapter -------------------------------------------------------------
#
# The seam between orch.sh's decision logic and the `gh` CLI. A caller like
# review.sh's severity_label_ensure calls an adapter operation, never `gh`
# itself, so a test can replace one in-process function instead of faking a
# `gh` binary on PATH. Every GitHub call in orch.sh and its modules goes
# through one. History: begun with labels (#91), issues (#92); all since #280.
#
# The operations, in the order they are defined below:
# - label: adapter_label_upsert, adapter_label_create, adapter_labels
# - issue: adapter_issue_body, adapter_issue_comments,
#   adapter_issue_state_labels, adapter_issue_state_labels_body,
#   adapter_issue_title_labels, adapter_issue_state, adapter_issues_labelled, adapter_issue_create,
#   adapter_issue_body_edit, adapter_issue_comment, adapter_issue_relabel,
#   adapter_issue_close, adapter_issue_reopen
# - pr: adapter_pr_create, adapter_pr_body, adapter_pr_comments,
#   adapter_pr_refs, adapter_pr_ready, adapter_pr_draft,
#   adapter_pr_state_draft, adapter_prs_open, adapter_prs_merged,
#   adapter_prs_merged_bodies, adapter_pr_close, adapter_pr_comment,
#   adapter_pr_body_edit
# - sub-issue and dependency: adapter_sub_issues, adapter_sub_issue_link,
#   adapter_sub_issue_unlink, adapter_issue_parent, adapter_blockers,
#   adapter_blocker_add, adapter_blocker_remove, adapter_sub_issues_supported
# - repo: adapter_repo_default_branch, adapter_repo_local_default,
#   adapter_auth_status
# - ci: adapter_pr_checks, adapter_branch_required_checks,
#   adapter_branch_rules, adapter_commit_has_check_runs,
#   adapter_commit_has_statuses, adapter_run_rerun
#
# ORCH_GH_ADAPTER is an opt-in test knob in the same spirit as review.sh's
# ORCH_CI_* ones, but read differently: not a value substituted at load time, but
# a file sourced immediately after the real adapter functions are defined:
# anything it redefines overrides the corresponding real function for the
# rest of the process, and anything it leaves alone keeps shelling out to the
# real `gh` below. Unset - every normal run - nothing is sourced and behaviour
# is identical to before the seam existed.
#
# Operations under the #280 contract - the label, issue, PR, sub-issue and
# dependency, repo, and CI ones - are named for what their callers need and own gh's
# flags, --jq and GitHub's database ids: each prints plain text in the shape
# documented on it, and on a gh failure returns non-zero with gh's stderr
# passed through.
#
# Their arguments (#664): required ones are positional, optional ones named
# options after them, and a caller with nothing to pass leaves the option out.
# An operation that takes options parses them before any gh call, and refuses an
# unknown option, or one missing its value or given an empty one, with status 2
# and a message on stderr - so a caller still on an older grammar fails loudly.
# An option directly followed by another of the operation's options is missing
# its value; a value that only begins with - or -- is still a value.

# option_value <operation> <option-names> <option> [value...]: true where
# <option> is followed by a value that is neither empty nor one of
# <option-names>, a space-separated list each compared whole; otherwise says so
# on stderr and returns 2. Called as
# `option_value <operation> "<option-names>" "$@" || return` from an option loop.
option_value() {
  local value="${4:-}" refused="" name names
  read -r -a names <<<"$2"
  [ -n "$value" ] || refused=1
  for name in "${names[@]}"; do [ "$value" != "$name" ] || refused=1; done
  [ -n "$refused" ] || return 0
  warn "$1: $3 needs a value"
  return 2
}

# unknown_option <operation> <argument>: refuses an argument the
# operation does not take, on stderr, with status 2.
unknown_option() {
  warn "$1: unknown option '$2'"
  return 2
}

# url_number <issues|pull> <gh-output>: the number in the last issue or PR URL
# of what gh create printed - the URL alone on its line - or nothing, failing,
# where it printed none. Each caller writes its own error.
url_number() {
  local n
  n="$(printf '%s\n' "$2" | sed -n "s#^https\{0,1\}://.*/$1/\([0-9][0-9]*\)\$#\1#p" | tail -n 1)"
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# adapter_label_upsert <name> <colour> <description>: creates the label, or
# updates the one that exists, to that colour and description. Prints nothing.
adapter_label_upsert() {
  gh label create "$1" --force --color "$2" --description "$3" >/dev/null
}

# adapter_label_create <name> <colour> <description>: creates the label where
# the repo has none of that name; fails where it has one, leaving it as it is.
# Prints nothing.
adapter_label_create() {
  gh label create "$1" --color "$2" --description "$3" >/dev/null
}

# adapter_labels <limit>: the names of the repo's labels, at most <limit> of
# them, one per line. Nothing at all for a repo with none.
adapter_labels() {
  gh label list --limit "$1" --json name --jq '.[].name'
}

# --- issue operations ---

# Every comment on an issue or PR, in order, each opened by a marker line
# naming its author and gh's ISO-8601 timestamp, one blank line between
# comments and bodies unescaped; nothing at all for none. pr comments (issue
# #418) reads a PR's comments through this same --jq, so the two read alike.
COMMENTS_JQ='[.comments[] | "<!-- comment @\(.author.login) \(.createdAt) -->\n\(.body)"] | select(length > 0) | join("\n\n")'

# The trimmed object `issue fetch --json` publishes (#528): the issue's number,
# title and body, its label names, and each comment's author login, gh's
# ISO-8601 timestamp and body - every other field gh answers with is dropped,
# so the shape does not change with gh's version.
ISSUE_JSON_JQ='{number, title, body, labels: [.labels[].name], comments: [.comments[] | {author: .author.login, createdAt, body}]}'

# adapter_issue_body <n>: the issue's body as GitHub holds it, then a newline.
adapter_issue_body() {
  gh issue view "$1" --json body --jq .body
}

# adapter_issue_comments <n>: the issue's comments in COMMENTS_JQ's shape.
adapter_issue_comments() {
  gh issue view "$1" --json comments --jq "$COMMENTS_JQ"
}

# adapter_issue_json <n>: the issue as ISSUE_JSON_JQ's one JSON object - the
# one operation that prints JSON rather than plain text, because that object
# is the shape `issue fetch --json` publishes.
adapter_issue_json() {
  gh issue view "$1" --json number,title,body,labels,comments --jq "$ISSUE_JSON_JQ"
}

# adapter_issue_state_labels <n>: OPEN or CLOSED on the first line, then one
# label per line - none at all for an unlabelled issue.
adapter_issue_state_labels() {
  gh issue view "$1" --json state,labels --jq '.state, (.labels[].name)'
}

# issue_state_labels_read <n> <state_var> <labels_var> <err_var>: reads issue
# <n> once through adapter_issue_state_labels and writes its state (the first
# line) and its labels (the rest, possibly empty) into the first two
# caller-named variables. Non-zero when the read fails, writing neither, and
# writing gh's stderr into <err_var>: the caller keeps its own failure
# message. gh's stderr is captured, never passed through. The answer is split
# through lines_split, as issue_publish_verified's is.
# Out-params through `printf -v`, as require_field's, its locals prefixed so
# no caller's variable name is shadowed.
issue_state_labels_read() {
  local __islr_out __islr_err
  if ! capture __islr_out __islr_err adapter_issue_state_labels "$1"; then
    printf -v "$4" '%s' "$__islr_err"
    return 1
  fi
  lines_split "$__islr_out" "$2" "$3"
}

# adapter_issue_state_labels_body <n>: OPEN or CLOSED on the first line, the
# label count on the second, then one label per line, then the body as GitHub
# holds it and a newline - the count marks where the labels end and the body
# begins.
adapter_issue_state_labels_body() {
  gh issue view "$1" --json state,labels,body --jq '.state, (.labels | length), (.labels[].name), .body'
}

# issue_state_labels_body_read <n> <state_var> <labels_var> <body_var>
# <err_var>: reads issue <n> once through adapter_issue_state_labels_body and
# writes its state, its labels (one per line, possibly none) and its body into
# the first three caller-named variables. Non-zero when the read fails or its
# answer does not parse, writing none of them, and writing gh's stderr into
# <err_var>, as issue_state_labels_read does.
issue_state_labels_body_read() {
  local __islbr_out __islbr_err __islbr_state __islbr_count __islbr_labels="" __islbr_body __islbr_i
  if ! capture __islbr_out __islbr_err adapter_issue_state_labels_body "$1"; then
    printf -v "$5" '%s' "$__islbr_err"
    return 1
  fi
  lines_split "$__islbr_out" __islbr_state __islbr_count __islbr_body
  case "$__islbr_count" in
    ''|*[!0-9]*) printf -v "$5" '%s' "gh answered no label count"; return 1 ;;
  esac
  for (( __islbr_i = 0; __islbr_i < __islbr_count; __islbr_i++ )); do
    __islbr_labels="$__islbr_labels${__islbr_body%%$'\n'*}"$'\n'
    case "$__islbr_body" in
      *$'\n'*) __islbr_body="${__islbr_body#*$'\n'}" ;;
      *) __islbr_body="" ;;
    esac
  done
  printf -v "$2" '%s' "$__islbr_state"
  printf -v "$3" '%s' "${__islbr_labels%$'\n'}"
  printf -v "$4" '%s' "$__islbr_body"
}

# adapter_issue_title_labels <n>: the title on the first line, then one label
# per line.
adapter_issue_title_labels() {
  gh issue view "$1" --json title,labels --jq '.title, (.labels[].name)'
}

# adapter_issue_state <n>: OPEN or CLOSED - or PULL where <n> is a pull
# request's number, which gh issue view answers for too.
adapter_issue_state() {
  gh issue view "$1" --json state,url --jq 'if (.url | test("/pull/")) then "PULL" else .state end'
}

# adapter_issues_labelled <label>...: the open issues carrying every label
# named, one number per line - gh filters on whole labels, not on a prefix.
adapter_issues_labelled() {
  local args=() l
  for l in "$@"; do args+=(--label "$l"); done
  gh issue list --state open ${args[@]+"${args[@]}"} --limit "$ISSUE_LIST_LIMIT" --json number --jq '.[].number'
}

# adapter_issue_create <title> <body-file> [label...]: files the issue under
# every label named and prints its number alone. Fails, printing nothing, where
# gh succeeded but printed no issue URL.
adapter_issue_create() {
  local title="$1" body="$2" args=() l out n
  shift 2
  for l in "$@"; do args+=(--label "$l"); done
  out="$(gh issue create --title "$title" --body-file "$body" ${args[@]+"${args[@]}"})" || return
  if ! n="$(url_number issues "$out")"; then
    printf 'gh issue create printed no issue URL: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$n"
}

# adapter_issue_body_edit <n> <file>: replaces the issue's body with the
# file's contents. Prints nothing.
adapter_issue_body_edit() {
  gh issue edit "$1" --body-file "$2" >/dev/null
}

# adapter_issue_comment <n> <file>: posts the file's contents as a comment on
# the issue. Prints nothing.
adapter_issue_comment() {
  gh issue comment "$1" --body-file "$2" >/dev/null
}

# adapter_issue_relabel <n> [--add <label>]... [--remove <label>]...: one edit
# adding and removing the labels named; with none named, no edit at all.
# Prints nothing.
adapter_issue_relabel() {
  local n="$1" args=() adds=() removes=() l options="--add --remove"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --add)    option_value adapter_issue_relabel "$options" "$@" || return; adds+=("$2"); shift 2 ;;
      --remove) option_value adapter_issue_relabel "$options" "$@" || return; removes+=("$2"); shift 2 ;;
      *) unknown_option adapter_issue_relabel "$1"; return ;;
    esac
  done
  [ ${#adds[@]} -gt 0 ] || [ ${#removes[@]} -gt 0 ] || return 0
  for l in ${removes[@]+"${removes[@]}"}; do args+=(--remove-label "$l"); done
  for l in ${adds[@]+"${adds[@]}"}; do args+=(--add-label "$l"); done
  gh issue edit "$n" "${args[@]}" >/dev/null
}

# adapter_issue_close <n> [--reason <r>] [--comment <c>] [--duplicate-of <B>]:
# closes the issue, reason "completed" or "not planned" (absent, gh's
# default), or as a duplicate of issue <B> - never given with --reason, and
# needing gh 2.102 or newer - posting the comment on it where one is given.
# Prints nothing.
adapter_issue_close() {
  local n="$1" reason="" comment="" duplicate_of="" args=() options="--reason --comment --duplicate-of"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)       option_value adapter_issue_close "$options" "$@" || return; reason="$2"; shift 2 ;;
      --comment)      option_value adapter_issue_close "$options" "$@" || return; comment="$2"; shift 2 ;;
      --duplicate-of) option_value adapter_issue_close "$options" "$@" || return; duplicate_of="$2"; shift 2 ;;
      *) unknown_option adapter_issue_close "$1"; return ;;
    esac
  done
  [ -z "$reason" ] || args+=(--reason "$reason")
  [ -z "$comment" ] || args+=(--comment "$comment")
  [ -z "$duplicate_of" ] || args+=(--duplicate-of "$duplicate_of")
  gh issue close "$n" ${args[@]+"${args[@]}"} >/dev/null
}

# adapter_issue_reopen <n>: reopens the issue. Prints nothing.
adapter_issue_reopen() {
  gh issue reopen "$1" >/dev/null
}

# --- pr operations ---

# adapter_pr_create <base> <head> <title> <body-file> [--draft]: opens the PR
# from head into base - a draft under --draft - and prints its number alone.
# Fails, printing nothing, where gh succeeded but printed no PR URL.
adapter_pr_create() {
  local base="$1" head="$2" title="$3" body="$4" args=() out n
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) args+=(--draft); shift ;;
      *) unknown_option adapter_pr_create "$1"; return ;;
    esac
  done
  out="$(gh pr create ${args[@]+"${args[@]}"} --base "$base" --head "$head" --title "$title" --body-file "$body")" || return
  if ! n="$(url_number pull "$out")"; then
    printf 'gh pr create printed no PR URL: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$n"
}

# adapter_pr_body <n>: the PR's body as GitHub holds it, then a newline.
adapter_pr_body() {
  gh pr view "$1" --json body --jq .body
}

# adapter_pr_comments <n>: the PR's comments in COMMENTS_JQ's shape, as
# adapter_issue_comments prints an issue's (issue #418).
adapter_pr_comments() {
  gh pr view "$1" --json comments --jq "$COMMENTS_JQ"
}

# adapter_pr_refs <n>: review ci's read of the PR's own head, base and commits
# (issues #475, #476) - the SHA and branch its grace is anchored to, and the
# commits its CI-evidence pre-check reads, come from the PR, not from local
# HEAD, which can be anywhere by the time the loop ends. Prints the head SHA,
# the head branch and the base branch on the first three lines, an empty line
# for one GitHub leaves unset, then one commit SHA per line, oldest first.
adapter_pr_refs() {
  gh pr view "$1" --json headRefOid,headRefName,baseRefName,commits \
    --jq '(.headRefOid // ""), (.headRefName // ""), (.baseRefName // ""), ((.commits // [])[].oid)'
}

# adapter_pr_ready <n>: marks the draft PR ready for review. Prints nothing.
adapter_pr_ready() {
  gh pr ready "$1" >/dev/null
}

# adapter_pr_draft <n>: turns the ready PR back into a draft (issue #967).
# Prints nothing.
adapter_pr_draft() {
  gh pr ready "$1" --undo >/dev/null
}

# adapter_pr_state_draft <n>: the PR's state - OPEN, CLOSED or MERGED - on the
# first line, then true or false, whether it is a draft.
adapter_pr_state_draft() {
  gh pr view "$1" --json state,isDraft --jq '.state, .isDraft'
}

# adapter_prs_open <head> [base]: the open PRs from the head branch - into the
# base branch, where one is named - one number per line, newest first.
adapter_prs_open() {
  local args=(--head "$1")
  [ -z "${2:-}" ] || args+=(--base "$2")
  gh pr list "${args[@]}" --state open --json number --jq '.[].number'
}

# adapter_prs_merged <head> <base>: the PRs from the head branch merged into
# the base branch, one number per line, newest first - the finished sweep's
# read for a quick implementation, which records no PR of its own. GitHub
# reports a squash or rebase merge as merged too, which git ancestry never
# would.
adapter_prs_merged() {
  gh pr list --head "$1" --base "$2" --state merged --json number --jq '.[].number'
}

# adapter_prs_merged_bodies <base>: the body of every PR merged into the base
# branch, each followed by a newline - pr release reads its issue references
# out of them (issue #139).
adapter_prs_merged_bodies() {
  gh pr list --base "$1" --state merged --limit "$ISSUE_LIST_LIMIT" --json body --jq '.[].body'
}

# adapter_pr_close <n> <comment>: closes the PR, posting the comment on it.
# Prints nothing.
adapter_pr_close() {
  gh pr close "$1" --comment "$2" >/dev/null
}

# adapter_pr_comment <n> <file>: posts the file's contents as a comment on the
# PR (issue #343). Prints nothing.
adapter_pr_comment() {
  gh pr comment "$1" --body-file "$2" >/dev/null
}

# adapter_pr_body_edit <n> <file>: replaces the PR's body with the file's
# contents (issue #444). Prints nothing.
adapter_pr_body_edit() {
  gh pr edit "$1" --body-file "$2" >/dev/null
}

# --- sub-issue and dependency operations ---

# issue_api_id <n>: issue #n's GitHub database id, which the sub-issue and
# blocked-by writes below take in place of its number. Shared by those
# operations; not called from anywhere else.
issue_api_id() {
  gh api "repos/{owner}/{repo}/issues/$1" --jq .id
}

# A parent's sub-issues as adapter_sub_issues prints them. GitHub can leave
# the dependency summary off an issue; its blocker field is then empty rather
# than a count, so `ticket next` does not read it as unblocked.
SUB_ISSUES_JQ='.[] | "\(.number)\t\(.state | ascii_upcase)\t\(.issue_dependencies_summary.blocked_by // "")"'

# adapter_sub_issues <parent>: every sub-issue of the parent, open or closed,
# in the order GitHub published them, one per line as TSV:
# "<n><TAB><OPEN|CLOSED><TAB><open blockers>" - the count of its blockers that
# are still open, or empty where GitHub gave no dependency summary. Nothing
# at all for a parent with none.
adapter_sub_issues() {
  gh api --paginate "repos/{owner}/{repo}/issues/$1/sub_issues" --jq "$SUB_ISSUES_JQ"
}

# adapter_sub_issue_link <parent> <child>: links the child as a sub-issue of
# the parent. Prints nothing.
adapter_sub_issue_link() {
  local id
  id="$(issue_api_id "$2")" || return
  gh api --method POST "repos/{owner}/{repo}/issues/$1/sub_issues" -F sub_issue_id="$id" >/dev/null
}

# adapter_sub_issue_unlink <parent> <child>: unlinks the child from the
# parent's sub-issues. Prints nothing.
adapter_sub_issue_unlink() {
  local id
  id="$(issue_api_id "$2")" || return
  gh api --method DELETE "repos/{owner}/{repo}/issues/$1/sub_issue" -F sub_issue_id="$id" >/dev/null
}

# adapter_issue_parent <n>: the number of the issue #n is a sub-issue of, or
# nothing at all where it is none. Read from the issue's own parent_issue_url
# rather than the /parent endpoint, whose "no parent" is a 404 indistinguishable
# by exit status from a missing issue: here every gh failure is a real one.
# GitHub omits the key on an issue with no parent, so an absent key and a null
# one both mean none. Fails where the URL carries no issue number.
adapter_issue_parent() {
  local url n
  url="$(gh api "repos/{owner}/{repo}/issues/$1" --jq '.parent_issue_url // empty')" || return
  [ -n "$url" ] || return 0
  n="${url##*/}"
  case "$n" in
    ''|*[!0-9]*)
      printf 'gh api printed a parent URL with no issue number: %s\n' "$url" >&2
      return 1 ;;
  esac
  printf '%s\n' "$n"
}

# adapter_blockers <n>: the issues #n is blocked by, open or closed, one number
# per line, in GitHub's order. Nothing at all for none.
adapter_blockers() {
  gh api --paginate "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by" --jq '.[].number'
}

# adapter_blocker_add <n> <blocker>: adds the edge marking #n blocked by the
# blocker. Prints nothing.
adapter_blocker_add() {
  local id
  id="$(issue_api_id "$2")" || return
  gh api --method POST "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by" -F issue_id="$id" >/dev/null
}

# adapter_blocker_remove <n> <blocker>: removes the edge marking #n blocked by
# the blocker. Prints nothing.
adapter_blocker_remove() {
  local id
  id="$(issue_api_id "$2")" || return
  gh api --method DELETE "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by/$id" >/dev/null
}

# adapter_sub_issues_supported: whether this GitHub answers the sub-issues
# endpoint, asked of the repo's most recent issue: "yes" where it answers,
# "no" only where the endpoint answers HTTP 404, nothing at all where the repo
# has no issue to ask it of. Every other failure - of the issue listing, or of
# the endpoint with any other status (401, 403, 410, 5xx) or no connection -
# fails it, passing gh's stderr through.
adapter_sub_issues_supported() {
  local n err rc=0
  n="$(gh issue list --state all --limit 1 --json number --jq '.[0].number // empty')" || return
  [ -n "$n" ] || return 0
  err="$(gh api "repos/{owner}/{repo}/issues/$n/sub_issues" 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'yes\n'; return 0; fi
  case "$err" in
    *"HTTP 404"*) printf 'no\n'; return 0 ;;
  esac
  [ -z "$err" ] || printf '%s\n' "$err" >&2
  return "$rc"
}

# --- repo operations ---

# adapter_repo_default_branch <repo>: the default branch of the repo, named
# [HOST/]OWNER/REPO, as a bare branch name on one line. The repo goes in gh's
# argv because `gh repo view` ignores GH_REPO and would otherwise read gh's own
# default repo. The answer is gh's stdout as is: a caller validates it.
adapter_repo_default_branch() {
  gh repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
}

# adapter_repo_local_default: gh's own default repo for this checkout, as the
# bare OWNER/REPO gh prints even for one off github.com, read from local git
# config, so no network is needed. Nothing at all where none is set: gh says so
# on stderr, exiting 0.
adapter_repo_local_default() {
  gh repo set-default --view
}

# adapter_auth_status: succeeds where gh is authenticated to the host,
# printing gh's own report; fails where it is not, or cannot tell, with gh's
# report passed through - its text is the only signal telling "not
# authenticated" from "could not connect".
adapter_auth_status() {
  gh auth status
}

# --- ci operations ---

# adapter_pr_checks <n> <required|all>: the PR's checks - the ones branch
# protection requires, or every check on its head - one per line as TSV,
# "<bucket><TAB><name><TAB><link>", in gh's order; an empty link for a check
# that has none. Nothing at all on stdout where gh reports no checks, or no
# required ones, with gh's line passed through on stderr. gh documents exit
# 8 for pending checks, still answering the JSON: that is read like an exit
# 0, and where it leaves nothing readable, a single pending check with no
# name or link is printed. Fails where gh answered with something jq cannot
# read.
adapter_pr_checks() {
  local args=("$1") err out tsv st=0
  [ "$2" != required ] || args+=(--required)
  capture out err gh pr checks "${args[@]}" --json bucket,name,link || st=$?
  case "$st" in
    0|8) ;;
    *)
      ! grep -q 'no checks reported\|no required checks' <<<"$err" || st=0
      printf '%s' "$err" >&2
      return "$st" ;;
  esac
  if ! tsv="$(printf '%s' "$out" | jq -r '.[] | "\(.bucket)\t\(.name)\t\(.link // "")"' 2>/dev/null)"; then
    if [ "$st" = 8 ]; then printf 'pending\t\t\n'; return 0; fi
    printf 'gh pr checks answered with something jq could not read\n' >&2
    return 1
  fi
  if [ -z "$tsv" ]; then
    [ "$st" != 8 ] || printf 'pending\t\t\n'
    return 0
  fi
  printf '%s\n' "$tsv"
}

# ci_api_read <what> <path> <jq>: one gh api read, its JSON answer run through
# the jq expression. On a gh failure, gh's stderr passes through - except
# where <what> is given and gh's answer names it: GitHub's message for an
# absence it reports as an error, which succeeds printing nothing. Shared by the
# CI-evidence operations below; not called from anywhere else.
ci_api_read() {
  local err out res st=0
  capture out err gh api "$2" || st=$?
  if [ "$st" != 0 ]; then
    if [ -n "$1" ] && grep -qF -- "$1" <<<"$out"$'\n'"$err"; then
      return 0
    fi
    printf '%s' "$err" >&2
    return "$st"
  fi
  if ! res="$(printf '%s' "$out" | jq -r "$3" 2>/dev/null)"; then
    printf 'gh api answered with something jq could not read\n' >&2
    return 1
  fi
  [ -z "$res" ] || printf '%s\n' "$res"
}

# review ci's CI-evidence reads (issue #476). None of them decides anything:
# no_ci_evidence judges what they print.
#
# adapter_branch_required_checks <branch>: the check contexts classic branch
# protection requires on the branch, one per line, each once. Nothing at all
# for an unprotected branch - GitHub's 404 `Branch not protected`. Any other
# failure, a bare 404 `Not Found` from lacking access included, fails it.
adapter_branch_required_checks() {
  ci_api_read 'Branch not protected' \
    "repos/{owner}/{repo}/branches/$1/protection/required_status_checks" \
    '[(.contexts // [])[], ((.checks // [])[] | .context)] | unique | .[]'
}

# adapter_branch_rules <branch>: the type of every rule the repo's rulesets
# apply to the branch, one per line; nothing at all for none.
adapter_branch_rules() {
  ci_api_read '' "repos/{owner}/{repo}/rules/branches/$1" '.[].type'
}

# adapter_commit_has_check_runs <ref>: "yes" where the commit (a SHA, or a
# branch name for its tip) has any check run, "no" where it has none.
adapter_commit_has_check_runs() {
  ci_api_read '' "repos/{owner}/{repo}/commits/$1/check-runs?per_page=1" \
    'if .total_count == 0 then "no" else "yes" end'
}

# adapter_commit_has_statuses <ref>: "yes" where the commit has any commit
# status, "no" where it has none.
adapter_commit_has_statuses() {
  ci_api_read '' "repos/{owner}/{repo}/commits/$1/status" \
    'if .total_count == 0 then "no" else "yes" end'
}

# adapter_run_rerun <run>: reruns the failed jobs of GitHub Actions run <run>
# (issue #525). Prints nothing.
adapter_run_rerun() {
  gh run rerun "$1" --failed >/dev/null
}

if [ -n "${ORCH_GH_ADAPTER:-}" ]; then
  # shellcheck disable=SC1090 # the adapter path is chosen at run time, by tests
  source "$ORCH_GH_ADAPTER"
fi
