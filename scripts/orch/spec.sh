# shellcheck shell=bash
# spec.sh - orch.sh's spec command: the flow's spec issue, read and written,
# and the pause that stops the spec phase's session once it is written. It also
# owns the round directory: the files saying where a spec review round stands,
# the working-directory reset and what a round hands the next.
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
  # Every other op makes the entry read of the flow's issue and phase here
  # and hands both on.
  local issue="" phase=""
  [ "$op" = round ] || require_state_read issue=issue phase=phase
  case "$op" in
    fetch|update|comment|comments) ;;
    pause) cmd_spec_pause "$issue" "$phase" "$@"; return ;;
    round) cmd_spec_round "$@"; return ;;
    round-dir) cmd_spec_round_dir "$issue" "$phase" "$@"; return ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment|comments|pause|round|round-dir)" ;;
  esac
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment|comments> <file>"
  local file="$1"
  require_value issue "$issue"
  [ "$phase" != "done" ] \
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
# With --round <k>/<n>, the stop after round k of n of a flow's spec review
# instead: see cmd_spec_pause_round.
cmd_spec_pause() {
  local issue="$1" phase="$2"
  shift 2
  if [ "${1:-}" = --round ]; then
    shift
    cmd_spec_pause_round "$issue" "$phase" "$@"
    return
  fi
  [ $# -eq 0 ] || die "usage: orch.sh spec pause [--round <k>/<n>]"
  spec_phase_guard die pause issue "$issue" "$phase"
  spec_marker_write "$SPEC_PAUSED_MARKER" "$issue"
  print_next_block "Spec #$issue written. The spec review runs in a fresh session."
}

# spec_phase_guard <die|die2> <op> <var> <issue> <phase>: the refusals every op
# that acts inside the spec phase shares once the caller holds the flow's
# <issue> and <phase> from its entry read - no recorded issue, a done flow, a
# phase other than spec - each through <die|die2>; it reads nothing, and assigns
# <issue> to the variable named <var>. Call it as a bare statement, as
# require_field.
spec_phase_guard() {
  local __sg_die="$1" __sg_op="$2"
  require_value issue "$4" "$__sg_die"
  [ "$5" != "done" ] \
    || "$__sg_die" "the flow on issue #$4 is done - spec $__sg_op acts only on an active flow"
  [ "$5" = spec ] \
    || "$__sg_die" "spec $__sg_op runs only in the spec phase - the flow is at phase $5"
  printf -v "$3" '%s' "$4"
}

# The round marker (#1346): the file a flow's spec review leaves in the
# handoff folder naming the flow's issue, a round k and the round count n, as
# one line `<issue> <k> <n>` - a format spec round alone reads. Like
# spec-paused it is no handoff - no phase table entry names it, so handoff
# validate and doctor never look at it - and no state.json field.
readonly SPEC_ROUND_MARKER=spec-round

# spec_marker_write <marker> <line>: creates the handoff folder and writes
# <line> as the one line of the marker file <marker> in it - the one writer of
# the spec module's two markers; dies when it cannot, hiding the shell's own
# redirection error.
spec_marker_write() {
  mkdir -p "$HANDOFF_DIR" 2>/dev/null || die "cannot create $HANDOFF_DIR"
  { printf '%s\n' "$2" >"$HANDOFF_DIR/$1"; } 2>/dev/null \
    || die "cannot write $HANDOFF_DIR/$1"
}

# The round directory's three state files: this module owns them, and the
# spec_round_* functions below read and write them. The empty file
# spec_round_complete writes in a round's directory, as its last local step but
# the answer's clearing: a round counts as complete only when its directory
# holds it.
readonly SPEC_ROUND_COMPLETE=round-complete
# The held-back fundamental items of an autopilot round, written by
# spec_round_hold in the round's directory (spec_round_complete removes it):
# while it exists the round waits for the human's answer, and spec round says
# so.
readonly SPEC_ROUND_FUNDAMENTAL=fundamental.md
# The saved answer of a spec-review apply that is running or died in the round's
# directory, written by spec_round_answer_save and cleared by
# spec_round_answer_clear: while it exists the round is applying, and spec round
# says so.
readonly SPEC_ROUND_APPLY_ANSWER=apply-answer
# Where a flow's spec review rounds work, one directory per round number. Not
# under spec-review/, the flow-less entry archive keeps: these belong to the
# flow and are archived with it.
readonly SPEC_ROUNDS_DIR="$ORCH/spec-rounds"

# The file round 1 of a flow's spec review writes its `agent get lens` read
# to, in its round directory: every later round, in a session of its own,
# starts its lenses on these values rather than reading the setting again, so
# the whole review runs on one lens setting (#1353).
readonly SPEC_ROUND_LENS_SETTING=agent-lens

# What a round hands the next: the Implementability lens's code map (#1141)
# and the settled file (#1185), read by both spec-review begin's --carry and a
# flow's spec round-dir. A flow's round-dir also carries
# SPEC_ROUND_LENS_SETTING, which --carry leaves out: a standalone review reads
# the lens setting once, in one session.
readonly SPEC_ROUND_CARRIED=(map-implementability.md settled.md)

# spec_round_state <dir> <var>: assigns the round's state to <var>, never
# prints it: `applying` while <dir> holds the saved apply answer, else
# `waiting` while it holds fundamental.md, else `open` while it holds no
# round-complete, else `complete`. A missing <dir> is open.
spec_round_state() {
  if [ -e "$1/$SPEC_ROUND_APPLY_ANSWER" ]; then printf -v "$2" '%s' applying
  elif [ -e "$1/$SPEC_ROUND_FUNDAMENTAL" ]; then printf -v "$2" '%s' waiting
  elif [ ! -e "$1/$SPEC_ROUND_COMPLETE" ]; then printf -v "$2" '%s' open
  else printf -v "$2" '%s' complete
  fi
}

# spec_round_held <dir>: whether <dir> holds fundamental.md, the items an
# autopilot round held back - apart from the state, as a resumed apply of a
# held round is `applying` and held at once.
spec_round_held() { [ -e "$1/$SPEC_ROUND_FUNDAMENTAL" ]; }

# spec_round_answer_name <var>: assigns the saved answer's file name to <var>,
# for a caller's message that names it.
spec_round_answer_name() { printf -v "$1" '%s' "$SPEC_ROUND_APPLY_ANSWER"; }

# spec_round_answer_save <dir> <file-options> <arg>...: spec-review apply's
# answer arguments saved to <dir>/apply-answer, one shell-quoted line, before
# the first GitHub write. <file-options> is one word of space-separated option
# names; the argument after each is a file, copied into <dir> first and saved
# as the copy, so a resume never reads a file the dead session left elsewhere.
spec_round_answer_save() {
  local dir="$1" file_opts=" $2 " a file_opt="" copy saved=()
  shift 2
  for a in "$@"; do
    if [ -n "$file_opt" ]; then
      copy="$dir/apply-${file_opt#--}.copy"
      cp "$a" "$copy" 2>/dev/null \
        || die "could not copy $a to $copy - nothing written to GitHub"
      saved+=("$copy")
      file_opt=""
      continue
    fi
    saved+=("$a")
    case "$file_opts" in *" $a "*) file_opt="$a" ;; esac
  done
  { printf '%q ' "${saved[@]}"; printf '\n'; } >"$dir/$SPEC_ROUND_APPLY_ANSWER" 2>/dev/null \
    || die "could not write $dir/$SPEC_ROUND_APPLY_ANSWER - nothing written to GitHub"
}

