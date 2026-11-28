# shellcheck shell=bash
# common.sh - the bash primitives no concept owns: die, warn, capture, the
# text helpers and the like. Sourced by the autopilot scripts; orch.sh sources
# nothing, every noun being Python.

# list_has <list> <item>: whether <item> is one of the newline-separated
# <list>, matched whole-line, literally and case-sensitively. The one
# newline-list membership test (word_listed matches its space-separated lists).
# It matches in bash, starting no command: <list> is framed in newlines and the
# quoted <item>, framed the same, is looked for in it, so an item beginning
# with `-` or holding glob or regex characters is an item, never an option or a
# pattern, and an item spanning lines is no line at all.
list_has() {
  [[ $2 != *$'\n'* ]] && [[ $'\n'"$1"$'\n' == *$'\n'"$2"$'\n'* ]]
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
# die for commands that reserve exit 1 for a meaningful "no", so their
# failures exit with status 2 instead.
die2() { printf 'orch: %s\n' "$*" >&2; exit 2; }

# die_opt_check <caller> <argc> <option> [value]: the one rule for die_hinted's
# options, checked by whatever takes them. <argc> is the caller's "$#" at
# <option>, so a trailing option with no value is told from an empty one.
# --exit must take 2; --hint must have a value, "" included. A bad pair dies
# with status 1, naming <caller> and the option.
die_opt_check() {
  case "$3" in
    --exit) [ "${4-}" = 2 ] || die "$1: --exit takes 2, not '${4-}'" ;;
    --hint) [ "$2" -ge 2 ] || die "$1: --hint needs a value" ;;
  esac
}

# die_hinted [--exit 2] [--hint <text>] <msg>: dies with <msg>, then " - <hint>"
# for a non-empty hint (--hint "" adds nothing) - through die2 under --exit 2,
# else die. Its options are the ones die_opt_check checks.
die_hinted() {
  local code=1 hint=""
  while [ $# -gt 1 ]; do
    case "$1" in
      --exit) die_opt_check die_hinted $# "$@"; code=2; shift 2 ;;
      --hint) die_opt_check die_hinted $# "$@"; hint="$2"; shift 2 ;;
      *) die "die_hinted: unknown option $1" ;;
    esac
  done
  local msg="$1"
  [ -z "$hint" ] || msg="$msg - $hint"
  [ "$code" != 2 ] || die2 "$msg"
  die "$msg"
}
# warn: die's line on stderr, without the exit - for a refusal that returns its
# own status, or a warning the command carries on past.
warn() { printf 'orch: %s\n' "$*" >&2; }

