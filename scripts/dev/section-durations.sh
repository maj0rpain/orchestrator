#!/usr/bin/env bash
# section-durations.sh: rewrites scripts/test/section-durations.tsv, the file
# orch_test.sh reads to start its sections longest-first. It has three modes.
# With no argument it is the full refresh, which resets the scale of every
# line: the human's call, made when the suite's shape changes (sections added,
# removed or made much slower or faster), on a tree whose suite passes. With
# --stale,
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
# Each of those other suites is timed under a slot of the job pool
# (test_jobs.sh's suite start): the wait for the slot is not timed, and the
# timed region ends once the suite and the slot's holder have both exited.
#
# Both modes time each other suite with DOCS_LINT_RECORDING=1, which only this
# script sets (all.sh and affected.sh unset it, CI never sets it, and
# docs_lint.sh --base-rules ignores it). docs_lint.sh's full run, with it
# set, skips the ledger freshness rule and the budget total rule (rules 1 and
# 2) and says so, so it does not fail on the lines being replaced; rule 3 still
# runs. With it unset it judges them all.
#
# ORCH_TEST_ONLY and ORCH_TEST_SHARD are unset, so the whole suite is always
# measured. With a job count of 1 (ORCH_TEST_JOBS=1) it prints a message naming
# the setting and exits 1 before measuring: a sequential run records nothing.
# If anything it measures fails it names each failure on stderr, exits 1 and
# leaves the committed file as it was; the file is replaced only when
# everything passed; it then deletes every durations fragment (never `.gitkeep`)
# along with it. On INT or TERM while it measures, it stops every run it
# started, exits 130 and leaves the durations file and every fragment in
# place. A TERM during the final copy into the durations file and the
# fragments' deletion is held until they end, so the file is
# then whole and new, never partial.
#
# With the argument --stale it records only what is out of date, in the
# branch's own durations fragment, `durations.d/<branch>.tsv` beside the
# durations file with each `/` of the branch name as `-`; it never edits the
# durations file or another fragment (the full refresh and --fold write the
# file). It refuses on a detached HEAD, naming the reason, writing nothing. It
# judges staleness and calibrates against the effective record (test_tree.sh's
# ledger_effective), so a line a fragment already supplies is fresh. It finds a
# section or suite with no line, or a stale line (a fingerprint that no longer
# matches the text, or a section or suite line of three columns only). The
# stale and missing sections are measured in one parallel orch_test.sh run
# filtered to them, together with the five calibration sections: the fresh
# sections whose recorded CPU is nearest 5.0 seconds, ties in walk order, never
# the isolation section (all of them when fewer than five). A stale or missing
# other suite is timed as the full refresh times it. The ratio is the
# calibration sections' recorded CPU, summed, over their measured CPU, summed;
# each new line's wall and CPU are what was measured times the ratio, rounded
# to tenths, and the line carries its fingerprint. The fragment is created, with
# durations.d, when missing; run again over its own fragment, it replaces the
# line of a re-recorded title, adds new lines, keeps walk order, leaves a title
# on two of its lines on one (the last), and drops its lines of no section or
# suite. It never writes a `shellcheck` line: only a full refresh does. It ends
# by printing the new effective total and the budget (the one number in
# suite-budget beside the durations file) on one line, naming the budget as
# missing when that file is missing or malformed; that does not stop the
# recording. Nothing out of date measures nothing, says so and creates no
# fragment (a fragment holding only surplus lines is mended without
# measuring). Something to measure with no fresh section is refused, naming the
# full refresh, and exits 1. When the effective record cannot be read it names
# the fault and exits 1. Any failed measurement is named, the durations file
# and every fragment are left unchanged and it exits 1, as the full refresh
# does; so is a job count of 1, refused, and an interrupt leaves them
# unchanged, as above. A TERM during the write of the fragment is held until
# it ends, so the fragment is whole.
#
# With the argument --fold it folds the durations fragments (the *.tsv files of
# durations.d beside the durations file; `.gitkeep` is no fragment) into the
# durations file, and measures nothing. It writes test_tree.sh's effective
# record (ledger_effective) in walk order, with the file's `shellcheck` line
# last, so no title is written twice and the lines of a section or suite that
# no longer exists are dropped, then deletes every fragment and keeps
# `.gitkeep`. The version-bump Action runs it on every push to main. With no
# fragment and the file already byte for byte that record it changes nothing,
# says so and exits 0; with no fragment but an orphaned or duplicated line it
# still rewrites the file. A malformed fragment line (a fragment's `shellcheck`
# line is not one) or a failing walk is named on stderr, exits 1 and leaves the
# file and every fragment unchanged; so does an interrupt. The file is replaced
# only whole. It needs no job pool, so ORCH_TEST_JOBS does not matter to it.
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

# replace_whole <src> <dest>: replaces <dest> with a copy of <src>, whole (a
# copy beside it, renamed over it), with INT and TERM held from here on, so an
# interrupt leaves <dest> whole, old or new.
replace_whole() {
  trap '' INT TERM
  cp "$1" "$2.$$" && mv "$2.$$" "$2"
}

