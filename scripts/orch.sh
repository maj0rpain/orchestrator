#!/usr/bin/env bash
#
# orch.sh - deterministic operations for the orchestrator plugin.
#
# Everything in this file has exactly one right answer: reading and writing
# state, validating handoffs, resolving the default branch, archiving. Prose
# instructions re-derive these slightly differently every session, so they live
# here instead. Judgment lives in the flow skill; mechanism lives here.
#
# Usage: orch.sh <command> [args]   (run `orch.sh help` for the list)

set -euo pipefail

# A tool manager's shim (mise) can print a status line on stdout ahead of the
# tool's own output, which then lands in every `$(gh ...)` capture (#465).
# Silence it for every command this script runs, doctor.sh's checks included.
# Where mise is absent this does nothing.
export MISE_QUIET=1

readonly ORCH_DIR_NAME=".orchestrator"
# The directories the plugin writes to and keeps out of git status: its flow
# state, and .scratch/, where planning drafts land. The one list both
# exclude_orch_dirs and doctor's exclude check read.
readonly EXCLUDED_DIRS=("$ORCH_DIR_NAME/" ".scratch/")
readonly PHASES="spec implement review done"
readonly LABELS_DOC="docs/agents/triage-labels.md"
readonly LABEL_LIMIT=1000
# The most issues or PRs one list call asks gh for, where gh needs a bare
# --limit: the labelled-issue list finding-triage scan reads, and the merged-PR
# bodies pr release reads. A list that reaches it may be missing entries past
# it. Overridable through the environment, like the ORCH_CI_* knobs below, so a
# test can turn it down; it stays out of the documented command surface.
readonly ISSUE_LIST_LIMIT="${ORCH_ISSUE_LIST_LIMIT:-1000}"
# The severities a filed finding carries as review:<severity> - the ones
# `review file` files. Blocking is always fixed in the loop, never filed.
readonly FILED_SEVERITIES="major nit"

# Whether <sev> is a filed severity: the one membership check over
# FILED_SEVERITIES, so adding a severity edits the constant and its label
# colour in `review file`, not every membership check.
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

# How long `review ci` waits, and how often it looks. Overridable through the
# environment rather than through positional arguments: the 60-second grace is
# what stops a repo whose checks have not registered yet being declared CI-less,
# and a test that could not turn it down would take a minute to prove it works.
# The environment keeps those knobs out of the documented command surface.
ORCH_CI_GRACE="${ORCH_CI_GRACE:-60}"
ORCH_CI_TIMEOUT="${ORCH_CI_TIMEOUT:-900}"
ORCH_CI_INTERVAL="${ORCH_CI_INTERVAL:-10}"

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
# Several answers here are one line of prose followed by detail lines, and it is
# always the first line that carries the verdict.
first_line() { printf '%s\n' "$1" | sed -n 1p; }
# The argument with leading and trailing whitespace removed.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
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

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
readonly ROOT
readonly ORCH="$ROOT/$ORCH_DIR_NAME"
readonly STATE="$ORCH/state.json"
readonly HANDOFF_DIR="$ORCH/handoff"
readonly REVIEW_DIR="$ORCH/review"

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
    *) die "flow_cmd: unknown command: $1" ;;
  esac
  plugin_cmd "$1" "orch-flow's $section section"
}

# Names finding triage, its fallback the skill the command runs, since finding
# triage is no orch-flow section.
finding_triage_cmd() {
  plugin_cmd finding-triage "the orch-finding-triage skill"
}

# Names how to start the next phase in a fresh session, in the host's own
# words: the boundary block's Next line. Junie's fresh-session wording is its
# own, not a flow_cmd name (docs/host-capabilities.md, "Start a fresh
# session"); every other host gets flow_cmd's.
next_phase_cmd() {
  case "$(host_detect)" in
    claude) printf '/clear, then %s' "$(flow_cmd next)" ;;
    junie)  printf '/new, then ask for the next phase with /orch-flow' ;;
    *)      printf 'a fresh session, then %s' "$(flow_cmd next)" ;;
  esac
}

# Every flow state key, one row each, in the order init seeds them into
# state.json: key|default|seed|owner. state_get, state set and init all read
# it, so adding a key is one row. Lines starting with # are comments.
#
# default: what state_get returns for a null or missing value. A flow started
#   by an older release lacks keys a fresh one seeds; each reads back as its
#   default. The default applies only to a null or missing value, never to a
#   stored false (jq's `//` would treat false like null).
# seed: the JSON literal init writes, or arg where init supplies the value at
#   run time (cmd_init types each arg value).
# owner: - for a key state set may write; otherwise the reason it refuses,
#   printed as "state set refuses <key>: <owner>".
STATE_KEYS='slug||arg|init seeds it
# phase_write spec sets the phase straight after init seeds it.
phase||null|use phase advance (review ready and redo also move it)
# Seeded from --issue when given; state.json carries no field for whether it
# was adopted or published - nothing downstream reads that distinction.
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

# Prints column $2 (default, seed or owner) of state key $1's row. An unknown
# key prints nothing and returns non-zero; the caller dies with its own message.
state_key() {
  local k d s o
  while IFS='|' read -r k d s o; do
    case "$k" in '#'*) continue ;; esac
    [ "$k" = "$1" ] || continue
    case "$2" in
      default) printf '%s\n' "$d" ;;
      seed)    printf '%s\n' "$s" ;;
      owner)   printf '%s\n' "$o" ;;
      *)       return 1 ;;
    esac
    return 0
  done <<EOF
$STATE_KEYS
EOF
  return 1
}

# Prints every state key, one per line, in table order.
state_keys() {
  local k rest
  while IFS='|' read -r k rest; do
    case "$k" in '#'*|'') continue ;; esac
    printf '%s\n' "$k"
  done <<EOF
$STATE_KEYS
EOF
}

# Every read of state.json goes through here, so what an absent key means is
# decided in the STATE_KEYS table rather than at each call site. A key outside
# the table dies: a misspelt read would otherwise look exactly like an unset one.
state_get() {
  local default
  default="$(state_key "$1" default)" || die "unknown state key: $1"
  jq -r --arg k "$1" --arg d "$default" '.[$k] | if . == null then $d else . end | tostring' "$STATE"
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

# advance needs the base SHA the review diffs against before leaving implement.
require_base_sha() { require_field "$1" base_sha "no base SHA recorded in state - branch create records it"; }

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
    b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')" || b=""
  fi
  is_branch_name "$b" || b="main"
  printf '%s\n' "$b"
}

