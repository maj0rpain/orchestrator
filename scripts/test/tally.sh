#!/usr/bin/env bash
# shellcheck disable=SC2034 # PASS, FAIL and SKIP are read by the summary
#
# Sourced by every suite (orch_test.sh and the six standalone ones): the
# assertion tally, kept in a file so an assertion made inside a `( ... )`
# subshell still counts. Sourcing it only defines functions.
#
# Every assertion appends one line - ok, bad or skip - to the run's tally file,
# which tally_init creates under the suite's own temp root. Its path lives in a
# plain, unexported variable, so a suite this run starts in turn keeps a tally
# of its own, and a subshell, which inherits the variable, writes to this one.
# Bash 4.0+, as the rest of the suite.

# tally_init: create this run's tally file. Call it once, before the first
# assertion; exits 1 when the file cannot be made.
tally_init() {
  tally_file="$(mktemp)" || {
    echo "${0##*/}: cannot create the tally file" >&2; exit 1; }
}

# tally_read: set PASS, FAIL and SKIP from the tally file. A missing or
# unreadable file is reported on stderr and counts as a failure.
tally_read() {
  PASS=0 FAIL=0 SKIP=0
  if [ -z "${tally_file:-}" ] || [ ! -r "$tally_file" ]; then
    echo "${0##*/}: the tally file is missing or unreadable: ${tally_file:-not created}" >&2
    FAIL=1
    return 0
  fi
  local kind count
  for kind in ok bad skip; do
    count="$(grep -cx "$kind" "$tally_file")"
    case "$kind" in ok) PASS="$count" ;; bad) FAIL="$count" ;; skip) SKIP="$count" ;; esac
  done
}

# print_fail <title> <detail>: one FAIL line and its detail line. bad() and the
# parallel runner both print through it, so their FAIL lines cannot drift apart.
print_fail() { printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# ORCH_TEST_QUIET=1 hides the ok lines; the count, FAIL and skip lines,
# section headers and the summary still print.
ok()   { echo ok >>"$tally_file"; [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad()  { print_fail "$1" "$2"; echo bad >>"$tally_file"; }
skip() { printf '  skip %s\n     %s\n' "$1" "$2"; echo skip >>"$tally_file"; }
