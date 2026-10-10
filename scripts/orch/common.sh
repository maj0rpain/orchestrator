# shellcheck shell=bash
# common.sh - the helpers more than one orch.sh module uses, or orch.sh and
# one module: die, warn, note, capture, the state readers and writers, the
# repo and base-branch resolvers, and the like. A helper only one module uses
# lives in that module instead, and the gh adapter layer lives whole in gh.sh.
# Sourced by orch.sh ahead of the ROOT block, which dies through die when run
# outside a git repository, and ahead of every noun module.

# Whether <sev> is a filed severity: the one membership check over
# FILED_SEVERITIES, so adding a severity edits the constant and its label
# colour in `review file`, not every membership check.
is_filed_severity() {
  local s
  for s in $FILED_SEVERITIES; do [ "$1" != "$s" ] || return 0; done
  return 1
}

# labels_have <labels> <label>: whether <label> is one of the newline-separated
# <labels>, matched whole-line and literally. The one label-membership test:
# `--` keeps a label beginning with `-` a label, never a grep option.
labels_have() {
  printf '%s\n' "$1" | grep -qxF -- "$2"
}

# review_labels <labels>: each label in the newline-separated list that marks
# a review finding - review: followed by at least one character. The one scan
# the two checks below share.
review_labels() {
  printf '%s\n' "$1" | grep '^review:.' || true
}

die()  { printf 'orch: %s\n' "$*" >&2; exit 1; }
# die for commands that reserve exit 1 for a meaningful "no" (pr comment: no
# open PR; ticket exists: no breakdown), so their failures exit with status 2 instead.
die2() { printf 'orch: %s\n' "$*" >&2; exit 2; }
# warn: die's line on stderr, without the exit - for a refusal that returns its
# own status, or a warning the command carries on past.
warn() { printf 'orch: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
# The one timestamp shape for .orchestrator/ directory names: compact, UTC, and
# colon-free so the path is valid on Windows too. now() stays ISO-8601: it is a
# field value, never a path segment.
dir_stamp() { date -u +%Y%m%d-%H%M%S; }
# capture_err <err-var> <command...>: runs the command, sets <err-var> to its
# stderr byte for byte, and returns its status. It leaves stdout alone, to the
# caller's own redirect: a body streamed to a file through
# `capture_err err adapter_issue_body "$n" >"$body"` keeps its trailing
# newlines, which capture's command substitution would strip. The stderr goes
# through one temp file capture_err owns. Call it in the current shell, never
# inside $(...): it sets the caller's variable with printf -v. Its locals carry
# a _capture_err_ prefix, so they shadow no caller's variable. The command runs
# in a subshell: the gh guard's no-repo death then signals the main shell,
# whose USR1 trap dies with the remedy on the real stderr, rather than dying
# here with its message redirected into the capture.
capture_err() {
  local _capture_err_file _capture_err_text _capture_err_st=0
  _capture_err_file="$(mktemp)"
  ( "${@:2}" ) 2>"$_capture_err_file" || _capture_err_st=$?
  _capture_err_text="$(cat "$_capture_err_file"; printf x)"
  rm -f "$_capture_err_file"
  printf -v "$1" '%s' "${_capture_err_text%x}"
  return "$_capture_err_st"
}
# capture <out-var> <err-var> <command...>: capture_err with the stdout taken
# too - sets <out-var> to the command's stdout (read back by command
# substitution, so trailing newlines go), <err-var> to its stderr byte for
# byte, and returns its status. Same rules as capture_err: current shell only,
# and _capture_-prefixed locals, nested calls included.
capture() {
  local _capture_file _capture_st=0
  _capture_file="$(mktemp)"
  capture_err "$2" "${@:3}" >"$_capture_file" || _capture_st=$?
  printf -v "$1" '%s' "$(cat "$_capture_file")"
  rm -f "$_capture_file"
  return "$_capture_st"
}
# gh_reason <stderr>: the reason a failed gh call gives - the first line of
# its captured stderr, or "gh gave no reason" when that line is empty, so a
# death message never ends in a bare colon. It only produces the reason; each
# site keeps its own die, die2, warn or why.
gh_reason() {
  local line="${1%%$'\n'*}"
  printf '%s\n' "${line:-gh gave no reason}"
}
# The argument with leading and trailing whitespace removed.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# The splitters below cut a string up by parameter expansion, so a hot path
# spawns no awk, sed, cut or tail to do it. Each assigns to caller-named
# variables through printf -v, as capture does, and is called in the current
# shell, never inside $(...).
#
# tsv_split <line> <var>...: <line>'s tab-separated fields into the named
# variables in turn, as awk -F '\t' reads them: an empty field stays empty,
# a field past the last tab is empty, and fields past the last variable are
# dropped.
tsv_split() {
  local _tsv_rest="$1"
  shift
  while [ $# -gt 0 ]; do
    printf -v "$1" '%s' "${_tsv_rest%%$'\t'*}"
    case "$_tsv_rest" in
      *$'\t'*) _tsv_rest="${_tsv_rest#*$'\t'}" ;;
      *) _tsv_rest="" ;;
    esac
    shift
  done
}

# lines_split <text> <var>... <rest-var>: <text>'s first line into the first
# variable, its next line into the next, and every line left into
# <rest-var> - as `sed -n <N>p` and `tail -n +<N>` captured by $(...) read a
# text with no trailing newline. A line past the end is empty.
lines_split() {
  local _ls_rest="$1"
  shift
  while [ $# -gt 1 ]; do
    printf -v "$1" '%s' "${_ls_rest%%$'\n'*}"
    case "$_ls_rest" in
      *$'\n'*) _ls_rest="${_ls_rest#*$'\n'}" ;;
      *) _ls_rest="" ;;
    esac
    shift
  done
  printf -v "$1" '%s' "$_ls_rest"
}

