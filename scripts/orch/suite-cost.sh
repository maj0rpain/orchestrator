# shellcheck shell=bash
# suite-cost.sh - orch.sh's suite-cost command: the suite cost of each passing
# verification run, recorded clone-wide.
# Its tests: scripts/test/orch/suite-cost.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.
#
# The record is one file under the clone's git common directory, so the main
# checkout, side checkouts and ticket worktrees share it, and it is per machine
# by construction. Its line format is the record's documented interface: five
# tab-separated fields - the full SHA of HEAD when the run started, the CPU
# seconds (user plus system, children included), the wall seconds, both to two
# places, the UTC time in ISO 8601, and the command, its words joined by single
# spaces. history prints it as written, and the tests seed it.

SUITE_COST_RUN_USAGE="usage: orch.sh suite-cost run -- <cmd> [args...]"

cmd_suite_cost() {
  local op="${1:-}"
  shift || true
  case "$op" in
    run)
      [ "${1:-}" = "--" ] && [ $# -ge 2 ] || die "$SUITE_COST_RUN_USAGE"
      shift
      suite_cost_run "$@"
      ;;
    check) die "suite-cost check is not built yet (#1305)" ;;
    history)
      [ $# -eq 0 ] || die "usage: orch.sh suite-cost history"
      suite_cost_history
      ;;
    *) die "unknown suite-cost op: ${op:-<none>} (want run, check or history)" ;;
  esac
}

# suite_cost_record: prints the path of the clone's record, under the git
# common directory, made absolute so it holds wherever the caller runs.
suite_cost_record() {
  local d
  d="$(git rev-parse --git-common-dir)" && d="$(cd "$d" && pwd -P)" ||
    die "could not find the clone's git common directory"
  printf '%s/orchestrator/suite-cost\n' "$d"
}

# suite_cost_run <cmd> [args...]: runs the command in the current directory,
# its stdout, stderr and exit code passed through, and on exit 0 appends its
# record line. Exits with the command's own status.
suite_cost_run() {
  local sha
  sha="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
  suite_cost_measure "$@"
  if [ "$SUITE_COST_STATUS" -eq 0 ]; then
    if [ -n "$sha" ]; then
      suite_cost_append "$sha" "$SUITE_COST_CPU" "$SUITE_COST_WALL" "$@"
    else
      warn "HEAD names no commit - this run's suite cost is not recorded"
    fi
  fi
  exit "$SUITE_COST_STATUS"
}

# suite_cost_measure <cmd> [args...]: runs the command once, its stdout,
# stderr and exit code passed through, and sets SUITE_COST_STATUS to its exit
# code, SUITE_COST_CPU to its CPU seconds (user plus system, children
# included) and SUITE_COST_WALL to its wall seconds, both to two places.
# Measured by bash's own time keyword and TIMEFORMAT, so no GNU-only time is
# needed: the report goes to a temp file while the command's stderr goes
# through fd 3 to the caller's. `command` keeps it off orch.sh's own functions.
suite_cost_measure() {
  local tf real user sys TIMEFORMAT='%2R %2U %2S'
  SUITE_COST_STATUS=0
  tf="$(mktemp)" || die "could not make a temp file to time the command"
  { time { command "$@" 2>&3 3>&- || SUITE_COST_STATUS=$?; }; } 3>&2 2>"$tf"
  read -r real user sys < <(tail -n 1 "$tf") || true
  rm -f "$tf"
  # A locale may write the decimal point as a comma.
  SUITE_COST_WALL="${real/,/.}"
  SUITE_COST_CPU="$(LC_ALL=C awk -v u="${user/,/.}" -v s="${sys/,/.}" 'BEGIN { printf "%.2f", u + s }')"
}

# suite_cost_append <sha> <cpu> <wall> <cmd> [args...]: appends one record
# line, making the record's directory when missing. An append that fails
# warns and records nothing, returning 0: the run it measured stands.
suite_cost_append() {
  local sha="$1" cpu="$2" wall="$3" rec IFS=' '
  shift 3
  rec="$(suite_cost_record)"
  if ! { mkdir -p "${rec%/*}" &&
    printf '%s\t%s\t%s\t%s\t%s\n' "$sha" "$cpu" "$wall" "$(now)" "$*" >>"$rec"; } 2>/dev/null; then
    warn "could not append to the suite-cost record $rec - this run's suite cost is not recorded"
  fi
  return 0
}

# suite_cost_history: prints the record's lines oldest first, as written, or
# nothing when there is no record.
suite_cost_history() {
  local rec
  rec="$(suite_cost_record)"
  [ ! -e "$rec" ] || cat -- "$rec" || die "could not read the suite-cost record $rec"
}
