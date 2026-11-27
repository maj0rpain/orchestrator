# shellcheck shell=bash
# gh.sh - the gh adapter layer (ADR-0033): gh(), the guard every GitHub call
# goes through, the failure contract its callers die by (gh_reason, gh_die,
# gh_or_die, gh_capture, gh_capture_err), every adapter_*
# operation, the out-variable readers over the multi-field ones, the JQ
# constants they read, and the GitHub limit record its limit handler makes in
# an autopilot process. It does not render: rendering happens in the Comments
# module, after the Trust filter.
# It stays whole, whoever calls each operation, and ends with the
# ORCH_GH_ADAPTER hook, so a test adapter overrides the real operations.
# Its tests: scripts/test/orch/gh.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The guard every GitHub call in orch.sh and its modules goes through by name
# (#520): `gh` itself, defined ahead of the ORCH_GH_ADAPTER seam so a test
# adapter picks it up. On use it resolves the repo and exports it as GH_REPO -
# with GH_HOST beside it, by repo_gh_host's one rule, whenever the repo itself
# decides its host - so the call - `gh api`'s {owner}/{repo} placeholders and
# host included - is pinned to it, never to gh's own default repo, which in a
# fork is the upstream. The export lives in the shell the guard runs in. The
# memo lives in the shell that resolves (repo_resolve) - usually the caller's,
# through gh_capture/gh_capture_err or a `repo_resolve || :` ahead of a
# substitution, before the guard's subshell forks - and every subshell that
# shell forks afterwards inherits it; a subshell that resolves first resolves
# once for itself and cannot hand the memo back. With no repo it dies
# naming GH_REPO; that death exits 1 whatever the command reserved, so a command
# that reserves exit 1 for a "no" resolves the repo itself first (repo_pin, then
# die2 with REPO_REMEDY). Inside a command substitution `die` would end only
# that subshell, and its message could land in a 2>/dev/null, so there it
# signals the main shell, whose USR1 trap dies with the remedy instead. A failed
# call goes through gh_limit_retry, and is retried once on a first secondary
# limit; the call it makes is the only one to the real gh binary in orch.sh
# and its modules.
#
# A compound write declares itself, as the quota read does, by a marker the
# guard reads - never by gh's argv (ADR-0033): the operation's own gh call is
# prefixed GH_LIMIT_COMPOUND=1, which covers that call alone, and no later
# call inherits it. A call must declare itself compound when it can land a
# write a rerun would duplicate or trip over before a later request of the
# same call is limited (a close that posts its comment first, a PR created
# before its labels are added). A harmlessly repeated write, such as
# relabelling, does not declare, and keeps the retry. A compound write that
# meets a first secondary limit is given up on at once, as a limit met again
# after the retry; a primary limit is handled as on any other call (the
# rate-limit message in place of gh's stderr, and the reset recorded in an
# autopilot process); only a failure that is no limit passes through untouched.
gh() {
  if ! repo_pin; then
    if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then kill -USR1 "$$"; exit 1; fi
    die "$REPO_REMEDY"
  fi
  gh_limit_retry command gh "$@"
}

# gh_capture <out-var> <err-var> <command...> and gh_capture_err <err-var>
# <command...>: capture and capture_err for a GitHub operation - an adapter_*
# operation, gh itself, or a function or whole command whose first GitHub call
# would otherwise resolve the Repo in the capture's subshell.
# Each runs the memoising resolver (repo_resolve) in the caller's shell first,
# ignoring its status, so the Repo is resolved once for the shell that calls
# it, rather than once per subshell the call runs in; a failed resolution is
# left to the guard, which dies with the remedy as it always did.
# Defined ahead of the ORCH_GH_ADAPTER seam. A command that reaches no GitHub
# goes through capture or capture_err.
gh_capture() {
  repo_resolve || :
  capture "$@"
}
gh_capture_err() {
  repo_resolve || :
  capture_err "$@"
}

# gh_limit_retry <command>...: runs <command>, its stdout and stderr held in
# temp files, through the limit retry protocol (#2724) - the one copy of it: a
# failed call goes through gh_limit_handle, a first secondary limit (status 2)
# is retried once, a limit given up on (status 1) fails the call with the
# handler's message in place of the command's stderr - and any other failure
# keeps its stderr as it is. The command's status passes through, and so does
# the stdout of the deciding attempt alone - the one whose outcome the call
# returns - byte for byte from its file, never through a shell variable; an
# attempt that is retried leaves nothing with the caller. Both files are
# removed on every way out. While GH_LIMIT_READING is set the handler is never
# called and nothing is retried; while GH_LIMIT_COMPOUND is set (the guard's
# compound-write marker) a first secondary limit is given up on, not retried.
gh_limit_retry() {
  local errf outf out_st err rc retried=0 spent given_up=0
  temp_file_make errf || die "could not create a temp file for the command's stderr"
  temp_file_make outf || { rm -f "$errf"; die "could not create a temp file for the command's stdout"; }
  while :; do
    out_st=0
    "$@" >"$outf" 2>"$errf" || out_st=$?
    err="$(cat "$errf")"
    if [ "$out_st" -eq 0 ] || [ -n "${GH_LIMIT_READING:-}" ]; then break; fi
    rc=0
    spent="$retried"
    [ -z "${GH_LIMIT_COMPOUND:-}" ] || spent=1
    gh_limit_handle "$err" "$spent" || rc=$?
    if [ "$rc" -eq 2 ]; then retried=1; continue; fi
    if [ "$rc" -eq 1 ]; then given_up=1; break; fi
    break
  done
  cat "$outf"
  [ "$given_up" -eq 1 ] || [ -z "$err" ] || printf '%s\n' "$err" >&2
  rm -f "$errf" "$outf"
  return "$out_st"
}

# --- GitHub API rate limits (#2577) -------------------------------------------
#
# gh_limit_handle is the one limit handler: the guard calls it on a failed
# call, and the test fake's failing operations call it too. It never dies: the
# failed call returns its own status, with the distinct message on stderr.

# gh_limit_kind <stderr>: secondary for GitHub's secondary-limit wording,
# "submitted too quickly" or an HTTP 429; primary for its primary-limit
# wording; nothing for any other failure.
gh_limit_kind() {
  if grep -qiE 'secondary rate limit|submitted too quickly|HTTP 429' <<<"$1"; then
    echo secondary
  elif grep -qiE 'API rate limit (already )?exceeded' <<<"$1"; then
    echo primary
  fi
}

# gh_limit_pools: GitHub's core and graphql pools, one per line as
# "<pool> <remaining> <limit> <reset>", the reset in epoch seconds; fails,
# printing nothing, when the read fails or is empty. The one quiet read of the
# pools: it runs with GH_LIMIT_READING set, so the guard neither retries it nor
# calls the limit handler, its stderr is discarded, and it costs no quota.
gh_limit_pools() {
  local out
  out="$(GH_LIMIT_READING=1 adapter_rate_limit 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  tr '\t' ' ' <<<"$out"
}