# spec_round_answer_load <dir> <array-var>: the saved answer's arguments read
# into the array <array-var>; dies when the file is unreadable.
spec_round_answer_load() {
  local text
  file_read text "$1/$SPEC_ROUND_APPLY_ANSWER" 2>/dev/null \
    || die "$1/$SPEC_ROUND_APPLY_ANSWER is unreadable - rerun the round"
  eval "$2=($text)" 2>/dev/null \
    || die "$1/$SPEC_ROUND_APPLY_ANSWER is unreadable - rerun the round"
}

# spec_round_answer_clear <dir> <landed>: the saved answer and its file copies
# removed, at the end of the run that no resume continues. <landed> names the
# GitHub writes that landed, for the message.
spec_round_answer_clear() {
  rm -f "$1/$SPEC_ROUND_APPLY_ANSWER" "$1"/apply-*.copy 2>/dev/null \
    || die "could not remove $1/$SPEC_ROUND_APPLY_ANSWER - every GitHub write landed: $2"
}

# spec_round_hold <dir> <blocks>: the end of an autopilot round's first run -
# the held-back fundamental items' <blocks> written, byte for byte, to
# <dir>/fundamental.md: the round's save point, which spec round reports as
# waiting.
spec_round_hold() {
  { printf '%s' "$2" >"$1/$SPEC_ROUND_FUNDAMENTAL"; } 2>/dev/null \
    || die "could not write $1/$SPEC_ROUND_FUNDAMENTAL - nothing written to GitHub"
}

