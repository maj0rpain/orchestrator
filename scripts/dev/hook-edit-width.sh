#!/usr/bin/env bash
# PostToolUse hook for the repo's own development, registered in the project
# .claude/settings.json (never in the plugin's hooks/hooks.json). After an
# Edit, Write or MultiEdit it runs the width tool on an edited .md or .sh
# file, and shellcheck at warning severity on an edited .sh file, each from
# the file's own git repo root. A Bash call is checked the same way on every
# .md or .sh file it changed in the checkout holding its cwd: PreToolUse
# snapshots the dirty and untracked files with a content hash, and
# PostToolUse or PostToolUseFailure checks the files that are new or whose
# hash differs (found with one hash run and one grep, whatever the number of
# dirty files), then deletes the snapshot. Findings go to stderr and the hook
# exits 2; every other case exits 0 with no output, and it never blocks a call.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

# check_file FILE: prints the width findings for FILE, plus shellcheck's at
# warning severity on a .sh file, each run from FILE's own git repo root.
# Prints nothing for a file that is not .md or .sh, is missing, or is outside
# a repo. The one check both the Edit and the Bash path call.
check_file() {
  local file="$1" root findings sc
  [ -n "$file" ] && [ -f "$file" ] || return 0
  case "$file" in *.md | *.sh) ;; *) return 0 ;; esac
  root="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" ||
    return 0
  [ -n "$root" ] || return 0
  findings="$(bash "$HERE/width.sh" --root "$root" "$file" 2>&1)"
  case "$file" in
    *.sh)
      if command -v shellcheck >/dev/null 2>&1; then
        sc="$(cd "$root" && shellcheck -S warning "$file" 2>&1)"
        [ -z "$sc" ] || findings="${findings:+$findings$'\n'}$sc"
      fi
      ;;
  esac
  [ -z "$findings" ] || printf '%s\n' "$findings"
}

# dirty_hashes ROOT: one "hash<TAB>path" line per dirty or untracked file of
# the checkout ROOT (paths relative to ROOT; a rename under its new path),
# hashed in one `git hash-object --stdin-paths` run, started only when a file
# is listed. A path that is not a regular readable file, or holds a newline
# (the one-line-per-file format cannot carry it), is left out. Returns 1,
# printing nothing, when the status listing or the hash run fails, or the hash
# run returns a different number of hashes than paths. The status stream read
# below ends with an "rc=<status>" record, never read as a path (a status entry
# has a space third).
dirty_hashes() {
  local root="$1" entry path quoted rest skip=0 n=0 i=0 hash hashes out="" status_rc=""
  local -a paths=()
  local quoted_paths=""
  while IFS= read -r -d '' entry; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$entry" in rc=[0-9]*) status_rc="${entry#rc=}"; continue ;; esac
    case "${entry:0:1}${entry:1:1}" in R* | C* | ?R | ?C) skip=1 ;; esac
    path="${entry:3}"
    [ -f "$root/$path" ] && [ -r "$root/$path" ] || continue
    case "$path" in *$'\n'*) continue ;; esac
    # --stdin-paths reads a line starting with a double quote as C-quoted.
    # Built character by character: a pattern substitution's replacement
    # quoting differs between bash 3.2 and 5.2.
    quoted=""
    rest="$path"
    while [ -n "$rest" ]; do
      case "${rest:0:1}" in
        "\\") quoted="$quoted\\\\" ;;
        '"') quoted="$quoted\\\"" ;;
        *) quoted="$quoted${rest:0:1}" ;;
      esac
      rest="${rest:1}"
    done
    quoted_paths="$quoted_paths\"$quoted\""$'\n'
    paths[n]="$path"
    n=$((n + 1))
  done < <(git -C "$root" status --porcelain -uall -z 2>/dev/null
    printf 'rc=%s\0' "$?")
  [ "$status_rc" = 0 ] || return 1
  [ "$n" -gt 0 ] || return 0
  hashes="$(printf '%s' "$quoted_paths" |
    git -C "$root" hash-object --stdin-paths 2>/dev/null)" || return 1
  while IFS= read -r hash; do
    [ -n "$hash" ] && [ "$i" -lt "$n" ] || return 1
    out="$out$hash"$'\t'"${paths[i]}"$'\n'
    i=$((i + 1))
  done <<<"$hashes"
  [ "$i" -eq "$n" ] || return 1
  printf '%s' "$out"
}

