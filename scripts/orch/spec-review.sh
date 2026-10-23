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
    prompt) spec_review_prompt "$@" ;;
    *) die "unknown spec-review op: ${op:-<none>} (want begin|check|apply|wait|prompt)" ;;
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
  if [ "$carry" = 1 ]; then
    spec_review_dir_reset "$dir" --carry
  else
    spec_review_dir_reset "$dir"
  fi
  printf '%s/\n' "$dir"
}

# spec_review_dir_reset <dir> [--carry]: a round's working directory made
# ready to run in - emptied, created when missing - the one reset both a
# standalone review's begin and a flow's spec round-dir run. --carry keeps
# what a round hands the next, the SPEC_REVIEW_CARRIED files, each when it
# exists, deleting every other entry in place.
spec_review_dir_reset() {
  local dir="$1"
  if [ "${2-}" = --carry ] && [ -d "$dir" ]; then
    local keep=() f
    for f in "${SPEC_REVIEW_CARRIED[@]}"; do keep+=(! -name "$f"); done
    find "$dir" -mindepth 1 -maxdepth 1 "${keep[@]}" -exec rm -rf {} +
  else
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
}

# What a round hands the next: the Implementability lens's code map (#1141)
# and the settled file (#1185), read by both begin's --carry and a flow's spec
# round-dir. A flow's round-dir also carries SPEC_ROUND_LENS_SETTING, which
# --carry leaves out: a standalone review reads the lens setting once, in one
# session.
readonly SPEC_REVIEW_CARRIED=(map-implementability.md settled.md)

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

# spec_review_item_check <index>: dies, naming the item's header line, unless
# the item carries what its recommendation needs.
spec_review_item_check() {
  local i="$1" line="${SR_IT_LINE[$1]}" n="${SR_IT_N[$1]}" opt fd cm opts=0 has_find="" has_comment="" unapplied_hint=""
  for opt in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
    [ "${SR_OP_ITEM[$opt]}" = "$i" ] || continue
    opts=$((opts + 1))
    [ -n "${SR_OP_SUMMARY[$opt]+x}" ] \
      || spec_review_batch_die "${SR_OP_LINE[$opt]}" "item $n option ${SR_OP_LETTER[$opt]} has no @@ summary"
    unapplied_hint=""
    [ "${SR_OP_LETTER[$opt]}" = "${SR_IT_ARG[$i]}" ] || unapplied_hint=" - an option not recommended still carries the edit it would make"
    [ -n "${SR_OP_REPLACE[$opt]+x}" ] \
      || spec_review_batch_die "${SR_OP_LINE[$opt]}" "item $n option ${SR_OP_LETTER[$opt]} has no @@ anchor/@@ replace/@@ end block$unapplied_hint"
  done
  for fd in ${SR_FD_ITEM[@]+"${!SR_FD_ITEM[@]}"}; do
    [ "${SR_FD_ITEM[$fd]}" != "$i" ] || has_find=1
  done
  for cm in ${SR_CM_ITEM[@]+"${!SR_CM_ITEM[@]}"}; do
    [ "${SR_CM_ITEM[$cm]}" != "$i" ] || has_comment=1
  done
  case "${SR_IT_REC[$i]}" in
    apply|decline)
      [ -n "${SR_IT_SUMMARY[$i]+x}" ] || spec_review_batch_die "$line" "item $n has no @@ summary"
      unapplied_hint=""
      [ "${SR_IT_REC[$i]}" != decline ] || unapplied_hint=" - a decline item still carries the edit it declines"
      [ -n "${SR_IT_REPLACE[$i]+x}" ] || spec_review_batch_die "$line" "item $n has no @@ anchor/@@ replace/@@ end block$unapplied_hint" ;;
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
  [ "${SR_IT_MARK[$i]}" != material ] || [ -n "${SR_IT_WHY[$i]+x}" ] \
    || spec_review_batch_die "$line" "item $n has no @@ why"
}

# spec_review_batch_die <line> <message>: a malformed batch file, refused
# naming the line.
spec_review_batch_die() { die "batch.md line $1: $2"; }

# The most words a batch.md @@ summary may hold (#1352), so each line of the
# compact view stays short.
SPEC_REVIEW_SUMMARY_WORDS=30

# spec_review_summary_cap <line> <what> <summary>: dies, naming <line> and
# <what> - `item <n>` or `item <n> option <L>` - when <summary> holds more
# than SPEC_REVIEW_SUMMARY_WORDS words, each a run of non-whitespace.
spec_review_summary_cap() {
  local words
  read -r -a words <<<"$3"
  [ "${#words[@]}" -le "$SPEC_REVIEW_SUMMARY_WORDS" ] \
    || spec_review_batch_die "$1" "$2's @@ summary has ${#words[@]} words, more than $SPEC_REVIEW_SUMMARY_WORDS"
}

# spec_review_mark_check <line> <n> <rec> <mark>: dies, naming <line>,
# unless item <n>'s <mark> - the last fixed token of its `@@ item` line - is
# material or minor, or fundamental when ORCH_AUTOPILOT=1 (a fundamental item
# is material everywhere else: the parser reads it as material, flagged in
# SR_IT_FUND).
spec_review_mark_check() {
  case "$4" in
    material|minor) ;;
    fundamental) autopilot_active \
      || spec_review_batch_die "$1" "item $2's mark must be material or minor, got 'fundamental' - the mark is accepted only in an autopilot flow" ;;
    '') spec_review_batch_die "$1" "@@ item $2 ... $3 needs its mark, material or minor" ;;
    *) spec_review_batch_die "$1" "item $2's mark must be material or minor, got '$4'" ;;
  esac
}

# spec_review_at_line <line> <kw-var> <args-var>: an `@@` line of the batch
# or tickets file split, its trailing CR stripped, into its keyword and the
# rest of the line after one space - empty when there is none.
spec_review_at_line() {
  local __sral_rest="${1%$'\r'}" __sral_args=""
  __sral_rest="${__sral_rest#@@}"; __sral_rest="${__sral_rest# }"
  [ "${__sral_rest%% *}" = "$__sral_rest" ] || __sral_args="${__sral_rest#* }"
  printf -v "$2" '%s' "${__sral_rest%% *}"
  printf -v "$3" '%s' "$__sral_args"
}