# gh_limit_reset: the epoch second a limit is waited out until: the latest
# reset among the core and graphql pools at 0 remaining; with none, or a failed
# read of the pools, 15 minutes from now.
gh_limit_reset() {
  local pools reset
  repo_resolve || :
  pools="$(gh_limit_pools)" || pools=""
  reset="$(awk '$2 == 0 && $4 + 0 > m { m = $4 + 0 } END { if (m) print m }' <<<"$pools")"
  printf '%s\n' "${reset:-$(($(date +%s) + 900))}"
}

# gh_limit_handle <stderr> <retry spent>: what a failed call's <stderr> means.
# Status 0: no limit - the caller passes its failure through untouched.
# Status 2: a first secondary limit, waited out (ORCH_GH_LIMIT_WAIT seconds,
# default 60) - the caller retries once and calls this again with
# <retry spent> 1.
# Status 1: a limit to give up on - a primary one, a secondary one met again
# after the retry, or a first secondary one on a compound write (never
# retried, so called with <retry spent> 1), handled as a primary one. The
# distinct message, naming the
# reset, is on stderr; in an autopilot process the reset is also recorded
# (autopilot_github_limit_record), and a failed write is part of that same one
# line, after " - " with its clauses joined by "; ", so gh_reason keeps it.
gh_limit_handle() {
  local kind reset clauses="" clause msg
  kind="$(gh_limit_kind "$1")"
  [ -n "$kind" ] || return 0
  if [ "$kind" = secondary ] && [ "$2" = 0 ]; then
    sleep "${ORCH_GH_LIMIT_WAIT:-60}"
    return 2
  fi
  reset="$(gh_limit_reset)"
  msg="GitHub API rate limit reached - it resets at $(autopilot_epoch_iso "$reset"). An autopilot session ends its turn now and does not retry; the watcher picks the work up after the reset."
  while IFS= read -r clause; do
    [ -z "$clause" ] || clauses="${clauses:+$clauses; }$clause"
  done < <(autopilot_github_limit_record "$reset")
  [ -z "$clauses" ] || msg="$msg - $clauses"
  warn "$msg"
  return 1
}

# --- the GitHub limit record (#2577) -----------------------------------------
#
# What gh_limit_handle records in an autopilot process: the GitHub limit pause
# under the main checkout, and a session's hit file. The pause file's format is
# pinned to the Python limit record by scripts/orch_py/tests/github_pause/. The
# autopilot noun, converted, reads and extends the same files through
# orch/autopilot.py's pause_* functions.

# The most seconds ahead a recorded GitHub reset is held: GitHub's rate limits
# reset hourly, so none names a later one (#3684).
AUTOPILOT_GITHUB_PAUSE_MAX=3600

# autopilot_dir <main-root>: where a clone's autopilot files live - the run
# records, the session logs, the limit files (limit, github-limit,
# github-early-<pool>), the housekeeping stamp (housekeeping) and the per-issue
# hit marks - under its main checkout.
autopilot_dir() { printf '%s/%s/autopilot\n' "$1" "$ORCH_DIR_NAME"; }

# autopilot_epoch_iso <epoch>: epoch seconds as a UTC timestamp, GNU or BSD
# date.
autopilot_epoch_iso() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ
}

# autopilot_iso_epoch <YYYY-MM-DDTHH:MM:SSZ>: the UTC timestamp as epoch
# seconds, GNU or BSD date; non-zero for a value neither reads.
autopilot_iso_epoch() {
  date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null
}

# autopilot_pause_epoch <file>: the reset recorded in the limit file <file> as
# epoch seconds; 0 when the file is missing or its text does not parse.
autopilot_pause_epoch() {
  local text
  text="$(cat "$1" 2>/dev/null)" || text=""
  autopilot_iso_epoch "$text" || echo 0
}

# autopilot_pause_put <file> <epoch>: records <epoch> (epoch seconds) in <file>
# as one UTC ISO timestamp, keeping a reset already there that is later and
# replacing one that is earlier or does not parse. Fails, silently, when the
# file cannot be written.
autopilot_pause_put() {
  local file="$1" new_epoch="$2" old_epoch
  if [ -f "$file" ]; then
    old_epoch="$(autopilot_pause_epoch "$file")"
    [ "$old_epoch" -lt "$new_epoch" ] || return 0
  fi
  { mkdir -p "$(dirname "$file")" && autopilot_epoch_iso "$new_epoch" >"$file"; } 2>/dev/null
}

# autopilot_github_pause_file <main>: the GitHub limit file under <main>, the
# pause a GitHub API rate limit writes (#2577).
autopilot_github_pause_file() { printf '%s/github-limit\n' "$(autopilot_dir "$1")"; }

# autopilot_github_reset_cap <epoch>: prints <epoch>, or now plus
# AUTOPILOT_GITHUB_PAUSE_MAX when <epoch> is further ahead. Every GitHub writer
# caps its reset through it; the usage limit file is never capped.
autopilot_github_reset_cap() {
  local max
  max=$(( $(date +%s) + AUTOPILOT_GITHUB_PAUSE_MAX ))
  if [ "$1" -gt "$max" ]; then echo "$max"; else echo "$1"; fi
}

# autopilot_github_limit_record <reset>: in an autopilot process - a tick or the
# session wrapper, each by a flag of its own, or a session (ORCH_AUTOPILOT=1) -
# writes the GitHub pause, its reset capped at an hour from now, extended only
# to the later of two resets; in a
# session, which has the wrapper's hit file path, writes the reset there too. An
# interactive call writes and prints nothing. Never fails and never warns: each
# write that fails prints one clause on stdout, for gh_limit_handle to join onto
# its one limit line.
autopilot_github_limit_record() {
  local main_root reset
  autopilot_active || [ -n "${ORCH_AUTOPILOT_TICK:-}${ORCH_AUTOPILOT_RUN:-}" ] || return 0
  reset="$(autopilot_github_reset_cap "$1")"
  if main_root="$(main_checkout_or_die 2>/dev/null)" && [ -n "$main_root" ]; then
    autopilot_pause_put "$(autopilot_github_pause_file "$main_root")" "$reset" ||
      echo "could not write the GitHub limit pause under $main_root"
  else
    echo "could not write the GitHub limit pause: the main checkout is unreadable"
  fi
  if autopilot_active && [ -n "${ORCH_AUTOPILOT_HIT_FILE:-}" ]; then
    autopilot_pause_put "$ORCH_AUTOPILOT_HIT_FILE" "$reset" ||
      echo "could not write the GitHub limit hit file $ORCH_AUTOPILOT_HIT_FILE"
  fi
  return 0
}

