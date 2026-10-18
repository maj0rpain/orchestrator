# shellcheck shell=bash
# spec-review.sh - orch.sh's spec-review command: a standalone spec review's
# start, a round's check - its batch validated before the batch question, with
# nothing written - and a round's apply - the human's answer to the batch
# question turned into the edited body, the published issue and the posted
# changelog.
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
    check) spec_review_check "$@" ;;
    apply) spec_review_apply "$@" ;;
    wait) spec_review_wait "$@" ;;
    *) die "unknown spec-review op: ${op:-<none>} (want begin|check|apply|wait)" ;;
  esac
}

# --carry, given on rounds 2 and later, keeps what a round hands the next
# through the wipe: the Implementability lens's code map (#1141) and the
# settled file (#1185), each when it exists. Every other entry is deleted in
# place, so neither is ever moved and there is no restore step to fail.
spec_review_begin() {
  local usage="usage: orch.sh spec-review begin <n> [--carry]"
  local carry=0
  case "$#" in
    1) ;;
    2) [ "$2" = --carry ] || die "$usage"; carry=1 ;;
    *) die "$usage" ;;
  esac
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
  if [ "$carry" = 1 ] && [ -d "$dir" ]; then
    find "$dir" -mindepth 1 -maxdepth 1 ! -name map-implementability.md ! -name settled.md -exec rm -rf {} +
  else
    rm -rf "$dir"
  fi
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