# default-branch [--sha]: the default branch's name, or with --sha the default
# SHA - the full SHA of refs/remotes/origin/<default> as it stands. --sha never
# fetches: finding triage reads it right after its scan's fetch set that ref,
# so it names the remote tip the scan used.
cmd_default_branch() {
  local usage="usage: orch.sh default-branch [--sha]" default ref sha
  [ $# -eq 0 ] && { default_branch; return; }
  [ $# -eq 1 ] && [ "$1" = --sha ] || die "$usage"
  default="$(default_branch)"
  ref="refs/remotes/origin/$default"
  sha="$(git rev-parse --verify -q "$ref^{commit}")" \
    || die "no $ref - fetch the default branch first"
  printf '%s\n' "$sha"
}

# The repo orch.sh works on (#520): GH_REPO when the caller set it, else the
# owner/name parsed from the checkout's origin remote - never gh's own default
# repo, which in a fork is the upstream. repo_resolve sets REPO_NAME to
# [HOST/]OWNER/REPO and REPO_SOURCE to GH_REPO or origin, printing nothing; it
# returns non-zero, with both empty, when nothing resolves. A caller that must
# have a repo dies with REPO_REMEDY; doctor reports it instead.
REPO_REMEDY="no GitHub repo to work on: origin is missing or not a GitHub owner/name - set GH_REPO=<owner>/<repo>"
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

# The guard every GitHub call in this file - and in doctor.sh, sourced into it
# - goes through by name (#520): `gh` itself, defined ahead of doctor.sh and the
# ORCH_GH_ADAPTER seam so both pick it up. On first use it resolves the repo
# and exports it as GH_REPO for the rest of the run - with GH_HOST beside it for
# a host other than github.com - so every later call - `gh api`'s
# {owner}/{repo} placeholders and host included - is pinned to it, never to
# gh's own default repo, which in a fork is the upstream. With no repo it dies
# naming GH_REPO. Inside a command substitution `die` would end only that
# subshell, and its message could land in a 2>/dev/null, so there it signals
# the main shell, whose USR1 trap dies with the remedy instead. Its last line is
# the only call to the real gh binary in orch.sh and doctor.sh.
gh() {
  if [ -z "${GH_REPO:-}" ]; then
    if ! repo_resolve; then
      if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then kill -USR1 "$$"; exit 1; fi
      die "$REPO_REMEDY"
    fi
    export GH_REPO="$REPO_NAME"
  fi
  repo_pin_host
  command gh "$@"
}

# gh api fills {owner}/{repo} from GH_REPO but takes its host only from
# GH_HOST, never from GH_REPO's host part (gh 2.102.0). So a HOST/OWNER/REPO
# GH_REPO also exports GH_HOST=HOST; an OWNER/REPO one, a github.com repo,
# leaves GH_HOST as it is.
repo_pin_host() {
  case "$GH_REPO" in
    */*/*) export GH_HOST="${GH_REPO%%/*}" ;;
  esac
}
trap 'die "$REPO_REMEDY"' USR1

cmd_repo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    show)
      case "$*" in
        "") ;;
        --name) ;;
        *) die "usage: orch.sh repo show [--name]" ;;
      esac
      repo_resolve || die "$REPO_REMEDY"
      if [ "${1:-}" = --name ]; then note "$REPO_NAME"; else note "$REPO_NAME ($REPO_SOURCE)"; fi
      ;;
    *) die "unknown repo op: ${op:-<none>} (want show)" ;;
  esac
}

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
base_source() { if [ -n "$(base_setting)" ]; then echo set; else echo default; fi; }

# The active flow's own base branch, recorded by init. A flow started before
# base was recorded has none, and always forked from the default branch.
flow_base() {
  local b
  b="$(state_get base)"
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

# Dies unless origin answers that it has branch $1 - the one check both
# `base set` and `base set --flow` make before writing anything.
require_on_origin() {
  local st=0
  origin_has_branch "$1" || st=$?
  case "$st" in
    0) ;;
    2) die "branch $1 does not exist on origin - push it first, or check the name" ;;
    *) die "could not reach origin to check that branch $1 exists - nothing was set" ;;
  esac
}

# Whether a flow is active: state.json exists and its phase is not done.
flow_active() { [ -f "$STATE" ] && [ "$(state_get phase)" != "done" ]; }

# A flow's base is fixed when init seeds it: no redo and no change to the
# checkout setting rewrites it, so its fork point and PR target cannot move
# under it. base set --flow is the one exception: the explicit correction of
# the active flow's own base, allowed only while the flow has no branch -
# before it first branches, or after redo review retires that branch. The
# checks run in a fixed order and the first that fails is reported; nothing is
# written unless all pass. The name is stored literally, the default branch's
# own included: a flow's base is pinned, unlike the checkout setting.
base_set_flow() {
  local b="$1" branch slug
  flow_active || die "no active flow - nothing was set"
  branch="$(state_get branch)"
  if [ -n "$branch" ]; then
    slug="$(state_get slug)"
    if [ "$(state_get phase)" = review ]; then
      die "flow $slug already has branch $branch - its base can change again once $(flow_cmd redo) retires it"
    fi
    die "flow $slug already has branch $branch - its base can no longer change; abort to start again on another base"
  fi
  is_branch_name "$b" || die "$b is not a valid branch name - nothing was set"
  require_on_origin "$b"
  state_write_string base "$b"
  note "$b (flow)"
}

cmd_base() {
  local op="${1:-}" b="" flow=0 a
  shift || true
  case "$op" in
    set)
      # --flow may come before or after the one branch name; anything else is
      # a usage error.
      for a in "$@"; do
        if [ "$a" = --flow ] && [ "$flow" -eq 0 ]; then flow=1
        elif [ -z "$b" ] && [ "$a" != --flow ]; then b="$a"
        else die "usage: orch.sh base set <branch> [--flow]"
        fi
      done
      [ -n "$b" ] || die "usage: orch.sh base set <branch> [--flow]"
      if [ "$flow" -eq 1 ]; then base_set_flow "$b"; return; fi
      require_on_origin "$b"
      # The default branch's own name is no setting at all: storing it would
      # pin today's default and outlive a rename of it.
      if [ "$b" = "$(default_branch)" ]; then
        git config --unset orchestrator.base 2>/dev/null || true
      else
        git config orchestrator.base "$b"
      fi
      note "$(base_branch) ($(base_source))"
      # The setting only reaches flows started after it; say so rather than
      # let the active flow's PR surprise anyone by targeting its old base.
      if flow_active; then
        local fb; fb="$(flow_base)"
        [ "$fb" = "$(base_branch)" ] ||
          note "note: the active flow $(state_get slug) keeps its own base branch: $fb"
      fi
      ;;
    show)
      [ $# -eq 0 ] || die "usage: orch.sh base show"
      note "$(base_branch) ($(base_source))"
      ;;
    clear)
      [ $# -eq 0 ] || die "usage: orch.sh base clear"
      git config --unset orchestrator.base 2>/dev/null || true
      note "$(base_branch) ($(base_source))"
      ;;
    *) die "unknown base op: ${op:-<none>} (want set|show|clear)" ;;
  esac
}

# --- parallel ----------------------------------------------------------------
# The clone's parallel cap: how many ticket subagents one frontier runs at once,
# 1 meaning sequential. Read here alone, so the default lives in one place and
# the skills never call git config; it is set with git config orchestrator.parallel.
PARALLEL_DEFAULT=3
cmd_parallel() {
  local op="${1:-}" v
  shift || true
  case "$op" in
    show)
      [ $# -eq 0 ] || die "usage: orch.sh parallel show"
      v="$(git config --get orchestrator.parallel 2>/dev/null || true)"
      [ -n "$v" ] || v="$PARALLEL_DEFAULT"
      [[ "$v" =~ ^[0-9]+$ ]] && [ "$((10#$v))" -gt 0 ] ||
        die "orchestrator.parallel is $v - it must be a positive integer (git config orchestrator.parallel <n>)"
      note "$((10#$v))"
      ;;
    *) die "unknown parallel op: ${op:-<none>} (want show)" ;;
  esac
}

# Ignore every directory in EXCLUDED_DIRS - the flow directory and .scratch/ -
# without touching a tracked .gitignore, so running the orchestrator in an
# unfamiliar repo never dirties its working tree. A line already present is
# never written again. The file is the clone's shared one (the common dir),
# the only info/exclude git reads, so a linked worktree writes it too.
exclude_orch_dirs() {
  local ex d
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  for d in "${EXCLUDED_DIRS[@]}"; do
    grep -qxF "$d" "$ex" 2>/dev/null || printf '%s\n' "$d" >>"$ex"
  done
}

# --- doctor -----------------------------------------------------------------
#
# Sourced rather than inlined: a change to how checks register, gate, or count
# then concentrates in doctor.sh instead of sharing file scope with the flow
# commands below.
source "$(dirname "${BASH_SOURCE[0]}")/doctor.sh"

# The one definition of the planning allowlist and the planning records,
# shared with hook-guard.sh so the flow-start check and the edit guard can
# never disagree about them.
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

# --- state ------------------------------------------------------------------

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
    die "git status failed - cannot check the working tree: $(first_line "$err")"
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

# The git-based backstop from ADR-0013. Where no host hook arms the edit
# guard, planning can edit source unhindered; flow start is where that gets
# caught, before any state exists. Runs against $ROOT, this working tree's own
# top level, so a flow started inside a worktree (ADR-0008) is judged by that
# worktree's changes and not by the checkout it was forked from.
require_clean_outside_allowlist() {
  local dirty records="" outside="" path msg outside_block
  dirty="$(dirty_outside_allowlist)" || exit 1
  [ -z "$dirty" ] && return 0
  while IFS= read -r path; do
    if planning_record "$path"; then
      records+="$path"$'\n'
    else
      outside+="$path"$'\n'
    fi
  done <<<"$dirty"
  outside_block="$(printf '%s' "$outside" | sed 's/^/       /')
     Planning may only change: $(planning_allowlist_text)."
  # With only source paths dirty, the message is exactly as before the
  # planning records (#186) got their own block.
  if [ -z "$records" ]; then
    die "the working tree has changes outside the planning allowlist:
$outside_block
     Commit, stash, or discard these changes, then run init again."
  fi
  # The redirect is one long sentence pair shared with the guard; wrapped here
  # to the message's own indent and width.
  msg="the working tree has changes planning does not make.
     Planning records changed (planning does not edit these in place):
$(printf '%s' "$records" | sed 's/^/       /')
$(planning_record_redirect | fold -s -w 75 | sed 's/ *$//; s/^/     /')"
  # Committing a record from planning is the option ADR-0022 rejects, so
  # records are only ever discarded or stashed once their wording has moved.
  if [ -z "$outside" ]; then
    die "$msg
     Discard or stash these changes, then run init again."
  fi
  die "$msg
     Changes outside the planning allowlist:
$outside_block
     Discard or stash the planning records; commit, stash, or discard the other
     changes, then run init again."
}

cmd_init() {
  local usage="usage: orch.sh init <slug> [--issue N]"
  local slug="${1:-}" issue=""
  [ -n "$slug" ] || die "$usage"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        issue="${2:-}"
        [ -n "$issue" ] || die "$usage"
        case "$issue" in
          ''|*[!0-9]*) die "--issue wants a plain issue number, got: $issue" ;;
        esac
        shift 2 ;;
      *) die "unknown init flag: $1 (want --issue)" ;;
    esac
  done
  slug="$(normalize_slug "$slug")"
  # A "done" flow already succeeded - its handoffs are read by no later phase,
  # so it is not "active" in any sense that matters. init archives it and
  # proceeds instead of refusing; every other phase still blocks a second flow.
  local archive_note=""
  if flow_active; then
    die "a flow is already active (slug: $(state_get slug), phase: $(state_get phase)).
     One flow at a time - finish it, or run $(flow_cmd abort)."
  fi
  require_clean_outside_allowlist
  # Adoption is validated before anything is written, mirroring how
  # branch create and pr open die on their own preconditions rather than
  # letting a whole phase run against an issue that cannot back it. Validating
  # before archiving a done flow means a bad --issue leaves it untouched and
  # re-runnable rather than archived for nothing.
  [ -z "$issue" ] || validate_adopted_issue "$issue"
  # The whole seed is built before a done flow is archived or anything is
  # written, so a lookup that dies leaves the previous state untouched. The
  # constant part comes from STATE_KEYS, a null placeholder for each arg row
  # keeping the table's key order; the arg values merge over it, typed here.
  # For base, see the header of base_set_flow.
  local k v fields="" seed
  for k in $(state_keys); do
    v="$(state_key "$k" seed)" || die "no seed for state key: $k"
    [ "$v" != arg ] || v=null
    fields="${fields:+$fields,}\"$k\":$v"
  done
  seed="$(jq -n --arg slug "$slug" --arg now "$(now)" --arg issue "$issue" --arg base "$(base_branch)" \
    "{$fields}"' + {
      slug: $slug, issue: (if $issue == "" then null else ($issue | tonumber) end),
      base: $base, created: $now, updated: $now
    }')" || die "could not build the state seed - nothing was written"
  if [ -f "$STATE" ]; then
    archive_note="$(cmd_archive)" || exit 1
  fi
  mkdir -p "$HANDOFF_DIR" "$REVIEW_DIR"
  exclude_orch_dirs
  printf '%s\n' "$seed" >"$STATE"
  phase_write spec
  [ -z "$archive_note" ] || note "$archive_note"
  note "$slug"
}

cmd_slug() {
  local raw="${1:-}" slug
  [ -n "$raw" ] || die "usage: orch.sh slug <text>"
  slug="$(normalize_slug "$raw")"
  note "$slug"
}

cmd_state() {
  local op="${1:-get}"
  shift || true
  case "$op" in
    get)
      require_state
      if [ $# -gt 0 ]; then state_get "$1"; else cat "$STATE"; fi
      ;;
    set)
      require_state
      [ $# -eq 2 ] || die "usage: orch.sh state set <key> <value>"
      # Only the keys skill prose sets are public. Every other key has a
      # command that owns it, and that command's guard is the point: a phase
      # set here would skip the handoff phase advance validates.
      local owner settable="" k
      if ! owner="$(state_key "$1" owner)"; then
        for k in $(state_keys); do
          [ "$(state_key "$k" owner)" = - ] || continue
          settable="${settable:+$settable, }$k"
        done
        die "state set refuses $1: settable keys are $settable"
      fi
      [ "$owner" = - ] || die "state set refuses $1: $owner"
      state_write "$1" "$2"
      ;;
    *) die "unknown state op: $op (want get|set)" ;;
  esac
}

# --- handoffs ---------------------------------------------------------------

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

cmd_handoff() {
  local op="${1:-}"
  shift || true
  case "$op" in
    path)
      [ $# -eq 1 ] || die "usage: orch.sh handoff path <phase>"
      # Assign first, print second. `handoff_file_for` dies on a phase it does
      # not know, and inside the printf's own substitution that kills the
      # subshell and leaves printf to succeed - so the caller gets the bare
      # handoff directory and a zero exit, which is worse than no answer.
      local file
      file="$(handoff_file_for "$1")"
      printf '%s/%s\n' "$HANDOFF_DIR" "$file"
      ;;
    validate)
      [ $# -eq 1 ] || die "usage: orch.sh handoff validate <file>"
      handoff_check "$1" ok || return 1
      ;;
    section)
      [ $# -eq 2 ] || die "usage: orch.sh handoff section <file> <heading>"
      local file="$1" heading="## $2"
      [ -f "$file" ] || die "handoff not found: $file"
      local count
      count="$(grep -cxF "$heading" "$file")" || true
      [ "$count" -gt 0 ] || die "section not found: $heading in $file"
      # A handoff with two identical sections is malformed; section_body would
      # print both bodies joined as if they were one.
      [ "$count" -eq 1 ] || die "repeated section: $heading in $file"
      # Trim leading and trailing blank lines, keeping inner ones. A section
      # holding only whitespace prints nothing - the same condition under which
      # handoff_report calls it empty.
      section_body "$file" "$heading" | awk '
        /[^[:space:]]/ { for (; held > 0; held--) print ""; print; seen = 1; next }
        seen { held++ }'
      ;;
    *) die "unknown handoff op: ${op:-<none>} (want path|validate|section)" ;;
  esac
}

# --- phases -----------------------------------------------------------------

# The block that ends every phase, for the handoff the phase now recorded
# reads: the next phase needs a fresh session this one cannot start, so the
# block names it in the host's own words, through next_phase_cmd.
print_boundary() {
  local phase="$1" done_name file next
  case "$phase" in
    spec)      done_name=plan ;;
    implement) done_name=spec ;;
    review)    done_name=implement ;;
    *) die "no phase boundary at phase: $phase - the flow is not between phases" ;;
  esac
  file="$(handoff_file_for "$phase")"
  next="$(next_phase_cmd)"
  printf 'Phase %s complete. Handoff written to %s/%s.\n\n  Next: %s\n' \
    "$done_name" "$HANDOFF_DIR" "$file" "$next"
}

cmd_phase() {
  local op="${1:-}"
  shift || true
  case "$op" in
    advance)
      [ $# -eq 0 ] || die "usage: orch.sh phase advance"
      require_state
      local phase next file _unused
      phase="$(state_get phase)"
      case "$phase" in
        spec)      next=implement ;;
        implement) next=review ;;
        review)    die "the review phase ends through review ready, once the PR is ready - phase advance does not leave it" ;;
        done)      die "the flow is done - there is no phase to advance to" ;;
        *)         die "not a flow phase: '$phase' - run orch.sh doctor --flow" ;;
      esac
      # The handoff this phase writes is the one the next phase reads. It is
      # checked before the state fields so a missing handoff - the likelier
      # gap - is the one reported.
      file="$HANDOFF_DIR/$(handoff_file_for "$next")"
      handoff_check "$file" || case $? in
        2) die "write $file before leaving the $phase phase" ;;
        *) die "$file is not valid - fix it, then run phase advance again; the flow stays at $phase" ;;
      esac
      case "$next" in
        implement) require_issue _unused ;;
        review)    require_branch _unused; require_base_sha _unused; require_pr _unused ;;
      esac
      phase_write "$next"
      print_boundary "$next"
      ;;
    boundary)
      [ $# -eq 0 ] || die "usage: orch.sh phase boundary"
      require_state
      print_boundary "$(state_get phase)"
      ;;
    *) die "unknown phase op: ${op:-<none>} (want advance|boundary)" ;;
  esac
}

# --- review -----------------------------------------------------------------

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

# --- gh adapter -------------------------------------------------------------
#
# The seam between this file's decision logic and the `gh` CLI. A caller like
# severity_label_ensure below calls an adapter function, never `gh` itself, so
# a test can replace one in-process function instead of faking a `gh` binary
# on PATH. Label creation was the first primitive moved behind it, proving the
# seam on the narrowest possible slice (issue #91, first of the #78
# breakdown); the issue-resource primitives below (view/edit/comment/create/
# close, issue #92) extend the same seam to cmd_spec, cmd_issue_publish,
# cmd_review file, and cmd_redo_spec's issue close. Every GitHub call in this
# file, and in doctor.sh, sourced into it, now goes through one (#280).
#
# ORCH_GH_ADAPTER is an opt-in test knob in the same spirit as the ORCH_CI_*
# ones above, but read differently: not a value substituted at load time, but
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

# adapter_issue_body <n>: the issue's body as GitHub holds it, then a newline.
adapter_issue_body() {
  gh issue view "$1" --json body --jq .body
}

# adapter_issue_comments <n>: the issue's comments in COMMENTS_JQ's shape.
adapter_issue_comments() {
  gh issue view "$1" --json comments --jq "$COMMENTS_JQ"
}

# adapter_issue_state_labels <n>: OPEN or CLOSED on the first line, then one
# label per line - none at all for an unlabelled issue.
adapter_issue_state_labels() {
  gh issue view "$1" --json state,labels --jq '.state, (.labels[].name)'
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
  n="$(printf '%s\n' "$out" | sed -n 's#^https\{0,1\}://.*/issues/\([0-9][0-9]*\)$#\1#p' | tail -n 1)"
  if [ -z "$n" ]; then
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

# adapter_issue_relabel <n> <add> <remove>: one edit adding and removing
# labels, each list comma-separated and either one empty. Prints nothing.
adapter_issue_relabel() {
  local n="$1" args=() add=() removals=() l
  [ -z "$2" ] || IFS=, read -r -a add <<<"$2"
  [ -z "$3" ] || IFS=, read -r -a removals <<<"$3"
  for l in ${removals[@]+"${removals[@]}"}; do args+=(--remove-label "$l"); done
  for l in ${add[@]+"${add[@]}"}; do args+=(--add-label "$l"); done
  gh issue edit "$n" ${args[@]+"${args[@]}"} >/dev/null
}

# adapter_issue_close <n> [reason] [comment]: closes the issue, reason
# "completed" or "not planned" (empty or absent, gh's default), posting the
# comment on it where one is given. Prints nothing.
adapter_issue_close() {
  local args=()
  [ -z "${2:-}" ] || args+=(--reason "$2")
  [ -z "${3:-}" ] || args+=(--comment "$3")
  gh issue close "$1" ${args[@]+"${args[@]}"} >/dev/null
}

# adapter_issue_reopen <n>: reopens the issue. Prints nothing.
adapter_issue_reopen() {
  gh issue reopen "$1" >/dev/null
}

# --- pr operations ---

# adapter_pr_create <base> <head> <title> <body-file> [draft]: opens the PR
# from head into base - a draft where draft is "true" - and prints its number
# alone. Fails, printing nothing, where gh succeeded but printed no PR URL.
adapter_pr_create() {
  local args=() out n
  [ "${5:-false}" != true ] || args+=(--draft)
  out="$(gh pr create ${args[@]+"${args[@]}"} --base "$1" --head "$2" --title "$3" --body-file "$4")" || return
  n="$(printf '%s\n' "$out" | sed -n 's#^https\{0,1\}://.*/pull/\([0-9][0-9]*\)$#\1#p' | tail -n 1)"
  if [ -z "$n" ]; then
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
# "no" where it refuses, nothing at all where the repo has no issue to ask it
# of. Fails only where the issue listing itself fails.
adapter_sub_issues_supported() {
  local n
  n="$(gh issue list --state all --limit 1 --json number --jq '.[0].number // empty')" || return
  [ -n "$n" ] || return 0
  if gh api "repos/{owner}/{repo}/issues/$n/sub_issues" >/dev/null 2>&1; then
    printf 'yes\n'
  else
    printf 'no\n'
  fi
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
# that has none. Nothing at all where gh reports no checks, or no required
# ones. gh documents exit 8 for pending checks, still answering the JSON: that
# is read like an exit 0, and where it leaves nothing readable, a single
# pending check with no name or link is printed. Fails where gh answered with
# something jq cannot read.
adapter_pr_checks() {
  local args=("$1") err out tsv st=0
  [ "$2" != required ] || args+=(--required)
  err="$(mktemp)"
  out="$(gh pr checks "${args[@]}" --json bucket,name,link 2>"$err")" || st=$?
  case "$st" in
    0|8) rm -f "$err" ;;
    *)
      if grep -q 'no checks reported\|no required checks' "$err"; then
        rm -f "$err"
        return 0
      fi
      cat "$err" >&2
      rm -f "$err"
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
  err="$(mktemp)"
  out="$(gh api "$2" 2>"$err")" || st=$?
  if [ "$st" != 0 ]; then
    if [ -n "$1" ] && printf '%s\n' "$out" | cat - "$err" | grep -qF -- "$1"; then
      rm -f "$err"
      return 0
    fi
    cat "$err" >&2
    rm -f "$err"
    return "$st"
  fi
  rm -f "$err"
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

# The severity label a filed finding carries, so triage can filter on it. It is
# this plugin's own, so overwriting it is safe: adapter_label_upsert updates a
# label that exists rather than failing on it, and filing works on a repo that
# has never seen the label and on one that has, with no listing step in between.
severity_label_ensure() {
  adapter_label_upsert "$1" "$2" "$3" || die "gh could not create label $1"
}

# The triage label is the repo's, not ours: created only where it is missing,
# and never rewritten, because a maintainer's colour and description on it are
# theirs to keep. A create that fails because the label exists is the common
# case and is ignored; one that fails for any other reason surfaces two lines
# later, when `gh issue create` cannot apply the label.
triage_label_ensure() {
  adapter_label_create "$1" e4e669 "Not yet triaged" 2>/dev/null || true
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

# Float comparison and addition, in awk, because the timings are overridable and
# the tests turn them down to fractions of a second; bash arithmetic is integer
# only and would read a grace of 0.3 as 0. A fractional `sleep` is a GNU/BSD
# extension rather than POSIX, which is a line this file can hold because the
# fractions only ever come from a test - the shipped defaults are whole seconds.
float_lt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
float_add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a + b }'; }

# awk compares a number against a non-numeric string as strings, which makes
# every `float_lt` above true and the poll loop endless. A zero interval is the
# same hazard by a different route: `sleep 0` returns at once and never advances
# the clock the loop sleeps on, leaving it to poll a rate-limited API as fast as
# GitHub will answer. The three knobs are read once, here, before anything
# sleeps on one of them.
require_ci_knobs() {
  local k v
  for k in ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL; do
    eval "v=\$$k"
    case "$v" in
      ''|*[!0-9.]*|*.*.*|.) die "$k is not a number: $v" ;;
    esac
  done
  # Every character is a zero or the point, so the value is zero however it was
  # written - and a glob cannot say that without also matching 0.05.
  case "${ORCH_CI_INTERVAL//[0.]/}" in
    '') die "ORCH_CI_INTERVAL must be greater than zero: $ORCH_CI_INTERVAL" ;;
  esac
}

# The larger of the wall clock and the time this loop has spent asleep. The wall
# clock alone is whole seconds, which a sub-second override never reaches; the
# sleep total alone ignores however long each `gh` call took, which would stretch
# a 15-minute cap well past 15 minutes on a slow connection.
ci_elapsed() { awk -v w="$(( $(date +%s) - $1 ))" -v s="$2" 'BEGIN { print (w > s) ? w : s }'; }

# One turn of the poll loop: wait, then advance both clocks. It assigns to the
# caller's `slept` and `elapsed`, which bash scopes dynamically - threading two
# counters back out through a subshell's stdout would cost more than it explains.
ci_tick() {
  sleep "$ORCH_CI_INTERVAL"
  slept="$(float_add "$slept" "$ORCH_CI_INTERVAL")"
  elapsed="$(ci_elapsed "$started" "$slept")"
}

# When the PR's head was pushed, in epoch seconds: the newest reflog entry of
# the head branch's remote-tracking ref whose new value is the head SHA. Prints
# nothing when there is no such entry - pushed from another machine, or a
# reflog that is not kept - and the grace then counts from the call instead.
ci_push_time() {
  local oid="$1" branch="$2"
  [ -n "$oid" ] && [ -n "$branch" ] || return 0
  git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null || return 0
  git reflog show --date=unix --format='%H %gd' "refs/remotes/origin/$branch" -- 2>/dev/null \
    | awk -v h="$oid" '$1 == h { sub(/.*@\{/, "", $2); sub(/\}$/, "", $2); print $2; exit }' || true
}

# Whether the repo shows no evidence of CI, for review ci's grace (issue
# #476, ADR-0032). Succeeds only when all four signals read as absent:
#   1. workflow files in the PR head's tree, read locally;
#   2. required checks on the base branch, by classic protection or a ruleset;
#   3. a check-run or commit status on an earlier commit of the PR;
#   4. a check-run or commit status on the base branch tip.
# Fails on the first signal present or unreadable. The errors are asymmetric:
# a false "has CI" costs a minute of grace, a false "no CI" marks a PR ready
# over checks nobody verified - so anything this cannot read counts as CI.
# Recomputed on every call: a workflow the PR itself adds is always seen.
no_ci_evidence() {
  local head="$1" base="$2" commits="$3" out sha
  [ -n "$head" ] && [ -n "$base" ] || return 1
  # 1. A head this clone has never fetched is unreadable, not empty.
  git cat-file -e "$head^{commit}" 2>/dev/null || return 1
  # --full-tree: the pathspec is otherwise read from the current directory,
  # and from a subdirectory an empty listing would read as no workflows.
  out="$(git ls-tree --full-tree --name-only "$head" -- .github/workflows/ 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -Eq '\.ya?ml$'; then return 1; fi
  # 2. Required checks, from classic protection or a ruleset. A read that
  # fails is an answer nobody has.
  out="$(adapter_branch_required_checks "$base" 2>/dev/null)" || return 1
  [ -z "$out" ] || return 1
  out="$(adapter_branch_rules "$base" 2>/dev/null)" || return 1
  if printf '%s\n' "$out" | grep -qx required_status_checks; then return 1; fi
  # 4, then 3: the base tip is one ref, the PR's earlier commits may be many.
  ci_ref_unchecked "$base" || return 1
  while IFS= read -r sha; do
    [ -z "$sha" ] || [ "$sha" = "$head" ] || ci_ref_unchecked "$sha" || return 1
  done <<<"$commits"
  return 0
}

# Succeeds when one ref has neither a check-run nor a commit status, and the
# two reads both answered.
ci_ref_unchecked() {
  [ "$(adapter_commit_has_check_runs "$1" 2>/dev/null)" = no ] || return 1
  [ "$(adapter_commit_has_statuses "$1" 2>/dev/null)" = no ]
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
  local pr="$1" scope="$2" out err failed name
  err="$(mktemp)"
  if ! out="$(adapter_pr_checks "$pr" "$scope" 2>"$err")"; then
    note unreachable
    note "      $(first_line "$(cat "$err")")"
    rm -f "$err"
    return 0
  fi
  rm -f "$err"
  if [ -z "$out" ]; then note none; return 0; fi
  failed="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "fail" || $1 == "cancel" { print $2 }')"
  if [ -n "$failed" ]; then
    note failing
    while IFS= read -r name; do [ -z "$name" ] || note "      $name"; done <<<"$failed"
    return 0
  fi
  if printf '%s\n' "$out" | cut -f1 | grep -qx pending; then note pending; return 0; fi
  note green
}

# The flow's flake rerun (issue #525): the failed jobs of the GitHub Actions
# run behind the PR's first failed or cancelled check, whose id is the
# `runs/<id>` segment of that check's link. `gh run rerun` with no id opens a
# prompt a non-interactive caller cannot answer, so the id is always passed.
# Exit 0 means the rerun started, and is the only answer that spends the
# flow's rerun. Exit 1 means the first failing check is no Actions run - an
# outside CI's status - so there is nothing to rerun. Everything else - a usage
# error, no repo, a GitHub that cannot be read, no failing check, a refused
# rerun - goes through die2. The repo is resolved here rather than left to the
# guard, whose death exits 1 and would read as "nothing to rerun".
review_rerun() {
  local pr="${1:-}" out link run name
  [ $# -eq 1 ] || die2 "usage: orch.sh review rerun <pr>"
  case "$pr" in ''|*[!0-9]*) die2 "not a PR number: $pr" ;; esac
  if [ -z "${GH_REPO:-}" ]; then
    repo_resolve || die2 "$REPO_REMEDY"
    export GH_REPO="$REPO_NAME"
  fi
  repo_pin_host
  out="$(adapter_pr_checks "$pr" all 2>&1)" \
    || die2 "gh could not read the checks of PR #$pr: $(first_line "$out")"
  link="$(printf '%s\n' "$out" | awk -F '\t' '$1 == "fail" || $1 == "cancel" { print $2 "\t" $3; exit }')"
  [ -n "$out" ] || die2 "gh could not read the checks of PR #$pr: no checks reported"
  [ -n "$link" ] || die2 "PR #$pr has no failed or cancelled check to rerun"
  name="${link%%$'\t'*}"
  link="${link#*$'\t'}"
  case "$link" in
    */actions/runs/[0-9]*) ;;
    *) warn "check $name on PR #$pr is not a GitHub Actions run - nothing to rerun"
       return 1 ;;
  esac
  run="${link##*/actions/runs/}"   # N/job/M -> N
  run="${run%%/*}"
  case "$run" in ''|*[!0-9]*) warn "check $name on PR #$pr links no Actions run id - nothing to rerun"; return 1 ;; esac
  adapter_run_rerun "$run" 2>/dev/null \
    || die2 "gh could not rerun the failed jobs of Actions run $run"
  note "$run"
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
# record or its section is missing or empty.
review_terminal_state() {
  require_state
  local i b path body first rest after s sep
  i="$(state_get iteration)"
  b="$(review_budget)"
  if [ "$i" -eq 0 ]; then note none; return 1; fi
  if [ "$i" -lt "$b" ]; then note pending; return 1; fi
  path="$(cmd_review path "$i")"
  if [ ! -f "$path" ] || [ -z "$(section_body "$path" '## Terminal state' | tr -d '[:space:]')" ]; then
    note interrupted
    return 1
  fi
  body="$(section_body "$path" '## Terminal state' | awk 'started || NF { started = 1; print }')"
  first="$(trim "$(printf '%s\n' "$body" | sed -n '1p')")"
  rest="$(printf '%s\n' "$body" | tail -n +2)"
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

cmd_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin)
      require_state
      local n budget
      n=$(( $(state_get iteration) + 1 ))
      budget="$(review_budget)"
      [ "$n" -le "$budget" ] || \
        die "budget of $budget iterations spent - stop the loop and report, do not start another"
      state_write iteration "$n"
      note "$n"
      ;;
    path)
      require_state
      [ $# -le 1 ] || die "usage: orch.sh review path [iteration]"
      local n
      n="${1:-$(state_get iteration)}"
      case "$n" in ''|*[!0-9]*) die "not an iteration number: $n" ;; esac
      # Base 10 explicitly: printf reads a zero-padded argument as octal, and
      # `08` is not a number in base 8.
      n=$((10#$n))
      # Flat, and numbered on across every loop the flow runs: one flow, one
      # trail, and nothing is ever moved aside for a loop that comes later.
      mkdir -p "$REVIEW_DIR"
      printf '%s/iteration-%02d.md\n' "$REVIEW_DIR" "$n"
      ;;
    file)
      require_state
      local usage="usage: orch.sh review file <${FILED_SEVERITIES// /|}> <title> --axis <spec|standards> --body-file <file>"
      [ $# -eq 6 ] && [ "$3" = --axis ] && [ "$5" = --body-file ] || die "$usage"
      local severity="$1" title="$2" axis="$4" body="$6" colour category triage n
      is_filed_severity "$severity" \
        || die "not a severity that gets filed: $severity (want ${FILED_SEVERITIES// / or } - blocking is always fixed, never filed)"
      case "$severity" in
        major) colour=d93f0b ;;
        nit)   colour=c5def5 ;;
        *) die "no label colour for filed severity: $severity" ;;
      esac
      # The category follows the axis; finding triage confirms or flips it later.
      category="$(category_for_axis "$axis")" \
        || die "not a review axis: $axis (want spec or standards)"
      [ -n "$title" ] || die "the title is empty"
      [ -f "$body" ] || die "body file not found: $body"
      severity_label_ensure "review:$severity" "$colour" "Review finding filed at $severity severity"
      triage="$(triage_label_for needs-triage)"
      triage_label_ensure "$triage"
      category_label_ensure "$category"
      # The title carries no severity prefix: the label holds it, where triage
      # can change it, and the title reads as an issue.
      n="$(adapter_issue_create "$title" "$body" "review:$severity" "$triage" "$category")" \
        || die "gh could not create the issue"
      # Prints the number alone: the record cites a number, and the caller
      # would otherwise be parsing a URL out of prose every time.
      note "$n"
      ;;
    ready)
      require_state
      local pr
      require_pr pr
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      adapter_pr_ready "$pr" 2>/dev/null \
        || die "gh could not mark PR #$pr ready - the flow stays in review"
      phase_write "done"
      note "$pr"
      ;;
    ci)
      require_state
      local pr started slept=0 elapsed=0 res verdict refs head_oid head_ref base_ref pushed push_age=0
      local commits="" no_ci=0
      require_ci_knobs
      require_pr pr
      started="$(date +%s)"
      # Two clocks: the timeout counts from this call, the grace from the push.
      # By the time the loop ends the fixer's last push is usually minutes old,
      # and a CI that has not registered a check in that time is not about to.
      # `push_age` is how long before this call the push landed; a PR that will
      # not say what its head is, or a head with no reflog entry, leaves it at zero,
      # and the grace counts from the call as it always did.
      if refs="$(adapter_pr_refs "$pr" 2>/dev/null)"; then
        head_oid="$(printf '%s\n' "$refs" | sed -n 1p)"
        head_ref="$(printf '%s\n' "$refs" | sed -n 2p)"
        base_ref="$(printf '%s\n' "$refs" | sed -n 3p)"
        commits="$(printf '%s\n' "$refs" | sed -n '4,$p')"
        pushed="$(ci_push_time "$head_oid" "$head_ref")"
        case "$pushed" in
          ''|*[!0-9]*) ;;
          *) [ "$pushed" -ge "$started" ] || push_age=$(( started - pushed )) ;;
        esac
        # With no evidence of CI anywhere, there is nothing for the grace to
        # wait on. It replaces only the wait: the unfiltered probe still runs,
        # so a check already reported on the head gives its verdict as before.
        if no_ci_evidence "$head_oid" "$base_ref" "$commits"; then
          no_ci=1
        fi
      fi
      while :; do
        # Branch protection's required checks decide it wherever it names any.
        # When nothing required has reported, gh's message cannot tell "this repo
        # requires nothing" from "what it requires has not registered yet" - so
        # the grace is spent waiting on the required set, and only once it runs
        # out does the net widen to every check on the commit. Widening sooner is
        # how an unrelated green check gets mistaken for a required one that
        # never arrived, and the PR marked ready over it.
        res="$(ci_probe "$pr" required)"
        verdict="$(first_line "$res")"
        if [ "$verdict" = none ]; then
          if [ "$no_ci" = 0 ] && float_lt "$(float_add "$push_age" "$elapsed")" "$ORCH_CI_GRACE"; then
            ci_tick; continue
          fi
          res="$(ci_probe "$pr" all)"
          verdict="$(first_line "$res")"
        fi
        case "$verdict" in
          green)       printf '%s\n' "$res"; return 0 ;;
          # Reported, not fixed: which failure is worth a flake rerun is a
          # judgement, and the budget for it belongs to the flow.
          failing)     printf '%s\n' "$res"; return 1 ;;
          unreachable) printf '%s\n' "$res"; return 1 ;;
          # Only reachable with the grace spent or skipped: nothing required
          # reported, and then nothing at all reported either. The detail line
          # says which, here rather than in ci_probe, so doctor's lines are
          # unchanged.
          none)
            printf '%s\n' "$res"
            if [ "$no_ci" = 1 ]; then
              note "      no CI signals found: no workflow files in the head, no required checks on $base_ref, no checks or statuses on earlier PR commits or the $base_ref tip"
            else
              note "      nothing reported before the ${ORCH_CI_GRACE}s grace ran out"
            fi
            return 0 ;;
          pending)
            if float_lt "$elapsed" "$ORCH_CI_TIMEOUT"; then ci_tick; continue; fi
            # Still pending at the cap is an answer we do not have, not a green
            # one. The loop stops rather than marking a PR ready over something
            # nothing ever verified.
            note unreachable
            note "      checks were still pending after ${ORCH_CI_TIMEOUT}s"
            return 1 ;;
          # Unreachable while ci_probe prints one of the five words above, and
          # the arm that keeps it that way: an unrecognised answer with no arm
          # would fall through to the next pass with nothing to wait on, and
          # spin this loop silently on the one command built to be bounded.
          *)
            note unreachable
            note "      unrecognised answer from gh pr checks: $verdict"
            return 1 ;;
        esac
      done
      ;;
    rerun) review_rerun "$@" ;;
    terminal)
      require_state
      [ $# -eq 0 ] || die "usage: orch.sh review terminal"
      review_terminal_state
      ;;
    retire)
      require_state
      [ $# -eq 1 ] || die "usage: orch.sh review retire <n>"
      local n="$1" dest f
      case "$n" in ''|*[!0-9]*) die "not a redo number: $n" ;; esac
      dest="$REVIEW_DIR/pre-redo-$n"
      [ ! -e "$dest" ] || die "$dest already exists - redo_count should only increase"
      mkdir -p "$REVIEW_DIR"
      for f in "$REVIEW_DIR"/iteration-*.md; do
        [ -e "$f" ] || continue
        mkdir -p "$dest"
        mv "$f" "$dest/"
      done
      note "$dest"
      ;;
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|ci|rerun|ready|terminal|retire)" ;;
  esac
}

