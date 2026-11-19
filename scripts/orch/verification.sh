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
# run again attaches to it.
# A run is one command in one checkout, kept in the main checkout's
# .orchestrator/verification/<hash of checkout, identity, command>/: root and
# id (the checkout and its identity token), state (HEAD and the
# working-tree state: tracked changes, staged or not, and unignored untracked
# files, by content), pid (a liveness record), out, err, status
# (written once the run ends), overrun (a run stopped at the ceiling), termed
# (when TERM was sent to a stale run's group), killed (when KILL was sent, by
# the stop, the delivery or the runner) and waiting (when a record with no state
# was first seen); the last three hold an epoch, so the grace counts across
# calls. A
# finished result or a live run whose state no
# longer matches is stale: the result is discarded undelivered, the live run
# stopped by its process group (TERM, then KILL after
# ORCH_VERIFICATION_GRACE) and a fresh run started. A run of another command
# is left alone. A run still going at orchestrator.verification.timeout (git
# config, default 3600 s) is stopped by its own runner, with no call needed,
# and delivered as failed by the next one, its orch: message naming the process
# group when that could not be stopped. A record with no state is waited on for
# ORCH_VERIFICATION_GRACE (counted across calls), then cleared as stale.
# Records of checkouts that no longer exist are cleared by the next call. A
# finished result is forgotten only once a call has printed it whole. Nothing
# about a delivered run is measured or kept (ADR-0063).
# Its tests: scripts/test/orch/verification.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# How often a waiting call looks at the run, in seconds.
ORCH_VERIFICATION_INTERVAL="${ORCH_VERIFICATION_INTERVAL:-0.2}"
# How long a stopped run's group has after TERM before KILL, in seconds.
ORCH_VERIFICATION_GRACE="${ORCH_VERIFICATION_GRACE:-5}"

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

# verification_state: prints the working-tree state: a hash of HEAD, the
# tracked files' changes against HEAD, staged or not, and each untracked file
# git does not ignore, by content. Ignored files never count.
verification_state() {
  {
    printf 'head %s\n' "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo none)"
    git -C "$ROOT" diff HEAD --binary 2>/dev/null || git -C "$ROOT" diff --binary 2>/dev/null || true
    git -C "$ROOT" ls-files --others --exclude-standard -z -- ":!$ORCH_DIR_NAME" 2>/dev/null | (
      cd "$ROOT" && while IFS= read -r -d '' f; do
        printf 'untracked %s %s\n' "$f" "$(git hash-object -- "$f" 2>/dev/null)"
      done
    )
  } | git hash-object --stdin
}

# verification_identity: prints this checkout's identity token, made once and
# kept in $ORCH/verification/id. A checkout removed and made again at the same
# path has none, so it is another checkout.
verification_identity() {
  local f="$ORCH/verification/id" t
  if [ ! -s "$f" ]; then
    mkdir -p "$ORCH/verification" || return 1
    t="$(printf '%s %s %s %s\n' "$$" "$RANDOM$RANDOM" "$(printf "%(%s)T" -1)" "$ROOT" | git hash-object --stdin)" || return 1
    file_write_atomic "$f" "$t"$'\n' || return 1
  fi
  cat "$f"
}

# verification_timeout: prints the ceiling in seconds, from the per-clone git
# config orchestrator.verification.timeout (default 3600, fractions allowed).
# Dies on a value that is not a positive number.
verification_timeout() {
  local v
  v="$(git -C "$ROOT" config --get orchestrator.verification.timeout 2>/dev/null || true)"
  [ -n "$v" ] || v=3600
  if is_positive_number "$v"; then
    printf '%s\n' "$v"
    return 0
  fi
  die "orchestrator.verification.timeout is $v - it must be a positive number of seconds (git config orchestrator.verification.timeout <seconds>)"
}

