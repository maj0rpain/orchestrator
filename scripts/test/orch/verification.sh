# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# vr_gate <dir> [quiet|after-state]: a command line that signals it is running
# through <dir>/up (a FIFO, unless quiet), waits until <dir>/gate exists, logs
# one start of the counted date, and prints "done". after-state signals once
# the call has written the record's state, which it does after the start, so a
# caller killed on the signal leaves a whole record, one newer than <dir>/mark.
vr_gate() {
  local up="echo up >\"$1/up\"; "
  [ "${2-}" != quiet ] || up=""
  [ "${2-}" != after-state ] || up="until [ -n \"\$(find .orchestrator/verification -name state -newer \"$1/mark\")\" ]; do sleep 0.1; done; $up"
  printf 'date >/dev/null; %swhile [ ! -f "%s/gate" ]; do sleep 0.1; done; echo done' "$up" "$1"
}

# vr_run <command>: one call of the line, the counted date on the path. A call
# that must end in exit 75 blocks the sub-second $vr_block (default 0.2), so a
# call that must deliver sets a longer one: `vr_block=5 vr_run <command>`.
vr_run() {
  PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK="${vr_block:-0.2}" \
    ORCH_VERIFICATION_GRACE=0.3 \
    "$ORCH" verification run "$1" 2>&1
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

# vs_rec <root>: the record directory of the run kept for <root>.
vs_rec() { vrun_rec "$vs_store" "$1"; }
# vs_live <root>: whether the process group of that run exists.
vs_live() { vrun_live "$vs_store" "$1"; }
# vs_kept <root>: prints "kept" when a record is kept for <root>, else "none".
vs_kept() { vs_rec "$1" >/dev/null && echo kept || echo none; }

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

out="$(ORCH_WAIT_BLOCK=0 "$ORCH" verification run 'true' 2>&1)"; st=$?
assert_ne "a zero wait block is refused" "$st" 0
assert_contains "naming it" "$out" "ORCH_WAIT_BLOCK"

out="$("$ORCH" verification 2>&1)"; st=$?
assert_status "verification with no verb exits 1" "$st" 1
assert_contains "with the usage line" "$out" "usage: orch.sh verification run <command>"
out="$("$ORCH" verification run 2>&1)"; st=$?
assert_status "verification run with no command exits 1" "$st" 1
assert_contains "with the usage line" "$out" "usage: orch.sh verification run <command>"

# A mark on a record directory that is gone brings nothing back.
vr_gone="$vr_dir/gone"
sourced_orch_script "orch_load verification; verification_mark '$vr_gone/termed'" >/dev/null 2>&1
assert_eq "a mark in a removed record directory creates nothing" "$([ -e "$vr_gone" ] && echo made || echo none)" "none"

# A termed record with a dead leader is still stoppable, until it has a status.
vr_sd="$vr_dir/stoppable"
mkdir "$vr_sd"
: >"$vr_sd/termed"
printf '99999999 x\n' >"$vr_sd/pid"
sourced_orch_script "orch_load verification; verification_stoppable '$vr_sd'" >/dev/null 2>&1; st=$?
assert_status "a termed record with a dead leader is stoppable" "$st" 0
: >"$vr_sd/status"
sourced_orch_script "orch_load verification; verification_stoppable '$vr_sd'" >/dev/null 2>&1; st=$?
assert_status "a record with a status is not stoppable" "$st" 1
rm -rf "$vr_sd"

# Outliving one call, then attaching, then delivery.
cmd="$(vr_gate "$vr_dir")"
out="$(PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=0.2 "$ORCH" verification run "$cmd" 2>"$vr_dir/err")"; st=$?
assert_status "work outliving one call exits 75" "$st" 75
assert_eq "with empty stdout" "$out" ""
assert_eq "and the still-running line on stderr" "$(<"$vr_dir/err")" \
  "orch: still running after 0.2s - run the same command again"
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
out="$(vr_run "$cmd")"; st=$?
assert_status "the same line run again attaches, still running" "$st" 75
assert_eq "and started no second copy" "$(counting_starts "$vr_count" date)" "1"
: >"$vr_dir/gate"
out="$(vr_block=5 vr_run "$cmd")"; st=$?
assert_status "the finished run is delivered with its status" "$st" 0
assert_eq "and its output" "$out" "done"
assert_eq "still one start" "$(counting_starts "$vr_count" date)" "1"
out="$(vr_run "$cmd")"; st=$?
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
  cmd="$(vr_gate "$vr_dir" after-state); echo $vr_case"
  : >"$vr_dir/pid"; : >"$vr_dir/mark"
  if [ "$vr_case" = alone ]; then
    PATH="$vr_count:$PATH" ORCH_WAIT_BLOCK=60 "$ORCH" verification run "$cmd" >/dev/null 2>&1 &
    vr_pid=$!
    disown "$vr_pid"  # its kill -9 below is not a job message on stderr
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
  out="$(vr_block=5 vr_run "$cmd")"; st=$?
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

cmd="$(vr_gate "$vr_dir")"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo noise >ig.log
mkdir -p .orchestrator/x && echo noise >.orchestrator/x/y
vr_run "$cmd" >/dev/null; st=$?
assert_eq "an ignored file written while a run is live leaves it attached" "$(counting_starts "$vr_count" date)" "1"
# Each call below replaces a stale run, so its block is two seconds: a 0.2 s
# block can end the call mid-stop when the whole-second clock rolls over.
echo one >>README.md
vr_block=2 vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "an edit to a tracked file makes the run stale: a fresh one starts" "$(counting_starts "$vr_count" date)" "2"
echo two >>README.md
vr_block=2 vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a second edit to the already-modified file makes it stale again" "$(counting_starts "$vr_count" date)" "3"
echo new >untracked.txt
vr_block=2 vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a new untracked file makes it stale" "$(counting_starts "$vr_count" date)" "4"

# A finished result whose tree has changed is never delivered.
vr_finished "$vr_dir"
echo three >>README.md
base="$(counting_starts "$vr_count" date)"
out="$(vr_block=5 vr_run "$vr_cmd")"; st=$?
assert_eq "a finished result whose tree changed starts a fresh run" "$(counting_starts "$vr_count" date)" "$((base + 1))"
assert_eq "and the old result is not delivered" "$out" "done
again"

# A stale live run is stopped by its process group: TERM first.
rm -f "$vr_dir/gate" "$vr_dir/log"
cmd="trap 'echo TERM >>\"$vr_dir/log\"; exit 0' TERM; date >/dev/null; echo up >\"$vr_dir/up\"; while :; do sleep 0.1; done"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo four >>README.md
vr_block=2 vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "a changed tree stops the live run with TERM" "$(<"$vr_dir/log")" "TERM"

# A stale run that ignores TERM is stopped by KILL after the grace.
rm -f "$vr_dir/pids"
cmd="trap '' TERM; echo \$\$ >>\"$vr_dir/pids\"; date >/dev/null; echo up >\"$vr_dir/up\"; while :; do sleep 0.1; done"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo five >>README.md
base="$(counting_starts "$vr_count" date)"
vr_block=2 vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_eq "the fresh run starts after the stale one is stopped" "$(counting_starts "$vr_count" date)" "$((base + 1))"
kill -0 "$(head -n 1 "$vr_dir/pids")" 2>/dev/null; st=$?
assert_status "and the stale run that ignored TERM is gone" "$st" 1

# A run whose process group was killed, leaving no status, is cleared and
# started fresh by the next call of the line: the command ends its own group
# the first time it starts.
rm -f "$vr_dir/gate" "$vr_dir/killed"
cmd="date >/dev/null; [ -f \"$vr_dir/killed\" ] || { : >\"$vr_dir/killed\"; kill -KILL 0; }; echo done"
base="$(counting_starts "$vr_count" date)"
vr_block=2 vr_run "$cmd" >/dev/null
out="$(vr_block=5 vr_run "$cmd")"; st=$?
assert_eq "a run whose group was killed is replaced by a fresh one" "$(counting_starts "$vr_count" date)" "$((base + 2))"
assert_eq "which is delivered whole" "$out" "done"

# A stale run that ignores TERM never holds a call past ORCH_WAIT_BLOCK: the
# grace wait of its stop is bounded by the block, and the grace is measured
# across calls, so a next call, with the grace spent since the TERM, goes on to
# KILL and starts the fresh run.
rm -f "$vr_dir/gate" "$vr_dir/pids"
cmd="trap '' TERM; echo \$\$ >>\"$vr_dir/pids\"; $(vr_gate "$vr_dir")"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
echo six >>README.md
vr_t0=$SECONDS
ORCH_WAIT_BLOCK=0.5 ORCH_VERIFICATION_GRACE=30 "$ORCH" verification run "$cmd" >/dev/null 2>&1; st=$?
assert_status "a stop whose grace outlasts the block ends in exit 75" "$st" 75
assert_eq "within the block, not the grace" "$(( SECONDS - vr_t0 < 4 ))" "1"
sleep 2
ORCH_WAIT_BLOCK=0.5 ORCH_VERIFICATION_GRACE=1 "$ORCH" verification run "$cmd" >/dev/null 2>&1; st=$?
assert_status "the next call, the grace spent since the TERM, goes on and starts the fresh run" "$st" 75
kill -0 "$(head -n 1 "$vr_dir/pids")" 2>/dev/null; st=$?
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
assert_status "and the stale run that ignored TERM is gone" "$st" 1
: >"$vr_dir/gate"

# The grace after a KILL is counted across calls too: a group still there when
# the KILL was sent longer ago than the grace is given up on at once, not met
# with a fresh grace that a short block never outlasts. kill is faked as a group
# that never goes.
vr_kd="$(mktemp -d)"
printf '%s\n' "$(( $(printf '%(%s)T' -1) - 10 ))" >"$vr_kd/termed"
cp "$vr_kd/termed" "$vr_kd/killed"
ORCH_WAIT_BLOCK=0.3 ORCH_VERIFICATION_GRACE=2 sourced_orch_script \
  "orch_load verification; orch_load wait; kill() { return 0; }; verification_stop 4242 '$vr_kd' || exit 3" >/dev/null 2>&1; st=$?
assert_status "a group still there past the grace since its KILL is given up on, not exit 75" "$st" 3
rm -rf "$vr_kd"

rm -f "$vr_dir/gate"
cmd="$(vr_gate "$vr_dir" quiet)"
vr_t0=$SECONDS
ORCH_VERIFICATION_INTERVAL=8 ORCH_WAIT_BLOCK=1 ORCH_VERIFICATION_GRACE=0.3 \
  "$ORCH" verification run "$cmd" >/dev/null 2>&1; st=$?
assert_status "a call with a long interval still ends in exit 75" "$st" 75
assert_eq "within the block, not a whole interval past it" "$(( SECONDS - vr_t0 < 4 ))" "1"
: >"$vr_dir/gate"

# A different command is left alone, and starts beside the live one.
rm -f "$vr_dir/gate"
cmd="$(vr_gate "$vr_dir")"
vr_run "$cmd" >/dev/null
fifo_read_line 20 "$vr_dir/up" "$vr_dir/up" >/dev/null
base="$(counting_starts "$vr_count" date)"
out="$(vr_block=5 vr_run 'echo other')"; st=$?
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
# A run finishing inside its ceiling is never stopped early, wherever the
# whole-second clock falls: begun just before a second turns, 0.7 s of work
# under a 1 s ceiling is delivered done.
vr_sec="$(printf '%(%s)T' -1)"
while [ "$(printf '%(%s)T' -1)" = "$vr_sec" ]; do sleep 0.05; done
sleep 0.85
out="$(ORCH_WAIT_BLOCK=30 "$ORCH" verification run 'sleep 0.7; echo inside' 2>&1)"; st=$?
assert_status "a run finishing inside its ceiling is delivered as done" "$st" 0
assert_eq "with its output" "$out" "inside"
for vr_bad in abc 0 -1 1.2.3; do
  git config orchestrator.verification.timeout "$vr_bad"
  out="$("$ORCH" verification run 'true' 2>&1)"; st=$?
  assert_ne "a timeout of $vr_bad is refused" "$st" 0
  assert_contains "naming the key ($vr_bad)" "$out" "orchestrator.verification.timeout"
done
git config --unset orchestrator.verification.timeout

echo
echo "verification run orphans"
new_repo >/dev/null
vr_dir="$(mktemp -d)"
vr_count="$(counting_bin date)"
vr_wt="$(mktemp -d)/wt"
git worktree add -q "$vr_wt" -b side
pushd "$vr_wt" >/dev/null || exit 1
vr_finished "$vr_dir"
popd >/dev/null || exit 1
git worktree remove --force "$vr_wt"
git worktree add -q "$vr_wt" side
base="$(counting_starts "$vr_count" date)"
out="$(cd "$vr_wt" && vr_block=5 vr_run "$vr_cmd")"; st=$?
assert_eq "a checkout made again at the same path starts a fresh run" "$(counting_starts "$vr_count" date)" "$((base + 1))"
assert_eq "and is never handed the old result" "$out" "done
again"

# --- verification stop --------------------------------------------------------
# Every live run of one checkout and of its ticket worktrees is stopped and its
# record removed; a finished run's record and another checkout's run stay.
echo
echo "verification stop"
new_repo >/dev/null
vs_main="$(pwd -P)"
vs_store="$vs_main/.orchestrator/verification"
vs_side="$(mktemp -d)/side"
git worktree add -q "$vs_side" -b vs-side
vs_tw="$vs_side/.orchestrator/worktrees/t5"
git worktree add -q "$vs_tw" -b vs-t5
vs_dir="$(mktemp -d)"
vrun_start "$vs_side" 'sleep 300'
vrun_start "$vs_tw" 'sleep 301'
vrun_start "$vs_main" 'sleep 302'
assert_eq "the three runs are live" "$(for p in "$vs_side" "$vs_tw" "$vs_main"; do vs_live "$p" && echo y; done | tr -d '\n')" "yyy"
vs_other_rec="$(vs_rec "$vs_main")"
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_side" >/dev/null 2>&1; st=$?
assert_status "stopping a checkout exits 0" "$st" 0
assert_eq "its own live run is gone with its record" "$(vs_kept "$vs_side")" "none"
assert_eq "so is the one in its ticket worktree" "$(vs_kept "$vs_tw")" "none"
assert_eq "a run of another checkout keeps running with its record" "$(vs_live "$vs_main" && [ -d "$vs_other_rec" ] && echo live)" "live"
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_side" >/dev/null 2>&1; st=$?
assert_status "a checkout with no live run is a no-op" "$st" 0
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_main" >/dev/null 2>&1
(cd "$vs_side" && vr_count="$(counting_bin date)" && vr_finished "$vs_dir")
assert_eq "a finished run's record exists before the stop" "$(vs_kept "$vs_side")" "kept"
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_side" >/dev/null 2>&1
assert_eq "and survives the stop" "$(vs_kept "$vs_side")" "kept"

# a group that survives KILL cannot be made for real, so the survival paths run
# with a kill that signals nothing and finds every group there
vrun_start "$vs_main" 'sleep 303'
out="$(cd "$vs_main" && ORCH_WAIT_BLOCK=5 ORCH_VERIFICATION_GRACE=0 sourced_orch_script "kill() { return 0; }; verification_stop_checkout \"\$1\"" "$vs_main" 2>&1)"; st=$?
assert_status "a group surviving the KILL makes the stop exit 1" "$st" 1
assert_contains "naming the process group" "$out" "process group"
assert_eq "and its record is kept" "$(vs_kept "$vs_main")" "kept"
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_main" >/dev/null 2>&1

