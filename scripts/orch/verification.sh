# shellcheck shell=bash
# verification.sh - orch.sh's verification command: a shell command line run
# detached from the call that started it and waited for in bounded calls (a
# re-callable command, GLOSSARY.md).
# `verification run <command>` runs the command with bash -c in a process group
# of its own (set -m in the detaching subshell, as the watcher's nohup-in-a-
# subshell start does, since setsid is not on every host), so it survives the
# call being stopped. A call blocks ORCH_WAIT_BLOCK seconds (default 570). A run
# that finishes inside the call is delivered whole, with its status; one still
# going leaves stdout empty, says so on stderr and exits 75, and the same line
# run again attaches to it. A run is keyed by the checkout, the command, HEAD
# and the working-tree state (tracked changes and unignored untracked files, by
# content), and kept in $ORCH/verification/<key>/: command, pid (a liveness
# record), out, err and status (written once the run ends). A finished result is
# forgotten only once a call has printed it whole. Nothing about a delivered run
# is measured or kept (ADR-0063).
# Its tests: scripts/test/orch/verification.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# How often a waiting call looks at the run, in seconds.
ORCH_VERIFICATION_INTERVAL="${ORCH_VERIFICATION_INTERVAL:-0.2}"

cmd_verification() {
  local op="${1:-}"
  shift || true
  case "$op" in
    run)
      [ $# -eq 1 ] && [ -n "$1" ] || die2 "usage: orch.sh verification run <command>"
      verification_run "$1" ;;
    *) die2 "usage: orch.sh verification run <command>" ;;
  esac
}

# verification_key <command>: prints the run key, a hash of the checkout, the
# command, HEAD and the working-tree state: the tracked files' changes against
# HEAD, staged or not, and each untracked file git does not ignore, by content.
verification_key() {
  {
    printf 'root %s\ncommand %s\nhead %s\n' "$ROOT" "$1" "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)"
    git -C "$ROOT" diff HEAD --binary 2>/dev/null || git -C "$ROOT" diff --binary 2>/dev/null || true
    git -C "$ROOT" ls-files --others --exclude-standard -z -- ":!$ORCH_DIR_NAME" 2>/dev/null | (
      cd "$ROOT" && while IFS= read -r -d '' f; do
        printf 'untracked %s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
      done
    )
  } | git hash-object --stdin
}

# verification_start <dir> <command>: starts the run detached, in a process
# group of its own, and records it in <dir>. The command's output goes to
# <dir>/out and <dir>/err, its status to <dir>/status once it ends.
verification_start() {
  local d="$1" pid
  printf '%s\n' "$2" >"$d/command"
  (
    set -m
    cd "$ROOT" || exit 1
    nohup bash -c '
      d="$1"; cmd="$2"
      bash -c "$cmd" >"$d/out" 2>"$d/err" </dev/null
      echo "$?" >"$d/status.tmp"
      mv "$d/status.tmp" "$d/status"
    ' _ "$d" "$2" >/dev/null 2>&1 </dev/null &
    echo "$!" >"$d/pid.raw"
  ) >/dev/null 2>&1 </dev/null
  pid="$(<"$d/pid.raw")"
  # A run that already ended has no start time to read: its status is there.
  liveness_record_write "$pid" "$d/pid" 2>/dev/null || true
}

# verification_deliver <dir>: prints the finished run's stdout and stderr whole
# and exits with its status - 1 and an orch: line naming it, for a command that
# itself exited 75 - then forgets the run, only once everything was printed.
verification_deliver() {
  local d="$1" st
  st="$(<"$d/status")"
  cat "$d/out" || exit 1
  cat "$d/err" >&2 || exit 1
  if [ "$st" = 75 ]; then
    warn "the command exited 75 - delivered as exit 1, its real status"
    st=1
  fi
  rm -rf "$d"
  exit "$st"
}

# verification_run <command>: the verb's work.
verification_run() {
  orch_load wait
  wait_block_check
  require_poll_knobs ORCH_VERIFICATION_INTERVAL
  local command="$1" key store d slept=0 attached=""
  key="$(verification_key "$command")" || die "could not read the working tree state"
  store="$ORCH/verification"
  d="$store/$key"
  mkdir -p "$store" || die "could not create $store"
  # Start the run, or attach to the live one under this key; a run that died
  # leaving no status is cleared and started afresh.
  until mkdir "$d" 2>/dev/null; do
    if [ -f "$d/status" ] || [ ! -f "$d/pid" ] || liveness_record_alive "$(<"$d/pid")"; then
      attached=1
      break
    fi
    rm -rf "$d"
  done
  [ -n "$attached" ] || verification_start "$d" "$command"
  while [ ! -f "$d/status" ]; do
    if [ -f "$d/pid" ] && ! liveness_record_alive "$(<"$d/pid")" && [ ! -f "$d/status" ]; then
      rm -rf "$d"
      die "the run ended without a status - run the same command again"
    fi
    if ! float_lt "$slept" "$ORCH_WAIT_BLOCK"; then
      printf 'orch: still running after %ss - run the same command again\n' "$ORCH_WAIT_BLOCK" >&2
      exit 75
    fi
    sleep "$ORCH_VERIFICATION_INTERVAL"
    slept="$(float_add "$slept" "$ORCH_VERIFICATION_INTERVAL")"
  done
  verification_deliver "$d"
}
