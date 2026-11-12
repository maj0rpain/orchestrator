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

# True while unquoted text $1 holds more `((` than `))`: a `<<` there is an
# arithmetic shift, not a heredoc.
_hook_bash_in_arith() {
  local t="$1" no_open no_close
  no_open="${t//((/}"; no_close="${t//))/}"
  [ "$(( ${#t} - ${#no_open} ))" -gt "$(( ${#t} - ${#no_close} ))" ]
}

# Reads the heredoc delimiter at the start of $1 (the text after `<<`) as
# bash's whole shell word: after `-` and blanks, unquoted characters other
# than blanks and `;&|<>()`, single- and double-quoted spans and backslash
# escapes, with quotes removed. Sets HOOK_BASH_HEREDOC_WORD and
# HOOK_BASH_HEREDOC_STRIP (1 for `<<-`); fails when no character forms a word
# (an empty quoted word is a word).
_hook_bash_heredoc_word() {
  local w="$1" word="" j=0 ch q tail
  HOOK_BASH_HEREDOC_STRIP=0
  if [ "${w::1}" = "-" ]; then HOOK_BASH_HEREDOC_STRIP=1; w="${w:1}"; fi
  w="${w#"${w%%[![:blank:]]*}"}"
  while [ "$j" -lt "${#w}" ]; do
    ch="${w:j:1}"
    case "$ch" in
      [[:blank:]]|';'|'&'|'|'|'<'|'>'|'('|')') break ;;
      "'")
        tail="${w:j+1}"
        if [[ "$tail" == *"'"* ]]; then q="${tail%%"'"*}"; j=$((j + ${#q} + 2)); else q="$tail"; j=${#w}; fi
        word+="$q" ;;
      '"')
        j=$((j + 1))
        while [ "$j" -lt "${#w}" ] && [ "${w:j:1}" != '"' ]; do
          ch="${w:j:1}"
          if [ "$ch" = '\' ] && [[ "${w:j+1:1}" == [\\\$\`\"] ]]; then j=$((j + 1)); ch="${w:j:1}"; fi
          word+="$ch"; j=$((j + 1))
        done
        j=$((j + 1)) ;;
      '\') word+="${w:j+1:1}"; j=$((j + 2)) ;;
      *) word+="$ch"; j=$((j + 1)) ;;
    esac
  done
  [ "$j" -gt 0 ] || return 1
  HOOK_BASH_HEREDOC_WORD="$word"
  return 0
}

# Calls hook_bash_walk's test with the part, its unquoted text and its head,
# then clears the part, its unquoted text and the head. Reads
# hook_bash_walk's locals (dynamic scope).
hook_bash_walk_call() {
  local hd="$part"
  [ "$head_set" = 1 ] && hd="$head"
  local rc=0
  head=""; head_set=0
  "$test_fn" "$part" "$unq" "$hd" || rc=$?
  part=""; unq=""
  return "$rc"
}

# The command walker (#2085): splits command $1 into parts - on `;`, `&&`, `||`
# and newlines, outside single and double quotes and outside heredoc bodies; an
# unquoted `#` at a word start ends its line - and
# calls the test "$2" with each part, its unquoted text (the part with every
# quoted span, quotes included, replaced by a space) and its head: the part's
# text before its first unquoted single `|` (a `|&` counts as that `|`; the head
# holds neither), or the whole part when it holds none, also across a
# trailing-`|` line continuation. The first part whose test
# succeeds ends the walk, with the test's output; the walk always succeeds. A
# command over 8 KB is not scanned (a false negative), to stay fast. A
# heredoc delimiter follows bash's word rule (the whole shell word after `<<`
# or `<<-`, quotes removed), and a `<<` inside arithmetic - while the part's
# unquoted text holds more `((` than `))` - is a shift and opens no heredoc.
hook_bash_walk() {
  local cmd="$1" test_fn="$2" line part="" unq="" head="" head_set=0 quote="" heredoc_end="" in_heredoc=0 heredoc_strip_tabs=0 continued=0 i c n rest re
  [ "${#cmd}" -le 8192 ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_heredoc" = 1 ]; then
      [ "$heredoc_strip_tabs" = 1 ] && line="${line#"${line%%[!$'\t']*}"}"
      [ "$line" = "$heredoc_end" ] && in_heredoc=0
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
          ';') hook_bash_walk_call && return 0 ;;
          '&'|'|')
            if [ "${line:i+1:1}" = "$c" ]; then
              hook_bash_walk_call && return 0
              i=$((i + 2)); continue
            fi
            if [ "$c" = "|" ] && [ "$head_set" = 0 ]; then head="$part"; head_set=1; fi
            part+="$c"; unq+="$c" ;;
          '<')
            if [ "${line:i:3}" = '<<<' ]; then part+="<<<"; unq+="<<<"; i=$((i + 3)); continue; fi
            if [ "${line:i:2}" != '<<' ]; then part+="$c"; unq+="$c"; i=$((i + 1)); continue; fi
            if _hook_bash_in_arith "$unq"; then part+="<<"; unq+="<<"; i=$((i + 2)); continue; fi
            if _hook_bash_heredoc_word "${rest:2}"; then
              in_heredoc=1; heredoc_end="$HOOK_BASH_HEREDOC_WORD"; heredoc_strip_tabs="$HOOK_BASH_HEREDOC_STRIP"
            fi
            part+="<<"; unq+="<<"; i=$((i + 2)); continue ;;
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
    else
      part+=$'\n'
    fi
  done <<<"$cmd"
  hook_bash_walk_call
  return 0
}
