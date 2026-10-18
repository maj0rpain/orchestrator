#!/usr/bin/env bash
#
# Tests for scripts/dev/lens-bench.sh, the lens benchmark.
#
# Each case runs `lens-bench.sh measure` on output directories laid out as
# `lens-bench.sh run` writes them - the committed, hand-built fixture under
# scripts/test/lens-bench/, or a copy of it with a file taken away - and
# asserts only what the run prints and its exit status. The failure modes
# worth catching: a split message counted twice, coverage judged by anything
# but the overlap rule, a summary over the wrong values, and a broken
# directory measured instead of refused.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BENCH="$DIR/dev/lens-bench.sh"
FIXTURE="$DIR/test/lens-bench"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines,
# section headers and the summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_lacks()    { case "$2" in *"$3"*) bad "$1" "unexpected '$3' in: $2" ;; *) ok "$1" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }
assert_status()   { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got exit $2"; fi; }

# The temp root, created before anything else: TMPDIR is exported as it, so
# every mktemp below lands inside it. The EXIT trap leaves the root, removes
# it, and keeps the exit status. An INT or TERM exits 130 through that trap.
bench_root="$(mktemp -d)" || {
  echo "lens_bench_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$bench_root"
bench_remove_root() {
  local status=$?
  cd / || :
  rm -rf "$bench_root"
  exit "$status"
}
trap bench_remove_root EXIT
trap 'exit 130' INT TERM

# >>> checks

# run_bench <args...>: runs the tool; its stdout lands in $out, its stderr in
# $err, its exit status in $st.
run_bench() {
  out="$(bash "$BENCH" "$@" 2>"$bench_root/stderr")"; st=$?
  err="$(<"$bench_root/stderr")"
}

echo "lens-bench tests"

echo
echo "usage errors"
for usage_case in "" "measure" "bogus" "measure -x"; do
  # shellcheck disable=SC2086 # each case's words are its arguments
  run_bench $usage_case
  assert_status "'$usage_case' exits 2" "$st" 2
  assert_contains "'$usage_case' prints the usage line" "$err" "usage: lens-bench.sh measure <dir>..."
  assert_empty "'$usage_case' prints nothing on stdout" "$out"
done

# has_line <test> <output> <line>: <line> is one whole line of <output>.
has_line() {
  if grep -qxF -- "$3" <<<"$2"; then ok "$1"; else bad "$1" "no line '$3' in: $2"; fi
}

echo
echo "per-run rows"
run_bench measure "$FIXTURE/with-baseline"
assert_status "measuring a directory exits 0" "$st" 0
assert_empty "measuring a directory prints nothing on stderr" "$err"
has_line "heads the report with the directory" "$out" "## $FIXTURE/with-baseline"
has_line "names the lens, revision and model" "$out" \
  "Lens implementability, revision 0123456789abcdef0123456789abcdef01234567, model claude-opus-5-5"
has_line "a split message counts as one turn and its input once" "$out" \
  "| run-1 | 3 | 3468 | 2 2 0 | 3 2 | 11 | 18 2 7 4 11 | 3/5 |"
has_line "a run with no ranged read shows none" "$out" \
  "| run-2 | 2 | 300 | 1 0 | - | 3 | 5 5 1 | 2/5 |"
has_line "a run with no tool call and no map has one turn of no calls" "$out" \
  "| run-3 | 1 | 2000 | 0 | - | - | - | 0/5 |"
assert_lacks "prints no row for a missing run" "$out" "| run-4 |"

echo
echo "coverage"
# with-baseline/map.md: a.sh:10 (old format), a.sh:20-30, a.sh:40-45,
# b.sh:5-8, and c.sh:100 followed by a second location, c.sh:200.
has_line "counts each baseline line's first location alone" "$out" "Baseline map: 5 locations"
# run-1's map: a.sh:8-25 merges a.sh:10 and a.sh:20-30; a.sh:41-42 and
# a.sh:44-50 split a.sh:40-45; d.sh:5-8 has b.sh:5-8's range in another file;
# c.sh:195-205 overlaps only the ignored c.sh:200.
assert_contains "a merged entry covers both, a split pair one, another file's and an ignored location none" \
  "$out" "| 18 2 7 4 11 | 3/5 |"
# run-2's map: a.sh:11-15 misses the one-line a.sh:10; b.sh:1-5 meets
# b.sh:5-8 at one line; c.sh:100-100 is c.sh:100.
assert_contains "an old-format entry is one line, and a range meeting it at one line overlaps" \
  "$out" "| 5 5 1 | 2/5 |"
assert_contains "a run with no map covers nothing and shows no widths" "$out" "| - | 0/5 |"

echo
echo "the per-directory summary"
has_line "summarises over every run" "$out" "Summary over 3 runs:"
has_line "turns: mean, median, minimum, maximum" "$out" "| Turns | 2 | 2 | 1 | 3 |"
has_line "input: a mean apart from the median, to one decimal place" "$out" \
  "| Input | 1922.7 | 2000 | 300 | 3468 |"
has_line "coverage: a run with no map counts as 0" "$out" "| Coverage | 1.7/5 | 2/5 | 0/5 | 3/5 |"

echo
echo "no baseline map"
run_bench measure "$FIXTURE/no-baseline/"
assert_status "a directory with no baseline map exits 0" "$st" 0
has_line "heads the report with the directory, its trailing slash dropped" "$out" \
  "## $FIXTURE/no-baseline"
has_line "says there is no baseline map" "$out" "Baseline map: none, so no coverage"
has_line "a row has no coverage" "$out" "| run-1 | 2 | 300 | 1 0 | - | 3 | 5 5 1 |"
has_line "a run with no map shows no widths and no coverage" "$out" "| run-2 | 1 | 100 | 0 | - | - | - |"
assert_lacks "the table has no coverage column" "$out" "Coverage"
has_line "an even number of runs takes the median between the middle two" "$out" \
  "| Turns | 1.5 | 1.5 | 1 | 2 |"
has_line "the summary has input" "$out" "| Input | 200 | 200 | 100 | 300 |"

echo
echo "more than one directory"
run_bench measure "$FIXTURE/with-baseline" "$FIXTURE/no-baseline"
assert_status "two directories exit 0" "$st" 0
assert_eq "reports each directory under its own heading, in order" \
  "$(grep -E '^## ' <<<"$out")" \
  "$(printf '## %s\n## %s' "$FIXTURE/with-baseline" "$FIXTURE/no-baseline")"
has_line "each directory has its own summary" "$out" "Summary over 2 runs:"

# broken <name> <file under with-baseline>: a copy of with-baseline, named
# <name>, with <file> removed. Prints its path.
broken() {
  local copy="$bench_root/$1"
  cp -R "$FIXTURE/with-baseline" "$copy"
  rm -rf "${copy:?}/$2"
  printf '%s\n' "$copy"
}
# refused <test> <dir> <named>: measuring <dir> after the good fixture exits
# 1, names <named> on stderr and prints no report.
refused() {
  run_bench measure "$FIXTURE/no-baseline" "$2"
  assert_status "$1: exits 1" "$st" 1
  assert_contains "$1: names it" "$err" "$3"
  assert_empty "$1: prints no report" "$out"
}

echo
echo "refusals"
refused "a directory that does not exist" "$bench_root/nowhere" "$bench_root/nowhere"
for file in lens revision model spec.md; do
  d="$(broken "no-$file" "$file")"
  refused "a directory missing its $file" "$d" "$d/$file"
done
d="$(broken no-transcript run-2/transcript.jsonl)"
refused "a run subdirectory with no transcript" "$d" "$d/run-2/transcript.jsonl"

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