# --- issue --------------------------------------------------------------
#
# The four stateless issue ops - fetch, comments, update and comment - on an
# issue given just its number: the same contract issue publish/pr
# publish/ticket publish already offer, extended to a plain issue. cmd_spec's
# fetch/comments/update/comment ops below are thin wrappers over all four,
# resolving the issue number from state, so flow's stateful spec access and
# quick implementation's stateless issue access share one tested code path
# instead of two independently-maintained copies. comment is stateless
# because a standalone spec review posts its summary on whatever issue it was
# pointed at, with no flow to resolve one from.
#
# `issue update` stays a dumb "replace the body with these exact bytes"
# primitive - fold-in choreography like fetch-then-append-then-write for
# merging ticket content into a parent belongs in the calling skill's prose,
# not here.

# Runs a gh read into <file>, written beside the target and moved into place
# only once gh has answered: a failed fetch that left a partial file behind is
# a body a caller would mistake for the actual content. <what> names the read
# in the error.
fetch_into() {
  local file="$1" what="$2" tmp
  shift 2
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  if ! "$@" >"$tmp"; then
    rm -f "$tmp"
    die "gh could not read $what"
  fi
  mv "$tmp" "$file"
}

cmd_issue_fetch() {
  local issue="$1" file="$2"
  fetch_into "$file" "the body of issue #$issue" \
    adapter_issue_body "$issue"
}

