# shellcheck shell=bash
# spec-review.sh - orch.sh's spec-review command: a standalone spec review's
# start, and a round's apply - the human's answer to the batch question turned
# into the edited body, the published issue and the posted changelog.
# Its tests: scripts/test/orch/spec-review.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A standalone spec review's start: the guard and the working-directory reset
# each have one right answer, so they live here rather than in skill prose.
# It reads state.json only when one exists, never through require_state - it
# dies with no flow, and no flow is the common case - and never writes it.
# The issue number is the caller's, never state's: the guard only compares.
# State holds only the phases in PHASES, so every not-done phase is one below.
cmd_spec_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) spec_review_begin "$@" ;;
    apply) spec_review_apply "$@" ;;
    *) die "unknown spec-review op: ${op:-<none>} (want begin|apply)" ;;
  esac
}

spec_review_begin() {
  [ $# -eq 1 ] || die "usage: orch.sh spec-review begin <n>"
  local issue="$1"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  if flow_active; then
    local phase held
    phase="$(state_get phase)"
    held="$(state_get issue)"
    if [ "$held" = "$issue" ]; then
      case "$phase" in
        spec)
          die "the active flow holds issue #$issue at phase spec - the flow's own spec phase will review it; run $(flow_cmd next)" ;;
        implement|review)
          die "the active flow holds issue #$issue at phase $phase - the ticket subagents build from this spec, so it cannot change behind the flow; run $(flow_cmd redo) to step back to the spec phase" ;;
        *)
          die "the active flow holds issue #$issue at phase '$phase', which is not a flow phase - refusing to review it; run orch.sh doctor --flow" ;;
      esac
    fi
  fi
  # Built from the validated number alone, so the wipe stays inside
  # spec-review/.
  local dir="$ORCH/spec-review/$issue"
  rm -rf "$dir"
  mkdir -p "$dir"
  printf '%s/\n' "$dir"
}

# --- spec-review apply (#1117) -------------------------------------------------
#
# A round's mechanical steps after the human answers the batch question: the
# session writes the batch once, to <dir>/batch.md, each lens its findings to
# <dir>/lens-<name>.md, and apply takes the answer as given. Every check runs
# before the first write, so a refusal changes nothing; every edit is applied
# to <dir>/spec.fetched.md, the body as first fetched, so a rerun never
# applies an edit twice.

# The lenses, in the lens table's order - the changelog's section order.
SPEC_REVIEW_LENSES="fidelity consistency testability implementability"

# The changelog's heading for a section: Consolidation, a lens, or Tickets.
spec_review_title() {
  case "$1" in
    consolidation) printf 'Consolidation' ;;
    fidelity) printf 'Fidelity' ;;
    consistency) printf 'Consistency' ;;
    testability) printf 'Testability' ;;
    implementability) printf 'Implementability' ;;
  esac
}

# spec_review_lens_known <name>: whether <name> is one of the four lenses.
spec_review_lens_known() {
  case " $SPEC_REVIEW_LENSES " in *" $1 "*) [ -n "$1" ] ;; *) return 1 ;; esac
}

# spec_review_lens_index <name>: the index of <name>'s `@@ lens` line in
# SR_LENS_NAME, or nothing.
spec_review_lens_index() {
  local i
  for i in ${SR_LENS_NAME[@]+"${!SR_LENS_NAME[@]}"}; do
    [ "${SR_LENS_NAME[$i]}" != "$1" ] || { printf '%s' "$i"; return 0; }
  done
  return 0
}

# spec_review_item_index <n>: the index of item <n> in SR_IT_N, or nothing.
spec_review_item_index() {
  local i
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    [ "${SR_IT_N[$i]}" != "$1" ] || { printf '%s' "$i"; return 0; }
  done
  return 0
}

# spec_review_option_index <item-index> <letter>: the index in SR_OP_ITEM of
# that item's option <letter>, or nothing.
spec_review_option_index() {
  local j
  for j in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
    [ "${SR_OP_ITEM[$j]}" = "$1" ] && [ "${SR_OP_LETTER[$j]}" = "$2" ] \
      && { printf '%s' "$j"; return 0; }
  done
  return 0
}

# spec_review_one_line <text>: <text> on one line - every line trimmed, the
# empty ones dropped, the rest joined by one space - so a finding or quote
# copied word for word stays one changelog line.
spec_review_one_line() {
  local out="" l t
  while IFS= read -r l || [ -n "$l" ]; do
    trim_split "$l" t
    [ -n "$t" ] || continue
    out="${out:+$out }$t"
  done <<<"$1"
  printf '%s' "$out"
}