# report_and_exit FINDINGS: exits 0 when FINDINGS is empty, else prints it to
# stderr and exits 2. Never returns.
report_and_exit() {
  [ -z "$1" ] && exit 0
  printf '%s\n' "$1" >&2
  exit 2
}

# drop_snapshot_and_exit SNAPSHOT: removes SNAPSHOT quietly and exits 0 whether
# or not the removal succeeds. Never returns.
drop_snapshot_and_exit() {
  rm -f "$1" 2>/dev/null
  exit 0
}

payload="$(cat 2>/dev/null)" || exit 0
tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null)" || exit 0

if [ "$tool" != Bash ]; then
  file="$(jq -r '.tool_input.file_path // empty' <<<"$payload" \
    2>/dev/null)" || exit 0
  report_and_exit "$(check_file "$file")"
fi

# The Bash path.
event="$(jq -r '.hook_event_name // empty' <<<"$payload")" || exit 0
cwd="$(jq -r '.cwd // empty' <<<"$payload")" || exit 0
sid="$(jq -r '.session_id // empty' <<<"$payload")" || exit 0
tid="$(jq -r '.tool_use_id // empty' <<<"$payload")" || exit 0
[ -n "$tid" ] || exit 0
key="$(printf '%s-%s' "$sid" "$tid" | tr -c 'A-Za-z0-9_-' '_')"
snap="${TMPDIR:-/tmp}/orch-width-hook-$key"

case "$event" in
  PreToolUse)
    [ -n "$cwd" ] || exit 0
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
    [ -n "$root" ] || exit 0
    # A listing that fails leaves no snapshot.
    list="$(dirty_hashes "$root")" || exit 0
    # The first line records the checkout, so Post can tell a call that
    # moved the session's cwd into another checkout.
    { printf 'root\t%s\n' "$root" &&
      { [ -z "$list" ] || printf '%s\n' "$list"; }; } 2>/dev/null \
      >"$snap" || drop_snapshot_and_exit "$snap"
    exit 0
    ;;
  PostToolUse | PostToolUseFailure) ;;
  *) exit 0 ;;
esac

[ -f "$snap" ] || exit 0
IFS= read -r head <"$snap" 2>/dev/null
root="${head#root$'\t'}"
cwd_root=""
[ -z "$cwd" ] || cwd_root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
# Only the checkout holding the payload's cwd is scanned: no cwd, a cwd outside
# any repo, or a cwd in another checkout than Pre's drops the snapshot and
# stays silent.
if [ -z "$cwd" ] || [ "$root" = "$head" ] || [ ! -d "$root" ] || [ "$cwd_root" != "$root" ]; then
  drop_snapshot_and_exit "$snap"
fi
# A listing or comparison that fails drops the snapshot and stays silent.
new="$(dirty_hashes "$root")" || drop_snapshot_and_exit "$snap"
findings=""
if [ -n "$new" ]; then
  # One grep (-a: a name invalid in the locale is still a line): the listed
  # lines absent from the snapshot. Status 1 selects no
  # line, the normal case of a call that changed no listed file.
  changed="$(printf '%s\n' "$new" | grep -a -vxFf "$snap" 2>/dev/null)"
  if [ "$?" -gt 1 ]; then
    drop_snapshot_and_exit "$snap"
  fi
  while IFS=$'\t' read -r _ path; do
    [ -n "$path" ] || continue
    out="$(check_file "$root/$path")"
    [ -z "$out" ] || findings="${findings:+$findings$'\n'}$out"
  done <<<"$changed"
fi
rm -f "$snap" 2>/dev/null
report_and_exit "$findings"
