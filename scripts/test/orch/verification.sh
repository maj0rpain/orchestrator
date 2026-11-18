# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# vr_gate <dir> [quiet]: a command line that signals it is running through
# <dir>/up (a FIFO, unless quiet), waits until <dir>/gate exists, logs one start
# of the counted date, and prints "done".
vr_gate() {
  local up="echo up >\"$1/up\"; "
  [ -z "${2-}" ] || up=""
  printf 'date >/dev/null; %swhile [ ! -f "%s/gate" ]; do sleep 0.1; done; echo done' "$up" "$1"
}

# vr_finished <dir>: runs a gated line, prints "done" then "again", to its end
# without delivering it, in the current checkout (vr_run, vr_count): the line is
# left in vr_cmd. The first run of the line tells <dir>/fin (a FIFO) it has
# ended; a later run, once <dir>/ended exists, tells nothing and waits for no
# reader.
vr_finished() {
  [ -p "$1/fin" ] || mkfifo "$1/fin"
  rm -f "$1/gate" "$1/ended"
  vr_cmd="$(vr_gate "$1" quiet); echo again; [ -f \"$1/ended\" ] || echo end >\"$1/fin\""
  vr_run "$vr_cmd" >/dev/null
  : >"$1/gate"
  fifo_read_line 20 "$1/fin" "$1/fin" >/dev/null
  : >"$1/ended"
}

# --- verification run ---------------------------------------------------------
# A command line run detached and waited for in bounded calls: delivered whole
# when it ends inside a call, else exit 75 with the still-running line, and the
# same line run again attaches and starts no second copy.
echo
echo "verification run"
new_repo >/dev/null
vr_dir="$(mktemp -d)"
vr_count="$(counting_bin date)"
mkfifo "$vr_dir/up"

out="$("$ORCH" verification run 'echo out; echo err >&2; exit 3' 2>"$vr_dir/err")"; st=$?
assert_status "work finishing inside one call exits with the command's status" "$st" 3
assert_eq "and prints its stdout" "$out" "out"
assert_eq "and its stderr" "$(<"$vr_dir/err")" "err"

out="$("$ORCH" verification run 'exit 75' 2>&1)"; st=$?
assert_status "a command that itself exits 75 is delivered as exit 1" "$st" 1
assert_contains "naming its real status" "$out" "75"

out="$(ORCH_WAIT_BLOCK=abc "$ORCH" verification run 'true' 2>&1)"; st=$?
assert_ne "a wait block that is not a number is refused" "$st" 0
assert_contains "naming it" "$out" "ORCH_WAIT_BLOCK"
out="$(ORCH_WAIT_BLOCK=0 "$ORCH" verification run 'true' 2>&1)"; st=$?
assert_ne "a zero wait block is refused" "$st" 0

# Outliving one call, then attaching, then delivery.
cmd="$(vr_gate "$vr_dir")"
out="$(PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=1 "$ORCH" verification run "$cmd" 2>"$vr_dir/err")"; st=$?
assert_status "work outliving one call exits 75" "$st" 75
assert_eq "with empty stdout" "$out" ""
assert_eq "and the still-running line on stderr" "$(<"$vr_dir/err")" \
  "orch: still running after 1s - run the same command again"
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
out="$(PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=1 "$ORCH" verification run "$cmd" 2>&1)"; st=$?
assert_status "the same line run again attaches, still running" "$st" 75
assert_eq "and started no second copy" "$(counting_starts "$vr_count" date)" "1"
: >"$vr_dir/gate"
out="$(PATH="$vr_count:$PATH" "$ORCH" verification run "$cmd" 2>&1)"; st=$?
assert_status "the finished run is delivered with its status" "$st" 0
assert_eq "and its output" "$out" "done"
assert_eq "still one start" "$(counting_starts "$vr_count" date)" "1"
out="$(PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=1 "$ORCH" verification run "$cmd" 2>&1)"; st=$?
assert_status "the call after delivery starts a fresh run, still going" "$st" 75
assert_eq "two starts in all" "$(counting_starts "$vr_count" date)" "2"
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null

