# shellcheck shell=bash
# shellcheck disable=SC2034 # TIMELINE_REASON is read by timeline_read's callers
# issue-timeline.sh - the Issue timeline module: a concept module with no
# orch.sh noun of its own, one reader over one issue's comment history. It reads
# the comments once (timeline_read) and then answers domain questions from that
# read, with no gh call and no 0/1/2 exit code: a query that finds nothing
# prints nothing and returns 1, bar two: timeline_limit_count always prints a
# number and returns 0, and timeline_answers prints nothing and returns 0 when
# no comment follows the question. Only the read can fail. The marker grammar
# stays in the Marked comment module (its jq prelude) and here. Its tests:
# scripts/test/orch/issue-timeline.sh.
# Sourced by orch.sh, after marked-comment.sh and gh.sh; layering: Marked
# comment, then Issue timeline, then Standing, autopilot and handoff.
#
# The rule for a stop lives here: a refusal or a failure comment is a stop (a
# limit stop is not), the legacy prose-opened ones included, which the Marked
# comment module already reads as those kinds.
#
# The reader that dies: timeline_read_or_die. The queries: timeline_question,
# timeline_replied, timeline_answers,
# timeline_stop, timeline_limit_count, timeline_handoff and timeline_body.

# The last read: the comments JSON, why the read failed (gh's reason, or empty
# when gh succeeded but its output could not be parsed), and per comment, by
# index, its kind, argument, retired flag and URL (empty when unmarked).
TIMELINE_JSON='[]'
# shellcheck disable=SC2034 # read by the callers of timeline_read
TIMELINE_REASON=""
TIMELINE_KIND=()
TIMELINE_ARG=()
TIMELINE_RETIRED=()
TIMELINE_URL=()

# timeline_read <issue>: reads the issue's comments from GitHub once, into the
# arrays above, replacing the last read - a failed read too, after which every
# query answers none. Returns non-zero, never dies, when the comments cannot be
# read: TIMELINE_REASON holds gh's reason, or is empty for output that is not a
# comment list.
timeline_read() {
  local json gh_err text kind arg retired url
  TIMELINE_JSON='[]' TIMELINE_REASON=""
  TIMELINE_KIND=() TIMELINE_ARG=() TIMELINE_RETIRED=() TIMELINE_URL=()
  if ! capture json gh_err adapter_issue_comments_json "$1"; then
    TIMELINE_REASON="$(gh_reason "$gh_err")"
    return 1
  fi
  # Every field is prefixed with _ so an empty one survives the tab split.
  text="$(jq -r "$(marked_comment_jq)"'
    marked_comment_entries[]
    | ["_" + (.info.kind // ""), "_" + (.info.arg // ""),
       "_" + (if .info.retired then "r" else "" end), "_" + (.c.url // "")]
    | @tsv' <<<"$json" 2>/dev/null)" || return 1
  TIMELINE_JSON="$(jq -c "$(marked_comment_jq)"' marked_comment_list' <<<"$json" 2>/dev/null)" || return 1
  while IFS=$'\t' read -r kind arg retired url; do
    TIMELINE_KIND+=("${kind#_}")
    TIMELINE_ARG+=("${arg#_}")
    TIMELINE_RETIRED+=("${retired#_}")
    TIMELINE_URL+=("${url#_}")
  done <<<"$text"
  # An empty comment list reads one blank line.
  if [ -z "$text" ]; then TIMELINE_KIND=() TIMELINE_ARG=() TIMELINE_RETIRED=() TIMELINE_URL=(); fi
}

# timeline_read_or_die <issue> [2]: timeline_read, dying when it cannot: with
# gh's wording when gh failed, with "could not read issue #<issue>'s comments"
# when its output was no comment list - status 1, or 2 when the second argument
# is 2.
timeline_read_or_die() {
  local issue="$1" code="${2-1}"
  timeline_read "$issue" && return 0
  if [ -z "$TIMELINE_REASON" ]; then
    if [ "$code" = 2 ]; then die2 "could not read issue #$issue's comments"; fi
    die "could not read issue #$issue's comments"
  fi
  if [ "$code" = 2 ]; then gh_die --exit 2 "read the comments of issue #$issue" "$TIMELINE_REASON"; fi
  gh_die "read the comments of issue #$issue" "$TIMELINE_REASON"
}

# timeline_question [<phase>]: the newest question comment, of <phase> when
# given, else of any phase: prints its index, phase and URL, tab-separated.
# Returns 1, printing nothing, when there is none.
timeline_question() {
  local i
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    [ "${TIMELINE_KIND[i]}" = question ] || continue
    [ -z "${1-}" ] || [ "${TIMELINE_ARG[i]}" = "$1" ] || continue
    printf '%s\t%s\t%s\n' "$i" "${TIMELINE_ARG[i]}" "${TIMELINE_URL[i]}"
    return 0
  done
  return 1
}

# timeline_replied [<phase>]: succeeds when a comment follows the newest
# question comment timeline_question finds; fails when none does or there is
# no question.
timeline_replied() {
  local q
  q="$(timeline_question "$@")" || return 1
  [ "${q%%$'\t'*}" -lt $((${#TIMELINE_KIND[@]} - 1)) ]
}

# timeline_answers [<phase>]: the bodies of the comments after the newest
# question comment, each after a `---` line, exactly, trailing newlines kept
# (read it with a sentinel). Prints nothing when none follows; returns 1 only
# when there is no question.
timeline_answers() {
  local q
  q="$(timeline_question "$@")" || return 1
  jq -j --argjson i "${q%%$'\t'*}" '.[$i + 1:] | map("\n---\n" + (.body // "")) | join("")' <<<"$TIMELINE_JSON"
}

# timeline_stop: the latest stop - the newest refusal or failure comment: prints
# its index, kind, phase and URL, tab-separated. Returns 1, printing nothing,
# when there is none.
timeline_stop() {
  local i
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    case "${TIMELINE_KIND[i]}" in
      refusal | failure)
        printf '%s\t%s\t%s\t%s\n' "$i" "${TIMELINE_KIND[i]}" "${TIMELINE_ARG[i]}" "${TIMELINE_URL[i]}"
        return 0 ;;
    esac
  done
  return 1
}

# timeline_limit_count <phase>: prints the number of <phase>'s limit stops in a
# row, counted newest first up to the first stop, question comment, handoff
# comment, or limit stop of another phase; other comments are skipped.
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
# it is not retired: prints its index. Returns 1, printing nothing, when there
# is none or the newest is retired.
timeline_handoff() {
  local i
  for ((i = ${#TIMELINE_KIND[@]} - 1; i >= 0; i--)); do
    [ "${TIMELINE_KIND[i]}" = handoff ] && [ "${TIMELINE_ARG[i]}" = "$1" ] || continue
    [ -z "${TIMELINE_RETIRED[i]}" ] || return 1
    printf '%s\n' "$i"
    return 0
  done
  return 1
}

# timeline_body <index>: the body of comment <index> with its first line
# stripped, printed exactly, trailing newlines kept (read it with a sentinel).
timeline_body() {
  jq -j --argjson i "$1" '.[$i].body // "" | (index("\n") // empty) as $n | .[$n + 1:]' <<<"$TIMELINE_JSON"
}
