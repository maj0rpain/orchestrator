# shellcheck shell=bash
# shellcheck disable=SC2034 # its SESSION_LOG_* results are read by the callers
# session-log.sh - the Session log module, a concept module with no noun: what
# a phase session's log says about Claude Code usage limits. Its one entry
# point, session_log_read, reads the log in a single pass; the Liveness module
# names the log files, this module reads them. Times are epoch seconds.
# Tested by scripts/test/orch/session-log.sh and, through autopilot_session_end,
# scripts/test/orch/autopilot.sh.

# The text of Claude Code's usage-limit message, with its reset time when it
# gives one: an epoch after `|`, or a `resets <time>`.
SESSION_LOG_LIMIT_PATTERN='(usage|[0-9]+-hour|weekly) limit reached(\|[0-9]+|[^|]{0,8}resets [^|]*)?'

# session_log_resets_epoch <text>: the next moment, in local time and as epoch
# seconds, of the `resets [<weekday>] <h>[:<mm>]<am|pm>` time in <text>, such
# as "resets 3pm" or "resets Mon 9am"; non-zero, nothing printed, when <text>
# holds none. A time already past today is the same time tomorrow, or, with a
# weekday, a week on at most.
session_log_resets_epoch() {
  local text re day="" h m ap now_epoch since target_since target clock shift_secs ahead cur i d
  text="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  re='resets[[:space:]]+(([a-z]{3})[a-z]*[[:space:]]+)?([0-9]{1,2})(:([0-9]{2}))?[[:space:]]*(am|pm)'
  [[ "$text" =~ $re ]] || return 1
  day="${BASH_REMATCH[2]}"; h="$((10#${BASH_REMATCH[3]}))"; m="$((10#${BASH_REMATCH[5]:-0}))"; ap="${BASH_REMATCH[6]}"
  [ "$h" -ge 1 ] && [ "$h" -le 12 ] && [ "$m" -le 59 ] || return 1
  [ "$ap" = pm ] && [ "$h" -ne 12 ] && h=$((h + 12))
  [ "$ap" = am ] && [ "$h" -eq 12 ] && h=0
  now_epoch="$(date +%s)"
  since="$(( 10#$(date +%H) * 3600 + 10#$(date +%M) * 60 + 10#$(date +%S) ))"
  target="$(( now_epoch - since + h * 3600 + m * 60 ))"
  if [ -n "$day" ]; then
    ahead=""
    cur="$(date +%u)"
    i=0
    for d in mon tue wed thu fri sat sun; do
      i=$((i + 1))
      [ "$d" != "$day" ] || ahead="$(( (i - cur + 7) % 7 ))"
    done
    [ -n "$ahead" ] || return 1
    target=$((target + ahead * 86400))
    [ "$target" -gt "$now_epoch" ] || target=$((target + 7 * 86400))
  else
    [ "$target" -gt "$now_epoch" ] || target=$((target + 86400))
  fi
  # A clock change between now and then shifts the hour: pull the target back to
  # the wanted local time of day.
  clock="$(date -d "@$target" +%H:%M:%S 2>/dev/null || date -r "$target" +%H:%M:%S)"
  target_since="$(( 10#${clock:0:2} * 3600 + 10#${clock:3:2} * 60 + 10#${clock:6:2} ))"
  shift_secs="$(( h * 3600 + m * 60 - target_since ))"
  [ "$shift_secs" -le 43200 ] || shift_secs=$((shift_secs - 86400))
  [ "$shift_secs" -ge -43200 ] || shift_secs=$((shift_secs + 86400))
  printf '%s\n' "$((target + shift_secs))"
}

# session_log_read <log>: reads the session log <log> in one jq pass and sets,
# in the current shell, all four of these, first clearing any earlier call's:
#   SESSION_LOG_LIMITED  1 when the session stopped on a usage limit, else 0
#   SESSION_LOG_RESET    the reset it named, epoch seconds; empty when none
#   SESSION_LOG_EARLY    the five-hour window's resetsAt, epoch seconds, when
#                        its utilization is 0.9 or more; else empty
#   SESSION_LOG_REPLY    the last result event's text as one line, cut to 500
#                        characters with "…" appended; empty when it has none
# The last rate_limit_event decides first: a window (top level or under
# unifiedWindows) whose status is neither allowed nor allowed_warning is a
# limit stop at the latest resetsAt among such windows, or at none. Only
# without one is the text read - the lines that do not parse as JSON in log
# order, then the last result event's text, never an assistant message or a
# tool result - and the last usage-limit message in it decides the reset. A
# missing or unreadable log, or a jq failure, leaves it not limited and the
# rest empty.
session_log_read() {
  local out rejecting_reset="" text hit
  SESSION_LOG_LIMITED=0; SESSION_LOG_RESET=""; SESSION_LOG_EARLY=""; SESSION_LOG_REPLY=""
  out="$(jq -nrR '
    reduce inputs as $line ({last_rate_limit: null, last_result: null, plain_lines: []};
      (try {json: ($line | fromjson)} catch {plain: $line}) as $entry
      | if $entry | has("plain") then .plain_lines += [$entry.plain]
        elif ($entry.json | type) == "object" and $entry.json.type == "rate_limit_event" then .last_rate_limit = $entry.json
        elif ($entry.json | type) == "object" and $entry.json.type == "result" then .last_result = $entry.json
        else . end)
    | ((.last_rate_limit // {}) | try (.rate_limit_info // {} | [., (.unifiedWindows // {} | .[])]
        | map(select(type == "object" and ((.status // "allowed") | IN("allowed", "allowed_warning") | not)))
        | if length == 0 then "none" else ([.[].resetsAt | numbers | floor] | max // "") end) catch "none") as $rejecting_reset
    | (((.last_rate_limit // {}) | try (.rate_limit_info // {}
        | (if .rateLimitType == "five_hour" then . else .unifiedWindows.five_hour end) // {}
        | select((.utilization | numbers) >= 0.9) | .resetsAt | numbers | floor) catch empty) // "" | tostring) as $early
    | ((.last_result // {} | try (.result | strings) catch empty) // "") as $result
    | ($rejecting_reset | tostring), $early,
      ($result | gsub("\\s+"; " ") | gsub("^ | $"; "")
        | if length > 500 then .[:500] + "…" else . end),
      (.plain_lines[]), $result' "$1" 2>/dev/null)" || return 0
  # read fails at end of input when `$(...)` trimmed trailing empty lines
  { IFS= read -r rejecting_reset || true; IFS= read -r SESSION_LOG_EARLY || true; IFS= read -r SESSION_LOG_REPLY || true; text="$(cat)"; } <<<"$out"
  if [ "$rejecting_reset" != none ]; then
    SESSION_LOG_LIMITED=1
    SESSION_LOG_RESET="$rejecting_reset"
    return 0
  fi
  hit="$(grep -Eio "$SESSION_LOG_LIMIT_PATTERN" <<<"$text" | tail -n 1)" || true
  [ -n "$hit" ] || return 0
  SESSION_LOG_LIMITED=1
  case "$hit" in
    *'|'*) SESSION_LOG_RESET="${hit##*|}" ;;
    *) SESSION_LOG_RESET="$(session_log_resets_epoch "$hit")" || SESSION_LOG_RESET="" ;;
  esac
  return 0
}
