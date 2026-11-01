# shellcheck shell=bash
# shellcheck disable=SC2034 # the TIMELINE_* results are read by the queries' callers
# issue-timeline.sh - the Issue timeline module: a concept module with no
# orch.sh noun of its own, one reader over one issue's comment history. It reads
# the comments once (timeline_read) and then answers domain questions from that
# read, with no gh call and no 0/1/2 exit code. The three queries that find a
# comment - timeline_question, timeline_stop and timeline_handoff - print
# nothing: they report it through named results (TIMELINE_Q_*, TIMELINE_STOP_*,
# TIMELINE_HANDOFF_INDEX), return 0 when they find it and 1 when they do not,
# and clear their results first, so a miss leaves them empty. Call them
# directly, never inside $(...), whose assignments do not reach the caller.
# timeline_replied answers by its return code alone. Of the printing queries,
# one that finds nothing prints nothing and returns 1, bar three:
# timeline_limit_count always prints a number and returns 0, timeline_answers
# prints nothing and returns 0 when no comment follows the question, and
# timeline_body always prints the indexed comment's body (possibly empty) and
# returns 0. Only the read can fail, and the two helpers documented beside it,
# timeline_die and timeline_read_or_die, are the module's only dying ones. The
# marker grammar stays in the Marked comment module (its jq prelude) and here.
# Its tests: scripts/test/orch/issue-timeline.sh.
# Sourced by orch.sh, after common.sh and the ROOT block; marked_comment_jq is
# expanded at call time, so marked-comment.sh may load after it. Layering:
# Marked comment, then Issue timeline, then Standing, autopilot and handoff.
#
# The rule for a stop lives here: a refusal or a failure comment is a stop (a
# limit stop is not), the legacy prose-opened ones included, which the Marked
# comment module already reads as those kinds.
#
# The queries: timeline_question, timeline_replied, timeline_answers,
# timeline_stop, timeline_limit_count, timeline_handoff and timeline_body.

# The last read: the comments JSON, why the read failed (gh's reason, or empty
# when gh succeeded but its output could not be parsed), and per comment, by
# index, its kind, argument, retired flag and URL (empty when unmarked).
TIMELINE_JSON='[]'
TIMELINE_REASON=""
TIMELINE_KIND=()
TIMELINE_ARG=()
TIMELINE_RETIRED=()
TIMELINE_URL=()
# The named results of timeline_question, timeline_stop and timeline_handoff;
# empty when the query found nothing.
TIMELINE_Q_INDEX="" TIMELINE_Q_PHASE="" TIMELINE_Q_URL=""
TIMELINE_STOP_INDEX="" TIMELINE_STOP_KIND="" TIMELINE_STOP_PHASE="" TIMELINE_STOP_URL=""
TIMELINE_HANDOFF_INDEX=""

