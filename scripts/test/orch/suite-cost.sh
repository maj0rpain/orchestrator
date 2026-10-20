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

# check_repo: a repo for suite-cost check, cwd inside it, its record's
# directory made: main's first commit (root) and its child (base), then branch
# feat off base, base recorded as its base SHA, with two commits (parent, then
# head, checked out). Sets root, base, parent, head, rec and the marker path a
# check's command leaves (marker), with cmd the words of that command and
# cmd_str its record field.
check_repo() {
  new_repo >/dev/null
  root="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m base
  base="$(git rev-parse HEAD)"
  git checkout -q -b feat
  git config branch.feat.orchestrator-base-sha "$base"
  git commit -q --allow-empty -m one
  parent="$(git rev-parse HEAD)"
  git commit -q --allow-empty -m two
  head="$(git rev-parse HEAD)"
  rec="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/orchestrator/suite-cost"
  mkdir -p "${rec%/*}"
  marker="$(mktemp -d)/ran"
  cmd=(touch "$marker")
  cmd_str="touch $marker"
}

# seed_run <sha> <cpu> [command]: appends a record line for a passing run at
# <sha> costing <cpu> CPU seconds, of <command> (default: cmd_str).
seed_run() {
  printf '%s\t%s\t1.00\t2026-10-01T10:00:00Z\t%s\n' "$1" "$2" "${3:-$cmd_str}" >>"$rec"
}

# --- suite-cost run ------------------------------------------------------------
# Runs a verification command with its output and exit code passed through, and
# records a passing run's suite cost in the clone-wide record.
echo
echo "suite-cost run"
new_repo >/dev/null
rec="$(git rev-parse --git-common-dir)/orchestrator/suite-cost"