# state_word <var> <state>: GitHub's uppercase issue or PR <state> into <var>
# as the lowercase word a message prints - bash 3.2 has no lowercase
# expansion. Any other value is passed through unchanged.
state_word() {
  case "$2" in
    OPEN) printf -v "$1" '%s' open ;;
    CLOSED) printf -v "$1" '%s' closed ;;
    MERGED) printf -v "$1" '%s' merged ;;
    *) printf -v "$1" '%s' "$2" ;;
  esac
}

# newlines_strip <var>: drops every trailing newline from the named
# variable's value, as $(...) drops them from a command's output.
newlines_strip() {
  local _ns_v="${!1}"
  while [ "${_ns_v%$'\n'}" != "$_ns_v" ]; do _ns_v="${_ns_v%$'\n'}"; done
  printf -v "$1" '%s' "$_ns_v"
}

# The one normalisation a slug gets: lowercase, non-alphanumeric runs collapsed
# to a single hyphen, trimmed, dying if nothing survives. `init` and `cmd_slug`
# both call this rather than each carrying their own copy of the sed expression
# and the empty-result check - and a caller outside this file (the
# quick-implement skill) reaches it through `orch.sh slug` instead of
# re-deriving the algorithm as prose.
normalize_slug() {
  local slug
  slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || die "slug is empty after normalisation"
  printf '%s\n' "$slug"
}

# plugin_cmd <command> <fallback>: names a plugin command so any host can act
# on it. Plugin commands are unverified on Junie (docs/host-capabilities.md),
# so off Claude Code it also names <fallback>, where the command routes - the
# same fallback the skills offer. On Claude Code the name stands alone, as it
# was before 1.0.0 (#121 story 2).
plugin_cmd() {
  if [ "$(host_detect)" = claude ]; then
    printf "/orchestrator:%s" "$1"
  else
    printf "/orchestrator:%s (or %s)" "$1" "$2"
  fi
}

# Names a flow command, its fallback the orch-flow section it routes to.
flow_cmd() {
  local section
  case "$1" in
    start) section="Starting a flow" ;;
    next)  section="Next phase" ;;
    redo)  section="Redo" ;;
    abort) section="Abort" ;;
    finish) section="Finish" ;;
    *) die "flow_cmd: unknown command: $1" ;;
  esac
  plugin_cmd "$1" "orch-flow's $section section"
}

# Names finding triage, its fallback the skill the command runs, since finding
# triage is no orch-flow section.
finding_triage_cmd() {
  plugin_cmd finding-triage "the orch-finding-triage skill"
}

# Every flow state key, one row each, in the order init seeds them into
# state.json: key|default|seed|owner. state_get, state set and init all read
# it, so adding a key is one row; an arg row also needs its value in cmd_init's
# case, and init dies naming the key without it. state_rows is its one reader:
# lines starting with # are comments, and blank lines are skipped.
#
# default: what state_get returns for a null or missing value. A flow started
#   by an older release lacks keys a fresh one seeds; each reads back as its
#   default. The default applies only to a null or missing value, never to a
#   stored false (jq's `//` would treat false like null).
# seed: the JSON literal init writes, or arg where init supplies the value at
#   run time; the value comes from cmd_init's case.
# owner: - for a key state set may write (state_key_settable); otherwise the
#   reason it refuses, printed as "state set refuses <key>: <owner>".
STATE_KEYS='slug||arg|init seeds it
# phase_write spec sets the phase straight after init seeds it.
phase||null|use phase advance (review ready and redo also move it)
# Seeded from --issue when given; state.json carries no field for whether it
# was adopted or published - nothing downstream needs that distinction
# recorded (ADR-0005).
issue||arg|-
# When a flow base may change: see the header of base_set_flow.
base||arg|init seeds it
branch||null|branch create records it
pr||null|pr open records it
base_sha||null|branch create records it
# Null until the review loop asks a human for one; review begin reads null as
# the default.
budget||null|-
iteration|0|0|review begin counts it
# Seeded here rather than at the review phase because its allowance belongs to
# the flow: one per flow, spent or not, so that one refilled each iteration
# could not become an infinite retry loop.
flake_rerun_used|false|false|-
redo_count|0|0|redo review counts it
# Marks a flow whose handoffs must record Host fallbacks (see
# host_fallbacks_required); an older flow without it reads false.
host_fallbacks|false|true|init seeds it
created||arg|init seeds it
updated||arg|every state change stamps it'

# Prints each data row of STATE_KEYS as key|default|seed|owner, in table
# order: the only reader of $STATE_KEYS, so every other reader skips the same
# comment and blank lines.
state_rows() {
  local k d s o
  while IFS='|' read -r k d s o; do
    case "$k" in '#'*|'') continue ;; esac
    printf '%s|%s|%s|%s\n' "$k" "$d" "$s" "$o"
  done <<EOF
$STATE_KEYS
EOF
}

