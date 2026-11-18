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
