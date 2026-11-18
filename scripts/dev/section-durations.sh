#!/usr/bin/env bash
# section-durations.sh: rewrites scripts/test/section-durations.tsv, the file
# orch_test.sh reads to start its sections longest-first. It has two modes. With
# no argument it is the full refresh, which resets the scale of every line: the
# human's call, made when the suite's shape changes (sections added, removed or
# made much slower or faster), on a tree whose suite passes. With --stale,
# below, a session that adds or edits tests records just what its change made
# out of date.
#
# The full refresh runs orch_test.sh once, unfiltered, with ORCH_TEST_DURATIONS
# pointing at a temporary file, so every section is measured (several at a time,
# from the job pool); then times each other suite of all.sh's suites list and
# the shellcheck step, one after another, with bash's `time` keyword. Each line
# of the file is "<wall tenths><TAB><CPU tenths><TAB><name><TAB><fingerprint>"
# - tenths of a second, CPU the user plus system time of the process tree: the
# sections in walk order, then the other suites in suite-list order, then
# `shellcheck`, whose line has three columns, no fingerprint. The fingerprint
# is the hash of the test text the line was measured from (test_tree.sh's
# ledger_fingerprints): a section's own lines plus its file's preamble, a
# suite's whole file; it is taken before anything is measured.
#
# ORCH_TEST_ONLY and ORCH_TEST_SHARD are unset, so the whole suite is always
# measured. With a job count of 1 (ORCH_TEST_JOBS=1) it prints a message naming
# the setting and exits 1 before measuring: a sequential run records nothing.
# If anything it measures fails it names each failure on stderr, exits 1 and
# leaves the committed file as it was; the file is replaced only when
# everything passed. On INT or TERM while it measures, it stops every run it
# started, exits 130 and leaves the durations file unchanged. A TERM during the
# final copy into the durations file is held until the copy ends, so the file is
# then whole and new, never partial.
#
# With the argument --stale it records only what is out of date, in the same
# durations file. It finds a section or suite with no line, a stale line (a
# fingerprint that no longer matches the text, or a section or suite line of
# three columns only), a line whose section or suite no longer exists, and a
# title on two lines. A section or suite title on two lines has every line
# removed and is measured afresh; two shellcheck lines end as the first, the
# rest removed, and shellcheck is never measured (only a full refresh writes
# it). The stale and missing sections are measured in one parallel orch_test.sh
# run filtered to them, together with the five calibration sections: the fresh
# sections whose recorded CPU is nearest 5.0 seconds, ties in walk order, never
# the isolation section (all of them when fewer than five). A stale or missing
# other suite is timed as the full refresh times it. The ratio is the
# calibration sections' recorded CPU, summed, over their measured CPU, summed;
# each new line's wall and CPU are what was measured times the ratio, rounded
# to tenths, and the line carries its fingerprint. New lines sit in walk order,
# orphaned lines are removed, and every other line is left byte for byte. It
# ends by printing the new total and the budget (the one number in suite-budget
# beside the durations file) on one line, naming the budget as missing when
# that file is missing or malformed; that does not stop the recording. Nothing
# out of date measures nothing, says so and exits 0; only orphaned or surplus
# lines are removed without measuring anything. Something to measure with no
# fresh section is refused, naming the full refresh, and exits 1. Any failed
# measurement is named, the file is left unchanged and it exits 1, as the full
# refresh does; so is a job count of 1, refused, and an interrupt leaves the
# file unchanged, as above.
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

mode=full
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --stale ]; }; then
  echo "section-durations.sh: usage: section-durations.sh [--stale]" >&2
  exit 1
fi
[ "${1-}" = --stale ] && mode=stale

unset ORCH_TEST_ONLY ORCH_TEST_SHARD
jobs="$(test_jobs_count section-durations.sh)" || exit 1
if [ "$jobs" -eq 1 ]; then
  echo "section-durations.sh: ORCH_TEST_JOBS=1 runs sections one at a time and records no durations; unset it or set more than 1" >&2
  exit 1
fi
test_jobs_pool_init section-durations.sh || exit 1

TAB=$(printf "\t")
tmp="$(mktemp -d)" || exit 1
ledger_fingerprints_all "$dir" >"$tmp/fingerprints" || {
  echo "section-durations.sh: ${SUITES_ERR:-could not fingerprint the test text}" >&2; rm -rf "$tmp"; exit 1; }
