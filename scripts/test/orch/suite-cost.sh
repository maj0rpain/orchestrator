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

# sub_check: the check from pkg/ with cmd, stderr to errf.
sub_check() { (cd pkg && "$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf"); }

# no_worktree: none when the repo has only its own worktree, else left.
no_worktree() { [ "$(git worktree list | wc -l | tr -d ' ')" -eq 1 ] && echo none || echo left; }

# branch_off_base: commits what is staged or untracked as the base commit, sets
# base to it, and starts branch feat off it recorded as its base SHA.
branch_off_base() {
  git add -A
  git commit -q --allow-empty -m base
  base="$(git rev-parse HEAD)"
  git checkout -q -b feat
  git config branch.feat.orchestrator-base-sha "$base"
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

# handshake_first <dir> [seconds]: prints the handshake's first side as a shell
# script line - it writes to <dir>/one, blocking until the second side reads it,
# then reads <dir>/two, which the second side writes - for sh -c or a run.sh
# body. The two FIFO operations run under timeout [seconds] (default 60); on
# expiry the line prints "first side (<dir>/one, <dir>/two): no partner within
# <seconds>s" on stderr and ends with status 124.
handshake_first() {
  printf '%q ' "${FIFO_BOUNDED[@]}" "${2:-60}" "first side ($1/one, $1/two)" \
    sh -c 'printf x >"$0"; read -r _ <"$1"' "$1/one" "$1/two"
  printf '\n'
}

# FIFO_BOUNDED: the prefix that runs the one fifo_bounded (fifo.sh) as a
# command: <seconds> <side> <command...> follow it.
FIFO_BOUNDED=(bash -c '. "$0"; fifo_bounded "$@"' "$TEST_DIR/fifo.sh")

# replay_on_expiry <status> <errfile>: when <status> is 124, timeout's expiry
# status (the one fifo_bounded signals), copies <errfile> verbatim to stderr;
# any other status prints nothing. Always returns 0.
replay_on_expiry() {
  [ "$1" -ne 124 ] || cat "$2" >&2
  return 0
}

# bounded_run_replayed <errfile> <seconds> <side> <cmd...>: runs <cmd...> as one
# bounded handshake side under suite-cost run (FIFO_BOUNDED, <seconds>, <side>),
# stdout to /dev/null and stderr to <errfile>, then replays <errfile> to stderr
# on timeout's expiry status (replay_on_expiry). Returns the run's own status,
# not the replay's 0.
bounded_run_replayed() {
  local errfile="$1" seconds="$2" side="$3" st
  shift 3
  "$ORCH" suite-cost run -- "${FIFO_BOUNDED[@]}" "$seconds" "$side" "$@" >/dev/null 2>"$errfile"; st=$?
  replay_on_expiry "$st" "$errfile"
  return "$st"
}

# handshake_partner <dir> [seconds]: a suite-cost run whose command is the
# handshake's second side - it reads <dir>/one, which the other side writes,
# then writes a line to <dir>/two, which the other side reads - so it is running
# while the other side's run is. Its output goes wherever the caller sends it.
# The FIFO operations run under timeout [seconds] (default 60); on expiry it
# prints "partner (<dir>/one, <dir>/two): no partner within <seconds>s" on
# stderr and exits 124.
handshake_partner() {
  "$ORCH" suite-cost run -- "${FIFO_BOUNDED[@]}" "${2:-60}" "partner ($1/one, $1/two)" \
    sh -c 'read -r _ <"$0"; printf "x\n" >"$1"' "$1/one" "$1/two"
}

# handshake_overlap_check <dir> <cmd> [args...]: runs suite-cost check on the
# command in the background - its stdout to <dir>/out, its stderr to
# <dir>/err - and, once the measured run's command has written <dir>/one (its
# handshake_first side), starts a suite-cost run whose command writes
# <dir>/two, so that run begins while check's run is under way: the overlap
# check's own end-of-run detection catches, which its pre-check cannot see
# coming. Waits for check, setting st to its exit status.
handshake_overlap_check() {
  local dir="$1" pid
  shift
  "$ORCH" suite-cost check -- "$@" >"$dir/out" 2>"$dir/err" &
  pid=$!
  fifo_read_line 60 "overlap check ($dir/one)" "$dir/one" >/dev/null
  bounded_run_replayed "$dir/err-writer" 60 "overlap check ($dir/two)" sh -c 'printf "x\n" >"$0"' "$dir/two"
  wait "$pid"; st=$?
}

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
assert_eq "a passing run appends exactly one line" "$(log_count "$rec")" 1
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
assert_eq "beside the main checkout's run" "$(log_count "$rec")" 2

for args in "" "true" "-- " "true --"; do
  # shellcheck disable=SC2086 # the words are the case
  out="$("$ORCH" suite-cost run $args 2>&1)"; st=$?
  assert_status "run with '${args}' is a usage error" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost run -- <cmd> [args...]"
done
assert_eq "a usage error records nothing" "$(log_count "$rec")" 2

# One argument is a shell line, run with bash -c and recorded as given.
new_repo >/dev/null
rec_path
rm -f "$rec"
sm="$(mktemp -d)/second"
line="true && touch $sm"
"$ORCH" suite-cost run -- "$line" >/dev/null 2>&1; st=$?
assert_status "a one-argument chained line exits 0" "$st" 0
assert_eq "its second half ran" "$(on_disk "$sm")" present
assert_eq "one record line is appended" "$(log_count "$rec")" 1
assert_eq "its command field is the argument as given" "$(tail -n 1 "$rec" | cut -f5)" "$line"
out="$("$ORCH" suite-cost run -- 'true && exit 3' 2>&1)"; st=$?
assert_status "a failing second half passes its exit code through" "$st" 3
assert_eq "and records nothing" "$(log_count "$rec")" 1
n_two="$(log_count "$rec")"
"$ORCH" suite-cost run -- 'echo a b' >/dev/null 2>&1
"$ORCH" suite-cost run -- echo a b >/dev/null 2>&1
assert_eq "both runs append a record line" "$(log_count "$rec")" "$((n_two + 2))"
assert_eq "one quoted argument records what the same words as several do" \
  "$(tail -n 2 "$rec" | cut -f5 | sort -u | wc -l | tr -d ' ')" 1
out="$("$ORCH" suite-cost run -- printf '%s\n' '&&' 2>&1)"
assert_eq "a several-argument run passes a literal && word to the program" "$out" "&&"
n_before="$(log_count "$rec")"
for blank in "" " " $'\t '; do
  for op in run check; do
    out="$("$ORCH" suite-cost "$op" -- "$blank" 2>&1)"; st=$?
    assert_status "$op with a blank single argument is a usage error" "$st" 1
    assert_contains "with its usage line" "$out" "usage: orch.sh suite-cost $op -- <cmd> [args...]"
    assert_contains "and its usage line names the one-argument form" "$out" "suite-cost $op -- '<shell line>'"
  done
done
assert_eq "and records nothing" "$(log_count "$rec")" "$n_before"

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

# While both are registered, each .contended file marks the other run - a run
# does not mark itself. The later run to scan marks the earlier; when both
# write their markers before either scans, each marks the other, so there are
# one or two.
"$ORCH" suite-cost run -- sh -c "$(handshake_first "$hs")" >/dev/null 2>"$hs/err-first" &
pid_a=$!
bounded_run_replayed "$hs/err-listing" 60 "listing partner ($hs/one, $hs/two)" \
  sh -c 'read -r _ <"$0"; ls "$2" >"$3"; printf "x\n" >"$1"' \
  "$hs/one" "$hs/two" "$rec.active" "$hs/listing"
wait "$pid_a"
replay_on_expiry "$?" "$hs/err-first"
n="$(grep -c '\.contended$' "$hs/listing")"
assert_eq "two overlapping runs leave one or two .contended files between them" \
  "$(case "$n" in 1|2) echo "one or two" ;; *) echo "$n" ;; esac)" "one or two"
unmarked=""
while IFS= read -r marked; do
  grep -qx "${marked%.contended}" "$hs/listing" || unmarked="$unmarked $marked"
done < <(grep '\.contended$' "$hs/listing")
assert_eq "and each marks a run whose marker is listed beside it" "$unmarked" ""

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
sourced_orch liveness_record_write "$$" "$active/$$"
: >"$active/$$.contended"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_contains "a live run already marked contended is contention" "$err" "orch: $overlap"
assert_eq "and its .contended file gets no .contended file of its own" \
  "$(on_disk "$active/$$.contended.contended")" absent
rm -f -- "$active/$$" "$active/$$.contended"

# A marker is the Liveness module's record, judged by its record-alive rule: a
# live pid with another start time is stale, its true start time is contention.
new_repo >/dev/null
rec_path
active="$rec.active"
mkdir -p "$active"
printf '%s 1\n' "$$" >"$active/$$"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a marker under a live pid with another start time is no contention" "$err" ""
assert_eq "the run is recorded" "$("$ORCH" suite-cost history | wc -l | tr -d ' ')" 1
assert_eq "and that marker is gone" "$(on_disk "$active/$$")" absent
sourced_orch liveness_record_write "$$" "$active/$$"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_contains "a marker with its true start time is contention" "$err" "orch: $overlap"
rm -f -- "$active/$$"

# Other stale markers: empty, malformed, unreadable start time, another pid's
# record. A contended mark beside one goes with it.
fake_proc="$(mktemp -d)"
for kind in empty malformed unreadable otherpid; do
  mkdir -p "$active"
  case "$kind" in
    empty) : >"$active/$$" ;;
    malformed) printf 'word\n' >"$active/$$" ;;
    unreadable) sourced_orch liveness_record_write "$$" "$active/$$" ;;
    otherpid)
      # a true record of a live pid that is not the marker's file name
      sleep 30 &
      other_pid=$!
      sourced_orch liveness_record_write "$other_pid" "$active/$$"
      ;;
  esac
  : >"$active/$$.contended"
  if [ "$kind" = unreadable ]; then
    # a fake process table that knows the run (exec keeps its pid) but not
    # the marker's pid, here the test shell's
    err="$(ORCH_PROC_DIR="$fake_proc" bash -c 'mkdir "$ORCH_PROC_DIR/$$"; cp "/proc/$$/stat" "$ORCH_PROC_DIR/$$/stat"; ps() { return 1; }; export -f ps; exec "$0" suite-cost run -- true' "$ORCH" 2>&1)"
  else
    err="$("$ORCH" suite-cost run -- true 2>&1)"
  fi
  assert_eq "a $kind marker is stale and no contention" "$err" ""
  assert_eq "and is removed with its contended mark" \
    "$(on_disk "$active/$$")$(on_disk "$active/$$.contended")" absentabsent
  if [ "$kind" = otherpid ]; then
    kill "$other_pid" 2>/dev/null || true
    wait "$other_pid" 2>/dev/null || true
  fi