# spec_review_batch_parse <file>: reads the batch file into the SR_ arrays -
# the `@@ lens` lines, then one entry per item, its findings, comments and
# options - dying on the first malformed line, named by its number. The
# citations' ranges are checked later, against the lens files.
spec_review_batch_parse() {
  local file="$1" line lineno=0 mode=top kw args cur=-1 opt=-1
  local buf="" bufn=0 block_line=0 quote_wanted="" n group rec rec_tail arg lens state reason
  local fd_lens fd_k login created letter label extra lens_slot fd_slot cm_slot target mark fund
  SR_LENS_NAME=(); SR_LENS_STATE=(); SR_LENS_REASON=()
  SR_IT_N=(); SR_IT_GROUP=(); SR_IT_REC=(); SR_IT_ARG=(); SR_IT_MARK=(); SR_IT_LINE=(); SR_IT_FUND=()
  SR_IT_SUMMARY=(); SR_IT_WHY=(); SR_IT_ANCHOR=(); SR_IT_ANCHOR_LINE=(); SR_IT_REPLACE=(); SR_IT_RESOLVED=()
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
    spec_review_at_line "$line" kw args
    case "$mode" in
      anchor)
        [ "$kw" = replace ] && [ -z "$args" ] \
          || spec_review_batch_die "$lineno" "expected @@ replace to end the anchor begun on line $block_line, got '$line'"
        [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the anchor is empty"
        if [ "$opt" -ge 0 ]; then
          SR_OP_ANCHOR[opt]="$buf"; SR_OP_ANCHOR_LINE[opt]="$block_line"
        else
          SR_IT_ANCHOR[cur]="$buf"; SR_IT_ANCHOR_LINE[cur]="$block_line"
        fi
        mode=replace; buf=""; bufn=0; block_line="$lineno"
        continue ;;
      replace)
        [ "$kw" = end ] && [ -z "$args" ] \
          || spec_review_batch_die "$lineno" "expected @@ end to end the replacement begun on line $block_line, got '$line'"
        if [ "$opt" -ge 0 ]; then SR_OP_REPLACE[opt]="$buf"; else SR_IT_REPLACE[cur]="$buf"; fi
        mode=item; buf=""; bufn=0
        continue ;;
      quote)
        [ -n "$(trim "$buf")" ] || spec_review_batch_die "$block_line" "the quote is empty"
        SR_CM_QUOTE+=("$buf")
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
        lens_slot="${#SR_LENS_NAME[@]}"
        SR_LENS_NAME[lens_slot]="$lens"; SR_LENS_STATE[lens_slot]="$state"; SR_LENS_REASON[lens_slot]="$reason" ;;
      item)
        [ "$cur" -lt 0 ] || spec_review_item_check "$cur"
        read -r n group rec rec_tail <<<"$args"
        case "$n" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "item number must be a positive number, got '$n'" ;; esac
        [ -z "$(array_index SR_IT_N "$n")" ] || spec_review_batch_die "$lineno" "a second item $n"
        case "$group" in
          consolidation|contradicts-the-plan) ;;
          *) spec_review_lens_known "$group" \
               || spec_review_batch_die "$lineno" "unknown group '$group' (want consolidation, a lens, or contradicts-the-plan)" ;;
        esac
        mark=""; arg=""
        case "$rec" in
          apply)
            read -r mark extra <<<"$rec_tail"
            spec_review_mark_check "$lineno" "$n" "$rec" "$mark"
            [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ item $n ... apply takes nothing after its mark" ;;
          resolved)
            case "$rec_tail" in
              material|material' '*|minor|minor' '*|fundamental|fundamental' '*) spec_review_batch_die "$lineno" "@@ item $n ... a resolved item carries no mark" ;;
            esac
            [ -z "$rec_tail" ] || spec_review_batch_die "$lineno" "@@ item $n ... resolved takes nothing after it" ;;
          decline)
            read -r mark arg <<<"$rec_tail"
            spec_review_mark_check "$lineno" "$n" "$rec" "$mark"
            [ -n "$arg" ] || spec_review_batch_die "$lineno" "@@ item $n ... decline needs a reason after its mark" ;;
          decision)
            read -r arg mark extra <<<"$rec_tail"
            case "$arg" in [A-Z]) ;; *) spec_review_batch_die "$lineno" "@@ item $n ... decision needs the recommended option's letter, A to Z" ;; esac
            spec_review_mark_check "$lineno" "$n" "$rec" "$mark"
            [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ item $n ... decision takes nothing after its mark" ;;
          *) spec_review_batch_die "$lineno" "item $n's recommendation must be apply <mark>, decline <mark> <reason>, decision <letter> <mark> or resolved" ;;
        esac
        fund=""
        if [ "$mark" = fundamental ]; then fund=1; mark=material; fi
        [ "$mark" != minor ] || [ "$rec" != decision ] \
          || spec_review_batch_die "$lineno" "decision item $n is always material, never minor"
        [ "$mark" != minor ] || [ "$group" != contradicts-the-plan ] \
          || spec_review_batch_die "$lineno" "contradicts-the-plan item $n is always material, never minor"
        cur="${#SR_IT_N[@]}"; opt=-1
        SR_IT_N[cur]="$n"; SR_IT_GROUP[cur]="$group"; SR_IT_REC[cur]="$rec"
        SR_IT_ARG[cur]="$arg"; SR_IT_MARK[cur]="$mark"; SR_IT_LINE[cur]="$lineno"
        [ -z "$fund" ] || SR_IT_FUND[cur]=1
        mode=item ;;
      summary)
        [ -n "$args" ] || spec_review_batch_die "$lineno" "@@ summary needs its line"
        [ "${SR_IT_REC[$cur]}" != resolved ] || spec_review_batch_die "$lineno" "a resolved item carries no @@ summary"
        if [ "$opt" -ge 0 ]; then
          spec_review_summary_cap "$lineno" "item ${SR_IT_N[$cur]} option ${SR_OP_LETTER[$opt]}" "$args"
          [ -z "${SR_OP_SUMMARY[$opt]+x}" ] || spec_review_batch_die "$lineno" "a second @@ summary for this option"
          SR_OP_SUMMARY[opt]="$args"
        else
          [ "${SR_IT_REC[$cur]}" != decision ] || spec_review_batch_die "$lineno" "a decision item's summaries go under its options"
          spec_review_summary_cap "$lineno" "item ${SR_IT_N[$cur]}" "$args"
          [ -z "${SR_IT_SUMMARY[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ summary for this item"
          SR_IT_SUMMARY[cur]="$args"
        fi ;;
      why)
        [ -n "$args" ] || spec_review_batch_die "$lineno" "@@ why needs its line"
        [ "${SR_IT_REC[$cur]}" != resolved ] || spec_review_batch_die "$lineno" "a resolved item carries no @@ why"
        [ "${SR_IT_MARK[$cur]}" = material ] || spec_review_batch_die "$lineno" "a minor item carries no @@ why"
        [ "$opt" -lt 0 ] || spec_review_batch_die "$lineno" "@@ why belongs to the item, never under an @@ option"
        [ -z "${SR_IT_WHY[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ why for this item"
        SR_IT_WHY[cur]="$args" ;;
      finding)
        read -r fd_lens fd_k extra <<<"$args"
        [ -n "$fd_lens" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>"
        case "$fd_k" in ''|*[!0-9]*|0*) spec_review_batch_die "$lineno" "@@ finding wants <lens> <k>, k a positive number" ;; esac
        fd_slot="${#SR_FD_ITEM[@]}"
        SR_FD_ITEM[fd_slot]="$cur"; SR_FD_LENS[fd_slot]="$fd_lens"; SR_FD_K[fd_slot]="$fd_k"; SR_FD_LINE[fd_slot]="$lineno" ;;
      comment)
        read -r login created extra <<<"$args"
        case "$login" in @?*) ;; *) spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>" ;; esac
        [ -n "$created" ] && [ -z "$extra" ] || spec_review_batch_die "$lineno" "@@ comment wants @<login> <createdAt>"
        cm_slot="${#SR_CM_ITEM[@]}"
        SR_CM_ITEM[cm_slot]="$cur"; SR_CM_LOGIN[cm_slot]="$login"; SR_CM_CREATED[cm_slot]="$created"
        quote_wanted=1 ;;
      quote)
        [ -n "$quote_wanted" ] || spec_review_batch_die "$lineno" "@@ quote must follow @@ comment"
        [ -z "$args" ] || spec_review_batch_die "$lineno" "@@ quote takes nothing after it; the quote is the lines below it"
        quote_wanted=""; mode=quote; buf=""; bufn=0; block_line="$lineno" ;;
      resolved-by)
        [ "${SR_IT_REC[$cur]}" = resolved ] || spec_review_batch_die "$lineno" "@@ resolved-by belongs to a resolved item"
        [ -z "${SR_IT_RESOLVED[$cur]+x}" ] || spec_review_batch_die "$lineno" "a second @@ resolved-by"
        target="$(array_index SR_IT_N "$args")"
        [ -n "$args" ] && [ -n "$target" ] && [ "$target" -lt "$cur" ] \
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
          resolved) spec_review_batch_die "$lineno" "a resolved item takes no @@ anchor, @@ replace or @@ end" ;;
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
      SR_CM_QUOTE+=("$buf") ;;
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