assert_eq "a fresh clone has no record directory" "$(on_disk "${rec%/*}")" absent
errf="$(mktemp)"
out="$("$ORCH" suite-cost run -- sh -c 'echo to-out; echo to-err >&2' 2>"$errf")"; st=$?
assert_status "a passing command's exit 0 passes through" "$st" 0
assert_eq "its stdout passes through, with nothing added" "$out" "to-out"
assert_eq "its stderr passes through, with nothing added" "$(cat "$errf")" "to-err"
assert_eq "the missing record directory is created" "$(on_disk "$rec")" present
assert_eq "a passing run appends exactly one line" "$(wc -l <"$rec" | tr -d ' ')" 1
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
assert_eq "beside the main checkout's run" "$(wc -l <"$rec" | tr -d ' ')" 2

for args in "" "true" "-- " "true --"; do
  # shellcheck disable=SC2086 # the words are the case
  out="$("$ORCH" suite-cost run $args 2>&1)"; st=$?
  assert_status "run with '${args}' is a usage error" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost run -- <cmd> [args...]"
done
assert_eq "a usage error records nothing" "$(wc -l <"$rec" | tr -d ' ')" 2

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
assert_contains "suite-cost check is in the usage text" "$out" "suite-cost check -- <cmd> [args...]"
assert_contains "the CLI conventions' noun table has a suite-cost row" \
  "$(grep '^| `suite-cost`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" \
  '`run`, `check`, `history`'

# --- suite-cost check ----------------------------------------------------------
# Compares the head's recorded suite cost with the baseline's and prints one
# verdict line. Records are seeded in the documented line shape, so no path
# burns real CPU, and the command is a marker that proves when it ran.
echo
echo "suite-cost check"
check_repo

out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)"; st=$?
assert_status "check with no record exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "without running the command" "$(on_disk "$marker")" absent

seed_run "$base" 60.00
seed_run "$head" 70.00 "scripts/test/orch_test.sh"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)"; st=$?
assert_status "check with a baseline and a head record of another command exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "never running the command on the head" "$(on_disk "$marker")" absent
assert_eq "nor recording anything" "$(cat "$rec")" "$before"

seed_run "$parent" 70.00
seed_run "$base" 60.00
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)"; st=$?
assert_status "growth past the threshold exits 0" "$st" 0
assert_eq "on one stdout line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
assert_contains "a head record on HEAD's parent counts, and the newer one on the base does not" \
  "$out" "grew 17 - "
assert_contains "its text names the baseline commit" "$out" "$base"
assert_contains "and its CPU seconds" "$out" "60.00"
assert_contains "the head's CPU seconds" "$out" "70.00"
assert_contains "and the threshold" "$out" "10%"
assert_eq "check never runs the command with both recorded" "$(on_disk "$marker")" absent

seed_run "$head" 66.00
assert_eq "growth at the threshold is ok, the newest head record counting" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "ok"
seed_run "$head" 50.00
assert_eq "a shrinking suite is ok" "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "ok"

: >"$rec"
seed_run "$base" 50.00
seed_run "$head" 100.00
assert_eq "a baseline below the floor is off" "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "off"

: >"$rec"
seed_run "$base" 100.00
seed_run "$root" 60.00
seed_run "$base" 30.00 "scripts/test/orch_test.sh"
seed_run "$head" 70.00
assert_contains "the baseline is the newest recorded ancestor of the base, of the same command" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "grew 17 - "

# The base commit: base-sha's recorded SHA, else its merge-base; state.base_sha
# inside a flow. Base costs 100, parent 60 and head 70: from base, the head is
# 70 against 100 (ok); from parent, 70 against 60 (grew).
check_repo
seed_run "$base" 100.00
seed_run "$parent" 60.00
seed_run "$head" 70.00
git config branch.feat.orchestrator-base-sha "$parent"
assert_contains "outside a flow, the base commit is the branch's recorded base SHA" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "grew 17 - "
git config --unset branch.feat.orchestrator-base-sha
git branch -q localbase "$base"
git config branch.feat.orchestrator-base localbase
assert_eq "without one, the merge-base with its base branch" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "ok"
mkdir -p .orchestrator && echo '{}' >.orchestrator/state.json
state_fixture phase review
state_fixture base_sha "$parent"
assert_contains "inside a flow, it is state.base_sha" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "grew 17 - "

# Floor and growth overrides. 60 to 70 is 17% growth on a 60 baseline.
check_repo
seed_run "$base" 60.00
seed_run "$head" 70.00
git config orchestrator.suiteCost.floor 61
assert_eq "a raised floor turns the check off" "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "off"
git config orchestrator.suiteCost.floor 0.5
git config orchestrator.suiteCost.growth 20
assert_eq "a raised growth threshold lets the growth pass" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "ok"
git config orchestrator.suiteCost.growth 16.5
assert_contains "a decimal threshold is honoured, and named" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "16.5%"

# An invalid override dies before anything runs: no head here would have
# meant a base run, so the marker and the record prove none started.
check_repo
seed_run "$head" 70.00
before="$(cat "$rec")"
for kv in "floor abc" "floor -1" "growth 1e3" "growth 10%"; do
  key="orchestrator.suiteCost.${kv%% *}" val="${kv#* }"
  git config "$key" "$val"
  out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>&1)"; st=$?
  assert_status "$key = $val dies" "$st" 1
  assert_contains "with an orch: message naming the key" "$out" "orch: $key"
  assert_contains "and the value" "$out" "$val"
  git config --unset "$key"
done
assert_eq "an invalid override runs no command" "$(on_disk "$marker")" absent
assert_eq "and records nothing" "$(cat "$rec")" "$before"

for args in "" "true" "-- "; do
  # shellcheck disable=SC2086 # the words are the case
  out="$("$ORCH" suite-cost check $args 2>&1)"; st=$?
  assert_status "check with '${args}' is a usage error" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost check -- <cmd> [args...]"
done

# --- suite-cost check base run -------------------------------------------------
# With no recorded ancestor of the base, check measures the base once, in a
# temporary worktree it removes, and records a pass.
echo
echo "suite-cost check base run"
check_repo
noisy=(sh -c 'echo noisy; echo loud >&2; touch "$0"' "$marker")
seed_run "$head" 70.00 "${noisy[*]}"
out="$("$ORCH" suite-cost check -- "${noisy[@]}" 2>/dev/null)"; st=$?
assert_status "a base run's check exits 0" "$st" 0
assert_eq "with the verdict alone on stdout - a cheap base is below the floor" "$out" "off"
assert_eq "the command ran once" "$(on_disk "$marker")" present
line="$(tail -n 1 "$rec")"
[[ "$line" =~ $SUITE_COST_LINE ]] && shape=well-formed || shape="malformed: $line"
assert_eq "its record line has the documented shape" "$shape" well-formed
assert_eq "recorded at the base commit" "$(cut -f1 <<<"$line")" "$base"
assert_eq "for the command" "$(cut -f5 <<<"$line")" "${noisy[*]}"
assert_eq "and the worktree is gone" "$(git worktree list | wc -l | tr -d ' ')" 1
rm -f "$marker"
"$ORCH" suite-cost check -- "${noisy[@]}" >/dev/null 2>&1
assert_eq "the next check uses that record, running nothing" "$(on_disk "$marker")" absent

check_repo
seed_run "$head" 70.00 "false"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- false 2>/dev/null)"; st=$?
assert_status "a failing base run exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "recording nothing" "$(cat "$rec")" "$before"
assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1

if [ "$(id -u)" -ne 0 ]; then
  check_repo
  seed_run "$head" 70.00
  chmod 444 "$rec"
  errf="$(mktemp)"
  out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"; st=$?
  assert_status "a base run whose append fails exits 0" "$st" 0
  assert_eq "with a verdict from the fresh measurement" "$out" "off"
  assert_contains "warning on stderr, naming the record" "$(cat "$errf")" "orch: could not append to the suite-cost record $rec"
  assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1
  chmod 644 "$rec"
fi