# Prints column $2 (default, seed or owner) of state key $1's row. An unknown
# key prints nothing and returns 1; the caller dies with its own message. An
# unknown column is a programming error, not caller input: it exits 2, never
# 1, so it is never read as an unknown key, and its caller exits with that
# status without a second message.
state_key_field() {
  local k d s o
  case "$2" in
    default|seed|owner) ;;
    *) die2 "state_key_field has no column: $2" ;;
  esac
  while IFS='|' read -r k d s o; do
    [ "$k" = "$1" ] || continue
    case "$2" in
      default) printf '%s\n' "$d" ;;
      seed)    printf '%s\n' "$s" ;;
      owner)   printf '%s\n' "$o" ;;
    esac
    return 0
  done <<EOF
$(state_rows)
EOF
  return 1
}

# Every read of state.json goes through here, so what an absent key means is
# decided in the STATE_KEYS table rather than at each call site. A key outside
# the table dies: a misspelt read would otherwise look exactly like an unset one.
state_get() { state_get_in "$STATE" "$1"; }

# state_get against the state file <file>: reads <key> from any checkout's
# state file, not only this one's.
state_get_in() {
  local default rc
  default="$(state_key_field "$2" default)" || {
    rc=$?
    [ "$rc" -ne 1 ] || die "unknown state key: $2"
    exit "$rc"
  }
  jq -r --arg k "$2" --arg d "$default" '.[$k] | if . == null then $d else . end | tostring' "$1"
}

# The one state-file write: sets key $1 to the JSON value $2 and stamps
# updated. Private to the writers below; every write after init's seed goes
# through here.
state_put() {
  local tmp; tmp="$(mktemp)"
  jq --arg k "$1" --argjson v "$2" --arg now "$(now)" \
    '.[$k] = $v | .updated = $now' "$STATE" >"$tmp"
  mv "$tmp" "$STATE"
}

# The unrestricted writer behind every internal state change. "null" stores a
# JSON null, "true" and "false" a boolean, and an all-digit value a number, so
# a key cleared, flagged or counted here reads back through state_get the way
# init seeded it. Every other value is stored as a string.
state_write() {
  case "$2" in
    null|true|false) state_put "$1" "$2" ;;
    *[!0-9]*|"") state_write_string "$1" "$2" ;;
    *) state_put "$1" "$(jq -n --arg v "$2" '$v | tonumber')" ;;
  esac
}

# Stores value $2 under key $1 as a JSON string, always. Not state_write: it
# would turn a value of null, true, false or all digits into JSON null, a
# boolean or a number - a branch can bear any of those names, and a base is
# always a string, as init stores it.
state_write_string() {
  state_put "$1" "$(jq -n --arg v "$2" '$v')"
}

require_state() {
  [ -f "$STATE" ] || die "no active flow ($ORCH_DIR_NAME/state.json not found). Run $(flow_cmd start) first."
}

# Fetches a required state field through state_get, dies with $3 if it comes back empty,
# and otherwise writes it into the variable named by $1 - a caller-named
# out-param via `printf -v` rather than a nameref: bash 3.2 has neither
# `local -n` nor `declare -n`, and this file promises to still run there (the
# same idiom `d_gate` uses in doctor.sh).
#
# Call it as a bare statement on its own line - `local pr; require_pr pr` -
# never folded into `$(...)`. A caller-named out-param has no result to
# capture with `pr="$(require_pr)"` in the first place, so that old shape no
# longer compiles into anything that reads state; the only thing left to write
# is the bare form, and `die` in that form runs directly in the caller's flow
# rather than inside a command substitution subshell, so `set -e` actually
# stops it instead of the caller carrying on with an empty value.
require_field() {
  local __rf_out="$1" __rf_key="$2" __rf_msg="$3" __rf_val
  __rf_val="$(state_get "$__rf_key")"
  [ -n "$__rf_val" ] || die "$__rf_msg"
  printf -v "$__rf_out" '%s' "$__rf_val"
}

# Every review command that reaches GitHub needs the flow's PR number and none
# of them can do anything useful without it.
require_pr() { require_field "$1" pr "no PR recorded in state - the implement phase opens it"; }

# branch create, pr open, and every spec op need the flow's spec issue number
# before touching GitHub.
require_issue() { require_field "$1" issue "no issue recorded in state - the spec phase must publish one first"; }

# pr open and redo review both need the flow's branch before touching GitHub.
require_branch() { require_field "$1" branch "no branch recorded in state"; }

# The one writer of state.phase. It knows only which phases exist: every caller
# - advance, review ready, both redos, and init's seed - keeps its own guard on
# which transition it may make, so a step back needs no handoff check here.
phase_write() {
  case " $PHASES " in
    *" $1 "*) ;;
    *) die "not a flow phase: $1 (want one of: $PHASES)" ;;
  esac
  state_write phase "$1"
}

# Ask GitHub first. refs/remotes/origin/HEAD is a *local cached pointer* frozen at
# clone time - in a clone taken while a feature branch was checked out it names
# that branch, which would silently base every feature branch off the wrong place.
# It is a fallback for repos gh cannot answer for, not the primary source.
# Each candidate counts only when it is a valid branch name, so noise around
# gh's answer - or a failed gh's output - falls through to the next (#465).
#
# GitHub is asked only when the repo resolves - adapter_repo_default_branch
# takes it positionally, since `gh repo view` ignores GH_REPO - and a checkout
# with none falls through to the local pointer rather than dying: the answer
# has always been best-effort, and init and base show ask it before anything
# needs GitHub.
default_branch() {
  local b=""
  if repo_resolve; then
    b="$(adapter_repo_default_branch "$REPO_NAME" 2>/dev/null)" || b=""
  fi
  if ! is_branch_name "$b"; then
    b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || b=""
    b="${b#origin/}"
  fi
  is_branch_name "$b" || b="main"
  printf '%s\n' "$b"
}
# REPO_SOURCE is read by repo.sh (repo show) and doctor.sh, not here.
# shellcheck disable=SC2034
repo_resolve() {
  local url
  REPO_NAME=""
  REPO_SOURCE=""
  if [ -n "${GH_REPO:-}" ]; then
    REPO_NAME="$GH_REPO"
    REPO_SOURCE=GH_REPO
    return 0
  fi
  url="$(git remote get-url origin 2>/dev/null)" || return 1
  REPO_NAME="$(repo_from_url "$url")" || { REPO_NAME=""; return 1; }
  REPO_SOURCE=origin
}

