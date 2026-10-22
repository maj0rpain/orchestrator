# shellcheck shell=bash
# suite-cost.sh - orch.sh's suite-cost command: the suite cost of each passing
# verification run, recorded clone-wide.
# Its tests: scripts/test/orch/suite-cost.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.
#
# The record is one file under the clone's git common directory, so the main
# checkout, side checkouts and ticket worktrees share it, and it is per machine
# by construction. Its line format is the record's documented interface: five
# tab-separated fields - the full SHA of HEAD when the run started, suffixed
# -dirty (the git describe --dirty convention) when git status --porcelain
# printed anything then, untracked files counting and ignored paths not, the CPU
# seconds (user plus system, children included), the wall seconds, both to two
# places, the UTC time in ISO 8601, and the command, its words joined by single
# spaces. history prints it as written, and the tests seed it.
#
# Only a run no other suite-cost run overlapped is recorded. Beside the record,
# the active-runs directory suite-cost.active holds one marker per measured run
# in progress - suite-cost run, or check's base run - a file named by the pid
# of the orch.sh process measuring it; its contended mark is a sibling file
# <pid>.contended. A run first removes its own pid's .contended file, left by
# an earlier run of the same process, then creates its marker, then lists the
# others: it marks each other live one contended, and itself when there was
# any. On finish it was overlapped when its .contended file exists, or when it
# saw another live marker at start, and it removes its marker and .contended
# file either way. A marker or .contended file whose pid names no live process
# is stale: no contention, and removed by the run that finds it. A failed
# .contended write for another run is not retried, and a failed removal is
# ignored. A run that cannot register still runs but is not recorded. No run
# ever waits for another.

SUITE_COST_RUN_USAGE="usage: orch.sh suite-cost run -- <cmd> [args...]"
SUITE_COST_CHECK_USAGE="usage: orch.sh suite-cost check -- <cmd> [args...]"

# check's defaults, read here alone: below the floor (CPU seconds) a baseline
# is compared with nothing, and growth past the threshold (percent) is a
# finding. Set per clone with git config orchestrator.suiteCost.floor and
# orchestrator.suiteCost.growth. A third per-clone key,
# orchestrator.suiteCost.setup, has no default: the install command (npm ci,
# uv sync) a base run runs first in its worktree, read by suite_cost_base_run.
SUITE_COST_FLOOR_DEFAULT=60
SUITE_COST_GROWTH_DEFAULT=15

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

# suite_cost_active: prints the path of the clone's active-runs directory,
# suite-cost.active beside the record.
suite_cost_active() {
  local rec
  rec="$(suite_cost_record)" || return 1
  printf '%s.active\n' "$rec"
}

# suite_cost_register: registers this orch.sh process's run as active, before
# it is measured, and sets SUITE_COST_MARK to its marker's path, empty when it
# could not register, and SUITE_COST_SAW to 1 when another live run's marker
# was present, else 0. Stale markers and .contended files it finds are removed.
suite_cost_register() {
  local dir me f p
  SUITE_COST_MARK="" SUITE_COST_SAW=0
  dir="$(suite_cost_active 2>/dev/null)" || return 0
  me="$dir/$$"
  rm -f -- "$me.contended" 2>/dev/null || true
  { mkdir -p -- "$dir" && : >"$me"; } 2>/dev/null || return 0
  SUITE_COST_MARK="$me"
  for f in "$dir"/*; do
    p="${f##*/}"
    p="${p%.contended}"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" != "$$" ] || continue
    if ! kill -0 "$p" 2>/dev/null; then
      rm -f -- "$f" 2>/dev/null || true
    elif [ "$f" = "$dir/$p" ]; then
      SUITE_COST_SAW=1
      : 2>/dev/null >"$f.contended" || true
    fi
  done
  [ "$SUITE_COST_SAW" -eq 0 ] || : 2>/dev/null >"$me.contended" || true
}