# delete_fragments: deletes every durations fragment, never `.gitkeep`.
delete_fragments() {
  local f
  while IFS= read -r f; do rm -f "$f"; done < <(ledger_fragments "$dir")
}

# fold_run: the --fold mode (see the header); returns the script's status. It
# measures nothing, so it needs no job pool. Everything is computed in a
# temporary directory first; then the file is replaced whole (a copy beside it,
# renamed over it) and the fragments are deleted, with INT and TERM held, so an
# interrupt before that leaves the file and every fragment as they were.
fold_run() {
  local ftmp faults frags=()
  ftmp="$(mktemp -d)" || return 1
  trap 'rm -rf "$ftmp" "$target.$$"' EXIT
  trap 'exit 130' INT TERM
  faults="$(ledger_fragment_faults "$dir")" || return 1
  if [ -n "$faults" ]; then
    echo "section-durations.sh: malformed durations fragment line, nothing folded:" >&2
    printf '%s\n' "$faults" >&2
    return 1
  fi
  ledger_effective "$dir" >"$ftmp/effective" || {
    echo "section-durations.sh: ${LEDGER_ERR:-could not read the durations record}, nothing folded" >&2
    return 1
  }
  mapfile -t frags < <(ledger_fragments "$dir")
  if [ "${#frags[@]}" -eq 0 ] && [ -f "$target" ] && cmp -s "$ftmp/effective" "$target"; then
    echo "section-durations.sh: nothing to fold, durations file unchanged"
    return 0
  fi
  replace_whole "$ftmp/effective" "$target" || return 1
  delete_fragments
  echo "section-durations.sh: folded ${#frags[@]} fragments into the durations file"
}

mode=full
if [ "$#" -gt 1 ] || { [ "$#" -eq 1 ] && [ "$1" != --stale ] && [ "$1" != --fold ]; }; then
  echo "section-durations.sh: usage: section-durations.sh [--stale|--fold]" >&2
  exit 1
fi
[ "${1-}" = --stale ] && mode=stale
if [ "${1-}" = --fold ]; then
  fold_run
  exit
fi

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
trap 'test_jobs_stop_children ${TEST_JOBS_SUITE_PID:+"$TEST_JOBS_SUITE_PID"} ${TEST_JOBS_CHILD:+"$TEST_JOBS_CHILD"} ${SHELLCHECK_PIDS[@]+"${SHELLCHECK_PIDS[@]}"}' INT TERM
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

# suite_run <name>: the start step and both waits of a suite under a slot the
# caller took. The suite starts, then its pid and the slot's holder
# (TEST_JOBS_HOLDER_PID, waited on only when set) are waited on, so the
# holder's CPU is charged to this suite's line, not the next one's. The status
# is the suite's.
suite_run() {
  local st
  TMPDIR="$tmp" test_jobs_suite_start bash "$dir/$1"
  wait "$TEST_JOBS_SUITE_PID"; st=$?
  [ -z "$TEST_JOBS_HOLDER_PID" ] || wait "$TEST_JOBS_HOLDER_PID"
  TEST_JOBS_SUITE_PID=""
  return "$st"
}

# stale_report: prints the new effective total and the budget on one
# line; the budget is named as missing when suite-budget is missing or is not
# one positive whole number.
stale_report() {
  local total budget
  total="$(ledger_effective "$dir" | durations_total)" || return 1
  if suite_budget_read "$dir/suite-budget"; then
    budget="$SUITE_BUDGET CPU seconds"
  else
    budget=missing
  fi
  echo "section-durations.sh: total $(tenths_text "$total") CPU seconds, budget $budget"
}

# measure_suite <name>: times the other suite <name> as the full refresh does,
# and on a failure adds it to failed, with its report and output on stderr.
# DOCS_LINT_RECORDING=1 tells docs_lint.sh the ledger is being recorded, so it
# does not fail on the very lines this run replaces.
measure_suite() {
  local suite_st
  test_jobs_slot_wait
  DOCS_LINT_RECORDING=1 measure "$1" suite_run "$1"; suite_st=$?
  if ! report_suite "$1" "$suite_st" "$(<"$tmp/out")" >"$tmp/report"; then
    failed+=("$1")
    cat "$tmp/report" "$tmp/out" >&2
  fi
}

# frag_build <new lines file>: prints the branch's fragment as it should end,
# in walk order: the lines of its own fragment ($frag) for a title of the walk
# that the new lines lack (the last line of a title stands; a `shellcheck` line
# and a line of no section or suite are dropped), and the new lines
# "<index> <wall> <cpu> <title> <fingerprint>".
frag_build() {
  local own=/dev/null
  [ -f "$frag" ] && own="$frag"
  awk -F'\t' -v OFS='\t' "$DURATIONS_AWK"'
    FILENAME == ARGV[1] { if (!($1 in widx)) widx[$1] = $4; next }
    FILENAME == ARGV[2] { skip[$4] = 1; print $1, $2, $3, $4, $5; next }
    durations_line() && $3 != "shellcheck" && ($3 in widx) { keep[$3] = $0 }
    END { for (t in keep) if (!(t in skip)) print widx[t], keep[t] }' \
    "$tmp/walk" "$1" "$own" | sort -s -t "$TAB" -k1,1n | cut -f2-
}

