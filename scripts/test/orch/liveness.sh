# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- Liveness module ---------------------------------------------------------
# The Liveness module's interface, called through a sourced orch.sh. A live
# record is written by a background shell kept alive, a gone one by a shell
# that has exited.

echo
echo "liveness"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
rundir="$top/.orchestrator/autopilot/run"
logdir="$top/.orchestrator/autopilot/logs"

# the start-time reader, through the records it writes
live_orch liveness_run_begin 5
rec="$(cat "$rundir/5.pid")"
assert_eq "a run record is the pid and one whitespace-free start time" "$([[ "$rec" =~ ^[0-9]+\ [^[:space:]]+$ ]] && echo yes)" yes
assert_eq "naming the calling process" "${rec%% *}" "$LIVE_PID"
out="$(sourced_orch liveness_issue_alive 5)"; st=$?
assert_status "a run record of a running process is alive" "$st" 0
assert_eq "printing its pid" "$out" "$LIVE_PID"
assert_eq "and listed as live" "$(sourced_orch liveness_live_issues)" "5"
live_stop
out="$(sourced_orch liveness_issue_alive 5)"; st=$?
assert_status "the same record once the process has exited is gone" "$st" 1
assert_eq "still printing its pid" "$out" "$LIVE_PID"
assert_eq "and no longer listed" "$(sourced_orch liveness_live_issues)" ""

# a bare pid, a malformed record and another start time are gone
running_pid=$$
printf '%s\n' "$running_pid" >"$rundir/6.pid"
sourced_orch liveness_issue_alive 6 >/dev/null; st=$?
assert_status "a bare-pid record is gone" "$st" 1
printf '%s a b\n' "$running_pid" >"$rundir/6.pid"
sourced_orch liveness_issue_alive 6 >/dev/null; st=$?
assert_status "a record with extra fields is gone" "$st" 1
printf 'word 1\n' >"$rundir/6.pid"
sourced_orch liveness_issue_alive 6 >/dev/null; st=$?
assert_status "a record with no pid is gone" "$st" 1
printf '%s 1\n' "$running_pid" >"$rundir/6.pid"
sourced_orch liveness_issue_alive 6 >/dev/null; st=$?
assert_status "a live pid with another start time is gone" "$st" 1
rm -f "$rundir/6.pid"
out="$(sourced_orch liveness_issue_alive 6)"; st=$?
assert_status "an issue with neither record is gone" "$st" 1
assert_eq "printing no pid" "$out" ""

# the run record outranks the tick record
live_orch liveness_tick_begin 8
printf '%s 1\n' "$LIVE_PID" >"$rundir/8.pid"
sourced_orch liveness_issue_alive 8 >/dev/null; st=$?
assert_status "a gone run record outranks a live tick record" "$st" 1
rm -f "$rundir/8.pid"
out="$(sourced_orch liveness_issue_alive 8)"; st=$?
assert_status "a live tick record alone is alive" "$st" 0
assert_eq "printing its pid" "$out" "$LIVE_PID"
live_stop

# the start time through a fake /proc, and through ps
fp="$(mktemp -d)"
ORCH_PROC_DIR="$fp" sourced_orch_script 'fake_proc_stat() { mkdir -p "$1/$2"; printf "%s (cmd with ) paren) S 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n" "$2" "$3" >"$1/$2/stat"; }; fake_proc_stat "$ORCH_PROC_DIR" $$ 4242; liveness_run_begin 9'
assert_eq "field 22 of the stat is the start time, past a command name with a paren" "$(sed 's/^[0-9]* //' "$rundir/9.pid")" "4242"
rm -rf "$fp"
fp="$(mktemp -d)"
if command -v ps >/dev/null 2>&1; then
  ORCH_PROC_DIR="$fp" sourced_orch liveness_run_begin 9
  assert_eq "with no /proc entry the start time comes from ps, whitespace-free" "$(sed 's/^[0-9]* //' "$rundir/9.pid" | tr -d '[:space:]')" "$(sed 's/^[0-9]* //' "$rundir/9.pid")"
  assert_eq "and is not empty" "$([ -n "$(sed 's/^[0-9]* //' "$rundir/9.pid")" ] && echo yes)" yes
else
  skip "with no /proc entry the start time comes from ps" "no ps on this machine (the autopilot image ships no procps)"
fi
rm -f "$rundir/9.pid"

# run_begin: success, failure
printf 'old\n' >"$rundir/10.tick"
sourced_orch liveness_run_begin 10
assert_eq "a successful run_begin leaves the run record" "$(on_disk "$rundir/10.pid")" present
assert_eq "and no tick record" "$(on_disk "$rundir/10.tick")" absent
rm -f "$rundir/10.pid"
printf 'old\n' >"$rundir/11.tick"
unreadable="$(mktemp -d)"
out="$(ORCH_PROC_DIR="$unreadable" sourced_orch_script 'ps() { return 1; }; export -f ps; liveness_run_begin 11' 2>&1)"; st=$?
assert_status "run_begin with an unreadable start time fails" "$st" 1
assert_contains "with an orch: line naming the pid" "$out" "orch: could not read the start time of pid "
assert_eq "writes no run record" "$(on_disk "$rundir/11.pid")" absent
assert_eq "and keeps the tick record" "$(cat "$rundir/11.tick")" "old"
rm -f "$rundir/11.tick"