# spec_review_text_store <target> <text> <item> <option> <line>: a finished
# anchor, replace or quote block stored where it belongs - option <option>'s
# when it is 0 or more, else item <item>'s; a quote goes to the last comment.
# An anchor keeps <line>, its `@@ anchor` line, for the errors naming it.
spec_review_text_store() {
  local item="$3" option="$4"
  case "$1" in
    anchor)
      if [ "$option" -ge 0 ]; then
        SR_OP_ANCHOR[option]="$2"; SR_OP_ANCHOR_LINE[option]="$5"
      else
        SR_IT_ANCHOR[item]="$2"; SR_IT_ANCHOR_LINE[item]="$5"
      fi ;;
    replace)
      if [ "$option" -ge 0 ]; then SR_OP_REPLACE[option]="$2"; else SR_IT_REPLACE[item]="$2"; fi ;;
    quote) SR_CM_QUOTE[${#SR_CM_QUOTE[@]}]="$2" ;;
  esac
}

# spec_review_item_check <index>: dies, naming the item's header line, unless
# the item carries what its recommendation needs.
spec_review_item_check() {
  local i="$1" line="${SR_IT_LINE[$1]}" n="${SR_IT_N[$1]}" j opts=0 has_find="" has_comment="" why=""
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
      [ "${SR_IT_REC[$i]}" != decline ] || why=" - a decline item still carries the edit it declines"
      [ -n "${SR_IT_REPLACE[$i]+x}" ] || spec_review_batch_die "$line" "item $n has no @@ anchor/@@ replace/@@ end block$why" ;;
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
  local buf="" bufn=0 block_line=0 quote_wanted="" n group rec arg lens state reason
  local fd_lens fd_k login created letter label extra j
  SR_LENS_NAME=(); SR_LENS_STATE=(); SR_LENS_REASON=()
  SR_IT_N=(); SR_IT_GROUP=(); SR_IT_REC=(); SR_IT_ARG=(); SR_IT_LINE=()
  SR_IT_SUMMARY=(); SR_IT_ANCHOR=(); SR_IT_ANCHOR_LINE=(); SR_IT_REPLACE=(); SR_IT_RESOLVED=()
  SR_FD_ITEM=(); SR_FD_LENS=(); SR_FD_K=(); SR_FD_LINE=()
  SR_CM_ITEM=(); SR_CM_LOGIN=(); SR_CM_CREATED=(); SR_CM_QUOTE=()
  SR_OP_ITEM=(); SR_OP_LETTER=(); SR_OP_LABEL=(); SR_OP_LINE=()
  SR_OP_SUMMARY=(); SR_OP_ANCHOR=(); SR_OP_ANCHOR_LINE=(); SR_OP_REPLACE=()
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
        spec_review_text_store anchor "$buf" "$cur" "$opt" "$block_line"
        mode=replace; buf=""; bufn=0; block_line="$lineno"
        continue ;;
      replace)
        [ "$kw" = end ] && [ -z "$args" ] \
          || spec_review_batch_die "$lineno" "expected @@ end to end the replacement begun on line $block_line, got '$line'"
        spec_review_text_store replace "$buf" "$cur" "$opt"
        mode=item; buf=""; bufn=0
        continue ;;
      quote)
        [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the quote is empty"
        spec_review_text_store quote "$buf" "$cur" "$opt"
        mode=item; buf=""; bufn=0 ;;
    esac
    [ -z "$quote_wanted" ] || [ "$kw" = quote ] \
      || spec_review_batch_die "$lineno" "@@ comment must be followed by @@ quote"
    [ "$kw" = lens ] || [ "$kw" = item ] || [ "$cur" -ge 0 ] \
      || spec_review_batch_die "$lineno" "@@ $kw outside an item"
    case "$kw" in
      lens)
        [ "$cur" -lt 0 ] || spec_review_batch_die "$lineno" "the @@ lens lines come first, before any item"
        read -r lens state reason <<<"$args"
        spec_review_lens_known "$lens" \
          || spec_review_batch_die "$lineno" "unknown lens '$lens' (want one of: $SPEC_REVIEW_LENSES)"
        [ -z "$(array_index SR_LENS_NAME "$lens")" ] \
          || spec_review_batch_die "$lineno" "a second @@ lens line for $lens"
        case "$state" in
          ran|standalone)
            [ -z "$reason" ] || spec_review_batch_die "$lineno" "@@ lens $lens $state takes nothing after it"
            [ "$state" = ran ] || [ "$lens" = fidelity ] \
              || spec_review_batch_die "$lineno" "only fidelity can be standalone" ;;
          not-run)
            [ -n "$reason" ] || spec_review_batch_die "$lineno" "@@ lens $lens not-run needs a reason" ;;
          *) spec_review_batch_die "$lineno" "@@ lens $lens wants ran, not-run <reason> or standalone" ;;
        esac
        j="${#SR_LENS_NAME[@]}"
        SR_LENS_NAME[j]="$lens"; SR_LENS_STATE[j]="$state"; SR_LENS_REASON[j]="$reason" ;;
      item)
        [ "$cur" -lt 0 ] || spec_review_item_check "$cur"
        read -r n group rec arg <<<"$args"
        case "$n" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "item number must be a positive number, got '$n'" ;; esac
        [ -z "$(array_index SR_IT_N "$n")" ] || spec_review_batch_die "$lineno" "a second item $n"
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
        read -r fd_lens fd_k extra <<<"$args"
        [ -n "$fd_lens" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>"
        case "$fd_k" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>, k a positive number" ;; esac
        j="${#SR_FD_ITEM[@]}"
        SR_FD_ITEM[j]="$cur"; SR_FD_LENS[j]="$fd_lens"; SR_FD_K[j]="$fd_k"; SR_FD_LINE[j]="$lineno" ;;
      comment)
        read -r login created extra <<<"$args"
        case "$login" in @?*) ;; *) spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>" ;; esac
        [ -n "$created" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>"
        j="${#SR_CM_ITEM[@]}"
        SR_CM_ITEM[j]="$cur"; SR_CM_LOGIN[j]="$login"; SR_CM_CREATED[j]="$created"
        quote_wanted=1 ;;
      quote)
        [ -n "$quote_wanted" ] || spec_review_batch_die "$lineno" "@@ quote must follow @@ comment"
        [ -z "$args" ] || spec_review_batch_die "$lineno" "@@ quote takes nothing after it; the quote is the lines below it"
        quote_wanted=""; mode=quote; buf=""; bufn=0; block_line="$lineno" ;;
      resolved-by)
        [ "${SR_IT_REC[$cur]}" = resolved ] || spec_review_batch_die "$lineno" "@@ resolved-by belongs to a resolved item"
        [ -z "${SR_IT_RESOLVED[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ resolved-by"
        j="$(array_index SR_IT_N "$args")"
        [ -n "$args" ] && [ -n "$j" ] && [ "$j" -lt "$cur" ] \
          || spec_review_batch_die "$lineno" "@@ resolved-by names '$args', which is no earlier item"
        SR_IT_RESOLVED[cur]="$args" ;;
      option)
        [ "${SR_IT_REC[$cur]}" = decision ] || spec_review_batch_die "$lineno" "@@ option belongs to a decision item"
        read -r letter label <<<"$args"
        case "$letter" in [A-Z]) ;; *) spec_review_batch_die "$lineno" "@@ option wants <letter> <label>, the letter A to Z" ;; esac
        [ -n "$label" ] || spec_review_batch_die "$lineno" "@@ option $letter needs a label"
        [ -z "$(spec_review_option_index "$cur" "$letter")" ] \
          || spec_review_batch_die "$lineno" "a second option $letter"
        opt="${#SR_OP_ITEM[@]}"
        SR_OP_ITEM[opt]="$cur"; SR_OP_LETTER[opt]="$letter"; SR_OP_LABEL[opt]="$label"; SR_OP_LINE[opt]="$lineno" ;;
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
      replace|end)
        [ "${SR_IT_REC[$cur]}" != resolved ] \
          || spec_review_batch_die "$lineno" "a resolved item takes no @@ anchor, @@ replace or @@ end"
        spec_review_batch_die "$lineno" "@@ $kw with no @@ anchor open" ;;
      *) spec_review_batch_die "$lineno" "unknown line '@@ $kw'" ;;
    esac
  done <"$file"
  case "$mode" in
    anchor|replace) spec_review_batch_die "$block_line" "the @@ $mode block is never ended" ;;
    quote)
      [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the quote is empty"
      spec_review_text_store quote "$buf" "$cur" "$opt" ;;
  esac
  [ -z "$quote_wanted" ] || spec_review_batch_die "$lineno" "@@ comment must be followed by @@ quote"
  [ "$cur" -lt 0 ] || spec_review_item_check "$cur"
  for lens in $SPEC_REVIEW_LENSES; do
    [ -n "$(array_index SR_LENS_NAME "$lens")" ] \
      || die "batch.md: no @@ lens line for $lens - every lens in the table has one"
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
  local j l count lf it
  for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    l="$(array_index SR_LENS_NAME "${SR_FD_LENS[$j]}")"
    spec_review_lens_known "${SR_FD_LENS[$j]}" \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "unknown lens '${SR_FD_LENS[$j]}'"
    [ "${SR_LENS_STATE[$l]}" = ran ] \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "cites lens ${SR_FD_LENS[$j]}, which did not run"
    count=0
    for lf in ${SR_LF_LENS[@]+"${!SR_LF_LENS[@]}"}; do
      [ "${SR_LF_LENS[$lf]}" != "${SR_FD_LENS[$j]}" ] || count=$((count + 1))
    done
    [ "${SR_FD_K[$j]}" -le "$count" ] \
      || spec_review_batch_die "${SR_FD_LINE[$j]}" "cites finding ${SR_FD_K[$j]} of lens ${SR_FD_LENS[$j]}, but lens-${SR_FD_LENS[$j]}.md holds $count"
  done
  for it in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    spec_review_lens_known "${SR_IT_GROUP[$it]}" || continue
    l="$(array_index SR_LENS_NAME "${SR_IT_GROUP[$it]}")"
    [ "${SR_LENS_STATE[$l]}" = ran ] \
      || spec_review_batch_die "${SR_IT_LINE[$it]}" "item ${SR_IT_N[$it]} is in group ${SR_IT_GROUP[$it]}, which did not run"
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
        i="$(array_index SR_IT_N "$n")"
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

# spec_review_reasons <flag> <file> <numbers> <dispositions> <reasons> <noun>
# <source> <answer>: the human's decline reasons from <file>, given as <flag>
# (no reasons when it is empty), one `<n>: <reason>` line per item, into the array
# named <reasons> - emptied first - at the index of <n> in the array named
# <numbers>. Blank lines are skipped; a malformed line, or one naming an item
# <source> does not have, one whose entry in the array named <dispositions>
# is not declined by <answer>, or one named twice, dies, calling the item a
# <noun>.
spec_review_reasons() {
  local flag="$1" f="$2" numbers="$3" disps="$4" reasons="$5" noun="$6" source="$7" answer_name="$8"
  local line lineno=0 n reason i ref
  eval "$reasons=()"
  [ -n "$f" ] || return 0
  [ -f "$f" ] || die "$flag file not found: $f"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line="${line%$'\r'}"
    [ -n "$(trim "$line")" ] || continue
    spec_review_reason_split "$flag" "$lineno" "$line" n reason
    i="$(array_index "$numbers" "$n")"
    [ -n "$i" ] || die "$flag line $lineno names $noun $n, which $source does not have"
    ref="${disps}[$i]"
    [ "${!ref:-}" = declined ] \
      || die "$flag line $lineno names $noun $n, which $answer_name does not decline"
    ref="${reasons}[$i]"
    [ -z "${!ref+x}" ] || die "$flag line $lineno names $noun $n a second time"
    printf -v "${reasons}[$i]" '%s' "$reason"
  done <"$f"
}

# spec_review_reason_split <flag> <lineno> <line> <n-var> <reason-var>: one
# `<n>: <reason>` line of a reasons file split into its item number and its
# reason, or a death naming <flag>'s line.
spec_review_reason_split() {
  local __srr_n="${3%%:*}" __srr_reason="${3#*:}"
  trim_split "$__srr_reason" __srr_reason
  case "$__srr_n" in ''|*[!0-9]*) die "$1 line $2: want <n>: <reason>, got '$3'" ;; esac
  [ "$__srr_n:" != "$3" ] && [ -n "$__srr_reason" ] && [ "${3#"$__srr_n": }" != "$3" ] \
    || die "$1 line $2: want <n>: <reason>, got '$3'"
  printf -v "$4" '%s' "$__srr_n"
  printf -v "$5" '%s' "$__srr_reason"
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

# spec_review_edit <var> <fetched> <what> <anchor> <replacement> [collect]:
# the text in <var> with <anchor> replaced once. Dies, naming <what>, unless
# the anchor occurs exactly once both in <fetched>, the body as fetched, and
# in the text the earlier items left. With [collect] set it dies on nothing:
# the problem is appended to SR_PROBLEMS, <var> is left unedited, and it
# returns 1.
spec_review_edit() {
  local __sre_text="${!1}" __sre_c __sre_problem=""
  __sre_c="$(spec_review_occurrences "$2" "$4")"
  if [ "$__sre_c" = 0 ]; then
    __sre_problem="its anchor matches no text in the body"
  elif [ "$__sre_c" = 2 ]; then
    __sre_problem="its anchor matches more than one place in the body"
  elif [ "$(spec_review_occurrences "$__sre_text" "$4")" != 1 ]; then
    __sre_problem="its anchor no longer matches exactly once after the earlier items' edits"
  fi
  if [ -n "$__sre_problem" ]; then
    [ -n "${6:-}" ] || die "$3: $__sre_problem - nothing applied, nothing written"
    SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$3: $__sre_problem"
    return 1
  fi
  printf -v "$1" '%s' "${__sre_text%%"$4"*}$5${__sre_text#*"$4"}"
}

# spec_review_anchor <accepted> <what> <anchor> <replacement> [collect]: one
# anchor of spec_review_validate's - applied to SR_TEXT when <accepted> is
# set, else, with [collect] set, checked on its own against SR_FETCHED.
spec_review_anchor() {
  if [ -n "$1" ]; then
    spec_review_edit SR_TEXT "$SR_FETCHED" "$2" "$3" "$4" "${5:-}" || true
  elif [ -n "${5:-}" ]; then
    # shellcheck disable=SC2034 # spec_review_edit writes it by name; discarded
    local scratch="$SR_FETCHED"
    spec_review_edit scratch "$SR_FETCHED" "$2" "$3" "$4" "$5" || true
  fi
}

# spec_review_validate <dir> <body-file> <answer> [collect]: the one
# validation check and apply share. Reads <dir>/batch.md and the lens files of
# the lenses that ran, checks the citations, takes <answer> (see
# spec_review_answer), and applies every anchor it accepts, in batch order, to
# <body-file>'s text: SR_FETCHED holds the body as read, SR_TEXT the body
# edited. Grammar, lens and citation errors die on the first. An anchor
# problem dies too, unless [collect] is set: then every anchor - the ones the
# answer leaves out checked on their own against SR_FETCHED - is checked, and
# each problem, naming its `@@ anchor` line, is appended to SR_PROBLEMS, the
# failed edit skipped.
spec_review_validate() {
  local dir="$1" body="$2" answer="$3" collect="${4:-}" lens i j accepted
  spec_review_batch_parse "$dir/batch.md"
  SR_LF_LENS=(); SR_LF_K=(); SR_LF_TEXT=()
  for lens in $SPEC_REVIEW_LENSES; do
    j="$(array_index SR_LENS_NAME "$lens")"
    [ "${SR_LENS_STATE[$j]}" != ran ] || spec_review_lens_parse "$dir" "$lens"
  done
  spec_review_findings_check
  spec_review_answer "$answer"
  file_read SR_FETCHED "$body" || die "could not read $body - nothing written"
  SR_TEXT="$SR_FETCHED"
  SR_PROBLEMS=()
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_IT_REC[$i]}" in
      apply|decline)
        accepted=""
        [ "${SR_DISP[$i]}" != applied ] || accepted=1
        spec_review_anchor "$accepted" "batch.md line ${SR_IT_ANCHOR_LINE[$i]}: item ${SR_IT_N[$i]}" \
          "${SR_IT_ANCHOR[$i]}" "${SR_IT_REPLACE[$i]}" "$collect" ;;
      decision)
        for j in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
          [ "${SR_OP_ITEM[$j]}" = "$i" ] || continue
          accepted=""
          [ "${SR_DISP[$i]}" != taken ] || [ "${SR_TAKEN[$i]}" != "${SR_OP_LETTER[$j]}" ] || accepted=1
          spec_review_anchor "$accepted" \
            "batch.md line ${SR_OP_ANCHOR_LINE[$j]}: item ${SR_IT_N[$i]} option ${SR_OP_LETTER[$j]}" \
            "${SR_OP_ANCHOR[$j]}" "${SR_OP_REPLACE[$j]}" "$collect"
        done ;;
    esac
  done
}

