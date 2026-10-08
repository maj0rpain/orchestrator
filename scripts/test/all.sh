#!/usr/bin/env bash
#
# The whole test run, the one command to run before committing: orch_test.sh,
# hooks_test.sh and docs_lint.sh, one after another, each in quiet mode. A
# failing suite does not stop the next. Printed per suite: its FAIL lines with
# their detail lines, then one summary line, "<suite>: <its last line>". A
# suite's stderr passes straight through.
#
# Then shellcheck, from the repo root two levels up:
# "shellcheck -S warning -f gcc scripts/*.sh scripts/test/*.sh", every tracked
# shell file, with .shellcheckrc's source settings. Its summary line has the
# same shape: each finding line, then "shellcheck: N findings"; or
# "shellcheck: 0 findings" when clean; or, on a non-zero exit with no finding
# line, shellcheck's output, then "shellcheck: failed (exit N)". With
# no shellcheck on PATH it prints "shellcheck: not installed - skipped", which
# fails the run only when CI is set.
#
# Exits 1 when any suite failed or shellcheck did not pass.
#
# ORCH_TEST_ONLY is unset, so every section of orch_test.sh runs. VERSION_BASE
# passes through untouched - set, empty or unset - for docs_lint.sh's version
# bump rule, which CI's "Read main's version" step feeds. ORCH_TEST_JOBS
# passes through too: orch_test.sh runs that many sections at once, by default
# the core count, and ORCH_TEST_JOBS=1 runs them sequentially, in one shell.
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

if ! command -v shellcheck >/dev/null 2>&1; then
  echo "shellcheck: not installed - skipped"
  [ -n "${CI:-}" ] && failed=1
else
  sc_out="$(cd "$dir/../.." && shellcheck -S warning -f gcc scripts/*.sh scripts/test/*.sh 2>&1)"
  sc_status=$?
  sc_findings="$(printf '%s\n' "$sc_out" | awk '/^[^:]+:[0-9]+:[0-9]+: /')"
  if [ "$sc_status" -eq 0 ]; then
    echo "shellcheck: 0 findings"
  elif [ -n "$sc_findings" ]; then
    printf '%s\n' "$sc_findings"
    echo "shellcheck: $(printf '%s\n' "$sc_findings" | awk 'END { print NR }') findings"
    failed=1
  else
    [ -n "$sc_out" ] && printf '%s\n' "$sc_out"
    echo "shellcheck: failed (exit $sc_status)"
    failed=1
  fi
fi
exit "$failed"
