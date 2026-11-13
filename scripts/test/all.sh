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
# N)" when its last line is not a summary line, whatever its exit status. A
# suite whose output has a "  FAIL " line is failed whatever its exit status:
# when it exited 0, the line "<suite>: printed FAIL lines but exited 0" follows
# its summary line, so a count lost in any way still turns the run red. A
# suite's stderr is not captured: it passes straight through, and the suites'
# stderr may interleave.
#
# Then shellcheck, from the repo root two levels up, at warning severity, one
# process per shell file matched by the one recursive glob scripts/**/*.sh,
# with .shellcheckrc's source settings, the files being those test_tree.sh's
# function shellcheck_files lists. A glob that matches nothing is dropped,
# never passed to shellcheck as the literal pattern. The processes start
# alongside the suites, at most as many at a time as the job count
# (ORCH_TEST_JOBS when set, else test_jobs.sh's default: 75% of the usable CPUs,
# or ORCH_TEST_POOL_PERCENT percent; all of them under CI), so no single
# run of shellcheck over every file is the critical path and the machine is
# not flooded with one process per file. Each
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
# On INT or TERM it sends TERM to every suite and shellcheck process it started,
# waits for each one, and exits 130; the temporary directory is removed only
# after that. A child that ignores TERM keeps all.sh waiting on it.
#
# Last, on stdout, the verdict line (report.sh): "all.sh: PASS (<n> parts)" when
# the run exits 0, else "all.sh: FAIL (<part>, <part>, ...)". A part is each
# item that printed a summary line - every suite, and shellcheck - and n counts
# those lines. A failed part is named by its summary line's prefix, in report
# order; leftover temp files are named "temp files", where their message is
# printed.
# Shellcheck fails with findings, with no finding line, or missing under CI. The
# paths that end before the report - an invalid ORCH_TEST_JOBS or
# ORCH_TEST_POOL_PERCENT, an INT or TERM stop - print no verdict.
#
# Exits 1 when any suite failed or printed a FAIL line, a suite left temp files
# behind, or shellcheck did not pass.
#
# ORCH_TEST_ONLY is unset, so every section of orch_test.sh runs.
#
# ORCH_TEST_SHARD=<i>/<n> passes to orch_test.sh alone (never to the other
# suites), which runs group i of n of its sections; all.sh runs the other suites
# and shellcheck only when i is 1, and in any other group runs orch_test.sh
# alone, its verdict line counting the parts it ran. An empty value is unset; a
# malformed one makes all.sh print "all.sh: ORCH_TEST_SHARD='<value>' is not
# <i>/<n> with 1 <= i <= n" on stderr and exit 1 before anything starts.
#
# CHANGELOG_BASE and NO_VERSION_BUMP pass through untouched - set, empty or
# unset - for docs_lint.sh's changelog fragment rule, which CI's "Read main's
# commit" step feeds. ORCH_TEST_JOBS
# passes through too: orch_test.sh runs that many sections at once, by default
# 75% of the usable CPUs (ORCH_TEST_POOL_PERCENT sets another share; the full
# count under CI), and ORCH_TEST_JOBS=1 runs them
# sequentially, in one shell. A set ORCH_TEST_JOBS that is not a positive
# integer makes all.sh print "all.sh: ORCH_TEST_JOBS='<value>' is not a positive
# integer" on stderr and exit 1 before anything starts; a set
# ORCH_TEST_POOL_PERCENT that is not one does the same with its own name (not
# under CI, which ignores it). The default all.sh
# computes for its shellcheck limit is never exported: an unset ORCH_TEST_JOBS
# stays unset for the suites.
#
# Each shellcheck process holds a slot of the job pool (test_jobs.sh) while it
# runs, waiting for one when none is free, and printing "all.sh: waiting for a
# job slot (N in use)" on stderr the first time; CI bypasses the pool.
#
# Outside CI all.sh lowers its own niceness to 10 at start (test_jobs.sh), so
# every process it starts inherits it; a niceness of 10 or more is left alone,
# and a failing renice is ignored.

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_jobs.sh
source "$dir/test_jobs.sh"
# shellcheck source=report.sh
source "$dir/report.sh"
# shellcheck source=test_tree.sh
source "$dir/test_tree.sh"
sc_jobs="$(test_jobs_count all.sh)" || exit 1
test_jobs_lower_priority
test_jobs_pool_init all.sh || exit 1
unset ORCH_TEST_ONLY
all_shard="${ORCH_TEST_SHARD:-}"
unset ORCH_TEST_SHARD
test_jobs_shard all.sh "$all_shard" || exit 1
export ORCH_TEST_QUIET=1
tmp="$(mktemp -d)" || exit 1
pids=()
sc_pids=()
# On INT or TERM, TERM every suite and shellcheck started, wait for each, and
# exit 130; the EXIT trap removes the temp directory only after that.
trap 'test_jobs_stop_children "${pids[@]}" "${sc_pids[@]}"' INT TERM
trap 'rm -rf "$tmp"' EXIT
suites_tmp="$tmp/suites-tmp"
mkdir "$suites_tmp" || exit 1

suites=(orch_test.sh hooks_test.sh docs_lint.sh version_bump_test.sh autopilot_container_test.sh autopilot_up_test.sh lens_bench_test.sh)
# A group other than the first runs orch_test.sh alone.
if [ "$TEST_SHARD_I" -gt 1 ]; then suites=(orch_test.sh); fi
for suite in "${suites[@]}"; do
  if [ "$suite" = orch_test.sh ]; then
    TMPDIR="$suites_tmp" ORCH_TEST_SHARD="$all_shard" bash "$dir/$suite" >"$tmp/$suite" &
  else
    TMPDIR="$suites_tmp" bash "$dir/$suite" >"$tmp/$suite" &
  fi
  pids+=("$!")
done
have_sc=0
if [ "$TEST_SHARD_I" -eq 1 ] && command -v shellcheck >/dev/null 2>&1; then
  have_sc=1
  root="$dir/../.."
  shellcheck_files "$root"
  sc_files=("${SHELLCHECK_FILES[@]}")
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
    test_jobs_slot_wait
    (cd "$root" && test_jobs_job shellcheck -S warning -f gcc "$sc_rel") \
      >"$tmp/shellcheck.${#sc_pids[@]}" 2>&1 &
    sc_pids+=("$!")
    test_jobs_slot_release "$!"
  done
fi

suite_exits=()
for suite_pid in "${pids[@]}"; do
  wait "$suite_pid"
  suite_exit=$?
  suite_exits+=("$suite_exit")
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
  report_suite "$suite" "${suite_exits[$suite_n]}" "$(<"$tmp/$suite")"
done

leftovers=("$suites_tmp"/* "$suites_tmp"/.[!.]* "$suites_tmp"/..?*)
for leftover in "${leftovers[@]}"; do
  if [ -e "$leftover" ] || [ -L "$leftover" ]; then
    echo "all.sh: the suites left temp files behind"
    report_temp_files_left
    break
  fi
done

if [ "$TEST_SHARD_I" -gt 1 ]; then
  :
elif [ "$have_sc" -eq 0 ]; then
  report_shellcheck_missing
else
  report_shellcheck "$sc_status" "$sc_out"
fi
report_verdict all.sh
exit $?
