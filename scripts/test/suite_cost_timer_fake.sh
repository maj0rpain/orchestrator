# shellcheck shell=bash
# The in-process half of the ORCH_SUITE_COST_TIMER seam.
#
# Sourced into orch.sh's own process via ORCH_SUITE_COST_TIMER, this redefines
# the one step of the suite-cost module that times a command,
# suite_cost_measure. The command still runs for real, its stdout, stderr and
# exit code passed through as the real step passes them; only the CPU and wall
# seconds it reports come from here, so no verdict a test asserts depends on
# the machine's speed or load.
#
# The seconds are keyed by commit: ORCH_SUITE_COST_FAKE_CPU names a file of
# "<sha> <cpu>" lines a test writes, and a run on <sha> - HEAD of the directory
# it runs in, a base or confirming run's worktree included - reports the <cpu>
# of the last line naming <sha>, as written, and 1.00 wall seconds. A run on a
# commit the file names nowhere is a test's mistake: it says so on stderr and
# exits 99, so a check reads it as a failed run.

# shellcheck disable=SC2034 # the SUITE_COST_* results are read by the module that sources this
suite_cost_measure() {
  local sha cpu
  SUITE_COST_STATUS=0
  command "$@" || SUITE_COST_STATUS=$?
  sha="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
  cpu="$(awk -v s="$sha" '$1 == s { c = $2 } END { print c }' "${ORCH_SUITE_COST_FAKE_CPU:-/dev/null}")"
  if [ -z "$cpu" ]; then
    printf 'suite-cost timer fake: no CPU seconds written for %s\n' "${sha:-<no commit>}" >&2
    SUITE_COST_STATUS=99 cpu=0.00
  fi
  SUITE_COST_CPU="$cpu" SUITE_COST_WALL=1.00
}
