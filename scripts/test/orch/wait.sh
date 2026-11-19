# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# wt_slow_awk <delay>: a new directory holding an awk that sleeps <delay>
# seconds before it runs, standing in for the cost of each poll of a wait (the
# float helpers every poll calls are awk).
wt_slow_awk() {
  local d real
  d="$(mktemp -d)"
  real="$(command -v awk)"
  printf '#!/bin/bash\nsleep %s\nexec %s "$@"\n' "$1" "$real" >"$d/awk"
  chmod +x "$d/awk"
  printf '%s\n' "$d"
}

# --- wait: a call's block is wall time ------------------------------------
# ORCH_WAIT_BLOCK bounds one call's wall time, the cost of each poll included,
# not only the time it slept: a poll that is slow does not stretch the call past
# the block a host's foreground limit is set against.
echo
echo "wait: a call's block is wall time"
new_repo >/dev/null
wt_dir="$(mktemp -d)"
wt_awk="$(wt_slow_awk 0.3)"

wt_cmd="while [ ! -f \"$wt_dir/gate\" ]; do sleep 0.1; done"
wt_t0=$SECONDS
PATH="$wt_awk:$PATH" ORCH_WAIT_BLOCK=2 "$ORCH" verification run "$wt_cmd" >/dev/null 2>&1; st=$?
assert_status "verification run with slow polls still exits 75" "$st" 75
assert_eq "and ends within the wall-clock block, not the summed sleep" \
  "$(( SECONDS - wt_t0 < 5 ))" "1"
: >"$wt_dir/gate"

wt_lens="$(mktemp -d)"
wt_t0=$SECONDS
PATH="$wt_awk:$PATH" ORCH_SPEC_REVIEW_WAIT_TIMEOUT=100 ORCH_SPEC_REVIEW_WAIT_INTERVAL=0.2 \
  ORCH_WAIT_BLOCK=2 "$ORCH" spec-review wait "$wt_lens" fidelity >/dev/null 2>&1; st=$?
assert_status "spec-review wait with slow polls still exits 75" "$st" 75
assert_eq "and ends within the wall-clock block too" \
  "$(( SECONDS - wt_t0 < 5 ))" "1"

# A call never sleeps past its block: the sleep is clamped to what is left, and
# a call whose sleep spent the block exits 75 without another turn.
wt_lens="$(mktemp -d)"
wt_t0=$SECONDS
ORCH_SPEC_REVIEW_WAIT_TIMEOUT=100 ORCH_SPEC_REVIEW_WAIT_INTERVAL=6 \
  ORCH_WAIT_BLOCK=0.5 "$ORCH" spec-review wait "$wt_lens" fidelity >/dev/null 2>&1; st=$?
assert_status "spec-review wait with an interval past the block exits 75" "$st" 75
assert_eq "and ends within the block, not a whole interval after it" \
  "$(( SECONDS - wt_t0 < 4 ))" "1"

# A rate limit the block could not hold (wait_limit_fits's mark) ends the poll
# loop's call as still running, total kept; with no mark, the loop goes on. The
# mark is WAIT_MARK, set apart from WAIT_FILE's name here, so a check that read
# a hard-coded "$WAIT_FILE.limited" would not see it.
wt_wf="$(mktemp)"
printf '1\n0\n' >"$wt_wf"
sourced_orch_script 'WAIT_FILE=$1; WAIT_MARK=$1.m; WAIT_START=1; WAIT_SLEPT=0; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with no mark, wait_limited_check goes on" "$st" 0
: >"$wt_wf.m"
sourced_orch_script 'WAIT_FILE=$1; WAIT_MARK=$1.m; WAIT_START=1; WAIT_SLEPT=7; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with the mark, it ends the call as still running" "$st" 75
assert_eq "keeps the stored start" "$(sed -n 1p "$wt_wf")" "1"
assert_eq "stores the seconds slept" "$(sed -n 2p "$wt_wf")" "7"
assert_status "and consumes the mark" "$([ -e "$wt_wf.m" ]; echo $?)" 1
: >"$wt_wf.m"
sourced_orch_script 'WAIT_FILE=$1; WAIT_MARK=$1.m; wait_forget; [ ! -e "$WAIT_FILE" ] && [ ! -e "$WAIT_MARK" ]' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "wait_forget removes the total and WAIT_MARK" "$st" 0
rm -f "$wt_wf" "$wt_wf.m"

# wait_limit_fits: the Wait module's decision on a limit wait (the mark is its)
wt_wf="$(mktemp)"
sourced_orch_script 'unset WAIT_FILE WAIT_MARK; ORCH_WAIT_BLOCK=0; wait_limit_fits 60' >/dev/null 2>&1; st=$?
assert_status "wait_limit_fits with no wait open fits even under a block that cannot hold it" "$st" 0
sourced_orch_script 'WAIT_MARK=$1.limited; ORCH_WAIT_BLOCK=570; wait_limit_fits 1' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "a block that can hold the wait fits" "$st" 0
assert_status "and leaves no mark" "$([ -e "$wt_wf.limited" ]; echo $?)" 1
sourced_orch_script 'WAIT_FILE=$1; WAIT_MARK=$1.limited; WAIT_START=1; WAIT_SLEPT=0; ORCH_WAIT_BLOCK=0; wait_limit_fits 60 && exit 9; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "a block that cannot hold it does not fit, and wait_limited_check ends the call as still running" "$st" 75
rm -f "$wt_wf" "$wt_wf.limited"

