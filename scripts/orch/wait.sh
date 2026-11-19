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
# `spec-review wait` sections, and the `gh rate limits (#2577)` section of
# scripts/test/orch/gh.sh; wait_block_nap's: the `verification run: block
# naps start no awk far from the block's end` section of
# scripts/test/orch/verification.sh.
# wait_block_nap is the block turn of a caller that keeps no stored total
# (`verification run`), with a fast path that starts no awk.
# The module also owns the limit decision - whether a GitHub rate-limit wait
# fits in what is left of the block (wait_limit_fits) - and the ".limited" mark
# that carries a give-up out of a subshell. The mark sits at WAIT_MARK, the open
# wait's mark path: beside the stored total (wait_open), or at the guard's
# provisional name (wait_guard) before the key is known; WAIT_FILE is the stored
# total alone, set only by wait_open. wait_guard is `review ci`'s guard;
# wait_block_check is the ORCH_WAIT_BLOCK knob check of all three re-callable
# commands (`review ci`, `spec-review wait`, `verification run`).
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
  local wall
  printf -v wall '%(%s)T' -1
  awk -v w="$(( wall - $1 ))" -v s="$2" 'BEGIN { print (w > s) ? w : s }'
}

# The wait's state, named here. wait_open sets it, wait_guard sets WAIT_MARK
# alone, and wait_tick advances it:
#   WAIT_FILE     the stored total's file
#   WAIT_MARK     the limit mark wait_limit_fits leaves: the stored total's
#                 ".limited" file, or the provisional guard's
#   WAIT_START    the epoch second of the wait's first call
#   WAIT_SLEPT    seconds slept across every call
#   WAIT_BLOCKED  seconds this call has blocked

# wait_open <key-text>: finds or creates the stored total for the wait
# <key-text> names, and sets WAIT_FILE, WAIT_MARK, WAIT_START and WAIT_SLEPT
# (0 when new) from it, and WAIT_BLOCKED to 0.
wait_open() {
  local key start="" slept=""
  key="$(printf '%s' "$1" | git hash-object --stdin)" || die "could not key the wait"
  mkdir -p "$ORCH/wait" || die "could not create $ORCH/wait"
  WAIT_FILE="$ORCH/wait/$key"
  WAIT_MARK="$WAIT_FILE.limited"
  if [ -f "$WAIT_FILE" ]; then
    { IFS= read -r start; IFS= read -r slept; } <"$WAIT_FILE" || true
  fi
  case "$start" in ''|*[!0-9]*) start="" ;; esac
  is_number "$slept" || slept=""
  if [ -z "$start" ] || [ -z "$slept" ]; then
    printf -v start '%(%s)T' -1
    slept=0
    file_write_atomic "$WAIT_FILE" "$start"$'\n'"$slept"$'\n' || die "could not store the wait"
  fi
  WAIT_START="$start"
  WAIT_SLEPT="$slept"
  WAIT_BLOCKED=0
}

# wait_taken: prints the open wait's elapsed time (wait_elapsed over WAIT_START
# and WAIT_SLEPT).
wait_taken() { wait_elapsed "$WAIT_START" "$WAIT_SLEPT"; }

# wait_forget: forgets the stored total and its mark (the Wait
# module's, see wait_limit_fits), once a call delivers an outcome.
wait_forget() {
  rm -f "${WAIT_FILE:-}" "${WAIT_MARK:-}"
}

# wait_limited_check: ends the call as still running (stores WAIT_SLEPT,
# exit 75) when a gh call met a rate limit the block could not hold - the mark
# wait_limit_fits left, which a subshell's exit could not. Call it after each
# probe of a poll loop.
wait_limited_check() {
  [ -e "${WAIT_MARK:-}" ] || return 0
  rm -f "$WAIT_MARK"
  wait_store_and_exit
}

# wait_limit_fits <seconds>: whether a limit wait of <seconds> fits. Returns 0
# when no re-callable wait is open (no WAIT_MARK) or what is left of
# ORCH_WAIT_BLOCK can hold it. Otherwise sleeps the rest of the block, leaves
# the mark at WAIT_MARK (not checked: an unwritable mark still returns 1) and
# returns 1.
wait_limit_fits() {
  local left
  [ -n "${WAIT_MARK:-}" ] || return 0
  left="$(wait_nap "$1" "$(wait_block_spent 0)")"
  float_lt "$left" "$1" || return 0
  if float_lt 0 "$left"; then sleep "$left"; fi
  : >"$WAIT_MARK" || :
  return 1
}