# suite_cost_unregister: ends the run suite_cost_register began, removing its
# marker and .contended file, and sets SUITE_COST_SOLO to solo, overlapped
# (its .contended file existed, or it saw another live run at start) or
# unregistered (it never had a marker).
suite_cost_unregister() {
  if [ -z "$SUITE_COST_MARK" ]; then
    SUITE_COST_SOLO=unregistered
    return 0
  fi
  SUITE_COST_SOLO=solo
  if [ "$SUITE_COST_SAW" -eq 1 ] || [ -e "$SUITE_COST_MARK.contended" ]; then
    SUITE_COST_SOLO=overlapped
  fi
  rm -f -- "$SUITE_COST_MARK" "$SUITE_COST_MARK.contended" 2>/dev/null || true
  SUITE_COST_MARK=""
}

# suite_cost_run <cmd> [args...]: runs the command in the current directory,
# its stdout, stderr and exit code passed through, and on exit 0 appends its
# record line, its commit <sha>-dirty when the tree had changes as it started -
# unless another suite-cost run overlapped it, or it could not register as
# active, either of which it warns of. Exits with the command's own status.
suite_cost_run() {
  local sha
  sha="$(git rev-parse --verify -q HEAD 2>/dev/null || true)"
  if [ -n "$sha" ] && [ -n "$(git status --porcelain 2>/dev/null)" ]; then
    sha="$sha-dirty"
  fi
  suite_cost_register
  suite_cost_measure "$@"
  suite_cost_unregister
  if [ "$SUITE_COST_SOLO" = unregistered ]; then
    warn "this run could not register as active - its suite cost is not recorded"
  elif [ "$SUITE_COST_SOLO" = overlapped ]; then
    warn "this run overlapped another suite-cost run - its suite cost is not recorded"
  elif [ "$SUITE_COST_STATUS" -eq 0 ]; then
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

# suite_cost_newest <rec> <cmd-string> <pred>: prints the CPU seconds and
# commit, tab-separated, of the newest record line of <cmd-string> whose commit
# passes <pred> (a function given the commit), or fails printing nothing.
suite_cost_newest() {
  local rec="$1" want="$2" pred="$3" sha cpu cmd
  [ -e "$rec" ] || return 1
  while IFS=$'\t' read -r sha cpu _ _ cmd; do
    [ "$cmd" = "$want" ] || continue
    if "$pred" "$sha"; then printf '%s\t%s\n' "$cpu" "$sha"; return 0; fi
  done < <(awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$rec")
  return 1
}

# suite_cost_lowest <rec> <cmd-string> <commit>: prints the lowest CPU seconds
# among the record lines of <cmd-string> whose commit field is <commit>
# exactly, so a <sha>-dirty line and a <sha> one are never pooled, or prints
# nothing when there is none.
suite_cost_lowest() {
  [ -e "$1" ] || return 0
  LC_ALL=C awk -F'\t' -v want="$2" -v sha="$3" '
    $1 == sha && $5 == want && (n++ == 0 || $2 + 0 < low + 0) { low = $2 }
    END { if (n) print low }' "$1"
}

# The head's records: a clean one whose commit is HEAD or an ancestor of it,
# but not the base commit nor an ancestor of it - so a run recorded just before
# its commit still counts - or a dirty one whose commit is HEAD or any ancestor
# of it, the base commit and its ancestors included, so a run made before a
# ticket's first commit counts. Local to suite_cost_check in effect: it reads
# the base commit, base_commit, from that call's locals, through bash's
# dynamic scope.
suite_cost_is_head() {
  case "$1" in
    *-dirty) git merge-base --is-ancestor "${1%-dirty}" HEAD 2>/dev/null ;;
    *)
      git merge-base --is-ancestor "$1" HEAD 2>/dev/null &&
        ! git merge-base --is-ancestor "$1" "$base_commit" 2>/dev/null
      ;;
  esac
}
# The baseline's records: clean ones alone, never a dirty one, whose commit is
# the base commit or an ancestor of it. Local to suite_cost_check in effect,
# reading its base_commit as suite_cost_is_head does.
suite_cost_is_base() {
  case "$1" in
    *-dirty) return 1 ;;
    *) git merge-base --is-ancestor "$1" "$base_commit" 2>/dev/null ;;
  esac
}