# A call stopped while printing leaves the result to be delivered whole.
big='head -c 300000 /dev/zero | tr "\0" x'
mkfifo "$vr_dir/sink"
exec 7<>"$vr_dir/sink"
timeout 3 "$ORCH" verification run "$big" >&7 2>/dev/null; st=$?
exec 7>&-
assert_status "a call whose stdout is an unread FIFO is stopped while printing" "$st" 124
out="$("$ORCH" verification run "$big" | wc -c | tr -d ' ')"
assert_eq "the next call delivers the result whole" "$out" "300000"

# The calling process killed mid-run, alone and with its whole process group.
for vr_case in alone group; do
  rm -f "$vr_dir/gate"
  cmd="$(vr_gate "$vr_dir"); echo $vr_case"
  : >"$vr_dir/pid"
  if [ "$vr_case" = alone ]; then
    PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=60 "$ORCH" verification run "$cmd" >/dev/null 2>&1 &
    vr_pid=$!
    fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
    kill -9 "$vr_pid"
  else
    bash -c 'set -m; PATH="$1:$PATH" ORCH_WAIT_BLOCK=60 "$2" verification run "$3" >/dev/null 2>&1 & echo $! >"$4"; wait' \
      _ "$vr_count" "$ORCH" "$cmd" "$vr_dir/pid" 2>/dev/null &
    fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
    vr_pid="$(<"$vr_dir/pid")"
    kill -9 -- "-$vr_pid"
  fi
  wait 2>/dev/null
  before="$(counting_starts "$vr_count" date)"
  : >"$vr_dir/gate"
  out="$(PATH="$vr_count:$PATH" "$ORCH" verification run "$cmd" 2>&1)"; st=$?
  assert_status "the run survives the caller killed ($vr_case): its result is collected" "$st" 0
  assert_eq "its output ($vr_case)" "$out" "done
$vr_case"
  assert_eq "with no second copy started ($vr_case)" "$(counting_starts "$vr_count" date)" "$before"
done

# --- verification run: the run key, stale runs, the ceiling -------------------
# One run per command in a checkout; a changed HEAD or tree makes it stale.
echo
echo "verification run key"
new_repo >/dev/null
printf 'ig.log\n' >.gitignore
git add .gitignore && git commit -qm ignore
vr_dir="$(mktemp -d)"
vr_count="$(counting_bin date)"
mkfifo "$vr_dir/up"
# vr_run <command>: one call of the line, the counted date on the path.
vr_run() { PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=1 ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification run "$1" 2>&1; }

cmd="$(vr_gate "$vr_dir")"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo noise >ig.log
mkdir -p .orchestrator/x && echo noise >.orchestrator/x/y
vr_run "$cmd" >/dev/null; st=$?
assert_eq "an ignored file written while a run is live leaves it attached" "$(counting_starts "$vr_count" date)" "1"
echo one >>README.md
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "an edit to a tracked file makes the run stale: a fresh one starts" "$(counting_starts "$vr_count" date)" "2"
echo two >>README.md
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a second edit to the already-modified file makes it stale again" "$(counting_starts "$vr_count" date)" "3"
echo new >untracked.txt
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a new untracked file makes it stale" "$(counting_starts "$vr_count" date)" "4"

# A finished result whose tree has changed is never delivered.
vr_finished "$vr_dir"
echo three >>README.md
base="$(counting_starts "$vr_count" date)"
out="$(vr_run "$vr_cmd")"; st=$?
assert_eq "a finished result whose tree changed starts a fresh run" "$(counting_starts "$vr_count" date)" "$((base + 1))"
assert_eq "and the old result is not delivered" "$out" "done
again"

# A stale live run is stopped by its process group: TERM first.
rm -f "$vr_dir/gate" "$vr_dir/log"
cmd="trap 'echo TERM >>\"$vr_dir/log\"; exit 0' TERM; date >/dev/null; echo up >\"$vr_dir/up\"; while :; do sleep 0.1; done"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo four >>README.md
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a changed tree stops the live run with TERM" "$(<"$vr_dir/log")" "TERM"

