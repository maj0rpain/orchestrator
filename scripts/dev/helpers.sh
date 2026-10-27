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
# out, as are functions inside an embedded awk program, string, substitution
# or heredoc.
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

# SHELL_CODE_AWK, the one rule of what counts as code in a shell file, loaded
# from scripts/test/shell_code.awk.
SHELL_CODE_AWK="$(<"$ROOT/scripts/test/shell_code.awk")" || SHELL_CODE_AWK=""
[ -n "$SHELL_CODE_AWK" ] || {
  echo "helpers.sh: scripts/test/shell_code.awk is missing or empty" >&2; exit 1; }

# index <path> <header>: the listing of one file. A line opens a definition
# only at column 0 of a line that starts at top level, and a comment line
# counts toward a description block only when it starts at top level too:
# shell_code_line, from SHELL_CODE_AWK, says whether a line starts outside any
# open quote, substitution or heredoc, so the scan keeps no state of its own.
index() {
  awk -v header="$2" "$SHELL_CODE_AWK"'
    BEGIN { print "# " header }
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
    {
      shell_code_line($0)
      if (!sc_top) { incomment = 0; next }
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
