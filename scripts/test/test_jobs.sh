#!/usr/bin/env bash
#
# Sourced by orch_test.sh, all.sh and affected.sh, so the runners never
# disagree on how much of the machine a test run may use, or on how they stop
# their children when signalled; and by the suites that own a temp root
# (hooks_test.sh, version_bump_test.sh, lens_bench_test.sh), for that stop
# alone. Runs nothing; the job pool below keeps its
# state in TEST_JOBS_* variables of the sourcing shell.
#
# is_positive_integer <value>: true when it is digits only and above zero, so
# `00` is no positive integer either.
#
# test_jobs_require_positive <runner> <name> <value>: true when <value> is a
# positive integer; else prints "<runner>: <name>='<value>' is not a positive
# integer" on stderr and returns 1.
#
# test_jobs_default <runner>: prints the default job count. The usable CPUs are
# the online cores (getconf _NPROCESSORS_ONLN, 4 when that fails), lowered to
# the cgroup v2 quota when one is set and lower: the file holds "<quota>
# <period>", quota/period rounded up; a missing or unreadable file, or a quota
# of "max", means no quota. The default is a share of the usable CPUs, rounded
# down, at least 1: ORCH_TEST_POOL_PERCENT percent (any positive integer,
# normalized to base 10, so 075 is 75), else 75. A set value that is not a
# positive integer prints "<runner>: ORCH_TEST_POOL_PERCENT='<value>' is not a
# positive integer" on stderr and returns 1. Under CI the default is the full
# usable count and the variable is neither read nor validated. The quota file is
# /sys/fs/cgroup/cpu.max unless the test-only ORCH_TEST_CPU_MAX_FILE names
# another.
#
# test_jobs_count <runner>: prints the run's job count - ORCH_TEST_JOBS when
# set, else test_jobs_default (which can fail as above, for the caller to exit
# on) - normalized to base 10. A set value that is not
# a positive integer prints "<runner>: ORCH_TEST_JOBS='<value>' is not a
# positive integer" on stderr and returns 1, for the caller to exit on.
#
# test_jobs_lower_priority: raises the calling shell's niceness to 10 unless CI
# is set, so the processes it starts inherit it. It never stacks: a niceness
# of 10 or more is left alone, and a ps that fails or prints no number means
# no renice. A failing renice is ignored, silently. renice is called with a
# relative increment (-n, with POSIXLY_CORRECT set so util-linux reads -n as
# relative, as macOS always does).
#
# The job pool. Every runner under one home directory draws its parallel jobs
# from one pool of slot lock files, so concurrent runs queue for slots instead
# of oversubscribing the machine. The pool holds test_jobs_default slots (the
# job-count logic is untouched); a slot is held by an flock on its file, which
# the kernel releases when the last process holding the open file dies. The pool
# lives in $HOME/.cache/orchestrator/test-job-pool unless the test-only
# ORCH_TEST_POOL_DIR names another directory.
#
# test_jobs_pool_init <runner>: decides whether this run is pooled, setting
# TEST_JOBS_POOL to the pool directory, or to "" when it runs unpooled: under
# CI, with no HOME and no ORCH_TEST_POOL_DIR, with no flock on PATH, when the
# directory cannot be created, or when ORCH_TEST_POOL_HELD - which a runner sets
# on the children that run under its slot - names this same directory, so a
# nested run takes no slot of its own. <runner> names it in the waiting notice.
# Outside CI an invalid ORCH_TEST_POOL_PERCENT fails it (returns 1) before any
# of those unpooled returns.
#
# test_jobs_slot_take: tries each slot in turn without blocking. Returns 0 with
# TEST_JOBS_SLOT_FD set to the fd holding the slot's lock, or to "" when the run
# is unpooled - including when a slot file cannot be opened or locked, which
# unpools the rest of the run. Returns 1 with TEST_JOBS_IN_USE set when every
# slot is taken.
#
# test_jobs_slot_note: on stderr, "<runner>: waiting for a job slot (N in use)",
# the first time it is called in a run.
#
# test_jobs_slot_wait: takes a slot, noting and polling while none is free.
#
# test_jobs_slot_release <pid>: hands the held slot to a holder process that
# keeps the lock until <pid> has exited, then closes the run's own copy of the
# fd. The job alone keeps the slot: a runner starts the job through
# test_jobs_job, so no process the job leaves running holds the lock after the
# job is gone, and the kernel still frees it should the holder die.
#
# test_jobs_job <cmd>...: closes the slot fd and execs <cmd> in place of the
# calling subshell, so the job's exit status is <cmd>'s. A runner starts every
# job through it, in the background, after test_jobs_slot_wait or
# test_jobs_slot_take, also inside a subshell that changes directory first. It
# never returns, so call it only in such a subshell, never in a runner's
# foreground. The fd number lives in one constant, TEST_JOBS_FD, read through
# eval, so the redirection is built from the constant in one place; no runner
# writes the number. <cmd>
# is an external command.
#
# test_jobs_stop_children <pid>...: a runner's INT/TERM handler. Sends TERM to
# every pid given, waits for each one, and exits 130, so the runner's EXIT trap
# removes its temp directory only once no child can still write into it. A
# child that ignores TERM keeps the runner waiting on it.
#
# test_jobs_descendants [<root pid>]: prints the live (non-zombie) processes
# below <root pid> - this shell when none is given - one pid a line, leaving
# out the command substitution it runs in and what that starts (its ps and awk).
#
# test_jobs_process_table: prints every process as "<pid> <parent pid>
# <state>", one a line, from ps, or from /proc/<pid>/stat on a host with no ps
# (a slim container); with neither it prints nothing.
#
# test_jobs_stop_tree <pid> [below]: sends TERM, once each, to <pid> and every
# live process below it - and what they started, until none is left - and sends
# KILL to any still alive after 5 seconds. A process it has signalled stays in
# its set even if its parent dies and it is orphaned. With the word `below`,
# <pid> itself is left out and only the processes below it are signalled. With
# no process table to read (test_jobs_process_table prints nothing), it signals
# <pid> alone (TERM, then KILL after 5 s), or nothing with `below`.
#
# test_jobs_stop_descendants: a temp-root suite's INT/TERM handler, and a
# sequential orch_test.sh run's: test_jobs_stop_tree $$ below, then exit 130, so
# it never signals its own shell and the EXIT trap removes the temp root only
# once nothing the run started can still write into it, or recreate it.