done
rm -rf "$fake_proc"

# A file under a marker's first name is neither removed nor counted.
: >"$active/.$dead.new"
before_first="$(log_count "$rec")"
err="$("$ORCH" suite-cost run -- true 2>&1)"
assert_eq "a file under a marker's first name is no contention" "$err" ""
assert_eq "and the run is recorded" "$(( $(log_count "$rec") - before_first ))" 1
assert_eq "and is left alone" "$(on_disk "$active/.$dead.new")" present
rm -f -- "$active/.$dead.new"

# A marker in progress holds its record while two runs overlap.
hs="$(handshake_fifos)"
"$ORCH" suite-cost run -- sh -c "$(handshake_first "$hs")" >/dev/null 2>"$hs/err-first" &
pid_a=$!
bounded_run_replayed "$hs/err-listing" 60 "record partner ($hs/one, $hs/two)" \
  sh -c 'read -r _ <"$0"; for m in "$2"/[0-9]*; do case "$m" in *.contended) ;; *) cat "$m" ;; esac; done >"$3"; printf "x\n" >"$1"' \
  "$hs/one" "$hs/two" "$active" "$hs/listing"
wait "$pid_a"
replay_on_expiry "$?" "$hs/err-first"
unrecorded="$(grep -vcE '^[0-9]+ [^ ]+$' "$hs/listing")"
assert_eq "each marker read while two runs overlap holds its record" \
  "$unrecorded:$(wc -l <"$hs/listing" | tr -d ' ')" "0:2"