# --- verification run orphans: a live run is stopped --------------------------
echo
echo "verification run orphans stop"
new_repo >/dev/null
vs_main="$(pwd -P)"
vs_store="$vs_main/.orchestrator/verification"
vs_wt="$(mktemp -d)/wt"
git worktree add -q "$vs_wt" -b vs-orph
vrun_start "$vs_wt" 'sleep 304'
vs_orph_pid="$(cut -d' ' -f1 "$(vs_rec "$vs_wt")/pid")"
git worktree remove --force "$vs_wt"
ORCH_WAIT_BLOCK=5 ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification run 'true' >/dev/null 2>&1
assert_eq "a live run whose worktree is removed is stopped by the next call" "$(kill -0 -- "-$vs_orph_pid" 2>/dev/null && echo live || echo stopped)" "stopped"
assert_eq "and its record dropped" "$(vs_kept "$vs_wt")" "none"
vrun_start "$vs_main" 'sleep 305'
vs_wt2="$(mktemp -d)/wt"
git worktree add -q "$vs_wt2" -b vs-orph2
vrun_start "$vs_wt2" 'sleep 306'
vs_pid2="$(cut -d' ' -f1 "$(vs_rec "$vs_wt2")/pid")"
git worktree remove --force "$vs_wt2"
out="$(ORCH_WAIT_BLOCK=5 ORCH_VERIFICATION_GRACE=0 sourced_orch_script "kill() { return 0; }; verification_clear_orphans \"\$1\"" "$vs_store" 2>&1)"; st=$?
assert_status "a surviving group does not stop the clearing" "$st" 0
assert_contains "it warns naming the process group" "$out" "orch: the run in $vs_wt2 (process group $vs_pid2)"
assert_eq "and the record is dropped anyway" "$(vs_kept "$vs_wt2")" "none"
kill -KILL -- "-$vs_pid2" 2>/dev/null
ORCH_VERIFICATION_GRACE=0.3 "$ORCH" verification stop "$vs_main" >/dev/null 2>&1