SHELLCHECK_PIDS=()
trap 'rm -rf "$tmp"' EXIT
trap 'test_jobs_stop_children ${TEST_JOBS_CHILD:+"$TEST_JOBS_CHILD"} ${SHELLCHECK_PIDS[@]+"${SHELLCHECK_PIDS[@]}"}' INT TERM
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

# stale_report: prints the durations file's new total and the budget on one
# line; the budget is named as missing when suite-budget is missing or is not
# one positive whole number.
stale_report() {
  local total budget
  total="$(durations_total <"$target")" || return 1
  total="$((total / 10)).$((total % 10))"
  if suite_budget_read "$dir/suite-budget"; then
    budget="$SUITE_BUDGET CPU seconds"
  else
    budget=missing
  fi
  echo "section-durations.sh: total $total CPU seconds, budget $budget"
}

# DOCS_LINT_RECORDING=1 tells docs_lint.sh the ledger is being recorded, so it
# does not fail on the very lines this run replaces.
# measure_suite <name>: times the other suite <name> as the full refresh does,
# and on a failure adds it to failed, with its report and output on stderr.
measure_suite() {
  local suite_st
  DOCS_LINT_RECORDING=1 TMPDIR="$tmp" measure "$1" test_jobs_run_child bash "$dir/$1"; suite_st=$?
  if ! report_suite "$1" "$suite_st" "$(<"$tmp/out")" >"$tmp/report"; then
    failed+=("$1")
    cat "$tmp/report" "$tmp/out" >&2
  fi
}