# spec_review_answer_tokens <answer> <array-var>: an Other-list answer split
# on its commas into the named array, each token trimmed - a trailing comma
# giving an empty last token.
spec_review_answer_tokens() {
  local __srat_rest="$1," __srat_k=0
  eval "$2=()"
  while [ -n "$__srat_rest" ]; do
    trim_split "${__srat_rest%%,*}" "$2[$__srat_k]"
    __srat_rest="${__srat_rest#*,}"
    __srat_k=$((__srat_k + 1))
  done
}

# spec_review_item_held <i>: whether item <i> is a fundamental item an
# autopilot round's first run holds back for the human's reply.
spec_review_item_held() { [ "${SR_FMODE:-}" = hold ] && [ -n "${SR_IT_FUND[$1]:-}" ]; }

# spec_review_item_skipped <i>: whether item <i> is one the resumed run leaves
# alone - the round already applied it before the fundamental items were held.
spec_review_item_skipped() { [ "${SR_FMODE:-}" = resume ] && [ -z "${SR_IT_FUND[$1]:-}" ]; }

# spec_review_answer <answer>: each item's disposition into
# SR_DISP (applied, declined, taken, undecided or resolved), SR_ASREC (1 where
# the human's call matched the recommendation) and SR_TAKEN (a decision's
# letter), from the batch question's answer: recommended, all, none, or an
# Other override list such as `3B, -4, +2`, naming only the departures from
# the recommendation - `<n><letter>` a decision's option, `-<n>` an item
# declined or a decision left undecided, `+<n>` a recommend-decline item
# applied - with every item it does not name taken as recommended. Dies,
# before any write, on a token of no such form (a bare number among them), an
# unknown item or option, a letter on an item that is no decision, `+` on a
# decision or on an item not recommended for decline, `-` or `+` on a
# resolved item, or an item named twice.
spec_review_answer() {
  local answer="$1" base="$1" i tok n letter sign bad j toks=()
  local form="is not recommended, all, none or a list of departures such as 3B, -4, +2"
  SR_DISP=(); SR_ASREC=(); SR_TAKEN=()
  case "$answer" in
    recommended|all|none) ;;
    *)
      base=recommended
      spec_review_answer_tokens "$answer" toks
      for tok in "${toks[@]}"; do
        sign=""; letter=""
        case "$tok" in
          [-+]*) sign="${tok:0:1}"; n="${tok:1}" ;;
          *) n="${tok%%[A-Za-z]*}"; letter="${tok#"$n"}" ;;
        esac
        bad=""
        case "$n" in ''|*[!0-9]*) bad=1 ;; esac
        case "$sign:$letter" in :[A-Za-z]|[-+]:) ;; *) bad=1 ;; esac
        [ -z "$bad" ] || die "the answer '$answer' $form - '$tok' is not <n><letter>, -<n> or +<n>"
        letter="$(printf '%s' "$letter" | tr '[:lower:]' '[:upper:]')"
        i="$(array_index SR_IT_N "$n")"
        [ -n "$i" ] || die "the answer names item $n, which batch.md does not have"
        [ -z "${SR_DISP[$i]+x}" ] || die "the answer names item $n twice"
        ! spec_review_item_held "$i" \
          || die "the answer names item $n, a fundamental item held back for the human's reply - it takes no answer in this run"
        ! spec_review_item_skipped "$i" \
          || die "the answer names item $n, which this round applied before the fundamental items were held back - the resumed answer names only fundamental items"
        [ "${SR_IT_REC[$i]}" != resolved ] \
          || die "the answer names item $n, which is resolved by item ${SR_IT_RESOLVED[$i]} and takes no answer"
        case "$sign:${SR_IT_REC[$i]}" in
          :decision)
            j="$(spec_review_option_index "$i" "$letter")"
            [ -n "$j" ] || die "the answer gives item $n option $letter, which it does not have"
            SR_DISP[i]=taken; SR_TAKEN[i]="$letter"
            [ "$letter" != "${SR_IT_ARG[$i]}" ] || SR_ASREC[i]=1 ;;
          :*) die "the answer gives item $n the letter $letter, but item $n is no decision item" ;;
          -:decision) SR_DISP[i]=undecided ;;
          -:decline) SR_DISP[i]=declined; SR_ASREC[i]=1 ;;
          -:*) SR_DISP[i]=declined ;;
          +:decline) SR_DISP[i]=applied ;;
          +:decision) die "the answer names +$n, but item $n is a decision item: name its option, as ${n}${SR_IT_ARG[$i]}" ;;
          +:*) die "the answer names +$n, but item $n is not recommended for decline" ;;
        esac
      done ;;
  esac
  local ibase
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    case "${SR_IT_REC[$i]}" in
      resolved) SR_DISP[i]=resolved; continue ;;
    esac
    # A fundamental item is held back in an autopilot round's first run; the
    # resumed run's answer is the fundamental items' alone, the rest recommended.
    if spec_review_item_held "$i"; then SR_DISP[i]=held; continue; fi
    ibase="$base"
    ! spec_review_item_skipped "$i" || ibase=recommended
    [ -z "${SR_DISP[$i]+x}" ] || continue
    case "$ibase:${SR_IT_REC[$i]}" in
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
  local line lineno=0 n reason i disp_ref reason_ref
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
    disp_ref="${disps}[$i]"
    [ "${!disp_ref:-}" = declined ] \
      || die "$flag line $lineno names $noun $n, which $answer_name does not decline"
    reason_ref="${reasons}[$i]"
    [ -z "${!reason_ref+x}" ] || die "$flag line $lineno names $noun $n a second time"
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

