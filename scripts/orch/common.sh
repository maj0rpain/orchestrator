# shellcheck shell=bash
# common.sh - the primitives no concept owns: die, warn, note, capture, the
# text and working-tree helpers and the like. A helper lives in the module of
# the concept it serves, whichever modules call it, and common.sh calls nothing
# a noun module defines; its test section checks this. A concept with no noun
# has a module of its own too: the Checkout module (checkout.sh), the Filed
# finding module (filed-finding.sh) and the Known items module
# (known-items.sh). Sourced by orch.sh ahead of the ROOT block, which dies
# through die when run outside a git repository, and ahead of every noun module.

# list_has <list> <item>: whether <item> is one of the newline-separated
# <list>, matched whole-line and literally. The one newline-list membership test
# (word_listed matches its space-separated lists without a fork):
# `--` keeps an item beginning with `-` an item, never a grep option, and an
# item spanning lines is no line at all, never several of grep's patterns.
list_has() {
  [[ $2 != *$'\n'* ]] && grep -qxF -- "$2" <<<"$1"
}

# list_join <list>: the newline-separated <list>'s non-empty lines joined with
# ", ", then a newline - a list reads better in a sentence. The one newline-list
# join, beside list_has; an item containing a comma stays whole.
list_join() {
  local out="" x
  while IFS= read -r x; do
    if [ -z "$x" ]; then continue; fi
    if [ -n "$out" ]; then out="$out, $x"; else out="$x"; fi
  done <<<"$1"
  printf '%s\n' "$out"
}

# word_listed <list> <word>: whether <word> is one of the space-separated
# <list>'s words, whole - never several of them, nor part of one, nor empty.
word_listed() {
  case "$2" in *[[:space:]]*) return 1 ;; esac
  [[ " $1 " == *" $2 "* ]]
}

die()  { printf 'orch: %s\n' "$*" >&2; exit 1; }
# die for commands that reserve exit 1 for a meaningful "no" (pr comment: no
# open PR; ticket exists: no breakdown), so their failures exit with status 2
# instead.
die2() { printf 'orch: %s\n' "$*" >&2; exit 2; }
# warn: die's line on stderr, without the exit - for a refusal that returns its
# own status, or a warning the command carries on past.
warn() { printf 'orch: %s\n' "$*" >&2; }
note() { printf '%s\n' "$*"; }
# The one timestamp shape for .orchestrator/ directory names: compact, UTC, and
# colon-free so the path is valid on Windows too. now(), in flow-state.sh, stays
# ISO-8601: it is a field value, never a path segment.
dir_stamp() { date -u +%Y%m%d-%H%M%S; }

# Float comparison and addition, in awk, because the poll loops' timings are
# overridable and the tests turn them down to fractions of a second; bash
# arithmetic is integer only and would read a grace of 0.3 as 0. A fractional
# `sleep` is a GNU/BSD extension rather than POSIX, which is a line this file
# can hold because the fractions only ever come from a test - the shipped
# defaults are whole seconds.
float_lt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
# float_add <a> <b>: prints a + b to three decimal places.
float_add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a + b }'; }

# is_positive_int <v>: whether <v> is a whole number of 1 or more, leading
# zeros allowed ("08" is 8). Each caller keeps its own reaction to a no.
is_positive_int() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$((10#$1))" -gt 0 ]; }

# clone_orchestrator_dir: prints the clone's orchestrator directory, under the
# git common directory (made absolute so it holds wherever the caller runs),
# which every worktree of the clone reaches alike.
clone_orchestrator_dir() {
  local d
  d="$(git rev-parse --git-common-dir)" && d="$(cd "$d" && pwd -P)" ||
    die "could not find the clone's git common directory"
  printf '%s/orchestrator\n' "$d"
}

# require_poll_knobs <var>... <interval-var>: dies unless every named variable
# holds a number and the last, the poll interval, is greater than zero.
# awk compares a number against a non-numeric string as strings, which makes
# every `float_lt` true and a poll loop endless. A zero interval is the same
# hazard by a different route: `sleep 0` returns at once and never advances the
# clock the loop sleeps on, leaving it to poll as fast as it can. A poll loop's
# knobs are read once, here, before anything sleeps on one of them.
require_poll_knobs() {
  local k v interval="${!#}"
  for k in "$@"; do
    eval "v=\$$k"
    case "$v" in
      ''|*[!0-9.]*|*.*.*|.) die "$k is not a number: $v" ;;
    esac
  done
  eval "v=\$$interval"
  # Every character is a zero or the point, so the value is zero however it was
  # written - and a glob cannot say that without also matching 0.05.
  case "${v//[0.]/}" in
    '') die "$interval must be greater than zero: $v" ;;
  esac
}
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
  file_read _capture_err_text "$_capture_err_file" || _capture_err_text=""
  rm -f "$_capture_err_file"
  printf -v "$1" '%s' "$_capture_err_text"
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
# git_config_unset <scope> <key>: removes every value of <key> at local or
# global scope; a key that is not set (git config's exit 5) is no error, and
# any other failure returns git's status, so each caller keeps its own die.
git_config_unset() {
  local status=0
  git config "--$1" --unset-all "$2" || status=$?
  [ "$status" -eq 5 ] && return 0
  return "$status"
}
# git_push <reason-var> <git push args...>: runs git push with the arguments,
# sets <reason-var> to git's reason through git_push_reason, and returns the
# push's status (#1300). Every push orch.sh makes runs through it, so none
# drops the reason or leaves the status unchecked; each site keeps its own die.
# Same rules as capture_err: current shell only, _git_push_-prefixed locals.
git_push() {
  local _git_push_err _git_push_st=0
  capture_err _git_push_err git push "${@:2}" || _git_push_st=$?
  git_push_reason "$_git_push_err" "$1"
  return "$_git_push_st"
}
# git_push_reason <stderr> <var>: the reason a git push's stderr gives, into
# <var> - its ` ! ` ref lines, trimmed and joined by "; ", since they carry a
# rejection's cause; else its first fatal: line, an auth or network failure's;
# else its first non-empty line; else "git gave no reason". git's first line
# is often just "To <url>", so it comes last.
git_push_reason() {
  local _gpr_line _gpr_trim _gpr_bangs="" _gpr_fatal="" _gpr_first=""
  while IFS= read -r _gpr_line; do
    trim_split "$_gpr_line" _gpr_trim
    case "$_gpr_line" in
      ' ! '*) _gpr_bangs="${_gpr_bangs:+$_gpr_bangs; }$_gpr_trim" ;;
      fatal:*) [ -n "$_gpr_fatal" ] || _gpr_fatal="$_gpr_line" ;;
    esac
    [ -n "$_gpr_first" ] || _gpr_first="$_gpr_trim"
  done <<<"$1"
  printf -v "$2" '%s' "${_gpr_bangs:-${_gpr_fatal:-${_gpr_first:-git gave no reason}}}"
}
# The argument with leading and trailing whitespace removed, as trim_split
# writes it.
trim() {
  local _trim_s
  trim_split "$1" _trim_s
  printf '%s' "$_trim_s"
}