# spec_review_text_store <target> <text>: a finished anchor, replace or quote
# block stored where it belongs - the current option's, the current item's, or
# the last comment's. Reads batch_parse's cur and opt.
spec_review_text_store() {
  case "$1" in
    anchor)
      if [ "$opt" -ge 0 ]; then SR_OP_ANCHOR[opt]="$2"; else SR_IT_ANCHOR[cur]="$2"; fi ;;
    replace)
      if [ "$opt" -ge 0 ]; then SR_OP_REPLACE[opt]="$2"; else SR_IT_REPLACE[cur]="$2"; fi ;;
    quote) SR_CM_QUOTE[${#SR_CM_QUOTE[@]}]="$2" ;;
  esac
}

# spec_review_item_check <index>: dies, naming the item's header line, unless
# the item carries what its recommendation needs.
spec_review_item_check() {
  local i="$1" line="${SR_IT_LINE[$1]}" n="${SR_IT_N[$1]}" j opts=0 has_find="" has_comment=""
  for j in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
    [ "${SR_OP_ITEM[$j]}" = "$i" ] || continue
    opts=$((opts + 1))
    [ -n "${SR_OP_SUMMARY[$j]+x}" ] \
      || spec_review_batch_die "${SR_OP_LINE[$j]}" "item $n option ${SR_OP_LETTER[$j]} has no @@ summary"
    [ -n "${SR_OP_REPLACE[$j]+x}" ] \
      || spec_review_batch_die "${SR_OP_LINE[$j]}" "item $n option ${SR_OP_LETTER[$j]} has no @@ anchor/@@ replace/@@ end block"
  done
  for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    [ "${SR_FD_ITEM[$j]}" != "$i" ] || has_find=1
  done
  for j in ${SR_CM_ITEM[@]+"${!SR_CM_ITEM[@]}"}; do
    [ "${SR_CM_ITEM[$j]}" != "$i" ] || has_comment=1
  done
  case "${SR_IT_REC[$i]}" in
    apply|decline)
      [ -n "${SR_IT_SUMMARY[$i]+x}" ] || spec_review_batch_die "$line" "item $n has no @@ summary"
      [ -n "${SR_IT_REPLACE[$i]+x}" ] || spec_review_batch_die "$line" "item $n has no @@ anchor/@@ replace/@@ end block" ;;
    decision)
      [ "$opts" -ge 2 ] || spec_review_batch_die "$line" "decision item $n needs at least two @@ option blocks"
      [ -n "$(spec_review_option_index "$i" "${SR_IT_ARG[$i]}")" ] \
        || spec_review_batch_die "$line" "decision item $n recommends option ${SR_IT_ARG[$i]}, which it does not have" ;;
    resolved)
      [ -n "${SR_IT_RESOLVED[$i]+x}" ] || spec_review_batch_die "$line" "resolved item $n has no @@ resolved-by line" ;;
  esac
  if [ "${SR_IT_GROUP[$i]}" = consolidation ]; then
    [ -n "$has_comment" ] || spec_review_batch_die "$line" "consolidation item $n cites no @@ comment"
  else
    [ -n "$has_find" ] || spec_review_batch_die "$line" "item $n cites no @@ finding"
  fi
}

# spec_review_batch_die <line> <message>: a malformed batch file, refused
# naming the line.
spec_review_batch_die() { die "batch.md line $1: $2"; }