# tick_begin: over an older record, and an unwritable run directory
printf 'old\n' >"$rundir/12.tick"
sourced_orch liveness_tick_begin 12
assert_eq "tick_begin replaces an older tick record with the caller's" "$([[ "$(cat "$rundir/12.tick")" =~ ^[0-9]+\ [^\ ]+$ ]] && echo record)" record
rm -f "$rundir/12.tick"
mv "$rundir" "$rundir.away"; : >"$rundir"
out="$(sourced_orch liveness_tick_begin 13 2>&1)"; st=$?
assert_status "tick_begin over an unwritable run directory returns 0" "$st" 0
assert_contains "warning" "$out" "orch: could not write the tick record for issue #13"
assert_eq "and leaves no record" "$(on_disk "$rundir/13.tick")" absent
rm -f "$rundir"; mv "$rundir.away" "$rundir"

# run_end clears only its own record
live_orch liveness_run_begin 14
rec14="$(cat "$rundir/14.pid")"
sourced_orch liveness_run_end 14
assert_eq "run_end by another process leaves the record" "$(cat "$rundir/14.pid")" "$rec14"
live_stop
sourced_orch_script 'liveness_run_begin 15; liveness_run_end 15'
assert_eq "run_end by the process the record names removes it" "$(on_disk "$rundir/15.pid")" absent
sourced_orch_script 'liveness_run_begin 15; printf "999\n" >"$1"; liveness_run_end 15' "$rundir/15.pid"
assert_eq "a newer run's record survives an older run's run_end" "$(cat "$rundir/15.pid")" "999"
rm -f "$rundir/15.pid"

# live_orch returns when its function ends the shell, or returns non-zero
live_orch eval 'exit 3'
wait "$LIVE_PID" 2>/dev/null
assert_eq "live_orch returns when its function exits the shell" "$(kill -0 "$LIVE_PID" 2>/dev/null && echo live || echo gone)" gone
live_orch eval 'set +e; false'
assert_eq "live_orch returns when its function returns non-zero, the shell kept alive" "$(kill -0 "$LIVE_PID" 2>/dev/null && echo live || echo gone)" live
live_stop

# issue_forget and live_issues
live_orch liveness_run_begin 20
sourced_orch liveness_tick_begin 21
printf 'x\n' >"$rundir/22.tick"
sourced_orch liveness_tick_begin 3
assert_eq "live_issues lists only live issues" "$(sourced_orch liveness_live_issues)" "20"
live_pid_20="$LIVE_PID"
live_orch liveness_tick_begin 100
assert_eq "ascending by number" "$(sourced_orch liveness_live_issues | tr '\n' ' ')" "20 100 "
live_stop
kill "$live_pid_20" 2>/dev/null; wait "$live_pid_20" 2>/dev/null
sourced_orch liveness_tick_begin 23
sourced_orch liveness_run_begin 23
printf 'x\n' >"$rundir/23.tick"
sourced_orch liveness_issue_forget 23
assert_eq "issue_forget leaves neither record" "$(on_disk "$rundir/23.pid")$(on_disk "$rundir/23.tick")" "absentabsent"

# session logs
rm -rf "$logdir"
assert_eq "latest_log of an issue with no log prints nothing" "$(sourced_orch liveness_latest_log 30)" ""
path="$(sourced_orch liveness_log_path 30 spec)"
assert_eq "log_path is logs/<issue>-<phase>-<stamp>.log" "$([[ "$path" =~ ^$logdir/30-spec-[0-9]{8}-[0-9]{6}\.log$ ]] && echo yes)" yes
assert_eq "and creates the logs directory" "$(on_disk "$logdir")" present
: >"$path"
assert_eq "latest_log agrees on the name" "$(sourced_orch liveness_latest_log 30 spec)" "$path"
: >"$logdir/30-spec-20990101-000000.log"
: >"$logdir/30-implement-20990202-000000.log"
: >"$logdir/300-spec-20991212-000000.log"
assert_eq "latest_log picks the newest of the phase, ignoring another phase's newer log" "$(sourced_orch liveness_latest_log 30 spec)" "$logdir/30-spec-20990101-000000.log"
assert_eq "without a phase it takes the newest of any" "$(sourced_orch liveness_latest_log 30)" "$logdir/30-implement-20990202-000000.log"
assert_eq "another issue's log whose number starts the same is not matched" "$(sourced_orch liveness_latest_log 3)" ""

# the watch record
gitdir="$(git rev-parse --git-common-dir)"
wpid="$gitdir/orchestrator/autopilot-watch.pid"
live_orch liveness_watch_begin
assert_eq "watch_begin writes the caller's record under the git common directory" "$(cut -d" " -f1 "$wpid")" "$LIVE_PID"
out="$(sourced_orch liveness_watch_begin 2>&1)"; st=$?
assert_status "a second watch of the clone is refused" "$st" 1
assert_contains "naming the live one" "$out" "orch: another autopilot watch (pid $LIVE_PID) is already running in this clone"
live_stop
sourced_orch liveness_watch_begin
assert_eq "a record whose process is gone is replaced" "$([ "$(cut -d' ' -f1 "$wpid")" != "$LIVE_PID" ] && echo yes)" yes
sourced_orch liveness_watch_end
assert_eq "watch_end leaves no watch pidfile" "$(on_disk "$wpid")" absent

# story 2: only liveness.sh touches /proc, ps and run/
others="$(grep -lE '/proc|ORCH_PROC_DIR|ps -o|[^[:alnum:]]run/' "$PLUGIN_ROOT/scripts/orch.sh" "$PLUGIN_ROOT"/scripts/orch/*.sh 2>/dev/null | xargs -n1 basename | tr '\n' ' ')"
assert_eq "/proc, ORCH_PROC_DIR, ps -o and a run/ path are in liveness.sh only" "$others" "liveness.sh "