# The splitters below cut a string up by parameter expansion, so a hot path
# spawns no awk, sed, cut or tail to do it. Each assigns to caller-named
# variables through printf -v, as capture does, and is called in the current
# shell, never inside $(...).
#
# trim_split <text> <var>: <text> with leading and trailing whitespace
# removed, into <var>.
trim_split() {
  local _trim_split_s="$1"
  _trim_split_s="${_trim_split_s#"${_trim_split_s%%[![:space:]]*}"}"
  printf -v "$2" '%s' "${_trim_split_s%"${_trim_split_s##*[![:space:]]}"}"
}

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

# file_read <var> <file>: <file>'s bytes into <var>, exactly - its trailing
# newlines kept, which $(cat) alone drops. Fails, <var> untouched, when the
# file cannot be read.
file_read() {
  local _file_read_s
  _file_read_s="$(cat "$2" && printf x)" || return 1
  printf -v "$1" '%s' "${_file_read_s%x}"
}

# array_index <array-name> <value>: the index of the first element of the
# named indexed array equal to <value>, or nothing when none is.
array_index() {
  local _array_index_keys _array_index_i _array_index_ref
  eval "_array_index_keys=(\${$1[@]+\"\${!$1[@]}\"})"
  for _array_index_i in ${_array_index_keys[@]+"${_array_index_keys[@]}"}; do
    _array_index_ref="$1[$_array_index_i]"
    [ "${!_array_index_ref}" != "$2" ] || { printf '%s' "$_array_index_i"; return 0; }
  done
  return 0
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
exclude_orch_dirs() { exclude_line "$(printf '%s\n' "${EXCLUDED_DIRS[@]}")"; }

# exclude_line <lines>: makes sure each of the newline-separated <lines> is a
# line of the clone's shared info/exclude, adding it once and never again: it
# appends the lines exclude_missing finds absent, creating the file's directory
# first, and does nothing at all when none is missing. The one place that file
# is appended to, for exclude_orch_dirs and agent sync's agent-copy line alike;
# it dies naming the missing lines and the file on a failed write.
exclude_line() {
  local missing ex
  missing="$(exclude_missing "$1")"
  [ -n "$missing" ] || return 0
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  { mkdir -p "${ex%/*}" && printf '%s\n' "$missing" >>"$ex"; } 2>/dev/null ||
    die "cannot add ${missing//$'\n'/, } to the git exclude file $ex"
}

# exclude_missing <lines>: prints, one per line, each of the newline-separated
# <lines> the clone's shared info/exclude lacks - every one when the file is
# missing. The one place the membership test is written: exclude_line appends
# exactly this, and orch_dirs_unexcluded prints it.
exclude_missing() {
  local ex l
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    grep -qxF -- "$l" "$ex" 2>/dev/null || printf '%s\n' "$l"
  done <<<"$1"
}

# Prints, one per line, each EXCLUDED_DIRS entry the clone's shared
# info/exclude lacks - every entry when the file is missing. doctor's
# check_git_exclude reports exactly this.
orch_dirs_unexcluded() { exclude_missing "$(printf '%s\n' "${EXCLUDED_DIRS[@]}")"; }
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

# FENCE_AWK: the one markdown code-fence rule, an awk function fragment each
# scanner prepends to its own program. A fence opens on a line whose first
# non-space character, after at most three spaces of indent, starts a run of
# at least three backticks or tildes; it closes only on a line that, with the
# same indent allowance, is a bare run of the same character at least as long.
# fenced(line) is called once per input line, in order, with the line's CR and
# trailing whitespace already stripped; it returns 1 for a fence delimiter or a
# line inside a fence, else 0. Callers still print or cut delimiter lines as any
# other; fenced only gates heading and section tests. State is fence_-prefixed.
# shellcheck disable=SC2034 # used by the pr and ticket modules
FENCE_AWK='
  function fence_run(s, c,   n) { n = 0; while (substr(s, n + 1, 1) == c) n++; return n }
  function fenced(line,   s, c) {
    s = line; sub(/^ ? ? ?/, "", s); c = substr(s, 1, 1)
    if (fence_char != "") {
      if (c == fence_char && fence_run(s, c) >= fence_len && fence_run(s, c) == length(s)) fence_char = ""
      return 1
    }
    if ((c == "`" || c == "~") && fence_run(s, c) >= 3) { fence_char = c; fence_len = fence_run(s, c); return 1 }
    return 0
  }
'
