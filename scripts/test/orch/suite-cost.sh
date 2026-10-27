# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# The record's one documented line shape: the full HEAD SHA, suffixed -dirty
# when the tree had changes, CPU and wall seconds to two places, the UTC time
# in ISO 8601, and the command, its words joined by single spaces - five
# tab-separated fields.
SUITE_COST_LINE='^[0-9a-f]{40}(-dirty)?'$'\t''[0-9]+\.[0-9]{2}'$'\t''[0-9]+\.[0-9]{2}'$'\t''[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'$'\t'

# assert_record_line <label> <line>: asserts <line> is a record line in the
# documented shape, with exactly five tab-separated fields.
assert_record_line() {
  local shape=well-formed
  if [[ ! "$2" =~ $SUITE_COST_LINE ]]; then
    shape="malformed: $2"
  elif [[ "$(awk -F'\t' '{ print NF }' <<<"$2")" != 5 ]]; then
    shape="not five fields: $2"
  fi
  assert_eq "$1" "$shape" well-formed
}

# rec_path [made]: sets rec to the record's path in the cwd's clone, resolved
# with pwd -P as suite-cost resolves it; with made, also creates the record's
# directory.
rec_path() {
  rec="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)/orchestrator/suite-cost"
  [[ "${1:-}" != made ]] || mkdir -p "${rec%/*}"
}

# check_repo: a repo for suite-cost check, cwd inside it, its record's
# directory made: main's first commit (root) and its child (base), then branch
# feat off base, base recorded as its base SHA, with two commits (parent, then
# head, checked out). Sets root, base, parent, head, rec and the marker path a
# check's command leaves (marker), with cmd the words of that command - which
# marks that it ran and exits 9, so a check reaching confirmation is
# unmeasured - and cmd_str its record field, and pass the words of a passing
# command that leaves the same marker.
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
  rec_path made
  marker="$(mktemp -d)/ran"
  cmd=(sh -c 'touch "$0"; exit 9' "$marker")
  cmd_str="${cmd[*]}"
  pass=(touch "$marker")
}

# seed_run <sha> <cpu> [command]: appends a record line for a passing run at
# <sha> costing <cpu> CPU seconds, of <command> (default: cmd_str).
seed_run() {
  printf '%s\t%s\t1.00\t2026-10-01T10:00:00Z\t%s\n' "$1" "$2" "${3:-$cmd_str}" >>"$rec"
}

# handshake_fifos: makes a temp directory holding two FIFOs, one and two, for
# a FIFO handshake that makes two suite-cost runs certain to overlap, and
# prints its path.
handshake_fifos() {
  local dir
  dir="$(mktemp -d)" && mkfifo "$dir/one" "$dir/two" && printf '%s\n' "$dir"
}

# handshake_first <dir>: prints the handshake's first side as a shell script
# line - it writes to <dir>/one, blocking until the second side reads it, then
# reads <dir>/two, which the second side writes - for sh -c or a run.sh body.
handshake_first() {
  printf 'printf x >%s/one; read -r _ <%s/two\n' "$1" "$1"
}

# handshake_partner <dir>: a suite-cost run whose command is the handshake's
# second side - it reads <dir>/one, which the other side writes, then writes a
# line to <dir>/two, which the other side reads - so it is running while the
# other side's run is. Its output goes wherever the caller sends it.
handshake_partner() {
  "$ORCH" suite-cost run -- sh -c 'read -r _ <"$0"; printf "x\n" >"$1"' "$1/one" "$1/two"
}

# --- suite-cost run -----------------------------------------------------------
# Runs a verification command with its output and exit code passed through, and
# records a passing run's suite cost in the clone-wide record.
echo
echo "suite-cost run"
new_repo >/dev/null
rec_path