# frag_write: replaces the branch's fragment with $tmp/frag whole (a copy
# beside it, renamed over it), creating durations.d when it is missing; an
# empty result removes the fragment. INT and TERM are held meanwhile (see
# replace_whole), so an interrupt leaves the fragment whole, old or new.
frag_write() {
  trap '' INT TERM
  if [ ! -s "$tmp/frag" ]; then
    rm -f "$frag"
    return 0
  fi
  mkdir -p "$(dirname "$frag")" && replace_whole "$tmp/frag" "$frag"
}

# stale_run: the --stale mode (see the header); returns the script's status.
stale_run() {
  local regex branch frag
  branch="$(git -C "$root" symbolic-ref --short -q HEAD 2>/dev/null)" || branch=""
  if [ -z "$branch" ]; then
    echo "section-durations.sh: --stale records into the branch's own fragment, and no branch is checked out (detached HEAD); nothing recorded" >&2
    return 1
  fi
  frag="$dir/durations.d/${branch//\//-}.tsv"
  # The ledger's walk: "<title> <fingerprint> <kind> <walk index>".
  awk -F'\t' -v OFS='\t' -v ns="${#LEDGER_OTHERS[@]}" 'NR == FNR { n = NR; next }
    { print $0, (FNR > n - ns ? "suite" : "section"), FNR }' "$tmp/fingerprints" "$tmp/fingerprints" >"$tmp/walk" || return 1
  # Staleness and calibration are judged on the effective record.
  ledger_effective "$dir" >"$tmp/eff" || {
    echo "section-durations.sh: ${LEDGER_ERR:-could not read the durations record}, nothing recorded" >&2
    return 1
  }
  # The states of the walk's titles and the record's (ledger_states), then
  # what to measure (todo: index, title, kind, fingerprint) and the fresh
  # sections but isolation (fresh).
  ledger_states "$tmp/walk" "$tmp/eff" >"$tmp/states" || return 1
  # A title on two lines of the branch's own fragment is measured afresh, as a
  # duplicate in the durations file is; the effective record holds only its
  # last line, so it is found in the fragment itself.
  if [ -f "$frag" ]; then
    awk -F'\t' "$DURATIONS_AWK"'durations_line() && $3 != "shellcheck" { c[$3]++ }
      END { for (t in c) if (c[t] > 1) print t }' "$frag" >"$tmp/dups" || return 1
  else
    : >"$tmp/dups"
  fi
  awk -F'\t' -v todo="$tmp/todo" -v fresh="$tmp/fresh" "$DURATIONS_AWK"'
    FILENAME == ARGV[1] { if (!($1 in fp)) { fp[$1] = $2; kind[$1] = $3; ttl[$4] = $1; top = $4 + 0 } next }
    FILENAME == ARGV[2] { state[$1] = $2; next }
    FILENAME == ARGV[3] { dup[$1] = 1; next }
    durations_line() && state[$3] == "fresh" { fcpu[$3] = $2 + 0 }
    END {
      printf "" > todo; printf "" > fresh
      for (k = 1; k <= top; k++) {
        name = ttl[k]
        if (name == "") continue
        if (state[name] != "fresh" || name in dup) printf "%d\t%s\t%s\t%s\n", k, name, kind[name], fp[name] > todo
        else if (kind[name] == "section" && k != 1) printf "%d\t%d\t%s\n", k, fcpu[name], name > fresh
      }
    }' "$tmp/walk" "$tmp/states" "$tmp/dups" "$tmp/eff" || return 1
  if [ ! -s "$tmp/todo" ]; then
    # Nothing to measure: only its own fragment's surplus is mended.
    if [ -f "$frag" ]; then
      frag_build /dev/null >"$tmp/frag" || return 1
      if ! cmp -s "$tmp/frag" "$frag"; then
        frag_write || return 1
        echo "section-durations.sh: mended the branch's fragment, measured nothing"
        stale_report
        return
      fi
    fi
    echo "section-durations.sh: nothing out of date, durations file and fragments unchanged"
    stale_report
    return
  fi
  if [ ! -s "$tmp/fresh" ]; then
    echo "section-durations.sh: no fresh section to calibrate against, nothing recorded; run the full refresh (section-durations.sh with no argument)" >&2
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
    echo "section-durations.sh: failed, nothing recorded: ${failed[*]}" >&2
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
  # The branch's fragment: its own lines and the new ones, in walk order.
  frag_build "$tmp/new" >"$tmp/frag" || return 1
  frag_write || return 1
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
    $3 in fp { print $0, fp[$3]; next } { print }' "$tmp/fingerprints" - |
  awk -F'\t' '!seen[$3]++' >"$tmp/new" || exit 1
# Whole or not at all: INT and TERM are held while the file is replaced and the
# fragments deleted.
replace_whole "$tmp/new" "$target" || exit 1
delete_fragments
