#!/usr/bin/env bash
#
# Sourced by orch_test.sh, all.sh and affected.sh, so the runners never
# disagree on how much of the machine a test run may use, or on how they stop
# their children when signalled. Runs nothing; the job pool below keeps its
# state in TEST_JOBS_* variables of the sourcing shell.
#
# is_positive_integer <value>: true when it is digits only and above zero, so
# `00` is no positive integer either.
#
# test_jobs_default: prints the default job count. The usable CPUs are the
# online cores (getconf _NPROCESSORS_ONLN, 4 when that fails), lowered to the
# cgroup v2 quota when one is set and lower: the file holds "<quota> <period>",
# quota/period rounded up; a missing or unreadable file, or a quota of "max",
# means no quota. The default is half the usable CPUs, rounded down, at least
# 1; under CI it is the full usable count. The quota file is
# /sys/fs/cgroup/cpu.max unless the test-only ORCH_TEST_CPU_MAX_FILE names
# another.
#
# test_jobs_count <runner>: prints the run's job count - ORCH_TEST_JOBS when
# set, else test_jobs_default - normalized to base 10. A set value that is not
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
# test_jobs_slot_release: closes the run's copy of the held fd, once the child
# that inherited it has started. The lock lasts as long as any copy is open.
#
# test_jobs_stop_children <pid>...: a runner's INT/TERM handler. Sends TERM to
# every pid given, waits for each one, and exits 130, so the runner's EXIT trap
# removes its temp directory only once no child can still write into it. A
# child that ignores TERM keeps the runner waiting on it.

is_positive_integer() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ]
}

test_jobs_default() {
  local cores quota period quota_cpus file usable
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
    echo $((usable / 2 > 0 ? usable / 2 : 1))
  fi
}

test_jobs_count() {
  local jobs
  if [ -n "${ORCH_TEST_JOBS+set}" ]; then
    jobs="$ORCH_TEST_JOBS"
  else
    jobs="$(test_jobs_default)"
  fi
  if ! is_positive_integer "$jobs"; then
    echo "$1: ORCH_TEST_JOBS='$jobs' is not a positive integer" >&2
    return 1
  fi
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

TEST_JOBS_POOL=""
TEST_JOBS_SLOTS=0
TEST_JOBS_SLOT_FD=""
TEST_JOBS_IN_USE=0
TEST_JOBS_NOTED=0
TEST_JOBS_RUNNER=""

test_jobs_pool_init() {
  local dir
  TEST_JOBS_RUNNER="$1" TEST_JOBS_POOL="" TEST_JOBS_SLOT_FD="" TEST_JOBS_NOTED=0
  [ -n "${CI:-}" ] && return 0
  dir="${ORCH_TEST_POOL_DIR:-}"
  if [ -z "$dir" ]; then
    [ -n "${HOME:-}" ] || return 0
    dir="$HOME/.cache/orchestrator/test-job-pool"
  fi
  [ "${ORCH_TEST_POOL_HELD:-}" = "$dir" ] && return 0
  command -v flock >/dev/null 2>&1 || return 0
  mkdir -p "$dir" 2>/dev/null || return 0
  TEST_JOBS_SLOTS="$(test_jobs_default)"
  TEST_JOBS_POOL="$dir"
}

test_jobs_slot_take() {
  local n rc busy=0
  TEST_JOBS_SLOT_FD="" TEST_JOBS_IN_USE=0
  [ -n "$TEST_JOBS_POOL" ] || return 0
  for ((n = 1; n <= TEST_JOBS_SLOTS; n++)); do
    if ! { exec 8>>"$TEST_JOBS_POOL/slot.$n"; } 2>/dev/null; then
      TEST_JOBS_POOL=""
      return 0
    fi
    flock -n -E 100 8 2>/dev/null
    rc=$?
    case "$rc" in
      0) TEST_JOBS_SLOT_FD=8; return 0 ;;
      100) busy=$((busy + 1)); exec 8>&- ;;
      *) exec 8>&-; TEST_JOBS_POOL=""; return 0 ;;
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
  exec 8>&-
  TEST_JOBS_SLOT_FD=""
}