# --- spec-review wait (#1183) --------------------------------------------------
#
# The session running a review starts its lenses and runs this in the same
# response, so a lens's hand-back queues behind the running tool instead of
# taking a turn of its own. A lens is back when its findings file exists: each
# lens writes it last. How long the wait lasts, and how often it looks, are
# overridable through the environment, as `review ci`'s are, so a test can turn
# them down to fractions of a second.
ORCH_SPEC_REVIEW_WAIT_TIMEOUT="${ORCH_SPEC_REVIEW_WAIT_TIMEOUT:-900}"
ORCH_SPEC_REVIEW_WAIT_INTERVAL="${ORCH_SPEC_REVIEW_WAIT_INTERVAL:-5}"

# spec-review wait <dir> <lens>...: blocks until <dir>/lens-<lens>.md exists
# for every named lens, then prints `lenses back: <lens> <count>, ...` in the
# order named, <count> its `@@ finding ` lines - the file is not validated
# here; check and the session's own read meet a malformed one. On timeout,
# nothing on stdout, and exit 1 naming the lenses still missing.
spec_review_wait() {
  local usage="usage: orch.sh spec-review wait <dir> <lens>..."
  [ $# -ge 2 ] || die "$usage"
  local dir="${1%/}" lens missing summary slept=0 n
  shift
  [ -d "$dir" ] || die "no such directory: $dir"
  for lens in "$@"; do
    spec_review_lens_known "$lens" || die "unknown lens '$lens' (want one of: $SPEC_REVIEW_LENSES)"
  done
  require_poll_knobs ORCH_SPEC_REVIEW_WAIT_TIMEOUT ORCH_SPEC_REVIEW_WAIT_INTERVAL
  while :; do
    missing=""
    for lens in "$@"; do
      [ -e "$dir/lens-$lens.md" ] || missing+=" $lens"
    done
    [ -n "$missing" ] || break
    float_lt "$slept" "$ORCH_SPEC_REVIEW_WAIT_TIMEOUT" \
      || die "lenses not back after ${ORCH_SPEC_REVIEW_WAIT_TIMEOUT}s:$missing"
    sleep "$ORCH_SPEC_REVIEW_WAIT_INTERVAL"
    slept="$(float_add "$slept" "$ORCH_SPEC_REVIEW_WAIT_INTERVAL")"
  done
  summary=""
  for lens in "$@"; do
    n="$(grep -c '^@@ finding ' "$dir/lens-$lens.md" || true)"
    summary+="${summary:+, }$lens ${n:-0}"
  done
  note "lenses back: $summary"
}

# spec_review_problems_exit: when a check collected problems in SR_PROBLEMS,
# warns each, one `orch: ` line apiece, and exits 1; else returns.
spec_review_problems_exit() {
  local p
  [ "${#SR_PROBLEMS[@]}" -gt 0 ] || return 0
  for p in "${SR_PROBLEMS[@]}"; do warn "$p"; done
  exit 1
}

# spec-review check <dir>: the round's batch validated as apply would take the
# all answer - every anchor checked, the recommended options in the dry run -
# against <dir>/spec.fetched.md when it exists, else <dir>/spec.md. Writes
# nothing, touches no GitHub, reads no flow state. Grammar, lens and citation
# errors stop at the first; every anchor problem is reported, one `orch: `
# line each, then exit 1. A clean batch prints its view on stdout - see
# spec_review_view - and a one-line summary on stderr. With --tickets, the
# round's tickets.md instead: see spec_review_tickets_check.
spec_review_check() {
  local usage="usage: orch.sh spec-review check <dir> [--tickets]" dir="" tickets=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --tickets) tickets=1 ;;
      -*) die "unknown option: $1 ($usage)" ;;
      *) [ -z "$dir" ] || die "$usage"; dir="$1" ;;
    esac
    shift
  done
  [ -n "$dir" ] || die "$usage"
  dir="${dir%/}"
  local body i anchors=0
  [ -d "$dir" ] || die "no such directory: $dir"
  if [ -n "$tickets" ]; then
    spec_review_tickets_check "$dir"
    return 0
  fi
  [ -f "$dir/batch.md" ] || die "batch.md not found in $dir"
  body=spec.fetched.md
  [ -e "$dir/$body" ] || body=spec.md
  [ -f "$dir/$body" ] || die "spec.md not found in $dir"
  spec_review_validate "$dir" "$dir/$body" all collect
  spec_review_problems_exit
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_IT_REC[$i]}" in apply|decline) anchors=$((anchors + 1)) ;; esac
  done
  anchors=$((anchors + ${#SR_OP_ITEM[@]}))
  spec_review_view
  note "batch.md passes: ${#SR_IT_N[@]} items, $anchors anchors, each matching once in $body, and the all answer applies cleanly" >&2
}

# spec_review_quoted <text>: <text> as a markdown blockquote, line for line.
spec_review_quoted() {
  local l
  while IFS= read -r l || [ -n "$l" ]; do
    if [ -n "$l" ]; then printf '> %s\n' "$l"; else printf '>\n'; fi
  done <<<"$1"
}

# spec_review_fenced <text>: <text> in a code block whose fence of backticks
# is longer than any run of backticks in it, so a fence in the text stays text.
spec_review_fenced() {
  local fence='```'
  while :; do
    case "$1" in *"$fence"*) fence="$fence\`" ;; *) break ;; esac
  done
  printf '%s\n%s\n%s\n' "$fence" "$1" "$fence"
}