# spec_review_edit <var> <fetched> <what> <anchor> <replacement>: the text
# in <var> with <anchor> replaced once, when the anchor occurs exactly once
# both in <fetched>, the body as fetched, and in the text the earlier items
# left. Otherwise the problem, naming <what>, is appended to SR_PROBLEMS,
# <var> is left unedited, and it returns 1.
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
    SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$3: $__sre_problem"
    return 1
  fi
  printf -v "$1" '%s' "${__sre_text%%"$4"*}$5${__sre_text#*"$4"}"
}

# spec_review_edit_accepted <accepted> <var> <fetched> <what> <anchor>
# <replacement>: spec_review_edit on <var> when <accepted> is set, else the
# anchor checked on its own against a scratch copy of <fetched>, so a declined
# item's broken anchor is a problem too. Returns spec_review_edit's status.
spec_review_edit_accepted() {
  if [ -n "$1" ]; then
    spec_review_edit "$2" "$3" "$4" "$5" "$6"
  else
    # shellcheck disable=SC2034 # spec_review_edit writes it by name; discarded
    local scratch="$3"
    spec_review_edit scratch "$3" "$4" "$5" "$6"
  fi
}

# spec_review_anchor_visit <accepted> <what> <anchor> <replacement>: one
# anchor of spec_review_validate's, counted into SR_ANCHOR_COUNT - applied to
# SR_TEXT when <accepted> is set, else checked on its own against a scratch
# copy of SR_FETCHED (see spec_review_edit_accepted).
spec_review_anchor_visit() {
  SR_ANCHOR_COUNT=$((SR_ANCHOR_COUNT + 1))
  spec_review_edit_accepted "$1" SR_TEXT "$SR_FETCHED" "$2" "$3" "$4" || true
}

# spec_review_validate <dir> <body-file> <answer>: the one validation check
# and apply share. Reads <dir>/batch.md and the lens files of
# the lenses that ran, checks the citations, takes <answer> (see
# spec_review_answer), and applies every anchor it accepts, in batch order, to
# <body-file>'s text: SR_FETCHED holds the body as read, SR_TEXT the body
# edited. Grammar, lens and citation errors die on the first. Every anchor is
# visited (see spec_review_anchor_visit) and counted into SR_ANCHOR_COUNT -
# the ones the answer declines checked on their own against SR_FETCHED - and
# each problem, naming its `@@ anchor` line, is appended to SR_PROBLEMS, the
# failed edit skipped; each caller reacts to SR_PROBLEMS itself.
spec_review_validate() {
  local dir="$1" body="$2" answer="$3" lens i l opt accepted
  spec_review_batch_parse "$dir/batch.md"
  SR_LF_LENS=(); SR_LF_K=(); SR_LF_TEXT=()
  for lens in $SPEC_REVIEW_LENSES; do
    l="$(array_index SR_LENS_NAME "$lens")"
    [ "${SR_LENS_STATE[$l]}" != ran ] || spec_review_lens_parse "$dir" "$lens"
  done
  spec_review_findings_check
  spec_review_answer "$answer"
  file_read SR_FETCHED "$body" || die "could not read $body - nothing written"
  SR_TEXT="$SR_FETCHED"
  SR_PROBLEMS=(); SR_ANCHOR_COUNT=0
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    # The resumed run's body already holds the other items' edits.
    ! spec_review_item_skipped "$i" || continue
    case "${SR_IT_REC[$i]}" in
      apply|decline)
        accepted=""
        [ "${SR_DISP[$i]}" != applied ] || accepted=1
        spec_review_anchor_visit "$accepted" "batch.md line ${SR_IT_ANCHOR_LINE[$i]}: item ${SR_IT_N[$i]}" \
          "${SR_IT_ANCHOR[$i]}" "${SR_IT_REPLACE[$i]}" ;;
      decision)
        for opt in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
          [ "${SR_OP_ITEM[$opt]}" = "$i" ] || continue
          accepted=""
          [ "${SR_DISP[$i]}" != taken ] || [ "${SR_TAKEN[$i]}" != "${SR_OP_LETTER[$opt]}" ] || accepted=1
          spec_review_anchor_visit "$accepted" \
            "batch.md line ${SR_OP_ANCHOR_LINE[$opt]}: item ${SR_IT_N[$i]} option ${SR_OP_LETTER[$opt]}" \
            "${SR_OP_ANCHOR[$opt]}" "${SR_OP_REPLACE[$opt]}"
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

# --- spec-review prompt (#1521) ------------------------------------------------
#
# A lens's whole prompt, for the session to pass unchanged: path existence is a
# fact orch.sh hands the lens, never one the lens discovers, so a lens never
# probes a round file that is not there.

# spec_review_prompt_line <label> <path>: `<label>: <path>` when <path>
# exists, `<label>: none` otherwise - an input the lens reads only when given.
spec_review_prompt_line() {
  if [ -e "$2" ]; then printf '%s: %s\n' "$1" "$2"; else printf '%s: none\n' "$1"; fi
}