# Every comment on the issue, in COMMENTS_JQ's shape - so the spec review reads
# the comments beside the body. No comments is an empty file, not an error.
cmd_issue_comments() {
  local issue="$1" file="$2"
  fetch_into "$file" "the comments of issue #$issue" \
    adapter_issue_comments "$issue"
}

cmd_issue_update() {
  local issue="$1" file="$2"
  [ -f "$file" ] || die "body file not found: $file"
  # --body-file, never --body: an issue body carries tables, fences, and
  # `#nn` references, and a heredoc through a shell is where those get
  # mangled.
  adapter_issue_body_edit "$issue" "$file" \
    || die "gh could not replace the body of issue #$issue"
}

cmd_issue_comment() {
  local issue="$1" file="$2"
  [ -f "$file" ] || die "body file not found: $file"
  adapter_issue_comment "$issue" "$file" \
    || die "gh could not comment on issue #$issue"
}

cmd_issue() {
  local op="${1:-}"
  shift || true
  case "$op" in
    fetch|update|comment|comments)
      [ $# -eq 2 ] || die "usage: orch.sh issue $op <n> <file>"
      local issue="$1" file="$2"
      case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue (usage: orch.sh issue $op <n> <file>)" ;; esac
      "cmd_issue_$op" "$issue" "$file"
      ;;
    publish) cmd_issue_publish "$@" ;;
    triage) cmd_issue_triage "$@" ;;
    ready) cmd_issue_ready "$@" ;;
    *) die "unknown issue op: ${op:-<none>} (want fetch|update|comment|comments|publish|triage|ready)" ;;
  esac
}

# issue ready <n>: exit 0 when issue <n> carries the repo's ready-for-agent
# label, 1 when it does not - so exit 1 is a meaningful "no", and a usage
# error or a gh failure exits 2 (die2), as ticket exists does. The spec
# skill's rewrite mode reads it to warn when a rewritten issue lacks the label.
cmd_issue_ready() {
  local usage="usage: orch.sh issue ready <n>"
  [ $# -eq 1 ] || die2 "$usage"
  local issue="$1" ready out
  case "$issue" in ''|*[!0-9]*) die2 "issue must be a plain issue number, got: $issue ($usage)" ;; esac
  ready="$(triage_label_for ready-for-agent)"
  out="$(adapter_issue_state_labels "$issue")" \
    || die2 "gh could not read issue #$issue"
  printf '%s\n' "$out" | tail -n +2 | grep -qxF -- "$ready"
}

# --- spec -------------------------------------------------------------------

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the four ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
# All four ops delegate to the issue primitives above, resolving the number
# from state. A done flow's issue is finished work: state.json lingers after
# the flow ends, so a spec op there would quietly touch an issue nobody is
# reviewing any more - it refuses and points at the stateless issue ops.
cmd_spec() {
  local op="${1:-}"
  shift || true
  require_state
  case "$op" in
    fetch|update|comment|comments) ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment|comments)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment|comments> <file>"
  local file="$1" issue
  require_issue issue
  [ "$(state_get phase)" != "done" ] \
    || die "the flow on issue #$issue is done - spec $op acts only on an active flow's issue; for another issue use orch.sh issue $op <n> <file>"
  "cmd_issue_$op" "$issue" "$file"
}

# --- spec-review ------------------------------------------------------------

# A standalone spec review's start: the guard and the working-directory reset
# each have one right answer, so they live here rather than in skill prose.
# It reads state.json only when one exists, never through require_state - it
# dies with no flow, and no flow is the common case - and never writes it.
# The issue number is the caller's, never state's: the guard only compares.
# State holds only the phases in PHASES, so every not-done phase is one below.
cmd_spec_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) ;;
    *) die "unknown spec-review op: ${op:-<none>} (want begin)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec-review begin <n>"
  local issue="$1"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  if [ -f "$STATE" ]; then
    local phase held
    phase="$(state_get phase)"
    held="$(state_get issue)"
    if [ "$phase" != "done" ] && [ "$held" = "$issue" ]; then
      case "$phase" in
        spec)
          die "the active flow holds issue #$issue at phase spec - the flow's own spec phase will review it; run $(flow_cmd next)" ;;
        implement|review)
          die "the active flow holds issue #$issue at phase $phase - the ticket subagents build from this spec, so it cannot change behind the flow; run $(flow_cmd redo) to step back to the spec phase" ;;
        *)
          die "the active flow holds issue #$issue at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
      esac
    fi
  fi
  # Built from the validated number alone, so the wipe stays inside
  # spec-review/.
  local dir="$ORCH/spec-review/$issue"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s/\n' "$dir"
}

# --- review-pass ------------------------------------------------------------

# A review pass's start, for a quick implementation's step 6 and a standalone
# review pass alike: the guard and the numbered report prefix each have one
# right answer, so they live here rather than in skill prose. Needs no flow
# state and may run where init never did, so it excludes the orchestrator
# directories itself. It reads state.json only when one exists, never through
# require_state, and never writes it: a branch or issue an active flow holds
# belongs to that flow (ADR-0029). Never wipes - each pass takes the next
# number, so a second pass on a branch never overwrites the first.
cmd_review_pass() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) ;;
    *) die "unknown review-pass op: ${op:-<none>} (want begin)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh review-pass begin <issue>"
  local issue="$1" branch
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  [ "$branch" != "$(recorded_base "$branch")" ] \
    || die "$branch is the base branch - a review pass reviews a branch's change against it; check out the change's branch"
  if [ -f "$STATE" ]; then
    local phase held held_branch
    phase="$(state_get phase)"
    held="$(state_get issue)"
    held_branch="$(state_get branch)"
    if [ "$phase" != "done" ] && { [ "$held" = "$issue" ] || [ "$held_branch" = "$branch" ]; }; then
      case "$phase" in
        implement|review)
          die "the active flow holds issue #$held at phase $phase - this change belongs to that flow's review loop; run $(flow_cmd next)" ;;
        spec)
          die "the active flow holds issue #$held at phase spec - its change has not been built yet; run $(flow_cmd next)" ;;
        *)
          die "the active flow holds issue #$held at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
      esac
    fi
  fi
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

# --- finding-triage ---------------------------------------------------------

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

# scan_line <file:lines> <result> <detail>: the scan's one line, in the
# columns `finding-triage scan` prints. Local to finding_scan_one in effect: it
# reads the issue and PR number, n and pr, from that call's locals, through
# bash's dynamic scope, and prints - for an empty PR.
scan_line() {
  printf '%s\t%s\t%s\t%s\t%s\n' "$n" "${pr:--}" "$1" "$2" "$3"
}

# finding_scan_one <issue> <body> <default ref>: the scan's one line for one
# finding.
finding_scan_one() {
  local n="$1" body="$2" ref="$3" loc pr file lines sha resolved_sha start end new_start new_end detail file_commit log_out
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
  # The newest commit since the filing that touched the finding's lines. The
  # output is captured whole before filtering: piping it into grep -m1 could
  # SIGPIPE git and pass for a failure under pipefail.
  if log_out="$(git log -1 --format=%H -L "$new_start,$new_end:$file" "$ref" "^$resolved_sha" 2>/dev/null)"; then
    detail="$(printf '%s\n' "$log_out" | grep -Ex '[0-9a-f]{40}' | head -n 1)" || true
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

# finding-triage scan [<issue> | --pr <n>]: read-only. Sorts each open filed
# finding still in needs-triage against origin/<default>, one tab-separated
# line apiece: <issue> <pr> <file>:<line> <result> <detail>.
cmd_finding_triage_scan() {
  local usage="usage: orch.sh finding-triage scan [<issue> | --pr <n>]"
  local issue="" pr_filter="" triage sev nums="" n out state labels body default ref
  case $# in
    0) ;;
    1) issue="$1" ;;
    2) [ "$1" = --pr ] && [ -n "$2" ] || die "$usage"; pr_filter="$2" ;;
    *) die "$usage" ;;
  esac
  case "$issue$pr_filter" in *[!0-9]*) die "$usage" ;; esac
  triage="$(triage_label_for needs-triage)"
  if [ -n "$issue" ]; then
    out="$(adapter_issue_state_labels "$issue")" \
      || die "gh could not read issue #$issue"
    state="$(first_line "$out")"
    labels="$(printf '%s\n' "$out" | tail -n +2)"
    [ "$state" = OPEN ] || die "issue #$issue is not open - finding triage takes open filed findings only"
    has_filed_severity_label "$labels" \
      || die "issue #$issue is not a filed finding - it carries no review:<severity> label for a filed severity (review:${FILED_SEVERITIES// / or review:})"
    printf '%s\n' "$labels" | grep -qxF "$triage" \
      || die "issue #$issue is not in triage - it carries no '$triage' label"
    nums="$issue"
  else
    for sev in $FILED_SEVERITIES; do
      out="$(adapter_issues_labelled "review:$sev" "$triage")" \
        || die "gh could not list the review:$sev findings"
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
    body="$(adapter_issue_body "$n")" || die "gh could not read issue #$n"
    if [ -n "$pr_filter" ] && [ "$(finding_pr "$body")" != "$pr_filter" ]; then continue; fi
    finding_scan_one "$n" "$body" "$ref"
  done
}

# finding-triage apply <issue> <outcome> [--category <bug|enhancement>]
# --comment-file <file>: finding triage's one write to GitHub. Posts the
# comment under the AI disclaimer, moves the issue out of needs-triage, and
# either closes it (close-fixed: completed; wontfix: not planned, labelled
# wontfix) or labels it with its state, keeping review:<severity> and leaving
# exactly the one category asked for. Every state label is the repo's name for
# the role. Only a failed category-label create is forgiven; any other failed
# gh call dies.
cmd_finding_triage_apply() {
  local usage="usage: orch.sh finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
       orch.sh finding-triage apply <issue> <ready-for-agent|ready-for-human> --category <bug|enhancement> --comment-file <file>"
  local issue="${1:-}" outcome="${2:-}" category="" file="" labels triage stale_category tmp
  # The labels to remove, comma-separated, possibly none: close-fixed, where
  # that is the whole relabel, skips an empty one rather than send a bare edit.
  local remove=""
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

  labels="$(adapter_issue_state_labels "$issue")" \
    || die "gh could not read issue #$issue"
  labels="$(printf '%s\n' "$labels" | tail -n +2)"
  triage="$(triage_label_for needs-triage)"
  # Remove only what the issue carries: gh refuses to remove a label the
  # repo does not have at all.
  if printf '%s\n' "$labels" | grep -qxF -- "$triage"; then remove="$triage"; fi

  tmp="$(mktemp)"
  { printf '%s\n\n' '> *This was generated by AI during triage.*'; cat "$file"; } >"$tmp"
  if ! adapter_issue_comment "$issue" "$tmp"; then
    rm -f "$tmp"
    die "gh could not comment on issue #$issue"
  fi
  rm -f "$tmp"

  case "$outcome" in
    close-fixed)
      if [ -n "$remove" ]; then
        adapter_issue_relabel "$issue" "" "$remove" || die "gh could not relabel issue #$issue"
      fi
      adapter_issue_close "$issue" completed || die "gh could not close issue #$issue" ;;
    wontfix)
      adapter_issue_relabel "$issue" "$(triage_label_for wontfix)" "$remove" \
        || die "gh could not relabel issue #$issue"
      adapter_issue_close "$issue" "not planned" || die "gh could not close issue #$issue" ;;
    *)
      category_label_ensure "$category"
      if printf '%s\n' "$labels" | grep -qxF -- "$stale_category"; then remove="${remove:+$remove,}$stale_category"; fi
      adapter_issue_relabel "$issue" "$(triage_label_for "$outcome"),$category" "$remove" \
        || die "gh could not relabel issue #$issue" ;;
  esac
}

cmd_finding_triage() {
  local op="${1:-}"
  shift || true
  case "$op" in
    scan) cmd_finding_triage_scan "$@" ;;
    apply) cmd_finding_triage_apply "$@" ;;
    *) die "usage: orch.sh finding-triage <scan|apply> ..." ;;
  esac
}

# --- git / github -----------------------------------------------------------

# Forking a named branch off a base branch has exactly one right answer -
# fetch it, then check it out, falling back to the local ref if origin was
# unreachable - so both branch create (a flow's own naming and state) and
# branch off (a quick implementation's, which keeps no state) share it rather
# than each hand-rolling the fetch/checkout-fallback idiom. The caller names
# the base: a flow's is the one it recorded at init. The caller also names
# the remedy for a base origin says is gone ($3), since only a flow has a
# base it can correct.
checkout_new_branch() {
  local name="$1" base="$2" remedy="${3:-start again on another base branch}"
  if git rev-parse --verify --quiet "$name" >/dev/null; then die "branch $name already exists"; fi
  if ! git fetch --quiet origin "$base" 2>/dev/null; then
    # Only an origin that could not be asked earns the local fallback: one
    # that answered "no such branch" means the base is gone, and forking from
    # a stale local copy of it would build on work nobody will merge.
    local st=0
    origin_has_branch "$base" || st=$?
    [ "$st" -ne 2 ] || die "base branch $base does not exist on origin - push it, or $remedy"
  fi
  git checkout -q -b "$name" "origin/$base" 2>/dev/null || git checkout -q -b "$name" "$base"
}