# spec_review_edit_view <anchor> <replacement>: an edit's Current and Proposed,
# both in full.
spec_review_edit_view() {
  printf '\n**Current**\n\n%s\n\n**Proposed**\n\n%s\n' "$(spec_review_fenced "$1")" "$(spec_review_fenced "$2")"
}

# spec_review_view: the parsed batch as the human reads it before the batch
# question - the lens lines, worded as the changelog words them, then every
# item in batch order: its group, its recommendation, the text of each finding
# it cites and of each comment it folds in, and its edit, or each option's, in
# full. Rendered from spec_review_validate's arrays alone.
spec_review_view() {
  local l i j group
  printf '## The batch\n\n### Lenses\n\n'
  for l in "${!SR_LENS_NAME[@]}"; do
    printf -- '- %s: ' "$(spec_review_title "${SR_LENS_NAME[$l]}")"
    spec_review_lens_state_line "$l"
  done
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_IT_GROUP[$i]}" in
      contradicts-the-plan) group="Contradicts the plan" ;;
      *) group="$(spec_review_title "${SR_IT_GROUP[$i]}")" ;;
    esac
    printf '\n### Item %s - %s\n\n**Recommendation:** ' "${SR_IT_N[$i]}" "$group"
    case "${SR_IT_REC[$i]}" in
      apply) printf 'apply\n' ;;
      decline) printf 'recommend decline - %s\n' "${SR_IT_ARG[$i]}" ;;
      decision) printf 'decision - option %s recommended\n' "${SR_IT_ARG[$i]}" ;;
      resolved) printf 'none - resolved by item %s\n' "${SR_IT_RESOLVED[$i]}" ;;
    esac
    for j in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
      [ "${SR_FD_ITEM[$j]}" = "$i" ] || continue
      printf '\n**Finding** (%s %s):\n\n' "$(spec_review_title "${SR_FD_LENS[$j]}")" "${SR_FD_K[$j]}"
      spec_review_quoted "$(spec_review_finding_text "${SR_FD_LENS[$j]}" "${SR_FD_K[$j]}")"
    done
    for j in ${SR_CM_ITEM[@]+"${!SR_CM_ITEM[@]}"}; do
      [ "${SR_CM_ITEM[$j]}" = "$i" ] || continue
      printf '\n**Comment** by %s, %s:\n\n' "${SR_CM_LOGIN[$j]}" "${SR_CM_CREATED[$j]}"
      spec_review_quoted "${SR_CM_QUOTE[$j]}"
    done
    case "${SR_IT_REC[$i]}" in
      apply|decline) spec_review_edit_view "${SR_IT_ANCHOR[$i]}" "${SR_IT_REPLACE[$i]}" ;;
      decision)
        for j in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
          [ "${SR_OP_ITEM[$j]}" = "$i" ] || continue
          printf '\n#### Option %s - %s' "${SR_OP_LETTER[$j]}" "${SR_OP_LABEL[$j]}"
          [ "${SR_OP_LETTER[$j]}" != "${SR_IT_ARG[$i]}" ] || printf ' (recommended)'
          printf '\n'
          spec_review_edit_view "${SR_OP_ANCHOR[$j]}" "${SR_OP_REPLACE[$j]}"
        done ;;
    esac
  done
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

# spec_review_decline_reason <has-reason> <reason> <as-recommended>
# <recommended-reason>: a declined item's changelog reason - the human's
# <reason> when <has-reason> is set, else, when <as-recommended> is, the
# recommendation's own reason, else plain "declined".
spec_review_decline_reason() {
  if [ -n "$1" ]; then printf '%s' "$2"
  elif [ -n "$3" ]; then printf 'declined as recommended: %s' "$4"
  else printf 'declined'
  fi
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
      reason="$(spec_review_decline_reason "${SR_REASON[$i]+x}" "${SR_REASON[$i]:-}" \
        "${SR_ASREC[$i]:-}" "${SR_IT_ARG[$i]}")"
      [ "${SR_IT_GROUP[$i]}" != contradicts-the-plan ] || reason="spec departs from the plan: $reason"
      printf -- '- (%s) %s - %s\n' "$n" "$(spec_review_quotes "$i")" "$reason" ;;
    undecided) printf -- '- (%s) %s - left undecided\n' "$n" "$(spec_review_quotes "$i")" ;;
    resolved) printf -- '- (%s) resolved by (%s)\n' "$n" "${SR_IT_RESOLVED[$i]}" ;;
  esac
}

# spec_review_lens_state_line <l>: lens <l>'s state, as the batch view and
# the changelog both word it - `ran`, or `not run - ` and why - on one line.
spec_review_lens_state_line() {
  case "${SR_LENS_STATE[$1]}" in
    ran) printf 'ran\n' ;;
    not-run) printf 'not run - %s\n' "${SR_LENS_REASON[$1]}" ;;
    standalone) printf 'not run - standalone review, no plan to check against\n' ;;
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
      l="$(array_index SR_LENS_NAME "$section")"
      [ "${SR_LENS_STATE[$l]}" = ran ] || { spec_review_lens_state_line "$l"; continue; }
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

# --- spec-review apply --tickets (#1118) ---------------------------------------
#
# The ticket step: on the rerun after the pause, <dir>/tickets.md holds the
# ticket items the session drafted - text edits against ticket-<t>.md or the
# collapsed body's `## Ticket` section, and blocked-by edges - and the
# ticket answer decides which apply. Like the batch, every check runs before
# the first write, and every edit applies to a fetched copy.