# spec-review prompt <dir> <lens>: prints <lens>'s prompt, one labelled line
# per path in its row of the lens table, every path absolute, the findings
# file last. <dir> is a standalone review's directory or a flow's round
# directory, holding spec.md and comments.md, which the session fetched first.
# A missing optional input prints none; the findings file and the
# Implementability map file are write targets, always given. Fidelity runs
# only in a flow round directory - one under SPEC_ROUNDS_DIR - and its plan
# handoff is what `handoff path spec` prints, the op dying when it fails.
spec_review_prompt() {
  [ $# -eq 2 ] || die "usage: orch.sh spec-review prompt <dir> <lens>"
  local dir="${1%/}" lens="$2" plan plan_err
  spec_review_lens_known "$lens" || die "unknown lens '$lens' (want one of: $SPEC_REVIEW_LENSES)"
  [ -d "$dir" ] || die "no such directory: $dir"
  dir="$(cd "$dir" && pwd -P)" || die "cannot resolve the directory: $1"
  [ -f "$dir/spec.md" ] || die "no spec body: $dir/spec.md does not exist - fetch it first"
  [ -f "$dir/comments.md" ] || die "no comments file: $dir/comments.md does not exist - fetch it first"
  if [ "$lens" = fidelity ]; then
    case "$dir/" in
      "$SPEC_ROUNDS_DIR"/?*) ;;
      *) die "the Fidelity lens runs only in a flow's spec review: $dir is not under $SPEC_ROUNDS_DIR/" ;;
    esac
    capture plan plan_err cmd_handoff path spec || {
      [ -z "$plan_err" ] || die "no plan handoff for the Fidelity prompt: ${plan_err#orch: }"
      die "no plan handoff for the Fidelity prompt: $plan does not exist"
    }
  fi
  printf 'Spec body: %s\nComments: %s\n' "$dir/spec.md" "$dir/comments.md"
  case "$lens" in
    consistency)
      spec_review_prompt_line Glossary "$dir/glossary.md"
      spec_review_prompt_line 'ADR directory' "$ROOT/docs/adr/"
      ;;
    testability) printf 'Repo root: %s\n' "$ROOT" ;;
    implementability)
      printf 'Repo root: %s\n' "$ROOT"
      spec_review_prompt_line 'Previous map' "$dir/map-implementability.md"
      printf 'Map file: %s\n' "$dir/map-implementability.md"
      ;;
    fidelity) printf 'Plan handoff: %s\n' "$plan" ;;
  esac
  spec_review_prompt_line Settled "$dir/settled.md"
  printf 'Findings file: %s\n' "$dir/lens-$lens.md"
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
# only <dir>/view.md, touches no GitHub, reads no flow state. Grammar, lens and citation
# errors stop at the first; every anchor problem is reported, one `orch: `
# line each, then exit 1, leaving any earlier view.md as it was. A clean batch
# prints its view on stdout - see spec_review_view - saves it to
# <dir>/view.md (see spec_review_view_save), and prints a one-line summary on
# stderr, ending in spec_review_nudge. With --tickets, the
# round's tickets.md instead: see spec_review_tickets_check. With --full
# <n>..., the same validation, then only the named items on stdout, each in
# full (see spec_review_item_view), in the order named - any item in
# batch.md, minor or resolved included.
spec_review_check() {
  local usage="usage: orch.sh spec-review check <dir> [--tickets | --full <n>...]" dir="" tickets="" full="" n
  local wanted=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --tickets) tickets=1 ;;
      --full) full=1 ;;
      -*) die "unknown option: $1 ($usage)" ;;
      *)
        if [ -n "$full" ]; then
          wanted+=("$1")
        else
          [ -z "$dir" ] || die "$usage"; dir="$1"
        fi ;;
    esac
    shift
  done
  [ -n "$dir" ] || die "$usage"
  [ -z "$full" ] || [ -z "$tickets" ] || die "--full and --tickets do not combine ($usage)"
  [ -z "$full" ] || [ "${#wanted[@]}" -gt 0 ] || die "--full needs at least one item number ($usage)"
  dir="${dir%/}"
  local body
  [ -d "$dir" ] || die "no such directory: $dir"
  if [ -n "$tickets" ]; then
    spec_review_tickets_check "$dir"
    return 0
  fi
  [ -f "$dir/batch.md" ] || die "batch.md not found in $dir"
  body=spec.fetched.md
  [ -e "$dir/$body" ] || body=spec.md
  [ -f "$dir/$body" ] || die "spec.md not found in $dir"
  spec_review_validate "$dir" "$dir/$body" all
  spec_review_problems_exit
  if [ -n "$full" ]; then
    for n in "${wanted[@]}"; do
      [ -n "$(array_index SR_IT_N "$n")" ] || die "--full $n: batch.md has no item $n"
    done
    local index=()
    for n in "${wanted[@]}"; do index+=("$(array_index SR_IT_N "$n")"); done
    spec_review_view_save "$dir" spec_review_full_view "${index[@]}"
  else
    spec_review_view_save "$dir" spec_review_view
  fi
  note "batch.md passes: ${#SR_IT_N[@]} items, $SR_ANCHOR_COUNT anchors, each matching once in $body, and the all answer applies cleanly$(spec_review_nudge "$dir")" >&2
}

# spec_review_full_view <index>...: check --full's view - each item <index>
# in full (see spec_review_item_view), in the order given.
spec_review_full_view() {
  local i
  for i in "$@"; do spec_review_item_view "$i"; done
}

# spec_review_view_save <dir> <command...>: <command>'s stdout, a view,
# written to <dir>/view.md - overwriting any earlier one - and then printed on
# stdout, exactly. Dies before printing anything when the view cannot be
# rendered or view.md cannot be written.
spec_review_view_save() {
  local dir="$1" view
  shift
  view="$("$@" && printf x)" || exit 1
  view="${view%x}"
  { printf '%s' "$view" >"$dir/view.md"; } 2>/dev/null \
    || die "could not write $(spec_review_view_path "$dir")"
  printf '%s' "$view"
}

