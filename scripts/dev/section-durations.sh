#!/usr/bin/env bash
# section-durations.sh: rewrites scripts/test/section-durations.tsv, the file
# orch_test.sh reads to start its sections longest-first. Run it when the
# suite's shape changes (sections added, removed or made much slower or faster),
# on a tree whose suite passes.
#
# It runs orch_test.sh once, unfiltered, with ORCH_TEST_DURATIONS pointing at a
# temporary file, so every section is measured (several at a time, from the job
# pool); then times each other suite of all.sh's suites list and the shellcheck
# step, one after another, with bash's `time` keyword. Each line of the file is
# "<wall tenths><TAB><CPU tenths><TAB><name>" - tenths of a second, CPU the
# user plus system time of the process tree: the sections in walk order, then
# the other suites in suite-list order, then `shellcheck`.
#
# ORCH_TEST_ONLY and ORCH_TEST_SHARD are unset, so the whole suite is always
# measured. With a job count of 1 (ORCH_TEST_JOBS=1) it prints a message naming
# the setting and exits 1 before measuring: a sequential run records nothing.
# If anything it measures fails it names each failure on stderr, exits 1 and
# leaves the committed file as it was; the file is replaced only when
# everything passed.
#
# A repo-development tool, not an orch.sh noun: it does not ship to users.
set -uo pipefail

dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../test" && pwd)"
root="$(cd "$dir/../.." && pwd)"
target="$dir/section-durations.tsv"
# shellcheck source=../test/test_jobs.sh
source "$dir/test_jobs.sh"
# shellcheck source=../test/test_tree.sh
source "$dir/test_tree.sh"
# shellcheck source=../test/report.sh
source "$dir/report.sh"

unset ORCH_TEST_ONLY ORCH_TEST_SHARD
jobs="$(test_jobs_count section-durations.sh)" || exit 1
if [ "$jobs" -eq 1 ]; then
  echo "section-durations.sh: ORCH_TEST_JOBS=1 runs sections one at a time and records no durations; unset it or set more than 1" >&2
  exit 1
fi
test_jobs_pool_init section-durations.sh || exit 1
suites_read "$dir/all.sh" "$dir" || {
  echo "section-durations.sh: $SUITES_ERR" >&2; exit 1; }

tmp="$(mktemp -d)" || exit 1
SHELLCHECK_PIDS=()
trap 'rm -rf "$tmp"' EXIT
trap 'test_jobs_stop_children ${SHELLCHECK_PIDS[@]+"${SHELLCHECK_PIDS[@]}"}' INT TERM
export ORCH_TEST_QUIET=1
failed=()

# measure <name> <cmd>...: runs the command with its output in $tmp/out, and
# appends "<wall>\t<cpu>\t<name>" to $tmp/rest, tenths of a second. The status
# is the command's.
measure() {
  local name="$1" st LC_NUMERIC=C
  shift
  # shellcheck disable=SC2034 # read by the time keyword
  TIMEFORMAT='%1R %1U %1S'
  { time "$@" >"$tmp/out" 2>&1; st=$?; } 2>"$tmp/time"
  awk -v name="$name" "$TENTHS_AWK"'
    { printf "%d\t%d\t%s\n", tenths($1), tenths($2) + tenths($3), name }
  ' "$tmp/time" >>"$tmp/rest"
  return "$st"
}

: >"$tmp/sections"
: >"$tmp/rest"
ORCH_TEST_DURATIONS="$tmp/sections" bash "$dir/orch_test.sh" || failed+=("orch_test.sh")

for suite in "${SUITES[@]}"; do
  [ "$suite" = orch_test.sh ] && continue
  TMPDIR="$tmp" measure "$suite" bash "$dir/$suite"; suite_st=$?
  if ! report_suite "$suite" "$suite_st" "$(<"$tmp/out")" >"$tmp/report"; then
    failed+=("$suite")
    cat "$tmp/report" "$tmp/out" >&2
  fi
done

if ! command -v shellcheck >/dev/null 2>&1; then
  failed+=("shellcheck (not installed)")
else
  shellcheck_files "$root"
  shellcheck_run() {
    shellcheck_start "$root" "$tmp" "$jobs"
    shellcheck_join "$tmp"
    printf '%s\n' "$SHELLCHECK_OUT"
    return "$SHELLCHECK_STATUS"
  }
  measure shellcheck shellcheck_run || {
    failed+=("shellcheck")
    cat "$tmp/out" >&2
  }
fi

if [ "${#failed[@]}" -gt 0 ]; then
  echo "section-durations.sh: failed, durations file left unchanged: ${failed[*]}" >&2
  exit 1
fi
if [ ! -s "$tmp/sections" ]; then
  echo "section-durations.sh: orch_test.sh recorded no sections, durations file left unchanged" >&2
  exit 1
fi
cat "$tmp/sections" "$tmp/rest" >"$tmp/new" || exit 1
cp "$tmp/new" "$target"
