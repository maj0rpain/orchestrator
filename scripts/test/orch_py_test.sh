#!/usr/bin/env bash
#
# The pytest suite: every test of the Python package in scripts/orch_py/
# (ADR-0067), run as one suite of all.sh and affected.sh. It is in neither
# all.sh's suites list nor the durations file, so it sits outside the suite
# budget, and it sources no tally.sh: pytest keeps its own count.
#
# pytest runs from the package folder (its pytest.ini names the tests), on the
# python of the /opt/orch-dev venv when that venv has one, else on python3 from
# PATH, with xdist, pytest-timeout's per-test timeout and no cache directory
# (both set in pytest.ini), no bytecode files, and
# a --basetemp under a temporary directory of its own, removed on exit (on INT
# or TERM too, once pytest has stopped), so it leaves no temporary file behind.
# The test-only ORCH_TEST_PYTEST_VENV names another venv directory.
#
# Its output is a suite's, as report.sh's report_suite reads it: a "  FAIL
# <test id>" line for each failed test and each error, with pytest's reason on
# a detail line under it, then the summary line "<n> passed, <m> failed", with
# ", <k> skipped" when pytest skipped any; errors count as failed. On any
# failure pytest's own output goes to stderr. A pytest run that ends with no
# result - an internal error, a usage error, no test collected - prints no
# summary line and exits with pytest's status, so the runners report it as
# died before its summary.
#
# Without pytest, pytest-xdist or pytest-timeout it runs nothing and prints
# "not installed - skipped", as the shellcheck run does: it exits 0, or 1 under
# CI (CI set and non-empty).
#
# It draws from the job pool (test_jobs.sh) like every other runner: it waits
# for one slot, then takes every other free slot without waiting, up to the
# run's job count (test_jobs_count, so ORCH_TEST_JOBS narrows it), holds them
# until pytest exits, and runs one xdist worker per slot held. Unpooled - under
# CI, nested in a runner that holds a slot, or with no flock - it runs as many
# workers as the job count. Outside CI it lowers its niceness to 10, as the
# other runners do.

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_jobs.sh
source "$dir/test_jobs.sh"
pkg="$dir/../orch_py"
venv="${ORCH_TEST_PYTEST_VENV:-/opt/orch-dev}"
python=python3
[ -x "$venv/bin/python" ] && python="$venv/bin/python"

# The check runs from the package, as pytest does, so no module in the
# caller's directory satisfies or breaks its imports.
if ! (cd "$pkg" && "$python" -c 'import pytest, xdist, pytest_timeout') </dev/null >/dev/null 2>&1; then
  echo "not installed - skipped"
  [ -n "${CI:-}" ] && exit 1
  exit 0
fi

jobs="$(test_jobs_count orch_py_test.sh)" || exit 1
test_jobs_lower_priority
test_jobs_pool_init orch_py_test.sh || exit 1
tmp="$(mktemp -d)" || exit 1
trap 'test_jobs_stop_children ${TEST_JOBS_CHILD:+"$TEST_JOBS_CHILD"}' INT TERM
trap 'rm -rf "$tmp"' EXIT

workers="$jobs"
if [ -n "$TEST_JOBS_POOL" ]; then
  test_jobs_slots_hold "$jobs"
  [ "${#TEST_JOBS_HELD_FDS[@]}" -eq 0 ] || workers="${#TEST_JOBS_HELD_FDS[@]}"
fi

# orch_py_pytest: pytest, in the child test_jobs_run_child starts, with the
# slot fds closed there: the run holds them, never pytest or its workers.
orch_py_pytest() {
  local fd
  for fd in "${TEST_JOBS_HELD_FDS[@]}"; do exec {fd}>&-; done
  cd "$pkg" || exit 1
  PYTHONDONTWRITEBYTECODE=1 exec "$python" -m pytest -q -rfE --basetemp="$tmp/basetemp" \
    -n "$workers" </dev/null
}
status=0
test_jobs_run_child orch_py_pytest >"$tmp/out" 2>&1 || status=$?

# The FAIL lines and the summary, from pytest's short test summary
# ("FAILED <id> - <reason>", "ERROR <id> - <reason>") and its last result line
# ("1 failed, 2 passed, 1 skipped, 1 error in 0.20s").
report="$(awk '
  /^(FAILED|ERROR) / {
    line = $0; sub(/^[A-Z]+ /, "", line)
    id = line; reason = ""
    at = index(line, " - ")
    if (at) { id = substr(line, 1, at - 1); reason = substr(line, at + 3) }
    print "  FAIL " id
    if (reason != "") print "     " reason
    next
  }
  / in [0-9.]+s/ && /(passed|failed|skipped|error|deselected)/ { result = $0 }
  END {
    if (result == "") exit
    n = split(result, words, /[ ,=]+/)
    for (i = 2; i <= n; i++) {
      if (words[i] !~ /^(passed|failed|skipped|error|errors)$/) continue
      count = words[i - 1] + 0
      if (words[i] == "passed") passed += count
      else if (words[i] == "skipped") skipped += count
      else failed += count
    }
    summary = (passed + 0) " passed, " (failed + 0) " failed"
    if (skipped) summary = summary ", " skipped " skipped"
    print "@summary " summary
  }' "$tmp/out")"

[ "$status" -eq 0 ] || cat "$tmp/out" >&2
summary=""
case "$report" in *"@summary "*) summary="${report##*@summary }" ;; esac
if [ "$status" -gt 1 ] || [ -z "$summary" ]; then
  echo "pytest ended with no result (exit $status)"
  [ "$status" -ne 0 ] || status=1
  exit "$status"
fi
fails="${report%@summary *}"
[ -z "$fails" ] || printf '%s' "$fails"
echo "$summary"
exit "$status"