assert_eq "a fresh clone has no record directory" "$(on_disk "${rec%/*}")" absent
errf="$(mktemp)"
out="$("$ORCH" suite-cost run -- sh -c 'echo to-out; echo to-err >&2' 2>"$errf")"; st=$?
assert_status "a passing command's exit 0 passes through" "$st" 0
assert_eq "its stdout passes through, with nothing added" "$out" "to-out"
assert_eq "its stderr passes through, with nothing added" "$(cat "$errf")" "to-err"
assert_eq "the missing record directory is created" "$(on_disk "$rec")" present
assert_eq "a passing run appends exactly one line" "$(wc -l <"$rec" | tr -d ' ')" 1
line="$(tail -n 1 "$rec")"
assert_record_line "the line has the documented shape, in exactly five fields" "$line"
assert_eq "its first field is HEAD's full SHA" "$(cut -f1 <<<"$line")" "$(git rev-parse HEAD)"
assert_eq "its fifth field is the command, its words joined by single spaces" \
  "$(cut -f5 <<<"$line")" "sh -c echo to-out; echo to-err >&2"

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
rec_path
mkdir -p "$rec"
out="$("$ORCH" suite-cost run -- echo passed 2>/dev/null)"; st=$?
assert_status "an unwritable record still passes the command's exit 0 through" "$st" 0
assert_eq "and its stdout" "$out" "passed"
err="$("$ORCH" suite-cost run -- true 2>&1 >/dev/null)"
assert_contains "it warns on stderr with an orch: message" "$err" "orch: "
assert_contains "naming the record" "$err" "$rec"
assert_eq "and records nothing" "$(ls -A "$rec")" ""

# A run with changes in the tree records its commit as <sha>-dirty; an
# ignored path is no change.
new_repo >/dev/null
rec_path
echo ignored >>.git/info/exclude
touch ignored
"$ORCH" suite-cost run -- true >/dev/null 2>&1
assert_eq "a run with only an ignored path in the tree records the bare SHA" \
  "$(tail -n 1 "$rec" | cut -f1)" "$(git rev-parse HEAD)"
echo changed >>README.md
"$ORCH" suite-cost run -- true >/dev/null 2>&1
line="$(tail -n 1 "$rec")"
assert_eq "a run with a tracked change records <sha>-dirty" \
  "$(cut -f1 <<<"$line")" "$(git rev-parse HEAD)-dirty"
assert_record_line "in the documented shape, still five fields" "$line"
git checkout -q -- README.md
touch untracked
"$ORCH" suite-cost run -- true >/dev/null 2>&1
assert_eq "a run with an untracked file records <sha>-dirty" \
  "$(tail -n 1 "$rec" | cut -f1)" "$(git rev-parse HEAD)-dirty"

# Solo recording: a run another suite-cost run overlapped is left out of the
# record. Two runs are made certain to overlap by a FIFO handshake, no sleep:
# the first's command opens one FIFO for writing and blocks until the second's
# opens it for reading, then reads a second FIFO the other writes - so each
# command is running, and its run registered, while the other's is.
overlap="this run overlapped another suite-cost run - its suite cost is not recorded"
new_repo >/dev/null
rec_path
hs="$(handshake_fifos)"
"$ORCH" suite-cost run -- sh -c "$(handshake_first "$hs"); exit 4" >/dev/null 2>"$hs/err-a" &
pid_a=$!
handshake_partner "$hs" >/dev/null 2>"$hs/err-b"; st_b=$?
wait "$pid_a"; st_a=$?
assert_status "the first of two overlapping runs passes its exit code through" "$st_a" 4
assert_status "and so does the second" "$st_b" 0
assert_contains "the first warns it overlapped another run" "$(cat "$hs/err-a")" "orch: $overlap"
assert_contains "and so does the second" "$(cat "$hs/err-b")" "orch: $overlap"
assert_eq "neither is recorded" "$("$ORCH" suite-cost history)" ""

# While both are registered, exactly one .contended file exists: the one the
# later run made for the earlier, whichever registered first. A run does not
# mark itself.
"$ORCH" suite-cost run -- sh -c "$(handshake_first "$hs")" >/dev/null 2>&1 &
pid_a=$!
"$ORCH" suite-cost run -- sh -c 'read -r _ <"$0"; ls "$2" >"$3"; printf "x\n" >"$1"' \
  "$hs/one" "$hs/two" "$rec.active" "$hs/listing" >/dev/null 2>&1
wait "$pid_a"
assert_eq "two overlapping runs leave exactly one .contended file between them" \
  "$(grep -c '\.contended$' "$hs/listing")" 1
marked="$(grep '\.contended$' "$hs/listing")"
assert_eq "and it marks a run whose marker is listed beside it" \
  "$(grep -cx "${marked%.contended}" "$hs/listing")" 1

git branch other
git worktree add -q "$PWD/wt" other
"$ORCH" suite-cost run -- sh -c "$(handshake_first "$hs")" >/dev/null 2>"$hs/err-a" &
pid_a=$!
(cd wt && handshake_partner "$hs" >/dev/null 2>"$hs/err-b"); st_b=$?
wait "$pid_a"; st_a=$?
assert_status "a run overlapping one in a linked worktree passes its exit code through" "$st_a" 0
assert_status "and so does the linked worktree's run" "$st_b" 0
assert_contains "the main checkout's run warns it overlapped" "$(cat "$hs/err-a")" "orch: $overlap"
assert_contains "and so does the linked worktree's" "$(cat "$hs/err-b")" "orch: $overlap"
assert_eq "neither is recorded, wherever it started" "$("$ORCH" suite-cost history)" ""

err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a solo run after them warns nothing" "$err" ""
line="$("$ORCH" suite-cost history)"
assert_record_line "and is recorded, in the unchanged five-field line" "$line"

# A stale marker or .contended file - its pid names no live process - is no
# contention, and the run that finds it removes it.
sh -c 'exit 0' &
dead=$!
wait "$dead"
active="$rec.active"
mkdir -p "$active"
: >"$active/$dead"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a stale marker seeded before a run is no contention" "$err" ""
assert_eq "the run is recorded" "$("$ORCH" suite-cost history | wc -l | tr -d ' ')" 2
assert_eq "and the stale marker is gone" "$(on_disk "$active/$dead")" absent
: >"$active/$dead.contended"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a stale .contended file with no marker is no contention" "$err" ""
assert_eq "the run is recorded" "$("$ORCH" suite-cost history | wc -l | tr -d ' ')" 3
assert_eq "and the stale .contended file is gone" "$(on_disk "$active/$dead.contended")" absent
# A .contended file whose pid is live but whose marker was removed meanwhile -
# the test shell's own pid, which has no marker - is stale in the same way.
: >"$active/$$.contended"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a live pid's .contended file with no marker is no contention" "$err" ""
assert_eq "the run is recorded" "$("$ORCH" suite-cost history | wc -l | tr -d ' ')" 4
assert_eq "and that .contended file is gone" "$(on_disk "$active/$$.contended")" absent
# A live run already marked contended - the test shell's own pid, its marker
# and .contended file seeded - is contention, and only its marker is marked:
# its .contended file is never taken for a marker of its own.
: >"$active/$$"
: >"$active/$$.contended"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_contains "a live run already marked contended is contention" "$err" "orch: $overlap"
assert_eq "and its .contended file gets no .contended file of its own" \
  "$(on_disk "$active/$$.contended.contended")" absent
rm -f -- "$active/$$" "$active/$$.contended"

# A run that cannot register as active: a plain file where the active-runs
# directory goes, the record itself still writable.
new_repo >/dev/null
rec_path made
: >"$rec.active"
errf="$(mktemp)"
out="$("$ORCH" suite-cost run -- sh -c 'echo ran; exit 0' 2>"$errf")"; st=$?
assert_status "a run that cannot register passes its exit code through" "$st" 0
assert_eq "and its stdout" "$out" "ran"
assert_contains "it warns it could not register" "$(cat "$errf")" \
  "orch: this run could not register as active - its suite cost is not recorded"
assert_eq "and is not recorded" "$("$ORCH" suite-cost history)" ""
rm -rf "$hs" "$errf"

out="$("$ORCH" suite-cost bogus 2>&1)"; st=$?
assert_status "suite-cost bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown suite-cost op"

# --- suite-cost history -------------------------------------------------------
# Prints the record's lines oldest first, in the documented line shape.
echo
echo "suite-cost history"
new_repo >/dev/null
out="$("$ORCH" suite-cost history 2>&1)"; st=$?
assert_status "history succeeds with no record" "$st" 0
assert_eq "and prints nothing" "$out" ""

rec_path made
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
flat="$(tr -s ' \n' ' ' <<<"$out")"
assert_contains "suite-cost run is in the usage text" "$out" "suite-cost run -- <cmd> [args...]"
assert_contains "suite-cost history is in the usage text" "$out" "suite-cost history"
assert_contains "the usage text says an overlapped run is not recorded" \
  "$flat" "A run another suite-cost run overlapped, in any checkout of the clone, is not recorded"
assert_contains "suite-cost check is in the usage text" "$out" "suite-cost check -- <cmd> [args...]"
assert_contains "check's usage text describes the lowest-sample comparison" "$out" \
  "lowest sample of <cmd> with the baseline's"
assert_contains "and the 15 percent default" "$out" "else 15 percent"
assert_contains "check's usage text says a growth is confirmed" "$flat" \
  "A growth is confirmed by measuring head and base once more"
assert_contains "the head being run only to confirm a growth" "$flat" \
  "the head is run only to confirm a growth"
assert_contains "check's usage text says a confirmed verdict is reused" "$flat" \
  "A verdict confirmed this way is stored (orchestrator/suite-cost.verdicts) and reused, printed with nothing run"
assert_not_contains "check's usage text names no ancestor baseline" "$flat" "the base commit or an ancestor"
assert_contains "check's usage text says a base commit with no record of its own is measured" "$flat" \
  "never an ancestor's record reused"
assert_contains "check's usage text says an overlapped base or confirming run is not recorded" \
  "$flat" "Such a base or confirming run is not recorded when another suite-cost run overlaps it, or when it could not register as active, and the verdict is then unmeasured"
assert_contains "the CLI conventions' noun table has a suite-cost row" \
  "$(grep '^| `suite-cost`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" \
  '`run`, `check`, `history`'

# --- suite-cost check ---------------------------------------------------------
# Compares the head's recorded suite cost with the baseline's and prints one
# verdict line. Records are seeded in the documented line shape, so no path
# burns real CPU, and the command marks that it ran and fails: a verdict
# decided from the record runs nothing, and a comparison past the threshold
# reaches confirmation, whose failing head confirming run is unmeasured.
echo
echo "suite-cost check"
check_repo
# verdict: check's stdout for the check_repo command, its stderr dropped.
verdict() { "$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null; }
unconfirmed="orch: the confirming run at $head exited 9 - the growth is unconfirmed"

out="$(verdict)"; st=$?
assert_status "check with no record exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "without running the command" "$(on_disk "$marker")" absent

seed_run "$base" 60.00
seed_run "$head" 70.00 "scripts/test/orch_test.sh"
before="$(cat "$rec")"
out="$(verdict)"; st=$?
assert_status "check with a baseline and a head record of another command exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "never running the command on the head" "$(on_disk "$marker")" absent
assert_eq "nor recording anything" "$(cat "$rec")" "$before"

seed_run "$parent" 70.00
seed_run "$base" 60.00
before="$(cat "$rec")"
errf="$(mktemp)"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"; st=$?
assert_status "growth past the threshold exits 0" "$st" 0
assert_eq "on one stdout line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 1
assert_eq "a head record on HEAD's parent counts, and the newer one on the base does not" \
  "$out" "unmeasured"
assert_contains "the growth reached confirmation, whose failing head run left it unconfirmed" \
  "$(cat "$errf")" "$unconfirmed"
assert_eq "nor is a failing confirming run recorded" "$(cat "$rec")" "$before"
rm -f "$marker"

seed_run "$head" 69.00
assert_eq "growth at the threshold is ok, the newest head record counting" "$(verdict)" "ok"
seed_run "$head" 50.00
assert_eq "a shrinking suite is ok" "$(verdict)" "ok"
assert_eq "an ok decided from the record runs nothing" "$(on_disk "$marker")" absent

: >"$rec"
seed_run "$base" 50.00
seed_run "$head" 100.00
assert_eq "a baseline below the floor is off" "$(verdict)" "off"
assert_eq "an off decided from the record runs nothing" "$(on_disk "$marker")" absent

: >"$rec"
seed_run "$base" 100.00
seed_run "$root" 60.00
seed_run "$base" 30.00 "scripts/test/orch_test.sh"
seed_run "$head" 70.00
assert_eq "the baseline is the base commit's own newest record of the same command, never an ancestor's" \
  "$(verdict)" "ok"
assert_eq "with no base run" "$(on_disk "$marker")" absent
rm -f "$marker"

# Lowest samples: of several records on the newest head record's commit, or
# on the newest baseline record's, the lowest decides, not the newest.
: >"$rec"
rm -f "$marker"
seed_run "$base" 100.00
seed_run "$head" 105.00
seed_run "$head" 130.00
assert_eq "the lowest head sample on the head's commit decides, not the newest" "$(verdict)" "ok"
: >"$rec"
seed_run "$base" 80.00
seed_run "$base" 100.00
seed_run "$head" 100.00
assert_eq "the lowest baseline sample on the baseline's commit decides, not the newest" \
  "$(verdict)" "unmeasured"
rm -f "$marker"
: >"$rec"
seed_run "$base" 100.00
seed_run "$head" 90.00 "scripts/test/orch_test.sh"
seed_run "$parent" 90.00
seed_run "$head" 130.00
assert_eq "only samples on the newest head record's commit, of its command, are pooled" \
  "$(verdict)" "unmeasured"
rm -f "$marker"
: >"$rec"
seed_run "$root" 70.00
seed_run "$base" 100.00
seed_run "$head" 100.00
assert_eq "only samples on the newest baseline record's commit are pooled" "$(verdict)" "ok"
: >"$rec"
seed_run "$base" 100.00
seed_run "$head-dirty" 100.00
seed_run "$head" 130.00
assert_eq "a -dirty sample of the head's SHA is not pooled with its clean ones" \
  "$(verdict)" "unmeasured"
rm -f "$marker"
: >"$rec"
seed_run "$base" 100.00
seed_run "$head" 100.00
seed_run "$head-dirty" 130.00
assert_eq "nor a clean sample with the -dirty ones" "$(verdict)" "unmeasured"
rm -f "$marker"

# The default threshold, 15%, with no override.
: >"$rec"
rm -f "$marker"
seed_run "$base" 100.00
seed_run "$head" 112.00
assert_eq "with no override, records 12% apart are ok" "$(verdict)" "ok"
assert_eq "running nothing" "$(on_disk "$marker")" absent
: >"$rec"
seed_run "$base" 100.00
seed_run "$head" 116.00
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "and records 16% apart reach confirmation, past the 15% default" "$out" "unmeasured"
assert_contains "where the failing head confirming run warns" "$(cat "$errf")" "$unconfirmed"

# Dirty records: one on the base, a run made before the ticket's first commit,
# is the head's; it is never the baseline, which stays the clean record.
: >"$rec"
rm -f "$marker"
seed_run "$base" 60.00
seed_run "$base-dirty" 70.00
assert_eq "a dirty record on the base counts as the head, the clean one the baseline" \
  "$(verdict)" "unmeasured"
rm -f "$marker"
: >"$rec"
seed_run "$base" 60.00
seed_run "$base-dirty" 30.00
seed_run "$head" 70.00
assert_eq "a dirty record on the base is never the baseline" "$(verdict)" "unmeasured"
rm -f "$marker"
seed_run "$head-dirty" 50.00
assert_eq "the newest head record, dirty, counts" "$(verdict)" "ok"

# The base commit: base-sha's recorded SHA, else its merge-base; state.base_sha
# inside a flow. Base costs 100, parent 60 and head 70: from base, the head is
# 70 against 100 (ok); from parent, 70 against 60 (past the threshold).
: >"$rec"
rm -f "$marker"
seed_run "$base" 100.00
seed_run "$parent" 60.00
seed_run "$head" 70.00
git config branch.feat.orchestrator-base-sha "$parent"
assert_eq "outside a flow, the base commit is the branch's recorded base SHA" \
  "$(verdict)" "unmeasured"
git config --unset branch.feat.orchestrator-base-sha
git branch -q localbase "$base"
git config branch.feat.orchestrator-base localbase
assert_eq "without one, the merge-base with its base branch" "$(verdict)" "ok"
mkdir -p .orchestrator && echo '{}' >.orchestrator/state.json
state_fixture phase review
state_fixture base_sha "$parent"
assert_eq "inside a flow, it is state.base_sha" "$(verdict)" "unmeasured"

# Floor and growth overrides. 60 to 70 is 17% growth on a 60 baseline.
check_repo
seed_run "$base" 60.00
seed_run "$head" 70.00
git config orchestrator.suiteCost.floor 61
assert_eq "a raised floor turns the check off" "$(verdict)" "off"
git config orchestrator.suiteCost.floor 0.5
git config orchestrator.suiteCost.growth 20
assert_eq "a raised growth threshold lets the growth pass" "$(verdict)" "ok"
git config orchestrator.suiteCost.growth 16.5
assert_eq "a decimal threshold is honoured" "$(verdict)" "unmeasured"
rm -f "$errf"

# An invalid override dies before anything runs: no head here would have
# meant a base run, so the marker and the record prove none started.
: >"$rec"
rm -f "$marker"
git config --unset orchestrator.suiteCost.floor || true
git config --unset orchestrator.suiteCost.growth || true
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

# --- suite-cost check base run ------------------------------------------------
# With no record on the base commit, check measures the base once, in a
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
assert_record_line "its record line has the documented shape" "$line"
assert_eq "recorded at the base commit" "$(cut -f1 <<<"$line")" "$base"
assert_eq "for the command" "$(cut -f5 <<<"$line")" "${noisy[*]}"
assert_eq "and the worktree is gone" "$(git worktree list | wc -l | tr -d ' ')" 1
rm -f "$marker"
"$ORCH" suite-cost check -- "${noisy[@]}" >/dev/null 2>&1
assert_eq "the next check uses that record, running nothing" "$(on_disk "$marker")" absent

# The baseline is the base commit's own records, never an ancestor's: an older
# ancestor's record is ignored and the base is measured by a base run.
check_repo
seed_run "$root" 100.00 "${pass[*]}"
seed_run "$head" 70.00 "${pass[*]}"
out="$("$ORCH" suite-cost check -- "${pass[@]}" 2>/dev/null)"
assert_eq "an ancestor's record is ignored: the base is measured and the verdict compares against it" "$out" "off"
assert_eq "by a base run of the command" "$(on_disk "$marker")" present
assert_eq "recorded at the base commit" "$(tail -n 1 "$rec" | cut -f1)" "$base"
rm -f "$marker"

check_repo
seed_run "$head" 70.00 "false"
before="$(cat "$rec")"
errf="$(mktemp)"
out="$("$ORCH" suite-cost check -- false 2>"$errf")"; st=$?
assert_status "a failing base run exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_contains "warning with its exit code" "$(cat "$errf")" \
  "orch: the base run at $base exited 1 - the suite cost is unmeasured"
assert_eq "recording nothing" "$(cat "$rec")" "$before"
assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1

if [ "$(id -u)" -ne 0 ]; then
  check_repo
  seed_run "$head" 70.00 "${pass[*]}"
  chmod 444 "$rec"
  out="$("$ORCH" suite-cost check -- "${pass[@]}" 2>"$errf")"; st=$?
  assert_status "a base run whose append fails exits 0" "$st" 0
  assert_eq "with a verdict from the fresh measurement" "$out" "off"
  assert_contains "warning on stderr, naming the record" "$(cat "$errf")" "orch: could not append to the suite-cost record $rec"
  assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1
  chmod 644 "$rec"
fi

# A per-clone setup, git config orchestrator.suiteCost.setup, runs in the base
# worktree before the timed run: here it writes the file the command needs.
check_repo
needy=(sh -c 'test -f dep && touch "$0"' "$marker")
seed_run "$head" 70.00 "${needy[*]}"
git config orchestrator.suiteCost.setup \
  "echo setup-out; echo setup-err >&2; awk 'BEGIN { for (i = 0; i < 3e7; i++); }'; touch dep"
out="$("$ORCH" suite-cost check -- "${needy[@]}" 2>"$errf")"; st=$?
assert_status "a base run with a setup exits 0" "$st" 0
assert_eq "with the verdict alone on stdout, measured" "$out" "off"
assert_eq "the command found what the setup provided" "$(on_disk "$marker")" present
line="$(tail -n 1 "$rec")"
assert_eq "the base is recorded" "$(cut -f1 <<<"$line")" "$base"
assert_eq "without the setup's CPU time" \
  "$(LC_ALL=C awk -v c="$(cut -f2 <<<"$line")" 'BEGIN { print (c < 0.25) ? "uncounted" : "counted " c }')" uncounted
assert_contains "the setup's stdout reaches stderr" "$(cat "$errf")" "setup-out"
assert_contains "and its stderr too" "$(cat "$errf")" "setup-err"
assert_eq "and the worktree is gone" "$(git worktree list | wc -l | tr -d ' ')" 1

check_repo
seed_run "$head" 70.00
git config orchestrator.suiteCost.setup "exit 3"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"; st=$?
assert_status "a failing setup exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_contains "warning with its command, the base and its exit code" "$(cat "$errf")" \
  "orch: the base run's setup (exit 3) at $base exited 3 - the suite cost is unmeasured"
assert_eq "running no measurement" "$(on_disk "$marker")" absent
assert_eq "recording nothing" "$(cat "$rec")" "$before"
assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1

# A base run exiting 127 with no setup names the setup key.
hint="orch: the base run at %s exited 127 (command not found) - the base worktree holds only tracked files; if the command needs installed dependencies, set git config orchestrator.suiteCost.setup '<install command>'"
today="orch: the base run at %s exited %s - the suite cost is unmeasured"
check_repo
seed_run "$head" 70.00 "orch-no-such-command"
"$ORCH" suite-cost check -- orch-no-such-command >/dev/null 2>"$errf"
# shellcheck disable=SC2059
assert_contains "with no setup key, a command not found gives the setup hint" \
  "$(cat "$errf")" "$(printf "$hint" "$base")"
git config orchestrator.suiteCost.setup ""
"$ORCH" suite-cost check -- orch-no-such-command >/dev/null 2>"$errf"
# shellcheck disable=SC2059
assert_contains "an empty setup key gives the same hint" \
  "$(cat "$errf")" "$(printf "$hint" "$base")"
git config orchestrator.suiteCost.setup true
"$ORCH" suite-cost check -- orch-no-such-command >/dev/null 2>"$errf"
# shellcheck disable=SC2059
assert_contains "with the key set, a 127 keeps today's warning" \
  "$(cat "$errf")" "$(printf "$today" "$base" 127)"
rm -f "$errf"

# A base run is a measured run too: one overlapped by a suite-cost run started
# alongside check - the FIFO handshake of the suite-cost run section, the
# FIFOs named by absolute path so the base worktree reaches them - is not
# recorded, and check is unmeasured.
check_repo
hs="$(handshake_fifos)"
waiter=(sh -c "$(handshake_first "$hs")")
seed_run "$head" 70.00 "${waiter[*]}"
before="$(cat "$rec")"
handshake_partner "$hs" >/dev/null 2>&1 &
pid_partner=$!
out="$("$ORCH" suite-cost check -- "${waiter[@]}" 2>"$hs/err")"; st=$?
wait "$pid_partner"
assert_status "an overlapped base run's check exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_contains "warning the base run overlapped another" "$(cat "$hs/err")" \
  "orch: the base run at $base overlapped another suite-cost run - the suite cost is unmeasured"
assert_eq "recording neither run" "$(cat "$rec")" "$before"
assert_eq "and leaving no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1
rm -rf "$hs"

# A base run that cannot register as active: a plain file where the
# active-runs directory goes.
check_repo
seed_run "$head" 70.00 "${pass[*]}"
before="$(cat "$rec")"
: >"$rec.active"
errf="$(mktemp)"
out="$("$ORCH" suite-cost check -- "${pass[@]}" 2>"$errf")"; st=$?
assert_status "a base run that cannot register exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_eq "though the command still ran" "$(on_disk "$marker")" present
assert_contains "warning it could not register" "$(cat "$errf")" \
  "orch: the base run at $base could not register as active - the suite cost is unmeasured"
assert_not_contains "never with an overlap warning" "$(cat "$errf")" "overlapped"
assert_eq "recording nothing" "$(cat "$rec")" "$before"
rm -f "$errf"

# --- suite-cost check confirmation --------------------------------------------
# A comparison past the threshold is confirmed before it is reported: check
# measures the head once in a temporary worktree at HEAD, then the base once
# at the baseline sample's commit, and compares again. The checked command is
# sh run.sh, a tracked script whose content each commit sets - a no-op, a
# failure, or a FIFO handshake - and the growth is seeded, the head at 100
# over a base at 50. The CPU seconds a confirming run reports come from the
# timer fake ORCH_SUITE_COST_TIMER names, keyed by the run's commit, so no
# verdict here depends on the machine's speed or load.
echo
echo "suite-cost check confirmation"
ORCH_SUITE_COST_FAKE_CPU="$(mktemp)"
export ORCH_SUITE_COST_TIMER="$TEST_DIR/suite_cost_timer_fake.sh" ORCH_SUITE_COST_FAKE_CPU

# fake_cpu <sha> <cpu>: the timer fake reports <cpu> CPU seconds for a run on
# <sha> from now on.
fake_cpu() { printf '%s %s\n' "$1" "$2" >>"$ORCH_SUITE_COST_FAKE_CPU"; }

# confirm_repo <base script> <head script>: a repo, cwd inside it, whose base
# commit tracks run.sh holding <base script> and whose head commit, on branch
# feat recorded with base as its base SHA, holds <head script>; a low floor,
# a growth seeded for sh run.sh, head 100.00 over base 50.00, and the timer
# fake reporting 50.00 for a run on either commit until fake_cpu says
# otherwise (see confirm_reset). Sets base, head, rec, vf (its stored-verdict
# record), cmd and cmd_str.
confirm_repo() {
  new_repo >/dev/null
  printf '%s\n' "$1" >run.sh
  git add run.sh
  git commit -q -m base
  base="$(git rev-parse HEAD)"
  git checkout -q -b feat
  git config branch.feat.orchestrator-base-sha "$base"
  printf '%s\n' "$2" >run.sh
  git add run.sh
  git commit -q --allow-empty -m head
  head="$(git rev-parse HEAD)"
  rec_path made
  vf="$rec.verdicts"
  cmd=(sh run.sh)
  cmd_str="sh run.sh"
  confirm_reset
}
# confirm_reset: puts confirm_repo's repo back to its built state, for a case
# that changed only the record, the stored verdicts, the .active file, the
# timer fake's CPU file or the suiteCost config keys: the record holds its two
# seeded lines, the stored-verdict record (a file or a directory) and .active
# are gone, the timer fake reports 50.00 for either commit, the floor is 0.01
# and growth and setup are unset.
confirm_reset() {
  : >"$rec"
  seed_run "$base" 50.00
  seed_run "$head" 100.00
  rm -rf "$rec.verdicts" "$rec.active"
  : >"$ORCH_SUITE_COST_FAKE_CPU"
  fake_cpu "$base" 50.00
  fake_cpu "$head" 50.00
  git config orchestrator.suiteCost.floor 0.01
  git config --unset orchestrator.suiteCost.growth || true
  git config --unset orchestrator.suiteCost.setup || true
}
# recorded <sha>: the CPU seconds of the newest record line at <sha> past the
# seeded ones, or nothing.
recorded() { awk -F'\t' -v s="$1" '$1 == s && NR > 2 { c = $2 } END { print c }' "$rec"; }
errf="$(mktemp)"
unconfirmed_tail="the growth is unconfirmed"

confirm_repo ":" ":"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"; st=$?
assert_status "a confirmed check exits 0" "$st" 0
assert_eq "a seeded growth the confirming runs, at 50 each, do not bear out is ok" "$out" "ok"
assert_eq "both passing solo confirming runs are recorded, head then base" \
  "$(awk -F'\t' 'NR > 2 { print $1 }' "$rec" | tr '\n' ' ')" "$head $base "
assert_eq "and their worktrees are gone" "$(git worktree list | wc -l | tr -d ' ')" 1

confirm_reset
fake_cpu "$head" 90.00
fake_cpu "$base" 60.00
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_contains "a growth that survives confirmation grew" "$out" "grew 80 - "
assert_contains "its finding text names the lowest head value, the confirming run's 90" "$out" \
  "90.00 CPU seconds at the head"
assert_contains "and the lowest baseline value, the seeded 50, at the baseline commit" "$out" \
  "against 50.00 at baseline commit $base"
assert_contains "and the default threshold" "$out" "past the 15% threshold"

confirm_reset
: >"$rec"
seed_run "$base" 30.00
seed_run "$head-dirty" 50.00
fake_cpu "$head" 90.00
fake_cpu "$base" 30.00
git config orchestrator.suiteCost.growth 16.5
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_contains "a dirty head sample's growth that survives grew" "$out" "grew 200 - "
assert_contains "the head side is the head confirming run alone, the dirty sample not pooled" \
  "$out" "90.00 CPU seconds at the head"
assert_not_contains "never the dirty sample's value" "$out" "50.00 CPU seconds"
assert_contains "a decimal threshold is named" "$out" "past the 16.5% threshold"

confirm_reset
git config orchestrator.suiteCost.floor 0.5
fake_cpu "$base" 0.05
assert_eq "a base confirming run landing below the floor, at 0.05, is off" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "off"

confirm_reset
git config orchestrator.suiteCost.setup "exit 3"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a failing confirming setup is unmeasured" "$out" "unmeasured"
assert_contains "warning with the setup, the head and its exit code" "$(cat "$errf")" \
  "orch: the confirming run's setup (exit 3) at $head exited 3 - $unconfirmed_tail"
assert_eq "recording nothing" "$(cat "$rec")" "$before"

if [ "$(id -u)" -ne 0 ]; then
  confirm_reset
  wts="$(git rev-parse --git-common-dir)/worktrees"
  mkdir -p "$wts"
  chmod 555 "$wts"
  out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
  chmod 755 "$wts"
  assert_eq "a confirming worktree that cannot be added is unmeasured" "$out" "unmeasured"
  assert_contains "warning it could not add the worktree" "$(cat "$errf")" \
    "orch: could not add a worktree for the confirming run at $head - $unconfirmed_tail"
fi

confirm_reset
: >"$rec.active"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a confirming run that cannot register is unmeasured" "$out" "unmeasured"
assert_contains "warning it could not register" "$(cat "$errf")" \
  "orch: the confirming run at $head could not register as active - $unconfirmed_tail"
assert_not_contains "never with an overlap warning" "$(cat "$errf")" "overlapped"

confirm_reset
: >"$rec"
seed_run "$base" 50.00
seed_run "$head" 52.00
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "an ok reached without confirmation stores nothing" "$(on_disk "$vf")" absent

# Setup runs first in both confirming worktrees: each commit's script needs
# the file it writes.
confirm_repo "test -f dep" "test -f dep"
git config orchestrator.suiteCost.setup "touch dep"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>"$errf"
assert_eq "with a setup, the head confirming run found what it provided, and is recorded" \
  "$("$ORCH" suite-cost history | grep -c "^$head")" 2
assert_eq "and so is the base confirming run" "$("$ORCH" suite-cost history | grep -c "^$base")" 2

# Failing confirming runs: the head's stops confirmation before the base's.
marker="$(mktemp -d)/base-ran"
confirm_repo "touch $marker" "exit 5"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a failing head confirming run is unmeasured" "$out" "unmeasured"
assert_contains "warning with its exit code" "$(cat "$errf")" \
  "orch: the confirming run at $head exited 5 - $unconfirmed_tail"
assert_eq "the base confirming run does not run" "$(on_disk "$marker")" absent
assert_eq "and nothing is recorded" "$(cat "$rec")" "$before"

confirm_repo "exit 6" ":"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a failing base confirming run is unmeasured" "$out" "unmeasured"
assert_contains "warning with its exit code" "$(cat "$errf")" \
  "orch: the confirming run at $base exited 6 - $unconfirmed_tail"
assert_eq "the passing solo head confirming run before it is recorded" "$(recorded "$head")" \
  "$(awk -F'\t' 'NR == 3 { print $2 }' "$rec")"
assert_eq "the failing base run is not" "$(recorded "$base")" ""

confirm_reset
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a confirmation ending unmeasured writes no line" "$(on_disk "$vf")" absent

# Overlapped confirming runs, by the FIFO handshake of the suite-cost run
# section. The head's: a suite-cost run started alongside check reads a FIFO
# the head's script writes, and writes one it reads.
overlap_tail="overlapped another suite-cost run - the growth is unconfirmed"
hs="$(handshake_fifos)"
marker="$hs/base-ran"
confirm_repo "touch $marker" "$(handshake_first "$hs")"
before="$(cat "$rec")"
handshake_partner "$hs" >/dev/null 2>&1 &
pid_partner=$!
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
wait "$pid_partner"
assert_eq "an overlapped head confirming run is unmeasured" "$out" "unmeasured"
assert_contains "warning of the contention at the head" "$(cat "$errf")" \
  "orch: the confirming run at $head $overlap_tail"
assert_eq "the base confirming run does not run" "$(on_disk "$marker")" absent
assert_eq "and nothing is recorded" "$(cat "$rec")" "$before"

# The base's, after a solo head confirming run: the base's script signals on
# one FIFO that it is running and waits on another, and only then does a
# suite-cost run start, its command writing the second.
confirm_repo "$(handshake_first "$hs")" ":"
"$ORCH" suite-cost check -- "${cmd[@]}" >"$hs/out" 2>"$errf" &
pid_c=$!
read -r _ <"$hs/one"
"$ORCH" suite-cost run -- sh -c 'printf "x\n" >"$0"' "$hs/two" >/dev/null 2>&1
wait "$pid_c"
assert_eq "an overlapped base confirming run is unmeasured" "$(cat "$hs/out")" "unmeasured"
assert_contains "warning of the contention at the base" "$(cat "$errf")" \
  "orch: the confirming run at $base $overlap_tail"
assert_eq "the solo head confirming run before it is recorded" "$(grep -c "^$head" "$rec")" 2
assert_eq "the overlapped base run is not" "$(grep -c "^$base" "$rec")" 1
assert_eq "and no worktree is left" "$(git worktree list | wc -l | tr -d ' ')" 1
# Verdict reuse: a verdict check confirmed is stored in suite-cost.verdicts and
# printed again, nothing run, while the clean HEAD, base commit, command and
# knobs are unchanged. A command that appends to a counter file counts runs.
cnt="$(mktemp)"
runs() { wc -l <"$cnt" | tr -d ' '; }
grown_reset() {
  confirm_reset
  fake_cpu "$head" 90.00
  fake_cpu "$base" 60.00
}
grown_repo() {
  confirm_repo "echo b >>$cnt" "echo h >>$cnt"
  grown_reset
}

grown_repo
first="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_contains "a confirmed growth grew" "$first" "grew 80 - "
assert_eq "its two confirming runs ran" "$(runs)" 2
assert_eq "one verdict line is written" "$(wc -l <"$vf" | tr -d ' ')" 1
assert_eq "in the documented format: head, base, floor, growth, time, command, verdict" \
  "$(awk -F'\t' -v h="$head" -v b="$base" -v v="$first" \
    '$1 == h && $2 == b && $3 == "0.01" && $4 == 15 && $5 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ && $6 == "sh run.sh" && $7 == v { print "ok" }' "$vf")" "ok"
second="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a second check on the unchanged clean HEAD prints the same verdict" "$second" "$first"
assert_eq "and runs the command no more" "$(runs)" 2
out="$("$ORCH" suite-cost check -- sh -c "sh run.sh" 2>/dev/null)"
assert_eq "a different command does not reuse it" "$out" "unmeasured"

printf 'x\n' >untracked
before_runs="$(runs)"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a dirty tree does not reuse the verdict" "$(runs)" "$((before_runs + 2))"
assert_eq "and writes no line" "$(wc -l <"$vf" | tr -d ' ')" 1
rm -f untracked

bs_cmd=(sh run.sh 'a\.b')
seed_run "$head" 100.00 "${bs_cmd[*]}"
seed_run "$base" 50.00 "${bs_cmd[*]}"
before_runs="$(runs)"
out="$("$ORCH" suite-cost check -- "${bs_cmd[@]}" 2>/dev/null)"
assert_contains "a command with a backslash compares its own records" "$out" "grew 80 - "
assert_eq "and confirms once" "$(runs)" "$((before_runs + 2))"
"$ORCH" suite-cost check -- "${bs_cmd[@]}" >/dev/null 2>&1
assert_eq "its confirmed verdict is reused, the backslash matched as written" "$(runs)" "$((before_runs + 2))"

git config orchestrator.suiteCost.growth 20
before_runs="$(runs)"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a changed growth knob does not reuse it" "$(runs)" "$((before_runs + 2))"
git config orchestrator.suiteCost.growth 15
git config orchestrator.suiteCost.floor 0.02
before_runs="$(runs)"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a changed floor knob does not reuse it" "$(runs)" "$((before_runs + 2))"
git config orchestrator.suiteCost.floor 0.01

before_runs="$(runs)"
git commit -q --allow-empty -m next
nhead="$(git rev-parse HEAD)"
fake_cpu "$nhead" 90.00
seed_run "$nhead" 100.00
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a new commit does not reuse it" "$(runs)" "$((before_runs + 2))"

grown_repo
printf '%s\t%s\t0.01\t15\t2020-01-01T00:00:00Z\tsh run.sh\tok\n' "$head" "$(git rev-parse "$base~1")" >"$vf"
before_runs="$(runs)"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a verdict stored for a different base commit is not reused" "$(runs)" "$((before_runs + 2))"

# A confirmed ok is reused too.
confirm_reset
before_runs="$(runs)"
okv="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)"
assert_eq "a seeded growth the confirming runs do not bear out is ok" "$okv" "ok"
assert_eq "it ran the two confirming runs" "$(runs)" "$((before_runs + 2))"
"$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1
assert_eq "a confirmed ok is reused" "$(runs)" "$((before_runs + 2))"

# The newest of two matching lines wins.
grown_reset
printf '%s\t%s\t0.01\t15\t2020-01-01T00:00:00Z\tsh run.sh\tgrew 1 - old\n' "$head" "$base" >"$vf"
printf '%s\t%s\t0.01\t15\t2021-01-01T00:00:00Z\tsh run.sh\tok\n' "$head" "$base" >>"$vf"
before_runs="$(runs)"
assert_eq "with two matching lines the newest one's verdict is printed" \
  "$("$ORCH" suite-cost check -- "${cmd[@]}" 2>/dev/null)" "ok"
assert_eq "and nothing ran" "$(runs)" "$before_runs"

# An unwritable verdict record warns and the verdict still prints.
grown_reset
mkdir -p "$vf"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_contains "the verdict still prints" "$out" "grew 80 - "
assert_contains "after an orch: warning" "$(cat "$errf")" "orch: could not append to the suite-cost verdict record"
rm -rf "$vf" "$cnt"

rm -rf "$hs" "$errf"
rm -f "$ORCH_SUITE_COST_FAKE_CPU"
restore_suite_env ORCH_SUITE_COST_TIMER ORCH_SUITE_COST_FAKE_CPU