# wait_guard / wait_guard_check: the provisional guard of a read that runs
# before the wait's key is known; its mark is WAIT_MARK, never WAIT_FILE.
sourced_orch_script 'wait_guard 7; : >"$WAIT_MARK"; (wait_guard_check) >/dev/null 2>&1; s=$?; [ -e "$WAIT_MARK" ] && exit 1; exit $s' >/dev/null 2>&1; st=$?
assert_status "wait_guard_check with the mark present ends the call as still running and consumes the mark" "$st" 75
sourced_orch_script 'unset WAIT_FILE; wait_guard 7; wait_guard_check && [ -z "${WAIT_FILE:-}" ]' >/dev/null 2>&1; st=$?
assert_status "with no mark wait_guard_check returns, and wait_guard sets no WAIT_FILE" "$st" 0
sourced_orch_script 'wait_guard 7; : >"$WAIT_MARK"; wait_guard 7; wait_guard_check' >/dev/null 2>&1; st=$?
assert_status "a mark left by an earlier call is cleared by wait_guard" "$st" 0

# After wait_guard then wait_open, the mark is the stored total's, and a limit
# the block cannot hold leaves it there; wait_limited_check then ends the call
# as still running with the total kept (the same file, not one wait_open wrote
# afresh): its second line is the seconds slept wait_limited_check stored.
out="$(sourced_orch_script 'wait_guard 7; wait_open "wt-mark-test"; s=$WAIT_START; ORCH_WAIT_BLOCK=0; wait_limit_fits 60 && exit 9; [ -e "$WAIT_FILE.limited" ] || exit 8; [ ! -e "$ORCH/wait/pending-7.limited" ] || exit 7; (WAIT_SLEPT=3; wait_limited_check) >/dev/null 2>&1; rc=$?; [ "$rc" = 75 ] || exit 6; [ "$(sed -n 1p "$WAIT_FILE")" = "$s" ] && [ "$(sed -n 2p "$WAIT_FILE")" = 3 ] || exit 5; exit 75' 2>&1)"; st=$?
assert_status "a limit the block cannot hold leaves the total's mark and wait_limited_check exits 75 keeping the total" "$st" 75
rm -rf "${ORCH_DIR_NAME:?}/wait"

# wait_limit_fits with only WAIT_MARK set decides a wait is open.
sourced_orch_script 'unset WAIT_FILE; WAIT_MARK=$1.m; ORCH_WAIT_BLOCK=0; wait_limit_fits 60 && exit 9; [ -e "$WAIT_MARK" ]' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "a limit the block cannot hold leaves the mark with only WAIT_MARK set" "$st" 0
rm -f "$wt_wf.m"

# wait_block_check refuses a non-number or zero block through the dier given.
for wt_bad in abc 0; do
  out="$(ORCH_WAIT_BLOCK=$wt_bad sourced_orch_script 'wait_block_check' 2>&1)"; st=$?
  assert_status "wait_block_check refuses a block of $wt_bad through die" "$st" 1
  out="$(ORCH_WAIT_BLOCK=$wt_bad sourced_orch_script 'wait_block_check die2' 2>&1)"; st=$?
  assert_status "and through die2" "$st" 2
done
assert_contains "naming the variable" "$out" "ORCH_WAIT_BLOCK"

# The stored total keeps the seconds slept across calls: each call that exits
# 75 stores more, and the next call on the same key reads it back.
rm -rf "${ORCH_DIR_NAME:?}/wait"
wt_lens="$(mktemp -d)"
wt_run() {
  ORCH_SPEC_REVIEW_WAIT_TIMEOUT=100 ORCH_SPEC_REVIEW_WAIT_INTERVAL=0.5 \
    ORCH_WAIT_BLOCK=1.1 "$ORCH" spec-review wait "$wt_lens" fidelity >/dev/null 2>&1
}
wt_run; st=$?
assert_status "a first spec-review wait call exits 75" "$st" 75
wt_file="$(find "$ORCH_DIR_NAME/wait" -type f)"
wt_first="$(sed -n 2p "$wt_file")"
assert_eq "and stores seconds slept above 0" "$(awk -v s="$wt_first" 'BEGIN { print (s > 0) }')" "1"
wt_run; st=$?
assert_status "a second call on the same key exits 75 again" "$st" 75
assert_eq "and stores more seconds slept than the first" \
  "$(awk -v a="$wt_first" -v b="$(sed -n 2p "$wt_file")" 'BEGIN { print (b > a) }')" "1"
