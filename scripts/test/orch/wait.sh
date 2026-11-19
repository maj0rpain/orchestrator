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
# loop's call as still running, total kept; with no mark, the loop goes on.
wt_wf="$(mktemp)"
printf '1\n0\n' >"$wt_wf"
sourced_orch_script 'WAIT_FILE=$1; WAIT_START=1; WAIT_SLEPT=0; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with no mark, wait_limited_check goes on" "$st" 0
: >"$wt_wf.limited"
sourced_orch_script 'WAIT_FILE=$1; WAIT_START=1; WAIT_SLEPT=7; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with the mark, it ends the call as still running" "$st" 75
assert_eq "keeps the stored start" "$(sed -n 1p "$wt_wf")" "1"
assert_eq "stores the seconds slept" "$(sed -n 2p "$wt_wf")" "7"
assert_status "and consumes the mark" "$([ -e "$wt_wf.limited" ]; echo $?)" 1
rm -f "$wt_wf"

# wait_limit_fits: the Wait module's decision on a limit wait (the mark is its)
wt_wf="$(mktemp)"
sourced_orch_script 'unset WAIT_FILE; wait_limit_fits 60' >/dev/null 2>&1; st=$?
assert_status "wait_limit_fits with no wait open fits" "$st" 0
sourced_orch_script 'WAIT_FILE=$1; ORCH_WAIT_BLOCK=570; wait_limit_fits 1' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "a block that can hold the wait fits" "$st" 0
assert_status "and leaves no mark" "$([ -e "$wt_wf.limited" ]; echo $?)" 1
sourced_orch_script 'WAIT_FILE=$1; WAIT_START=1; WAIT_SLEPT=0; ORCH_WAIT_BLOCK=0; wait_limit_fits 60 && exit 9; wait_limited_check' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "a block that cannot hold it does not fit, and wait_limited_check ends the call as still running" "$st" 75
rm -f "$wt_wf" "$wt_wf.limited"

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

# --- wait: block naps start no awk far from the block's end ----------------
# A waiting call, and a grace wait inside it, start no awk on a turn while the
# block is far from spent (wait_block_nap's fast path); a sub-second block still
# ends in exit 75 on time (the section above).
echo
echo "wait: block naps start no awk far from the block's end"
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
  counting_starts "$bn_awk" awk
}
bn_gone="$(bn_stop 0)"
bn_slow="$(bn_stop 2)"
assert_eq "a grace wait over a group that lasts a second starts no more awk than one over a gone group" \
  "$(( bn_slow <= bn_gone ))" "1"

# verification_wait_state: a record with no state past its grace is given up on
# at once, never exit 75 under a long block; with its state it is waited for
# no more.
bn_rec="$(mktemp -d)"
printf '%s\n' "$(( $(printf '%(%s)T' -1) - 10 ))" >"$bn_rec/waiting"
ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=1 sourced_orch_script \
  "orch_load verification; verification_wait_state '$bn_rec'" >/dev/null 2>&1; st=$?
assert_status "a record with no state and a 10 s old mark is given up on at once" "$st" 1
: >"$bn_rec/state"
ORCH_WAIT_BLOCK=60 ORCH_VERIFICATION_GRACE=1 sourced_orch_script \
  "orch_load verification; verification_wait_state '$bn_rec'" >/dev/null 2>&1; st=$?
assert_status "a record with its state returns 0" "$st" 0
rm -rf "$bn_rec"