rm -rf "$hs"

# A start time unreadable at registration: no registration, the record
# writer's line then the could-not-register line.
new_repo >/dev/null
rec_path made
fake_proc="$(mktemp -d)"
fake_bin="$(fails_bin ps '*')"
errf="$(mktemp)"
out="$(PATH="$fake_bin:$PATH" ORCH_PROC_DIR="$fake_proc" "$ORCH" suite-cost run -- sh -c 'echo $PPID; exit 3' 2>"$errf")"; st=$?
assert_status "a run whose start time is unreadable passes its exit code through" "$st" 3
assert_eq "and records nothing" "$("$ORCH" suite-cost history)" ""
assert_eq "stderr names the orch.sh pid first" "$(sed -n 1p "$errf")" "orch: could not read the start time of pid $out"
assert_contains "then the could-not-register line" "$(sed -n 2p "$errf")" \
  "orch: this run could not register as active - its suite cost is not recorded"
rm -rf "$fake_proc" "$fake_bin" "$errf"

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
shell_line_text="A single argument is a shell line, run with bash -c and recorded as given"
run_block="${flat#*"suite-cost run -- <cmd> [args...] "}"
run_block="${run_block%%"suite-cost check -- <cmd> [args...] "*}"
check_block="${flat#*"suite-cost check -- <cmd> [args...] "}"
check_block="${check_block%%"suite-cost history "*}"
assert_contains "run's help text says a single argument is a shell line run with bash -c and recorded as given" \
  "$run_block" "$shell_line_text"
assert_contains "check's help text says a single argument is a shell line run with bash -c and recorded as given" \
  "$check_block" "$shell_line_text"
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

# A clean record of the full command on one commit, then a further commit with
# no record of its own: check uses that record as the head's, not unmeasured.
: >"$rec"
seed_run "$base" 100.00
seed_run "$parent" 105.00
assert_eq "a clean record on an earlier commit is used as the head's, not unmeasured" \
  "$(verdict)" "ok"
assert_eq "decided from the record, running nothing" "$(on_disk "$marker")" absent
rm -f "$marker"

seed_run "$base" 60.00
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

# A record file over a pipe's capacity, the head record newest: the verdict is
# the same and nothing reaches stderr when SIGPIPE is ignored, whatever of the
# record file is left unread.
: >"$rec"
seed_run "$base" 100.00
filler="$(printf 'x%.0s' $(seq 80))"
for _ in $(seq 1000); do seed_run "$root" 1.00 "$filler"; done
seed_run "$head" 105.00
assert_eq "the record file is over a pipe's capacity" \
  "$([ "$(wc -c <"$rec")" -gt 65536 ] && echo over)" "over"
errf="$(mktemp)"
out="$( (trap '' PIPE; "$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf") )"
assert_eq "a large record file gives the same verdict with SIGPIPE ignored" "$out" "ok"
assert_eq "and writes nothing to stderr" "$(cat "$errf")" ""
rm -f "$errf" "$marker"

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
state_truncate 10
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>&1)"; st=$?
assert_state_unreadable "suite-cost check" 0 "$out" "$st"
assert_contains "suite-cost check reports the base unmeasured, not a fallback" "$out" "unmeasured"
assert_not_contains "suite-cost check prints no measured line" "$out" "ok"

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

# A base run is a measured run too: one overlapped by a suite-cost run that
# starts once the base run is under way (handshake_overlap_check, the FIFOs
# named by absolute path so the base worktree reaches them) is not recorded,
# and check is unmeasured.
check_repo
hs="$(handshake_fifos)"
waiter=(sh -c "$(handshake_first "$hs")")
seed_run "$head" 70.00 "${waiter[*]}"
before="$(cat "$rec")"
handshake_overlap_check "$hs" "${waiter[@]}"
out="$(cat "$hs/out")"
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


# Started from a subdirectory, a base run measures in the matching directory
# of the base commit's worktree - pkg/ there, never the top.
# sub_repo: a repo, cwd at its top, with rec and a marker path set;
# branch_off_base commits what the case wrote as the base commit; sub_head
# commits it as head. Scripts are written executable by put_script <path>
# <content>.
sub_repo() { new_repo >/dev/null; rec_path made; marker="$(mktemp -d)/ran"; }
put_script() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" >"$1"; chmod +x "$1"; }
sub_head() { git add -A; git commit -q --allow-empty -m head; head="$(git rev-parse HEAD)"; }
active_left() { [ -s "$rec.active" ] && echo left || echo none; }

sub_repo
put_script pkg/test.sh ': >"$1"'
branch_off_base
sub_head
cmd=(./test.sh "$marker")
seed_run "$head" 70.00 "${cmd[*]}"
errf="$(mktemp)"
out="$(sub_check)"; st=$?
assert_status "a base run from a subdirectory exits 0" "$st" 0
assert_eq "its command, which exists only there, ran" "$(on_disk "$marker")" present
assert_eq "recorded at the base commit" "$(tail -n 1 "$rec" | cut -f1)" "$base"
assert_eq "under the command string" "$(tail -n 1 "$rec" | cut -f5)" "${cmd[*]}"
assert_eq "and the worktree is gone" "$(no_worktree)" none

