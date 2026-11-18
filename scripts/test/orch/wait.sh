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

# wt_seconds: the epoch second now.
wt_seconds() { printf '%(%s)T\n' -1; }

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
wt_start="$(wt_seconds)"
PATH="$wt_awk:$PATH" ORCH_WAIT_BLOCK=2 "$ORCH" verification run "$wt_cmd" >/dev/null 2>&1; st=$?
wt_took=$(( $(wt_seconds) - wt_start ))
assert_status "verification run with slow polls still exits 75" "$st" 75
assert_eq "and ends within the wall-clock block, not the summed sleep" \
  "$([ "$wt_took" -le 4 ] && echo yes || echo "no (${wt_took}s)")" "yes"
: >"$wt_dir/gate"

wt_lens="$(mktemp -d)"
wt_start="$(wt_seconds)"
PATH="$wt_awk:$PATH" ORCH_SPEC_REVIEW_WAIT_TIMEOUT=100 ORCH_SPEC_REVIEW_WAIT_INTERVAL=0.2 \
  ORCH_WAIT_BLOCK=2 "$ORCH" spec-review wait "$wt_lens" fidelity >/dev/null 2>&1; st=$?
wt_took=$(( $(wt_seconds) - wt_start ))
assert_status "spec-review wait with slow polls still exits 75" "$st" 75
assert_eq "and ends within the wall-clock block too" \
  "$([ "$wt_took" -le 4 ] && echo yes || echo "no (${wt_took}s)")" "yes"

# A call never sleeps past its block: the sleep is clamped to what is left, and
# a call whose sleep spent the block exits 75 without another turn.
wt_lens="$(mktemp -d)"
wt_start="$(wt_seconds)"
ORCH_SPEC_REVIEW_WAIT_TIMEOUT=100 ORCH_SPEC_REVIEW_WAIT_INTERVAL=6 \
  ORCH_WAIT_BLOCK=0.5 "$ORCH" spec-review wait "$wt_lens" fidelity >/dev/null 2>&1; st=$?
wt_took=$(( $(wt_seconds) - wt_start ))
assert_status "spec-review wait with an interval past the block exits 75" "$st" 75
assert_eq "and ends within the block, not a whole interval after it" \
  "$([ "$wt_took" -le 3 ] && echo yes || echo "no (${wt_took}s)")" "yes"

# A rate limit the block could not hold (gh_limit_handle's mark) ends the poll
# loop's call as still running, total kept; with no mark, the loop goes on.
wt_wf="$(mktemp)"
printf '1\n0\n' >"$wt_wf"
sourced_orch_script 'WAIT_FILE=$1; WAIT_START=1; wait_limited_check 0' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with no mark, wait_limited_check goes on" "$st" 0
: >"$wt_wf.limited"
sourced_orch_script 'WAIT_FILE=$1; WAIT_START=1; wait_limited_check 0' "$wt_wf" >/dev/null 2>&1; st=$?
assert_status "with the mark, it ends the call as still running" "$st" 75
assert_eq "keeps the stored total" "$(sed -n 1p "$wt_wf")" "1"
assert_status "and consumes the mark" "$([ -e "$wt_wf.limited" ]; echo $?)" 1
rm -f "$wt_wf"
