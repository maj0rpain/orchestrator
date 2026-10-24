#!/usr/bin/env bash
#
# The whole test run, the one command to run before committing: every suite in
# the `suites` list below, each in quiet mode, and shellcheck, all started at
# once so they overlap.
# Each one's stdout is captured to a temporary directory, removed on exit, and
# its exit status is taken from waiting on it; once every one has finished,
# their output is printed in a fixed order, no matter which finished first. A
# failing suite does not stop the others. Printed per suite, in the order of
# the `suites` list: its FAIL lines with their detail lines, then one summary
# line, "<suite>: <its last line>", or "<suite>: died before its summary (exit
# N)" when it exited non-zero and its last line is not a summary line. A
# suite's stderr is not captured: it passes straight through, and the suites'
# stderr may interleave.
#
# Then shellcheck, from the repo root two levels up, at warning severity, one
# process per shell file matched by the one recursive glob scripts/**/*.sh,
# with .shellcheckrc's source settings. A glob that matches nothing is dropped,
# never passed to shellcheck as the literal pattern. The processes start
# alongside the suites, at most as many at a time as the job count
# (ORCH_TEST_JOBS when set, else test_jobs.sh's default: half the usable CPUs,
# all of them under CI), so no single shellcheck run over every file is the
# critical path and the machine is not flooded with one process per file. Each
# process's stdout and stderr go to its own captured
# buffer, and all.sh waits on each one; the buffers are joined in glob order,
# and the status taken is the highest exit among the processes. Its summary
# line has the same shape: each finding line, then "shellcheck: N findings"; or
# "shellcheck: 0 findings" when clean; or, on a non-zero exit with no finding
# line, the output of shellcheck, then "shellcheck: failed (exit N)". With
# no shellcheck on PATH it prints "shellcheck: not installed - skipped", which
# fails the run only when CI is set.
#
# The suites run with TMPDIR set to a fresh, empty directory under that
# temporary directory. Once they have finished, if anything is left in it -
# a suite that did not remove its temp files - all.sh prints "all.sh: the
# suites left temp files behind" after the suites' summaries and before
# the shellcheck summary, and the run fails.
#
# Exits 1 when any suite failed, a suite left temp files behind, or shellcheck
# did not pass.
#
# ORCH_TEST_ONLY is unset, so every section of orch_test.sh runs.
# CHANGELOG_BASE and NO_VERSION_BUMP pass through untouched - set, empty or
# unset - for docs_lint.sh's changelog fragment rule, which CI's "Read main's
# commit" step feeds. ORCH_TEST_JOBS
# passes through too: orch_test.sh runs that many sections at once, by default
# half the usable CPUs (the full count under CI), and ORCH_TEST_JOBS=1 runs them
# sequentially, in one shell. A set ORCH_TEST_JOBS that is not a positive
# integer makes all.sh print "all.sh: ORCH_TEST_JOBS='<value>' is not a positive
# integer" on stderr and exit 1 before anything starts. The default all.sh
# computes for its shellcheck limit is never exported: an unset ORCH_TEST_JOBS
# stays unset for the suites.
#
# Outside CI all.sh lowers its own niceness to 10 at start (test_jobs.sh), so
# every process it starts inherits it; a niceness of 10 or more is left alone,
# and a failing renice is ignored.

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_jobs.sh
source "$dir/test_jobs.sh"
if [ -n "${ORCH_TEST_JOBS+set}" ]; then
  sc_jobs="$ORCH_TEST_JOBS"
else
  sc_jobs="$(test_jobs_default)"
fi
if ! is_positive_integer "$sc_jobs"; then
  echo "all.sh: ORCH_TEST_JOBS='$sc_jobs' is not a positive integer" >&2
  exit 1
fi
sc_jobs=$((10#$sc_jobs))
test_jobs_lower_priority
unset ORCH_TEST_ONLY
export ORCH_TEST_QUIET=1
tmp="$(mktemp -d)" || exit 1
trap 'rm -rf "$tmp"' EXIT
failed=0
suites_tmp="$tmp/suites-tmp"
mkdir "$suites_tmp" || exit 1

suites=(orch_test.sh hooks_test.sh docs_lint.sh version_bump_test.sh autopilot_container_test.sh lens_bench_test.sh)
pids=()
for suite in "${suites[@]}"; do
  TMPDIR="$suites_tmp" bash "$dir/$suite" >"$tmp/$suite" &
  pids+=("$!")
done
have_sc=0
if command -v shellcheck >/dev/null 2>&1; then
  have_sc=1
  root="$dir/../.."
  sc_pids=()
  shopt -s globstar nullglob
  sc_files=("$root"/scripts/**/*.sh)
  shopt -u globstar nullglob
  # At most sc_jobs run at once: past that, wait for the oldest still running
  # (in start order, so its status is kept for the join below).
  sc_exits=()
  sc_next=0
  for sc_file in "${sc_files[@]}"; do
    while [ "$((${#sc_pids[@]} - sc_next))" -ge "$sc_jobs" ]; do
      wait "${sc_pids[$sc_next]}"
      sc_exits[sc_next]=$?
      sc_next=$((sc_next + 1))
    done
    sc_rel="${sc_file#"$root/"}"
    (cd "$root" && exec shellcheck -S warning -f gcc "$sc_rel") \
      >"$tmp/shellcheck.${#sc_pids[@]}" 2>&1 &
    sc_pids+=("$!")
  done
fi

suite_exits=()
for suite_pid in "${pids[@]}"; do
  wait "$suite_pid"
  suite_exit=$?
  suite_exits+=("$suite_exit")
  [ "$suite_exit" -ne 0 ] && failed=1
done
if [ "$have_sc" -eq 1 ]; then
  sc_status=0
  sc_out=""
  for sc_n in "${!sc_pids[@]}"; do
    if [ -n "${sc_exits[$sc_n]:-}" ]; then
      sc_exit="${sc_exits[$sc_n]}"
    else
      wait "${sc_pids[$sc_n]}"
      sc_exit=$?
    fi
    [ "$sc_exit" -gt "$sc_status" ] && sc_status=$sc_exit
    sc_part="$(<"$tmp/shellcheck.$sc_n")"
    [ -n "$sc_part" ] && sc_out+="${sc_out:+$'\n'}$sc_part"
  done
fi

for suite_n in "${!suites[@]}"; do
  suite="${suites[$suite_n]}"
  out="$(<"$tmp/$suite")"
  printf '%s\n' "$out" | awk '
    in_fail && /^     / { print; next }
    { in_fail = 0 }
    /^  FAIL / { print; in_fail = 1 }'
  last="$(printf '%s\n' "$out" | tail -n 1)"
  status="${suite_exits[$suite_n]}"
  if [ "$status" -ne 0 ] &&
    ! [[ "$last" =~ ^[0-9]+\ passed,\ [0-9]+\ failed(,\ [0-9]+\ skipped)?$ ]]; then
    echo "$suite: died before its summary (exit $status)"
  else
    echo "$suite: $last"
  fi
done

leftovers=("$suites_tmp"/* "$suites_tmp"/.[!.]* "$suites_tmp"/..?*)
for leftover in "${leftovers[@]}"; do
  if [ -e "$leftover" ] || [ -L "$leftover" ]; then
    echo "all.sh: the suites left temp files behind"
    failed=1
    break
  fi
done

if [ "$have_sc" -eq 0 ]; then
  echo "shellcheck: not installed - skipped"
  [ -n "${CI:-}" ] && failed=1
else
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