# A command resolving at the top and in the subdirectory runs in the latter.
sub_repo
put_script test.sh 'echo top >"$1"'
put_script pkg/test.sh 'echo sub >"$1"'
branch_off_base
sub_head
cmd=(./test.sh "$marker")
seed_run "$head" 70.00 "${cmd[*]}"
(cd pkg && "$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1)
assert_eq "a command at the top and in pkg/ leaves pkg's trace, never the top's" "$(cat "$marker")" sub

# A base commit with no matching directory, or a file at that path, is
# unmeasured: no setup, no command, no record, no worktree, no marker.
for variant in absent file; do
  sub_repo
  if [ "$variant" = file ]; then echo x >pkg; fi
  branch_off_base
  rm -f pkg
  put_script pkg/test.sh 'touch "$1"'
  sub_head
  cmd=(./test.sh "$marker")
  seed_run "$head" 70.00 "${cmd[*]}"
  before="$(cat "$rec")"
  setup_mark="$(mktemp -d)/setup"
  git config orchestrator.suiteCost.setup "touch '$setup_mark'"
  out="$(sub_check)"; st=$?
  assert_status "a base commit with $variant at the path exits 0" "$st" 0
  assert_eq "and is unmeasured" "$out" "unmeasured"
  assert_contains "warning the base-run wording" "$(cat "$errf")" \
    "orch: commit $base has no directory pkg for the base run - the suite cost is unmeasured"
  assert_eq "recording nothing" "$(cat "$rec")" "$before"
  assert_eq "running no command" "$(on_disk "$marker")" absent
  assert_eq "running no setup" "$(on_disk "$setup_mark")" absent
  assert_eq "leaving no worktree" "$(no_worktree)" none
  assert_eq "and no active-runs marker" "$(active_left)" none
done

# The setup runs at the worktree's top; the measured command sees it from pkg/.
sub_repo
put_script pkg/test.sh 'cp ../setup.out "$1"'
branch_off_base
sub_head
cmd=(./test.sh "$marker")
seed_run "$head" 70.00 "${cmd[*]}"
git config orchestrator.suiteCost.setup 'echo at-top >setup.out'
(cd pkg && "$ORCH" suite-cost check -- "${cmd[@]}" >/dev/null 2>&1)
assert_eq "the setup's file is at the worktree's top, seen from pkg/" "$(cat "$marker")" at-top

# Exit 127 in the matching directory, with no setup, names the setup key.
sub_repo
mkdir pkg; : >pkg/keep
branch_off_base
put_script pkg/test.sh 'exit 0'
sub_head
cmd=(./test.sh)
seed_run "$head" 70.00 "${cmd[*]}"
out="$(sub_check)"; st=$?
assert_status "a base run exiting 127 from a subdirectory exits 0" "$st" 0
assert_contains "with the hint naming the setup key" "$(cat "$errf")" \
  "$base exited 127 (command not found)"
assert_contains "naming orchestrator.suiteCost.setup" "$(cat "$errf")" "orchestrator.suiteCost.setup"

# A one-argument line is a shell line: the base run runs it whole, through the
# timer fake, and records it as given.
ORCH_SUITE_COST_FAKE_CPU="$(mktemp)"
export ORCH_SUITE_COST_TIMER="$TEST_DIR/suite_cost_timer_fake.sh" ORCH_SUITE_COST_FAKE_CPU
errf="$(mktemp)"
check_repo
mk2="$(mktemp -d)/second"
line="true && touch $mk2"
fake_cpu "$base" 5.00
fake_cpu "$head" 5.00
seed_run "$head" 70.00 "$line"
out="$("$ORCH" suite-cost check -- "$line" 2>"$errf")"
assert_eq "a one-argument chained line's base run runs its second half" "$(on_disk "$mk2")" present
assert_eq "and records the line as given on the base" \
  "$(awk -F'\t' -v b="$base" -v l="$line" '$1 == b && $5 == l' "$rec" | wc -l | tr -d ' ')" 1

: >"$rec"
seed_run "$base" 5.00 "true"
seed_run "$head" 5.00 "true"
before="$(cat "$rec")"
"$ORCH" suite-cost check -- "true" >/dev/null 2>"$errf"
assert_eq "a seeded one-word record serves as the base: no base run records" "$(cat "$rec")" "$before"

: >"$rec"
line="no-such-program-xyz --flag"
seed_run "$head" 70.00 "$line"
out="$("$ORCH" suite-cost check -- "$line" 2>"$errf")"
assert_eq "a missing program in a one-argument line is unmeasured" "$out" "unmeasured"
assert_contains "its base run exits 127" "$(cat "$errf")" "$base exited 127"
assert_contains "and the warning names the setup key" "$(cat "$errf")" "orchestrator.suiteCost.setup"

: >"$rec"
line="true && exit 4"
seed_run "$head" 70.00 "$line"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "$line" 2>"$errf")"
assert_eq "a failing second half is unmeasured" "$out" "unmeasured"
assert_contains "warning with the base run's exit code" "$(cat "$errf")" "the base run at $base exited 4"
assert_eq "no base record is written" "$(cat "$rec")" "$before"
assert_eq "and no verdict" "$(on_disk "$rec.verdicts")" absent
rm -rf "$errf" "$ORCH_SUITE_COST_FAKE_CPU"
restore_suite_env ORCH_SUITE_COST_TIMER ORCH_SUITE_COST_FAKE_CPU
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

# Overlapped confirming runs, by handshake_overlap_check: a suite-cost run
# starts once the confirming run's script signals it is running. The head's
# first.
overlap_tail="overlapped another suite-cost run - the growth is unconfirmed"
hs="$(handshake_fifos)"
marker="$hs/base-ran"
confirm_repo "touch $marker" "$(handshake_first "$hs")"
before="$(cat "$rec")"
handshake_overlap_check "$hs" "${cmd[@]}"
out="$(cat "$hs/out")"
assert_eq "an overlapped head confirming run is unmeasured" "$out" "unmeasured"
assert_contains "warning of the contention at the head" "$(cat "$hs/err")" \
  "orch: the confirming run at $head $overlap_tail"
assert_eq "the base confirming run does not run" "$(on_disk "$marker")" absent
assert_eq "and nothing is recorded" "$(cat "$rec")" "$before"

# The base's, after a solo head confirming run.
confirm_repo "$(handshake_first "$hs")" ":"
handshake_overlap_check "$hs" "${cmd[@]}"
assert_eq "an overlapped base confirming run is unmeasured" "$(cat "$hs/out")" "unmeasured"
assert_contains "warning of the contention at the base" "$(cat "$hs/err")" \
  "orch: the confirming run at $base $overlap_tail"
assert_eq "the solo head confirming run before it is recorded" "$(grep -c "^$head" "$rec")" 2
assert_eq "the overlapped base run is not" "$(grep -c "^$base" "$rec")" 1
assert_eq "and no worktree is left" "$(git worktree list | wc -l | tr -d ' ')" 1
# Verdict reuse: a verdict check confirmed is stored in suite-cost.verdicts and
# printed again, nothing run, while the clean HEAD, base commit, command and
# knobs are unchanged. A command that appends to a counter file counts runs.
cnt="$(mktemp)"
runs() { log_count "$cnt"; }
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
assert_eq "one verdict line is written" "$(log_count "$vf")" 1
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
assert_eq "and writes no line" "$(log_count "$vf")" 1
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