# spec_review_tickets_die <line> <message>: a malformed tickets.md, refused
# naming the line.
spec_review_tickets_die() { die "tickets.md line $1: $2"; }

# spec_review_ticket_item_check <index>: dies, naming the item's header line,
# unless a text item carries its summary and its anchor/replace block.
spec_review_ticket_item_check() {
  case "${ST_KIND[$1]}" in
    ticket|section)
      [ -n "${ST_SUMMARY[$1]+x}" ] \
        || spec_review_tickets_die "${ST_LINE[$1]}" "item ${ST_N[$1]} has no @@ summary"
      [ -n "${ST_REPLACE[$1]+x}" ] \
        || spec_review_tickets_die "${ST_LINE[$1]}" "item ${ST_N[$1]} has no @@ anchor/@@ replace/@@ end block" ;;
  esac
}

# spec_review_tickets_parse <file>: reads tickets.md into the ST_ arrays -
# its `@@ recommend` line, then one entry per item and per `@@ closed` line,
# or the lone `@@ none-affected` - dying on the first malformed line, named
# by its number. ST_LINE holds each item's header line, ST_ANCHOR_LINE a text
# item's `@@ anchor` line.
spec_review_tickets_parse() {
  local file="$1" line lineno=0 mode=top rest kw args cur=-1 seen=""
  local buf="" bufn=0 block_line=0 n kind tail t by b rec arg what
  ST_RECOMMEND=""; ST_NONE=""
  ST_N=(); ST_KIND=(); ST_T=(); ST_B=(); ST_REC=(); ST_ARG=(); ST_LINE=()
  ST_SUMMARY=(); ST_ANCHOR=(); ST_ANCHOR_LINE=(); ST_REPLACE=(); ST_CL_T=(); ST_CL_WHAT=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    case "$line" in
      '@@ '*|'@@'|$'@@\r') ;;
      *)
        if [ "$mode" = anchor ] || [ "$mode" = replace ]; then
          if [ "$bufn" -eq 0 ]; then buf="$line"; else buf="$buf"$'\n'"$line"; fi
          bufn=$((bufn + 1))
          continue
        fi
        [ -n "$(trim "$line")" ] || continue
        spec_review_tickets_die "$lineno" "text outside an @@ anchor or @@ replace block" ;;
    esac
    line="${line%$'\r'}"
    rest="${line#@@}"; rest="${rest# }"
    kw="${rest%% *}"; args=""
    [ "$kw" = "$rest" ] || args="${rest#* }"
    case "$mode" in
      anchor)
        [ "$kw" = replace ] && [ -z "$args" ] \
          || spec_review_tickets_die "$lineno" "expected @@ replace to end the anchor begun on line $block_line"
        [ -n "$(trim "$buf")" ] || spec_review_tickets_die "$block_line" "the anchor is empty"
        ST_ANCHOR[cur]="$buf"
        mode=replace; buf=""; bufn=0; block_line="$lineno"
        continue ;;
      replace)
        [ "$kw" = end ] && [ -z "$args" ] \
          || spec_review_tickets_die "$lineno" "expected @@ end to end the replacement begun on line $block_line"
        ST_REPLACE[cur]="$buf"
        mode=top; buf=""; bufn=0
        continue ;;
    esac
    [ -z "$ST_NONE" ] || spec_review_tickets_die "$lineno" "@@ none-affected stands alone in its file"
    case "$kw" in
      recommend|none-affected)
        [ -z "$seen" ] || spec_review_tickets_die "$lineno" "@@ $kw comes first, and only once" ;;
      *)
        [ -n "$ST_RECOMMEND" ] \
          || spec_review_tickets_die "$lineno" "@@ recommend comes first: @@ recommend apply or @@ recommend retire" ;;
    esac
    seen=1
    case "$kw" in
      recommend)
        case "$args" in
          apply|retire) ST_RECOMMEND="$args" ;;
          *) spec_review_tickets_die "$lineno" "@@ recommend wants apply or retire, got '$args'" ;;
        esac ;;
      none-affected)
        [ -z "$args" ] || spec_review_tickets_die "$lineno" "@@ none-affected takes nothing after it"
        ST_NONE=1 ;;
      item)
        [ "$cur" -lt 0 ] || spec_review_ticket_item_check "$cur"
        read -r n kind tail <<<"$args"
        case "$n" in ''|*[!0-9]*|0*) spec_review_tickets_die "$lineno" "item number must be a positive number, got '$n'" ;; esac
        [ -z "$(array_index ST_N "$n")" ] || spec_review_tickets_die "$lineno" "a second item $n"
        t=""; b=""
        case "$kind" in
          ticket) read -r t rec arg <<<"$tail" ;;
          section) read -r rec arg <<<"$tail" ;;
          block|unblock)
            read -r t by b rec arg <<<"$tail"
            [ "$by" = by ] || spec_review_tickets_die "$lineno" "@@ item $n $kind wants <t> by <b>"
            case "$b" in ''|*[!0-9]*) spec_review_tickets_die "$lineno" "@@ item $n $kind wants <t> by <b>, each a plain issue number" ;; esac
            [ "$t" != "$b" ] || spec_review_tickets_die "$lineno" "@@ item $n: a ticket never blocks itself" ;;
          *) spec_review_tickets_die "$lineno" "item $n wants ticket <t>, section, block <t> by <b> or unblock <t> by <b>" ;;
        esac
        if [ "$kind" != section ]; then
          case "$t" in ''|*[!0-9]*) spec_review_tickets_die "$lineno" "@@ item $n $kind wants a plain issue number, got '$t'" ;; esac
        fi
        case "$rec" in
          apply) [ -z "$arg" ] || spec_review_tickets_die "$lineno" "@@ item $n ... apply takes nothing after it" ;;
          decline) [ -n "$arg" ] || spec_review_tickets_die "$lineno" "@@ item $n ... decline needs a reason" ;;
          *) spec_review_tickets_die "$lineno" "item $n's recommendation must be apply or decline <reason>" ;;
        esac
        cur="${#ST_N[@]}"
        ST_N[cur]="$n"; ST_KIND[cur]="$kind"; ST_T[cur]="$t"; ST_B[cur]="$b"
        ST_REC[cur]="$rec"; ST_ARG[cur]="$arg"; ST_LINE[cur]="$lineno" ;;
      summary|anchor)
        [ "$cur" -ge 0 ] || spec_review_tickets_die "$lineno" "@@ $kw outside an item"
        case "${ST_KIND[$cur]}" in
          ticket|section) ;;
          *) spec_review_tickets_die "$lineno" "an edge item carries no @@ $kw" ;;
        esac
        if [ "$kw" = summary ]; then
          [ -n "$args" ] || spec_review_tickets_die "$lineno" "@@ summary needs its line"
          [ -z "${ST_SUMMARY[$cur]+x}" ] || spec_review_tickets_die "$lineno" "a second @@ summary for this item"
          ST_SUMMARY[cur]="$args"
        else
          [ -z "$args" ] || spec_review_tickets_die "$lineno" "@@ anchor takes nothing after it; the anchor is the lines below it"
          [ -z "${ST_ANCHOR[$cur]+x}" ] || spec_review_tickets_die "$lineno" "a second @@ anchor for this item"
          ST_ANCHOR_LINE[cur]="$lineno"
          mode=anchor; buf=""; bufn=0; block_line="$lineno"
        fi ;;
      closed)
        [ "$cur" -lt 0 ] || spec_review_ticket_item_check "$cur"
        cur=-1
        read -r t what <<<"$args"
        case "$t" in ''|*[!0-9]*) spec_review_tickets_die "$lineno" "@@ closed wants <t> <what changed>, t a plain issue number" ;; esac
        [ -n "$what" ] || spec_review_tickets_die "$lineno" "@@ closed $t needs what changed"
        ST_CL_T[${#ST_CL_T[@]}]="$t"; ST_CL_WHAT[${#ST_CL_WHAT[@]}]="$what" ;;
      replace|end) spec_review_tickets_die "$lineno" "@@ $kw with no @@ anchor open" ;;
      *) spec_review_tickets_die "$lineno" "unknown line '@@ $kw'" ;;
    esac
  done <"$file"
  case "$mode" in
    anchor|replace) spec_review_tickets_die "$block_line" "the @@ $mode block is never ended" ;;
  esac
  [ "$cur" -lt 0 ] || spec_review_ticket_item_check "$cur"
  [ -n "$seen" ] || die "tickets.md is empty - it holds @@ recommend and the ticket items, or @@ none-affected"
}

