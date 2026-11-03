#!/usr/bin/env bash
# PostToolUse hook for the repo's own development, registered in the project
# .claude/settings.json (never in the plugin's hooks/hooks.json). After an
# Edit, Write or MultiEdit it runs the width tool on an edited .md or .sh
# file, and shellcheck at warning severity on an edited .sh file, each from
# the file's own git repo root. A Bash call is checked the same way on every
# .md or .sh file it changed in the checkout holding its cwd: PreToolUse
# snapshots the dirty and untracked files with a content hash, and
# PostToolUse or PostToolUseFailure checks the files that are new or whose
# hash differs, then deletes the snapshot. Findings go to stderr and the hook
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
# the checkout ROOT (paths relative to ROOT; a rename under its new path).
dirty_hashes() {
  local root="$1" entry path skip=0
  while IFS= read -r -d '' entry; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "${entry:0:1}${entry:1:1}" in R* | C* | ?R | ?C) skip=1 ;; esac
    path="${entry:3}"
    [ -f "$root/$path" ] || continue
    printf '%s\t%s\n' "$(git -C "$root" hash-object -- "$path" 2>/dev/null)" \
      "$path"
  done < <(git -C "$root" status --porcelain -uall -z 2>/dev/null)
}

report() {
  [ -z "$1" ] && exit 0
  printf '%s\n' "$1" >&2
  exit 2
}

payload="$(cat 2>/dev/null)" || exit 0
tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null)" || exit 0

if [ "$tool" != Bash ]; then
  file="$(jq -r '.tool_input.file_path // empty' <<<"$payload" \
    2>/dev/null)" || exit 0
  report "$(check_file "$file")"
fi

# The Bash path.
event="$(jq -r '.hook_event_name // empty' <<<"$payload")" || exit 0
cwd="$(jq -r '.cwd // empty' <<<"$payload")" || exit 0
sid="$(jq -r '.session_id // empty' <<<"$payload")" || exit 0
tid="$(jq -r '.tool_use_id // empty' <<<"$payload")" || exit 0
[ -n "$tid" ] && [ -n "$cwd" ] || exit 0
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -n "$root" ] || exit 0
key="$(printf '%s-%s' "$sid" "$tid" | tr -c 'A-Za-z0-9_-' '_')"
snap="${TMPDIR:-/tmp}/orch-width-hook-$key"

case "$event" in
  PreToolUse)
    dirty_hashes "$root" 2>/dev/null >"$snap" || rm -f "$snap" 2>/dev/null
    exit 0
    ;;
  PostToolUse | PostToolUseFailure) ;;
  *) exit 0 ;;
esac

[ -f "$snap" ] || exit 0
findings=""
while IFS=$'\t' read -r hash path; do
  case "$path" in *.md | *.sh) ;; *) continue ;; esac
  grep -qxF -- "$hash"$'\t'"$path" "$snap" && continue
  out="$(check_file "$root/$path")"
  [ -z "$out" ] || findings="${findings:+$findings$'\n'}$out"
done < <(dirty_hashes "$root")
rm -f "$snap" 2>/dev/null
report "$findings"
