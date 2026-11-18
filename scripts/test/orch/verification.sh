# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# vr_gate <dir>: a command line that signals it is running through <dir>/up (a
# FIFO), waits until <dir>/gate exists, logs one start of the counted date, and
# prints "done".
vr_gate() {
  printf 'date >/dev/null; echo up >"%s/up"; while [ ! -f "%s/gate" ]; do sleep 0.1; done; echo done' "$1" "$1"
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

# --- verification run in help and the CLI conventions -------------------------
echo
echo "verification run docs"
new_repo >/dev/null
assert_contains "orch.sh help lists verification run with its wait knob" \
  "$(help_entry "verification run" | flat_text)" "ORCH_WAIT_BLOCK"
assert_contains "the CLI conventions noun table lists the noun" \
  "$(<"${ORCH%/*}/../docs/agents/cli-conventions.md")" '| `verification` | `run`'