# temp_file_name <var>: sets <var> to a fresh, unpredictable path under the temp
# directory, built from $RANDOM. temp_file_make takes every name from it, so a
# test replaces it to force a collision.
temp_file_name() {
  printf -v "$1" '%s/orch.%s%s%s' "${TMPDIR:-/tmp}" "$RANDOM" "$RANDOM" "$RANDOM"
}
# temp_file_make <var>: creates an empty temp file, owner-only, and sets <var>
# to its path, starting no external command. The name comes from
# temp_file_name; one at which anything already exists, of any type, is skipped
# untouched. The create is exclusive (noclobber) and runs in a subshell under
# umask 077, so the caller's mask and options are never changed; afterwards the
# name must be a regular file and no link, or it too counts as a collision and
# is left as it is. After 10 tries it fails, saying nothing: each caller words
# its own message. The caller removes the file.
temp_file_make() {
  local _tfm_path _tfm_try
  for _tfm_try in 1 2 3 4 5 6 7 8 9 10; do
    temp_file_name _tfm_path
    [[ -e $_tfm_path || -L $_tfm_path ]] && continue
    (umask 077; set -o noclobber; : >"$_tfm_path") 2>/dev/null || continue
    [[ -f $_tfm_path && ! -L $_tfm_path ]] || continue
    printf -v "$1" '%s' "$_tfm_path"
    return 0
  done
  return 1
}
# capture_err <err-var> <command...>: runs the command, sets <err-var> to its
# stderr byte for byte, and returns its status. It leaves stdout alone, to the
# caller's own redirect: a body streamed to a file through
# `capture_err err cat "$file" >"$copy"` keeps its trailing
# newlines, which capture's strip would remove. The stderr goes
# through one temp file capture_err makes with temp_file_make and reads back
# with file_read; only the final rm, and the cat of a failed file_read, start an
# external command. Call it in the current shell, never inside $(...): it sets
# the caller's variable with printf -v. Its
# locals carry a _capture_err_ prefix, so they shadow no caller's variable. The
# command runs in a subshell, so an exit in it ends the command alone.
capture_err() {
  local _capture_err_file _capture_err_text _capture_err_st=0
  temp_file_make _capture_err_file || {
    echo "could not create a temp file for the command's stderr" >&2
    printf -v "$1" '%s' "could not create a temp file for the command's stderr"
    return 1
  }
  ( "${@:2}" ) 2>"$_capture_err_file" || _capture_err_st=$?
  file_read _capture_err_text "$_capture_err_file" || _capture_err_text=""
  rm -f "$_capture_err_file"
  printf -v "$1" '%s' "$_capture_err_text"
  return "$_capture_err_st"
}
# capture <out-var> <err-var> <command...>: capture_err with the stdout taken
# too - sets <out-var> to the command's stdout (read back with file_read, its
# trailing newlines stripped), <err-var> to its stderr byte for byte, and
# returns its status. The stdout goes through a temp file, never a command
# substitution, so a background process the command leaves holding it cannot
# block the return. Same rules as capture_err: current shell only, and
# _capture_-prefixed locals, nested calls included.
capture() {
  local _capture_file _capture_text _capture_st=0
  temp_file_make _capture_file || {
    echo "could not create a temp file for the command's stdout" >&2
    printf -v "$2" '%s' "could not create a temp file for the command's stdout"
    return 1
  }
  capture_err "$2" "${@:3}" >"$_capture_file" || _capture_st=$?
  file_read_text _capture_text "$_capture_file"
  rm -f "$_capture_file"
  printf -v "$1" '%s' "$_capture_text"
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

# trim_split <text> <var>: <text> with leading and trailing whitespace
# removed, into <var>, by parameter expansion, so it spawns no command. It
# assigns through printf -v, as capture does, and is called in the current
# shell, never inside $(...).
trim_split() {
  local _trim_split_s="$1"
  _trim_split_s="${_trim_split_s#"${_trim_split_s%%[![:space:]]*}"}"
  printf -v "$2" '%s' "${_trim_split_s%"${_trim_split_s##*[![:space:]]}"}"
}

# file_read <var> <file>: <file>'s bytes into <var>, exactly - its trailing
# newlines kept, a NUL byte dropped as $(cat) drops it - read by the shell
# itself, starting no external command. Fails, <var> untouched, when the file
# cannot be read: that failure starts one cat, which prints cat's own
# diagnostic on stderr.
file_read() {
  local _file_read_s="" _file_read_c=""
  if [[ -r $2 && ! -d $2 ]]; then
    # read -d '' stops at each NUL: take every chunk, the last one unterminated.
    # A failed open (a socket, a file gone since the check) leaves the loop
    # status 1, which takes the failure path; its own error is silenced.
    if while IFS= read -r -d '' _file_read_c; do _file_read_s+=$_file_read_c; done 2>/dev/null <"$2"; then
      _file_read_s+=$_file_read_c
      printf -v "$1" '%s' "$_file_read_s"
      return 0
    fi
  fi
  # Only the failure path starts a command: cat gives its own diagnostic.
  cat "$2" >/dev/null || :
  return 1
}

# newlines_strip <var>: drops every trailing newline from the named
# variable's value, as $(...) drops them from a command's output.
newlines_strip() {
  local _ns_v="${!1}"
  while [ "${_ns_v%$'\n'}" != "$_ns_v" ]; do _ns_v="${_ns_v%$'\n'}"; done
  printf -v "$1" '%s' "$_ns_v"
}

# file_read_text <var> <file>: <file>'s text into <var> as $(cat <file>) gives
# it - trailing newlines dropped - read by the shell itself. An unreadable file
# gives empty, with the diagnostic $(cat) printed: file_read's.
file_read_text() {
  printf -v "$1" '%s' ""
  file_read "$1" "$2" || :
  newlines_strip "$1"
}

# exclude_line <lines>: makes sure each of the newline-separated <lines> is a
# line of the clone's shared info/exclude, adding it once and never again: it
# appends the lines exclude_missing finds absent, creating the file's directory
# first, and does nothing at all when none is missing. The one place that file
# is appended to; it dies naming the missing lines and the file on a failed
# write.
exclude_line() {
  local missing ex
  missing="$(exclude_missing "$1")"
  [ -n "$missing" ] || return 0
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  # A last line the user left unterminated is ended first, so the first line
  # added is never glued onto their pattern.
  { mkdir -p "${ex%/*}" &&
    { ! [ -s "$ex" ] || [ -z "$(tail -c1 "$ex")" ] || printf '\n' >>"$ex"; } &&
    printf '%s\n' "$missing" >>"$ex"; } 2>/dev/null ||
    die "cannot add $(list_join "$missing") to the git exclude file $ex"
}

# exclude_missing <lines>: prints, one per line, each of the newline-separated
# <lines> the clone's shared info/exclude lacks - every one when the file is
# missing. The one place the membership test is written: exclude_line appends
# exactly this.
exclude_missing() {
  local ex l
  ex="$(git rev-parse --git-common-dir)/info/exclude"
  while IFS= read -r l; do
    [ -n "$l" ] || continue
    grep -qxF -- "$l" "$ex" 2>/dev/null || printf '%s\n' "$l"
  done <<<"$1"
}