# spec_review_batch_parse <file>: reads the batch file into the SR_ arrays -
# the `@@ lens` lines, then one entry per item, its findings, comments and
# options - dying on the first malformed line, named by its number. The
# citations' ranges are checked later, against the lens files.
spec_review_batch_parse() {
  local file="$1" line lineno=0 mode=top rest kw args cur=-1 opt=-1
  local buf="" bufn=0 block_line=0 quote_wanted="" n group rec arg name state extra j
  SR_LENS_NAME=(); SR_LENS_STATE=(); SR_LENS_REASON=()
  SR_IT_N=(); SR_IT_GROUP=(); SR_IT_REC=(); SR_IT_ARG=(); SR_IT_LINE=()
  SR_IT_SUMMARY=(); SR_IT_ANCHOR=(); SR_IT_REPLACE=(); SR_IT_RESOLVED=()
  SR_FD_ITEM=(); SR_FD_LENS=(); SR_FD_K=(); SR_FD_LINE=()
  SR_CM_ITEM=(); SR_CM_QUOTE=()
  SR_OP_ITEM=(); SR_OP_LETTER=(); SR_OP_LABEL=(); SR_OP_LINE=()
  SR_OP_SUMMARY=(); SR_OP_ANCHOR=(); SR_OP_REPLACE=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      '@@ '*|'@@'|$'@@\r') ;;
      *)
        case "$mode" in
          anchor|replace|quote)
            if [ "$bufn" -eq 0 ]; then buf="$line"; else buf="$buf"$'\n'"$line"; fi
            bufn=$((bufn + 1))
            continue ;;
        esac
        [ -n "$(trim "$line")" ] \
          || continue
        spec_review_batch_die "$lineno" "text outside an @@ anchor, @@ replace or @@ quote block" ;;
    esac
    line="${line%$'\r'}"
    rest="${line#@@}"; rest="${rest# }"
    kw="${rest%% *}"; args=""
    [ "$kw" = "$rest" ] || args="${rest#* }"
    case "$mode" in
      anchor)
        [ "$kw" = replace ] && [ -z "$args" ] \
          || spec_review_batch_die "$lineno" "expected @@ replace to end the anchor begun on line $block_line"
        [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the anchor is empty"
        spec_review_text_store anchor "$buf"
        mode=replace; buf=""; bufn=0; block_line="$lineno"
        continue ;;
      replace)
        [ "$kw" = end ] && [ -z "$args" ] \
          || spec_review_batch_die "$lineno" "expected @@ end to end the replacement begun on line $block_line"
        spec_review_text_store replace "$buf"
        mode=item; buf=""; bufn=0
        continue ;;
      quote)
        [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the quote is empty"
        spec_review_text_store quote "$buf"
        mode=item; buf=""; bufn=0 ;;
    esac
    [ -z "$quote_wanted" ] || [ "$kw" = quote ] \
      || spec_review_batch_die "$lineno" "@@ comment must be followed by @@ quote"
    [ "$kw" = lens ] || [ "$kw" = item ] || [ "$cur" -ge 0 ] \
      || spec_review_batch_die "$lineno" "@@ $kw outside an item"
    case "$kw" in
      lens)
        [ "$cur" -lt 0 ] || spec_review_batch_die "$lineno" "the @@ lens lines come first, before any item"
        read -r name state extra <<<"$args"
        spec_review_lens_known "$name" \
          || spec_review_batch_die "$lineno" "unknown lens '$name' (want one of: $SPEC_REVIEW_LENSES)"
        [ -z "$(spec_review_lens_index "$name")" ] \
          || spec_review_batch_die "$lineno" "a second @@ lens line for $name"
        case "$state" in
          ran|standalone)
            [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ lens $name $state takes nothing after it"
            [ "$state" = ran ] || [ "$name" = fidelity ] \
              || spec_review_batch_die "$lineno" "only fidelity can be standalone" ;;
          not-run)
            [ -n "$extra" ] || spec_review_batch_die "$lineno" "@@ lens $name not-run needs a reason" ;;
          *) spec_review_batch_die "$lineno" "@@ lens $name wants ran, not-run <reason> or standalone" ;;
        esac
        j="${#SR_LENS_NAME[@]}"
        SR_LENS_NAME[j]="$name"; SR_LENS_STATE[j]="$state"; SR_LENS_REASON[j]="$extra" ;;
      item)
        [ "$cur" -lt 0 ] || spec_review_item_check "$cur"
        read -r n group rec arg <<<"$args"
        case "$n" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "item number must be a positive number, got '$n'" ;; esac
        [ -z "$(spec_review_item_index "$n")" ] || spec_review_batch_die "$lineno" "a second item $n"
        case "$group" in
          consolidation|contradicts-the-plan) ;;
          *) spec_review_lens_known "$group" \
               || spec_review_batch_die "$lineno" "unknown group '$group' (want consolidation, a lens, or contradicts-the-plan)" ;;
        esac
        case "$rec" in
          apply|resolved)
            [ -z "$arg" ] || spec_review_batch_die "$lineno" "@@ item $n ... $rec takes nothing after it" ;;
          decline)
            [ -n "$arg" ] || spec_review_batch_die "$lineno" "@@ item $n ... decline needs a reason" ;;
          decision)
            case "$arg" in [A-Z]) ;; *) spec_review_batch_die "$lineno" "@@ item $n ... decision needs the recommended option's letter, A to Z" ;; esac ;;
          *) spec_review_batch_die "$lineno" "item $n's recommendation must be apply, decline <reason>, decision <letter> or resolved" ;;
        esac
        cur="${#SR_IT_N[@]}"; opt=-1
        SR_IT_N[cur]="$n"; SR_IT_GROUP[cur]="$group"; SR_IT_REC[cur]="$rec"
        SR_IT_ARG[cur]="$arg"; SR_IT_LINE[cur]="$lineno"
        mode=item ;;
      summary)
        [ -n "$args" ] || spec_review_batch_die "$lineno" "@@ summary needs its line"
        [ "${SR_IT_REC[$cur]}" != resolved ] || spec_review_batch_die "$lineno" "a resolved item carries no @@ summary"
        if [ "$opt" -ge 0 ]; then
          [ -z "${SR_OP_SUMMARY[$opt]+x}" ] || spec_review_batch_die "$lineno" "a second @@ summary for this option"
          SR_OP_SUMMARY[opt]="$args"
        else
          [ "${SR_IT_REC[$cur]}" != decision ] || spec_review_batch_die "$lineno" "a decision item's summaries go under its options"
          [ -z "${SR_IT_SUMMARY[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ summary for this item"
          SR_IT_SUMMARY[cur]="$args"
        fi ;;
      finding)
        read -r name n extra <<<"$args"
        [ -n "$name" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>"
        case "$n" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>, k a positive number" ;; esac
        j="${#SR_FD_ITEM[@]}"
        SR_FD_ITEM[j]="$cur"; SR_FD_LENS[j]="$name"; SR_FD_K[j]="$n"; SR_FD_LINE[j]="$lineno" ;;
      comment)
        read -r name n extra <<<"$args"
        case "$name" in @?*) ;; *) spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>" ;; esac
        [ -n "$n" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>"
        SR_CM_ITEM[${#SR_CM_ITEM[@]}]="$cur"
        quote_wanted=1 ;;
      quote)
        [ -n "$quote_wanted" ] || spec_review_batch_die "$lineno" "@@ quote must follow @@ comment"
        [ -z "$args" ] || spec_review_batch_die "$lineno" "@@ quote takes nothing after it; the quote is the lines below it"
        quote_wanted=""; mode=quote; buf=""; bufn=0; block_line="$lineno" ;;
      resolved-by)
        [ "${SR_IT_REC[$cur]}" = resolved ] || spec_review_batch_die "$lineno" "@@ resolved-by belongs to a resolved item"
        [ -z "${SR_IT_RESOLVED[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ resolved-by"
        j="$(spec_review_item_index "$args")"
        [ -n "$args" ] && [ -n "$j" ] && [ "$j" -lt "$cur" ] \
          || spec_review_batch_die "$lineno" "@@ resolved-by names '$args', which is no earlier item"
        SR_IT_RESOLVED[cur]="$args" ;;
      option)
        [ "${SR_IT_REC[$cur]}" = decision ] || spec_review_batch_die "$lineno" "@@ option belongs to a decision item"
        read -r name extra <<<"$args"
        case "$name" in [A-Z]) ;; *) spec_review_batch_die "$lineno" "@@ option wants <letter> <label>, the letter A to Z" ;; esac
        [ -n "$extra" ] || spec_review_batch_die "$lineno" "@@ option $name needs a label"
        [ -z "$(spec_review_option_index "$cur" "$name")" ] \
          || spec_review_batch_die "$lineno" "a second option $name"
        opt="${#SR_OP_ITEM[@]}"
        SR_OP_ITEM[opt]="$cur"; SR_OP_LETTER[opt]="$name"; SR_OP_LABEL[opt]="$extra"; SR_OP_LINE[opt]="$lineno" ;;
      anchor)
        [ -z "$args" ] || spec_review_batch_die "$lineno" "@@ anchor takes nothing after it; the anchor is the lines below it"
        case "${SR_IT_REC[$cur]}" in
          resolved) spec_review_batch_die "$lineno" "a resolved item carries no anchor" ;;
          decision)
            [ "$opt" -ge 0 ] || spec_review_batch_die "$lineno" "a decision item's anchors go under its options"
            [ -z "${SR_OP_ANCHOR[$opt]+x}" ] || spec_review_batch_die "$lineno" "a second @@ anchor for this option" ;;
          *) [ -z "${SR_IT_ANCHOR[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ anchor for this item" ;;
        esac
        mode=anchor; buf=""; bufn=0; block_line="$lineno" ;;
      replace|end) spec_review_batch_die "$lineno" "@@ $kw with no @@ anchor open" ;;
      *) spec_review_batch_die "$lineno" "unknown line '@@ $kw'" ;;
    esac
  done <"$file"
  case "$mode" in
    anchor|replace) spec_review_batch_die "$block_line" "the @@ $mode block is never ended" ;;
    quote)
      [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the quote is empty"
      spec_review_text_store quote "$buf" ;;
  esac
  [ -z "$quote_wanted" ] || spec_review_batch_die "$lineno" "@@ comment must be followed by @@ quote"
  [ "$cur" -lt 0 ] || spec_review_item_check "$cur"
  for name in $SPEC_REVIEW_LENSES; do
    [ -n "$(spec_review_lens_index "$name")" ] \
      || die "batch.md: no @@ lens line for $name - every lens in the table has one"
  done
}

