# shellcheck shell=bash
# common.sh - the primitives no concept owns: die, warn, note, capture, the
# text and working-tree helpers and the like. A helper lives in the module of
# the concept it serves, whichever modules call it, and common.sh calls nothing
# a noun module defines; its test section checks this. The Filed finding
# helpers stay here until #1026 gives them a module. Sourced by orch.sh ahead
# of the ROOT block, which dies through die when run outside a git repository,
# and ahead of every noun module.

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
  grep -qxF -- "$2" <<<"$1"
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