# spec_round_complete <dir> <changelog> <landed>: the round's local tail once
# its changelog comment landed, safe to run again: <changelog> appended to
# settled.md unless it already ends with it (a settled.md that cannot be read
# is not taken to), fundamental.md removed, round-complete written, the saved
# answer cleared. <landed> names the GitHub writes, for the messages.
spec_round_complete() {
  local dir="$1" log="$2" landed="$3" n
  n="$(printf '%s\n' "$log" | wc -c)"
  if [ ! -f "$dir/settled.md" ] || [ "$(tail -c "$n" "$dir/settled.md" 2>/dev/null)" != "$log" ]; then
    { printf '%s\n' "$log" >>"$dir/settled.md"; } 2>/dev/null \
      || die "could not append the changelog to $dir/settled.md - every GitHub write landed: $landed"
  fi
  rm -f "$dir/$SPEC_ROUND_FUNDAMENTAL" 2>/dev/null \
    && [ ! -e "$dir/$SPEC_ROUND_FUNDAMENTAL" ] \
    || die "could not remove $dir/$SPEC_ROUND_FUNDAMENTAL - every GitHub write landed and settled.md is appended: $landed"
  # The round's completion, the very last local step but the answer's clearing:
  # spec round reads it to tell a resumed flow which round runs next.
  { : >"$dir/$SPEC_ROUND_COMPLETE"; } 2>/dev/null \
    || die "could not write $dir/$SPEC_ROUND_COMPLETE - every GitHub write landed and settled.md is appended: $landed"
  spec_round_answer_clear "$dir" "$landed"
}

# spec_rounds_dir <var>: assigns the flow's rounds directory to <var>.
spec_rounds_dir() { printf -v "$1" '%s' "$SPEC_ROUNDS_DIR"; }

# spec_round_in_flow <dir>: whether <dir> is under a flow's rounds directory,
# at any depth - a flow's round directory, not a standalone review's.
spec_round_in_flow() {
  case "${1%/}/" in "$SPEC_ROUNDS_DIR"/?*) return 0 ;; esac
  return 1
}

# spec_round_dir_reset <dir> [--carry]: a round's working directory made ready
# to run in - the one reset both a standalone review's spec-review begin and a
# flow's spec round-dir run. With --carry, every entry of an existing <dir>
# but the code map and the settled file is deleted in place, keeping what a
# round hands the next; without it <dir> is removed whole. Either way <dir> is
# then created when missing.
spec_round_dir_reset() {
  local dir="$1"
  if [ "${2:-}" = --carry ] && [ -d "$dir" ]; then
    local keep=() f
    for f in "${SPEC_ROUND_CARRIED[@]}"; do keep+=(! -name "$f"); done
    find "$dir" -mindepth 1 -maxdepth 1 "${keep[@]}" -exec rm -rf {} +
  else
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
}

# spec_round_carry <k>: copies into round k's directory what round k-1 of a
# flow's review hands it - the lens setting, the code map and the settled file,
# each when it exists; dies when a copy fails. A copy, not a carry in place:
# every round keeps its own directory for the final session to read its
# changelog from.
spec_round_carry() {
  local k="$1" f
  for f in "$SPEC_ROUND_LENS_SETTING" "${SPEC_ROUND_CARRIED[@]}"; do
    [ ! -f "$SPEC_ROUNDS_DIR/$((k - 1))/$f" ] \
      || cp "$SPEC_ROUNDS_DIR/$((k - 1))/$f" "$SPEC_ROUNDS_DIR/$k/$f" \
      || die "cannot copy round $((k - 1))'s $f into $SPEC_ROUNDS_DIR/$k"
  done
}

# spec_round_number <s>: whether <s> is a positive whole number with no
# leading zero - a round or a round count.
spec_round_number() {
  case "$1" in ''|*[!0-9]*|0*) return 1 ;; esac
}

# spec_round_count_parse <k>/<n> <k-var> <n-var>: a round and the round count,
# two positive whole numbers with k no greater than n, into the variables
# named; dies otherwise.
spec_round_count_parse() {
  local __rc_arg="$1" __rc_k __rc_n
  local __rc_want="want <k>/<n>, a round and the round count, two positive whole numbers, got: $__rc_arg"
  case "$__rc_arg" in */*) ;; *) die "$__rc_want" ;; esac
  __rc_k="${__rc_arg%%/*}"; __rc_n="${__rc_arg#*/}"
  spec_round_number "$__rc_k" && spec_round_number "$__rc_n" || die "$__rc_want"
  [ "$__rc_k" -le "$__rc_n" ] || die "round $__rc_k is past the round count $__rc_n"
  printf -v "$2" '%s' "$__rc_k"
  printf -v "$3" '%s' "$__rc_n"
}