# spec_review_lens_parse <dir> <lens>: reads <dir>/lens-<lens>.md into the
# SR_LF_ arrays - its `@@ finding <k>` blocks, numbered from 1 in order, or
# the single line `@@ none` - dying on a missing file or a malformed line.
spec_review_lens_parse() {
  local f="$1/lens-$2.md" line lineno=0 k=0 cur=-1 none="" rest
  [ -f "$f" ] || die "lens-$2.md not found in $1 - lens $2 is marked ran in batch.md"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    case "$line" in
      '@@ none')
        [ "$k" -eq 0 ] && [ -z "$none" ] \
          || die "lens-$2.md line $lineno: @@ none stands alone in its file"
        none=1 ;;
      '@@ finding '*)
        [ -z "$none" ] || die "lens-$2.md line $lineno: @@ none stands alone in its file"
        rest="${line#@@ finding }"
        [ "$cur" -lt 0 ] || [ -n "$(trim "${SR_LF_TEXT[$cur]}")" ] \
          || die "lens-$2.md line $lineno: finding $k is empty"
        [ "$rest" = "$((k + 1))" ] \
          || die "lens-$2.md line $lineno: expected @@ finding $((k + 1)), got '$line'"
        k=$((k + 1)); cur="${#SR_LF_LENS[@]}"
        SR_LF_LENS[cur]="$2"; SR_LF_K[cur]="$k"; SR_LF_TEXT[cur]="" ;;
      '@@ '*|'@@') die "lens-$2.md line $lineno: unknown line '$line' (want @@ finding <k> or @@ none)" ;;
      *)
        if [ "$cur" -ge 0 ]; then
          SR_LF_TEXT[cur]="${SR_LF_TEXT[$cur]}${SR_LF_TEXT[$cur]:+$'\n'}$line"
        elif [ -n "$(trim "$line")" ]; then
          die "lens-$2.md line $lineno: text before the first @@ finding"
        fi ;;
    esac
  done <"$f"
  [ "$cur" -lt 0 ] || [ -n "$(trim "${SR_LF_TEXT[$cur]}")" ] \
    || die "lens-$2.md line $lineno: finding $k is empty"
  [ "$k" -gt 0 ] || [ -n "$none" ] \
    || die "lens-$2.md holds no @@ finding and no @@ none"
}