# label_listed <labels> <label>: whether <label> is one of the newline-separated
# <labels>, matched whole-line, literally and case-insensitively: GitHub's label
# names are case-insensitive, and it attaches a label in the repo's existing
# casing. The one label-membership test; list_has is its case-sensitive sibling
# for what is not a label. It matches in bash, starting no command, and folds
# ASCII case only, whatever the caller's locale: both sides are lower-cased
# under a function-local LC_ALL=C, so a Turkish locale's I never folds to a
# dotless i and a non-ASCII letter stays as it is.
label_listed() {
  local LC_ALL=C
  local _ll_list="${1,,}" _ll_item="${2,,}"
  list_has "$_ll_list" "$_ll_item"
}

# --- gh failure contract (#1022) ----------------------------------------------
#
# How a caller reacts to a failed adapter operation. gh_reason cuts gh's stderr
# to a reason; gh_die is the one place the dying message is built; gh_or_die
# runs an operation and dies through gh_die when it fails. A site that reacts
# another way - a warning, a verdict - calls gh_reason itself.

# gh_reason <stderr>: the reason a failed gh call gives - the first line of
# its captured stderr, or "gh gave no reason" when that line is empty, so a
# death message never ends in a bare colon. It only produces the reason; each
# site keeps its own die, die2, warn or why.
gh_reason() {
  local line="${1%%$'\n'*}"
  printf '%s\n' "${line:-gh gave no reason}"
}

# gh_die [--exit 2] [--hint <text>] <what> <stderr>: dies with
# "gh could not <what>: <gh_reason of stderr>", then " - <hint>" when a hint is
# given - through die, or through die2 under --exit 2. A bad option dies with
# status 1, naming it, through die_opt_check.
gh_die() {
  local opts=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --exit|--hint)
        die_opt_check gh_die $# "$@"
        opts+=("$1" "$2"); shift 2 ;;
      -*) die "gh_die: unknown option $1" ;;
      *) break ;;
    esac
  done
  die_hinted ${opts[@]+"${opts[@]}"} "gh could not $1: $(gh_reason "${2-}")"
}

# gh_or_die [--exit 2] [--hint <text>] [--out <var> | --file <path>] <what>
# <op> [args...]: resolves the Repo in the caller's shell, then runs the
# operation through gh_capture/gh_capture_err - so in their
# subshell, and the gh guard's no-repo death still reaches the real stderr -
# and on failure dies through gh_die with the same --exit and --hint. Those
# are checked through die_opt_check before the operation runs, so a bad one
# dies with status 1, naming gh_or_die, and the operation never runs.
# --out <var> assigns the operation's stdout to the caller's variable (trailing
# newlines gone, as capture reads it). --file <path> streams it into a temp
# file beside the target, creating the target's directory, and moves it into
# place only on success, byte for byte: a failure removes the temp file and
# leaves an existing target untouched. With neither, stdout is left to the
# caller's own redirect. --out with --file, an --out or --file with no value,
# or an unknown option, dies naming it, with status 1 whatever --exit says.
# Inside $(...), --out cannot set a variable outside the subshell, and a
# death ends only the subshell, so the caller must pass its status on. Its
# locals are prefixed so no caller's variable is shadowed.
gh_or_die() {
  local _gh_or_die_die_opts=() _gh_or_die_out="" _gh_or_die_file=""
  local _gh_or_die_text _gh_or_die_err _gh_or_die_tmp _gh_or_die_st=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --exit|--hint)
        # gh_die's own options: checked now, passed on to gh_die.
        die_opt_check gh_or_die $# "$@"
        _gh_or_die_die_opts+=("$1" "$2")
        shift 2 ;;
      --out|--file)
        [ -n "${2-}" ] || die "gh_or_die: $1 needs a value"
        if [ "$1" = --out ]; then _gh_or_die_out="$2"; else _gh_or_die_file="$2"; fi
        shift 2 ;;
      -*) die "gh_or_die: unknown option $1" ;;
      *) break ;;
    esac
  done
  if [ -n "$_gh_or_die_out" ] && [ -n "$_gh_or_die_file" ]; then
    die "gh_or_die: --out and --file cannot be given together"
  fi
  [ $# -ge 2 ] || die "gh_or_die: needs <what> and an operation"
  if [ -n "$_gh_or_die_out" ]; then
    gh_capture _gh_or_die_text _gh_or_die_err "${@:2}" || _gh_or_die_st=$?
    [ "$_gh_or_die_st" -ne 0 ] || printf -v "$_gh_or_die_out" '%s' "$_gh_or_die_text"
  elif [ -n "$_gh_or_die_file" ]; then
    mkdir -p "$(dirname "$_gh_or_die_file")"
    _gh_or_die_tmp="$(mktemp "$_gh_or_die_file.XXXXXX")" || die "could not create a temp file beside $_gh_or_die_file"
    if gh_capture_err _gh_or_die_err "${@:2}" >"$_gh_or_die_tmp"; then
      mv "$_gh_or_die_tmp" "$_gh_or_die_file"
    else
      _gh_or_die_st=$?
      rm -f "$_gh_or_die_tmp"
    fi
  else
    gh_capture_err _gh_or_die_err "${@:2}" || _gh_or_die_st=$?
  fi
  [ "$_gh_or_die_st" -ne 0 ] || return 0
  gh_die ${_gh_or_die_die_opts[@]+"${_gh_or_die_die_opts[@]}"} "$1" "$_gh_or_die_err"
}

# --- gh adapter -------------------------------------------------------------
#
# The seam between orch.sh's decision logic and the `gh` CLI. A caller like
# base.sh's default-branch lookup calls an adapter operation, never `gh`
# itself, so a test can replace one in-process function instead of faking a
# `gh` binary on PATH. Every GitHub call in orch.sh and its modules goes
# through one. History: begun with labels (#91), issues (#92); all since #280.
#
# The operations, in the order they are defined below:
# - label: adapter_label_upsert, adapter_labels_detail
# - rate limit: adapter_rate_limit
# - issue: adapter_issue_body, adapter_issue_state_labels,
#   adapter_issue_title_labels, adapter_issue_authorship, adapter_issue_state,
#   adapter_issue_created_at, adapter_issues_labelled_rows,
#   adapter_issues_any_labelled_rows,
#   adapter_issues_open_rows, adapter_issues_titled_rows,
#   adapter_issue_body_edit, adapter_issue_comment,
#   adapter_issue_comment_url,
#   adapter_issue_relabel, adapter_issue_close, adapter_issue_reopen
# - pr: adapter_pr_create, adapter_pr_labels, adapter_pr_body,
#   adapter_pr_refs, adapter_pr_draft,
#   adapter_pr_state_draft, adapter_prs_open, adapter_prs_open_bodies,
#   adapter_prs_open_mergeability,
#   adapter_pr_diff, adapter_prs_merged,
#   adapter_prs_merged_closing, adapter_prs_merged_bodies, adapter_pr_close,
#   adapter_pr_comment,
#   adapter_pr_body_edit, adapter_pr_title_edit, adapter_pr_label_add
# - sub-issue and dependency: adapter_sub_issues, adapter_sub_issue_link,
#   adapter_sub_issue_unlink, adapter_issue_parent, adapter_blockers,
#   adapter_issue_open_blockers, adapter_blockers_states,
#   adapter_blocker_add, adapter_blocker_remove
# - repo: adapter_repo_default_branch
#
# ORCH_GH_ADAPTER is an opt-in test knob in the same spirit as review ci's
# ORCH_CI_* ones, but read differently: not a value substituted at load time,
# but a file sourced immediately after the real adapter functions are defined:
# anything it redefines overrides the corresponding real function for the
# rest of the process, and anything it leaves alone keeps shelling out to the
# real `gh` below. Unset - every normal run - nothing is sourced and behaviour
# is identical to before the seam existed.
#
# Operations under the #280 contract - the label, issue, PR, sub-issue and
# dependency, and repo ones - are named for what their callers need and own
# gh's flags, --jq and GitHub's database ids: each prints plain text in the
# shape documented on it, and on a gh failure returns non-zero with gh's stderr
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
# `option_value <operation> "<option-names>" "$@" || return` from an option
# loop.
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