# spec pause --round <k>/<n> (#1347): the stop after round k of n, k < n, has
# applied its answer - writes the round marker naming the flow's issue, the
# next round k+1 and the count n, so the fresh session's spec round resumes
# there, then prints the stop block. The marker is written first, so a failed
# write prints no block. The last round never pauses: the ticket breakdown and
# the handoff follow it in the same session.
cmd_spec_pause_round() {
  local issue="$1" phase="$2"
  shift 2
  [ $# -eq 1 ] || die "usage: orch.sh spec pause [--round <k>/<n>]"
  local k n
  spec_round_count_parse "$1" k n
  [ "$k" -lt "$n" ] \
    || die "round $k is the last of $n - the last round never pauses; go on to the ticket breakdown"
  spec_phase_guard die pause issue "$issue" "$phase"
  spec_marker_write "$SPEC_ROUND_MARKER" "$issue $((k + 1)) $n"
  # In autopilot the round's session ends here: the claim is released, and the
  # next tick starts the next round.
  ! autopilot_active || standing_pause "$issue" "wrote the round marker"
  print_next_block "Spec review round $k of $n applied. Round $((k + 1)) runs in a fresh session."
}

# spec round-dir <k>/<n>: round k's working directory made ready and printed,
# then the round marker written naming the flow's issue, k and n - last, so a
# failed write prints no path and a round never runs without its marker.
# Ready means emptied (created when missing); on round 1 every other round's
# directory deleted, a redone review leaking nothing stale; on a later round
# round k-1's lens setting, code map and settled file copied in, each when it
# exists - a copy, not a carry in place, since every round keeps its own
# directory for the final session to read its changelog from. Idempotent.
cmd_spec_round_dir() {
  local issue="$1" phase="$2"
  shift 2
  local usage="usage: orch.sh spec round-dir <k>/<n>"
  [ $# -eq 1 ] || die "$usage"
  local k n
  spec_round_count_parse "$1" k n
  spec_phase_guard die round-dir issue "$issue" "$phase"
  local dir="$SPEC_ROUNDS_DIR/$k"
  spec_round_dir_reset "$dir"
  if [ "$k" -eq 1 ]; then
    find "$SPEC_ROUNDS_DIR" -mindepth 1 -maxdepth 1 ! -name 1 -exec rm -rf {} +
  else
    spec_round_carry "$k"
  fi
  spec_marker_write "$SPEC_ROUND_MARKER" "$issue $k $n"
  printf '%s/\n' "$dir"
}

# spec round: the round a resumed flow's spec review runs next, from the
# round marker - `<k> <n> applying` while the marker's round holds a saved
# apply answer (an apply died), `<k> <n> waiting` while the marker's round holds
# fundamental
# items back for the human's answer (autopilot), else `<k> <n>`, the marker's k,
# or k+1 once round k's directory holds round-complete - or `done <n>` once
# round n's does. Exit 1, printing nothing, when there is no marker or it names
# another issue; every failure is exit 2, so a caller never reads one as
# "no marker".
cmd_spec_round() {
  [ $# -eq 0 ] || die2 "usage: orch.sh spec round"
  local issue phase marker="$HANDOFF_DIR/$SPEC_ROUND_MARKER" line m_issue k n extra
  require_state_read die2 issue=issue phase=phase
  spec_phase_guard die2 round issue "$issue" "$phase"
  [ -f "$marker" ] || return 1
  line=""
  IFS= read -r line <"$marker" || [ -n "$line" ] \
    || die2 "malformed round marker $marker: it is empty - want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"
  read -r m_issue k n extra <<<"$line"
  local malformed="malformed round marker $marker: '$line' - want <issue> <k> <n>; rerun orch.sh spec round-dir <k>/<n>"
  case "$m_issue" in ''|*[!0-9]*) die2 "$malformed" ;; esac
  spec_round_number "$k" && spec_round_number "$n" && [ -z "$extra" ] && [ "$k" -le "$n" ] \
    || die2 "$malformed"
  [ "$m_issue" = "$issue" ] || return 1
  local state
  spec_round_state "$SPEC_ROUNDS_DIR/$k" state
  case "$state" in
    applying|waiting) printf '%s %s %s\n' "$k" "$n" "$state" ;;
    open) printf '%s %s\n' "$k" "$n" ;;
    *)
      if [ "$k" -lt "$n" ]; then printf '%s %s\n' "$((k + 1))" "$n"; else printf 'done %s\n' "$n"; fi ;;
  esac
}