# wait_guard <name>: opens the provisional guard "pending-<name>" for a read
# that runs before the wait's key is known: points WAIT_MARK at its mark (not
# WAIT_FILE) and clears any old mark.
wait_guard() {
  mkdir -p "$ORCH/wait" || die "could not create $ORCH/wait"
  WAIT_MARK="$ORCH/wait/pending-$1.limited"
  rm -f "$WAIT_MARK"
}

# wait_guard_check: ends the call as still running (exit 75, no total stored)
# when the guard's mark was left, consuming it; otherwise returns.
wait_guard_check() {
  [ -e "${WAIT_MARK:-}" ] || return 0
  rm -f "$WAIT_MARK"
  wait_exit_running
}

# wait_block_check [die|die2]: the poll-knob check on ORCH_WAIT_BLOCK, beside
# its default, dying through the dier given.
wait_block_check() {
  require_poll_knobs "${1:-die}" ORCH_WAIT_BLOCK
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

# wait_block_nap <interval>: one turn of a poll inside this call's block, for a
# caller that keeps no stored total (`verification run` and its grace waits):
# exits 75 through wait_exit_running when the block is spent, else sleeps
# <interval>, or what is left of the block when that is less. The fast path -
# the whole seconds since WAIT_CALL_START, plus one, plus <interval> rounded up,
# at most the block's whole-second part - just sleeps: no awk, and nothing added
# to the caller's `blocked`; the wall clock alone bounds the block there. It
# sets `block_fast` in the caller's scope. The slow path keeps
# wait_block_spent's test, counting the wall clock plus one second once
# `block_fast` is set (the whole-second clock reads up to a second short, and
# the fast naps are not in
# `blocked`), and adds its nap to the caller's `blocked`, read as ${blocked:-0}.
wait_block_nap() {
  local wall whole up="${1%%.*}" frac="" spent nap
  [[ "$1" != *.* ]] || frac="${1#*.}"
  [ -z "${frac//0/}" ] || up=$(( 10#${up:-0} + 1 ))
  whole="${ORCH_WAIT_BLOCK%%.*}"
  printf -v wall '%(%s)T' -1
  if [ $(( wall - WAIT_CALL_START + 1 + 10#${up:-0} )) -le "$(( 10#${whole:-0} ))" ]; then
    block_fast=1
    sleep "$1"
    return 0
  fi
  if [ -n "${block_fast:-}" ]; then
    spent="$(wait_elapsed "$(( WAIT_CALL_START - 1 ))" "${blocked:-0}")"
  else
    spent="$(wait_block_spent "${blocked:-0}")"
  fi
  float_lt "$spent" "$ORCH_WAIT_BLOCK" || wait_exit_running
  nap="$(wait_nap "$1" "$spent")"
  sleep "$nap"
  blocked="$(float_add "${blocked:-0}" "$nap")"
}

# wait_store_and_exit: stores WAIT_START and WAIT_SLEPT in WAIT_FILE, says the
# wait is not over, and exits 75. wait_exit_running, which stores nothing, is
# the ending where there is no total to keep.
wait_store_and_exit() {
  file_write_atomic "$WAIT_FILE" "$WAIT_START"$'\n'"$WAIT_SLEPT"$'\n' || die "could not store the wait"
  wait_exit_running
}

# wait_tick <interval>: one turn of a poll loop's wait. A call that has blocked
# ORCH_WAIT_BLOCK seconds (wait_block_spent) stores the total and exits 75
# instead of sleeping on; otherwise it sleeps <interval>, or what is left of the
# block when that is less, and adds it to WAIT_SLEPT (across every call) and
# WAIT_BLOCKED (this call). A call whose sleep spent the block exits 75 at
# once, so the caller runs no further probe past ORCH_WAIT_BLOCK.
wait_tick() {
  local spent nap
  spent="$(wait_block_spent "$WAIT_BLOCKED")"
  float_lt "$spent" "$ORCH_WAIT_BLOCK" || wait_store_and_exit
  nap="$(wait_nap "$1" "$spent")"
  sleep "$nap"
  WAIT_SLEPT="$(float_add "$WAIT_SLEPT" "$nap")"
  WAIT_BLOCKED="$(float_add "$WAIT_BLOCKED" "$nap")"
  float_lt "$(wait_block_spent "$WAIT_BLOCKED")" "$ORCH_WAIT_BLOCK" || wait_store_and_exit
}