# adapter_labels_detail <limit>: the repo's labels, at most <limit> of them, one
# per line as `name<TAB>colour<TAB>description` (colour without a leading #,
# description possibly empty). Nothing at all for a repo with none.
adapter_labels_detail() {
  gh label list --limit "$1" --json name,color,description \
    --jq '.[] | [.name, .color, (.description // "")] | @tsv'
}

# adapter_rate_limit: GitHub's rate-limit pools, the core (REST) and graphql
# ones, one per line as "<pool><TAB><remaining><TAB><limit><TAB><reset>", the
# reset in epoch seconds. The read does not count against the primary limit.
adapter_rate_limit() {
  gh api rate_limit --jq '.resources | {core, graphql} | to_entries[] | [.key, .value.remaining, .value.limit, .value.reset] | @tsv'
}

# --- issue operations ---

# The trimmed issue object the whole-issue adapter prints (#528): the issue's
# number, title and body and its label names - every other field gh answers
# with is dropped, so the shape does not change with gh's version. It carries
# no comments: the Python gh adapter reads them. No bash caller is left:
# `issue fetch --json` is Python now, with its own ISSUE_JSON_JQ in
# orch/gh.py, and the adapter stays as a recorded deviation (#3916).
ISSUE_JSON_JQ='{number, title, body, labels: [.labels[].name]}'

# adapter_issue_body <n>: the issue's body as GitHub holds it, then a newline.
adapter_issue_body() {
  gh issue view "$1" --json body --jq .body
}

# adapter_issue_json <n>: the issue as ISSUE_JSON_JQ's one JSON object, with no
# comments - an operation that prints JSON rather than plain text. It has no
# bash caller left: the Python issue noun joins its own copy with the comments.
adapter_issue_json() {
  gh issue view "$1" --json number,title,body,labels --jq "$ISSUE_JSON_JQ"
}

# adapter_issue_state_labels <n>: OPEN or CLOSED on the first line, then one
# label per line - none at all for an unlabelled issue.
adapter_issue_state_labels() {
  gh issue view "$1" --json state,labels --jq '.state, (.labels[].name)'
}

# gh_lines_read <adapter> <n> <err_var> <var>... <rest-var>: the readers'
# shared contract (#1106), the one the readers below cite. Reads
# <n> once through <adapter> and splits its answer through lines_split into
# the caller-named variables: the first line into the first, and so on, every
# line left into the last. Non-zero when the read fails, writing none of them,
# and writing gh's stderr into <err_var>: the caller keeps its own failure
# message. gh's stderr is captured, never passed through. Out-params through
# `printf -v`, as capture's (which it calls through gh_capture), its locals
# prefixed so no caller's variable name is shadowed.
gh_lines_read() {
  local __glr_out __glr_err
  if ! gh_capture __glr_out __glr_err "$1" "$2"; then
    printf -v "$3" '%s' "$__glr_err"
    return 1
  fi
  lines_split "$__glr_out" "${@:4}"
}

# issue_state_labels_read <n> <state_var> <labels_var> <err_var>: reads issue
# <n> once through adapter_issue_state_labels and writes its state (the first
# line) and its labels (the rest, possibly empty) into the first two
# caller-named variables, on gh_lines_read's contract: non-zero on a failed
# read, writing neither, gh's stderr captured into <err_var>.
issue_state_labels_read() {
  gh_lines_read adapter_issue_state_labels "$1" "$4" "$2" "$3"
}

# gh_issue_not_found <stderr>: whether a failed issue read's captured stderr
# says no issue or pull request has that number - GitHub's own not-found
# answer, as against any other failed read. The one place its wording is
# matched.
gh_issue_not_found() {
  [[ "$1" == *"Could not resolve to an issue or pull request with the number of"* ]]
}

# adapter_issue_title_labels <n>: the title on the first line, then one label
# per line.
adapter_issue_title_labels() {
  gh issue view "$1" --json title,labels --jq '.title, (.labels[].name)'
}

# issue_title_labels_read <n> <title_var> <labels_var> <err_var>: reads issue
# <n> once through adapter_issue_title_labels and writes its title and its
# labels (one per line, possibly none) into the first two caller-named
# variables, on gh_lines_read's contract: non-zero on a failed read,
# writing neither, gh's stderr captured into <err_var>, never passed through.
issue_title_labels_read() {
  gh_lines_read adapter_issue_title_labels "$1" "$4" "$2" "$3"
}

# The GraphQL query and --jq behind adapter_issue_authorship.
# One line, so a logged argv (the gh fixture's) stays one line.
ISSUE_AUTHORSHIP_QUERY='query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { issue(number: $number) { author { login } authorAssociation editor { login } timelineItems(last: 1, itemTypes: [RENAMED_TITLE_EVENT]) { nodes { ... on RenamedTitleEvent { actor { login } } } } } } }'
ISSUE_AUTHORSHIP_JQ='.data.repository.issue | (.author.login // ""), (.authorAssociation // ""), (.editor.login // ""), (.timelineItems.nodes[0].actor.login // "")'

# adapter_issue_authorship <n>: four lines, each possibly empty: the issue
# author's login, the author's authorAssociation, the login of whoever last
# edited the body (the issue's `editor`), and the login of whoever made the
# newest rename of the title (the actor of its newest RenamedTitleEvent). One
# GraphQL read, for the Trust module's reader.
adapter_issue_authorship() {
  gh api graphql -F owner='{owner}' -F name='{repo}' -F number="$1" \
    -f query="$ISSUE_AUTHORSHIP_QUERY" --jq "$ISSUE_AUTHORSHIP_JQ"
}

