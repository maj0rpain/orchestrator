# shellcheck shell=bash
# wait.sh - the stored total of a re-callable wait (GLOSSARY.md): `review ci`
# and `spec-review wait` poll against a total counted from their first call and
# kept in $ORCH/wait/<key>, and each call blocks at most ORCH_WAIT_BLOCK
# seconds of wall time (default 570, the setting `verification run` reads),
# leaving stdout empty, saying so on stderr and exiting 75 while its wait is
# not over. The
# file holds two lines: the epoch second of the first call, and the seconds
# slept so far across every call (the larger of that and the wall clock since
# the first call is what has elapsed, as wait_elapsed counts it, so a sub-second
# test override still advances). A stored total belongs to one wait, named by
# the key the caller builds, and is forgotten as soon as a call delivers an
# outcome. Its tests: scripts/test/orch/wait.sh, and the `review ci` and
# `spec-review wait` sections.
# Sourced by orch.sh, after common.sh and the ROOT block.

ORCH_WAIT_BLOCK="${ORCH_WAIT_BLOCK:-570}"
# The epoch second this call began (the module loads once per call), what a
# call's block is measured from.
printf -v WAIT_CALL_START '%(%s)T' -1

# wait_elapsed <start> <slept>: prints the time a wait has taken: the larger of
# the wall clock since <start> and the seconds slept across every call. The wall
# clock alone is whole seconds, which a sub-second override never reaches; the
# sleep total alone ignores however long each `gh` call took, which would
# stretch a 15-minute cap well past 15 minutes on a slow connection.
wait_elapsed() {
  local now
  printf -v now '%(%s)T' -1
  awk -v w="$(( now - $1 ))" -v s="$2" 'BEGIN { print (w > s) ? w : s }'
}

# wait_open <key-text> <start-var> <slept-var>: finds or creates the stored
# total for the wait <key-text> names, and sets the two variables to the
# epoch second of its first call and the seconds slept so far (0 when new).
# It sets WAIT_FILE and WAIT_START, the file wait_forget and wait_still_running
# use and the epoch second of the wait's first call.
wait_open() {
  local key epoch start="" slept=""
  key="$(printf '%s' "$1" | git hash-object --stdin)" || die "could not key the wait"
  mkdir -p "$ORCH/wait" || die "could not create $ORCH/wait"
  WAIT_FILE="$ORCH/wait/$key"
  if [ -f "$WAIT_FILE" ]; then
    { IFS= read -r start; IFS= read -r slept; } <"$WAIT_FILE" || true
  fi
  case "$start" in ''|*[!0-9]*) start="" ;; esac
  is_number "$slept" || slept=""
  if [ -z "$start" ] || [ -z "$slept" ]; then
    epoch="$(date +%s)"
    start="$epoch"
    slept=0
    file_write_atomic "$WAIT_FILE" "$start"$'\n'"$slept"$'\n' || die "could not store the wait"
  fi
  WAIT_START="$start"
  printf -v "$2" '%s' "$start"
  printf -v "$3" '%s' "$slept"
}

# wait_forget: forgets the stored total, once a call delivers an outcome.
wait_forget() {
  rm -f "$WAIT_FILE" "$WAIT_FILE.limited"
}

# wait_limited_check <slept>: ends the call as still running (stores <slept>,
# exit 75) when a gh call met a rate limit the block could not hold - the mark
# gh_limit_handle left, which a subshell's exit could not. Call it after each
# probe of a poll loop.
wait_limited_check() {
  [ -e "$WAIT_FILE.limited" ] || return 0
  rm -f "$WAIT_FILE.limited"
  wait_still_running "$1"
}

# wait_exit_running: says on stderr that the call's wait is not over and exits
# 75; the one ending of every re-callable call that blocked ORCH_WAIT_BLOCK
# seconds without an outcome.
wait_exit_running() {
  warn "still running after ${ORCH_WAIT_BLOCK}s - run the same command again"
  exit 75
}

# wait_block_spent <summed>: prints what this call has blocked: the larger of
# the wall clock since the call began and <summed>, the seconds it slept, so
# the time each poll itself took counts against ORCH_WAIT_BLOCK too.
wait_block_spent() { wait_elapsed "$WAIT_CALL_START" "$1"; }

# wait_nap <interval> <spent>: prints <interval>, or what is left of
# ORCH_WAIT_BLOCK after <spent> seconds when that is less.
wait_nap() {
  awk -v i="$1" -v b="$ORCH_WAIT_BLOCK" -v s="$2" 'BEGIN { r = b - s; print (r < i) ? r : i }'
}

# wait_still_running <slept>: stores the seconds slept so far, says the wait is
# not over, and exits 75.
wait_still_running() {
  file_write_atomic "$WAIT_FILE" "$WAIT_START"$'\n'"$1"$'\n' || die "could not store the wait"
  wait_exit_running
}

# wait_tick <interval>: one turn of a poll loop's wait. A call that has blocked
# ORCH_WAIT_BLOCK seconds (wait_block_spent) stores the total and exits 75
# instead of sleeping on; otherwise it sleeps <interval>, or what is left of the
# block when that is less, and adds it to the caller's `slept` (across every
# call) and `blocked` (this call), which bash scopes dynamically - threading
# two counters back out through a subshell's stdout would cost more than it
# explains. A call whose sleep spent the block exits 75 at once, so the caller
# runs no further probe past ORCH_WAIT_BLOCK.
wait_tick() {
  local spent nap
  spent="$(wait_block_spent "$blocked")"
  float_lt "$spent" "$ORCH_WAIT_BLOCK" || wait_still_running "$slept"
  nap="$(wait_nap "$1" "$spent")"
  sleep "$nap"
  slept="$(float_add "$slept" "$nap")"
  blocked="$(float_add "$blocked" "$nap")"
  float_lt "$(wait_block_spent "$blocked")" "$ORCH_WAIT_BLOCK" || wait_still_running "$slept"
}