# timeline_read <issue>: reads the issue's comments from GitHub once, into the
# arrays above, replacing the last read - a failed read too, after which every
# query answers none. Returns non-zero, never dies, when the comments cannot be
# read: TIMELINE_REASON holds gh's reason, or is empty for output that is not a
# comment list.
timeline_read() {
  local json gh_err text rows line kind arg retired url
  TIMELINE_JSON='[]' TIMELINE_REASON=""
  TIMELINE_Q_INDEX="" TIMELINE_Q_PHASE="" TIMELINE_Q_URL=""
  TIMELINE_STOP_INDEX="" TIMELINE_STOP_KIND="" TIMELINE_STOP_PHASE="" TIMELINE_STOP_URL=""
  TIMELINE_HANDOFF_INDEX=""
  TIMELINE_KIND=() TIMELINE_ARG=() TIMELINE_RETIRED=() TIMELINE_URL=()
  if ! capture json gh_err adapter_issue_comments_json "$1"; then
    TIMELINE_REASON="$(gh_reason "$gh_err")"
    return 1
  fi
  # One pass: the first line is the comment list, compact, then one row per
  # comment.
  text="$(jq -r "$(marked_comment_jq)"'
    (marked_comment_list | tojson),
    (marked_comment_entries[]
     | [(.info.kind // ""), (.info.arg // ""),
        (if .info.retired then "r" else "" end), (.c.url // "")]
     | @tsv)' <<<"$json" 2>/dev/null)" || return 1
  TIMELINE_JSON="${text%%$'\n'*}"
  rows=""
  case "$text" in *$'\n'*) rows="${text#*$'\n'}" ;; esac
  [ -z "$rows" ] || while IFS= read -r line; do
    tsv_split "$line" kind arg retired url
    TIMELINE_KIND+=("$kind")
    TIMELINE_ARG+=("$arg")
    TIMELINE_RETIRED+=("$retired")
    TIMELINE_URL+=("$url")
  done <<<"$rows"
}

# timeline_die <issue>: dies (exit 1) for the timeline read that just failed,
# with gh's reason, or with `could not read issue #<n>'s comments` when gh
# succeeded but its output was not a comment list.
timeline_die() {
  [ -n "$TIMELINE_REASON" ] || die "could not read issue #$1's comments"
  gh_die "read the comments of issue #$1" "$TIMELINE_REASON"
}

# timeline_read_or_die <issue>: timeline_read, else timeline_die.
timeline_read_or_die() {
  timeline_read "$1" || timeline_die "$1"
}

# timeline_question [<phase>]: the newest question comment, of <phase> when
# given, else of any phase: sets TIMELINE_Q_INDEX, TIMELINE_Q_PHASE and
# TIMELINE_Q_URL and returns 0. Returns 1, the results empty, when there is
# none. Prints nothing.
timeline_question() {
  local i
  TIMELINE_Q_INDEX="" TIMELINE_Q_PHASE="" TIMELINE_Q_URL=""
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    [ "${TIMELINE_KIND[i]}" = question ] || continue
    [ -z "${1-}" ] || [ "${TIMELINE_ARG[i]}" = "$1" ] || continue
    TIMELINE_Q_INDEX="$i" TIMELINE_Q_PHASE="${TIMELINE_ARG[i]}" TIMELINE_Q_URL="${TIMELINE_URL[i]}"
    return 0
  done
  return 1
}

# timeline_replied [<phase>]: succeeds when a comment follows the newest
# question comment timeline_question finds; fails when none does or there is
# no question.
timeline_replied() {
  timeline_question "$@" || return 1
  [ "$TIMELINE_Q_INDEX" -lt $((${#TIMELINE_KIND[@]} - 1)) ]
}

# timeline_answers [<phase>]: the bodies of the comments after the newest
# question comment, each after a `---` line, exactly, trailing newlines kept
# (read it with a sentinel). Prints nothing when none follows; returns 1 only
# when there is no question.
timeline_answers() {
  timeline_question "$@" || return 1
  jq -j --argjson i "$TIMELINE_Q_INDEX" '.[$i + 1:] | map("\n---\n" + (.body // "")) | join("")' <<<"$TIMELINE_JSON"
}

# timeline_stop: the latest stop - the newest refusal or failure comment:
# sets TIMELINE_STOP_INDEX, TIMELINE_STOP_KIND (refusal or failure),
# TIMELINE_STOP_PHASE and TIMELINE_STOP_URL and returns 0. Returns 1, the
# results empty, when there is none. Prints nothing.
timeline_stop() {
  local i
  TIMELINE_STOP_INDEX="" TIMELINE_STOP_KIND="" TIMELINE_STOP_PHASE="" TIMELINE_STOP_URL=""
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    case "${TIMELINE_KIND[i]}" in
      refusal | failure)
        TIMELINE_STOP_INDEX="$i" TIMELINE_STOP_KIND="${TIMELINE_KIND[i]}"
        TIMELINE_STOP_PHASE="${TIMELINE_ARG[i]}" TIMELINE_STOP_URL="${TIMELINE_URL[i]}"
        return 0 ;;
    esac
  done
  return 1
}

# timeline_limit_count <phase>: prints the number of <phase>'s limit stops in a
# row, counted newest first up to the first stop, question comment, handoff
# comment, or limit stop of another phase; other comments are skipped. Always
# prints a number (0 for none) and returns 0.
timeline_limit_count() {
  local i n=0
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    case "${TIMELINE_KIND[i]}" in
      refusal | failure | question | handoff) break ;;
      limited)
        [ "${TIMELINE_ARG[i]}" = "$1" ] || break
        n=$((n + 1)) ;;
    esac
  done
  printf '%s\n' "$n"
}

# timeline_handoff <name>: the live handoff of <name> - its newest comment, when
# it is not retired: sets TIMELINE_HANDOFF_INDEX to its index and returns 0.
# Returns 1, the result empty, when there is none or the newest is retired.
# Prints nothing.
timeline_handoff() {
  local i
  TIMELINE_HANDOFF_INDEX=""
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    [ "${TIMELINE_KIND[i]}" = handoff ] && [ "${TIMELINE_ARG[i]}" = "$1" ] || continue
    [ -z "${TIMELINE_RETIRED[i]}" ] || return 1
    TIMELINE_HANDOFF_INDEX="$i"
    return 0
  done
  return 1
}

# timeline_body <index>: the body of comment <index> with its first line
# stripped, printed exactly, trailing newlines kept (read it with a sentinel).
# Always returns 0; prints nothing for a comment with no body.
timeline_body() {
  jq -j --argjson i "$1" '.[$i].body // "" | (index("\n") // empty) as $n | .[$n + 1:]' <<<"$TIMELINE_JSON"
}
