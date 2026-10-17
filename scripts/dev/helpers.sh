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
    BEGIN { print "# " header; nheredocs = 0; cur_heredoc = 1; open_quote = "" }
    # describe(name): the first line of the comment block directly above, its
    # `#` and any `<name> <args>:` signature dropped - or the second line
    # of the block, where the signature filled the first; - when there is none.
    function describe(name,   desc, rest) {
      if (!incomment) return "-"
      desc = uncomment(comment_lines[1])
      if (substr(desc, 1, length(name)) == name) {
        rest = substr(desc, length(name) + 1)
        if (match(rest, /^([ \t][^:]*)?:([ \t]|$)/)) desc = substr(rest, RLENGTH + 1)
      }
      sub(/^[ \t]+/, "", desc)
      if (desc == "" && ncomment > 1) desc = uncomment(comment_lines[2])
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
        if (open_quote == "'\''") { if (c == "'\''") open_quote = ""; prev = c; continue }
        if (open_quote == "$") {
          if (c == "\\") { i++; continue }
          if (c == "'\''") open_quote = ""
          prev = c; continue
        }
        if (open_quote == "\"") {
          if (c == "\\") { i++; continue }
          if (c == "\"") open_quote = ""
          prev = c; continue
        }
        if (c == "\\") { i++; prev = " "; continue }
        if (c == "#" && prev ~ /[ \t;(|&]/) return
        if (c == "$" && substr(line, i + 1, 1) == "'\''") { open_quote = "$"; i++; prev = c; continue }
        if (c == "'\''" || c == "\"") { open_quote = c; prev = c; continue }
        if (c == "<" && substr(line, i, 2) == "<<" && substr(line, i + 2, 1) != "<") {
          rest = substr(line, i + 2); strip = 0
          if (substr(rest, 1, 1) == "-") { strip = 1; rest = substr(rest, 2) }
          match(rest, /^[ \t]*/); ws = RLENGTH; rest = substr(rest, ws + 1)
          if (match(rest, /^("[A-Za-z_][A-Za-z0-9_]*"|'\''[A-Za-z_][A-Za-z0-9_]*'\''|[A-Za-z_][A-Za-z0-9_]*)/)) {
            word = substr(rest, 1, RLENGTH); gsub(/["'\'']/, "", word)
            nheredocs++; hword[nheredocs] = word; hstrip[nheredocs] = strip
            i += 1 + strip + ws + RLENGTH
            prev = " "; continue
          }
        }
        prev = c
      }
    }
    {
      if (cur_heredoc <= nheredocs) {
        t = $0
        if (hstrip[cur_heredoc]) sub(/^\t*/, "", t)
        if (t == hword[cur_heredoc]) { cur_heredoc++; if (cur_heredoc > nheredocs) { nheredocs = 0; cur_heredoc = 1 } }
        incomment = 0; next
      }
      if (open_quote != "") { scan($0); incomment = 0; next }
      if (match($0, /^[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        name = substr($0, 1, RLENGTH); sub(/[ \t]*\(\)$/, "", name)
        if (name !~ /^cmd_/) print name "\t" describe(name)
      }
      if ($0 ~ /^[ \t]*#/) {
        if (!incomment) ncomment = 0
        comment_lines[++ncomment] = $0
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