cmd_branch_create() {
  require_state
  [ $# -eq 0 ] || die "usage: orch.sh branch create"
  local slug issue name
  slug="$(state_get slug)"
  require_issue issue
  name="orch/${issue}-${slug}"
  checkout_new_branch "$name" "$(flow_base)" \
    "point this flow at another base: orch.sh base set <branch> --flow"
  state_write branch "$name"
  state_write base_sha "$(git rev-parse HEAD)"
  note "$name"
}

# A quick implementation keeps no state.json, so it has nothing to derive a
# name from - the caller passes the full name. It forks from the base branch in
# effect and records that base on the branch itself in local git config, so
# pr publish targets it even if the setting moves in the meantime - and records
# the base branch's tip at branching as the branch's base SHA, the meaning a
# flow's base_sha has, for its reviewers to diff from.
cmd_branch_off() {
  [ $# -eq 1 ] || die "usage: orch.sh branch off <name>"
  local base
  base="$(base_branch)"
  checkout_new_branch "$1" "$base"
  git config "branch.$1.orchestrator-base" "$base"
  git config "branch.$1.orchestrator-base-sha" "$(git rev-parse HEAD)"
  note "$1"
}

# The base branch a branch belongs to: the one branch off recorded for it, else,
# for a branch made before that was recorded, the base branch in effect now.
# The one rule pr publish targets and branch base-sha falls back to, so the PR
# and the SHA its review diffs from never name different bases.
recorded_base() {
  git config --get "branch.$1.orchestrator-base" 2>/dev/null || base_branch
}

# The current branch's base SHA, as branch off recorded it. A branch made
# before that was recorded falls back to the merge-base with its recorded_base,
# preferring origin's copy of it. Only a fallback: a base merged in mid-branch
# moves the merge-base and silently shrinks the diff it bounds.
cmd_branch_base_sha() {
  [ $# -eq 0 ] || die "usage: orch.sh branch base-sha"
  local branch sha base ref
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  sha="$(git config --get "branch.$branch.orchestrator-base-sha" 2>/dev/null)" || sha=""
  if [ -n "$sha" ]; then note "$sha"; return; fi
  base="$(recorded_base "$branch")"
  if git rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
    ref="refs/remotes/origin/$base"
  elif git rev-parse --verify --quiet "refs/heads/$base" >/dev/null; then
    ref="refs/heads/$base"
  else
    die "base branch $base of $branch is neither on origin nor local - no base SHA to fall back to"
  fi
  git merge-base HEAD "$ref" || die "$branch shares no history with base branch $base"
}

cmd_branch() {
  local op="${1:-}"
  shift || true
  case "$op" in
    create) cmd_branch_create "$@" ;;
    off)    cmd_branch_off "$@" ;;
    base-sha) cmd_branch_base_sha "$@" ;;
    retire)
      [ $# -eq 2 ] || die "usage: orch.sh branch retire <old> <new>"
      local old="$1" new="$2" upstream="" old_ok=1 new_ok=1
      git rev-parse --verify --quiet "$old" >/dev/null 2>&1 || old_ok=0
      git rev-parse --verify --quiet "$new" >/dev/null 2>&1 || new_ok=0
      if [ "$old_ok" = 1 ] && [ "$new_ok" = 1 ]; then
        die "branch $new already exists"
      elif [ "$old_ok" = 0 ] && [ "$new_ok" = 0 ]; then
        die "branch $old does not exist"
      elif [ "$old_ok" = 1 ]; then
        upstream="$(git rev-parse --abbrev-ref --verify --quiet "$old@{upstream}" 2>/dev/null)" || upstream=""
        git branch -m "$old" "$new"
      else
        # $old is already gone and $new already exists: a previous call's
        # local rename succeeded and it died on the remote push or delete
        # below - resume from there instead of failing on "$old does not
        # exist", the unretryable state issue #63 named. Reaching this state
        # is only possible by way of the upstream branch below, since a
        # no-upstream retire has no later step left to die on - so the
        # remote steps still needing doing is a safe assumption here.
        upstream=origin
      fi
      # A leftover remote ref under the un-suffixed name is exactly what the
      # next implement attempt's branch create/pr open will reuse, and their
      # plain push is not a force-push - so the old ref's delete is not
      # optional, and both failures die rather than leaving origin out of
      # sync with what this rename just did locally.
      if [ -n "$upstream" ]; then
        # The rename above is local-only and free to undo - if the push
        # never lands, undoing it is what keeps `$old` a real, retryable
        # branch instead of a name a retry can no longer find.
        git push -q -u origin "$new" \
          || { git branch -m "$new" "$old"; die "could not push $new to origin"; }
        if ! git push -q origin --delete "$old" 2>/dev/null; then
          # Already gone - a previous call's delete already succeeded before
          # something else failed - is not an error to retry into; only a
          # ref that is still there and won't go is.
          git ls-remote --exit-code origin "refs/heads/$old" >/dev/null 2>&1 \
            && die "could not delete origin/$old"
        fi
      fi
      note "$new"
      ;;
    *) die "unknown branch op: ${op:-<none>} (want create|off|base-sha|retire)" ;;
  esac
}

# True only once the created issue reads back with the title it was given
# and the ready-for-agent role's label among its labels. Read fresh every
# call, never cached - the caller retries this on a mismatch, as
# ticket_links_verified's caller does.
issue_publish_verified() {
  local n="$1" title="$2" label="$3" out
  out="$(adapter_issue_title_labels "$n" 2>/dev/null)" \
    || return 1
  [ "$(first_line "$out")" = "$title" ] || return 1
  printf '%s\n' "$out" | tail -n +2 | grep -qxF "$label"
}

# The publishing boundary a spec and a quick implementation call instead of
# hardcoding `gh issue create` in skill prose - the same reason `review file`
# owns its own `gh issue create` rather than leaving it to whichever skill
# files a finding. Stateless like branch off: the caller may have no flow to
# record into, so the title and body are its own and nothing here remembers
# them. Verify-then-die like ticket publish: the issue is created under the
# ready-for-agent role's label (an agent works it next), then its title and
# labels are read back - one retry on a mismatch, a second failure dies
# naming the issue, so a half-published spec never reaches the next step.
cmd_issue_publish() {
  [ $# -eq 2 ] || die "usage: orch.sh issue publish <title> <body-file>"
  local title="$1" body_file="$2" ready n
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  ready="$(triage_label_for ready-for-agent)"
  n="$(adapter_issue_create "$title" "$body_file" "$ready")" \
    || die "gh could not create the issue"
  issue_publish_verified "$n" "$title" "$ready" \
    || issue_publish_verified "$n" "$title" "$ready" \
    || die "issue #$n's title and '$ready' label did not verify - checked twice, both failed"
  note "$n"
}

# True only once the issue reads back carrying <ready> and none of the
# comma-separated <removed> labels. Read fresh every call, never cached - the
# caller re-reads once on a mismatch, as issue publish's does.
issue_triage_verified() {
  local n="$1" ready="$2" out labels l removed=()
  out="$(adapter_issue_state_labels "$n" 2>/dev/null)" || return 1
  labels="$(printf '%s\n' "$out" | tail -n +2)"
  printf '%s\n' "$labels" | grep -qxF -- "$ready" || return 1
  [ -z "$3" ] || IFS=, read -r -a removed <<<"$3"
  for l in ${removed[@]+"${removed[@]}"}; do
    ! printf '%s\n' "$labels" | grep -qxF -- "$l" || return 1
  done
}

# issue triage <n> [--override]: moves an open issue to the repo's
# ready-for-agent label, so init --issue can adopt it - the planning close's
# one write to GitHub (#571). One relabel adds ready-for-agent and removes
# whichever other triage-role labels the issue carries, then the labels are
# read back (ADR-0011), and one comment names the label it now carries.
cmd_issue_triage() {
  local usage="usage: orch.sh issue triage <n> [--override]"
  local issue="" override=false ready out labels remove="" role label
  while [ $# -gt 0 ]; do
    case "$1" in
      --override) override=true ;;
      -*) die "$usage" ;;
      *) [ -z "$issue" ] || die "$usage"; issue="$1" ;;
    esac
    shift
  done
  case "$issue" in ''|*[!0-9]*) die "$usage" ;; esac
  ready="$(triage_label_for ready-for-agent)"

  out="$(adapter_issue_state_labels "$issue")" \
    || die "gh could not read issue #$issue"
  labels="$(printf '%s\n' "$out" | tail -n +2)"
  [ "$(first_line "$out")" = OPEN ] \
    || die "issue #$issue is not open - only an open issue is triaged to '$ready'"
  # A filed finding not yet triaged comes back into the pipeline through
  # finding triage first, which checks it against the default branch
  # (ADR-0031). Only the labels finding triage itself applies - ready-for-agent,
  # ready-for-human, wontfix - show it ran; after that the finding is an
  # ordinary issue, and the interview settles what ready-for-human waited on.
  # The gate reads labels, not history, and --override does not bypass it. Any
  # review:<severity> label marks a finding, not only the severities filed today.
  local finding triaged=false
  if has_review_label "$labels"; then
    finding="$(review_labels "$labels" | sed -n 1p)"
    for role in ready-for-agent ready-for-human wontfix; do
      label="$(triage_label_for "$role")"
      if printf '%s\n' "$labels" | grep -qxF -- "$label"; then triaged=true; fi
    done
    [ "$triaged" = true ] \
      || die "issue #$issue is a filed finding ($finding) not yet triaged - triage it with $(finding_triage_cmd)"
  fi
  # Already ready: nothing to move, and no comment to leave as noise.
  if printf '%s\n' "$labels" | grep -qxF -- "$ready"; then return 0; fi
  # A deliberate triage decision is the human's to reverse: exit 2 is no
  # failure but a request for that decision, the label found on stdout.
  if [ "$override" = false ]; then
    for role in wontfix ready-for-human; do
      label="$(triage_label_for "$role")"
      if printf '%s\n' "$labels" | grep -qxF -- "$label"; then
        note "$label"
        exit 2
      fi
    done
  fi
  for role in $TRIAGE_ROLES; do
    [ "$role" != ready-for-agent ] || continue
    label="$(triage_label_for "$role")"
    if printf '%s\n' "$labels" | grep -qxF -- "$label"; then
      remove="${remove:+$remove,}$label"
    fi
  done

  adapter_issue_relabel "$issue" "$ready" "$remove" \
    || die "gh could not relabel issue #$issue"
  issue_triage_verified "$issue" "$ready" "$remove" \
    || issue_triage_verified "$issue" "$ready" "$remove" \
    || die "issue #$issue's '$ready' label did not verify - checked twice, both failed"

  local tmp
  tmp="$(mktemp)"
  printf 'An orchestrator planning session triaged this issue to `%s`.\n' "$ready" >"$tmp"
  adapter_issue_comment "$issue" "$tmp" \
    || warn "warning: issue #$issue is labelled $ready, but gh could not post the triage comment on it"
  rm -f "$tmp"
}

# Pushing a branch and opening a PR against it has exactly one right answer -
# push, then prefix the body with the issue line - Closes into the default
# branch, so GitHub links the PR as a closer (no agent-chosen wording can leave
# the issue open again), Refs into any other base - then create the PR - so
# pr open (a flow's own, draft, recorded into state) and pr publish (a quick
# implementation's, not a draft, recording nothing) share it rather
# than each hand-rolling the push/issue-line/gh-pr-create idiom.
open_pr() {
  local branch="$1" base="$2" issue="$3" title="$4" body_file="$5" draft="$6" tmp pr keyword=Closes
  git push -q -u origin "$branch"
  # GitHub only acts on a closing keyword when the PR merges into the default
  # branch, so a PR into any other base branch refers to its issue instead of
  # claiming to close it - the release PR is what closes it.
  [ "$base" = "$(default_branch)" ] || keyword=Refs
  tmp="$(mktemp)"
  { printf '%s #%s\n\n' "$keyword" "$issue"; cat "$body_file"; } >"$tmp"
  if ! pr="$(adapter_pr_create "$base" "$branch" "$title" "$tmp" "$draft")"; then
    rm -f "$tmp"
    die "gh could not open the PR for branch $branch (issue #$issue)"
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
# ran before this is called.
cmd_pr_publish() {
  [ $# -eq 3 ] || die "usage: orch.sh pr publish <issue> <title> <body-file>"
  local issue="$1" title="$2" body_file="$3" branch base pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  base="$(recorded_base "$branch")"
  pr="$(open_pr "$branch" "$base" "$issue" "$title" "$body_file" false)"
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
  local open
  open="$(adapter_prs_open "$base" "$default")" ||
    die "gh could not list the open PRs from $base into $default"
  [ -z "$open" ] || die "a release PR from $base into $default is already open: #$(first_line "$open")"
  # Read from the merged PRs' bodies rather than GitHub's closing-issue links:
  # GitHub only links closing keywords on PRs into the default branch, and a
  # Refs line never links at all. Refs, Closes, Fixes and Resolves count, in
  # any case and anywhere in the body - not every closing form GitHub knows,
  # so prose such as "a quick fix #12" is never mistaken for a reference.
  local bodies refs n state issues="" tmp pr
  bodies="$(adapter_prs_merged_bodies "$base")" ||
    die "gh could not list the PRs merged into $base"
  refs="$(printf '%s\n' "$bodies" |
    grep -ioE '(^|[^[:alnum:]_])(refs|closes|fixes|resolves):?[[:space:]]+#[0-9]+' |
    grep -oE '[0-9]+$' | sort -nu)" || true
  # gh issue view answers for a PR number too, so a reference to a PR reads
  # as PULL and is dropped - only still-open issues get a Closes line.
  for n in $refs; do
    state="$(adapter_issue_state "$n")" ||
      die "gh could not read the state of issue #$n"
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
  if ! pr="$(adapter_pr_create "$default" "$base" "$title" "$tmp")"; then
    rm -f "$tmp"
    die "gh could not open the release PR from $base into $default"
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
# a failure for "no PR". Only the GitHub-unreadable rule is shared with ticket
# exists: a GitHub that cannot be read exits 2, never 1.
cmd_pr_comment() {
  [ $# -eq 1 ] || die2 "usage: orch.sh pr comment <file>"
  local file="$1" pr
  [ -f "$file" ] || die2 "body file not found: $file"
  pr="$(current_open_pr)" || return $?
  adapter_pr_comment "$pr" "$file" \
    || die2 "gh could not comment on PR #$pr"
  printf '%s\n' "$pr"
}

# The current branch's open PR number, for pr comment, pr comments, pr fetch
# and pr update.
# Returns 1, printing nothing, when the branch has no open PR; every other
# failure - a detached HEAD, a GitHub that cannot be read - goes through die2,
# so a caller in a subshell can tell "no PR" apart from an error and map each
# to its own exit code.
current_open_pr() {
  local branch open
  branch="$(git symbolic-ref --quiet --short HEAD)" \
    || die2 "not on a branch (detached HEAD)"
  open="$(adapter_prs_open "$branch")" \
    || die2 "gh could not list the open PRs from $branch"
  [ -n "$open" ] || return 1
  first_line "$open"
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
  local file="$1" pr current line
  [ -f "$file" ] || die "body file not found: $file"
  pr="$(required_open_pr)" || exit 1
  current="$(adapter_pr_body "$pr")" \
    || die "gh could not read the body of PR #$pr"
  line="$(printf '%s\n' "$current" | sed -n '1{s/\r$//;p;}')"
  printf '%s\n' "$line" | grep -qE '^(Closes|Refs) #[0-9]+$' \
    || die "PR #$pr's body does not open with a Closes/Refs #<issue> line, so there is no issue line to keep - refusing to replace it"
  [ "$(sed -n '1{s/\r$//;p;}' "$file")" = "$line" ] \
    || die "$file must open with PR #$pr's issue line, '$line' - refusing to replace the body"
  adapter_pr_body_edit "$pr" "$file" \
    || die "gh could not replace the body of PR #$pr"
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
    *) die "unknown pr op: ${op:-<none>} (want open|publish|release|comment|comments|fetch|update)" ;;
  esac
}

# --- ticket -------------------------------------------------------------
#
# GitHub's native sub-issues and issue dependencies, in one place, so no skill
# or agent prose ever calls `gh api` on these endpoints directly. Every read
# and write goes through the adapter's sub-issue and dependency operations.
# Stateless throughout, like issue publish/pr publish: callable with no
# state.json, since quick implementation keeps none.

# ticket_sub_issues <parent> [die|die2]: the parent's sub-issues as
# adapter_sub_issues prints them - the one listing every ticket command reads
# (#394). Dies, before asking GitHub, on a parent that is no plain number;
# dies through the second argument (default die) where GitHub cannot list
# them.
ticket_sub_issues() {
  local parent="$1" fail="${2:-die}" subs
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  subs="$(adapter_sub_issues "$parent")" || "$fail" "gh could not list sub-issues of #$parent"
  if [ -n "$subs" ]; then printf '%s\n' "$subs"; fi
}

# The one parser of a comma list of issue numbers for every `ticket` command:
# `ticket publish --blocked-by` and `ticket block`/`unblock --by`. Prints the
# numbers one per line, sorted and de-duplicated. Dies naming <flag> and the
# whole list on any entry that is not a plain issue number, an empty one
# included (`1,,2`, `,5`, `5,`). An empty <list> is the caller's to handle.
issue_number_list() {
  local flag="$1" list="$2"
  # Digits and commas only, with no comma leading, trailing or doubled - a
  # per-entry loop over a command substitution would lose a trailing empty.
  case "$list" in
    ''|*[!0-9,]*|,*|*,|*,,*) die "$flag must be plain issue numbers, got: $list" ;;
  esac
  printf '%s\n' "$list" | tr ',' '\n' | sort -un
}

# True only once both links read back exactly as published: the parent's
# sub-issue listing contains the child, and the child's blocked-by listing
# is the same set of numbers requested, in any order, both sides
# de-duplicated. Read fresh every call, never cached - the caller retries
# this on a mismatch, and a cached answer would just repeat the same wrong
# verdict.
ticket_links_verified() {
  local parent="$1" child="$2" want="$3" have_children have_blockers
  have_children="$(adapter_sub_issues "$parent")" || return 1
  printf '%s\n' "$have_children" | cut -f1 | grep -qxF "$child" || return 1
  have_blockers="$(ticket_blockers "$child" return)" || return 1
  [ "$have_blockers" = "$(printf '%s\n' "$want" | sort -un)" ]
}

# Publishes a child issue, links it to <parent> as a native sub-issue, adds a
# native blocking edge for every --blocked-by argument, and applies this
# repo's ready-for-agent label - then verifies every link it just wrote by
# reading it back. One retry on a mismatch; a second failure dies naming the
# ticket rather than falling back to a text-based `Blocked by:` convention,
# since nothing downstream ever reads that fallback.
cmd_ticket_publish() {
  local usage="usage: orch.sh ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]"
  [ $# -ge 3 ] || die "$usage"
  local parent="$1" title="$2" body_file="$3" blocked_by="" have_blocked_by="" want="" b
  local ready child
  shift 3
  # Every argument check runs here, before the first GitHub write. A second
  # --blocked-by is refused, never allowed to replace the first.
  while [ $# -gt 0 ]; do
    case "$1" in
      --blocked-by)
        [ $# -ge 2 ] && [ -z "$have_blocked_by" ] || die "$usage"
        blocked_by="$2"; have_blocked_by=1; shift 2 ;;
      *) die "$usage" ;;
    esac
  done
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  # A wholly empty --blocked-by "" means no blockers. The list comes back
  # de-duplicated: GitHub stores a blocking edge once however often it is
  # requested, so a duplicate would leave the readback's set permanently
  # smaller than $want and fail verification for a correct link.
  if [ -n "$blocked_by" ]; then
    want="$(issue_number_list --blocked-by "$blocked_by")" || exit 1
  fi

  ready="$(triage_label_for ready-for-agent)"
  child="$(adapter_issue_create "$title" "$body_file" "$ready")" \
    || die "gh could not create the ticket"

  adapter_sub_issue_link "$parent" "$child" \
    || die "gh could not link ticket #$child as a sub-issue of #$parent"

  if [ -n "$want" ]; then
    while IFS= read -r b; do
      adapter_blocker_add "$child" "$b" \
        || die "gh could not add a blocking edge from ticket #$child on #$b"
    done <<<"$want"
  fi

  ticket_links_verified "$parent" "$child" "$want" \
    || ticket_links_verified "$parent" "$child" "$want" \
    || die "ticket #$child's sub-issue/blocked-by links did not verify - checked twice, both failed"

  note "$child"
}

# The parent's open sub-issues with zero open blockers, in the order GitHub
# published them.
cmd_ticket_next() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket next <parent>"
  local subs
  subs="$(ticket_sub_issues "$1")" || exit 1
  printf '%s\n' "$subs" | awk -F '\t' '$2 == "OPEN" && $3 == 0 { print $1 }'
}

# Every sub-issue of <parent>, open or closed, one "<n> open|closed" line
# each, in the order GitHub published them - how a spec review finds the
# tickets its accepted edits touch without calling a sub-issue endpoint.
cmd_ticket_list() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket list <parent>"
  local subs
  subs="$(ticket_sub_issues "$1")" || exit 1
  printf '%s\n' "$subs" | awk -F '\t' 'NF { print $1, tolower($2) }'
}