# spec_review_finding_text <lens> <k>: the k-th finding of <lens>'s file.
spec_review_finding_text() {
  local j
  for j in ${SR_LF_LENS[@]+"${!SR_LF_LENS[@]}"}; do
    [ "${SR_LF_LENS[$j]}" = "$1" ] && [ "${SR_LF_K[$j]}" = "$2" ] \
      && { printf '%s' "${SR_LF_TEXT[$j]}"; return 0; }
  done
  return 0
}

# spec_review_findings_check: dies, naming the batch line, on a citation of a
# lens that did not run or past its file's count of findings, and on an item
# in a lens's group when that lens did not run.
spec_review_findings_check() {
  local j l count i
  for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    l="$(spec_review_lens_index "${SR_FD_LENS[$j]}")"
    spec_review_lens_known "${SR_FD_LENS[$j]}" \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "unknown lens '${SR_FD_LENS[$j]}'"
    [ "${SR_LENS_STATE[$l]}" = ran ] \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "cites lens ${SR_FD_LENS[$j]}, which did not run"
    count=0
    for i in ${SR_LF_LENS[@]+"${!SR_LF_LENS[@]}"}; do
      [ "${SR_LF_LENS[$i]}" != "${SR_FD_LENS[$j]}" ] || count=$((count + 1))
    done
    [ "${SR_FD_K[$j]}" -le "$count" ] \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "cites finding ${SR_FD_K[$j]} of lens ${SR_FD_LENS[$j]}, but lens-${SR_FD_LENS[$j]}.md holds $count"
  done
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    spec_review_lens_known "${SR_IT_GROUP[$i]}" || continue
    l="$(spec_review_lens_index "${SR_IT_GROUP[$i]}")"
    [ "${SR_LENS_STATE[$l]}" = ran ] \
      || spec_review_batch_die "${SR_IT_LINE[$i]}" "item ${SR_IT_N[$i]} is in group ${SR_IT_GROUP[$i]}, which did not run"
  done
}

# spec_review_answer <answer>: each item's disposition into
# SR_DISP (applied, declined, taken, undecided or resolved), SR_ASREC (1 where
# the human's call matched the recommendation) and SR_TAKEN (a decision's
# letter), from the batch question's answer: recommended, all, none, or an
# Other list such as `1B, 2, 3, 5`. Dies, before any write, on an unknown
# item or option, a letter on an item that is no decision, a decision named
# without one, a resolved item, or an item named twice.
spec_review_answer() {
  local answer="$1" i tok n letter rest named=" " j
  SR_DISP=(); SR_ASREC=(); SR_TAKEN=()
  case "$answer" in
    recommended|all|none) ;;
    *)
      rest="$answer,"
      while [ -n "$rest" ]; do
        tok="${rest%%,*}"; rest="${rest#*,}"
        trim_split "$tok" tok
        n="${tok%%[A-Za-z]*}"; letter="${tok#"$n"}"
        case "$n" in ''|*[!0-9]*) die "the answer '$answer' is not recommended, all, none or a list such as 1B, 2, 3 - '$tok' is no item" ;; esac
        case "$letter" in ''|[A-Za-z]) ;; *) die "the answer '$answer' is not recommended, all, none or a list such as 1B, 2, 3 - '$tok' is no item" ;; esac
        letter="$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')"
        i="$(spec_review_item_index "$n")"
        [ -n "$i" ] || die "the answer names item $n, which batch.md does not have"
        case "$named" in *" $n "*) die "the answer names item $n twice" ;; esac
        named="$named$n "
        case "${SR_IT_REC[$i]}" in
          resolved) die "the answer names item $n, which is resolved by item ${SR_IT_RESOLVED[$i]} and takes no answer" ;;
          decision)
            [ -n "$letter" ] || die "the answer names decision item $n without an option letter"
            j="$(spec_review_option_index "$i" "$letter")"
            [ -n "$j" ] || die "the answer gives item $n option $letter, which it does not have"
            SR_DISP[i]=taken; SR_TAKEN[i]="$letter"
            [ "$letter" != "${SR_IT_ARG[$i]}" ] || SR_ASREC[i]=1 ;;
          *)
            [ -z "$letter" ] || die "the answer gives item $n the letter $letter, but item $n is no decision item"
            SR_DISP[i]=applied
            [ "${SR_IT_REC[$i]}" != apply ] || SR_ASREC[i]=1 ;;
        esac
      done ;;
  esac
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_IT_REC[$i]}" in
      resolved) SR_DISP[i]=resolved; continue ;;
    esac
    [ -z "${SR_DISP[$i]+x}" ] || continue
    case "$answer:${SR_IT_REC[$i]}" in
      recommended:apply|all:apply|all:decline) SR_DISP[i]=applied; SR_ASREC[i]=1 ;;
      recommended:decision|all:decision)
        SR_DISP[i]=taken; SR_TAKEN[i]="${SR_IT_ARG[$i]}"; SR_ASREC[i]=1 ;;
      *:decision) SR_DISP[i]=undecided ;;
      *:decline) SR_DISP[i]=declined; SR_ASREC[i]=1 ;;
      *) SR_DISP[i]=declined ;;
    esac
  done
}