# spec_review_tickets_answer <answer>: each ticket item's disposition into
# ST_DISP (applied or declined) and ST_ASREC, or ST_RETIRE, from the ticket
# question's answer: recommended (following @@ recommend), all, none, retire,
# or an Other list such as `1, 3`. Dies, before any write, on an unknown item
# or one named twice.
spec_review_tickets_answer() {
  local answer="$1" rest tok i named=" "
  ST_DISP=(); ST_ASREC=(); ST_RETIRE=""
  case "$answer" in
    retire) ST_RETIRE=1; return 0 ;;
    recommended)
      [ "$ST_RECOMMEND" != retire ] || { ST_RETIRE=1; return 0; } ;;
    all|none) ;;
    *)
      rest="$answer,"
      while [ -n "$rest" ]; do
        tok="${rest%%,*}"; rest="${rest#*,}"
        trim_split "$tok" tok
        case "$tok" in ''|*[!0-9]*) die "the --tickets answer '$answer' is not recommended, all, none, retire or a list such as 1, 3 - '$tok' is no ticket item" ;; esac
        i="$(array_index ST_N "$tok")"
        [ -n "$i" ] || die "the --tickets answer names ticket item $tok, which tickets.md does not have"
        case "$named" in *" $tok "*) die "the --tickets answer names ticket item $tok twice" ;; esac
        named="$named$tok "
        ST_DISP[i]=applied
        [ "${ST_REC[$i]}" != apply ] || ST_ASREC[i]=1
      done ;;
  esac
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    [ -z "${ST_DISP[$i]+x}" ] || continue
    case "$answer:${ST_REC[$i]}" in
      recommended:apply|all:apply) ST_DISP[i]=applied; ST_ASREC[i]=1 ;;
      all:decline) ST_DISP[i]=applied ;;
      *:decline) ST_DISP[i]=declined; ST_ASREC[i]=1 ;;
      *) ST_DISP[i]=declined ;;
    esac
  done
}

# spec_review_ticket_load <dir> <t> <what> [collect]: ticket #<t>'s copy into
# TK_FETCHED and TK_TEXT, once - ticket-<t>.fetched.md, else, before any
# apply run has taken that copy, ticket-<t>.md. Dies, naming <what>, when the
# session wrote no ticket-<t>.md; with [collect] set, the problem is appended
# to SR_PROBLEMS instead and it returns 1.
spec_review_ticket_load() {
  local j copy problem file="$1/ticket-$2.fetched.md"
  [ -z "$(array_index TK_T "$2")" ] || return 0
  if [ ! -f "$1/ticket-$2.md" ]; then
    problem="$3: ticket-$2.md not found in $1 - fetch each ticket a ticket item names into it"
    [ -n "${4:-}" ] || die "$problem"
    SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$problem"
    return 1
  fi
  [ -e "$file" ] || file="$1/ticket-$2.md"
  file_read copy "$file" || die "could not read $file - nothing written"
  j="${#TK_T[@]}"
  TK_T[j]="$2"; TK_FETCHED[j]="$copy"; TK_TEXT[j]="$copy"
}

# spec_review_ticket_local <index> <body-var> <post> <dir> [collect]: ticket
# item <index>'s checks that read no GitHub, the half apply and check share.
# A text item's ticket is loaded (see spec_review_ticket_load) and, when
# ST_DISP holds it applied, its edit made in memory: to its ticket's copy in
# TK_TEXT, or a `## Ticket` edit to the body in <body-var>, anchored on
# <post>, the body as the batch items left it. An applied edge item is
# checked against its ticket's copy's `## Blocked by`. Dies on a problem;
# with [collect] set - check's way - each problem, naming its tickets.md line
# (a text item's `@@ anchor` line, else its header line), is appended to
# SR_PROBLEMS instead.
spec_review_ticket_local() {
  local i="$1" body_var="$2" post="$3" dir="$4" collect="${5:-}" j at="" problem="" have=""
  local what="ticket item ${ST_N[$1]}"
  [ -z "$collect" ] || at="tickets.md line ${ST_LINE[$i]}: "
  case "${ST_KIND[$i]}" in
    ticket)
      spec_review_ticket_load "$dir" "${ST_T[$i]}" "$at$what" "$collect" || return 0
      [ "${ST_DISP[$i]}" = applied ] || return 0
      [ -z "$collect" ] || at="tickets.md line ${ST_ANCHOR_LINE[$i]}: "
      j="$(array_index TK_T "${ST_T[$i]}")"
      spec_review_edit "TK_TEXT[$j]" "${TK_FETCHED[$j]}" "$at$what (#${ST_T[$i]})" \
        "${ST_ANCHOR[$i]}" "${ST_REPLACE[$i]}" "$collect" || true ;;
    section)
      [ "${ST_DISP[$i]}" = applied ] || return 0
      [ -z "$collect" ] || at="tickets.md line ${ST_ANCHOR_LINE[$i]}: "
      spec_review_edit "$body_var" "$post" "$at$what (## Ticket)" \
        "${ST_ANCHOR[$i]}" "${ST_REPLACE[$i]}" "$collect" || true ;;
    block|unblock)
      [ "${ST_DISP[$i]}" = applied ] || return 0
      spec_review_ticket_load "$dir" "${ST_T[$i]}" "$at$what" "$collect" || return 0
      j="$(array_index TK_T "${ST_T[$i]}")"
      case $'\n'"$(printf '%s\n' "${TK_FETCHED[$j]}" | blocked_by_section_numbers)"$'\n' in
        *$'\n'"${ST_B[$i]}"$'\n'*) have=1 ;;
      esac
      if [ "${ST_KIND[$i]}" = block ]; then
        [ -z "$have" ] || problem="#${ST_T[$i]} is already blocked by #${ST_B[$i]}"
      else
        [ -n "$have" ] || problem="#${ST_T[$i]} is not blocked by #${ST_B[$i]}"
      fi
      [ -n "$problem" ] || return 0
      [ -n "$collect" ] || die "$what: $problem - nothing written"
      SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$at$what: $problem" ;;
  esac
}