cmd_ticket_close() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket close <n>"
  local n="$1"
  case "$n" in ''|*[!0-9]*) die "not a plain issue number: $n" ;; esac
  adapter_issue_close "$n" || die "gh could not close ticket #$n"
}

# Reopens every sub-issue of <parent> that is currently closed, and only
# those - the fix `redo review` needs before handing back to a fresh
# implement phase, whose frontier query would otherwise find nothing.
cmd_ticket_reset() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket reset <parent>"
  local subs closed n
  subs="$(ticket_sub_issues "$1")" || exit 1
  closed="$(printf '%s\n' "$subs" | awk -F '\t' '$2 == "CLOSED" { print $1 }')"
  if [ -n "$closed" ]; then
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      adapter_issue_reopen "$n" || die "gh could not reopen ticket #$n"
    done <<<"$closed"
  fi
}

# Prints <n>'s parent issue number, or nothing (still exit 0) when <n> is
# not a sub-issue. Every gh failure is a real one (see adapter_issue_parent).
cmd_ticket_parent() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket parent <n>"
  local n="$1"
  case "$n" in ''|*[!0-9]*) die "not a plain issue number: $n" ;; esac
  issue_parent "$n"
}

# The lookup behind `ticket parent`, shared with `ticket block` and
# `ticket unblock`'s preconditions: <n>'s parent number, or nothing when it
# has none. An optional <context> is appended to the failure message, so a
# caller can name the ticket it was working on.
issue_parent() {
  adapter_issue_parent "$1" || die "gh could not read issue #$1's parent${2:+, $2}"
}

# Whether <parent> already has a ticket breakdown, decided by structure
# rather than prose (ADR-0028): `sub-issues` when it has at least one,
# open or closed; `collapsed` when it has none but its body carries a line
# that is exactly `## Ticket` outside a code fence, the heading a
# 0-1-ticket collapse appends under; exit 1 and no output when neither.
# Sub-issues win when both hold.
# A body edited on the web arrives with CRLF line ends, so a trailing CR
# does not stop the heading's line from matching. A GitHub it cannot read
# exits 2, never 1: a caller reading 1 as "no breakdown" would publish a
# second one.
cmd_ticket_exists() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket exists <parent>"
  local parent="$1" subs body
  subs="$(ticket_sub_issues "$parent" die2)" || exit "$?"
  if [ -n "$subs" ]; then
    printf 'sub-issues\n'
    return 0
  fi
  body="$(adapter_issue_body "$parent")" \
    || die2 "gh could not read issue #$parent's body"
  if printf '%s\n' "$body" | has_ticket_heading; then
    printf 'collapsed\n'
    return 0
  fi
  return 1
}

# The fixed heading line a collapsed ticket breakdown sits under (ADR-0012).
TICKET_HEADING='## Ticket'

# True when the body on stdin has a line that is exactly TICKET_HEADING outside
# a code fence, CRLF ends allowed - the test `ticket exists` uses, and the line
# `strip_ticket_sections` cuts from.
has_ticket_heading() {
  awk -v heading="$TICKET_HEADING" '
    { l = $0; sub(/\r$/, "", l) }
    !fence && l == heading { found = 1 }
    l ~ /^(```|~~~)/ { fence = !fence }
    END { exit !found }
  '
}

# The body on stdin with every `## Ticket` section removed - the heading line
# `ticket exists` detects, outside a code fence, through the line before the
# next `#` or `##` heading outside a code fence, or the end of the body - and
# the blank lines a section at the end leaves behind trimmed. Every other
# line is kept byte for byte, CRLF ends and trailing blank lines included.
strip_ticket_sections() {
  awk -v heading="$TICKET_HEADING" '
    { l = $0; sub(/\r$/, "", l) }
    skip && !fence && l ~ /^##?([ \t]|$)/ && l != heading { skip = 0 }
    !fence && l == heading { skip = 1; next }
    l ~ /^(```|~~~)/ { fence = !fence }
    skip { next }
    l == "" { held = held $0 "\n"; next }
    { printf "%s%s\n", held, $0; held = "" }
    END { if (!skip) printf "%s", held }
  '
}

# Retires <parent>'s ticket breakdown so nothing later picks it up again
# (issue #334): every sub-issue is closed as not planned if still open,
# commented on, and unlinked from <parent> - unlinked last, so a run that
# dies part-way still finds what it has not finished, and a ticket that
# already carries the retirement comment is not commented on again - and
# every `## Ticket` section is cut from <parent>'s body. Afterwards `ticket
# exists <parent>` exits 1. A breakdown already retired has nothing to list
# and no section to cut, so a repeat writes nothing. Any GitHub failure dies.
cmd_ticket_retire() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket retire <parent>"
  local parent="$1" subs n state comments msg old_msg comment_file
  subs="$(ticket_sub_issues "$parent")" || exit 1
  msg="This ticket was retired: its spec, #$parent, changed and will be broken down into tickets again."
  # The wording a retire posted before a spec review could retire too: a
  # ticket carrying it from a run that died part-way is already commented on.
  old_msg="This ticket was retired by an orchestrator redo: its spec, #$parent, is being redone and will be broken down into tickets again."
  while IFS=$'\t' read -r n state _; do
    [ -z "$n" ] && continue
    if [ "$state" = OPEN ]; then
      adapter_issue_close "$n" "not planned" "$msg" \
        || die "gh could not close ticket #$n"
    else
      comments="$(adapter_issue_comments "$n")" \
        || die "gh could not read ticket #$n's comments"
      if ! grep -qF -e "$msg" -e "$old_msg" <<<"$comments"; then
        comment_file="$(mktemp)"
        printf '%s\n' "$msg" >"$comment_file"
        adapter_issue_comment "$n" "$comment_file" \
          || { rm -f "$comment_file"; die "gh could not comment on ticket #$n"; }
        rm -f "$comment_file"
      fi
    fi
    adapter_sub_issue_unlink "$parent" "$n" \
      || die "gh could not unlink ticket #$n from #$parent"
  done <<<"$subs"
  # A body with no `## Ticket` line outside a code fence comes back
  # unchanged, so it is not written.
  issue_body_rewrite "$parent" "gh could not read issue #$parent's body" \
    "gh could not remove the ## Ticket section from #$parent" strip_ticket_sections
}

# issue_body_rewrite <n> <read-msg> <write-msg> <filter> [<arg>...]: issue
# <n>'s body through <filter> (stdin to stdout) and back. The body is read
# into a file, never through $(...), which would drop its trailing newlines,
# so the bytes the filter keeps go back unchanged - the same round trip
# `issue fetch` and `issue update` make. A body with no final newline gets
# none back; a result byte-identical to the body is not written. A failed
# read dies with <read-msg>, a failed write with <write-msg>.
issue_body_rewrite() {
  local n="$1" read_msg="$2" write_msg="$3" body result out
  shift 3
  body="$(mktemp)"
  adapter_issue_body "$n" >"$body" \
    || { rm -f "$body"; die "$read_msg"; }
  result="$(mktemp)"
  "$@" <"$body" >"$result"
  # awk ends every line it prints with a newline; a body that had no final
  # newline gets none back.
  if [ -s "$body" ] && [ -n "$(tail -c 1 "$body")" ]; then
    out="$(cat "$result"; printf x)"; out="${out%x}"
    printf '%s' "${out%$'\n'}" >"$result"
  fi
  if cmp -s "$body" "$result"; then rm -f "$body" "$result"; return 0; fi
  rm -f "$body"
  adapter_issue_body_edit "$n" "$result" \
    || { rm -f "$result"; die "$write_msg"; }
  rm -f "$result"
}

# Dies, before any write, unless ticket <n> is open, is a sub-issue, and
# every --by issue is its sibling: a sub-issue of the same parent. A closed
# blocker is allowed - an edge to a finished ticket is still a record. The
# state is the issue noun's own read (#496); a pull request's number passes it
# and is refused as no sub-issue.
ticket_edge_preconditions() {
  local n="$1" by="$2" state parent b bp
  state="$(adapter_issue_state "$n")" \
    || die "gh could not read ticket #$n"
  [ "$state" != CLOSED ] || die "ticket #$n is closed - its blocking edges can no longer change anything"
  parent="$(issue_parent "$n")" || exit 1
  [ -n "$parent" ] || die "#$n is not a sub-issue, so it is no ticket of a breakdown"
  while IFS= read -r b; do
    bp="$(issue_parent "$b" "a blocker of ticket #$n")" || exit 1
    [ "$bp" = "$parent" ] \
      || die "#$b is not a sub-issue of #$parent, ticket #$n's parent - edges never cross breakdowns"
  done <<<"$by"
}

# Ticket <n>'s blocker numbers, read fresh from its native blocked-by
# listing, one per line, sorted and de-duplicated: edges are a set. A gh
# failure dies naming the ticket; with `return`, it returns 1 and prints
# nothing, so a caller that retries (publish's verify, ADR-0011) can.
ticket_blockers() {
  local have
  if ! have="$(adapter_blockers "$1")"; then
    [ "${2:-}" = return ] && return 1
    die "gh could not read ticket #$1's blockers"
  fi
  if [ -n "$have" ]; then printf '%s\n' "$have" | sort -un; fi
}

# Verify-then-die (ADR-0011): ticket <n>'s blocked-by listing, read back
# fresh, must be exactly the set <want>. A mismatch is re-read once; a second
# mismatch dies naming the ticket. Never falls back to body text.
ticket_edges_verify() {
  local n="$1" want="$2" have
  have="$(ticket_blockers "$n")" || exit 1
  [ "$have" = "$want" ] && return 0
  have="$(ticket_blockers "$n")" || exit 1
  [ "$have" = "$want" ] \
    || die "ticket #$n's blocking edges did not verify - checked twice, both failed"
}

# The heading of a ticket body's section listing its blockers - kept in line
# with the native edges for human readers; no command reads it.
BLOCKED_BY_HEADING='## Blocked by'

# The body on stdin with its first `## Blocked by` section outside a code
# fence - the heading through the line before the next `#` or `##` heading
# outside a code fence, or the end of the body; `###` does not end it -
# rewritten as: the heading, a blank line, one `- #<n>` line per blocker in
# <blockers> (or `None (can start immediately)` when empty), then a blank line
# if another heading follows. The section's lines end the way its heading's
# line did, CRLF included. With no such section, one is appended after one
# blank line. Every other line is kept byte for byte.
rewrite_blocked_by_section() {
  awk -v heading="$BLOCKED_BY_HEADING" -v blockers="$1" '
    function section(eol,   i, n, b) {
      printf "%s%s%s", heading, eol, eol
      n = split(blockers, b, "\n")
      if (blockers == "") printf "None (can start immediately)%s", eol
      else for (i = 1; i <= n; i++) printf "- #%s%s", b[i], eol
    }
    { l = $0; cr = ($0 ~ /\r$/) ? "\r" : ""; sub(/\r$/, "", l); last = l; lastcr = cr }
    skip && !fence && l ~ /^##?([ \t]|$)/ { skip = 0; printf "%s\n", seol }
    !done && !fence && l == heading { seol = cr; section(cr "\n"); skip = 1; done = 1; next }
    l ~ /^(```|~~~)/ { fence = !fence }
    skip { next }
    { print }
    END {
      if (!done) {
        if (NR > 0 && last != "") printf "%s\n", lastcr
        section(lastcr "\n")
      }
    }
  '
}

# Brings ticket <n>'s `## Blocked by` section in line with <blockers>
# through issue_body_rewrite. The write is not read back - ADR-0011 governs
# the edges, not the body.
ticket_blocked_by_rewrite() {
  issue_body_rewrite "$1" "gh could not read ticket #$1's body" \
    "gh could not rewrite ticket #$1's ## Blocked by section" \
    rewrite_blocked_by_section "$2"
}

# `ticket block` and `ticket unblock`'s one driver: `ticket <verb> <n> --by
# N,N,...`. The arguments are checked before anything touches GitHub: <n>
# and every --by entry plain issue numbers, --by required and given once - a
# second --by would otherwise replace the first - and the --by list sorted
# and de-duplicated, as `ticket publish --blocked-by` does. Then the
# preconditions, the current edges, one adapter write per edge that needs
# it, verify-then-die (ADR-0011) against the wanted set, and the `## Blocked
# by` rewrite. Only the verb varies: block skips edges already present, adds
# the rest and wants the union; unblock skips edges already absent, removes
# the rest and wants the difference. Either re-run is idempotent.
ticket_edges_change() {
  local verb="$1" usage n="" by="" have_by="" before want b present
  usage="usage: orch.sh ticket $verb <n> --by N,N,..."
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --by) [ $# -ge 2 ] && [ -z "$have_by" ] || die "$usage"; by="$2"; have_by=1; shift 2 ;;
      -*)   die "$usage" ;;
      *)    [ -z "$n" ] || die "$usage"; n="$1"; shift ;;
    esac
  done
  [ -n "$n" ] || die "$usage"
  [ -n "$have_by" ] || die "$usage"
  case "$n" in *[!0-9]*) die "not a plain issue number: $n" ;; esac
  [ -n "$by" ] || die "--by must be plain issue numbers, got nothing"
  by="$(issue_number_list --by "$by")" || exit 1
  ticket_edge_preconditions "$n" "$by"
  before="$(ticket_blockers "$n")" || exit 1
  while IFS= read -r b; do
    present=""
    if printf '%s\n' "$before" | grep -qxF "$b"; then present=1; fi
    case "$verb" in
      block)
        [ -z "$present" ] || continue
        adapter_blocker_add "$n" "$b" \
          || die "gh could not add a blocking edge from ticket #$n on #$b" ;;
      unblock)
        [ -n "$present" ] || continue
        adapter_blocker_remove "$n" "$b" \
          || die "gh could not remove a blocking edge from ticket #$n on #$b" ;;
    esac
  done <<<"$by"
  case "$verb" in
    block)   want="$(printf '%s\n%s\n' "$before" "$by" | sed '/^$/d' | sort -un)" ;;
    unblock) want="$(printf '%s\n' "$before" | grep -vxF -f <(printf '%s\n' "$by") || true)" ;;
  esac
  ticket_edges_verify "$n" "$want"
  ticket_blocked_by_rewrite "$n" "$want"
}

