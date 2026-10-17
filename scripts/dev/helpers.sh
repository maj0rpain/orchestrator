#!/usr/bin/env bash
# helpers.sh [--tests] [<file>]: the helper index. Prints every top-level
# function of orch.sh's modules (scripts/orch/*.sh), or with --tests of the
# shared test setup and the gh adapter fake, or of the one bash <file> named,
# each with the first line of the comment directly above its definition.
#
# Output, per file: a `# <path>` header - relative to the repo root, or <file>
# as given - then one `<name><TAB><description>` line per function in file
# order, files separated by a blank line. The description drops the comment's
# leading `#` and any `<name> <args>:` signature; a function with no comment
# line directly above it prints `-`. Subcommand entry points (cmd_*) are left
# out, as are functions inside an embedded awk program, string or heredoc.
#
# A repo-development tool, not an orch.sh noun: it does not ship to users.
# Usage errors exit 2.
set -euo pipefail

usage() {
  printf 'usage: %s [--tests] [<file>]\n' "${0##*/}" >&2
  exit 2
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

tests=0
file=""
for arg in "$@"; do
  case "$arg" in
    --tests) tests=1 ;;
    -*) usage ;;
    *) [ -z "$file" ] || usage; file="$arg" ;;
  esac
done
[ "$tests" -eq 0 ] || [ -z "$file" ] || usage
[ -z "$file" ] || [ -f "$file" ] || usage

# index <path> <header>: the listing of one file. A line opens a definition
# only at column 0 outside any quoted string or heredoc, which the scan below
# tracks line by line: single and double quotes, $'...' strings, comments, and
# each heredoc's body up to its terminator.
index() {
  awk -v header="$2" '
    BEGIN { print "# " header; nh = 0; hi = 1; q = "" }
    # describe(name): the first line of the comment block directly above, its
    # `#` and any `<name> <args>:` signature dropped - or the second line of the block
    # line, where the signature filled the first; - when there is none.
    function describe(name,   desc, rest) {
      if (!incomment) return "-"
      desc = uncomment(blk[1])
      if (substr(desc, 1, length(name)) == name) {
        rest = substr(desc, length(name) + 1)
        if (match(rest, /^([ \t][^:]*)?:([ \t]|$)/)) desc = substr(rest, RLENGTH + 1)
      }
      sub(/^[ \t]+/, "", desc)
      if (desc == "" && nb > 1) desc = uncomment(blk[2])
      return desc == "" ? "-" : desc
    }
    function uncomment(line) {
      sub(/^[ \t]*#[ \t]*/, "", line)
      return line
    }
    function scan(line,   i, c, n, prev, rest, word, strip, ws) {
      n = length(line); prev = " "
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "'\''") { if (c == "'\''") q = ""; prev = c; continue }
        if (q == "$") {
          if (c == "\\") { i++; continue }
          if (c == "'\''") q = ""
          prev = c; continue
        }
        if (q == "\"") {
          if (c == "\\") { i++; continue }
          if (c == "\"") q = ""
          prev = c; continue
        }
        if (c == "\\") { i++; prev = " "; continue }
        if (c == "#" && prev ~ /[ \t;(|&]/) return
        if (c == "$" && substr(line, i + 1, 1) == "'\''") { q = "$"; i++; prev = c; continue }
        if (c == "'\''" || c == "\"") { q = c; prev = c; continue }
        if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2); strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          match(rest, /^[ \t]*/); ws = RLENGTH; rest = substr(rest, ws + 1)
          if (match(rest, /^("[A-Za-z_][A-Za-z0-9_]*"|'\''[A-Za-z_][A-Za-z0-9_]*'\''|[A-Za-z_][A-Za-z0-9_]*)/)) {
            word = substr(rest, 1, RLENGTH); gsub(/["'\'']/, "", word)
            nh++; hword[nh] = word; hstrip[nh] = strip
            i += 1 + strip + ws + RLENGTH
            prev = " "; continue
          }
        }
        prev = c
      }
    }
    {
      if (hi <= nh) {
        t = $0
        if (hstrip[hi]) sub(/^\t*/, "", t)
        if (t == hword[hi]) { hi++; if (hi > nh) { nh = 0; hi = 1 } }
        incomment = 0; next
      }
      if (q != "") { scan($0); incomment = 0; next }
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        name = substr($0, 1, RLENGTH); sub(/[ \t]*\(\)$/, "", name)
        if (name !~ /^cmd_/) print name "\t" describe(name)
      }
      if ($0 ~ /^[ \t]*#/) {
        if (!incomment) nb = 0
        blk[++nb] = $0
        incomment = 1
      } else {
        incomment = 0
      }
      scan($0)
    }' "$1"
}

if [ -n "$file" ]; then
  index "$file" "$file"
  exit 0
fi

if [ "$tests" -eq 1 ]; then
  files=(scripts/test/orch/setup.sh scripts/test/gh_adapter_fake.sh)
else
  files=()
  for f in "$ROOT"/scripts/orch/*.sh; do files+=("scripts/orch/${f##*/}"); done
fi

sep=""
for rel in "${files[@]}"; do
  printf '%s' "$sep"
  index "$ROOT/$rel" "$rel"
  sep=$'\n'
done