# From a subdirectory, the confirming runs measure in the matching directory.
# sub_confirm_repo <base has pkg> <head has pkg>: confirm_repo's shape with
# run.sh under pkg/, cwd at the top (cd pkg for the check).
sub_confirm_repo() {
  new_repo >/dev/null
  mkdir -p pkg
  [ "$1" = yes ] && { echo ':' >pkg/run.sh; } || : >keep
  branch_off_base
  [ "$2" = yes ] && echo ':' >pkg/run.sh
  git add -A; git commit -q --allow-empty -m head
  head="$(git rev-parse HEAD)"
  rec_path made
  vf="$rec.verdicts"
  cmd=(sh run.sh)
  cmd_str="sh run.sh"
  confirm_reset
}
rec_shas() { awk -F'\t' 'NR > 2 { print $1 }' "$rec" | tr '\n' ' '; }

sub_confirm_repo yes yes
out="$(sub_check)"
assert_eq "confirming runs from a subdirectory give the timer fake's verdict" "$out" "ok"
assert_eq "both are recorded, head then base" "$(rec_shas)" "$head $base "
assert_eq "and their worktrees are gone" "$(no_worktree)" none

confirm_reset
: >"$rec"
seed_run "$head" 100.00
out="$(sub_check)"
assert_eq "a base run then confirmation from a subdirectory gives the fake's verdict" "$out" "ok"
assert_eq "records base, head, then base" "$(awk -F'\t' '{ print $1 }' "$rec" | tr '\n' ' ')" "$head $base $head $base "

sub_confirm_repo no no
marker="$(mktemp -d)/ran"
printf 'touch %s\n' "$marker" >pkg/run.sh
before="$(cat "$rec")"
out="$(sub_check)"
assert_eq "a head without the tracked directory is unmeasured" "$out" "unmeasured"
assert_contains "warning the confirming-run wording naming HEAD" "$(cat "$errf")" \
  "orch: commit $head has no directory pkg for the confirming run - the growth is unconfirmed"
assert_eq "adding no record line" "$(cat "$rec")" "$before"
assert_eq "running no command" "$(on_disk "$marker")" absent
assert_eq "and leaving no worktree" "$(no_worktree)" none

sub_confirm_repo no yes
out="$(sub_check)"
assert_eq "a base commit without the directory is unmeasured" "$out" "unmeasured"
assert_contains "warning the confirming-run wording naming the base commit" "$(cat "$errf")" \
  "orch: commit $base has no directory pkg for the confirming run - the growth is unconfirmed"
assert_eq "leaving the head confirming run's line alone" "$(rec_shas)" "$head "
assert_eq "and no worktree" "$(no_worktree)" none

# A one-argument chained line: each confirming run runs the whole line, and the
# verdict record carries the line as given.
confirm_repo ":" ":"
cmark="$(mktemp -d)/ran"
line=": && echo ran >>$cmark"
cmd=("$line")
cmd_str="$line"
confirm_reset
fake_cpu "$head" 90.00
fake_cpu "$base" 60.00
out="$("$ORCH" suite-cost check -- "$line" 2>"$errf")"
assert_contains "a one-argument chained line's growth is confirmed" "$out" "grew "
assert_eq "each confirming run ran the whole line: head's and base's" "$(wc -l <"$cmark" | tr -d ' ')" 2
assert_eq "the verdict record carries the line as given" "$(cut -f6 "$vf")" "$line"
rm -rf "$hs" "$errf"
rm -f "$ORCH_SUITE_COST_FAKE_CPU"
restore_suite_env ORCH_SUITE_COST_TIMER ORCH_SUITE_COST_FAKE_CPU

# --- suite-cost check pre-check -----------------------------------------------
# Before a measured run, check looks for another live suite-cost run in the
# active-runs directory and, finding one, starts nothing and is unmeasured.
# A live foreign marker is seeded under the test shell's own pid.
echo
echo "suite-cost check pre-check"
ORCH_SUITE_COST_FAKE_CPU="$(mktemp)"
export ORCH_SUITE_COST_TIMER="$TEST_DIR/suite_cost_timer_fake.sh" ORCH_SUITE_COST_FAKE_CPU
errf="$(mktemp)"
sh -c 'exit 0' &
dead=$!
wait "$dead"

# One repo for every case, from confirm_repo: head 100.00 over base 50.00
# seeded, the timer fake at 50.00 on either commit. pre_reset puts it back,
# with the base record dropped so a check must make a base run, and .active
# gone.
confirm_repo ":" ":"
active="$rec.active"
pre_reset() {
  confirm_reset
  : >"$rec"
  seed_run "$head" 100.00
}

# (a) no base record: a live marker beside a stale one blocks the base run.
pre_reset
mkdir -p "$active"
sourced_orch liveness_record_write "$$" "$active/$$"
: >"$active/$dead"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"; st=$?
assert_status "a check beside a live run exits 0" "$st" 0
assert_eq "and is unmeasured" "$out" "unmeasured"
assert_contains "warning naming the live pid" "$(cat "$errf")" \
  "orch: another suite-cost run (pid $$) is in progress - the suite cost is unmeasured"
assert_eq "recording nothing" "$(cat "$rec")" "$before"
assert_eq "marking the live run not contended" "$(on_disk "$active/$$.contended")" absent
assert_eq "leaving only the live marker" "$(ls "$active")" "$$"
assert_eq "and adding no worktree" "$(git worktree list | wc -l | tr -d ' ')" 1

# (b) a grew comparison with a live marker: no confirming run.
confirm_reset
mkdir -p "$active"
sourced_orch liveness_record_write "$$" "$active/$$"
before="$(cat "$rec")"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a grew comparison beside a live run is unmeasured" "$out" "unmeasured"
assert_contains "warning the growth is unconfirmed, naming the pid" "$(cat "$errf")" \
  "orch: another suite-cost run (pid $$) is in progress - the growth is unconfirmed"
