#!/usr/bin/env bash
#
# Tests for scripts/version-bump.sh, the script the version-bump Action runs
# on every push to main.
#
# Each case runs the script from the root of a temporary checkout holding a
# .claude-plugin/plugin.json, a CHANGELOG.md and, under changelog.d/, the
# fragments, and asserts only what the run leaves: the files, its output and
# its exit status. The failure modes worth catching: a fragment lost or bumped
# twice, a bump at the wrong level, prose out of issue-number order, a byte of
# either file changed beyond the bump, and a refusal that writes anything.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUMP="$DIR/version-bump.sh"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines,
# section headers and the summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }
assert_status()   { if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got exit $2"; fi; }

# The temp root, created before anything else: TMPDIR is exported as it, so
# every mktemp below, and the script's own, lands inside it. The EXIT trap
# leaves the root, removes it, and keeps the exit status. An INT or TERM exits
# 130 through that trap.
bump_root="$(mktemp -d)" || {
  echo "version_bump_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$bump_root"
bump_remove_root() {
  local status=$?
  cd / || :
  rm -rf "$bump_root"
  exit "$status"
}
trap bump_remove_root EXIT
trap 'exit 130' INT TERM

# >>> checks

# checkout <version>: a fresh checkout whose plugin.json carries <version> on
# its one "version" line, among other lines, and whose CHANGELOG.md is a
# preamble and two older entries. Prints its path.
checkout() {
  local c
  c="$(mktemp -d "$bump_root/checkout.XXXXXX")"
  mkdir "$c/.claude-plugin"
  printf '{\n  "name": "orchestrator",\n  "version": "%s",\n  "keywords": [\n    "handoff"\n  ]\n}\n' \
    "$1" >"$c/.claude-plugin/plugin.json"
  printf '%s\n' '# Changelog' '' 'All notable changes.' '' "## $1" '' 'The latest change.' '' \
    '## 0.0.1' '' 'The first change.' >"$c/CHANGELOG.md"
  printf '%s\n' "$c"
}
# fragment <checkout> <name> <lines...>: writes changelog.d/<name>, one line
# per argument.
fragment() {
  local c="$1" name="$2"
  shift 2
  mkdir -p "$c/changelog.d"
  printf '%s\n' "$@" >"$c/changelog.d/$name"
}
# run_bump <checkout>: runs the script from <checkout>'s root; its stdout
# lands in $out, its stderr in $err, its exit status in $st.
run_bump() {
  out="$(cd "$1" && bash "$BUMP" 2>"$bump_root/stderr")"; st=$?
  err="$(<"$bump_root/stderr")"
}
# snapshot <checkout>: every file under it with its contents, so a refusal
# can be shown to change nothing.
snapshot() {
  (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do
    printf '== %s\n' "$f"; cat "$f"; done)
}
# version_of <checkout>: the version its plugin.json carries.
version_of() {
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$1/.claude-plugin/plugin.json"
}
# top_heading <checkout>: its CHANGELOG's first ## heading.
top_heading() { grep -m 1 -E '^## ' "$1/CHANGELOG.md"; }

echo "version-bump tests"

echo
echo "no fragment"
c="$(checkout 4.5.6)"
before="$(snapshot "$c")"
run_bump "$c"
assert_status "exits 0 with no fragment" "$st" 0
assert_empty "prints nothing with no fragment" "$out$err"
assert_eq "changes nothing with no fragment" "$(snapshot "$c")" "$before"

echo
echo "one fragment, each level"
for level_case in "patch 4.5.7" "minor 4.6.0" "major 5.0.0"; do
  read -r level want <<<"$level_case"
  c="$(checkout 4.5.6)"
  fragment "$c" 12.md "bump: $level" '' "A $level change."
  run_bump "$c"
  assert_status "a $level fragment exits 0" "$st" 0
  assert_eq "a $level fragment bumps 4.5.6 to $want, printing it" "$out" "$want"
  assert_eq "a $level fragment sets plugin.json's version to $want" "$(version_of "$c")" "$want"
  assert_eq "a $level fragment tops the CHANGELOG with ## $want" "$(top_heading "$c")" "## $want"
done
c="$(checkout 9.9.9)"
fragment "$c" 12.md "bump: patch" '' "Past nine."
run_bump "$c"
assert_eq "a patch bump steps a part past 9 numerically" "$out" "9.9.10"
c="$(checkout 1.9.3)"
fragment "$c" 12.md "bump: minor" '' "Past nine."
run_bump "$c"
assert_eq "a minor bump resets the patch to 0" "$out" "1.10.0"

echo
echo "the files a bump leaves"
c="$(checkout 4.5.6)"
fragment "$c" 12.md 'bump: patch' '' '' 'First line of the prose.' 'Second line.' ''
run_bump "$c"
assert_eq "the preamble, the new entry and the older entries, byte for byte" \
  "$(cat "$c/CHANGELOG.md")" \
  "$(printf '%s\n' '# Changelog' '' 'All notable changes.' '' '## 4.5.7' '' \
    'First line of the prose.' 'Second line.' '' '## 4.5.6' '' 'The latest change.' '' \
    '## 0.0.1' '' 'The first change.')"
assert_eq "every other plugin.json line is kept byte for byte" \
  "$(cat "$c/.claude-plugin/plugin.json")" \
  "$(printf '{\n  "name": "orchestrator",\n  "version": "4.5.7",\n  "keywords": [\n    "handoff"\n  ]\n}')"
assert_eq "the fragments are deleted" "$(find "$c" -path '*changelog.d*' -type f)" ""
assert_eq "the printed version is plugin.json's new version" "$out" "$(version_of "$c")"
assert_eq "the printed version is the CHANGELOG's top heading" "## $out" "$(top_heading "$c")"
# The facts docs_lint.sh's CHANGELOG check reads: the top heading equals the
# version, appears once, and its entry is non-empty.
assert_eq "the new version's heading appears once" \
  "$(grep -cxF -- "## $out" "$c/CHANGELOG.md")" "1"
assert_contains "the new version's entry is non-empty" \
  "$(sed -n "/^## $out\$/,/^## 4.5.6\$/p" "$c/CHANGELOG.md")" "First line of the prose."

echo
echo "several fragments"
c="$(checkout 4.5.6)"
fragment "$c" 30.md 'bump: minor' '' 'The minor change.'
fragment "$c" 20.md 'bump: patch' '' 'The patch change.'
run_bump "$c"
assert_eq "a patch and a minor fragment make one minor bump" "$out" "4.6.0"
assert_eq "one entry carries both fragments' prose, in issue-number order" \
  "$(sed -n '/^## 4.6.0$/,/^## 4.5.6$/p' "$c/CHANGELOG.md")" \
  "$(printf '%s\n' '## 4.6.0' '' 'The patch change.' '' 'The minor change.' '' '## 4.5.6')"
assert_eq "both fragments are deleted" "$(find "$c" -path '*changelog.d*' -type f)" ""
c="$(checkout 4.5.6)"
fragment "$c" 100.md 'bump: patch' '' 'Issue one hundred.'
fragment "$c" 99.md 'bump: patch' '' 'Issue ninety-nine.'
run_bump "$c"
assert_eq "issue-number order is numeric, 99 before 100" \
  "$(grep -E '^Issue ' "$c/CHANGELOG.md")" "$(printf '%s\n' 'Issue ninety-nine.' 'Issue one hundred.')"

# refused <test> <checkout> <file>: runs the script, which must exit 1, name
# <file> on stderr, print nothing on stdout, and change nothing.
refused() {
  local before
  before="$(snapshot "$2")"
  run_bump "$2"
  assert_status "$1: exits 1" "$st" 1
  assert_contains "$1: names $3" "$err" "$3"
  assert_empty "$1: prints no version" "$out"
  assert_eq "$1: changes nothing" "$(snapshot "$2")" "$before"
}

echo
echo "refusals"
# Each malformed fragment sits beside a well-formed one, so the refusal is
# shown to stop the whole run, not to skip the bad fragment.
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
fragment "$c" 12.md 'A change with no bump line.'
refused "a fragment with no bump: line" "$c" "changelog.d/12.md"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
fragment "$c" 12.md 'bump: huge' '' 'An unknown level.'
refused "a fragment with an unknown bump: level" "$c" "changelog.d/12.md"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
fragment "$c" 12.md 'bump: minor' '' '   '
refused "a fragment with no prose" "$c" "changelog.d/12.md"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
fragment "$c" notes.md 'bump: patch' '' 'Misnamed.'
refused "a file under changelog.d/ not named <digits>.md" "$c" "changelog.d/notes.md"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
fragment "$c" 12.txt 'bump: patch' '' 'Misnamed.'
refused "a fragment without the .md suffix" "$c" "changelog.d/12.txt"

c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
printf '{\n  "name": "orchestrator"\n}\n' >"$c/.claude-plugin/plugin.json"
refused "a plugin.json with no version line" "$c" ".claude-plugin/plugin.json"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
printf '{\n  "version": "4.5.6",\n  "version": "4.5.6"\n}\n' >"$c/.claude-plugin/plugin.json"
refused "a plugin.json with two version lines" "$c" ".claude-plugin/plugin.json"
c="$(checkout 4.5)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
refused "a plugin.json version that is not MAJOR.MINOR.PATCH" "$c" ".claude-plugin/plugin.json"
c="$(checkout 4.5.6-rc1)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
refused "a plugin.json version with a suffix" "$c" ".claude-plugin/plugin.json"
c="$(checkout 4.5.6)"
fragment "$c" 11.md 'bump: patch' '' 'A good one.'
printf '%s\n' '# Changelog' '' 'No entries yet.' >"$c/CHANGELOG.md"
refused "a CHANGELOG.md with no ## heading" "$c" "CHANGELOG.md"

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