# A stale run that ignores TERM is stopped by KILL after the grace.
rm -f "$vr_dir/pids"
cmd="trap '' TERM; echo \$\$ >>\"$vr_dir/pids\"; date >/dev/null; echo up >\"$vr_dir/up\"; while :; do sleep 0.1; done"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo five >>README.md
base="$(counting_starts "$vr_count" date)"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "the fresh run starts after the stale one is stopped" "$(counting_starts "$vr_count" date)" "$((base + 1))"
kill -0 "$(head -n 1 "$vr_dir/pids")" 2>/dev/null; st=$?
assert_status "and the stale run that ignored TERM is gone" "$st" 1

# A different command is left alone, and starts beside the live one.
rm -f "$vr_dir/gate"
cmd="$(vr_gate "$vr_dir")"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
base="$(counting_starts "$vr_count" date)"
out="$(vr_run 'echo other')"; st=$?
assert_eq "a different command starts its own run" "$out" "other"
vr_run "$cmd" >/dev/null; st=$?
assert_status "the first command's run is still live" "$st" 75
assert_eq "and was never restarted" "$(counting_starts "$vr_count" date)" "$base"
: >"$vr_dir/gate"

# The ceiling.
git config orchestrator.verification.timeout 1
out="$(ORCH_WAIT_BLOCK=30 ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification run 'echo partial; sleep 60' 2>&1)"; st=$?
assert_status "a run past the ceiling exits 1" "$st" 1
assert_contains "with the output it wrote" "$out" "partial"
assert_contains "and the ceiling's orch: line" "$out" "orch: the run was still going after the ceiling of 1s (orchestrator.verification.timeout)"
# The run is its own timer: a run nobody calls again is stopped at the ceiling,
# and the next call delivers it as failed.
[ -p "$vr_dir/fin" ] || mkfifo "$vr_dir/fin"
cmd="trap 'echo stopped >\"$vr_dir/fin\"; exit 0' TERM; echo partial; while :; do sleep 0.1; done"
ORCH_WAIT_BLOCK=0.2 ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification run "$cmd" >/dev/null 2>&1; st=$?
assert_status "a run outliving its call is still going" "$st" 75
assert_eq "with no call waiting on it, the ceiling stops it by TERM" \
  "$(fifo_read_line 20 "$vr_dir/fin" "$vr_dir/fin")" "stopped"
out="$(ORCH_WAIT_BLOCK=30 "$ORCH" verification run "$cmd" 2>&1)"; st=$?
assert_status "the next call delivers it as a failed run" "$st" 1
assert_contains "with the output it wrote" "$out" "partial"
assert_contains "and the ceiling's orch: line" "$out" "orch: the run was still going after the ceiling of 1s"
for vr_bad in abc 0 -1 1.2.3; do
  git config orchestrator.verification.timeout "$vr_bad"
  out="$("$ORCH" verification run 'true' 2>&1)"; st=$?
  assert_ne "a timeout of $vr_bad is refused" "$st" 0
  assert_contains "naming the key ($vr_bad)" "$out" "orchestrator.verification.timeout"
done
git config --unset orchestrator.verification.timeout

# A record of a checkout that no longer exists is cleared by the next call.
echo
echo "verification run orphans"
new_repo >/dev/null
vr_wt="$(mktemp -d)/wt"
git worktree add -q "$vr_wt" -b side
pushd "$vr_wt" >/dev/null || exit 1
vr_finished "$vr_dir"
popd >/dev/null || exit 1
git worktree remove --force "$vr_wt"
git worktree add -q "$vr_wt" side
base="$(counting_starts "$vr_count" date)"
out="$(cd "$vr_wt" && vr_run "$vr_cmd")"; st=$?
assert_eq "a checkout made again at the same path starts a fresh run" "$(counting_starts "$vr_count" date)" "$((base + 1))"
assert_eq "and is never handed the old result" "$out" "done
again"

# --- verification run in help and the CLI conventions -------------------------
echo
echo "verification run docs"
new_repo >/dev/null
assert_contains "orch.sh help lists verification run with its wait knob" \
  "$(help_entry "verification run" | flat_text)" "ORCH_WAIT_BLOCK"
assert_contains "the CLI conventions noun table lists the noun" \
  "$(<"${ORCH%/*}/../docs/agents/cli-conventions.md")" '| `verification` | `run`'