# spec_review_tickets_follow <body-var> <dir> <kind> <issue>: every accepted
# ticket item checked and applied in memory - see spec_review_ticket_local -
# and the checks that read GitHub: every edge item's tickets in the
# breakdown, and a `## Ticket` item only on a collapsed one. Dies, before any
# write, on the first that fails.
spec_review_tickets_follow() {
  local body_var="$1" dir="$2" kind="$3" issue="$4" i t what post subs="" listed
  [ -z "$ST_RETIRE" ] || return 0
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    case "${ST_KIND[$i]}" in
      block|unblock)
        listed="$(ticket_sub_issues "$issue")" || exit 1
        subs="$(printf '%s\n' "$listed" | cut -f1)"
        break ;;
    esac
  done
  post="${!body_var}"
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    what="ticket item ${ST_N[$i]}"
    case "${ST_KIND[$i]}" in
      section)
        [ "$kind" = collapsed ] \
          || die "$what: a ## Ticket item, but #$issue's breakdown is $kind - nothing written" ;;
      block|unblock)
        for t in "${ST_T[$i]}" "${ST_B[$i]}"; do
          case $'\n'"$subs"$'\n' in
            *$'\n'"$t"$'\n'*) ;;
            *) die "$what: #$t is not a ticket of #$issue's breakdown - nothing written" ;;
          esac
        done ;;
    esac
    spec_review_ticket_local "$i" "$body_var" "$post" "$dir"
  done
}

# spec_review_tickets_check <dir>: check --tickets - <dir>/tickets.md
# validated as apply --tickets would take the all answer, against the ticket
# copies and <dir>/spec.md, with nothing written and no GitHub read. A
# grammar error stops at the first; every other problem is reported, one
# `orch: ` line each, then exit 1. A clean file prints its view on stdout -
# see spec_review_tickets_view - and a one-line summary on stderr.
spec_review_tickets_check() {
  local dir="$1" i anchors=0 __srtc_body
  [ -f "$dir/tickets.md" ] || die "tickets.md not found in $dir"
  [ -f "$dir/spec.md" ] || die "spec.md not found in $dir"
  spec_review_tickets_parse "$dir/tickets.md"
  spec_review_tickets_answer all
  file_read __srtc_body "$dir/spec.md" || die "could not read $dir/spec.md"
  local post="$__srtc_body"
  SR_PROBLEMS=(); TK_T=(); TK_FETCHED=(); TK_TEXT=()
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    spec_review_ticket_local "$i" __srtc_body "$post" "$dir" collect
    case "${ST_KIND[$i]}" in ticket|section) anchors=$((anchors + 1)) ;; esac
  done
  spec_review_problems_exit
  spec_review_tickets_view
  if [ -n "$ST_NONE" ]; then
    note "tickets.md passes: no open ticket affected" >&2
  else
    note "tickets.md passes: ${#ST_N[@]} items, $anchors anchors, each matching once, and the all answer applies cleanly" >&2
  fi
}

# spec_review_tickets_view: the parsed tickets.md as the human reads it
# before the ticket question - every item in order, with its ticket or the
# `## Ticket` section, its recommendation and its edit in full, then the
# closed tickets and the file's recommended answer. Rendered from the ST_
# arrays alone.
spec_review_tickets_view() {
  local i
  printf '## The ticket items\n'
  if [ -n "$ST_NONE" ]; then
    printf '\nNo open ticket is affected.\n'
    return 0
  fi
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    printf '\n### Item %s - ' "${ST_N[$i]}"
    case "${ST_KIND[$i]}" in
      ticket) printf '#%s\n' "${ST_T[$i]}" ;;
      section) printf 'the %s section\n' '`## Ticket`' ;;
      *) printf '%s #%s by #%s\n' "${ST_KIND[$i]}" "${ST_T[$i]}" "${ST_B[$i]}" ;;
    esac
    printf '\n**Recommendation:** '
    case "${ST_REC[$i]}" in
      apply) printf 'apply\n' ;;
      decline) printf 'recommend decline - %s\n' "${ST_ARG[$i]}" ;;
    esac
    case "${ST_KIND[$i]}" in
      ticket|section) spec_review_edit_view "${ST_ANCHOR[$i]}" "${ST_REPLACE[$i]}" ;;
    esac
  done
  printf '\n### Closed tickets\n\n'
  for i in ${ST_CL_T[@]+"${!ST_CL_T[@]}"}; do
    printf -- '- #%s - %s\n' "${ST_CL_T[$i]}" "${ST_CL_WHAT[$i]}"
  done
  [ "${#ST_CL_T[@]}" -gt 0 ] || printf 'None\n'
  printf '\n**Recommended answer:** '
  case "$ST_RECOMMEND" in
    apply) printf 'apply\n' ;;
    retire) printf 'retire - the ticket breakdown retired, to be broken down again\n' ;;
  esac
}

# spec_review_tickets_lines: the changelog's Tickets lines, from tickets.md,
# the ticket answer and the reasons.
spec_review_tickets_lines() {
  local i n reason out=""
  if [ -z "$ST_RETIRE" ]; then
    for i in ${ST_N[@]+"${!ST_N[@]}"}; do
      n="${ST_N[$i]}"
      if [ "${ST_DISP[$i]}" = applied ]; then
        case "${ST_KIND[$i]}" in
          ticket|section) out="$out- ($n) ${ST_SUMMARY[$i]}"$'\n' ;;
          block) out="$out- ($n) #${ST_T[$i]} now blocked by #${ST_B[$i]}"$'\n' ;;
          unblock) out="$out- ($n) #${ST_T[$i]} no longer blocked by #${ST_B[$i]}"$'\n' ;;
        esac
        continue
      fi
      reason="$(spec_review_decline_reason "${ST_REASON[$i]+x}" "${ST_REASON[$i]:-}" \
        "${ST_ASREC[$i]:-}" "${ST_ARG[$i]}")"
      case "${ST_KIND[$i]}" in
        ticket|section) out="$out- ($n) \"$(spec_review_one_line "${ST_REPLACE[$i]}")\" - $reason"$'\n' ;;
        *) out="$out- ($n) \"${ST_KIND[$i]} #${ST_T[$i]} by #${ST_B[$i]}\" - $reason"$'\n' ;;
      esac
    done
  else
    out="- retired, to be broken down again"$'\n'
  fi
  for i in ${ST_CL_T[@]+"${!ST_CL_T[@]}"}; do
    out="$out- #${ST_CL_T[$i]} closed, built against the earlier spec: ${ST_CL_WHAT[$i]}"$'\n'
  done
  printf '%s' "${out%$'\n'}"
  [ -n "$out" ] || printf 'None - no ticket affected'
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

# spec_review_err_line <err>: a captured error's first line, its `orch: `
# prefix dropped, for quoting inside a die message of our own.
spec_review_err_line() {
  local err="${1#orch: }"
  printf '%s' "${err%%$'\n'*}"
}

# spec_review_write <dir> <what> <command...>: one GitHub write, appended to
# <dir>/applied.log once it lands. A failure dies naming <what> and every
# write already landed; nothing is rolled back and changelog.md stays.
spec_review_write() {
  local dir="$1" what="$2" err
  shift 2
  if ! capture_err err "$@" >/dev/null; then
    die "could not write $what: $(spec_review_err_line "$err") - already landed: $(spec_review_landed "$dir"); $dir/changelog.md is kept, and the review stops here"
  fi
  printf '%s\n' "$what" >>"$dir/applied.log" \
    || die "$what landed, but $dir/applied.log could not record it"
}

