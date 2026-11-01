# shellcheck shell=bash
# liveness.sh - the Liveness module, a concept module with no noun: whether
# the process behind an autopilot flow's claim on this host is still running.
# It owns the autopilot directory's run/ layout (run/<issue>.pid, the run
# record, and run/<issue>.tick, the tick's record), the `<pid> <start-time>`
# record format, the start-time reader (/proc/<pid>/stat field 22 under
# $ORCH_PROC_DIR, else `ps -o lstart=`), the record-alive rule, the watch
# pidfile and the session log naming (logs/<issue>-<phase>-<stamp>.log). Of
# orch.sh's files only this one touches /proc, ps and run/. Its tests:
# scripts/test/orch/liveness.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# liveness_proc_start <pid>: the process's start time as one whitespace-free
# token. Fails when unreadable.
liveness_proc_start() {
  local pid="$1" root="${ORCH_PROC_DIR:-/proc}" stat rest t
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  if [ -r "$root/$pid/stat" ]; then
    stat="$(cat "$root/$pid/stat" 2>/dev/null)" || stat=""
    rest="${stat##*) }"
    # shellcheck disable=SC2086
    set -- $rest
    # after the command name, field 22 is the 20th word
    [ -n "${20:-}" ] || return 1
    printf '%s\n' "${20}"
    return 0
  fi
  t="$(ps -o lstart= -p "$pid" 2>/dev/null)" || return 1
  t="$(printf '%s' "$t" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/[[:space:]][[:space:]]*/_/g')"
  [ -n "$t" ] || return 1
  printf '%s\n' "$t"
}

# liveness_record_write <pid> <file>: writes the process's record,
# `<pid> <start-time>`, to the file. Fails with an orch: line when the start
# time cannot be read.
liveness_record_write() {
  local pid="$1" file="$2" start
  start="$(liveness_proc_start "$pid")" || { warn "could not read the start time of pid $pid"; return 1; }
  printf '%s %s\n' "$pid" "$start" >"$file"
}

# liveness_record_alive <record>: whether the record's process is running with
# the recorded start time. A bare-pid or malformed record is stale.
liveness_record_alive() {
  local pid start extra current
  read -r pid start extra <<<"${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ -n "$start" ] && [ -z "${extra:-}" ] || return 1
  current="$(liveness_proc_start "$pid")" || return 1
  [ "$current" = "$start" ]
}

# liveness_subdir <name>: the main checkout's autopilot subdirectory of that
# name. Dies when the checkouts cannot be read; called in a substitution, so
# the caller carries the status.
liveness_subdir() {
  local root
  root="$(main_checkout_or_die)" || exit $?
  printf '%s/%s\n' "$(autopilot_dir "$root")" "$1"
}

# liveness_tick_begin <issue>: right after a tick takes a claim, writes the
# calling process's record as the issue's tick record, overwriting an older
# one. A failed write warns and carries on: with no record, the claim's
# process counts as gone.
liveness_tick_begin() {
  local dir
  dir="$(liveness_subdir run 2>/dev/null)" || dir=""
  { [ -n "$dir" ] && mkdir -p "$dir" && liveness_record_write "$$" "$dir/$1.tick"; } 2>/dev/null ||
    warn "could not write the tick record for issue #$1"
  return 0
}

# liveness_run_begin <issue>: writes the calling process's run record and
# removes the issue's tick record. Fails with an orch: line when the start
# time cannot be read, leaving the tick record.
liveness_run_begin() {
  local dir
  dir="$(liveness_subdir run)" || return $?
  mkdir -p "$dir" || die "could not create $dir"
  liveness_record_write "$$" "$dir/$1.pid" || return 1
  rm -f "$dir/$1.tick"
}

# liveness_run_end <issue>: removes the issue's run record only while it still
# names the calling process, so a later run's record survives an earlier run's
# exit.
liveness_run_end() {
  local dir record
  dir="$(liveness_subdir run)" || return $?
  record="$(cat "$dir/$1.pid" 2>/dev/null)" || record=""
  [ "${record%% *}" = "$$" ] && liveness_record_alive "$record" || return 0
  rm -f "$dir/$1.pid"
}