# spec_review_view_path <dir>: <dir>/view.md's absolute path - <dir> taken
# from the current directory when relative, symlinks left as named.
spec_review_view_path() {
  case "$1" in
    /*) printf '%s/view.md' "$1" ;;
    *) printf '%s/%s/view.md' "$PWD" "$1" ;;
  esac
}

# spec_review_nudge <dir>: what a check pass line that saved a view ends
# with - the instruction to end the turn on one plain-text reply holding the
# view word for word and the question, with no tool call (ADR-0051), and the
# view.md it was saved to, by absolute path. scripts/hook-paste-guard.sh
# arms on a pass line ending "; it is saved in <path>/view.md": keep that tail.
spec_review_nudge() {
  printf ' - end your turn on one plain-text reply, no tool call: the view above word for word, then the question with its answer words spelled out; it is saved in %s' \
    "$(spec_review_view_path "$1")"
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

# spec_review_group_title <index>: the title item <index>'s header gives its
# group - Contradicts the plan, else its section's heading.
spec_review_group_title() {
  case "${SR_IT_GROUP[$1]}" in
    contradicts-the-plan) printf 'Contradicts the plan' ;;
    *) spec_review_title "${SR_IT_GROUP[$1]}" ;;
  esac
}

# spec_review_item_view <index>: item <index> in full - its group, its
# recommendation (a resolved item's resolving item), the text of each finding it cites and of each comment it
# folds in, and its edit, or each option's, in full.
spec_review_item_view() {
  local i="$1" j
  printf '\n### Item %s - %s\n\n**Recommendation:** ' "${SR_IT_N[$i]}" "$(spec_review_group_title "$i")"
  case "${SR_IT_REC[$i]}" in
    apply) printf 'apply\n' ;;
    decline) printf 'recommend decline - %s\n' "${SR_IT_ARG[$i]}" ;;
    decision) printf 'decision - option %s recommended\n' "${SR_IT_ARG[$i]}" ;;
    resolved) printf 'resolved by item %s\n' "${SR_IT_RESOLVED[$i]}" ;;
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
        printf '\n#### %s\n' "$(spec_review_option_line "$i" "$j")"
        spec_review_edit_view "${SR_OP_ANCHOR[$j]}" "${SR_OP_REPLACE[$j]}"
      done ;;
  esac
}

# spec_review_option_line <index> <option>: option <option> of decision item
# <index> as both views name it - `Option <L> - <label>`, then ` (recommended)`
# when it is the recommended one - the compact view's sub-bullet and --full's
# heading alike.
spec_review_option_line() {
  printf 'Option %s - %s' "${SR_OP_LETTER[$2]}" "${SR_OP_LABEL[$2]}"
  [ "${SR_OP_LETTER[$2]}" != "${SR_IT_ARG[$1]}" ] || printf ' (recommended)'
}

# spec_review_minor_line <index>: minor or resolved item <index> on one line
# - `- **<n>** - <Group>: <summary>`, a recommend-decline's reason after it,
# or a resolved item's resolving item in place of a summary. The number is
# literal, never a Markdown ordered-list number a renderer would recount.
spec_review_minor_line() {
  local i="$1"
  printf -- '- **%s** - %s: ' "${SR_IT_N[$i]}" "$(spec_review_group_title "$i")"
  case "${SR_IT_REC[$i]}" in
    resolved) printf 'resolved by item %s\n' "${SR_IT_RESOLVED[$i]}" ;;
    decline) printf '%s - recommend decline: %s\n' "${SR_IT_SUMMARY[$i]}" "${SR_IT_ARG[$i]}" ;;
    *) printf '%s\n' "${SR_IT_SUMMARY[$i]}" ;;
  esac
}

# spec_review_material_entry <index>: material item <index> as one entry of
# the compact view's list - one line, `- **<n>** - **<Group>** - <summary>
# (apply) - <why>`, a recommend-decline's `(recommend decline: <reason>)` in
# place of `(apply)`, with <n> its literal batch.md number, never a Markdown
# ordered-list number a renderer would recount; a decision item's header
# `- **<n>** - **<Group>** (decision, option <L> recommended) - <why>`, then
# one sub-bullet per option, `Option <L> - <label>: <summary>` (see
# spec_review_option_line), indented a fixed 2 spaces, so none is ever a
# 4-space code block. No citation and no diff: --full shows those.
spec_review_material_entry() {
  local i="$1" n="${SR_IT_N[$1]}" j
  case "${SR_IT_REC[$i]}" in
    apply) printf -- '- **%s** - **%s** - %s (apply) - %s\n' "$n" "$(spec_review_group_title "$i")" \
      "${SR_IT_SUMMARY[$i]}" "${SR_IT_WHY[$i]}" ;;
    decline) printf -- '- **%s** - **%s** - %s (recommend decline: %s) - %s\n' "$n" "$(spec_review_group_title "$i")" \
      "${SR_IT_SUMMARY[$i]}" "${SR_IT_ARG[$i]}" "${SR_IT_WHY[$i]}" ;;
    decision)
      printf -- '- **%s** - **%s** (decision, option %s recommended) - %s\n' "$n" "$(spec_review_group_title "$i")" \
        "${SR_IT_ARG[$i]}" "${SR_IT_WHY[$i]}"
      for j in ${SR_OP_ITEM[@]+"${!SR_OP_ITEM[@]}"}; do
        [ "${SR_OP_ITEM[$j]}" = "$i" ] || continue
        printf '  - %s: %s\n' "$(spec_review_option_line "$i" "$j")" "${SR_OP_SUMMARY[$j]}"
      done ;;
  esac
}

# spec_review_view: the parsed batch as the human reads it before the batch
# question - the lens lines, worded as the changelog words them, then the
# material items as one list in batch order, each under its batch.md number
# (see spec_review_material_entry), then, under a Minor edits
# heading omitted when there are none, every minor and resolved item on one
# line, in batch order. Rendered from spec_review_validate's arrays alone.
spec_review_view() {
  local l i minor=() first=1
  printf '## The batch\n\n### Lenses\n\n'
  for l in "${!SR_LENS_NAME[@]}"; do
    printf -- '- %s: ' "$(spec_review_title "${SR_LENS_NAME[$l]}")"
    spec_review_lens_state_line "$l"
  done
  for i in ${SR_IT_N[@]+"${!SR_IT_N[@]}"}; do
    if [ "${SR_IT_MARK[$i]}" = material ]; then
      [ -z "$first" ] || printf '\n'
      first=""
      spec_review_material_entry "$i"
    else
      minor+=("$i")
    fi
  done
  [ "${#minor[@]}" -gt 0 ] || return 0
  printf '\n### Minor edits\n\n'
  for i in "${minor[@]}"; do spec_review_minor_line "$i"; done
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
# An applied item reads `- (<n>) <summary>`, minor or material alike (#1352).
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
      list_has "$(spec_review_item_sections "$i")" "$section" || continue
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
  local file="$1" line lineno=0 mode=top kw args cur=-1 seen=""
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
    spec_review_at_line "$line" kw args
    case "$mode" in
      anchor)
        [ "$kw" = replace ] && [ -z "$args" ] \
          || spec_review_tickets_die "$lineno" "expected @@ replace to end the anchor begun on line $block_line, got '$line'"
        [ -n "$(trim "$buf")" ] || spec_review_tickets_die "$block_line" "the anchor is empty"
        ST_ANCHOR[cur]="$buf"
        mode=replace; buf=""; bufn=0; block_line="$lineno"
        continue ;;
      replace)
        [ "$kw" = end ] && [ -z "$args" ] \
          || spec_review_tickets_die "$lineno" "expected @@ end to end the replacement begun on line $block_line, got '$line'"
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
  local answer="$1" tok i toks=()
  ST_DISP=(); ST_ASREC=(); ST_RETIRE=""
  case "$answer" in
    retire) ST_RETIRE=1; return 0 ;;
    recommended)
      [ "$ST_RECOMMEND" != retire ] || { ST_RETIRE=1; return 0; } ;;
    all|none) ;;
    *)
      spec_review_answer_tokens "$answer" toks
      for tok in "${toks[@]}"; do
        case "$tok" in ''|*[!0-9]*) die "the --tickets answer '$answer' is not recommended, all, none, retire or a list such as 1, 3 - '$tok' is no ticket item" ;; esac
        i="$(array_index ST_N "$tok")"
        [ -n "$i" ] || die "the --tickets answer names ticket item $tok, which tickets.md does not have"
        [ -z "${ST_DISP[$i]+x}" ] || die "the --tickets answer names ticket item $tok twice"
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

# spec_review_ticket_load <dir> <t> <what>: ticket #<t>'s copy into
# TK_FETCHED and TK_TEXT, once - ticket-<t>.fetched.md, else, before any
# apply run has taken that copy, ticket-<t>.md. When the session wrote no
# ticket-<t>.md, the problem, naming <what>, is appended to SR_PROBLEMS and it
# returns 1; a copy it cannot read dies, naming <what> too.
spec_review_ticket_load() {
  local j copy file="$1/ticket-$2.fetched.md"
  [ -z "$(array_index TK_T "$2")" ] || return 0
  if [ ! -f "$1/ticket-$2.md" ]; then
    SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$3: ticket-$2.md not found in $1 - fetch each ticket a ticket item names into it"
    return 1
  fi
  [ -e "$file" ] || file="$1/ticket-$2.md"
  file_read copy "$file" || die "$3: could not read $file - nothing written"
  j="${#TK_T[@]}"
  TK_T[j]="$2"; TK_FETCHED[j]="$copy"; TK_TEXT[j]="$copy"
}

# The text items spec_review_ticket_item_offline has counted, which only
# check --tickets reports; it resets this before its loop.
SR_TICKET_ANCHOR_COUNT=0

# spec_review_ticket_item_offline <index> <body-var> <batch-body> <dir>: ticket
# item <index>'s checks that read no GitHub, the half apply and check share. A
# text item, counted into SR_TICKET_ANCHOR_COUNT, has its ticket loaded (see
# spec_review_ticket_load) and its anchor visited (see
# spec_review_edit_accepted): when ST_DISP holds it applied, its edit made in
# memory, to its ticket's copy in TK_TEXT, or a `## Ticket` edit to the body
# in <body-var>, anchored on <batch-body>, the body as the batch items left it;
# when declined, checked on its own against the ticket as fetched, or
# <batch-body>. An applied edge item is checked against its ticket's copy's
# `## Blocked by`. Each problem, naming its tickets.md line (a text item's
# `@@ anchor` line, else its header line), is appended to SR_PROBLEMS; each
# caller reacts to SR_PROBLEMS itself.
spec_review_ticket_item_offline() {
  local i="$1" body_var="$2" batch_body="$3" dir="$4" j at problem="" have="" accepted=""
  local what="ticket item ${ST_N[$1]}"
  at="tickets.md line ${ST_LINE[$i]}: "
  [ "${ST_DISP[$i]}" != applied ] || accepted=1
  case "${ST_KIND[$i]}" in
    ticket)
      SR_TICKET_ANCHOR_COUNT=$((SR_TICKET_ANCHOR_COUNT + 1))
      spec_review_ticket_load "$dir" "${ST_T[$i]}" "$at$what" || return 0
      at="tickets.md line ${ST_ANCHOR_LINE[$i]}: "
      j="$(array_index TK_T "${ST_T[$i]}")"
      spec_review_edit_accepted "$accepted" "TK_TEXT[$j]" "${TK_FETCHED[$j]}" \
        "$at$what (#${ST_T[$i]})" "${ST_ANCHOR[$i]}" "${ST_REPLACE[$i]}" || return 0 ;;
    section)
      SR_TICKET_ANCHOR_COUNT=$((SR_TICKET_ANCHOR_COUNT + 1))
      at="tickets.md line ${ST_ANCHOR_LINE[$i]}: "
      spec_review_edit_accepted "$accepted" "$body_var" "$batch_body" "$at$what (## Ticket)" \
        "${ST_ANCHOR[$i]}" "${ST_REPLACE[$i]}" || return 0 ;;
    block|unblock)
      [ -n "$accepted" ] || return 0
      spec_review_ticket_load "$dir" "${ST_T[$i]}" "$at$what" || return 0
      j="$(array_index TK_T "${ST_T[$i]}")"
      ! list_has "$(printf '%s\n' "${TK_FETCHED[$j]}" | blocked_by_section_numbers)" \
        "${ST_B[$i]}" || have=1
      if [ "${ST_KIND[$i]}" = block ]; then
        [ -z "$have" ] || problem="#${ST_T[$i]} is already blocked by #${ST_B[$i]}"
      else
        [ -n "$have" ] || problem="#${ST_T[$i]} is not blocked by #${ST_B[$i]}"
      fi
      [ -n "$problem" ] || return 0
      SR_PROBLEMS[${#SR_PROBLEMS[@]}]="$at$what: $problem" ;;
  esac
}

# spec_review_tickets_follow <body-var> <dir> <kind> <issue>: every ticket
# item checked, an accepted one applied in memory and a declined text item's
# anchor checked on its own against a scratch copy - see
# spec_review_ticket_item_offline - and the checks that read GitHub: every
# edge item's tickets in the breakdown, and a `## Ticket` item only on a
# collapsed one. Dies, before any write, on the first GitHub-reading check
# that fails, else, after the loop, on the first problem
# spec_review_ticket_item_offline collected.
spec_review_tickets_follow() {
  local body_var="$1" dir="$2" kind="$3" issue="$4" i t what batch_body subs="" listed
  [ -z "$ST_RETIRE" ] || return 0
  SR_PROBLEMS=()
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    case "${ST_KIND[$i]}" in
      block|unblock)
        listed="$(ticket_sub_issues "$issue")" || exit 1
        subs="$(printf '%s\n' "$listed" | cut -f1)"
        break ;;
    esac
  done
  batch_body="${!body_var}"
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    what="tickets.md line ${ST_LINE[$i]}: ticket item ${ST_N[$i]}"
    case "${ST_KIND[$i]}" in
      section)
        [ "$kind" = collapsed ] \
          || die "$what: a ## Ticket item, but #$issue's breakdown is $kind - nothing written" ;;
      block|unblock)
        for t in "${ST_T[$i]}" "${ST_B[$i]}"; do
          list_has "$subs" "$t" \
            || die "$what: #$t is not a ticket of #$issue's breakdown - nothing written"
        done ;;
    esac
    spec_review_ticket_item_offline "$i" "$body_var" "$batch_body" "$dir"
  done
  [ "${#SR_PROBLEMS[@]}" -eq 0 ] || die "${SR_PROBLEMS[0]} - nothing written"
}

# spec_review_tickets_check <dir>: check --tickets - <dir>/tickets.md
# validated as apply --tickets would take the all answer, against the ticket
# copies and <dir>/spec.md, with nothing written but <dir>/view.md and no
# GitHub read. A grammar error stops at the first; every other problem is
# reported, one `orch: ` line each, then exit 1. A clean file prints its view
# on stdout - see spec_review_tickets_view - saves it to <dir>/view.md, and
# prints a one-line summary on stderr ending in spec_review_nudge. With
# @@ none-affected its stdout is a stub, not a view: any earlier view.md is
# removed, none written, and the summary names none.
spec_review_tickets_check() {
  local dir="$1" i __srtc_body
  [ -f "$dir/tickets.md" ] || die "tickets.md not found in $dir"
  [ -f "$dir/spec.md" ] || die "spec.md not found in $dir"
  spec_review_tickets_parse "$dir/tickets.md"
  spec_review_tickets_answer all
  file_read __srtc_body "$dir/spec.md" || die "could not read $dir/spec.md"
  local batch_body="$__srtc_body"
  SR_PROBLEMS=(); SR_TICKET_ANCHOR_COUNT=0; TK_T=(); TK_FETCHED=(); TK_TEXT=()
  for i in ${ST_N[@]+"${!ST_N[@]}"}; do
    spec_review_ticket_item_offline "$i" __srtc_body "$batch_body" "$dir"
  done
  spec_review_problems_exit
  if [ -n "$ST_NONE" ]; then
    { rm -f "$dir/view.md"; } 2>/dev/null \
      || die "could not remove $(spec_review_view_path "$dir")"
    spec_review_tickets_view
    note "tickets.md passes: no open ticket affected" >&2
  else
    spec_review_view_save "$dir" spec_review_tickets_view
    note "tickets.md passes: ${#ST_N[@]} items, $SR_TICKET_ANCHOR_COUNT anchors, each matching once, and the all answer applies cleanly$(spec_review_nudge "$dir")" >&2
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

# spec_review_hold <dir>: the end of an autopilot round's first run, when the
# batch held fundamental items back - every other item is applied and the body
# published, and no changelog is posted yet. Writes <dir>/fundamental.md, the
# held-back items' blocks in the batch grammar behind the batch's `@@ lens`
# lines: the round's save point, which spec round reports as waiting and the
# resumed apply reads as its cue. Then clears applied.log, whose body write
# is no failure the resumed run must refuse, and makes spec.fetched.md the
# body as published, the base the resumed run's edits anchor in.
spec_review_hold() {
  local dir="$1" held=" " i
  for i in ${SR_IT_FUND[@]+"${!SR_IT_FUND[@]}"}; do held="$held${SR_IT_N[$i]} "; done
  { {
    grep '^@@ lens ' "$dir/batch.md" || true
    awk -v held="$held" '
      /^@@ item / { keep = index(held, " " $3 " ") > 0 }
      keep { print }' "$dir/batch.md"
  } >"$dir/$SPEC_ROUND_FUNDAMENTAL"; } 2>/dev/null \
    || die "could not write $dir/$SPEC_ROUND_FUNDAMENTAL - every GitHub write landed: $(spec_review_landed "$dir")"
  cp "$dir/spec.md" "$dir/spec.fetched.md" 2>/dev/null \
    || die "could not copy spec.md to $dir/spec.fetched.md - the fundamental items are held in $dir/$SPEC_ROUND_FUNDAMENTAL; every GitHub write landed: $(spec_review_landed "$dir")"
  rm -f "$dir/applied.log" 2>/dev/null \
    || die "could not clear $dir/applied.log - the fundamental items are held in $dir/$SPEC_ROUND_FUNDAMENTAL; every GitHub write landed: $(spec_review_landed "$dir")"
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
  local ticket_answer="" ticket_reasons="" opt_like
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
      *)
        # An override answer may begin with -, as -4: before <dir> any
        # leading dash makes an unknown option, after it only a double one -
        # one dash is stripped first, so a single dash starts the answer.
        opt_like="${1#-}"
        [ -n "$dir" ] || opt_like="$1"
        case "$opt_like" in -*) die "unknown option: $1 ($usage)" ;; esac
        if [ -z "$dir" ]; then
          dir="$1"
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
  # An autopilot round's two runs (see spec_review_hold): the first holds the
  # fundamental items back, the run after the reply, finding fundamental.md,
  # applies only those.
  SR_FMODE=""
  if autopilot_active; then
    if [ -f "$dir/$SPEC_ROUND_FUNDAMENTAL" ]; then SR_FMODE=resume; else SR_FMODE=hold; fi
  fi
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
    flow_active \
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
  # Every anchor checked against the fetched copy, and every accepted one
  # applied to it; the first problem refuses the batch.
  spec_review_validate "$dir" "$dir/spec.fetched.md" "$answer"
  [ "${#SR_PROBLEMS[@]}" -eq 0 ] || die "${SR_PROBLEMS[0]} - nothing applied, nothing written"
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

  local held_any=""
  [ "$SR_FMODE" != hold ] || [ "${#SR_IT_FUND[@]}" -eq 0 ] || held_any=1
  local log=""
  if [ -z "$held_any" ]; then
    log="$(spec_review_changelog "$round" "$unattended" "$tickets" "$hosts")"
    spec_review_local_write "$dir/changelog.md" "$log"$'\n'
  fi

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
  if [ -n "$held_any" ]; then
    spec_review_hold "$dir"
    return 0
  fi
  spec_review_write "$dir" "the changelog comment on issue #$issue" "${comment[@]}" "$dir/changelog.md"
  # The settled file, last: a pause or a failed write before this point
  # appends nothing, so a rerun never appends a changelog twice.
  { printf '%s\n' "$log" >>"$dir/settled.md"; } 2>/dev/null \
    || die "could not append the changelog to $dir/settled.md - every GitHub write landed: $(spec_review_landed "$dir")"
  if [ "$SR_FMODE" = resume ]; then
    rm -f "$dir/$SPEC_ROUND_FUNDAMENTAL" 2>/dev/null \
      && [ ! -e "$dir/$SPEC_ROUND_FUNDAMENTAL" ] \
      || die "could not remove $dir/$SPEC_ROUND_FUNDAMENTAL - every GitHub write landed and settled.md is appended: $(spec_review_landed "$dir")"
  fi
  # The round's completion, the very last step: spec round reads it to tell
  # a resumed flow which round runs next, so it exists only once every write
  # above has landed.
  { : >"$dir/$SPEC_ROUND_COMPLETE"; } 2>/dev/null \
    || die "could not write $dir/$SPEC_ROUND_COMPLETE - every GitHub write landed and settled.md is appended: $(spec_review_landed "$dir")"
}
