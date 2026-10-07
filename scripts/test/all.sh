#!/usr/bin/env bash
#
# The whole test run, the one command to run before committing: orch_test.sh,
# hooks_test.sh and docs_lint.sh, one after another, each in quiet mode. A
# failing suite does not stop the next. Printed per suite: its FAIL lines with
# their detail lines, then one summary line, "<suite>: <its last line>". A
# suite's stderr passes straight through. Exits 1 when any suite failed.
#
# ORCH_TEST_ONLY is unset, so every section of orch_test.sh runs. VERSION_BASE
# passes through untouched - set, empty or unset - for docs_lint.sh's version
# bump rule, which CI's "Read main's version" step feeds.
#
# While iterating, run one section instead:
#   ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh

unset ORCH_TEST_ONLY
export ORCH_TEST_QUIET=1
dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
failed=0
for suite in orch_test.sh hooks_test.sh docs_lint.sh; do
  out="$(bash "$dir/$suite")" || failed=1
  printf '%s\n' "$out" | awk '
    in_fail && /^     / { print; next }
    { in_fail = 0 }
    /^  FAIL / { print; in_fail = 1 }'
  echo "$suite: $(printf '%s\n' "$out" | tail -n 1)"
done
exit "$failed"