# adapter_issue_state <n>: OPEN or CLOSED - or PULL where <n> is a pull
# request's number, which gh issue view answers for too.
adapter_issue_state() {
  gh issue view "$1" --json state,url --jq 'if (.url | test("/pull/")) then "PULL" else .state end'
}

# adapter_issue_created_at <n>: issue #n's creation time, a UTC timestamp in
# the form a PR's mergedAt has, so the two compare as strings.
adapter_issue_created_at() {
  gh issue view "$1" --json createdAt --jq '.createdAt'
}

# issue_list_limit_warn <count> <what>: warns on stderr when a listing of
# <what> (e.g. "the open issues labelled needs-human") returned <count> rows,
# reaching its effective limit - the lesser of ISSUE_LIST_LIMIT and 1000,
# GitHub's search cap - and names that limit. Always succeeds.
issue_list_limit_warn() {
  local limit="$ISSUE_LIST_LIMIT"
  [ "$limit" -le "$ISSUE_SEARCH_CAP" ] || limit="$ISSUE_SEARCH_CAP"
  if [ "$1" -ge "$limit" ]; then
    warn "$2 reached the issue-list limit of $limit - the newest past it are missing from this list"
  fi
  return 0
}

# issues_labelled_limit_warn <count> <label>...: issue_list_limit_warn for a
# listing of the open issues carrying every label named. Always succeeds.
issues_labelled_limit_warn() {
  local __illw_n="$1" __illw_what="the open issues labelled $2" __illw_l
  for __illw_l in "${@:3}"; do __illw_what="$__illw_what and $__illw_l"; done
  issue_list_limit_warn "$__illw_n" "$__illw_what"
}

# The plain state record the labelled, any-labelled and open row adapters share:
# --json's field list and --jq's expression for number, state, label count, then
# one label per line. adapter_issues_titled_rows answers its own record, the
# state and title on one line.
readonly ISSUE_STATE_ROWS_JSON=number,state,labels
readonly ISSUE_STATE_ROWS_JQ='.[] | .number, .state, (.labels | length), (.labels[].name)'

# adapter_issues_labelled_rows <label>...: the open issues carrying every label
# named, oldest first and cut at ISSUE_LIST_LIMIT (the newest dropped),
# each as one count-marked record: its number, its state as GitHub answered it,
# its label count, then one label per line. The state is never assumed from the
# listing's own open-only filter.
# shellcheck disable=SC2120 # adapter_issues_open_rows passes no label
adapter_issues_labelled_rows() {
  local args=() l
  for l in "$@"; do args+=(--label "$l"); done
  gh issue list --state open ${args[@]+"${args[@]}"} --search "sort:created-asc" --limit "$ISSUE_LIST_LIMIT" --json "$ISSUE_STATE_ROWS_JSON" --jq "$ISSUE_STATE_ROWS_JQ"
}

# adapter_issues_any_labelled_rows <label>...: the open issues carrying any of
# the labels named, as adapter_issues_labelled_rows prints them: oldest first,
# cut once at ISSUE_LIST_LIMIT across all the labels. GitHub's search takes a
# comma-joined list of quoted labels as an any-of match.
adapter_issues_any_labelled_rows() {
  local any="" l
  for l in "$@"; do any="${any:+$any,}\"$l\""; done
  gh issue list --state open --search "label:$any sort:created-asc" --limit "$ISSUE_LIST_LIMIT" --json "$ISSUE_STATE_ROWS_JSON" --jq "$ISSUE_STATE_ROWS_JQ"
}

# issues_any_labels_phrase <var> <label>...: writes the labels named, joined by
# " or ", into <var>, for an `orch: ` message about an any-of listing.
issues_any_labels_phrase() {
  local __ialp_s="$2" __ialp_l
  for __ialp_l in "${@:3}"; do __ialp_s="$__ialp_s or $__ialp_l"; done
  printf -v "$1" '%s' "$__ialp_s"
}

# issues_any_labelled_limit_warn <count> <label>...: issue_list_limit_warn for a
# listing of the open issues carrying any of the labels named, joined by "or".
# Always succeeds.
issues_any_labelled_limit_warn() {
  local __iall_n="$1" __iall_any
  issues_any_labels_phrase __iall_any "${@:2}"
  issue_list_limit_warn "$__iall_n" "the open issues labelled $__iall_any"
}

# issues_labelled_rows_read <nums_var> <states_array> <labels_array> <err_var>
# <label>...: reads the listing once through adapter_issues_labelled_rows and
# writes the issue numbers, oldest first one per line, into <nums_var>, and adds
# each record's state and labels (one per line, possibly none) to two
# caller-declared associative arrays keyed by issue number. It adds to the
# arrays, never clearing them. Non-zero, writing nothing, on a failed read (gh's
# stderr into <err_var>, as gh_lines_read) or an answer that does not parse
# (<err_var> "gh answered a listing that does not parse"). Warns through
# issues_labelled_limit_warn when the listing reaches the issue-list limit. Dies
# when an array name is not a declared associative array. Elements are assigned
# by eval on a validated name, the value by reference (assoc_pairs_assign).
issues_labelled_rows_read() {
  issues_rows_read_via issues_labelled_rows_read adapter_issues_labelled_rows issues_labelled_limit_warn "$@"
}

# issues_any_labelled_rows_read <nums_var> <states_array> <labels_array>
# <err_var> <label>...: issues_labelled_rows_read for the open issues carrying
# any of the labels, through adapter_issues_any_labelled_rows, its limit warning
# worded by issues_any_labelled_limit_warn.
issues_any_labelled_rows_read() {
  issues_rows_read_via issues_any_labelled_rows_read adapter_issues_any_labelled_rows issues_any_labelled_limit_warn "$@"
}

# adapter_issues_open_rows: every open issue, oldest first and cut at
# ISSUE_LIST_LIMIT, each as the count-marked record adapter_issues_labelled_rows
# answers: number, state as GitHub answered it, label count, one label per line.
# It is that adapter with no labels, kept under its own name so a test can seed
# a failure for this listing alone.
adapter_issues_open_rows() {
  adapter_issues_labelled_rows
}

# issues_open_limit_warn <count>: issue_list_limit_warn for a listing of every
# open issue. Always succeeds.
issues_open_limit_warn() {
  issue_list_limit_warn "$1" "the open issues"
}

# issues_open_rows_read <nums_var> <states_array> <labels_array> <err_var>:
# issues_labelled_rows_read for every open issue, through
# adapter_issues_open_rows, its limit warning worded by issues_open_limit_warn.
issues_open_rows_read() {
  issues_rows_read_via issues_open_rows_read adapter_issues_open_rows issues_open_limit_warn "$@"
}

