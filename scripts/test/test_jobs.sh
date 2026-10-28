#!/usr/bin/env bash
#
# Sourced by orch_test.sh and all.sh, so the two runners never disagree on how
# much of the machine a test run may use, or on how they stop their children
# when signalled. Defines no state and runs nothing.
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