is_positive_integer() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ]
}

test_jobs_require_positive() {
  is_positive_integer "$3" && return 0
  echo "$1: $2='$3' is not a positive integer" >&2
  return 1
}

test_jobs_default() {
  local cores quota period quota_cpus file usable percent=75 share
  if [ -z "${CI:-}" ] && [ -n "${ORCH_TEST_POOL_PERCENT+set}" ]; then
    test_jobs_require_positive "$1" ORCH_TEST_POOL_PERCENT "$ORCH_TEST_POOL_PERCENT" || return 1
    percent=$((10#$ORCH_TEST_POOL_PERCENT))
  fi
  cores="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
  is_positive_integer "$cores" || cores=4
  cores=$((10#$cores))
  file="${ORCH_TEST_CPU_MAX_FILE:-/sys/fs/cgroup/cpu.max}"
  quota="" period=""
  read -r quota period 2>/dev/null <"$file"
  usable="$cores"
  if is_positive_integer "$quota" && is_positive_integer "$period"; then
    quota_cpus=$(((10#$quota + 10#$period - 1) / 10#$period))
    [ "$quota_cpus" -lt "$usable" ] && usable="$quota_cpus"
  fi
  if [ -n "${CI:-}" ]; then
    echo "$usable"
  else
    share=$((usable * percent / 100))
    echo $((share > 0 ? share : 1))
  fi
}

test_jobs_count() {
  local jobs
  if [ -n "${ORCH_TEST_JOBS+set}" ]; then
    jobs="$ORCH_TEST_JOBS"
  else
    jobs="$(test_jobs_default "$1")" || return 1
  fi
  test_jobs_require_positive "$1" ORCH_TEST_JOBS "$jobs" || return 1
  echo "$((10#$jobs))"
}

test_jobs_lower_priority() {
  local nice
  [ -n "${CI:-}" ] && return 0
  nice="$(ps -o nice= -p "$$" 2>/dev/null)"
  nice="${nice//[[:space:]]/}"
  case "$nice" in '' | *[!0-9-]* | -) return 0 ;; esac
  [ "$nice" -ge 10 ] && return 0
  POSIXLY_CORRECT=1 renice -n "$((10 - nice))" -p "$$" >/dev/null 2>&1
  return 0
}

test_jobs_stop_children() {
  local pid
  kill "$@" 2>/dev/null
  for pid in "$@"; do wait "$pid"; done
  exit 130
}

test_jobs_process_table() {
  local stat line state parent
  if command -v ps >/dev/null 2>&1; then
    ps -A -o pid= -o ppid= -o stat= 2>/dev/null
    return 0
  fi
  for stat in /proc/[0-9]*/stat; do
    read -r line 2>/dev/null <"$stat" || continue
    # The name between the parentheses may hold spaces: fields resume after it.
    read -r state parent _ <<<"${line##*) }"
    echo "${line%% *} $parent $state"
  done
}

test_jobs_descendants() {
  # Read here: inside the pipeline, BASHPID would be the forked element's own.
  local self="$BASHPID"
  test_jobs_process_table |
    awk -v root="${1:-$$}" -v self="$self" '
      { pid[NR] = $1; parent[NR] = $2; zombie[NR] = ($3 ~ /^Z/) }
      END {
        below[root] = 1
        for (grew = 1; grew;) {
          grew = 0
          for (i = 1; i <= NR; i++)
            if (!(pid[i] in below) && pid[i] != self && (parent[i] in below)) {
              below[pid[i]] = 1; grew = 1
            }
        }
        for (i = 1; i <= NR; i++)
          if (pid[i] != root && (pid[i] in below) && !zombie[i]) print pid[i]
      }'
}

test_jobs_stop_tree() {
  local root="$1" below="${2:-}" carried="" sent=" " table walked live pid tick
  [ "$below" = below ] || carried="$root"  # seed carried with the root pid
  for ((tick = 0; tick < 100; tick++)); do
    table="$(test_jobs_process_table)"
    walked="$(test_jobs_descendants "$root")"
    # What was signalled stays in carried, so a process its dead parent
    # orphaned is still stopped.
    if [ -n "$table" ]; then
      live="$(printf '%s\n' "$table" | awk -v want="$walked $carried" '
        BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) w[a[i]] = 1 }
        ($1 in w) && $3 !~ /^Z/ && !($1 in done) { done[$1] = 1; print $1 }')"
    else
      live=""
      for pid in $carried; do kill -0 "$pid" 2>/dev/null && live="$live $pid"; done
    fi
    [ -n "${live// /}" ] || break
    carried=""
    for pid in $live; do
      carried="$carried $pid"
      if [ "$tick" -ge 50 ]; then
        kill -KILL "$pid" 2>/dev/null
      elif [[ "$sent" != *" $pid "* ]]; then
        kill -TERM "$pid" 2>/dev/null
        sent="$sent$pid "
      fi
    done
    sleep 0.1
  done
  return 0
}

test_jobs_stop_descendants() {
  test_jobs_stop_tree $$ below
  exit 130
}

TEST_JOBS_FD=8
TEST_JOBS_POOL=""
TEST_JOBS_SLOTS=0
TEST_JOBS_SLOT_FD=""
TEST_JOBS_IN_USE=0
TEST_JOBS_NOTED=0
TEST_JOBS_RUNNER=""

test_jobs_pool_init() {
  local dir slots
  TEST_JOBS_RUNNER="$1" TEST_JOBS_POOL="" TEST_JOBS_SLOT_FD="" TEST_JOBS_NOTED=0
  [ -n "${CI:-}" ] && return 0
  slots="$(test_jobs_default "$1")" || return 1
  dir="${ORCH_TEST_POOL_DIR:-}"
  if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || return 0
    dir="$HOME/.cache/orchestrator/test-job-pool"
  fi
  [ "${ORCH_TEST_POOL_HELD:-}" = "$dir" ] && return 0
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  TEST_JOBS_SLOTS="$slots"
  TEST_JOBS_POOL="$dir"
}

test_jobs_slot_take() {
  local n rc busy=0
  TEST_JOBS_SLOT_FD="" TEST_JOBS_IN_USE=0
  [ -n "$TEST_JOBS_POOL" ] || return 0
  for ((n = 1; n <= TEST_JOBS_SLOTS; n++)); do
    if ! { eval "exec $TEST_JOBS_FD>>\"\$TEST_JOBS_POOL/slot.\$n\""; } 2>/dev/null; then
      TEST_JOBS_POOL=""
      return 0
    fi
    flock -n -E 100 "$TEST_JOBS_FD" 2>/dev/null
    rc=$?
    case "$rc" in
      0) TEST_JOBS_SLOT_FD="$TEST_JOBS_FD"; return 0 ;;
      100) busy=$((busy + 1)); eval "exec $TEST_JOBS_FD>&-" ;;
      *) eval "exec $TEST_JOBS_FD>&-"; TEST_JOBS_POOL=""; return 0 ;;
    esac
  done
  TEST_JOBS_IN_USE="$busy"
  return 1
}

test_jobs_slot_note() {
  [ "$TEST_JOBS_NOTED" -eq 0 ] || return 0
  TEST_JOBS_NOTED=1
  echo "$TEST_JOBS_RUNNER: waiting for a job slot ($TEST_JOBS_IN_USE in use)" >&2
}

test_jobs_slot_wait() {
  until test_jobs_slot_take; do
    test_jobs_slot_note
    sleep 0.1
  done
}

test_jobs_slot_release() {
  [ -z "$TEST_JOBS_SLOT_FD" ] && return 0
  (
    while kill -0 "$1" 2>/dev/null; do eval "sleep 0.1 $TEST_JOBS_FD>&-"; done
  ) </dev/null >/dev/null 2>&1 &
  eval "exec $TEST_JOBS_FD>&-"
  TEST_JOBS_SLOT_FD=""
}

test_jobs_job() {
  eval "exec $TEST_JOBS_FD>&-"
  exec "$@"
}