# Adds a native blocking edge on <n> for every --by issue it lacks.
cmd_ticket_block() { ticket_edges_change block "$@"; }

# Removes the native blocking edge on <n> for every --by issue it has.
cmd_ticket_unblock() { ticket_edges_change unblock "$@"; }

cmd_ticket() {
  local op="${1:-}"
  shift || true
  case "$op" in
    publish) cmd_ticket_publish "$@" ;;
    next)    cmd_ticket_next "$@" ;;
    list)    cmd_ticket_list "$@" ;;
    close)   cmd_ticket_close "$@" ;;
    reset)   cmd_ticket_reset "$@" ;;
    parent)  cmd_ticket_parent "$@" ;;
    exists)  cmd_ticket_exists "$@" ;;
    retire)  cmd_ticket_retire "$@" ;;
    block)   cmd_ticket_block "$@" ;;
    unblock) cmd_ticket_unblock "$@" ;;
    merge)   cmd_ticket_merge "$@" ;;
    *) die "unknown ticket op: ${op:-<none>} (want publish|next|list|close|reset|parent|exists|retire|block|unblock|merge)" ;;
  esac
}

# --- ticket-worktree ----------------------------------------------------------
#
# A ticket's own worktree on its own ticket branch, so ticket subagents of one
# breakdown can build at once without sharing a working tree (ADR-0036). Each
# lives under the current checkout's top level - inside the session's project
# directory, so an implementer's edits draw no permission prompt - and is kept
# out of git status by the clone's exclude file.

readonly TICKET_WORKTREES="$ORCH/worktrees"

# The ticket number <n> names, or die: digits only, not zero.
ticket_worktree_number() {
  case "$1" in
    ''|*[!0-9]*|0*) die "not a ticket number: ${1:-<none>} (want a positive integer)" ;;
  esac
  printf '%s\n' "$1"
}

ticket_worktree_path() { printf '%s/t%s\n' "$TICKET_WORKTREES" "$1"; }

# Forks <current-branch>--t<n> from the current branch's tip, records the
# forked-from branch on it, and checks it out at .orchestrator/worktrees/t<n>.
# The exclude entry is written before the branch exists; anything failing
# after that takes the worktree and the branch back out before dying.
cmd_ticket_worktree_add() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket-worktree add <n>"
  local n parent branch path
  n="$(ticket_worktree_number "$1")"
  parent="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  branch="$parent--t$n"
  path="$(ticket_worktree_path "$n")"
  [ ! -e "$path" ] || die "ticket worktree $path already exists"
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    die "branch $branch already exists"
  fi
  exclude_orch_dirs
  git branch -q "$branch" HEAD || die "could not create branch $branch"
  if ! git worktree add -q "$path" "$branch" \
     || ! git config "branch.$branch.orchestrator-ticket-parent" "$parent"; then
    # A freshly added worktree holds nothing of anyone's, so no force is
    # needed to take it back out; -D deletes the branch's config section too.
    if [ -e "$path" ]; then git worktree remove "$path" 2>/dev/null || true; fi
    git branch -q -D "$branch" 2>/dev/null || true
    die "could not add ticket worktree $path - removed branch $branch again"
  fi
  note "$path"
}

# Prints <n> <path> for every ticket worktree under this checkout's
# .orchestrator/worktrees/, and nothing else: another checkout's ticket
# worktrees are that checkout's business.
cmd_ticket_worktree_list() {
  [ $# -eq 0 ] || die "usage: orch.sh ticket-worktree list"
  local line path name
  while IFS= read -r line; do
    case "$line" in "worktree "*) ;; *) continue ;; esac
    path="${line#worktree }"
    [ "$(dirname "$path")" = "$TICKET_WORKTREES" ] || continue
    name="$(basename "$path")"
    case "$name" in t[1-9]*) ;; *) continue ;; esac
    case "${name#t}" in *[!0-9]*) continue ;; esac
    note "${name#t} $path"
  done < <(git worktree list --porcelain)
}

# Dies, naming every ticket worktree under this checkout, when any is left:
# moving .orchestrator/ wholesale would break git's record of each one.
refuse_ticket_worktrees() {
  local left
  left="$(cmd_ticket_worktree_list)"
  [ -n "$left" ] || return 0
  die "ticket worktrees are left under this checkout - moving them would break git's record of them:
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

# Removes ticket <n>'s worktree and deletes its branch, never with --force.
# Both refusals - a dirty worktree, and without --unmerged a branch not merged
# into its forked-from branch - run before anything is removed.
cmd_ticket_worktree_remove() {
  local n="" unmerged=0 path branch parent
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=1 ;;
      -*) die "unknown flag: $1 (usage: orch.sh ticket-worktree remove <n> [--unmerged])" ;;
      *) [ -z "$n" ] || die "usage: orch.sh ticket-worktree remove <n> [--unmerged]"; n="$1" ;;
    esac
    shift
  done
  ticket_worktree_resolve "$n"
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "ticket worktree $path is dirty - commit or discard its changes first; it is never removed with force"
  if [ "$unmerged" = 0 ]; then
    parent="$(git config --get "branch.$branch.orchestrator-ticket-parent" 2>/dev/null)" \
      || die "branch $branch records no forked-from branch - pass --unmerged to discard it"
    git merge-base --is-ancestor "$branch" "$parent" 2>/dev/null \
      || die "branch $branch is not merged into $parent - merge it first, or pass --unmerged to discard it"
  fi
  git worktree remove "$path" || die "could not remove ticket worktree $path"
  # -D, not -d, either way: without --unmerged the merge-base check above
  # already proved the branch merged into its forked-from branch, while -d
  # would judge it against this checkout's HEAD (a ticket branch has no
  # upstream) and could refuse after the worktree is gone.
  git branch -q -D "$branch" || die "could not delete branch $branch"
}

# The checkout that has <branch> checked out, or nothing: the first worktree
# git lists on refs/heads/<branch>.
branch_checkout() {
  local line path=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) path="${line#worktree }" ;;
      "branch refs/heads/$1") note "$path"; return 0 ;;
    esac
  done < <(git worktree list --porcelain)
}

# Lands ticket <n>'s branch on the branch it was forked from: rebases it onto
# that branch's tip inside the ticket worktree, then fast-forwards that branch
# in whichever checkout has it - so history stays linear. Every refusal (exit
# 1) runs before anything moves; a rebase conflict is aborted and exits 3,
# leaving both branches at their prior tips.
cmd_ticket_merge() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket merge <n>"
  local n path branch parent pwt
  ticket_worktree_resolve "$1"
  parent="$(git config --get "branch.$branch.orchestrator-ticket-parent" 2>/dev/null)" \
    || die "branch $branch records no forked-from branch"
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || die "ticket worktree $path is dirty - commit or discard its changes first"
  pwt="$(branch_checkout "$parent")"
  [ -n "$pwt" ] || die "$parent, the branch $branch was forked from, is checked out nowhere - check it out first"
  [ -z "$(git -C "$pwt" status --porcelain)" ] \
    || die "$pwt, the checkout of $parent, is dirty - commit or discard its changes first"
  if ! git -C "$path" rebase -q "$parent" >/dev/null 2>&1; then
    git -C "$path" rebase --abort >/dev/null 2>&1 || true
    warn "rebasing $branch onto $parent hit a conflict - aborted; both branches are as they were"
    exit 3
  fi
  git -C "$pwt" merge -q --ff-only "$branch" \
    || die "could not fast-forward $parent to $branch in $pwt"
}

cmd_ticket_worktree() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add)    cmd_ticket_worktree_add "$@" ;;
    list)   cmd_ticket_worktree_list "$@" ;;
    remove) cmd_ticket_worktree_remove "$@" ;;
    *) die "unknown ticket-worktree op: ${op:-<none>} (want add|list|remove)" ;;
  esac
}

# --- redo ---------------------------------------------------------------

# True when any of the named files exists under <dir>.
any_exist_under() {
  local dir="$1" f
  shift
  for f in "$@"; do [ -e "$dir/$f" ] && return 0; done
  return 1
}

# Moves each named handoff that exists into exactly <dest>, created only when
# there is something to move. A <dest> already holding one of them is refused
# before any handoff moves; unlike `review retire`, a <dest> that merely
# exists is fine.
retire_handoffs() {
  local dest="$1" f
  shift
  any_exist_under "$HANDOFF_DIR" "$@" || return 0
  if any_exist_under "$dest" "$@"; then
    die "$dest already holds a retired handoff - refusing to overwrite it"
  fi
  mkdir -p "$dest"
  for f in "$@"; do
    [ -e "$HANDOFF_DIR/$f" ] && mv "$HANDOFF_DIR/$f" "$dest/"
  done
  return 0
}

# The full `review -> implement` transition: retire the old branch and PR,
# reopen the spec issue's closed tickets, move the old loop's records aside,
# and reset the state a fresh implement attempt needs - never mid-budget, and
# never over a loop nobody has confirmed actually ended. `flake_rerun_used` is
# deliberately untouched throughout, per docs/adr/0007: it is a per-flow
# allowance, not a per-loop one.
cmd_redo_review() {
  [ $# -eq 0 ] || die "usage: orch.sh redo review"
  require_state
  local phase i b word slug issue branch pr redo_count new_n new_branch msg
  phase="$(state_get phase)"
  [ "$phase" = review ] || die "flow is not at the review phase - nothing to redo back from"
  i="$(state_get iteration)"
  b="$(review_budget)"
  local terminal; terminal="$(review_terminal_state)" || true
  word="$(first_line "$terminal")"
  case "$word" in
    none)
      die "no review loop has run yet - nothing to redo back from; run $(flow_cmd next) to start one." ;;
    pending)
      die "the review loop hasn't reached its budget yet (iteration $i of budget $b) - that's what $(flow_cmd next) is for; redo is for after a loop ends." ;;
    interrupted)
      die "the review loop's last iteration ($i) has no recorded terminal state - the session looks interrupted, not stopped. Resume it with $(flow_cmd next); redo only runs once a loop actually ends." ;;
    malformed)
      die "the review loop's last iteration ($i) has a malformed terminal state - rewrite the first line of $(cmd_review path "$i") in the shape below; redo only runs once a loop actually ends.
$(printf '%s\n' "$terminal" | tail -n +2)" ;;
    stop) ;;
    *) die "review_terminal_state answered something redo does not know: $word" ;;
  esac

  slug="$(state_get slug)"
  require_issue issue
  require_branch branch
  require_pr pr
  redo_count="$(state_get redo_count)"

  # A previous call at this same redo can have already retired the branch
  # and recorded it here before dying on the PR close below - branch and
  # redo_count are set together right after a real retire, so if the
  # recorded branch already matches what this redo_count's retire would
  # have produced, the retire already happened: resume at closing the PR
  # instead of retiring an already-retired branch a second time, which
  # issue #63 called out by name as not what a retry should do.
  if [ "$redo_count" -gt 0 ] && [ "$branch" = "orch/${issue}-${slug}-redo-${redo_count}" ]; then
    new_n="$redo_count"
    new_branch="$branch"
  else
    new_n=$(( redo_count + 1 ))
    new_branch="orch/${issue}-${slug}-redo-${new_n}"
    cmd_branch retire "$branch" "$new_branch" >/dev/null
    # Recorded immediately, before the gh call below that can still fail:
    # the rename already happened for real, so state.branch has to track it
    # now rather than keep naming a branch that no longer exists if pr
    # close dies and a retry has to find the real current name.
    state_write branch "$new_branch"
    state_write redo_count "$new_n"
  fi

  msg="$(printf 'This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\nA new PR will follow once the redone implement phase reaches pr open again.\n' "$new_branch")"
  adapter_pr_close "$pr" "$msg" || die "gh could not close PR #$pr"

  # The prior implement phase closed every ticket it finished, so the redone
  # implement phase's frontier query (ticket next) would otherwise find
  # nothing and open an empty PR - reopen exactly what ticket close closed.
  cmd_ticket_reset "$issue" >/dev/null

  cmd_review retire "$new_n" >/dev/null
  # The implement handoff described the attempt just retired; left in place,
  # phase advance would let the redone implement phase leave on it (#279).
  # Same N as the review records beside it. 01-plan.md is never touched.
  retire_handoffs "$HANDOFF_DIR/pre-redo-$new_n" 03-implement.md

  state_write branch null
  state_write pr null
  state_write base_sha null
  state_write iteration 0
  phase_write implement
  note "$new_n"
}

# The full `implement -> spec` transition. Defaults to keeping the existing
# spec issue and re-reviewing it - the same path an adopted issue already
# takes through the spec phase's step 0 - and retires that issue's ticket
# breakdown (`ticket retire`, issue #334) so the redone spec is broken down
# again. The retire runs first: a GitHub failure there dies with the phase
# still `implement` and the handoffs in place, so a re-run resumes. Only
# `--new-issue` closes the old one and clears state.issue, so orch-to-spec
# runs again from scratch; its tickets are left as they are.
cmd_redo_spec() {
  require_state
  local phase new_issue=0
  phase="$(state_get phase)"
  [ "$phase" = implement ] || die "flow is not at the implement phase - nothing to redo back from"
  case "${1:-}" in
    "") ;;
    --new-issue) new_issue=1; shift ;;
    *) die "usage: orch.sh redo spec [--new-issue]" ;;
  esac
  [ $# -eq 0 ] || die "usage: orch.sh redo spec [--new-issue]"
  if [ "$new_issue" -eq 1 ]; then
    local issue msg
    require_issue issue
    msg="$(printf 'This issue was closed by an orchestrator redo because the spec itself needed to change.\n\nA fresh issue will follow from orch-to-spec in this same flow.\n')"
    adapter_issue_close "$issue" "" "$msg" || die "gh could not close issue #$issue"
    state_write issue null
  else
    local kept
    require_issue kept
    cmd_ticket_retire "$kept"
  fi
  # The spec handoff - and the implement handoff built on it, if any - are
  # stale once the spec is being redone, so phase advance must not pass on
  # them (#279). redo_count stays put: it counts review step-backs and names
  # the retired branch, so the directory is told apart by a UTC timestamp.
  local dest
  dest="$HANDOFF_DIR/pre-redo-spec-$(dir_stamp)"
  retire_handoffs "$dest" 02-spec.md 03-implement.md
  phase_write spec
}

cmd_redo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    review) cmd_redo_review "$@" ;;
    spec)   cmd_redo_spec "$@" ;;
    *) die "unknown redo op: ${op:-<none>} (want review|spec)" ;;
  esac
}

# --- lifecycle --------------------------------------------------------------