# adapter_issues_titled_rows <label>: the open issues carrying the label,
# oldest first and cut at ISSUE_LIST_LIMIT (the newest dropped), each as one
# count-marked record: its number, its state as GitHub answered it and its
# title joined by a tab on one line, its label count, then one label per line.
# The state is never assumed from the listing's own open-only filter.
adapter_issues_titled_rows() {
  gh issue list --state open --label "$1" --search "sort:created-asc" --limit "$ISSUE_LIST_LIMIT" --json number,state,title,labels \
    --jq '.[] | .number, (.state + "\t" + .title), (.labels | length), (.labels[].name)'
}

# issues_label_block_read <lines_array> <index_var> <out_var> <count>: reads
# <count> label lines from the indexed array <lines_array>, starting at the
# index <index_var> holds, joins them by newlines into <out_var> and advances
# <index_var> past them. Returns 1, writing nothing, when the lines run out
# before <count>. The array is reached by eval, as bash 4.2 has no namerefs;
# the names are the caller's own locals, passed literally.
issues_label_block_read() {
  local __ilbk_i __ilbk_total __ilbk_j __ilbk_line __ilbk_block=""
  eval "__ilbk_i=\${$2} __ilbk_total=\${#$1[@]}"
  for (( __ilbk_j = 0; __ilbk_j < 10#$4; __ilbk_j++ )); do
    [ "$__ilbk_i" -lt "$__ilbk_total" ] || return 1
    eval "__ilbk_line=\${$1[__ilbk_i]}"
    [ "$__ilbk_j" -eq 0 ] || __ilbk_block="$__ilbk_block"$'\n'
    __ilbk_block="$__ilbk_block$__ilbk_line"
    __ilbk_i=$(( __ilbk_i + 1 ))
  done
  printf -v "$3" '%s' "$__ilbk_block"
  printf -v "$2" '%s' "$__ilbk_i"
}

# assoc_pairs_assign <assoc_array> <keys_array> <values_array>: assigns each
# key and value of the two parallel indexed arrays into the associative array
# <assoc_array>, by eval on a validated name, the value by reference. Dies when
# <assoc_array> is not a declared associative array.
assoc_pairs_assign() {
  assoc_array_require assoc_pairs_assign "$1" __apa_
  local __apa_r __apa_idx
  eval "__apa_idx=(\${$2[@]+\"\${!$2[@]}\"})"
  for __apa_r in ${__apa_idx[@]+"${__apa_idx[@]}"}; do
    eval "$1"'[${'"$2"'[__apa_r]}]=${'"$3"'[__apa_r]}'
  done
}

# issues_rows_read_via <caller> <adapter> <warn> <nums_var> <field_array>
# <labels_array> <err_var> [<label>...]: the reading the readers above
# share (the open-issue reader takes no labels), through the listing <adapter>
# and the limit warning <warn>; <caller> names the public reader in a die
# message.
issues_rows_read_via() {
  assoc_array_require "$1" "$5" __ilrr_
  assoc_array_require "$1" "$6" __ilrr_
  local __ilrr_adapter="$2" __ilrr_warn="$3"
  shift 3
  local __ilrr_out __ilrr_err __ilrr_lines=() __ilrr_nums=() __ilrr_fields=() __ilrr_labs=()
  local __ilrr_i=0 __ilrr_total __ilrr_n __ilrr_field __ilrr_count __ilrr_rl
  local __ilrr_bad="gh answered a listing that does not parse"
  local __ilrr_whole='^[0-9]+$'
  if ! gh_capture __ilrr_out __ilrr_err "$__ilrr_adapter" "${@:5}"; then
    printf -v "$4" '%s' "$__ilrr_err"
    return 1
  fi
  [ -z "$__ilrr_out" ] || mapfile -t __ilrr_lines <<<"$__ilrr_out"
  __ilrr_total="${#__ilrr_lines[@]}"
  while [ "$__ilrr_i" -lt "$__ilrr_total" ]; do
    __ilrr_n="${__ilrr_lines[__ilrr_i]}"
    __ilrr_field="${__ilrr_lines[__ilrr_i+1]-}"
    __ilrr_count="${__ilrr_lines[__ilrr_i+2]-}"
    [[ $__ilrr_n =~ $__ilrr_whole && -n $__ilrr_field && $__ilrr_count =~ $__ilrr_whole ]] \
      || { printf -v "$4" '%s' "$__ilrr_bad"; return 1; }
    __ilrr_i=$(( __ilrr_i + 3 ))
    issues_label_block_read __ilrr_lines __ilrr_i __ilrr_rl "$__ilrr_count" \
      || { printf -v "$4" '%s' "$__ilrr_bad"; return 1; }
    __ilrr_nums+=("$(( 10#$__ilrr_n ))")
    __ilrr_fields+=("$__ilrr_field")
    __ilrr_labs+=("$__ilrr_rl")
  done
  assoc_pairs_assign "$2" __ilrr_nums __ilrr_fields
  assoc_pairs_assign "$3" __ilrr_nums __ilrr_labs
  printf -v "$1" '%s' "$(printf '%s\n' ${__ilrr_nums[@]+"${__ilrr_nums[@]}"} | grep . || true)"
  "$__ilrr_warn" "${#__ilrr_nums[@]}" "${@:5}"
}

# adapter_issues_open_titles: every open issue, one per line as
# <number><TAB><title>, pull requests left out. The listing is paginated, not
# searched or cut at ISSUE_LIST_LIMIT, so the caller's exact comparison sees
# them all. Nothing at all where none is open.
adapter_issues_open_titles() {
  gh api --paginate "repos/{owner}/{repo}/issues?state=open&per_page=100" \
    --jq '.[] | select(has("pull_request") | not) | "\(.number)\t\(.title)"'
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

# adapter_issue_comment_url <n> <file>: posts the file's contents as a comment
# on the issue, as adapter_issue_comment does, and prints the URL gh printed for
# the posted comment; where gh printed none, succeeds printing nothing.
adapter_issue_comment_url() {
  local out
  out="$(gh issue comment "$1" --body-file "$2")" || return
  [ -z "$out" ] || printf '%s\n' "${out%%$'\n'*}"
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

# adapter_issue_close <n> [--reason <r>] [--comment <c>]: closes the issue,
# reason "completed" or "not planned" (absent, gh's default), posting the
# comment on it where one is given.
# Prints nothing. Given a comment it declares its gh call a compound write:
# gh posts the comment first and closes second, so a failed close can leave the
# comment, and a rerun would post it twice.
adapter_issue_close() {
  local n="$1" reason="" comment="" compound="" args=() options="--reason --comment"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason)  option_value adapter_issue_close "$options" "$@" || return; reason="$2"; shift 2 ;;
      --comment) option_value adapter_issue_close "$options" "$@" || return; comment="$2"; shift 2 ;;
      *) unknown_option adapter_issue_close "$1"; return ;;
    esac
  done
  [ -z "$reason" ] || args+=(--reason "$reason")
  [ -z "$comment" ] || { args+=(--comment "$comment"); compound=1; }
  GH_LIMIT_COMPOUND=$compound gh issue close "$n" ${args[@]+"${args[@]}"} >/dev/null
}

# adapter_issue_reopen <n>: reopens the issue. Prints nothing.
adapter_issue_reopen() {
  gh issue reopen "$1" >/dev/null
}

# --- pr operations ---

# adapter_pr_create <base> <head> <title> <body-file> [--draft]
# [--label <name>]...: opens the PR from head into base - a draft under
# --draft, carrying each label named (#1299), passed to gh pr create's --label
# in the order given - and prints its number alone. gh adds the labels in a
# mutation after the create, so the PR can open before they land: given a
# label it declares its gh call a compound write, as a rerun after the PR has
# opened fails with "already exists" for a PR that was in fact opened.
# Fails, printing nothing, where gh succeeded but printed no PR URL.
adapter_pr_create() {
  local base="$1" head="$2" title="$3" body="$4" args=() out n compound="" options="--draft --label"
  shift 4
  while [ $# -gt 0 ]; do
    case "$1" in
      --draft) args+=(--draft); shift ;;
      --label) option_value adapter_pr_create "$options" "$@" || return; args+=(--label "$2"); compound=1; shift 2 ;;
      *) unknown_option adapter_pr_create "$1"; return ;;
    esac
  done
  out="$(GH_LIMIT_COMPOUND=$compound gh pr create ${args[@]+"${args[@]}"} --base "$base" --head "$head" --title "$title" --body-file "$body")" || return
  if ! n="$(url_number pull "$out")"; then
    printf 'gh pr create printed no PR URL: %s\n' "$out" >&2
    return 1
  fi
  printf '%s\n' "$n"
}