# suite_cost_check <cmd> [args...]: prints one verdict line - off, ok,
# grew <pct> - <finding text>, or unmeasured - comparing the head's lowest
# sample of the command with the baseline's: the lowest CPU seconds on the
# commit of the newest head record, and on that of the newest baseline record.
# The knobs are validated first, so
# a bad one dies before anything runs; the command runs only to measure a base
# with no recorded ancestor, never on the head.
suite_cost_check() {
  local floor growth rec want base_commit head_cpu base_cpu base_sha head_found base_found pct IFS=' '
  floor="$(suite_cost_knob orchestrator.suiteCost.floor "$SUITE_COST_FLOOR_DEFAULT")" || exit 1
  growth="$(suite_cost_knob orchestrator.suiteCost.growth "$SUITE_COST_GROWTH_DEFAULT")" || exit 1
  rec="$(suite_cost_record)" || exit 1
  want="$*"
  base_commit="$(suite_cost_base_commit)" || { note unmeasured; return 0; }
  head_found="$(suite_cost_newest "$rec" "$want" suite_cost_is_head)" ||
    { note unmeasured; return 0; }
  head_cpu="$(suite_cost_lowest "$rec" "$want" "${head_found#*$'\t'}")"
  if base_found="$(suite_cost_newest "$rec" "$want" suite_cost_is_base)"; then
    base_sha="${base_found#*$'\t'}"
    base_cpu="$(suite_cost_lowest "$rec" "$want" "$base_sha")"
  else
    suite_cost_base_run "$base_commit" "$@" || { note unmeasured; return 0; }
    base_cpu="$SUITE_COST_CPU" base_sha="$base_commit"
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
# happened. The worktree holds only tracked files, so git config
# orchestrator.suiteCost.setup, when set and non-empty, runs there first with
# bash -c, untimed and its output on stderr; a failing setup measures nothing.
# The run is registered as active from its setup to its end, and a passing run
# another suite-cost run overlapped, or that could not register, is not
# recorded and fails, warning which.
# With no setup, a run exiting 127 names that key. Succeeds, SUITE_COST_CPU set, only when the run passed solo and the
# worktree is gone; a failed removal after a pass keeps the record and names
# the left-over worktree.
suite_cost_base_run() {
  local base="$1" tmp wt here="$PWD" status=0 setup setup_status=0
  shift
  tmp="$(mktemp -d)" || { warn "could not make a temp directory for the base run"; return 1; }
  wt="$tmp/base"
  if ! git worktree add -q --detach "$wt" "$base" >/dev/null 2>&1; then
    warn "could not add a worktree at base commit $base - the suite cost is unmeasured"
    rm -rf "$tmp"
    return 1
  fi
  setup="$(git config --get orchestrator.suiteCost.setup 2>/dev/null || true)"
  if cd "$wt"; then
    suite_cost_register
    [ -z "$setup" ] || bash -c "$setup" >&2 || setup_status=$?
    [ "$setup_status" -ne 0 ] || suite_cost_measure "$@" >&2
    suite_cost_unregister
    cd "$here" || die "could not return to $here"
    if [ "$setup_status" -eq 0 ] && [ "$SUITE_COST_STATUS" -eq 0 ] && [ "$SUITE_COST_SOLO" = solo ]; then
      suite_cost_append "$base" "$SUITE_COST_CPU" "$SUITE_COST_WALL" "$@"
    elif [ "$setup_status" -eq 0 ] && [ "$SUITE_COST_STATUS" -eq 0 ]; then
      status=1
      if [ "$SUITE_COST_SOLO" = unregistered ]; then
        warn "the base run at $base could not register as active - the suite cost is unmeasured"
      else
        warn "the base run at $base overlapped another suite-cost run - the suite cost is unmeasured"
      fi
    else
      status=1
      if [ "$setup_status" -ne 0 ]; then
        warn "the base run's setup ($setup) at $base exited $setup_status - the suite cost is unmeasured"
      elif [ "$SUITE_COST_STATUS" -eq 127 ] && [ -z "$setup" ]; then
        warn "the base run at $base exited 127 (command not found) - the base worktree holds only tracked files; if the command needs installed dependencies, set git config orchestrator.suiteCost.setup '<install command>'"
      else
        warn "the base run at $base exited $SUITE_COST_STATUS - the suite cost is unmeasured"
      fi
    fi
  else
    status=1
  fi
  if git worktree remove --force "$wt" >/dev/null 2>&1; then
    rmdir "$tmp" 2>/dev/null || true
  else
    warn "could not remove the base run's worktree $wt - remove it with: git worktree remove --force $wt"
    status=1
  fi
  return "$status"
}