cmd_status() {
  if [ ! -f "$STATE" ]; then
    note "No active flow. Run $(flow_cmd start) from an approved plan."
    return 0
  fi
  local slug phase issue branch pr iteration redo_count
  slug="$(state_get slug)";       phase="$(state_get phase)"
  issue="$(state_get issue)";     branch="$(state_get branch)"
  pr="$(state_get pr)";           iteration="$(state_get iteration)"
  redo_count="$(state_get redo_count)"
  issue="${issue:--}";            branch="${branch:--}";  pr="${pr:--}"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "base:      $(flow_base)"
  note "branch:    $branch"
  note "PR:        $pr"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $(review_budget)"
  # Unconditional, like every other line here: a flow that has never been
  # redone still has an answer - 0 - rather than a line that only appears once
  # something has happened.
  note "redo:      $redo_count"
  note ""
  note "handoffs:"
  local f
  for f in "$HANDOFF_DIR"/*.md; do
    [ -e "$f" ] || { note "  (none yet)"; break; }
    note "  ${f#"$ROOT"/}"
  done
}

# Archive rather than delete: the moment you want a handoff back is precisely
# the moment you just threw it away. The directory is git-excluded anyway.
cmd_archive() {
  require_state
  refuse_ticket_worktrees
  local slug ts dest entry
  slug="$(state_get slug)"
  ts="$(dir_stamp)"
  dest="$ORCH/archive/$ts-$slug"
  mkdir -p "$dest"
  for entry in "$ORCH"/*; do
    [ -e "$entry" ] || continue
    if [ "$(basename "$entry")" = "archive" ]; then continue; fi
    mv "$entry" "$dest/"
  done
  note "${dest#"$ROOT"/}"
}

cmd_help() {
  cat <<'USAGE'
orch.sh - deterministic operations for the orchestrator flow

  doctor [--env|--flow]       diagnose the machine, the repo, and the active flow
  default-branch [--sha]      resolve the repo's default branch, as GitHub
                              reports it; --sha prints the default SHA instead,
                              origin/<default>'s tip as it stands, unfetched
  base set <branch>           set this checkout's base branch - the branch
                              flows and quick implementations fork from and
                              open PRs against; refuses a branch origin does
                              not have. Shared by every worktree, never
                              committed; the default branch's name clears it.
                              An active flow keeps the base it started with
  base set <branch> --flow    correct the active flow's own base branch
                              instead, leaving the checkout setting alone;
                              only while the flow has no branch (before
                              branch create, or after redo review). Stores
                              the name as given; refuses a name that is not
                              a valid branch or that origin does not have
  base show                   print the base branch in effect and its source:
                              set, or default
  base clear                  remove the setting, falling back to the default
                              branch; succeeds when nothing was set
  parallel show               print the parallel cap, how many ticket
                              subagents a frontier runs at once: git config
                              orchestrator.parallel, else 3; 1 is sequential.
                              Dies naming the key and value when it is not a
                              positive integer
  repo show [--name]          print the GitHub repo orch.sh works on and its
                              source: GH_REPO when set, else the checkout's
                              origin - never gh's default repo. --name prints
                              the bare [HOST/]OWNER/REPO alone, for gh -R.
                              Exits 1, naming GH_REPO, when neither resolves
  init <slug> [--issue N]     start a flow (refuses if one is active, unless
                              it is done - a done flow is archived, unless a
                              ticket worktree is left, and the
                              new one starts over it, or if the working tree
                              has changes outside the planning allowlist);
                              --issue adopts an already-open,
                              ready-for-agent issue N as the flow's spec
                              instead of leaving it unset. Records the base
                              branch in effect as the flow's own
  slug <text>                 normalise text to the kebab-case slug init would
                              store - lowercase, non-alphanumeric runs collapsed
                              to a hyphen, trimmed
  state get [key]             print state.json, or one key
  state set <key> <value>     update one of issue, budget, flake_rerun_used
                              (all digits store a number). Any other key is
                              refused, naming the command that owns it -
                              phase moves only through phase advance,
                              review ready, and redo
  phase advance               leave the current phase: validate the handoff
                              it writes for the next one (02-spec.md from
                              spec, 03-implement.md from implement) and the
                              state the next one needs (issue; branch,
                              base_sha, pr), then record the next phase and
                              print the boundary. On a FAIL the phase stays.
                              Refuses at review (use review ready) and done
  phase boundary              print the block that ends a phase - the
                              handoff the current phase reads, and the
                              host's Next line
  handoff path <phase>        print the handoff path for a phase
  handoff validate <file>     check required sections exist and are non-empty
  handoff section <file> <heading>
                              print the body of the section headed
                              `## <heading>`, blank lines trimmed; a missing
                              file, a missing heading, or a repeated heading
                              is an error
  branch create               create orch/<issue>-<slug> off the flow's base
                              branch, recorded at init
  branch off <name>           create and check out <name> off the base branch
                              in effect, recording that base on the branch
                              (branch.<name>.orchestrator-base in local git
                              config) and its tip at branching as the base
                              SHA (branch.<name>.orchestrator-base-sha), and
                              no state - for a quick implementation, which
                              keeps none
  branch base-sha             print the current branch's base SHA as branch
                              off recorded it; a branch without one falls
                              back to the merge-base with its recorded base
                              branch (else the base branch in effect), on
                              origin if there, else local
  branch retire <old> <new>   rename <old> aside to <new>, republishing it on
                              origin and deleting the old remote ref, without
                              force-pushing over anything
  issue publish <title> <body-file>
                              create a GitHub issue under ready-for-agent
                              and verify its title and label by reading them
                              back - recording no state; prints the number
  issue fetch <n> <file>      write issue <n>'s body to <file>, recording no
                              state
  issue update <n> <file>     replace issue <n>'s body with <file>, recording
                              no state
  issue comment <n> <file>    post <file> as a comment on issue <n>,
                              recording no state
  issue comments <n> <file>   write every comment on issue <n> to <file>, in
                              order, each opened by a line
                              <!-- comment @<login> <createdAt> --> - recording
                              no state; no comments is an empty file
  issue triage <n> [--override]
                              move open issue <n> to ready-for-agent, removing
                              its other triage labels, verify by reading the
                              labels back, and post one comment saying so -
                              recording no state. Exit 0 when moved, or when
                              it already carries ready-for-agent (nothing
                              changed); exit 2, printing the label, on
                              wontfix or ready-for-human without --override;
                              exit 1 on a closed issue, a filed finding not yet
                              triaged (finding triage moves those) or a gh
                              failure.
                              A failed comment only warns
  issue ready <n>             exit 0 when issue <n> carries the repo's
                              ready-for-agent label, 1 when it does not, 2 on
                              a usage error or a gh failure - recording no
                              state
  pr open <title> <body-file> push and open a draft PR against the flow's base
                              branch - Closes its issue into the default
                              branch, Refs it into any other
  pr publish <issue> <title> <body-file>
                              push the current branch and open a non-draft PR
                              against the base branch branch off recorded for
                              it (else the base branch in effect) - Closes
                              <issue> into the default branch, Refs it into any
                              other - recording no state; prints the PR number
                              - for a quick implementation whose review pass
                              already ran
  pr release [--force] <title> <body-file>
                              open the release PR: a non-draft PR from the
                              base branch in effect into the default branch,
                              its body one Closes line per still-open issue
                              any PR merged into the base branch refers to
                              (Refs/Closes/Fixes/Resolves #N), then
                              <body-file>. Refuses on the default branch,
                              while a release PR is already open (printing
                              it), and with nothing to close unless --force;
                              pushes nothing, records no state; prints the
                              PR number
  pr comment <file>           post <file> as a comment on the current
                              branch's open PR, recording no state; prints
                              the PR number. Exits 1 printing nothing when
                              the branch has no open PR, 2 when GitHub
                              cannot be read, the post fails, or the call
                              is wrong (no file, detached HEAD)
  pr comments <file>          write every comment on the current branch's
                              open PR to <file>, as issue comments does -
                              recording no state; no comments is an empty
                              file. Exits 1 writing nothing when the branch
                              has no open PR, 2 when GitHub cannot be read
                              or the call is wrong
  pr fetch <file>             write the current branch's open PR body to
                              <file>, recording no state
  pr update <file>            replace the current branch's open PR body with
                              <file>, recording no state. Refuses, leaving
                              the body unchanged, unless <file> opens with
                              the PR's existing Closes/Refs #<issue> line
  ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]
                              create a ticket, link it as a sub-issue of
                              <parent>, add a blocking edge for every
                              --blocked-by issue, apply ready-for-agent, and
                              verify the links it just wrote by reading them
                              back - recording no state; prints the number
  ticket next <parent>       print <parent>'s open sub-issues with zero open
                              blockers, in the order they were published
  ticket list <parent>       print every sub-issue of <parent>, open or
                              closed, as <n> open|closed, in the order they
                              were published
  ticket close <n>           close ticket <n>
  ticket reset <parent>      reopen every sub-issue of <parent> that is
                              currently closed, and only those
  ticket parent <n>          print <n>'s parent issue number, or nothing
                              when <n> is not a sub-issue
  ticket exists <parent>      whether <parent> already has a ticket
                              breakdown: prints sub-issues (it has any, open
                              or closed) or collapsed (none, but its body has
                              a line that is exactly `## Ticket` outside a
                              code fence); exits 1 printing nothing when
                              neither, 2 when GitHub cannot be read
  ticket retire <parent>      retire <parent>'s ticket breakdown: close each
                              open sub-issue as not planned, comment on every
                              one, unlink it, and cut every `## Ticket`
                              section from the body; afterwards ticket exists
                              exits 1. A repeat changes nothing
  ticket block <n> --by N,N,...
                              add a blocking edge on open ticket <n> for every
                              --by sibling (a sub-issue of <n>'s parent; a
                              closed one is fine) it lacks, verify the edges
                              by reading them back, and rewrite <n>'s body's
                              `## Blocked by` section to match. A repeat
                              writes no edge; re-running a failed run
                              finishes it
  ticket unblock <n> --by N,N,...
                              remove the blocking edge on open ticket <n> for
                              every --by sibling it has, verify the rest by
                              reading them back, and rewrite <n>'s body's
                              `## Blocked by` section to match (`None (can
                              start immediately)` once none is left). A repeat
                              removes no edge; re-running a failed run
                              finishes it
  ticket merge <n>            land ticket <n>'s branch on the branch it was
                              forked from: rebase it onto that branch's tip
                              inside its ticket worktree, then fast-forward
                              that branch in whichever checkout has it - no
                              merge commit. Exits 1, changing nothing, when
                              the ticket worktree or that checkout is dirty,
                              or the branch is checked out nowhere; on a
                              rebase conflict aborts the rebase and exits 3,
                              both branches at their prior tips
  ticket-worktree add <n>     fork <current-branch>--t<n> from the current
                              branch's tip, record the forked-from branch on
                              it (branch.<ticket-branch>.orchestrator-ticket-
                              parent in local git config), check it out at
                              .orchestrator/worktrees/t<n> under this
                              checkout's top level, git-exclude .orchestrator/
                              in the clone's shared info/exclude, and print
                              the worktree's absolute path. Refuses when that
                              worktree or branch already exists; a failure
                              after the branch is made leaves nothing behind
  ticket-worktree list        print <n> <path> for each ticket worktree under
                              this checkout's .orchestrator/worktrees/ only;
                              nothing, exit 0, when there are none
  ticket-worktree remove <n> [--unmerged]
                              remove ticket <n>'s worktree and delete its
                              ticket branch, never with --force. Refuses a
                              dirty worktree and, without
                              --unmerged, a branch not merged into its
                              forked-from branch, before removing anything;
                              --unmerged deletes a clean worktree's unmerged
                              branch
  review begin                claim the next iteration, refusing once the
                              flow's budget is spent (5 when none is set)
  review path [n]             record path, .orchestrator/review/iteration-NN.md,
                              creating the directory if it is not there yet
  review file <major|nit> <title> --axis <spec|standards> --body-file <file>
                              file a finding as a GitHub issue labelled
                              review:<severity>, the repo's needs-triage, and
                              bug (spec axis) or enhancement (standards axis),
                              creating the labels if missing; prints the number
  review ci                   classify the PR's checks: green, failing, none, or
                              unreachable; exits non-zero on the last two
  review rerun <pr>           rerun the failed jobs of the Actions run behind
                              the PR's first failed or cancelled check; prints
                              the run id. Exits 1 when that check is no Actions
                              run, 2 on any other failure
  review ready                mark the draft PR ready and set the phase to done
  review terminal             classify the last iteration: none, pending,
                              interrupted, malformed, ready, or stop; exits
                              non-zero on the first four
  review retire <n>           move every iteration-*.md into pre-redo-<n>/
  spec fetch <file>           write the spec issue's body to <file>
  spec update <file>          replace the spec issue's body with <file>
  spec comment <file>         post <file> as a comment on the spec issue
  spec comments <file>        write every comment on the spec issue to
                              <file>, as issue comments does
                              all four act on the active flow's issue,
                              refusing once the flow is done; for any other
                              issue use issue <op> <n> <file>
  spec-review begin <n>       start a standalone spec review of issue <n>:
                              refuse while an active flow holds <n> - at spec
                              (pointing at next) or at implement or review
                              (pointing at redo) - and otherwise empty
                              .orchestrator/spec-review/<n>/ and print its
                              path. Reads state.json only to compare, and
                              never writes it
  review-pass begin <issue>   start a review pass of the current branch
                              against issue <issue>: refuse on a detached
                              HEAD, on the base branch, and while an active
                              flow holds <issue> or the branch (pointing at
                              next, or at doctor --flow for an unknown phase);
                              otherwise print the next free report prefix
                              .orchestrator/review-pass/<branch>/iteration-NN,
                              branch name used whole, git-excluding
                              .orchestrator/. Never wipes; reads state.json
                              only to compare, and never writes it
  finding-triage scan [<issue> | --pr <n>]
                              read-only: fetch origin/<default> and sort each
                              open review:<severity> finding still in the
                              repo's needs-triage - or the one <issue>, or
                              those whose **PR:** is <n> - one line apiece:
                              <issue> TAB <pr> TAB <file>:<line> TAB <result>
                              TAB <detail>; result unchanged, changed (detail:
                              the newest touching commit's full SHA), gone, or
                              unknown (detail: why), fetching
                              refs/pull/<pr>/head before calling a SHA
                              unreachable
  finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
  finding-triage apply <issue> <ready-for-agent|ready-for-human>
                       --category <bug|enhancement> --comment-file <file>
                              finding triage's one write: post <file> under
                              the AI disclaimer, take the issue out of the
                              repo's needs-triage, then close it as completed
                              (close-fixed) or as not planned labelled wontfix,
                              or label it with that state, keeping
                              review:<severity> and leaving exactly the one
                              category - created only where missing, never
                              with --force. --category is required on the open
                              outcomes and refused on the closing ones; state
                              labels are the repo's names for the roles
  redo review                 retire the branch and PR, reopen the spec
                              issue's closed tickets, reset the loop, retire
                              03-implement.md into handoff/pre-redo-<n>/, and
                              step the flow back to implement - refuses unless
                              the review loop has reached a terminal state
  redo spec [--new-issue]     step the flow back to spec, keeping the existing
                              issue by default and retiring its ticket
                              breakdown (ticket retire) so the redone spec is
                              broken down again; --new-issue closes it and
                              clears state.issue so orch-to-spec starts fresh;
                              02-spec.md and any 03-implement.md move into
                              handoff/pre-redo-spec-<UTC timestamp>/
  status                      human-readable summary
  archive                     move the live flow into .orchestrator/archive/
                              (refuses, naming each, while a ticket worktree
                              is left under this checkout)
USAGE
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    doctor)        cmd_doctor "$@" ;;
    default-branch) cmd_default_branch "$@" ;;
    base)          cmd_base "$@" ;;
    parallel)      cmd_parallel "$@" ;;
    repo)          cmd_repo "$@" ;;
    init)          cmd_init "$@" ;;
    slug)          cmd_slug "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    phase)         cmd_phase "$@" ;;
    branch)        cmd_branch "$@" ;;
    issue)         cmd_issue "$@" ;;
    pr)            cmd_pr "$@" ;;
    ticket)        cmd_ticket "$@" ;;
    ticket-worktree) cmd_ticket_worktree "$@" ;;
    review)        cmd_review "$@" ;;
    spec)          cmd_spec "$@" ;;
    spec-review)   cmd_spec_review "$@" ;;
    review-pass)   cmd_review_pass "$@" ;;
    finding-triage) cmd_finding_triage "$@" ;;
    redo)          cmd_redo "$@" ;;
    status)        cmd_status "$@" ;;
    archive)       cmd_archive "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

# Run as a command, not when sourced: a test sources this file to reach a
# helper such as is_filed_severity directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
