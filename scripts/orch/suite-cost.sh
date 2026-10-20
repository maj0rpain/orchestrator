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
SUITE_COST_CHECK_USAGE="usage: orch.sh suite-cost check -- <cmd> [args...]"

# check's defaults, read here alone: below the floor (CPU seconds) a baseline
# is compared with nothing, and growth past the threshold (percent) is a
# finding. Set per clone with git config orchestrator.suiteCost.floor and
# orchestrator.suiteCost.growth.
SUITE_COST_FLOOR_DEFAULT=60
SUITE_COST_GROWTH_DEFAULT=10

cmd_suite_cost() {
  local op="${1:-}"
  shift || true
  case "$op" in
    run)
      [ "${1:-}" = "--" ] && [ $# -ge 2 ] || die "$SUITE_COST_RUN_USAGE"
      shift
      suite_cost_run "$@"
      ;;
    check)
      [ "${1:-}" = "--" ] && [ $# -ge 2 ] || die "$SUITE_COST_CHECK_USAGE"
      shift
      suite_cost_check "$@"
      ;;
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

# suite_cost_knob <key> <default>: prints git config <key>, else <default>,
# dying unless it is a non-negative number - read as parallel show reads
# orchestrator.parallel.
suite_cost_knob() {
  local v
  v="$(git config --get "$1" 2>/dev/null || true)"
  [ -n "$v" ] || v="$2"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] ||
    die "$1 is $v - it must be a non-negative number (git config $1 <n>)"
  note "$v"
}

# suite_cost_base_commit: prints the base commit - state.base_sha inside a
# flow, else what branch base-sha prints - or fails, its reason on stderr.
suite_cost_base_commit() {
  local sha=""
  ! flow_active || sha="$(state_get base_sha)"
  if [ -z "$sha" ]; then
    sha="$(cmd_branch_base_sha)" || return 1
  fi
  git rev-parse --verify -q "$sha^{commit}" ||
    { warn "base commit $sha names no commit"; return 1; }
}

# suite_cost_newest <rec> <cmd-string> <test>: prints the CPU seconds and
# commit, tab-separated, of the newest record line of <cmd-string> whose commit
# passes <test> (a function given the commit), or fails printing nothing.
suite_cost_newest() {
  local rec="$1" want="$2" test="$3" sha cpu cmd
  [ -e "$rec" ] || return 1
  while IFS=$'\t' read -r sha cpu _ _ cmd; do
    [ "$cmd" = "$want" ] || continue
    if "$test" "$sha"; then printf '%s\t%s\n' "$cpu" "$sha"; return 0; fi
  done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$rec")
  return 1
}

# The head's commits: HEAD or an ancestor of it, but not the base commit nor
# an ancestor of it - so a run recorded just before its commit still counts.
suite_cost_is_head() {
  git merge-base --is-ancestor "$1" HEAD 2>/dev/null &&
    ! git merge-base --is-ancestor "$1" "$SUITE_COST_BASE" 2>/dev/null
}
# The baseline's commits: the base commit or an ancestor of it.
suite_cost_is_base() { git merge-base --is-ancestor "$1" "$SUITE_COST_BASE" 2>/dev/null; }

# suite_cost_check <cmd> [args...]: prints one verdict line - off, ok,
# grew <pct> - <finding text>, or unmeasured - comparing the head's newest
# record of the command with the baseline's. The knobs are validated first, so
# a bad one dies before anything runs; the command runs only to measure a base
# with no recorded ancestor, never on the head.
suite_cost_check() {
  local floor growth rec want head_cpu base_cpu base_sha found pct IFS=' '
  floor="$(suite_cost_knob orchestrator.suiteCost.floor "$SUITE_COST_FLOOR_DEFAULT")" || exit 1
  growth="$(suite_cost_knob orchestrator.suiteCost.growth "$SUITE_COST_GROWTH_DEFAULT")" || exit 1
  rec="$(suite_cost_record)" || exit 1
  want="$*"
  SUITE_COST_BASE="$(suite_cost_base_commit)" || { note unmeasured; return 0; }
  found="$(suite_cost_newest "$rec" "$want" suite_cost_is_head)" ||
    { note unmeasured; return 0; }
  head_cpu="${found%%$'\t'*}"
  if found="$(suite_cost_newest "$rec" "$want" suite_cost_is_base)"; then
    base_cpu="${found%%$'\t'*}" base_sha="${found#*$'\t'}"
  else
    suite_cost_base_run "$SUITE_COST_BASE" "$@" || { note unmeasured; return 0; }
    base_cpu="$SUITE_COST_CPU" base_sha="$SUITE_COST_BASE"
  fi
  # A zero baseline, possible only with a zero floor, has no growth to measure.
  if float_lt "$base_cpu" "$floor" || ! float_lt 0 "$base_cpu"; then
    note off
    return 0
  fi
  pct="$(LC_ALL=C awk -v h="$head_cpu" -v b="$base_cpu" -v g="$growth" \
    'BEGIN { p = (h - b) / b * 100; if (p > g) printf "%.0f", p }')"
  if [ -z "$pct" ]; then
    note ok
  else
    note "grew $pct - suite cost grew ${pct}% past the ${growth}% threshold: $head_cpu CPU seconds at the head against $base_cpu at baseline commit $base_sha"
  fi
}

# suite_cost_base_run <base> <cmd> [args...]: measures the command once in a
# temporary detached worktree at <base>, its output sent to stderr so check's
# stdout stays its verdict, records a pass, and removes the worktree whatever
# happened. Succeeds, SUITE_COST_CPU set, only when the run passed and the
# worktree is gone; a failed removal after a pass keeps the record and names
# the left-over worktree.
suite_cost_base_run() {
  local base="$1" tmp wt here="$PWD" ok=0
  shift
  tmp="$(mktemp -d)" || { warn "could not make a temp directory for the base run"; return 1; }
  wt="$tmp/base"
  if ! git worktree add -q --detach "$wt" "$base" >/dev/null 2>&1; then
    warn "could not add a worktree at base commit $base - the suite cost is unmeasured"
    rm -rf "$tmp"
    return 1
  fi
  if cd "$wt"; then
    suite_cost_measure "$@" >&2
    cd "$here" || die "could not return to $here"
    if [ "$SUITE_COST_STATUS" -eq 0 ]; then
      suite_cost_append "$base" "$SUITE_COST_CPU" "$SUITE_COST_WALL" "$@"
    else
      warn "the base run at $base exited $SUITE_COST_STATUS - the suite cost is unmeasured"
      ok=1
    fi
  else
    ok=1
  fi
  if git worktree remove --force "$wt" >/dev/null 2>&1; then
    rmdir "$tmp" 2>/dev/null || true
  else
    warn "could not remove the base run's worktree $wt - remove it with: git worktree remove --force $wt"
    ok=1
  fi
  return "$ok"
}