assert_eq "with no confirming run recorded" "$(cat "$rec")" "$before"

# (c) a live run appearing during the head confirming run stops the base one.
live_rec="$(sourced_orch liveness_record_write "$$" /dev/stdout)"
cmd=(sh -c 'if [ "$(git rev-parse HEAD)" = "$0" ]; then mkdir -p "$1" && printf "%s\n" "$3" >"$1/$2"; fi' "$head" "$active" "$$" "$live_rec")
cmd_str="${cmd[*]}"
confirm_reset
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a live run seeded by the head confirming run leaves check unmeasured" "$out" "unmeasured"
assert_contains "warning before the base confirming run" "$(cat "$errf")" \
  "orch: another suite-cost run (pid $$) is in progress - the growth is unconfirmed"
assert_eq "the head confirming run is recorded" "$(grep -c "^$head" "$rec")" 2
assert_eq "and the base confirming run never ran" "$(grep -c "^$base" "$rec")" 1
cmd=(sh run.sh)
cmd_str="sh run.sh"

# (d) answers needing no run are unchanged beside a live run.
confirm_reset
: >"$rec"
seed_run "$base" 100.00
seed_run "$head" 100.00
mkdir -p "$active"
sourced_orch liveness_record_write "$$" "$active/$$"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a recorded base whose comparison is ok prints ok" "$out" "ok"
assert_eq "without a warning" "$(cat "$errf")" ""
git config orchestrator.suiteCost.floor 1000
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a recorded base whose comparison is off prints off" "$out" "off"
assert_eq "without a warning" "$(cat "$errf")" ""
git config orchestrator.suiteCost.floor 0.01
printf '%s\t%s\t0.01\t15\t2021-01-01T00:00:00Z\t%s\tgrew 7 - stored\n' "$head" "$base" "$cmd_str" >"$rec.verdicts"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a stored verdict is printed" "$out" "grew 7 - stored"
assert_eq "without a warning" "$(cat "$errf")" ""

# (e) a stale marker does not block the base run.
pre_reset
mkdir -p "$active"
: >"$active/$dead"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a stale marker does not block the base run" "$out" "ok"
assert_eq "and the base run is recorded" "$(grep -c "^$base" "$rec")" 2

# (f) a .contended file under a live pid, no marker, does not block it.
pre_reset
mkdir -p "$active"
: >"$active/$$.contended"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a .contended file with no marker does not block the base run" "$out" "ok"
assert_eq "and the base run is recorded" "$(grep -c "^$base" "$rec")" 2

# (g) a marker with another start time and an empty marker do not block it.
pre_reset
mkdir -p "$active"
printf '%s 1\n' "$$" >"$active/$$"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "a marker with another start time does not block the base run" "$out" "ok"
pre_reset
mkdir -p "$active"
: >"$active/$$"
out="$("$ORCH" suite-cost check -- "${cmd[@]}" 2>"$errf")"
assert_eq "an empty marker does not block the base run" "$out" "ok"

rm -rf "$errf" "$ORCH_SUITE_COST_FAKE_CPU"
restore_suite_env ORCH_SUITE_COST_TIMER ORCH_SUITE_COST_FAKE_CPU

# --- suite-cost interrupt -----------------------------------------------------
# A measured run interrupted by INT, TERM or HUP cleans up after itself: no
# marker, contended mark, timing file or worktree is left, nothing is recorded,
# one warning says so, and the process exits 128 plus the signal's number.
echo
echo "suite-cost interrupt"
sig_status() { case "$1" in INT) echo 130 ;; TERM) echo 143 ;; HUP) echo 129 ;; esac; }
interrupted_msg="orch: this run was interrupted - its suite cost is not recorded"

# assert_clean_interrupt <label> <errfile> <status> <signal> <tmpdir>
assert_clean_interrupt() {
  assert_status "$1: exits 128 plus the signal's number" "$3" "$(sig_status "$4")"
  assert_eq "$1: warns once" "$(grep -cF -- "$interrupted_msg" "$2")" 1
  assert_eq "$1: leaves no marker or contended mark" "$(ls -A "$rec.active" 2>/dev/null | wc -l | tr -d ' ')" 0
  assert_eq "$1: leaves no timing file" "$(ls -A "$5" | wc -l | tr -d ' ')" 0
  assert_eq "$1: leaves no worktree" "$(no_worktree)" none
}