# stale_run: the --stale mode (see the header); returns the script's status.
stale_run() {
  local regex
  # The ledger's walk: "<title> <fingerprint> <kind> <walk index>".
  awk -F'\t' -v OFS='\t' -v ns="${#LEDGER_OTHERS[@]}" 'NR == FNR { n = NR; next }
    { print $0, (FNR > n - ns ? "suite" : "section"), FNR }' "$tmp/fingerprints" "$tmp/fingerprints" >"$tmp/walk" || return 1
  [ -f "$target" ] || : >"$target"
  # Pass 1: the lines kept byte for byte (kept), what to measure (todo: index,
  # title, kind, fingerprint) and the fresh sections but isolation (fresh).
  awk -F'\t' -v kept="$tmp/kept" -v todo="$tmp/todo" -v fresh="$tmp/fresh" "$DURATIONS_AWK"'
    NR == FNR { if (!($1 in fp)) { fp[$1] = $2; kind[$1] = $3; ttl[$4] = $1; top = $4 + 0 } next }
    { line[++n] = $0
      ok[n] = durations_line()
      if (ok[n]) { t[n] = $3; cnt[$3]++; nf[n] = NF; f4[n] = (NF == 4 ? $4 : ""); cpuv[n] = $2 + 0 } }
    END {
      printf "" > kept; printf "" > todo; printf "" > fresh
      for (i = 1; i <= n; i++) {
        if (!ok[i]) { print line[i] > kept; continue }
        name = t[i]
        if (name == "shellcheck") { if (!seen) { seen = 1; print line[i] > kept } continue }
        if (!(name in fp) || cnt[name] > 1) continue
        if (nf[i] == 4 && f4[i] == fp[name]) { print line[i] > kept; isfresh[name] = 1; fcpu[name] = cpuv[i] }
      }
      for (k = 1; k <= top; k++) {
        name = ttl[k]
        if (name == "") continue
        if (!(name in isfresh)) printf "%d\t%s\t%s\t%s\n", k, name, kind[name], fp[name] > todo
        else if (kind[name] == "section" && k != 1) printf "%d\t%d\t%s\n", k, fcpu[name], name > fresh
      }
    }' "$tmp/walk" "$target" || return 1
  if [ ! -s "$tmp/todo" ]; then
    if cmp -s "$tmp/kept" "$target"; then
      echo "section-durations.sh: nothing out of date, durations file unchanged"
    else
      cp "$tmp/kept" "$target" || return 1
      echo "section-durations.sh: removed the lines of no section or suite, measured nothing"
    fi
    stale_report
    return
  fi
  if [ ! -s "$tmp/fresh" ]; then
    echo "section-durations.sh: no fresh section to calibrate against, durations file left unchanged; run the full refresh (section-durations.sh with no argument)" >&2
    return 1
  fi
  # The calibration sections: recorded CPU nearest 5.0 seconds, ties in walk
  # order; "<distance> <index> <cpu> <title>".
  awk -F'\t' '{ d = $2 - 50; if (d < 0) d = -d; printf "%d\t%d\t%d\t%s\n", d, $1, $2, $3 }' "$tmp/fresh" |
    sort -t "$TAB" -k1,1n -k2,2n | awk "NR <= 5" >"$tmp/calib" || return 1
  { awk -F'\t' '$3 == "section" { print $2 }' "$tmp/todo"; cut -f4 "$tmp/calib"; } >"$tmp/needed"
  # One filtered parallel run measures the stale and missing sections and the
  # calibration ones; the pattern holds each title whole.
  regex="$(titles_regex <"$tmp/needed")"
  : >"$tmp/sections"
  : >"$tmp/rest"
  ORCH_TEST_ONLY="$regex" ORCH_TEST_DURATIONS="$tmp/sections" \
    test_jobs_run_child bash "$dir/orch_test.sh" >"$tmp/orch.out" 2>&1 || {
    failed+=("orch_test.sh")
    cat "$tmp/orch.out" >&2
  }
  mapfile -t unmeasured < <(awk -F'\t' 'NR == FNR { have[$3] = 1; next } !($0 in have)' "$tmp/sections" "$tmp/needed")
  for title in ${unmeasured[@]+"${unmeasured[@]}"}; do
    failed+=("section '$title' (no line measured)")
  done
  while IFS=$'\t' read -r _ title kind _; do
    [ "$kind" = suite ] || continue
    measure_suite "$title"
  done <"$tmp/todo"
  if [ "${#failed[@]}" -gt 0 ]; then
    echo "section-durations.sh: failed, durations file left unchanged: ${failed[*]}" >&2
    return 1
  fi
  # The new lines, "<index> <wall> <cpu> <title> <fingerprint>": measured times
  # the ratio, rounded to tenths; the measured CPU sum is held at one tenth or
  # more, so a calibration that measured nothing cannot divide by zero.
  cat "$tmp/sections" "$tmp/rest" >"$tmp/measured"
  awk -F'\t' -v OFS='\t' '
    FILENAME == ARGV[1] { rec[$4] = $3; next }
    FILENAME == ARGV[2] { idx[$2] = $1; fp[$2] = $4; next }
    { if (!($3 in wall)) { wall[$3] = $1 + 0; cpu[$3] = $2 + 0 } }
    END {
      for (name in rec) { r += rec[name]; m += cpu[name] }
      if (m < 1) m = 1
      for (name in idx) print idx[name], int(wall[name] * r / m + 0.5), int(cpu[name] * r / m + 0.5), name, fp[name]
    }' "$tmp/calib" "$tmp/todo" "$tmp/measured" | sort -t "$TAB" -k1,1n >"$tmp/new" || return 1
  # Merge: a new line goes before the first kept line that is later in the walk.
  awk -F'\t' -v OFS='\t' "$DURATIONS_AWK"'
    FILENAME == ARGV[1] { widx[$1] = $4; next }
    FILENAME == ARGV[2] { nn++; nidx[nn] = $1; $1 = ""; nline[nn] = substr($0, 2); next }
    {
      k = last
      if (durations_line())
        k = ($3 == "shellcheck" ? 1000000000 : ($3 in widx ? widx[$3] : last))
      while (p < nn && nidx[p + 1] < k) print nline[++p]
      last = k
      print
    }
    END { while (p < nn) print nline[++p] }' "$tmp/walk" "$tmp/new" "$tmp/kept" >"$tmp/final" || return 1
  cp "$tmp/final" "$target" || return 1
  stale_report
}
if [ "$mode" = stale ]; then
  stale_run
  exit
fi

: >"$tmp/sections"
: >"$tmp/rest"
ORCH_TEST_DURATIONS="$tmp/sections" test_jobs_run_child bash "$dir/orch_test.sh" || failed+=("orch_test.sh")

for suite in ${LEDGER_OTHERS[@]+"${LEDGER_OTHERS[@]}"}; do
  measure_suite "$suite"
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
cat "$tmp/sections" "$tmp/rest" |
  awk -F'\t' -v OFS='\t' 'NR == FNR { if (!($1 in fp)) fp[$1] = $2; next }
    $3 in fp { print $0, fp[$3]; next } { print }' "$tmp/fingerprints" - >"$tmp/new" || exit 1
cp "$tmp/new" "$target"