# --- verification run: block naps start no awk far from the end ---------------
# A waiting call, and a grace wait inside it, start no awk on a turn while the
# block is far from spent (wait_block_nap's fast path); a sub-second block still
# ends in exit 75 on time (the section above).
echo
echo "verification run: block naps start no awk far from the block's end"
new_repo >/dev/null
bn_awk="$(counting_bin awk)"
PATH="$bn_awk:$PATH" ORCH_WAIT_BLOCK=60 "$ORCH" verification run 'true' >/dev/null 2>&1
bn_quick="$(counting_starts "$bn_awk" awk)"
: >"$bn_awk/awk.log"
PATH="$bn_awk:$PATH" ORCH_WAIT_BLOCK=60 "$ORCH" verification run 'sleep 1' >/dev/null 2>&1; st=$?
assert_status "a long-block call polling a run of about a second delivers it" "$st" 0
assert_eq "and starts no more awk than a call whose run ends at once" \
  "$(( $(counting_starts "$bn_awk" awk) <= bn_quick ))" "1"

# verification_stop's grace wait, kill faked as a group that goes after a second
# (or is gone already).
bn_stop() {
  : >"$bn_awk/awk.log"
  bn_d="$(mktemp -d)"
  PATH="$bn_awk:$PATH" ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=5 sourced_orch_script \
    "orch_load verification; end=\$(( SECONDS + $1 )); kill() { [ \"\$1\" != -0 ] || [ \"\$SECONDS\" -lt \"\$end\" ]; }; verification_stop 4242 '$bn_d'" >/dev/null 2>&1
  assert_status "a stop whose group goes after $1 s returns 0" "$?" 0
  bn_count="$(counting_starts "$bn_awk" awk)"
}
bn_stop 0; bn_gone="$bn_count"
bn_stop 2; bn_slow="$bn_count"
assert_eq "a grace wait over a group that lasts a second starts no more awk than one over a gone group" \
  "$(( bn_slow <= bn_gone ))" "1"