# A shell that started with SIGINT ignored, as a parallel runner's child does,
# hands that on to orch.sh, which then cannot trap INT. perl restores its
# default for the INT cases; without perl they are skipped.
int_launch=()
int_skip=0
if [ "$(trap -p INT)" = "trap -- '' SIGINT" ]; then
  if command -v perl >/dev/null 2>&1; then
    int_launch=(perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"')
  else
    int_skip=1
  fi
fi

for sig in INT TERM HUP; do
  if [ "$sig" = INT ] && [ "$int_skip" -eq 1 ]; then
    skip "a run sent INT cleans up" "this shell started with SIGINT ignored, and perl is not installed to restore it"
    continue
  fi
  launch=()
  [ "$sig" != INT ] || launch=(${int_launch[@]+"${int_launch[@]}"})
  new_repo >/dev/null
  rec_path
  tdir="$(mktemp -d)"; errf="$(mktemp)"
  out="$(TMPDIR="$tdir" ${launch[@]+"${launch[@]}"} "$ORCH" suite-cost run -- sh -c "kill -$sig \$PPID" 2>"$errf")"; st=$?
  assert_clean_interrupt "run $sig" "$errf" "$st" "$sig" "$tdir"
  assert_eq "run $sig: records nothing" "$(on_disk "$rec")" absent
  TMPDIR="$tdir" "$ORCH" suite-cost run -- true >/dev/null 2>"$errf"
  assert_eq "run $sig: a run after an interrupted one warns nothing" "$(cat "$errf")" ""
  assert_eq "run $sig: and is recorded" "$(log_count "$rec")" 1

  check_repo
  seed_run "$head" 70.00 "sh -c kill -$sig \$PPID"
  tdir="$(mktemp -d)"; errf="$(mktemp)"
  out="$(TMPDIR="$tdir" ${launch[@]+"${launch[@]}"} "$ORCH" suite-cost check -- sh -c "kill -$sig \$PPID" 2>"$errf")"; st=$?
  assert_clean_interrupt "base run $sig" "$errf" "$st" "$sig" "$tdir"
  assert_eq "base run $sig: prints no verdict line" "$out" ""
  assert_eq "base run $sig: stores no verdict" "$(on_disk "$rec.verdicts")" absent
  assert_eq "base run $sig: records nothing new" "$(log_count "$rec")" 1
done

# A run interrupted while its stderr cannot be written still cleans up and exits
# 128 plus the signal's number: no write may end the handler early.
for sig in TERM HUP; do
  new_repo >/dev/null
  rec_path
  tdir="$(mktemp -d)"
  TMPDIR="$tdir" "$ORCH" suite-cost run -- sh -c "kill -$sig \$PPID" >/dev/null 2>/dev/full; st=$?
  assert_status "unwritable stderr $sig: exits 128 plus the signal's number" "$st" "$(sig_status "$sig")"
  assert_eq "unwritable stderr $sig: leaves no marker or contended mark" "$(ls -A "$rec.active" 2>/dev/null | wc -l | tr -d ' ')" 0
  assert_eq "unwritable stderr $sig: leaves no timing file" "$(ls -A "$tdir" | wc -l | tr -d ' ')" 0
  assert_eq "unwritable stderr $sig: records nothing" "$(on_disk "$rec")" absent
done

# A command that sends TERM and then finds its marker still on disk.
new_repo >/dev/null
rec_path
tdir="$(mktemp -d)"; errf="$(mktemp)"
proof="$(mktemp -u)"
TMPDIR="$tdir" "$ORCH" suite-cost run -- sh -c 'kill -TERM $PPID; test -e "$0/$PPID" && : >"$1"' "$rec.active" "$proof" >/dev/null 2>"$errf"; st=$?
assert_clean_interrupt "a command finding its marker after TERM" "$errf" "$st" TERM "$tdir"
assert_eq "the marker stayed until the command returned" "$(on_disk "$proof")" present
rm -f -- "$proof"

# A base run's setup command that signals its parent.
check_repo
seed_run "$head" 70.00 "${pass[*]}"
git config orchestrator.suiteCost.setup 'kill -TERM $PPID'
tdir="$(mktemp -d)"; errf="$(mktemp)"
out="$(TMPDIR="$tdir" "$ORCH" suite-cost check -- "${pass[@]}" 2>"$errf")"; st=$?
assert_clean_interrupt "a setup that signals" "$errf" "$st" TERM "$tdir"
assert_eq "the command never ran" "$(on_disk "$marker")" absent
assert_eq "a setup that signals: prints no verdict line" "$out" ""
assert_eq "a setup that signals: stores no verdict" "$(on_disk "$rec.verdicts")" absent
assert_eq "a setup that signals: records nothing new" "$(log_count "$rec")" 1

# A confirming run: the base is recorded, the head grew, so the base confirming
# run (the command's second run) measures the command, which signals.
check_repo
sigcmd=(sh -c 'if [ -e "$0" ]; then kill -TERM $PPID; fi; touch "$0"' "$marker")
seed_run "$head" 100.00 "${sigcmd[*]}"
seed_run "$base" 70.00 "${sigcmd[*]}"
tdir="$(mktemp -d)"; errf="$(mktemp)"
out="$(TMPDIR="$tdir" "$ORCH" suite-cost check -- "${sigcmd[@]}" 2>"$errf")"; st=$?
assert_clean_interrupt "a confirming run" "$errf" "$st" TERM "$tdir"
assert_eq "a confirming run prints no verdict line" "$out" ""
assert_eq "a confirming run stores no verdict" "$(on_disk "$rec.verdicts")" absent
# Two seeds plus the head run the check recorded before the base run signalled.
assert_eq "a confirming run records nothing from the interrupted run" "$(log_count "$rec")" 3

# A base run whose command locks its own worktree before signalling: the
# removal fails, naming the removing command, and the exit stays 143.
check_repo
seed_run "$head" 70.00 "sh -c git worktree lock . && kill -TERM \$PPID"
tdir="$(mktemp -d)"; errf="$(mktemp)"
TMPDIR="$tdir" "$ORCH" suite-cost check -- sh -c 'git worktree lock . && kill -TERM $PPID' >/dev/null 2>"$errf"; st=$?
assert_status "a locked worktree: still exits 143" "$st" 143
# the locked worktree keeps its own directory; no timing file may stay beside it
assert_eq "a locked worktree: leaves no timing file" "$(find "$tdir" -mindepth 1 -maxdepth 1 ! -type d | wc -l | tr -d ' ')" 0
assert_contains "the removal's warning names the removing command" "$(cat "$errf")" "git worktree remove --force"
git worktree list --porcelain | awk '/^worktree /{print $2}' | while read -r w; do
  [ "$w" = "$PWD" ] || { git worktree unlock "$w" 2>/dev/null; git worktree remove --force "$w" 2>/dev/null; }
done

# A base run interrupted once whose worktree removal sends the process a second
# signal: the cleanup still finishes, warns once, and the exit stays 143.
check_repo
seed_run "$head" 70.00 "sh -c kill -TERM \$PPID"
realgit="$(command -v git)"
gitbin="$(mktemp -d)"
cat >"$gitbin/git" <<EOS
#!/bin/sh
if [ "\$1 \$2" = "worktree remove" ]; then kill -HUP \$PPID; fi
exec "$realgit" "\$@"
EOS
chmod +x "$gitbin/git"
tdir="$(mktemp -d)"; errf="$(mktemp)"
out="$(PATH="$gitbin:$PATH" TMPDIR="$tdir" "$ORCH" suite-cost check -- sh -c 'kill -TERM $PPID' 2>"$errf")"; st=$?
assert_clean_interrupt "a second signal during cleanup" "$errf" "$st" TERM "$tdir"
rm -rf -- "$gitbin"

# A run that could not register: a plain file where the active-runs directory
# goes.
new_repo >/dev/null
rec_path made
printf 'plain\n' >"$rec.active"
tdir="$(mktemp -d)"; errf="$(mktemp)"
TMPDIR="$tdir" "$ORCH" suite-cost run -- sh -c 'kill -TERM $PPID' >/dev/null 2>"$errf"; st=$?
assert_status "an unregistered run, interrupted, exits 143" "$st" 143
assert_eq "an unregistered run, interrupted: leaves no timing file" "$(ls -A "$tdir" | wc -l | tr -d ' ')" 0
assert_eq "warns once" "$(grep -cF -- "$interrupted_msg" "$errf")" 1
assert_eq "records nothing" "$(on_disk "$rec")" absent
assert_eq "and leaves the plain file as it was" "$(cat "$rec.active")" plain

# --- suite-cost barrier -------------------------------------------------------
# A FIFO handshake whose partner never arrives fails fast, naming the side and
# its FIFO, instead of hanging the run.
hs="$(handshake_fifos)"
SECONDS=0
err="$(fifo_read_line 1 "side X ($hs/one)" "$hs/one" 2>&1 >/dev/null)"; st=$?
assert_status "fifo_read_line: a partnerless FIFO read returns 124" "$st" 124
assert_eq "and gives up within a few seconds" "$([ "$SECONDS" -le 5 ] && echo yes)" "yes"
assert_eq "and names the side and the FIFO" "$err" "side X ($hs/one): no partner within 1s"

err="$(fifo_bounded 1 "side W" sleep 5 2>&1)"; st=$?
assert_status "fifo_bounded: a command outlasting the bound returns 124" "$st" 124
assert_eq "and names the side" "$err" "side W: no partner within 1s"

err="$(fifo_bounded 5 "side Y" sh -c 'exit 3' 2>&1)"; st=$?
assert_status "fifo_bounded: another status passes through" "$st" 3
assert_eq "and prints no message" "$err" ""

( printf x >"$hs/one" ) &
out="$(fifo_read_line 5 "side Z" "$hs/one"; echo "END$?")"
wait
assert_eq "fifo_read_line: a read of a last line with no newline succeeds" "${out##*END}" 0
assert_eq "and yields the line plus one newline" "${out%END*}" "x
"

new_repo >/dev/null
rec_path
SECONDS=0
bash -c "$(handshake_first "$hs" 1)" >/dev/null 2>"$hs/err-first"; st=$?
assert_status "the first side with no partner ends 124" "$st" 124
assert_contains "and its message names the first side and its FIFO" "$(cat "$hs/err-first")" "first side ($hs/one, $hs/two): no partner within 1s"
handshake_partner "$hs" 1 >/dev/null 2>"$hs/err-partner"; st=$?
assert_status "the partner with no first side ends 124" "$st" 124
assert_contains "and its message names the partner and its FIFO" "$(cat "$hs/err-partner")" "partner ($hs/one, $hs/two): no partner within 1s"
assert_eq "and neither waited long" "$([ "$SECONDS" -le 10 ] && echo yes)" "yes"

# replay_on_expiry copies the captured stderr on timeout's status only.
printf 'warn\nside Q: no partner within 1s\n' >"$hs/captured"
err="$(replay_on_expiry 124 "$hs/captured" 2>&1 >/dev/null)"; st=$?
assert_eq "replay_on_expiry: status 124 replays the whole file to stderr" "$err" "$(cat "$hs/captured")"
assert_status "and returns 0" "$st" 0
for rst in 0 1; do
  err="$(replay_on_expiry "$rst" "$hs/captured" 2>&1 >/dev/null)"; st=$?
  assert_eq "replay_on_expiry: status $rst prints nothing" "$err" ""
  assert_status "and returns 0 at $rst" "$st" 0
done

# A lone side run through bounded_run_replayed, as the handshake sites run
# theirs, ends 124 and its expiry reaches stderr through the replay; a first
# side's line does too under sh.
err="$(bounded_run_replayed "$hs/err-lone" 1 "listing partner ($hs/one, $hs/two)" sh -c 'read -r _ <"$0"' "$hs/one" 2>&1 >/dev/null)"; st=$?
assert_status "bounded_run_replayed: a lone side ends 124" "$st" 124
assert_contains "and its expiry reaches stderr through the replay" "$err" "listing partner ($hs/one, $hs/two): no partner within 1s"
sh -c "$(handshake_first "$hs" 1)" >/dev/null 2>"$hs/err-lone"; st=$?
assert_status "the first side's line under sh with no partner ends 124" "$st" 124
assert_contains "and names the first side and its FIFOs" "$(cat "$hs/err-lone")" "first side ($hs/one, $hs/two): no partner within 1s"

# A completed handshake writes nothing to stderr, the partner run through
# bounded_run_replayed as the handshake sites run theirs.
sh -c "$(handshake_first "$hs" 5)" >/dev/null 2>"$hs/err-done-first" &
pid_first=$!
err="$(bounded_run_replayed "$hs/err-done" 5 "partner ($hs/one, $hs/two)" sh -c 'read -r _ <"$0"; printf "x\n" >"$1"' "$hs/one" "$hs/two" 2>&1 >/dev/null)"; st=$?
wait "$pid_first"; st_first=$?
assert_status "bounded_run_replayed: a completed handshake's partner ends 0" "$st" 0
assert_status "and so does its first side" "$st_first" 0
assert_eq "and the partner captured nothing" "$(cat "$hs/err-done")" ""
assert_eq "and the first side wrote nothing to stderr" "$(cat "$hs/err-done-first")" ""
assert_eq "and the replay wrote nothing to stderr" "$err" ""
rm -rf "$hs"

# --- suite-cost base commit reads the flow state once -------------------------
echo
echo "suite-cost base commit one jq"
fresh_flow scjq
state_fixture base_sha "$(git rev-parse HEAD)"
sj_jq="$(counting_bin jq)"
out="$(PATH="$sj_jq:$PATH" sourced_orch suite_cost_base_commit 2>&1)"
assert_eq "inside a flow it prints state.base_sha" "$out" "$(git rev-parse HEAD)"
assert_eq "and starts exactly one jq" "$(counting_starts "$sj_jq" jq)" "1"
restore_suite_env