# The one parser of a [HOST/]OWNER/REPO repo name, as repo_resolve sets
# REPO_NAME. repo_host <name> prints its explicit host, or nothing for an
# OWNER/REPO name, whose host is the implicit github.com; repo_owner_name
# <name>, in doctor.sh, its one caller, prints its OWNER/REPO, any host
# dropped.
repo_host() {
  case "$1" in
    */*/*) printf '%s\n' "${1%%/*}" ;;
  esac
}

# repo_pin: pin every later gh call to the repo - when GH_REPO is unset, resolve
# it and export it as GH_REPO, then pin its host (repo_pin_host). Returns 1,
# exporting nothing, when nothing resolves, and never dies: each caller picks
# its own exit, the gh guard's subshell signal or die, review rerun's die2.
repo_pin() {
  if [ -z "${GH_REPO:-}" ]; then
    repo_resolve || return 1
    export GH_REPO="$REPO_NAME"
  fi
  repo_pin_host
}

# repo_from_url <url>: [HOST/]OWNER/REPO from a clone URL in any of its three
# forms - https://host/o/r, git@host:o/r, ssh://[user@]host[:port]/o/r - with
# or without .git. github.com is left implicit, as gh -R expects; any other
# host is kept. A URL with no host or not exactly owner/name fails.
repo_from_url() {
  local url="$1" host path
  case "$url" in
    https://*|http://*|ssh://*|git://*)
      url="${url#*://}"
      host="${url%%/*}"
      path="${url#*/}"
      [ "$path" != "$url" ] || return 1
      host="${host##*@}"
      host="${host%%:*}"
      ;;
    *@*:*)
      host="${url%%:*}"
      host="${host##*@}"
      path="${url#*:}"
      ;;
    *) return 1 ;;
  esac
  path="${path%/}"
  path="${path%.git}"
  case "$path" in
    */*/*|/*|*/|"") return 1 ;;
    */*) ;;
    *) return 1 ;;
  esac
  [ -n "$host" ] || return 1
  if [ "$host" = github.com ]; then
    printf '%s\n' "$path"
  else
    printf '%s/%s\n' "$host" "$path"
  fi
}

# gh api fills {owner}/{repo} from GH_REPO but takes its host only from
# GH_HOST, never from GH_REPO's host part (gh 2.102.0). So a HOST/OWNER/REPO
# GH_REPO also exports GH_HOST=HOST; an OWNER/REPO one, a github.com repo,
# leaves GH_HOST as it is.
repo_pin_host() {
  local host
  host="$(repo_host "$GH_REPO")"
  if [ -n "$host" ]; then export GH_HOST="$host"; fi
}
trap 'die "$REPO_REMEDY"' USR1

# Whether $1 is a valid branch name (git check-ref-format --branch rejects an empty one).
is_branch_name() {
  git check-ref-format --branch "$1" >/dev/null 2>&1
}

# The base branch in effect now: the checkout's orchestrator.base setting, else
# the default branch. The one answer every fork, PR target and doctor check
# asks for - default_branch keeps meaning GitHub's default branch alone.
# Local git config rather than state.json or a tracked file: it outlives
# abort and archiving, every worktree of the clone shares it, and it never
# travels with a push.
base_setting() { git config --get orchestrator.base 2>/dev/null || true; }
base_branch() {
  local b
  b="$(base_setting)"
  if [ -n "$b" ]; then printf '%s\n' "$b"; else default_branch; fi
}

# The active flow's own base branch, recorded by init. A flow started before
# base was recorded has none, and always forked from the default branch.
flow_base() { flow_base_in "$STATE"; }

# flow_base against another checkout's state file <file>.
flow_base_in() {
  local b
  b="$(state_get_in "$1" base)"
  if [ -n "$b" ]; then printf '%s\n' "$b"; else default_branch; fi
}

# Whether origin has branch $1: 0 yes, 2 origin answered and it does not,
# anything else origin could not be asked. ls-remote's own exit codes carry
# exactly that split, which is the one doctor's severity rule turns on.
origin_has_branch() {
  local st=0
  git ls-remote --quiet --exit-code origin "refs/heads/$1" >/dev/null 2>&1 || st=$?
  return "$st"
}

# Whether a flow is active: state.json exists and its phase is not done.
flow_active() { [ -f "$STATE" ] && [ "$(state_get phase)" != "done" ]; }

# flow_holding_phase <branch> [issue]: prints the phase of the active flow
# (phase not done) when it holds the branch, or the issue where one is given,
# and fails printing nothing otherwise. A branch or issue an active flow holds
# belongs to it (ADR-0029), so review-pass begin and pr draft/ready refuse it,
# each with its own message. Reads state.json only when one exists.
flow_holding_phase() {
  local branch="$1" issue="${2:-}" phase
  [ -f "$STATE" ] || return 1
  phase="$(state_get phase)"
  [ "$phase" != "done" ] || return 1
  [ "$(state_get branch)" = "$branch" ] \
    || { [ -n "$issue" ] && [ "$(state_get issue)" = "$issue" ]; } \
    || return 1
  printf '%s\n' "$phase"
}

# The refusal of a second flow beside one mid-pipeline, shared by init and
# branch off (a quick implementation must never move an active flow's checkout
# off its branch). It exits 3, a code no other failure of either uses, so a
# skill can tell "a flow is active" apart from every other refusal.
refuse_beside_active_flow() {
  flow_active || return 0
  warn "a flow is already active (slug: $(state_get slug), phase: $(state_get phase)).
     One flow at a time - finish it, or run $(flow_cmd abort)."
  exit 3
}

# Ignore every directory in EXCLUDED_DIRS - the flow directory and .scratch/ -
# without touching a tracked .gitignore, so running the orchestrator in an
# unfamiliar repo never dirties its working tree. A line already present is
# never written again. The file is the clone's shared one (the common dir),
# the only info/exclude git reads, so a linked worktree writes it too.
exclude_orch_dirs() {
  local ex d
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  mkdir -p "${ex%/*}"
  for d in "${EXCLUDED_DIRS[@]}"; do
    grep -qxF "$d" "$ex" 2>/dev/null || printf '%s\n' "$d" >>"$ex"
  done
}
# Prints, one per line, every path with tracked modifications or untracked
# files in this working tree that falls outside the planning allowlist. -z
# keeps unusual file names intact; a rename or copy carries its source path as
# a second record, and both sides count - the source is gone from where it was.
# -uall lists untracked files individually, so a new directory is judged by
# what is in it rather than by its name.
dirty_outside_allowlist() {
  local rec path want_src=0 status err
  # Captured first rather than read through a process substitution, whose
  # failure set -e never sees: a git status that cannot run must refuse, not
  # read as a clean tree. A file, not a variable, because the output is
  # NUL-separated. git's own error is kept so the refusal can name it.
  status="$(mktemp)"
  if ! err="$(git -C "$ROOT" status --porcelain=v1 -z -uall 2>&1 >"$status")"; then
    rm -f "$status"
    die "git status failed - cannot check the working tree: ${err%%$'\n'*}"
  fi
  while IFS= read -r -d '' rec; do
    if [ "$want_src" -eq 1 ]; then
      path="$rec"; want_src=0
    else
      path="${rec:3}"
      case "${rec:0:2}" in *R*|*C*) want_src=1 ;; esac
    fi
    planning_allowlisted "$path" || printf '%s\n' "$path"
  done <"$status"
  rm -f "$status"
}

# tree_status <path>: prints git status --porcelain for the working tree at
# <path> - empty when it is clean. A git status that cannot run must never
# read as a clean tree, so instead it prints why, naming git's error, and
# returns 1: callers refuse with that line, or report it.
tree_status() {
  local out err
  if ! capture out err git -C "$1" status --porcelain; then
    printf 'git status failed - cannot check the working tree: %s\n' "${err%%$'\n'*}"
    return 1
  fi
  printf '%s' "$out"
}

# require_clean_tree <path> <dirty message>: returns 0 when the working tree
# at <path> is clean. Dies with tree_status's own line when git status cannot
# run, and with <dirty message> when the tree is dirty. Called as a bare
# statement so `die` stops the caller.
require_clean_tree() {
  local status
  status="$(tree_status "$1")" || die "$status"
  [ -z "$status" ] || die "$2"
}
# Every review loop, however many the flow has run, reads the implement
# handoff, so the four facts a loop runs on have exactly one authority.
handoff_file_for() {
  case "$1" in
    spec)      printf '01-plan.md\n' ;;
    implement) printf '02-spec.md\n' ;;
    review)    printf '03-implement.md\n' ;;
    *) die "no handoff defined for phase: $1" ;;
  esac
}

# A handoff missing a required section means the next phase runs blind, so the
# boundary is where it must fail - the context to fix it still exists there.
handoff_required() {
  case "$1" in
    01-plan.md)      printf '%s\n' '## Decisions' '## Rejected alternatives' '## Constraints' '## Open assumptions' ;;
    02-spec.md)      printf '%s\n' '## Spec issue' '## Seams' '## Spec review changelog' '## Ticket breakdown' ;;
    03-implement.md) printf '%s\n' '## PR' '## Spec issue' '## Base SHA' '## Deviations' '## Verification' ;;
    *) die "unknown handoff file: $1" ;;
  esac
  if host_fallbacks_required; then printf '%s\n' '## Host fallbacks'; fi
}

# A flow started before 1.0.0 wrote its handoffs without Host fallbacks, and
# its state.json has no host_fallbacks field. It keeps validating as it did, so
# upgrading mid-flow breaks nothing; every flow init starts now requires the
# section. With no state at all there is no older flow to spare.
host_fallbacks_required() {
  [ ! -f "$STATE" ] || [ "$(state_get host_fallbacks 2>/dev/null)" = true ]
}

section_body() {
  awk -v h="$2" '$0 == h { inside = 1; next } /^## / { inside = 0 } inside { print }' "$1"
}

# The single statement of what a valid handoff is: one line per required
# section, each `ok <heading>` or `FAIL <problem>`. doctor's flow-state check
# reads the same answer rather than writing a second one that can drift from it.
handoff_report() {
  local file="$1" base heading required failed=0
  base="$(basename "$file")"
  # Resolved up front, and the failure caught by hand: read straight out of a
  # process substitution, a name this file does not know would die in a subshell
  # nobody checks, the loop would read nothing, and a file with no required
  # sections at all would validate clean.
  required="$(handoff_required "$base")" || return 1
  while IFS= read -r heading; do
    if ! grep -qxF "$heading" "$file"; then
      printf 'FAIL missing section: %s\n' "$heading"
      failed=1
    elif [ -z "$(section_body "$file" "$heading" | tr -d '[:space:]')" ]; then
      printf 'FAIL empty section: %s\n' "$heading"
      failed=1
    else
      printf 'ok %s\n' "$heading"
    fi
  done <<<"$required"
  return "$failed"
}

# Check one handoff and relay the verdict in the aligned `ok    ` / `FAIL  `
# form: every FAIL line, and the ok lines too when the second argument is `ok`.
# A missing file is one FAIL line and status 2, an invalid one status 1, so a
# caller can pick its remedy without testing the file again. It never dies -
# the status is the verdict, and each caller keeps its own reaction to it.
handoff_check() {
  local file="$1" show_ok="${2:-}" report line failed=0
  if [ ! -f "$file" ]; then
    note "FAIL  handoff not found: $file"
    return 2
  fi
  report="$(handoff_report "$file")" || failed=1
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   [ "$show_ok" = ok ] && note "ok    ${line#ok }" ;;
      "FAIL "*) note "FAIL  ${line#FAIL }" ;;
    esac
  done <<<"$report"
  return "$failed"
}
# The bound belongs here rather than in the skill's prose: a session that has
# spent four iterations arguing with itself is exactly the one that would
# re-remember five as six. The number itself is the human's, read from state;
# this is only what it reads as when nobody has set one - a flow started before
# the key existed, or a value nothing can count.
readonly DEFAULT_BUDGET=5

review_budget() {
  local b
  b="$(state_get budget)"
  case "$b" in ''|*[!0-9]*) b="$DEFAULT_BUDGET" ;; esac
  printf '%s\n' "$b"
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

# One look at the PR's checks, classified. Prints the classification on the first
# line and any detail on the lines after it, indented like doctor's remedies.
#
# adapter_pr_checks answers nothing at all for a repo with no checks, and fails
# for an API that would not answer or an answer it could not read - so the two
# meanings an empty read could carry stay apart. Getting that distinction
# backwards is what would make the loop declare a CI-having repo CI-less, or
# mark a PR ready over checks nobody read.
ci_probe() {
  local pr="$1" scope="$2" out err failed="" pending="" line bucket name
  if ! capture out err adapter_pr_checks "$pr" "$scope"; then
    note unreachable
    note "      ${err%%$'\n'*}"
    return 0
  fi
  if [ -z "$out" ]; then note none; return 0; fi
  # One pass over the checks: each failed or cancelled one's name, and
  # whether any is pending.
  while IFS= read -r line; do
    tsv_split "$line" bucket name
    case "$bucket" in
      fail|cancel) failed+="$name"$'\n' ;;
      pending) pending=1 ;;
    esac
  done <<<"$out"
  newlines_strip failed
  if [ -n "$failed" ]; then
    note failing
    while IFS= read -r name; do [ -z "$name" ] || note "      $name"; done <<<"$failed"
    return 0
  fi
  if [ -n "$pending" ]; then note pending; return 0; fi
  note green
}

# Classifies the review loop's last iteration against its budget - the one
# answer `review terminal` and doctor's `check_flow_review_terminal` both read,
# rather than each re-deriving which iteration counts as done. Checked with
# the same section_body/required-heading pattern handoff_report already uses,
# not a second implementation of it. Prints the classification word on the
# first line, and for `stop`, the recorded reason on the lines after it; for
# `malformed`, the one expected-shape line callers quote rather than copy.
# Exit status is 0 for ready/stop, non-zero for none/pending/interrupted/
# malformed - a single boolean a caller can act on without re-deriving which
# words count as terminal.
#
# The section is read as markdown is written: blank lines under the heading
# are skipped, the first line is trimmed, and `stop` may carry its reason on
# the same line after a separator (-, –, —, :). Anything else in a non-empty
# section is malformed, never silently interrupted - interrupted means the
# record or its section is missing or empty once the budget is spent; short
# of it, the same absence is pending.
review_terminal_state() {
  require_state
  local i b path sec="" line started="" body="" first_raw first rest after s sep
  i="$(state_get iteration)"
  b="$(review_budget)"
  if [ "$i" -eq 0 ]; then note none; return 1; fi
  path="$(cmd_review path "$i")"
  # A loop can stop short of its budget (a failed base sync goes straight to
  # Termination), so a recorded terminal state is read whatever the
  # iteration; only its absence depends on the budget - pending before it is
  # spent, interrupted once it is.
  if [ -f "$path" ]; then sec="$(section_body "$path" '## Terminal state')" || true; fi
  if [ ! -f "$path" ] || [ -z "${sec//[[:space:]]/}" ]; then
    if [ "$i" -lt "$b" ]; then note pending; else note interrupted; fi
    return 1
  fi
  # The section from its first line holding more than spaces and tabs on.
  while IFS= read -r line; do
    if [ -z "$started" ]; then
      case "$line" in *[!$' \t']*) started=1 ;; *) continue ;; esac
    fi
    body+="$line"$'\n'
  done <<<"$sec"
  newlines_strip body
  lines_split "$body" first_raw rest
  first="$(trim "$first_raw")"
  case "$first" in
    ready) note ready; return 0 ;;
    stop*)
      after="$(trim "${first#stop}")"
      sep=
      for s in - – — :; do
        case "$after" in "$s"*) sep="$s"; break ;; esac
      done
      # Bare `stop`, or `stop` and a separator: anything else after the word
      # (`stopped`, `stop CI failed`) falls through to malformed.
      if [ -z "$after" ] || [ -n "$sep" ]; then
        after="$(trim "${after#"$sep"}")"
        note stop
        [ -z "$after" ] || printf '%s\n' "$after"
        [ -z "$rest" ] || printf '%s\n' "$rest"
        return 0
      fi ;;
  esac
  note malformed
  note "expected: first line 'ready', or 'stop' with its reason after a separator (-, –, —, :) or on the lines below"
  return 1
}
# Runs a gh read into <file>, written beside the target and moved into place
# only once gh has answered: a failed fetch that left a partial file behind is
# a body a caller would mistake for the actual content. <what> names the read
# in the error, beside gh's own first line. stdout streams straight to the
# temp file through capture_err, never through capture's $(...), so the body
# keeps its trailing newlines byte for byte.
fetch_into() {
  local file="$1" what="$2" tmp err
  shift 2
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  if ! capture_err err "$@" >"$tmp"; then
    rm -f "$tmp"
    die "gh could not read $what: $(gh_reason "$err")"
  fi
  mv "$tmp" "$file"
}

# The base branch a branch belongs to: the one branch off recorded for it, else,
# for a branch made before that was recorded, the base branch in effect now.
# The one rule pr publish targets and branch base-sha falls back to, so the PR
# and the SHA its review diffs from never name different bases.
recorded_base() {
  git config --get "branch.$1.orchestrator-base" 2>/dev/null || base_branch
}

# The ticket number <n> names, or die: digits only, not zero.
ticket_worktree_number() {
  case "$1" in
    ''|*[!0-9]*|0*) die "not a ticket number: ${1:-<none>} (want a positive integer)" ;;
  esac
  printf '%s\n' "$1"
}

ticket_worktree_path() { printf '%s/t%s\n' "$TICKET_WORKTREES" "$1"; }

# forked_from_key <branch>: the git config key that records the branch ticket
# branch <branch> was forked from - the one place code spells it out.
forked_from_key() { printf 'branch.%s.orchestrator-ticket-parent\n' "$1"; }

# forked_from_branch <branch>: prints the forked-from branch recorded on
# ticket branch <branch>, or prints nothing and returns non-zero when none is
# recorded.
forked_from_branch() { git config --get "$(forked_from_key "$1")" 2>/dev/null; }

# Prints <n> <path> for every ticket worktree under the checkout at <root>.
ticket_worktrees_under() {
  local line path name
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    path="${line#worktree }"
    [ "$(dirname "$path")" = "$1/$ORCH_DIR_NAME/worktrees" ] || continue
    name="$(basename "$path")"
    case "$name" in t[1-9]*) ;; *) continue ;; esac
    case "${name#t}" in *[!0-9]*) continue ;; esac
    note "${name#t} $path"
  done < <(git worktree list --porcelain)
}

# refuse_ticket_worktrees <root>: dies, naming every ticket worktree under the
# checkout at <root>, when any is left: moving .orchestrator/ wholesale would
# break git's record of each one, and removing the checkout would delete them.
refuse_ticket_worktrees() {
  local left
  left="$(ticket_worktrees_under "$1")"
  [ -n "$left" ] || return 0
  die "ticket worktrees are left under $1 - moving them would break git's record of them:
$(while read -r n path; do printf '       %s (orch.sh ticket-worktree remove %s)\n' "$path" "$n"; done <<<"$left")
     Remove each with orch.sh ticket-worktree remove <n> first."
}

# Resolves ticket <n>'s worktree for a command that acts on an existing one:
# dies unless <n> is a ticket number whose worktree exists and is on a branch.
# It assigns to the caller's `n`, `path` and `branch`, which bash scopes
# dynamically, and is called as a bare statement so `die` stops the caller.
ticket_worktree_resolve() {
  n="$(ticket_worktree_number "$1")"
  path="$(ticket_worktree_path "$n")"
  [ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" = "$path" ] \
    || die "no ticket worktree for ticket $n at $path"
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD)" \
    || die "ticket worktree $path is not on a branch (detached HEAD)"
}

# Whether a rebase is in progress in the checkout at <path>.
rebase_in_progress() {
  local gitdir
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]
}

# The main checkout: the first worktree git lists.
main_checkout() {
  local list first
  list="$(git worktree list --porcelain)" || return
  first="${list%%$'\n'*}"
  case "$first" in "worktree "*) printf '%s\n' "${first#worktree }" ;; esac
}

# side_checkout_marker <path>: prints the ownership marker's path for the
# worktree at <path>; returns 1 when it carries none.
side_checkout_marker() {
  local gd
  gd="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" \
    && [ -f "$gd/$SIDE_CHECKOUT_MARKER" ] && printf '%s\n' "$gd/$SIDE_CHECKOUT_MARKER"
}

# Whether the worktree at <path> carries the ownership marker.
is_side_checkout() { side_checkout_marker "$1" >/dev/null; }

# Every checkout's path, one per line, the main checkout first.
checkout_paths() {
  local list line
  list="$(git worktree list --porcelain)" || return
  while IFS= read -r line; do
    case "$line" in "worktree "*) printf '%s\n' "${line#worktree }" ;; esac
  done <<<"$list"
}

# Whether the checkout at <path> holds a flow.
checkout_has_flow() { [ -f "$1/$ORCH_DIR_NAME/state.json" ]; }

# What the checkout at <path> holds: its flow (flow <slug> <phase> #<issue>),
# else its checked-out branch (branch <name>), else (no branch).
checkout_holding() {
  local state="$1/$ORCH_DIR_NAME/state.json" issue issue_label branch
  if [ -f "$state" ]; then
    issue="$(state_get_in "$state" issue)"
    if [ -n "$issue" ]; then issue_label="#$issue"; else issue_label="(no issue)"; fi
    note "flow $(state_get_in "$state" slug) $(state_get_in "$state" phase) $issue_label"
  elif branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)"; then
    note "branch $branch"
  else
    note "(no branch)"
  fi
}

# --- the finished sweep ---
#
# Finished is read from GitHub's PR state, never git ancestry: a squash or
# rebase merge never makes the branch an ancestor of its base (ADR-0037). The
# verdicts below assign to the caller's `verdict` and `branch`, which bash
# scopes dynamically, and return 0 finished, 1 not finished - `verdict` the
# reason - or 2 the verdict could not be read, GitHub or the checkout's own
# git status - `verdict` naming which, and its error.

# github_read <var> <adapter-call> [args...]: runs the adapter call, its output
# assigned to the caller's <var>. On failure it sets `verdict` to the call's
# first error line and returns 2.
github_read() {
  local into="$1" got err
  shift
  capture got err "$@" || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
  printf -v "$into" '%s' "$got"
}

# finished_flow <state-file>: whether that flow is finished - at done, and its
# recorded PR merged into its own base branch.
finished_flow() {
  local state="$1" phase pr base state_draft pr_state shown_state refs _head_oid _head_ref merged_base _commits
  phase="$(state_get_in "$state" phase)"
  if [ "$phase" != "done" ]; then
    verdict="flow $(state_get_in "$state" slug) is at $phase, not done"; return 1
  fi
  branch="$(state_get_in "$state" branch)"
  [ -n "$branch" ] || { verdict="no branch"; return 1; }
  pr="$(state_get_in "$state" pr)"
  [ -n "$pr" ] || { verdict="no PR recorded"; return 1; }
  base="$(flow_base_in "$state")"
  github_read state_draft adapter_pr_state_draft "$pr" || return
  pr_state="${state_draft%%$'\n'*}"
  if [ "$pr_state" != MERGED ]; then
    state_word shown_state "$pr_state"
    verdict="PR #$pr is $shown_state"; return 1
  fi
  github_read refs adapter_pr_refs "$pr" || return
  # The base branch is the third line, empty when there is none.
  lines_split "$refs" _head_oid _head_ref merged_base _commits
  [ "$merged_base" = "$base" ] || { verdict="PR #$pr merged into $merged_base, not $base"; return 1; }
}

# side_checkout_finished <path>: whether the side checkout there is finished -
# a clean tree, and either a finished flow, or no flow and a PR merged from
# its checked-out branch into the base branch off recorded for it (see
# recorded_base). A git status that cannot run returns 2, as an unreadable
# GitHub does, so the sweep removes nothing on a tree it could not read.
# verdict is read by its callers, side-checkout.sh (side-checkout prune) and
# doctor.sh, not here.
# shellcheck disable=SC2034
side_checkout_finished() {
  local path="$1" base prs st
  st="$(tree_status "$path")" || { verdict="$st"; return 2; }
  if [ -n "$st" ]; then
    verdict="uncommitted changes or untracked files"; return 1
  fi
  if checkout_has_flow "$path"; then
    finished_flow "$path/$ORCH_DIR_NAME/state.json"; return
  fi
  branch="$(git -C "$path" symbolic-ref --quiet --short HEAD)" \
    || { verdict="no branch"; return 1; }
  base="$(recorded_base "$branch")"
  github_read prs adapter_prs_merged "$branch" "$base" || return
  [ -n "$prs" ] || { verdict="no merged PR from $branch into $base"; return 1; }
}

# Moves the flow in the checkout at <root> into an archive directory, and
# prints that directory - relative to this checkout when inside it, else in
# full. A side checkout's flow goes to the main checkout's archive; any other
# checkout, a hand-made worktree included, archives in place.
archive_flow() {
  local root="$1" orch="$1/$ORCH_DIR_NAME" home slug dest entry
  refuse_ticket_worktrees "$root"
  home="$orch"
  if is_side_checkout "$root"; then home="$(main_checkout)/$ORCH_DIR_NAME"; fi
  slug="$(state_get_in "$orch/state.json" slug)"
  dest="$home/archive/$(dir_stamp)-$slug"
  mkdir -p "$dest"
  for entry in "$orch"/*; do
    [ -e "$entry" ] || continue
    # Side checkouts are live worktrees, never part of the flow's files.
    case "$(basename "$entry")" in archive|checkouts) continue ;; esac
    mv "$entry" "$dest/"
  done
  note "${dest#"$ROOT"/}"
}

# Tells the human to close the session when this command ran in <here>, inside
# <path>, a worktree just removed: the session's working directory is gone.
side_checkout_close_note() {
  case "$2/" in
    "$1"/*) note "This session's working directory was that side checkout, and it is gone - close this session." ;;
  esac
}
