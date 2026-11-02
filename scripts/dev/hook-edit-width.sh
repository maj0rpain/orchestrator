#!/usr/bin/env bash
# PostToolUse hook for the repo's own development, registered in the project
# .claude/settings.json (never in the plugin's hooks/hooks.json). After an
# Edit, Write or MultiEdit it runs the width tool on an edited .md or .sh
# file, and shellcheck at warning severity on an edited .sh file, each from
# the file's own git repo root. Findings go to stderr and the hook exits 2;
# every other case exits 0 with no output.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

file="$(jq -r '.tool_input.file_path // empty' 2>/dev/null)" || exit 0
[ -n "$file" ] && [ -f "$file" ] || exit 0
case "$file" in *.md | *.sh) ;; *) exit 0 ;; esac

root="$(git -C "$(dirname "$file")" rev-parse --show-toplevel 2>/dev/null)" ||
  exit 0
[ -n "$root" ] || exit 0

findings="$(bash "$HERE/width.sh" --root "$root" "$file" 2>&1)"
case "$file" in
  *.sh)
    if command -v shellcheck >/dev/null 2>&1; then
      sc="$(cd "$root" && shellcheck -S warning "$file" 2>&1)"
      [ -z "$sc" ] || findings="${findings:+$findings$'\n'}$sc"
    fi
    ;;
esac

[ -z "$findings" ] && exit 0
printf '%s\n' "$findings" >&2
exit 2