# spec_review_reasons <file>: the human's decline reasons, one `<n>: <reason>`
# line per item, into SR_REASON. Blank lines are skipped; a malformed line, or
# one naming an unknown item, one not declined, or one named twice, dies.
spec_review_reasons() {
  local f="$1" line lineno=0 n reason i
  SR_REASON=()
  [ -n "$f" ] || return 0
  [ -f "$f" ] || die "--reasons file not found: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [ -n "$(trim "$line")" ] || continue
    n="${line%%:*}"
    reason="${line#*:}"
    trim_split "$reason" reason
    case "$n" in ''|*[!0-9]*) die "--reasons line $lineno: want <n>: <reason>, got '$line'" ;; esac
    [ "$n:" != "$line" ] && [ -n "$reason" ] && [ "${line#"$n": }" != "$line" ] \
      || die "--reasons line $lineno: want <n>: <reason>, got '$line'"
    i="$(spec_review_item_index "$n")"
    [ -n "$i" ] || die "--reasons line $lineno names item $n, which batch.md does not have"
    [ "${SR_DISP[$i]}" = declined ] \
      || die "--reasons line $lineno names item $n, which the answer does not decline"
    [ -z "${SR_REASON[$i]+x}" ] || die "--reasons line $lineno names item $n a second time"
    SR_REASON[i]="$reason"
  done <"$f"
}

# spec_review_occurrences <text> <needle>: 0, 1 or 2 - how often <needle>
# occurs in <text>, counting no further than two.
spec_review_occurrences() {
  local hay="$1" c=0
  while [ "$c" -lt 2 ]; do
    case "$hay" in *"$2"*) ;; *) break ;; esac
    c=$((c + 1))
    hay="${hay#*"$2"}"
  done
  printf '%s' "$c"
}

# spec_review_edit <var> <fetched> <what> <anchor> <replacement>: the text in
# <var> with <anchor> replaced once. Dies, naming <what>, unless the anchor
# occurs exactly once both in <fetched>, the body as fetched, and in the text
# the earlier items left.
spec_review_edit() {
  local __sre_text="${!1}" __sre_c
  __sre_c="$(spec_review_occurrences "$2" "$4")"
  [ "$__sre_c" != 0 ] || die "$3: its anchor matches no text in the body - nothing applied, nothing written"
  [ "$__sre_c" != 2 ] || die "$3: its anchor matches more than one place in the body - nothing applied, nothing written"
  [ "$(spec_review_occurrences "$__sre_text" "$4")" = 1 ] \
    || die "$3: its anchor no longer matches exactly once after the earlier items' edits - nothing applied, nothing written"
  printf -v "$1" '%s' "${__sre_text%%"$4"*}$5${__sre_text#*"$4"}"
}

# spec_review_item_sections <index>: the changelog sections item <index> is
# recorded under, one per line - its group's (Fidelity for
# contradicts-the-plan), every lens its findings cite, and Consolidation when
# it cites a comment.
spec_review_item_sections() {
  local i="$1" j
  case "${SR_IT_GROUP[$i]}" in
    contradicts-the-plan) printf 'fidelity\n' ;;
    *) printf '%s\n' "${SR_IT_GROUP[$i]}" ;;
  esac
  for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    [ "${SR_FD_ITEM[$j]}" != "$i" ] || printf '%s\n' "${SR_FD_LENS[$j]}"
  done
  for j in ${SR_CM_ITEM[@]+"${!SR_CM_ITEM[@]}"}; do
    [ "${SR_CM_ITEM[$j]}" != "$i" ] || printf 'consolidation\n'
  done
}

# spec_review_quotes <index>: item <index>'s findings, then its comments'
# quotes, each word for word on one line, in double quotes, joined by " / ".
spec_review_quotes() {
  local i="$1" j out="" q
  for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    [ "${SR_FD_ITEM[$j]}" = "$i" ] || continue
    q="$(spec_review_one_line "$(spec_review_finding_text "${SR_FD_LENS[$j]}" "${SR_FD_K[$j]}")")"
    out="${out:+$out / }\"$q\""
  done
  for j in ${SR_CM_ITEM[@]+"${!SR_CM_ITEM[@]}"}; do
    [ "${SR_CM_ITEM[$j]}" = "$i" ] || continue
    out="${out:+$out / }\"$(spec_review_one_line "${SR_CM_QUOTE[$j]}")\""
  done
  printf '%s' "$out"
}