# verification_wait_state: a record with no state past its grace is given up on
# at once, never exit 75 under a long block; with its state it is waited for
# no more.
bn_rec="$(mktemp -d)"
printf '%s\n' "$(( $(printf '%(%s)T' -1) - 10 ))" >"$bn_rec/waiting"
ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=1 sourced_orch_script \
  "orch_load verification; verification_wait_state '$bn_rec'" >/dev/null 2>&1; st=$?
assert_status "a record with no state and a 10 s old mark under a 1 s grace returns 1, never exit 75" "$st" 1
bn_t0=$SECONDS
ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=3 sourced_orch_script \
  "orch_load verification; verification_wait_state '$bn_rec'" >/dev/null 2>&1; st=$?
assert_status "a record with no state and a 10 s old mark is given up on at once" "$st" 1
assert_eq "and without waiting out a grace counted from naps" "$(( SECONDS - bn_t0 < 2 ))" "1"
: >"$bn_rec/state"
ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=1 sourced_orch_script \
  "orch_load verification; verification_wait_state '$bn_rec'" >/dev/null 2>&1; st=$?
assert_status "a record with its state returns 0" "$st" 0
rm -rf "$bn_rec"

# --- verification run in help and the CLI conventions -------------------------
echo
echo "verification run docs"
new_repo >/dev/null
assert_contains "orch.sh help lists verification run with its wait knob" \
  "$(help_entry "verification run" | flat_text)" "ORCH_WAIT_BLOCK"
assert_contains "the CLI conventions noun table lists the noun" \
  "$(<"${ORCH%/*}/../docs/agents/cli-conventions.md")" '| `verification` | `run`, `stop`'
