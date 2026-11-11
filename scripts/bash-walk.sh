# shellcheck shell=bash
# bash-walk.sh - the command walker and in-scope filter the two Bash hooks
# share. Sourced by hook-bash-stdin.sh and hook-bash-poll.sh, not executed on
# its own.

# The jq prefix the Bash hooks' filters share: binds $c to the command string
# and keeps only an in-scope payload ($auto is the ORCH_AUTOPILOT value).
# shellcheck disable=SC2034 # read by the hooks that source this file
HOOK_BASH_SCOPE='
  (.tool_input.command? // null) as $c
  | select(($c | type) == "string")
  | select($auto == "1" or ((.agent_type? // "") | type == "string"
      and (startswith("orchestrator:orch-") or startswith("orch-"))))
  | '

# Calls hook_bash_walk's test with the part, its unquoted text and its head, then
# starts the next part's head. Reads hook_bash_walk's locals (dynamic scope).
hook_bash_walk_call() {
  local hd="$part"
  [ "$head_set" = 1 ] && hd="$head"
  head=""; head_set=0
  "$test_fn" "$part" "$unq" "$hd"
}

# The command walker (#2085): splits command $1 into parts - on `;`, `&&`, `||`
# and newlines, outside single and double quotes and outside heredoc bodies; an
# unquoted `#` at a word start ends its line - and
# calls the test "$2" with each part, its unquoted text (the part with every
# quoted span, quotes included, replaced by a space) and its head: the part's
# text before its first unquoted single `|` (a `|&` counts as that `|`; the head
# holds neither), or the whole part when it holds none, also across a trailing-`|`
# line continuation. The first part whose test
# succeeds ends the walk, with the test's output; the walk always succeeds. A
# command over 8 KB is not scanned (a false negative), to stay fast.
hook_bash_walk() {
  local cmd="$1" test_fn="$2" line part="" unq="" head="" head_set=0 quote="" heredoc_end="" heredoc_strip_tabs=0 continued=0 i c n rest re
  [ "${#cmd}" -le 8192 ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$heredoc_end" ]; then
      [ "$heredoc_strip_tabs" = 1 ] && line="${line#"${line%%[!$'\t']*}"}"
      [ "$line" = "$heredoc_end" ] && heredoc_end=""
      continue
    fi
    n=${#line}; i=0; continued=0
    while [ "$i" -lt "$n" ]; do
      rest="${line:i}"
      if [ -z "$quote" ]; then re='^[^'"'"'"\\#;&|<]+'
      elif [[ "$quote" == "'" ]]; then re="^[^']+"
      else re='^[^"\\]+'; fi
      if [[ "$rest" =~ $re ]]; then part+="${BASH_REMATCH[0]}"; [ -n "$quote" ] || unq+="${BASH_REMATCH[0]}"; i=$((i + ${#BASH_REMATCH[0]})); continue; fi
      c="${rest::1}"
      if [ -n "$quote" ]; then
        if [ "$quote" = '"' ] && [ "$c" = '\' ]; then
          part+="$c${line:i+1:1}"; i=$((i + 2)); continue
        fi
        [ "$c" = "$quote" ] && quote=""
        part+="$c"
      else
        case "$c" in
          "'"|'"') quote="$c"; part+="$c"; unq+=" " ;;
          '\')
            if [ "$((i + 1))" -ge "$n" ]; then continued=1; i=$((i + 2)); continue; fi
            unq+="$c${line:i+1:1}"; part+="$c${line:i+1:1}"; i=$((i + 2)); continue ;;
          '#')
            if [ -z "$part" ] || [[ "${part: -1}" == [[:space:]] ]]; then break; fi
            part+="$c"; unq+="$c" ;;
          ';') hook_bash_walk_call && return 0; part=""; unq="" ;;
          '&'|'|')
            if [ "${line:i+1:1}" = "$c" ]; then
              hook_bash_walk_call && return 0
              part=""; unq=""; i=$((i + 2)); continue
            fi
            if [ "$c" = "|" ] && [ "$head_set" = 0 ]; then head="$part"; head_set=1; fi
            part+="$c"; unq+="$c" ;;
          '<')
            if [ "${line:i:3}" = '<<<' ]; then part+="<<<"; unq+="<<<"; i=$((i + 3)); continue; fi
            if [[ "$rest" =~ ^\<\<(-?)[[:space:]]*\\?[\'\"]?([A-Za-z_][A-Za-z0-9_]*)[\'\"]? ]]; then
              heredoc_end="${BASH_REMATCH[2]}"; heredoc_strip_tabs=0; [ -n "${BASH_REMATCH[1]}" ] && heredoc_strip_tabs=1
            fi
            part+="$c"; unq+="$c" ;;
          *) part+="$c"; unq+="$c" ;;
        esac
      fi
      i=$((i + 1))
    done
    if [ "$continued" = 1 ]; then
      :
    elif [ -z "$quote" ] && [[ "$part" =~ \|[[:space:]]*$ ]]; then
      :  # a trailing lone | continues the pipeline on the next line
    elif [ -z "$quote" ]; then
      hook_bash_walk_call && return 0
      part=""; unq=""
    else
      part+=$'\n'
    fi
  done <<<"$cmd"
  hook_bash_walk_call
  return 0
}