# liveness_issue_record <issue>: the issue's record text - the run record's when
# there is one, else the tick record's, else nothing.
liveness_issue_record() {
  local dir
  dir="$(liveness_subdir run)" || return $?
  if [ -f "$dir/$1.pid" ]; then cat "$dir/$1.pid"
  elif [ -f "$dir/$1.tick" ]; then cat "$dir/$1.tick"; fi
  return 0
}

# liveness_issue_alive <issue>: whether the process behind the issue is alive,
# by the run record, else the tick record; with neither, gone. Prints the
# recorded pid (nothing when there is no record).
liveness_issue_alive() {
  local record
  record="$(liveness_issue_record "$1")" || return $?
  printf '%s\n' "${record%% *}"
  liveness_record_alive "$record"
}

# liveness_issue_forget <issue>: removes both of the issue's records.
liveness_issue_forget() {
  local dir
  dir="$(liveness_subdir run)" || return $?
  rm -f "$dir/$1.pid" "$dir/$1.tick"
}

# liveness_live_issues: the issues whose process is alive by
# liveness_issue_alive's rule, one number per line, ascending.
liveness_live_issues() {
  local dir f name issue
  dir="$(liveness_subdir run)" || return $?
  for f in "$dir"/*.pid "$dir"/*.tick; do
    [ -e "$f" ] || continue
    name="${f##*/}"; printf '%s\n' "${name%.*}"
  done | sort -un | while read -r issue; do
    ! liveness_issue_alive "$issue" >/dev/null || printf '%s\n' "$issue"
  done
}

# liveness_log_path <issue> <phase>: a new session log's path,
# logs/<issue>-<phase>-<stamp>.log, creating the logs directory.
liveness_log_path() {
  local dir
  dir="$(liveness_subdir logs)" || return $?
  mkdir -p "$dir" || die "could not create $dir"
  printf '%s/%s-%s-%s.log\n' "$dir" "$1" "$2" "$(dir_stamp)"
}

# liveness_latest_log <issue> [<phase>]: the newest session log of the issue
# (of that phase, when given); nothing when there is none.
liveness_latest_log() {
  local dir f base rest prefix="$1-"
  dir="$(liveness_subdir logs)" || return $?
  [ -z "${2:-}" ] || prefix="$1-$2-"
  for f in "$dir/$prefix"*.log; do
    [ -e "$f" ] || continue
    base="${f##*/}"; rest="${base#"$1"-}"
    # <phase>-<stamp>.log: order by the stamp, whatever the phase
    printf '%s %s\n' "${rest#*-}" "$f"
  done | sort | tail -n 1 | cut -d' ' -f2-
}

# liveness_watch_pidfile: the clone's watch pidfile, under the git common
# directory beside the suite-cost record, so every worktree of the clone
# reaches the same one.
liveness_watch_pidfile() {
  local d
  d="$(clone_orchestrator_dir)" || return 1
  printf '%s/autopilot-watch.pid\n' "$d"
}

# liveness_watch_begin: dies while another watch of the clone is alive,
# replaces a record whose process is gone, and writes the calling process's
# record to the watch pidfile.
liveness_watch_begin() {
  local pidfile other
  pidfile="$(liveness_watch_pidfile)" || return 1
  if [ -f "$pidfile" ]; then
    other="$(cat "$pidfile" 2>/dev/null)" || other=""
    ! liveness_record_alive "$other" ||
      die "another autopilot watch (pid ${other%% *}) is already running in this clone"
  fi
  mkdir -p "$(dirname "$pidfile")" || die "could not create $(dirname "$pidfile")"
  liveness_record_write "$$" "$pidfile" || return 1
}

# liveness_watch_end: removes the watch pidfile.
liveness_watch_end() {
  local pidfile
  pidfile="$(liveness_watch_pidfile)" || return 1
  rm -f "$pidfile"
}