# adapter_pr_labels <n>: the PR's label names, one per line (#1299).
adapter_pr_labels() {
  gh pr view "$1" --json labels --jq '.labels[].name'
}

# adapter_pr_body <n>: the PR's body as GitHub holds it, then a newline.
adapter_pr_body() {
  gh pr view "$1" --json body --jq .body
}

# adapter_pr_refs <n>: the read of the PR's own head and base, from the PR, not
# from local HEAD, which can be anywhere by the time a caller reads it. Prints
# the head SHA, the head branch and the base branch, an empty line for one
# GitHub leaves unset.
adapter_pr_refs() {
  gh pr view "$1" --json headRefOid,headRefName,baseRefName \
    --jq '(.headRefOid // ""), (.headRefName // ""), (.baseRefName // "")'
}

# pr_refs_read <n> <head_oid_var> <head_ref_var> <base_var> <err_var>: reads
# PR <n> once through adapter_pr_refs and writes its head SHA, head branch and
# base branch (each empty where GitHub leaves it unset) into the three
# caller-named variables, on gh_lines_read's contract.
pr_refs_read() {
  gh_lines_read adapter_pr_refs "$1" "$5" "$2" "$3" "$4"
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

# pr_state_draft_read <n> <state_var> <draft_var> <err_var>: reads PR <n> once
# through adapter_pr_state_draft and writes its state (OPEN, CLOSED or MERGED)
# and its draft flag, normalised to true or false, into the first two
# caller-named variables, on gh_lines_read's contract.
pr_state_draft_read() {
  local __psdr_state __psdr_draft __psdr_rest
  gh_lines_read adapter_pr_state_draft "$1" "$4" \
    __psdr_state __psdr_draft __psdr_rest || return 1
  [ "$__psdr_draft" = true ] || __psdr_draft=false
  printf -v "$2" '%s' "$__psdr_state"
  printf -v "$3" '%s' "$__psdr_draft"
}

# adapter_prs_open <head> [base]: the open PRs from the head branch - into the
# base branch, where one is named - newest first, one per line as
# `<number>\t<isCrossRepository>` (`true` or `false`), unfiltered: the Trust
# module's trust_filter_prs drops the fork PRs.
adapter_prs_open() {
  local args=(--head "$1")
  [ -z "${2:-}" ] || args+=(--base "$2")
  gh pr list "${args[@]}" --state open --json number,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.isCrossRepository)"'
}

# adapter_prs_open_bodies: every open PR, newest first, one per line as
# `<number>\t<body>\t<isCrossRepository>` - the body a JSON string (gh's
# @json), so a multi-line body stays on one line and the caller decodes it
# with jq; the flag `true` or `false`, last - unfiltered: the Trust module's
# trust_filter_prs drops the fork PRs.
adapter_prs_open_bodies() {
  gh pr list --state open --limit "$ISSUE_LIST_LIMIT" --json number,body,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.body | @json)\t\(.isCrossRepository)"'
}

# adapter_prs_open_mergeability: every open PR, newest first, one per line as
# `<number>\t<head branch>\t<mergeable>\t<isCrossRepository>` - mergeable is
# gh's MERGEABLE, CONFLICTING or UNKNOWN, the flag `true` or `false` -
# unfiltered: the Trust module's trust_filter_prs drops the fork PRs. No bash
# caller is left: the converted autopilot watcher's one read per tick (issue
# #2325) is orch/gh.py's prs_open_mergeability.
adapter_prs_open_mergeability() {
  gh pr list --state open --limit "$ISSUE_LIST_LIMIT" --json number,headRefName,mergeable,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.headRefName)\t\(.mergeable)\t\(.isCrossRepository)"'
}

# adapter_pr_diff <n>: the PR's diff, as gh prints it.
adapter_pr_diff() {
  gh pr diff "$1"
}

# adapter_prs_merged <head> <base>: the PRs from the head branch merged into
# the base branch, one line each, newest first: its number, its head SHA and
# its isCrossRepository flag (`true` or `false`), tab-separated and unfiltered:
# the Trust module's trust_filter_prs drops the fork PRs. The finished sweep's
# read for a quick implementation, which records no PR of its own. GitHub
# reports a squash or rebase merge as merged too, which git ancestry never
# would.
adapter_prs_merged() {
  gh pr list --head "$1" --base "$2" --state merged --json number,headRefOid,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.headRefOid)\t\(.isCrossRepository)"'
}

# adapter_prs_merged_closing <base> <since>: every PR merged into the base
# branch at or after the UTC timestamp <since>, newest created first (stated in
# the search), one per line as `<number>\t<head branch>\t<mergedAt>\t
# <closing issues>\t<isCrossRepository>` - the closing issues the numbers of its
# closingIssuesReferences, comma-separated, empty when none - unfiltered: the
# Trust module's trust_filter_prs drops the fork PRs. The merged-PR backstop's
# one read per tick (issue #2478), bounded since the oldest issue it may close
# was created (issue #3061).
adapter_prs_merged_closing() {
  gh pr list --base "$1" --state merged --search "merged:>=$2 sort:created-desc" --limit "$ISSUE_LIST_LIMIT" \
    --json number,headRefName,mergedAt,closingIssuesReferences,isCrossRepository \
    --jq '.[] | "\(.number)\t\(.headRefName)\t\(.mergedAt)\t\([.closingIssuesReferences[].number] | map(tostring) | join(","))\t\(.isCrossRepository)"'
}