# verification_clear_orphans <store>: removes the records of checkouts that no
# longer exist, or were made again at their path, and those a call stopped
# before it wrote their root and id left behind. A live run there runs to its
# end, undelivered.
verification_clear_orphans() {
  local r root id current idf
  for r in "$1"/*/; do
    r="${r%/}"
    if [ ! -f "$r/root" ] || [ ! -f "$r/id" ]; then
      # A call stopped before it wrote them: no call will, so the record is
      # stale once no starting call can still be at it.
      [ -z "$(find "$r" -maxdepth 0 -mmin +1 2>/dev/null)" ] || rm -rf "$r"
      continue
    fi
    root="$(<"$r/root")"
    id="$(<"$r/id")"
    current=""
    idf="$root/$ORCH_DIR_NAME/verification/id"
    [ ! -f "$idf" ] || current="$(<"$idf")"
    [ "$current" = "$id" ] || rm -rf "$r"
  done
}

# verification_grace_nap: one 0.1 s turn of a grace wait, clamped to what is
# left of ORCH_WAIT_BLOCK; a call whose block is spent exits 75 instead, so no
# grace wait runs a call past the block.
verification_grace_nap() {
  local spent
  orch_load wait
  spent="$(wait_block_spent 0)"
  float_lt "$spent" "$ORCH_WAIT_BLOCK" || wait_exit_running
  sleep "$(wait_nap 0.1 "$spent")"
}

# verification_epoch_in <file>: prints the epoch second <file> holds, or the
# current one when it is missing or holds no whole number.
verification_epoch_in() {
  local t=""
  [ ! -f "$1" ] || t="$(<"$1")"
  case "$t" in ''|*[!0-9]*) printf '%(%s)T\n' -1 ;; *) printf '%s\n' "$t" ;; esac
}

# verification_mark <file>: records the current epoch second in <file> unless it
# already holds one, so a grace is counted across calls, from the first.
verification_mark() {
  [ ! -f "$1" ] || return 0
  if printf '%(%s)T\n' -1 >"$1.tmp" 2>/dev/null; then
    mv -f "$1.tmp" "$1" 2>/dev/null || true
  fi
}

# verification_wait_gone <pid> [<epoch>]: waits until ORCH_VERIFICATION_GRACE
# seconds have passed since <epoch> (default now) - wall clock, so a grace spent
# across several calls counts as one - or ORCH_WAIT_BLOCK ends the call, for the
# process group <pid> to be gone. Returns 1 when it is still there.
verification_wait_gone() {
  local pid="$1" since="${2:-}" slept=0
  [ -n "$since" ] || printf -v since '%(%s)T' -1
  while kill -0 -- "-$pid" 2>/dev/null; do
    float_lt "$(wait_elapsed "$since" "$slept")" "$ORCH_VERIFICATION_GRACE" || return 1
    verification_grace_nap
    slept="$(float_add "$slept" 0.1)"
  done
}

# verification_stop <pid> <dir>: stops the run's process group: TERM, then KILL
# once ORCH_VERIFICATION_GRACE seconds have passed since the TERM, which
# <dir>/termed keeps, so a call whose block ends inside the grace is followed
# by one that goes on to KILL; the grace after the KILL counts the same way,
# from <dir>/killed. Returns 1 when the group is still there.
verification_stop() {
  local pid="$1" d="$2"
  if [ ! -f "$d/termed" ]; then
    kill -TERM -- "-$pid" 2>/dev/null || true
    verification_mark "$d/termed"
  fi
  verification_wait_gone "$pid" "$(verification_epoch_in "$d/termed")" && return 0
  kill -KILL -- "-$pid" 2>/dev/null || true
  verification_mark "$d/killed"
  verification_wait_gone "$pid" "$(verification_epoch_in "$d/killed")"
}

# verification_wait_state <dir>: waits until ORCH_VERIFICATION_GRACE seconds
# have passed since a call first found the record <dir> without its state file
# (kept in <dir>/waiting, so the grace holds across calls) for it to have one.
# Returns 1 when it still has none.
verification_wait_state() {
  local slept=0 since
  verification_mark "$1/waiting"
  since="$(verification_epoch_in "$1/waiting")"
  until [ -f "$1/state" ]; do
    float_lt "$(wait_elapsed "$since" "$slept")" "$ORCH_VERIFICATION_GRACE" || return 1
    verification_grace_nap
    slept="$(float_add "$slept" 0.1)"
  done
}

# verification_start <dir> <command> <ceiling>: starts the run detached, in a
# process group of its own, and records it in <dir>. The command's output goes
# to <dir>/out and <dir>/err, its status to <dir>/status once it ends. The
# runner is the run's own timer: a command still going at <ceiling> seconds
# (whole seconds, rounded up) is stopped by the process group, TERM then KILL
# after ORCH_VERIFICATION_GRACE, and its status recorded as 1 beside an
# <dir>/overrun file, so a run nobody calls again cannot outlive its ceiling.
verification_start() {
  local d="$1" ceiling="$3" limit steps pid
  limit="$(awk -v c="$ceiling" 'BEGIN { printf "%d", (c == int(c)) ? c : int(c) + 1 }')"
  steps="$(awk -v g="$ORCH_VERIFICATION_GRACE" 'BEGIN { printf "%d", g * 10 + 0.5 }')"
  (
    set -m
    cd "$ROOT" || exit 1
    nohup bash -c '
      d="$1"; cmd="$2"; ceiling="$3"; limit="$4"; steps="$5"
      # One second past the whole second the run began in, so the whole-second
      # test below never fires before the ceiling, only up to a second after.
      start="$(( $(printf "%(%s)T" -1) + 1 ))"
      (
        bash -c "$cmd" >"$d/out" 2>"$d/err" </dev/null
        echo "$?" >"$d/status.tmp"
        mv "$d/status.tmp" "$d/status"
      ) &
      until [ -f "$d/status" ]; do
        if [ "$(( $(printf "%(%s)T" -1) - start ))" -ge "$limit" ]; then
          trap "" TERM
          printf "%s\n" "$ceiling" >"$d/overrun"
          kill -TERM 0
          n=0
          while [ "$n" -lt "$steps" ] && [ -n "$(jobs -r)" ]; do
            sleep 0.1
            n=$((n + 1))
          done
          printf "%(%s)T\n" -1 >"$d/killed"
          echo 1 >"$d/status.tmp"
          mv "$d/status.tmp" "$d/status"
          kill -KILL 0
        fi
        sleep 0.2
      done
    ' _ "$d" "$2" "$ceiling" "$limit" "$steps" >/dev/null 2>&1 </dev/null &
    echo "$!" >"$d/pid.raw"
  ) >/dev/null 2>&1 </dev/null
  pid="$(<"$d/pid.raw")"
  # A run that already ended has no start time to read: its status is there.
  liveness_record_write "$pid" "$d/pid" 2>/dev/null || true
}

# verification_deliver <dir>: prints the finished run's stdout and stderr whole
# and exits with its status - 1 and an orch: line naming it, for a command that
# itself exited 75, and 1 for a run stopped at the ceiling, with an orch: line
# saying so (naming the process group when it is still there) - then forgets
# the run, only once everything was printed.
verification_deliver() {
  local d="$1" st ceiling rec group gone=1
  st="$(<"$d/status")"
  if [ -f "$d/overrun" ]; then
    ceiling="$(<"$d/overrun")"
    # The runner's KILL ends the group an instant after it wrote the status.
    # Waited for before anything is printed: a call whose block is spent exits
    # 75 here, and the next one delivers.
    rec=""
    [ ! -f "$d/pid" ] || rec="$(<"$d/pid")"
    group="${rec%% *}"
    if [ -n "$group" ]; then
      # The grace counts from the runner's KILL (its mark), across calls.
      verification_mark "$d/killed"
      verification_wait_gone "$group" "$(verification_epoch_in "$d/killed")" || gone=""
    fi
  fi
  cat "$d/out" || exit 1
  cat "$d/err" >&2 || exit 1
  if [ -f "$d/overrun" ]; then
    if [ -z "$gone" ]; then
      warn "the run was still going after the ceiling of ${ceiling}s (orchestrator.verification.timeout) and its process group $group is left running - stop it by hand"
    else
      warn "the run was still going after the ceiling of ${ceiling}s (orchestrator.verification.timeout) and was stopped"
    fi
    st=1
  elif [ "$st" = 75 ]; then
    warn "the command exited 75 - delivered as exit 1, its real status"
    st=1
  fi
  rm -rf "$d"
  exit "$st"
}

# verification_died <dir>: whether the run in <dir> died without leaving a
# status: it has a process record that is no longer alive, and no status.
verification_died() {
  [ ! -f "$1/status" ] && [ -f "$1/pid" ] && ! liveness_record_alive "$(<"$1/pid")"
}

# verification_run <command>: the verb's work.
verification_run() {
  orch_load wait
  wait_block_check
  require_poll_knobs ORCH_VERIFICATION_GRACE ORCH_VERIFICATION_INTERVAL
  local command="$1" state store d slept=0 attached="" ceiling id main_root rec stop spent nap
  ceiling="$(verification_timeout)" || exit $?
  id="$(verification_identity)" || die "could not record this checkout's identity in $ORCH"
  state="$(verification_state)" || die "could not read the working tree state"
  main_root="$(main_checkout_or_die)" || exit $?
  store="$main_root/$ORCH_DIR_NAME/verification"
  mkdir -p "$store" || die "could not create $store"
  verification_clear_orphans "$store"
  d="$store/$(printf 'root %s\nid %s\ncommand %s\n' "$ROOT" "$id" "$command" | git hash-object --stdin)"
  # Start the run, or attach to this command's run when it is current.
  # A finished result, or a live run, whose HEAD or tree no longer matches is
  # stale: the result is dropped, the live run stopped by its process group,
  # and a fresh
  # run started. A run that died leaving no status is cleared the same way.
  # A record with no state is another call still starting the run, for as long
  # as ORCH_VERIFICATION_GRACE: a call stopped before it wrote the state never
  # will, and its record is stale like any other.
  until mkdir "$d" 2>/dev/null; do
    stop=1
    if [ ! -f "$d/state" ]; then
      verification_wait_state "$d" && continue
    elif [ "$(<"$d/state")" = "$state" ]; then
      if ! verification_died "$d"; then
        attached=1; break
      fi
      stop=""
    fi
    # A TERMed run whose leader died still has its group to KILL: its record
    # says termed, whatever the liveness record says.
    if [ -n "$stop" ] && [ ! -f "$d/status" ] && [ -f "$d/pid" ] &&
       { [ -f "$d/termed" ] || liveness_record_alive "$(<"$d/pid")"; }; then
      rec="$(<"$d/pid")"
      verification_stop "${rec%% *}" "$d" || die "the stale run of this command (process group ${rec%% *}) could not be stopped - stop it by hand"
    fi
    rm -rf "$d"
  done
  if [ -z "$attached" ]; then
    printf '%s\n' "$ROOT" >"$d/root"
    printf '%s\n' "$id" >"$d/id"
    printf '%s\n' "$state" >"$d/state.tmp"
    verification_start "$d" "$command" "$ceiling"
    mv "$d/state.tmp" "$d/state"
  fi
  while [ ! -f "$d/status" ]; do
    if verification_died "$d"; then
      rm -rf "$d"
      die "the run ended without a status - run the same command again"
    fi
    spent="$(wait_block_spent "$slept")"
    float_lt "$spent" "$ORCH_WAIT_BLOCK" || wait_exit_running
    nap="$(wait_nap "$ORCH_VERIFICATION_INTERVAL" "$spent")"
    sleep "$nap"
    slept="$(float_add "$slept" "$nap")"
  done
  verification_deliver "$d"
}
