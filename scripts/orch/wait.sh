# shellcheck shell=bash
# wait.sh - the stored total of a re-callable wait (GLOSSARY.md): `review ci`
# and `spec-review wait` poll against a total counted from their first call and
# kept in $ORCH/wait/<key>, and each call blocks at most ORCH_WAIT_BLOCK
# seconds (default 570, the setting `verification run` reads), leaving stdout
# empty, saying so on stderr and exiting 75 while its wait is not over. The
# file holds two lines: the epoch second of the first call, and the seconds
# slept so far across every call (the larger of that and the wall clock since
# the first call is what has elapsed, as ci_elapsed counts it, so a sub-second
# test override still advances). A stored total belongs to one wait, named by
# the key the caller builds, and is forgotten as soon as a call delivers an
# outcome. Its tests: the `review ci` and `spec-review wait` sections.
# Sourced by orch.sh, after common.sh and the ROOT block.

ORCH_WAIT_BLOCK="${ORCH_WAIT_BLOCK:-570}"

# wait_block_check: refuses an ORCH_WAIT_BLOCK that is not a positive number.
wait_block_check() {
  require_poll_knobs ORCH_WAIT_BLOCK
}

# wait_open <key-text> <start-var> <slept-var>: finds or creates the stored
# total for the wait <key-text> names, and sets the two variables to the
# epoch second of its first call and the seconds slept so far (0 when new).
# It sets WAIT_FILE, the file wait_forget and wait_still_running use.
wait_open() {
  local key now start="" slept=""
  key="$(printf '%s' "$1" | git hash-object --stdin)" || die "could not key the wait"
  mkdir -p "$ORCH/wait" || die "could not create $ORCH/wait"
  WAIT_FILE="$ORCH/wait/$key"
  if [ -f "$WAIT_FILE" ]; then
    { IFS= read -r start; IFS= read -r slept; } <"$WAIT_FILE" || true
  fi
  case "$start" in ''|*[!0-9]*) start="" ;; esac
  case "$slept" in ''|*[!0-9.]*|*.*.*|.) slept="" ;; esac
  if [ -z "$start" ] || [ -z "$slept" ]; then
    now="$(date +%s)"
    start="$now"
    slept=0
    printf '%s\n%s\n' "$start" "$slept" >"$WAIT_FILE" || die "could not store the wait"
  fi
  printf -v "$2" '%s' "$start"
  printf -v "$3" '%s' "$slept"
}

# wait_forget: forgets the stored total, once a call delivers an outcome.
wait_forget() {
  rm -f "$WAIT_FILE"
}

# wait_still_running <slept>: stores the seconds slept so far, says the wait is
# not over, and exits 75.
wait_still_running() {
  printf '%s\n%s\n' "$(sed -n 1p "$WAIT_FILE")" "$1" >"$WAIT_FILE.tmp" \
    && mv "$WAIT_FILE.tmp" "$WAIT_FILE" || die "could not store the wait"
  printf 'orch: still running after %ss - run the same command again\n' "$ORCH_WAIT_BLOCK" >&2
  exit 75
}
