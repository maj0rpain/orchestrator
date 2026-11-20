# shellcheck shell=bash
# bash-walk.sh - the command walker the Bash hook sources, a module of its own
# because its concept is the walker. Sourced by hook-bash.sh, not executed on
# its own.

# Prints the count of `((` minus `))` in unquoted text $1.
_hook_bash_arith_count() {
  local t="$1" no_open no_close
  no_open="${t//((/}"; no_close="${t//))/}"
  echo "$(( (${#no_close} - ${#no_open}) / 2 ))"
}

# True while the arithmetic depth carried across parts ($2) plus the count so
# far in unquoted text $1 is above 0: a `<<` there is an arithmetic shift, not
# a heredoc.
_hook_bash_in_arith() {
  [ "$(( $2 + $(_hook_bash_arith_count "$1") ))" -gt 0 ]
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

# Handles the finished word $w of _hook_bash_compound_scan (dynamic scope: w,
# cmdpos, fn_keyword, compounds). fn_keyword tracks a `function` keyword: 0,
# no `function` keyword pending; 1, `function` seen, its name next; 2, its
# name seen, so a `{` next opens the function body as a compound. A reserved
# word counts only in command position (cmdpos 1); it opens or closes a
# compound on `compounds`, one letter per open compound: `{`, `(`, `i` (if),
# `l` (loop), `c` (case).
_hook_bash_compound_word() {
  [ -n "$w" ] || return 0
  local pos="$cmdpos" word="$w"
  w=""; cmdpos=0
  if [ "$fn_keyword" = 1 ]; then fn_keyword=2; return 0; fi
  if [ "$fn_keyword" = 2 ]; then
    fn_keyword=0
    if [ "$word" = '{' ]; then compounds+='{'; cmdpos=1; return 0; fi
  fi
  [ "$pos" = 1 ] || return 0
  case "$word" in
    '{') compounds+='{'; cmdpos=1 ;;
    if) compounds+=i; cmdpos=1 ;;
    while|until|for|select) compounds+=l; cmdpos=1 ;;
    case) compounds+=c; cmdpos=1 ;;
    '}') [[ "$compounds" == *'{' ]] && compounds="${compounds%?}"; cmdpos=1 ;;
    fi) [[ "$compounds" == *i ]] && compounds="${compounds%?}"; cmdpos=1 ;;
    done) [[ "$compounds" == *l ]] && compounds="${compounds%?}"; cmdpos=1 ;;
    'esac') [[ "$compounds" == *c ]] && compounds="${compounds%?}"; cmdpos=1 ;;
    do|then|elif|else|'!'|time) cmdpos=1 ;;
    function) fn_keyword=1 ;;
  esac
  return 0
}

# Updates the open compounds `compounds` (dynamic scope, from hook_bash_walk)
# with the unquoted text $1 of one part. A part starts in command position; so
# does the word after `|`, `&`, `(`, `)` or a reserved word. An unquoted `(` or
# `)` counts wherever it stands. No external command.
_hook_bash_compound_scan() {
  local t="$1" k=0 ch w="" cmdpos=1 fn_keyword=0 cs_rest
  while [ "$k" -lt "${#t}" ]; do
    cs_rest="${t:k}"
    if [[ "$cs_rest" =~ ^[^\\[:space:]\;\&\|\<\>\(\)]+ ]]; then
      w+="${BASH_REMATCH[0]}"; k=$((k + ${#BASH_REMATCH[0]})); continue
    fi
    ch="${cs_rest::1}"
    case "$ch" in
      '\') w+="${cs_rest::2}"; k=$((k + 2)); continue ;;
      '(') _hook_bash_compound_word; compounds+='('; cmdpos=1; fn_keyword=0 ;;
      ')') _hook_bash_compound_word; [[ "$compounds" == *'(' ]] && compounds="${compounds%?}"; cmdpos=1; fn_keyword=0 ;;
      '&'|'|') _hook_bash_compound_word; cmdpos=1; fn_keyword=0 ;;
      *) _hook_bash_compound_word ;;
    esac
    k=$((k + 1))
  done
  _hook_bash_compound_word
}

# Calls hook_bash_walk's test with the part, its unquoted text, part_head
# (the walker's captured head when one was set, else the whole part) and
# `inside` (1 when the part starts inside an open compound command, else 0),
# the open compounds having been updated from the part just before the call;
# then clears the part, its unquoted text and the head, and carries the part's
# arithmetic count into the depth `arith`, stopped at 0. Reads
# hook_bash_walk's locals (dynamic scope).
hook_bash_walk_call() {
  local part_head="$part"
  [ "$head_set" = 1 ] && part_head="$head"
  local rc=0
  head=""; head_set=0
  local inside=0
  [ -z "$compounds" ] || inside=1
  _hook_bash_compound_scan "$unq"
  "$test_fn" "$part" "$unq" "$part_head" "$inside" || rc=$?
  arith=$(( arith + $(_hook_bash_arith_count "$unq") )); [ "$arith" -ge 0 ] || arith=0
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
# trailing-`|` line continuation - and a fourth value, `inside`: 1 when the part
# starts inside an open compound command (a group, subshell, loop, `if`, `case`
# or function body, #3049), else 0. The walker carries the open compounds
# across its part splits: they open at `{`, `(`, `if`, `while`, `until`, `for`,
# `select` and `case` and close at `}`, `)`, `fi`, `done` and `esac`, each
# closing only the innermost compound and only as its own closer; a reserved
# word counts only in command position, an unquoted `(` or `)` anywhere. A rare
# input it mis-reads (a `)` inside a parameter expansion) errs either way. An
# accepted false negative: a command substitution or array literal spread over
# several lines keeps its inner lines inside an open `(`, so a reader on them is
# not judged (`x=$(` newline `cat` newline `)`). The first part whose test
# succeeds ends the walk, with the test's output; the walk always succeeds. A
# command over 8 KB is not scanned (a false negative), to stay fast. A
# heredoc delimiter follows bash's word rule (the whole shell word after `<<`
# or `<<-`, quotes removed), and a `<<` inside arithmetic - while the depth
# carried across parts (each one's `((` minus `))`, stopped at 0 at a split)
# plus the current part's count is above 0 - is a shift and opens no heredoc.
hook_bash_walk() {
  local cmd="$1" test_fn="$2" line part="" unq="" arith=0 compounds="" head="" head_set=0 quote="" heredoc_end="" in_heredoc=0 heredoc_strip_tabs=0 continued=0 i c n rest re
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
            if _hook_bash_in_arith "$unq" "$arith"; then part+="<<"; unq+="<<"; i=$((i + 2)); continue; fi
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