# spec_review_item_line <index> <unattended>: item <index>'s changelog line.
spec_review_item_line() {
  local i="$1" n="${SR_IT_N[$1]}" j reason
  case "${SR_DISP[$i]}" in
    applied) printf -- '- (%s) %s\n' "$n" "${SR_IT_SUMMARY[$i]}" ;;
    taken)
      j="$(spec_review_option_index "$i" "${SR_TAKEN[$i]}")"
      if [ "$2" = true ]; then
        printf -- '- decision (%s): took %s - %s, as recommended\n' "$n" "${SR_TAKEN[$i]}" "${SR_OP_LABEL[$j]}"
      else
        printf -- '- (%s) decision: took %s - %s\n' "$n" "${SR_TAKEN[$i]}" "${SR_OP_LABEL[$j]}"
      fi ;;
    declined)
      if [ -n "${SR_REASON[$i]+x}" ]; then reason="${SR_REASON[$i]}"
      elif [ -n "${SR_ASREC[$i]:-}" ]; then reason="declined as recommended: ${SR_IT_ARG[$i]}"
      else reason="declined"
      fi
      [ "${SR_IT_GROUP[$i]}" != contradicts-the-plan ] || reason="spec departs from the plan: $reason"
      printf -- '- (%s) %s - %s\n' "$n" "$(spec_review_quotes "$i")" "$reason" ;;
    undecided) printf -- '- (%s) %s - left undecided\n' "$n" "$(spec_review_quotes "$i")" ;;
    resolved) printf -- '- (%s) resolved by (%s)\n' "$n" "${SR_IT_RESOLVED[$i]}" ;;
  esac
}

# spec_review_changelog <round> <unattended> <tickets-line> <host-fallbacks>:
# the round's changelog, from the parsed batch, the lens files and the
# dispositions.
spec_review_changelog() {
  local unattended="$2" section l i lines
  printf '## Spec review\nRound %s of %s\n' "${1%/*}" "${1#*/}"
  [ "$unattended" != true ] \
    || printf 'Unattended spec review, run from a quick implementation: applied as recommended.\n'
  for section in consolidation $SPEC_REVIEW_LENSES; do
    printf '\n### %s\n' "$(spec_review_title "$section")"
    if [ "$section" != consolidation ]; then
      l="$(spec_review_lens_index "$section")"
      case "${SR_LENS_STATE[$l]}" in
        not-run) printf 'not run - %s\n' "${SR_LENS_REASON[$l]}"; continue ;;
        standalone) printf 'not run - standalone review, no plan to check against\n'; continue ;;
      esac
    fi
    lines=""
    for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
      case $'\n'"$(spec_review_item_sections "$i")"$'\n' in
        *$'\n'"$section"$'\n'*) ;;
        *) continue ;;
      esac
      lines="$lines$(spec_review_item_line "$i" "$unattended")"$'\n'
    done
    if [ -n "$lines" ]; then printf '%s' "$lines"; else printf 'None\n'; fi
  done
  printf '\n### Tickets\n%s\n' "$3"
  [ -z "$4" ] || printf '\n**Host fallbacks:** %s\n' "$4"
}

# spec_review_landed <dir>: the writes <dir>/applied.log records, joined for
# a message, or "nothing" when none landed.
spec_review_landed() {
  local l out=""
  if [ -f "$1/applied.log" ]; then
    while IFS= read -r l; do
      [ -n "$l" ] && out="${out:+$out; }$l"
    done <"$1/applied.log"
  fi
  printf '%s' "${out:-nothing}"
}

# spec_review_write <dir> <what> <command...>: one GitHub write, appended to
# <dir>/applied.log once it lands. A failure dies naming <what> and every
# write already landed; nothing is rolled back and changelog.md stays.
spec_review_write() {
  local dir="$1" what="$2" err
  shift 2
  if ! capture_err err "$@" >/dev/null; then
    err="${err#orch: }"
    die "could not write $what: ${err%%$'\n'*} - already landed: $(spec_review_landed "$dir"); $dir/changelog.md is kept, and the review stops here"
  fi
  printf '%s\n' "$what" >>"$dir/applied.log" \
    || die "$what landed, but $dir/applied.log could not record it"
}

# spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
# [--issue <n>] [--unattended] [--host-fallbacks <file>]: the round's
# answer applied, the body published when it changed, and the changelog
# written to <dir>/changelog.md and posted. Every check runs before the first
# write. With an accepted edit and a ticket breakdown it pauses, exit 3,
# before any GitHub write, printing the breakdown kind.
spec_review_apply() {
  local usage="usage: orch.sh spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>] [--issue <n>] [--unattended] [--host-fallbacks <file>]"
  local dir="" answer="" have_answer="" round="" reasons="" issue="" unattended=false hosts_file="" hosts=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --round|--reasons|--issue|--host-fallbacks)
        [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value ($usage)"
        case "$1" in
          --round) round="$2" ;;
          --reasons) reasons="$2" ;;
          --issue) issue="$2" ;;
          --host-fallbacks) hosts_file="$2" ;;
        esac
        shift 2 ;;
      --unattended) unattended=true; shift ;;
      -*) die "unknown option: $1 ($usage)" ;;
      *)
        if [ -z "$dir" ]; then dir="$1"
        elif [ -z "$have_answer" ]; then answer="$1"; have_answer=1
        else die "$usage"
        fi
        shift ;;
    esac
  done
  [ -n "$dir" ] && [ -n "$have_answer" ] || die "$usage"
  [ -n "$round" ] || die "--round <k>/<n> is required ($usage)"
  case "$round" in
    [1-9]*/[1-9]*) ;;
    *) die "--round must be <k>/<n>, two positive numbers, got: $round" ;;
  esac
  case "${round%/*}${round#*/}" in *[!0-9]*) die "--round must be <k>/<n>, two positive numbers, got: $round" ;; esac
  [ "${round%/*}" -le "${round#*/}" ] || die "--round $round: round ${round%/*} is past the round count ${round#*/}"
  if [ -n "$issue" ]; then
    case "$issue" in *[!0-9]*) die "--issue must be a plain issue number, got: $issue" ;; esac
  fi
  if [ "$unattended" = true ]; then
    [ -n "$issue" ] || die "--unattended needs --issue: an unattended spec review is a standalone one"
    [ "$answer" = recommended ] \
      || die "--unattended takes only the answer recommended, got: $answer"
  fi
  [ -d "$dir" ] || die "no such directory: $dir"
  dir="${dir%/}"
  [ ! -s "$dir/applied.log" ] \
    || die "$dir/applied.log records writes that already landed: $(spec_review_landed "$dir") - this review stopped at a failed write; apply refuses to run again"
  if [ -n "$hosts_file" ]; then
    [ -f "$hosts_file" ] || die "--host-fallbacks file not found: $hosts_file"
    hosts="$(spec_review_one_line "$(cat "$hosts_file")")"
    [ -n "$hosts" ] || die "--host-fallbacks file is empty: $hosts_file"
  fi
  # Flow mode: the issue is state's, and the spec command's guards hold. The
  # standalone entry never reads state.json.
  local flow=""
  if [ -z "$issue" ]; then
    flow=1
    require_state
    require_issue issue
    [ "$(state_get phase)" != "done" ] \
      || die "the flow on issue #$issue is done - spec-review apply acts only on an active flow's issue; for another issue use --issue <n>"
  fi

  [ -f "$dir/spec.md" ] || die "spec.md not found in $dir"
  [ -f "$dir/batch.md" ] || die "batch.md not found in $dir"
  if [ ! -e "$dir/spec.fetched.md" ]; then
    cp "$dir/spec.md" "$dir/spec.fetched.md" 2>/dev/null \
      || die "could not copy spec.md to $dir/spec.fetched.md - nothing written"
  fi

  local lens i j fetched text
  spec_review_batch_parse "$dir/batch.md"
  SR_LF_LENS=(); SR_LF_K=(); SR_LF_TEXT=()
  for lens in $SPEC_REVIEW_LENSES; do
    j="$(spec_review_lens_index "$lens")"
    [ "${SR_LENS_STATE[$j]}" != ran ] || spec_review_lens_parse "$dir" "$lens"
  done
  spec_review_findings_check
  spec_review_answer "$answer"
  spec_review_reasons "$reasons"

  # Every accepted anchor, checked against the fetched copy and applied to it.
  fetched="$(cat "$dir/spec.fetched.md"; printf x)"; fetched="${fetched%x}"
  text="$fetched"
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_DISP[$i]}" in
      applied)
        spec_review_edit text "$fetched" "item ${SR_IT_N[$i]}" \
          "${SR_IT_ANCHOR[$i]}" "${SR_IT_REPLACE[$i]}" ;;
      taken)
        j="$(spec_review_option_index "$i" "${SR_TAKEN[$i]}")"
        spec_review_edit text "$fetched" "item ${SR_IT_N[$i]} option ${SR_TAKEN[$i]}" \
          "${SR_OP_ANCHOR[$j]}" "${SR_OP_REPLACE[$j]}" ;;
    esac
  done

  # The ticket step's entry: only an applied edit can leave a ticket behind.
  local tickets kind err st=0 changed=""
  [ "$text" = "$fetched" ] || changed=1
  if [ -z "$changed" ]; then
    tickets="Not checked - no edit applied"
  else
    capture kind err cmd_ticket_exists "$issue" || st=$?
    case "$st" in
      0) ;;
      1) tickets="None - no ticket breakdown" ;;
      *)
        err="${err#orch: }"
        die "ticket exists #$issue exited $st: ${err%%$'\n'*} - nothing written" ;;
    esac
  fi
  { printf '%s' "$text" >"$dir/spec.md"; } 2>/dev/null \
    || die "could not write $dir/spec.md - nothing written to GitHub"
  if [ -n "$changed" ] && [ "$st" -eq 0 ]; then
    # The pause: the session drafts the ticket items and runs apply again.
    note "$kind"
    exit 3
  fi

  local log
  log="$(spec_review_changelog "$round" "$unattended" "$tickets" "$hosts")"
  { printf '%s\n' "$log" >"$dir/changelog.md"; } 2>/dev/null \
    || die "could not write $dir/changelog.md - nothing written to GitHub"

  # Flow mode writes through the spec command, whose guards hold; the
  # standalone entry through the stateless issue commands.
  local update=(cmd_issue update "$issue") comment=(cmd_issue comment "$issue")
  [ -z "$flow" ] || { update=(cmd_spec update); comment=(cmd_spec comment); }
  if [ -n "$changed" ]; then
    spec_review_write "$dir" "the body of issue #$issue" "${update[@]}" "$dir/spec.md"
  fi
  spec_review_write "$dir" "the changelog comment on issue #$issue" "${comment[@]}" "$dir/changelog.md"
}
