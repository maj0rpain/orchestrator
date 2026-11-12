#!/usr/bin/env bash
# width.sh [--root <dir>] <file>...  |  width.sh --root <dir>
#
# The 80-column line-width rule, whole: which files it covers and which lines
# in them are too wide. Prints "<file>:<line>: <length> columns, past 80" for
# each covered, non-exempt line longer than 80, <file> relative to the root,
# and nothing when clean.
#
# With files, checks each one, skipping a missing or uncovered file silently.
# Coverage is decided by the file's path inside the root: <dir> given by
# --root, else the file's own git repo root (a file in no repo is skipped).
# With --root and no files, scans every covered file under <dir>.
#
# Covered: every *.md under skills/, agents/, commands/ and docs/, the root
# README.md, CONTRIBUTING.md, GLOSSARY.md and CLAUDE.md, and the whole-line
# comments of every *.sh under scripts/ outside heredoc bodies. Frontmatter,
# fenced code (a fence closes only on a bare run of its opener's character at
# least as long as the opener), table rows, lines with a URL, "# shellcheck"
# directives and one-token lines are exempt. Columns count characters, so a
# multi-byte character is one column.
#
# A repo-development tool, not an orch.sh noun: it does not ship to users.
# It exits 0 with or without findings; a bad argument exits 2.
set -euo pipefail

usage() {
  printf 'width.sh: usage: width.sh [--root <dir>] <file>... | width.sh --root <dir>\n' >&2
  exit 2
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHELL_CODE_AWK="$(<"$HERE/../test/shell_code.awk")"
[ -n "$SHELL_CODE_AWK" ] || {
  echo "width.sh: scripts/test/shell_code.awk is missing or empty" >&2; exit 1; }

# covered <path inside the root>: whether the rule covers the file.
covered() {
  case "$1" in
    skills/*.md | agents/*.md | commands/*.md | docs/*.md) return 0 ;;
    README.md | CONTRIBUTING.md | GLOSSARY.md | CLAUDE.md) return 0 ;;
    scripts/*.sh) return 0 ;;
  esac
  return 1
}

# scan_file <root> <path inside the root>: the findings of one covered file.
scan_file() {
  F="$2" LC_ALL=C awk "$SHELL_CODE_AWK"'
    FNR == 1 {
      is_shell = ENVIRON["F"] ~ /\.sh$/
      in_frontmatter = 0; fchar = ""
    }
    { stripped = $0; sub(/^[[:space:]]+/, "", stripped) }
    is_shell { shell_code_line($0) }
    is_shell && (!sc_top || stripped !~ /^#/) { next }
    is_shell && FNR == 1 && stripped ~ /^#!/ { next }
    is_shell && stripped ~ /^#[[:space:]]*shellcheck/ { next }
    !is_shell && FNR == 1 && $0 == "---" { in_frontmatter = 1; next }
    in_frontmatter { if ($0 == "---") in_frontmatter = 0; next }
    !is_shell && fchar != "" {
      closer = stripped; sub(/[[:space:]]+$/, "", closer)
      if (closer ~ ("^" fchar "+$") && length(closer) >= flen) fchar = ""
      next
    }
    !is_shell && match(stripped, /^(```+|~~~+)/) {
      fchar = substr(stripped, 1, 1); flen = RLENGTH
      next
    }
    stripped ~ /^\|/ || /https?:\/\// { next }
    {
      bare = stripped; sub(/^#+[[:space:]]*/, "", bare)
      sub(/[[:space:]]+$/, "", bare)
      sub(/^([-*+]|[0-9]+[.)])[[:space:]]+/, "", bare)
      if (bare !~ /[[:space:]]/) next
    }
    {
      chars = $0
      cols = length(chars) - gsub(/[\200-\277]/, "", chars)
    }
    cols > 80 { print ENVIRON["F"] ":" FNR ": " cols " columns, past 80" }' "$1/$2"
}

root=""
files=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] && [ -d "$2" ] || usage
      root="$(cd "$2" && pwd -P)"; shift 2 ;;
    -*) usage ;;
    *) files+=("$1"); shift ;;
  esac
done

if [ "${#files[@]}" -eq 0 ]; then
  [ -n "$root" ] || usage
  while IFS= read -r f; do
    scan_file "$root" "$f"
  done < <(cd "$root" && {
    # Candidates only: covered is the one statement of coverage.
    find skills agents commands docs scripts -type f 2>/dev/null || true
    for f in *.md; do
      if [ -f "$f" ]; then echo "$f"; fi
    done
  } | while IFS= read -r f; do
    if covered "$f"; then echo "$f"; fi
  done | sort)
  exit 0
fi

for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  dir="$(cd "$(dirname "$f")" && pwd -P)"
  abs="$dir/$(basename "$f")"
  r="$root"
  if [ -z "$r" ]; then
    r="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || continue
    r="$(cd "$r" && pwd -P)"
  fi
  case "$abs" in "$r"/*) ;; *) continue ;; esac
  rel="${abs#"$r"/}"
  covered "$rel" || continue
  scan_file "$r" "$rel"
done
exit 0
