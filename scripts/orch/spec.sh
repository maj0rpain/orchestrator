# shellcheck shell=bash
# spec.sh - orch.sh's spec command: the flow's spec issue, read and written,
# and the pause that stops the spec phase's session once it is written.
# Its tests: scripts/test/orch/spec.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the four ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
# The four read and write ops delegate to issue.sh's issue primitives,
# resolving the number from state; pause touches no issue. A done flow's issue
# is finished work: state.json lingers after the flow ends, so a spec op there
# would quietly touch an issue nobody is reviewing any more - it refuses and
# points at the stateless issue ops.
cmd_spec() {
  local op="${1:-}"
  shift || true
  # spec round reserves exit 1 for "no round marker", so even its missing
  # flow is exit 2: it checks for the flow itself, through die2.
  [ "$op" = round ] || require_state
  case "$op" in
    fetch|update|comment|comments) ;;
    pause) cmd_spec_pause "$@"; return ;;
    round) cmd_spec_round "$@"; return ;;
    round-dir) cmd_spec_round_dir "$@"; return ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment|comments|pause|round|round-dir)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment|comments> <file>"
  local file="$1" issue
  require_issue issue
  flow_active \
    || die "the flow on issue #$issue is done - spec $op acts only on an active flow's issue; for another issue use orch.sh issue $op <n> <file>"
  "cmd_issue_$op" "$issue" "$file"
}

# The marker a spec phase leaves when it stops its session once the spec is
# written (#1181), holding the issue number: the fresh session's spec phase
# reads it and goes straight to the spec review. A file in the handoff folder
# but not a handoff - no phase table entry names it, so handoff validate and
# doctor never look at it - and no state.json field (ADR-0005). redo spec moves
# it aside with the stale handoffs.
readonly SPEC_PAUSED_MARKER=spec-paused