# adapter_prs_merged_bodies <base>: the body of every PR merged into the base
# branch, each followed by a newline - pr release reads its issue references
# out of them (issue #139).
adapter_prs_merged_bodies() {
  gh pr list --base "$1" --state merged --limit "$ISSUE_LIST_LIMIT" --json body --jq '.[].body'
}

# adapter_pr_close <n> <comment>: closes the PR, posting the comment on it.
# Prints nothing. It declares its gh call a compound write: gh posts the
# comment first and closes second, so a failed close can leave the comment, and
# a rerun would post it twice.
adapter_pr_close() {
  GH_LIMIT_COMPOUND=1 gh pr close "$1" --comment "$2" >/dev/null
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

# adapter_pr_title_edit <n> <title>: replaces the PR's title. Prints nothing.
adapter_pr_title_edit() {
  gh pr edit "$1" --title "$2" >/dev/null
}

# adapter_pr_label_add <n> <label>: adds the label to the PR, removing none.
# Prints nothing.
adapter_pr_label_add() {
  gh pr edit "$1" --add-label "$2" >/dev/null
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

# adapter_issue_open_blockers <n>: the count of #n's blockers still open, from
# the dependency summary on the issue itself, or nothing at all where GitHub
# leaves the summary off - never a stand-in zero.
adapter_issue_open_blockers() {
  gh api "repos/{owner}/{repo}/issues/$1" --jq '.issue_dependencies_summary.blocked_by // ""'
}

# adapter_blockers_states <n>: the issues #n is blocked by, one per line as TSV
# "<n><TAB><OPEN|CLOSED>", in GitHub's order. Nothing at all for none.
adapter_blockers_states() {
  gh api --paginate "repos/{owner}/{repo}/issues/$1/dependencies/blocked_by" \
    --jq '.[] | "\(.number)\t\(.state | ascii_upcase)"'
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

# --- repo operations ---

# adapter_repo_default_branch <repo>: the default branch of the repo, named
# [HOST/]OWNER/REPO, as a bare branch name on one line. The repo goes in gh's
# argv because `gh repo view` ignores GH_REPO and would otherwise read gh's own
# default repo. The answer is gh's stdout as is: a caller validates it.
adapter_repo_default_branch() {
  gh repo view "$1" --json defaultBranchRef --jq .defaultBranchRef.name
}

# --- claim operations (#1454) ---
#
# A claim is a ref on origin, refs/orch/claims/<issue>: the one origin write
# autopilot adds. These run git against origin, not gh, but are adapter
# operations all the same, so the suite fakes them with the rest (create, delete
# and list; adapter_claim_ref is a pure name builder the fake shares).

# adapter_claim_ref <issue>: prints the claim's ref, refs/orch/claims/<issue>.
adapter_claim_ref() { printf 'refs/orch/claims/%s\n' "$1"; }

# adapter_claim_create <issue> <phase> <pid> <host>: takes the claim on <issue>
# for <phase>, recording <host>, <pid> and the start time. It pushes a throwaway
# empty-tree commit, made with commit-tree so no checkout is touched, to the
# claim's ref with an empty --force-with-lease expect: the push succeeds only
# where the ref does not exist, atomically on the server, so exactly one of
# two racers wins. Prints nothing. Exit 2 where an existing ref beat it - the
# loss, the only status a caller reads as "skip this issue"; exit 1, git's
# reason on stderr, for any other failure.
adapter_claim_create() {
  local ref commit reason
  ref="$(adapter_claim_ref "$1")"
  commit="$(git commit-tree "$(git hash-object -t tree /dev/null)" -m "orch claim $1" \
    -m "$(printf 'host: %s\npid: %s\nphase: %s\nstarted: %s' \
      "$4" "$3" "$2" "$(now)")")" || return 1
  git_push reason --force-with-lease="$ref:" origin "$commit:$ref" && return 0
  case "$reason" in
    *'stale info'*|*'already exists'*) return 2 ;;
  esac
  printf '%s\n' "$reason" >&2
  return 1
}

# adapter_claim_delete <issue>: frees the claim on <issue>. A claim already
# gone is freed all the same: succeeds. Prints nothing; git's reason on stderr
# where the push fails.
adapter_claim_delete() {
  local reason
  git_push reason origin ":$(adapter_claim_ref "$1")" && return 0
  case "$reason" in
    *'does not exist'*) return 0 ;;
  esac
  printf '%s\n' "$reason" >&2
  return 1
}

# adapter_claim_list: the claims on origin, one line each, by issue number, as
# TSV "<issue><TAB><host><TAB><pid><TAB><phase><TAB><started>", read from each
# claim commit's message; nothing for none. Fetches refs/orch/claims/* first,
# pruning the local copies of claims since freed. Fails, git's reason on
# stderr, where origin cannot be read.
adapter_claim_list() {
  local err ref msg issue host pid phase started sentinel_read=""
  local nl=$'\n' sentinel='orch-claim-list-end'
  local pat_host="$nl"'host: ([^'"$nl"']*)' pat_pid="$nl"'pid: ([^'"$nl"']*)'
  local pat_phase="$nl"'phase: ([^'"$nl"']*)' pat_started="$nl"'started: ([^'"$nl"']*)'
  capture_err err git fetch --quiet --prune origin '+refs/orch/claims/*:refs/orch/claims/*' || {
    printf '%s\n' "${err:-git gave no reason}" >&2
    return 1
  }
  # One for-each-ref gives every claim's ref and message, NUL-separated, in
  # version (numeric) order; the sentinel record is printed only when it
  # succeeds. The loop never exits early, so git is read to EOF.
  while IFS= read -r -d '' ref && IFS= read -r -d '' msg; do
    ref="${ref#"$nl"}"
    if [ "$ref" = "$sentinel" ]; then
      sentinel_read=1
      continue
    fi
    issue="${ref##*/}"
    host="" pid="" phase="" started=""
    msg="$nl$msg"
    [[ "$msg" =~ $pat_host ]] && host="${BASH_REMATCH[1]}"
    [[ "$msg" =~ $pat_pid ]] && pid="${BASH_REMATCH[1]}"
    [[ "$msg" =~ $pat_phase ]] && phase="${BASH_REMATCH[1]}"
    [[ "$msg" =~ $pat_started ]] && started="${BASH_REMATCH[1]}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$issue" "$host" "$pid" "$phase" "$started"
  done < <(git for-each-ref --sort=version:refname --format='%(refname)%00%(contents)%00' refs/orch/claims/ \
    && printf '%s\0\0' "$sentinel")
  [ -n "$sentinel_read" ] || return 1
}

if [ -n "${ORCH_GH_ADAPTER:-}" ]; then
  # shellcheck disable=SC1090 # the adapter path is chosen at run time, by tests
  source "$ORCH_GH_ADAPTER"
fi
