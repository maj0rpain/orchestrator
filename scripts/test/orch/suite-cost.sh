# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# The record's one documented line shape: the full HEAD SHA, CPU and wall
# seconds to two places, the UTC time in ISO 8601, and the command, its words
# joined by single spaces - five tab-separated fields.
SUITE_COST_LINE='^[0-9a-f]{40}'$'\t''[0-9]+\.[0-9]{2}'$'\t''[0-9]+\.[0-9]{2}'$'\t''[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'$'\t'

# --- suite-cost run ------------------------------------------------------------
# Runs a verification command with its output and exit code passed through, and
# records a passing run's suite cost in the clone-wide record.
echo
echo "suite-cost run"
new_repo >/dev/null
rec="$(git rev-parse --git-common-dir)/orchestrator/suite-cost"

assert_eq "a fresh clone has no record directory" "$(on_disk "${rec%/*}")" absent
out="$("$ORCH" suite-cost run -- sh -c 'echo to-out; echo to-err >&2' 2>/dev/null)"; st=$?
assert_status "a passing command's exit 0 passes through" "$st" 0
assert_eq "its stdout passes through, with nothing added" "$out" "to-out"
err="$("$ORCH" suite-cost run -- sh -c 'echo to-out; echo to-err >&2' 2>&1 >/dev/null)"
assert_eq "its stderr passes through, with nothing added" "$err" "to-err"
assert_eq "the missing record directory is created" "$(on_disk "$rec")" present
assert_eq "each passing run appends exactly one line" "$(wc -l <"$rec" | tr -d ' ')" 2
line="$(tail -n 1 "$rec")"
[[ "$line" =~ $SUITE_COST_LINE ]] && shape=well-formed || shape="malformed: $line"
assert_eq "the line has the documented shape" "$shape" well-formed
assert_eq "its first field is HEAD's full SHA" "$(cut -f1 <<<"$line")" "$(git rev-parse HEAD)"
assert_eq "its fifth field is the command, its words joined by single spaces" \
  "$(cut -f5 <<<"$line")" "sh -c echo to-out; echo to-err >&2"
assert_eq "it has exactly five fields" "$(awk -F'\t' '{ print NF }' <<<"$line")" 5

before="$(cat "$rec")"
out="$("$ORCH" suite-cost run -- sh -c 'echo failing; exit 3' 2>&1)"; st=$?
assert_status "a failing command's exit code passes through" "$st" 3
assert_eq "its output passes through" "$out" "failing"
assert_eq "a non-zero exit appends nothing" "$(cat "$rec")" "$before"

git branch other
git worktree add -q "$PWD/wt" other
(cd wt && "$ORCH" suite-cost run -- true >/dev/null 2>&1)
assert_eq "a run in a second worktree lands in the same record" \
  "$(tail -n 1 "$rec" | cut -f5)" "true"
assert_eq "beside the main checkout's runs" "$(wc -l <"$rec" | tr -d ' ')" 3

for args in "" "true" "-- " "true --"; do
  # shellcheck disable=SC2086 # the words are the case
  out="$("$ORCH" suite-cost run $args 2>&1)"; st=$?
  assert_status "run with '${args}' is a usage error" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost run -- <cmd> [args...]"
done
assert_eq "a usage error records nothing" "$(wc -l <"$rec" | tr -d ' ')" 3

# An append that fails: the record's path is a directory, so no user, root
# included, can write it.
new_repo >/dev/null
rec="$(git rev-parse --git-common-dir)/orchestrator/suite-cost"
mkdir -p "$rec"
out="$("$ORCH" suite-cost run -- echo passed 2>/dev/null)"; st=$?
assert_status "an unwritable record still passes the command's exit 0 through" "$st" 0
assert_eq "and its stdout" "$out" "passed"
err="$("$ORCH" suite-cost run -- true 2>&1 >/dev/null)"
assert_contains "it warns on stderr with an orch: message" "$err" "orch: "
assert_contains "naming the record" "$err" "$rec"
assert_eq "and records nothing" "$(ls -A "$rec")" ""

out="$("$ORCH" suite-cost bogus 2>&1)"; st=$?
assert_status "suite-cost bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown suite-cost op"

# --- suite-cost history --------------------------------------------------------
# Prints the record's lines oldest first, in the documented line shape.
echo
echo "suite-cost history"
new_repo >/dev/null
out="$("$ORCH" suite-cost history 2>&1)"; st=$?
assert_status "history succeeds with no record" "$st" 0
assert_eq "and prints nothing" "$out" ""

rec="$(git rev-parse --git-common-dir)/orchestrator/suite-cost"
mkdir -p "${rec%/*}"
seed="$(printf '%s\t%s\t%s\t%s\t%s\n' \
  "$(git rev-parse HEAD)" 61.50 12.03 2026-10-01T10:00:00Z "scripts/test/all.sh" \
  "$(git rev-parse HEAD)" 64.00 12.50 2026-10-02T10:00:00Z "scripts/test/all.sh")"
printf '%s\n' "$seed" >"$rec"
out="$("$ORCH" suite-cost history 2>&1)"; st=$?
assert_status "history succeeds with a record" "$st" 0
assert_eq "it prints the seeded lines, oldest first" "$out" "$seed"

out="$("$ORCH" suite-cost history extra 2>&1)"; st=$?
assert_status "history refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost history"

out="$("$ORCH" help 2>&1)"
assert_contains "suite-cost run is in the usage text" "$out" "suite-cost run -- <cmd> [args...]"
assert_contains "suite-cost history is in the usage text" "$out" "suite-cost history"
assert_contains "the CLI conventions' noun table has a suite-cost row" \
  "$(grep '^| `suite-cost`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" \
  '`run`, `check`, `history`'