# Stops the spec phase's session after the spec is written: writes the marker,
# then prints the stop block with the host's Next line. The marker is written
# first, so a failed write prints no block; the phase is left at spec.
cmd_spec_pause() {
  [ $# -eq 0 ] || die "usage: orch.sh spec pause"
  local issue
  spec_phase_guard die pause issue
  mkdir -p "$HANDOFF_DIR" || die "cannot create $HANDOFF_DIR"
  printf '%s\n' "$issue" >"$HANDOFF_DIR/$SPEC_PAUSED_MARKER" \
    || die "cannot write $HANDOFF_DIR/$SPEC_PAUSED_MARKER"
  print_next_block "Spec #$issue written. The spec review runs in a fresh session."
}

# spec_phase_guard <die|die2> <op> <var>: the refusals every op that acts
# inside the spec phase shares - no flow, no recorded issue, a done flow, a
# phase other than spec - each through <die|die2>; assigns the flow's issue
# to the variable named <var>. Call it as a bare statement, as require_field.
spec_phase_guard() {
  local __sg_die="$1" __sg_op="$2" __sg_issue __sg_phase
  require_state "$__sg_die"
  require_issue __sg_issue "$__sg_die"
  flow_active \
    || "$__sg_die" "the flow on issue #$__sg_issue is done - spec $__sg_op acts only on an active flow"
  __sg_phase="$(state_get phase)"
  [ "$__sg_phase" = spec ] \
    || "$__sg_die" "spec $__sg_op runs only in the spec phase - the flow is at phase $__sg_phase"
  printf -v "$3" '%s' "$__sg_issue"
}

# The round marker (#1346): the file a flow's spec review leaves in the
# handoff folder naming the flow's issue, a round k and the round count n, as
# one line `<issue> <k> <n>` - a format spec round alone reads. Like
# spec-paused it is no handoff - no phase table entry names it, so handoff
# validate and doctor never look at it - and no state.json field.
readonly SPEC_ROUND_MARKER=spec-round
# The empty file spec-review apply writes in a round's directory as its very
# last step: a round counts as complete only when its directory holds it.
readonly SPEC_ROUND_COMPLETE=round-complete
# Where a flow's spec review rounds work, one directory per round number. Not
# under spec-review/, the flow-less entry archive keeps: these belong to the
# flow and are archived with it.
readonly SPEC_ROUNDS_DIR="$ORCH/spec-rounds"

# spec_round_count_parse <k>/<n> <k-var> <n-var>: a round and the round count,
# two positive whole numbers with k no greater than n, into the variables
# named; dies otherwise.
spec_round_count_parse() {
  local __rc_arg="$1" __rc_k __rc_n
  __rc_k="${__rc_arg%%/*}"; __rc_n="${__rc_arg#*/}"
  case "$__rc_arg" in */*) ;; *) __rc_k="" ;; esac
  case "$__rc_k" in [1-9]|[1-9]*[0-9]) ;; *) __rc_k="" ;; esac
  case "$__rc_n" in [1-9]|[1-9]*[0-9]) ;; *) __rc_n="" ;; esac
  case "$__rc_k$__rc_n" in *[!0-9]*) __rc_k="" ;; esac
  [ -n "$__rc_k" ] && [ -n "$__rc_n" ] \
    || die "want <k>/<n>, a round and the round count, two positive whole numbers, got: $__rc_arg"
  [ "$__rc_k" -le "$__rc_n" ] || die "round $__rc_k is past the round count $__rc_n"
  printf -v "$2" '%s' "$__rc_k"
  printf -v "$3" '%s' "$__rc_n"
}

# spec round-dir <k>/<n>: round k's working directory made ready and printed,
# then the round marker written naming the flow's issue, k and n - last, so a
# failed write prints no path and a round never runs without its marker.
# Ready means emptied (created when missing); on round 1 every other round's
# directory deleted, a redone review leaking nothing stale; on a later round
# round k-1's code map and settled file copied in, each when it exists - a
# copy, not a carry in place, since every round keeps its own directory for
# the final session to read its changelog from. Idempotent.
cmd_spec_round_dir() {
  local usage="usage: orch.sh spec round-dir <k>/<n>"
  [ $# -eq 1 ] || die "$usage"
  local k n issue
  spec_round_count_parse "$1" k n
  spec_phase_guard die round-dir issue
  local dir="$SPEC_ROUNDS_DIR/$k" f
  spec_review_dir_empty "$dir"
  if [ "$k" -eq 1 ]; then
    find "$SPEC_ROUNDS_DIR" -mindepth 1 -maxdepth 1 ! -name 1 -exec rm -rf {} +
  else
    for f in map-implementability.md settled.md; do
      [ ! -f "$SPEC_ROUNDS_DIR/$((k - 1))/$f" ] \
        || cp "$SPEC_ROUNDS_DIR/$((k - 1))/$f" "$dir/$f" \
        || die "cannot copy round $((k - 1))'s $f into $dir"
    done
  fi
  mkdir -p "$HANDOFF_DIR" 2>/dev/null || die "cannot create $HANDOFF_DIR"
  { printf '%s %s %s\n' "$issue" "$k" "$n" >"$HANDOFF_DIR/$SPEC_ROUND_MARKER"; } 2>/dev/null \
    || die "cannot write the round marker $HANDOFF_DIR/$SPEC_ROUND_MARKER"
  printf '%s/\n' "$dir"
}

# spec round: the round a resumed flow's spec review runs next, from the
# round marker - `<k> <n>`, the marker's k, or k+1 once round k's directory
# holds round-complete - or `done <n>` once round n's does. Exit 1, printing
# nothing, when there is no marker or it names another issue; every failure
# is exit 2, so a caller never reads one as "no marker".
cmd_spec_round() {
  [ $# -eq 0 ] || die2 "usage: orch.sh spec round"
  local issue marker="$HANDOFF_DIR/$SPEC_ROUND_MARKER" line m_issue k n extra
  spec_phase_guard die2 round issue
  [ -f "$marker" ] || return 1
  line=""
  IFS= read -r line <"$marker" || [ -n "$line" ] \
    || die2 "malformed round marker $marker: it is empty - want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"
  read -r m_issue k n extra <<<"$line"
  case "$m_issue" in ''|*[!0-9]*) m_issue="" ;; esac
  case "$k" in [1-9]|[1-9]*[0-9]) ;; *) k="" ;; esac
  case "$n" in [1-9]|[1-9]*[0-9]) ;; *) n="" ;; esac
  case "$k$n" in *[!0-9]*) k="" ;; esac
  if [ -z "$m_issue" ] || [ -z "$k" ] || [ -z "$n" ] || [ -n "$extra" ] || [ "$k" -gt "$n" ]; then
    die2 "malformed round marker $marker: '$line' - want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"
  fi
  [ "$m_issue" = "$issue" ] || return 1
  if [ ! -e "$SPEC_ROUNDS_DIR/$k/$SPEC_ROUND_COMPLETE" ]; then
    printf '%s %s\n' "$k" "$n"
  elif [ "$k" -lt "$n" ]; then
    printf '%s %s\n' "$((k + 1))" "$n"
  else
    printf 'done %s\n' "$n"
  fi
}