# spec_review_local_write <file> <text>: <text> written to <file>, exactly,
# before any GitHub write - so a failure dies saying none was made.
spec_review_local_write() {
  { printf '%s' "$2" >"$1"; } 2>/dev/null \
    || die "could not write $1 - nothing written to GitHub"
}

# spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
# [--tickets <answer> [--ticket-reasons <file>]] [--issue <n>] [--unattended]
# [--host-fallbacks <file>]: the round's answer applied, the tickets
# followed, the body published when it changed, any retire run, and the
# changelog written to <dir>/changelog.md, posted, and appended to the
# review-wide settled file, <dir>/settled.md. Every check runs before
# the first write. With an accepted edit and a ticket breakdown but no
# --tickets it pauses, exit 3, before any GitHub write, printing the
# breakdown kind.
spec_review_apply() {
  local usage="usage: orch.sh spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>] [--tickets <answer> [--ticket-reasons <file>]] [--issue <n>] [--unattended] [--host-fallbacks <file>]"
  local dir="" answer="" have_answer="" round="" reasons="" issue="" unattended=false hosts_file="" hosts=""
  local ticket_answer="" ticket_reasons=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --round|--reasons|--issue|--host-fallbacks|--tickets|--ticket-reasons)
        [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value ($usage)"
        case "$1" in
          --round) round="$2" ;;
          --reasons) reasons="$2" ;;
          --issue) issue="$2" ;;
          --host-fallbacks) hosts_file="$2" ;;
          --tickets) ticket_answer="$2" ;;
          --ticket-reasons) ticket_reasons="$2" ;;
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
  case "$ticket_answer" in
    ''|recommended|all|none|retire) ;;
    *[!0-9,\ ]*)
      die "--tickets wants recommended, all, none, retire or a list such as 1, 3, got: $ticket_answer" ;;
  esac
  [ -z "$ticket_reasons" ] || [ -n "$ticket_answer" ] \
    || die "--ticket-reasons goes with --tickets: it holds the ticket answer's decline reasons"
  if [ "$unattended" = true ]; then
    [ -n "$issue" ] || die "--unattended needs --issue: an unattended spec review is a standalone one"
    [ "$answer" = recommended ] \
      || die "--unattended takes only the answer recommended, got: $answer"
    [ -z "$ticket_answer" ] || [ "$ticket_answer" = recommended ] \
      || die "--unattended takes only --tickets recommended, got: $ticket_answer"
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
  # Each ticket file's fetched copy, taken by the first run that finds the
  # file - the --tickets rerun, as the session fetches tickets after the pause.
  local tf tn
  for tf in "$dir"/ticket-*.md; do
    tn="${tf##*/ticket-}"; tn="${tn%.md}"
    case "$tn" in ''|*[!0-9]*) continue ;; esac
    [ -e "$dir/ticket-$tn.fetched.md" ] \
      || cp "$tf" "$dir/ticket-$tn.fetched.md" 2>/dev/null \
      || die "could not copy ticket-$tn.md to $dir/ticket-$tn.fetched.md - nothing written"
  done

  local i j fetched text
  # Every accepted anchor, checked against the fetched copy and applied to it.
  spec_review_validate "$dir" "$dir/spec.fetched.md" "$answer"
  fetched="$SR_FETCHED"; text="$SR_TEXT"
  spec_review_reasons --reasons "$reasons" SR_IT_N SR_DISP SR_REASON \
    item batch.md "the answer"

  # The ticket step's entry: only an applied edit can leave a ticket behind.
  local tickets kind err st=0 changed=""
  ST_N=(); ST_RETIRE=""; TK_T=(); TK_FETCHED=(); TK_TEXT=()
  [ "$text" = "$fetched" ] || changed=1
  if [ -z "$changed" ]; then
    tickets="Not checked - no edit applied"
  else
    capture kind err cmd_ticket_exists "$issue" || st=$?
    case "$st" in
      0) ;;
      1) tickets="None - no ticket breakdown" ;;
      *)
        die "ticket exists #$issue exited $st: $(spec_review_err_line "$err") - nothing written" ;;
    esac
  fi
  if [ -n "$changed" ] && [ "$st" -eq 0 ]; then
    if [ -z "$ticket_answer" ]; then
      # The pause: the session drafts the ticket items and runs apply again.
      spec_review_local_write "$dir/spec.md" "$text"
      note "$kind"
      exit 3
    fi
    [ -f "$dir/tickets.md" ] \
      || die "tickets.md not found in $dir - --tickets answers the ticket items it holds"
    spec_review_tickets_parse "$dir/tickets.md"
    spec_review_tickets_answer "$ticket_answer"
    spec_review_reasons --ticket-reasons "$ticket_reasons" ST_N ST_DISP ST_REASON \
      "ticket item" tickets.md "the --tickets answer"
    spec_review_tickets_follow text "$dir" "$kind" "$issue"
    tickets="$(spec_review_tickets_lines)"
  fi
  spec_review_local_write "$dir/spec.md" "$text"
  for j in ${TK_T[@]+"${!TK_T[@]}"}; do
    spec_review_local_write "$dir/ticket-${TK_T[$j]}.md" "${TK_TEXT[$j]}"
  done

  local log
  log="$(spec_review_changelog "$round" "$unattended" "$tickets" "$hosts")"
  spec_review_local_write "$dir/changelog.md" "$log"$'\n'

  # Flow mode writes through the spec command, whose guards hold; the
  # standalone entry through the stateless issue commands.
  local update=(cmd_issue update "$issue") comment=(cmd_issue comment "$issue")
  [ -z "$flow" ] || { update=(cmd_spec update); comment=(cmd_spec comment); }
  # Ticket text edits, then edges, then the body, then the retire: a ticket's
  # text edit before its edge, whose ## Blocked by rewrite reads the edited
  # body back; a collapsed ## Ticket edit inside the body; a retire after it.
  local done_t=" "
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    [ "${ST_KIND[$i]}" = ticket ] && [ "${ST_DISP[$i]:-}" = applied ] || continue
    case "$done_t" in *" ${ST_T[$i]} "*) continue ;; esac
    done_t="$done_t${ST_T[$i]} "
    spec_review_write "$dir" "ticket #${ST_T[$i]}'s body" \
      cmd_issue update "${ST_T[$i]}" "$dir/ticket-${ST_T[$i]}.md"
  done
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    case "${ST_KIND[$i]}:${ST_DISP[$i]:-}" in
      block:applied|unblock:applied)
        spec_review_write "$dir" "${ST_KIND[$i]} #${ST_T[$i]} by #${ST_B[$i]}" \
          "cmd_ticket_${ST_KIND[$i]}" "${ST_T[$i]}" --by "${ST_B[$i]}" ;;
    esac
  done
  if [ -n "$changed" ]; then
    spec_review_write "$dir" "the body of issue #$issue" "${update[@]}" "$dir/spec.md"
  fi
  if [ -n "$ST_RETIRE" ]; then
    spec_review_write "$dir" "the retire of #$issue's ticket breakdown" cmd_ticket_retire "$issue"
  fi
  spec_review_write "$dir" "the changelog comment on issue #$issue" "${comment[@]}" "$dir/changelog.md"
  # The settled file, last: a pause or a failed write before this point
  # appends nothing, so a rerun never appends a changelog twice.
  { printf '%s\n' "$log" >>"$dir/settled.md"; } 2>/dev/null \
    || die "could not append the changelog to $dir/settled.md - every GitHub write landed: $(spec_review_landed "$dir")"
}
