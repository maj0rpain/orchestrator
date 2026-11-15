# shellcheck shell=bash
# audit.sh - orch.sh's audit command: audit begin, which makes an audit run's
# working directory (ADR-0064), audit report, which renders a run's ranked file
# and area files into one HTML page, and audit file, which files one audit
# finding as a GitHub issue, its body rendered from the finding file, its
# locations and the HEAD it was audited at, and parsed back before any write;
# and audit file --run, which files a run's picked findings from its ranked
# file, stamped with the commit audit begin recorded.
# Its tests: scripts/test/orch/audit.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# audit_body_tail <sha> <location>...: prints the body's tail - one
# **Location:** line per location in the order given, then the **Audited at:**
# line, each line followed by a blank line.
audit_body_tail() {
  local sha="$1" l
  shift
  for l in "$@"; do printf '%s\n\n' "**Location:** \`$l\`"; done
  printf '%s\n\n' "**Audited at:** $sha"
}

# audit_body_render <finding-file> <sha> <location>...: prints the issue body -
# the finding text, its trailing newlines stripped, a blank line, then
# audit_body_tail.
audit_body_render() {
  local file="$1" sha="$2"
  shift 2
  printf '%s\n\n' "$(cat "$file")"
  audit_body_tail "$sha" "$@"
}

# audit_body_parse <body> <locations_var> <sha_var>: reads every **Location:**
# line's backticked location, newline-joined in order, into the first variable,
# and every **Audited at:** line's text, newline-joined, into the second. A
# line carrying no backticked location contributes an empty entry, so it
# shows up as a mismatch.
audit_body_parse() {
  local __abp_line __abp_locs="" __abp_shas="" __abp_re='^\*\*Location:\*\* `([^`]*)`$'
  while IFS= read -r __abp_line; do
    case "$__abp_line" in
      '**Location:**'*)
        if [[ $__abp_line =~ $__abp_re ]]; then
          __abp_locs+="${BASH_REMATCH[1]}"$'\n'
        else
          __abp_locs+=$'\n'
        fi
        ;;
      '**Audited at:**'*)
        __abp_shas+="$(trim "${__abp_line#'**Audited at:**'}")"$'\n'
        ;;
    esac
  done <<<"$1"
  printf -v "$2" '%s' "$__abp_locs"
  printf -v "$3" '%s' "$__abp_shas"
}

# AUDIT_KINDS: the kinds of audit `audit begin` takes, one per audit skill.
AUDIT_KINDS="code docs tests"

# audit_usage: the usage text naming every form of the audit command, one per
# line. The one-finding form's own refusals print audit_file_usage alone.
audit_usage() {
  local kinds="${AUDIT_KINDS// /|}"
  printf 'usage: orch.sh audit begin <%s>\n   or: orch.sh audit report <dir> <out.html>\n   or: orch.sh audit file --run <dir> <numbers>\n   or: %s' \
    "$kinds" "$(audit_file_usage | sed 's/^usage: //')"
}

# audit_begin <kind>: makes .orchestrator/audit/<kind>-<stamp>/ in the current
# checkout, git-excluded, records the kind and the HEAD commit in its `record`
# file, and prints its absolute path and nothing else. Every check comes before
# the directory is made; the directory is never reused; a write failing after
# it is made removes it before dying. Reads and writes no flow state.
audit_begin() {
  [ $# -eq 1 ] || die "$(audit_usage)"
  local kind="$1" sha dir
  word_listed "$AUDIT_KINDS" "$kind" || die "$(audit_usage)"
  sha="$(git rev-parse --verify HEAD 2>/dev/null)" || die "cannot read the HEAD commit"
  dir="$ORCH/audit/$kind-$(dir_stamp)"
  [ ! -e "$dir" ] || die "the audit run directory already exists: $dir"
  mkdir -p "$ORCH/audit" 2>/dev/null && mkdir "$dir" 2>/dev/null \
    || die "cannot make the audit run directory $dir"
  # A failed write below dies inside exclude_line or here; the trap removes
  # the half-made directory either way.
  # shellcheck disable=SC2064 # the directory is fixed now
  trap "rm -rf $(printf '%q' "$dir")" EXIT
  exclude_orch_dirs
  printf 'kind %s\ncommit %s\n' "$kind" "$sha" >"$dir/record" 2>/dev/null \
    || die "cannot write the audit run record in $dir"
  trap - EXIT
  note "$dir"
}

# The ranked file and its reader (ADR-0064). audit_ranked_read is the one
# reader: it checks that a run directory's ranked file holds together, and
# leaves the run in the AUDIT_* globals for its two callers: audit report, to
# render, and audit file --run, to file from. It dies, with an orch: message
# naming what is wrong and its line, before anything is written.
#
# A resolved finding i is in AUDIT_TITLE[i], AUDIT_CATEGORY[i], AUDIT_LOCS[i]
# (newline-joined), AUDIT_LINKS[i] (the finding numbers it overlaps, on either
# side, space-separated and ascending) and AUDIT_FIELDS[i]: its fields in
# resolved order, each a label, AUDIT_US and its value, ended by AUDIT_RS.
AUDIT_US=$'\x1f'
AUDIT_RS=$'\x1e'
AUDIT_FENCE='```'

# audit_fields_split <text> <first line>: splits a block's text into its
# fields, in AUDIT_FL (labels), AUDIT_FV (values) and AUDIT_FN (line numbers,
# the block's first line being <first line>). A field opens on a line outside a
# fenced block that starts with a label - a capital letter, then letters,
# spaces or / - and a colon, and runs to the next field. Text before the
# first field is dropped.
audit_fields_split() {
  local line fence="" cur=-1 ln="$2" i
  local re='^([A-Z][A-Za-z /]*):[[:space:]]*(.*)$'
  AUDIT_FL=() AUDIT_FV=() AUDIT_FN=()
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ $line == "$AUDIT_FENCE"* ]]; then
      if [ -n "$fence" ]; then fence=""; else fence=1; fi
      if [ "$cur" -ge 0 ]; then AUDIT_FV[cur]+=$'\n'"$line"; fi
    elif [ -z "$fence" ] && [[ $line =~ $re ]]; then
      cur=$((cur + 1))
      AUDIT_FL[cur]="${BASH_REMATCH[1]}"
      AUDIT_FV[cur]="${BASH_REMATCH[2]}"
      AUDIT_FN[cur]="$ln"
      ln=$((ln + 1))
      continue
    elif [ "$cur" -ge 0 ]; then
      AUDIT_FV[cur]+=$'\n'"$line"
    fi
    ln=$((ln + 1))
  done <<<"$1"
  for i in "${!AUDIT_FV[@]}"; do trim_split "${AUDIT_FV[i]}" "AUDIT_FV[$i]"; done
}

# audit_area_load <dir> <name>: reads <dir>/<name>.md into AUDIT_AB, each
# `@@ finding <k>` block's text under the key <name>:<k>. Returns 1 when there
# is no such file.
audit_area_load() {
  local file="$1/$2.md" line k="" ln=0
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    if [[ $line =~ ^@@[[:space:]]+finding[[:space:]]+([0-9]+)[[:space:]]*$ ]]; then
      k="${BASH_REMATCH[1]}"
      AUDIT_AB["$2:$k"]=""
      AUDIT_ABL["$2:$k"]=$((ln + 1))
    elif [[ $line == '@@'* ]]; then
      k=""
    elif [ -n "$k" ]; then
      AUDIT_AB["$2:$k"]+="$line"$'\n'
    fi
  done <"$file"
}

# audit_list_split <var> <text>: <text>'s comma-separated entries, trimmed,
# empty ones dropped, one per line, into <var>.
audit_list_split() {
  local item out="" rest="$2,"
  while [ -n "$rest" ]; do
    trim_split "${rest%%,*}" item
    rest="${rest#*,}"
    [ -z "$item" ] || out+="$item"$'\n'
  done
  printf -v "$1" '%s' "$out"
}

# audit_ranked_sections <file>: the ranked file's lines in AUDIT_SK (kind),
# AUDIT_SA (the text after the kind), AUDIT_ST (the block's text) and AUDIT_SL
# (the line), one entry per `@@` line.
audit_ranked_sections() {
  local line ln=0 idx=-1 kind arg
  local re='^@@[[:space:]]+([a-z]+)([[:space:]]+(.*))?$'
  AUDIT_SK=() AUDIT_SA=() AUDIT_ST=() AUDIT_SL=()
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    if [[ $line == '@@'* ]]; then
      [[ $line =~ $re ]] || die "ranked.md line $ln: not a ranked-file line: $line"
      kind="${BASH_REMATCH[1]}"
      trim_split "${BASH_REMATCH[3]}" arg
      case "$kind" in
        scope | areas | note | top | finding | none) ;;
        *) die "ranked.md line $ln: unknown line @@ $kind" ;;
      esac
      idx=$((idx + 1))
      AUDIT_SK[idx]="$kind" AUDIT_SA[idx]="$arg" AUDIT_ST[idx]="" AUDIT_SL[idx]="$ln"
    elif [ "$idx" -ge 0 ]; then
      AUDIT_ST[idx]+="$line"$'\n'
    elif [[ -n ${line//[[:space:]]/} ]]; then
      die "ranked.md line $ln: text before the first @@ line"
    fi
  done <"$1"
}

# audit_finding_resolve <n> <body> <first line>: resolves ranked finding <n>
# against its From: sources into AUDIT_FIELDS[n]: the first source's fields in
# its order, each field the block restates replacing the source's in place, a
# label the source lacks added after; the locations of every source, in From:
# order and without repeats, unless the block restates Location:.
audit_finding_resolve() {
  local n="$1" i k label value from="" from_ln src first="" locs="" restated="" sources area kn
  local locline loc lw lk
  local rl=() rv=() rw=()
  audit_fields_split "$2" "$3"
  for i in "${!AUDIT_FL[@]}"; do
    if [ "${AUDIT_FL[i]}" = From ]; then
      [ -z "$from" ] || die "ranked.md line ${AUDIT_FN[i]}: finding $n has two From: fields"
      from="${AUDIT_FV[i]}" from_ln="${AUDIT_FN[i]}"
      [ -n "$from" ] || die "ranked.md line $from_ln: From: names no source"
    else
      rl+=("${AUDIT_FL[i]}") rv+=("${AUDIT_FV[i]}") rw+=("ranked.md line ${AUDIT_FN[i]}")
      [ "${AUDIT_FL[i]}" != Location ] || restated=1
    fi
  done
  local bl=() bv=() bw=() sl
  if [ -n "$from" ]; then
    audit_list_split sources "$from"
    while IFS= read -r src; do
      [ -n "$src" ] || continue
      [[ $src =~ ^(area-[0-9]+):([0-9]+)$ ]] \
        || die "ranked.md line $from_ln: From: $src is not <area file>:<k>, an area-<n> file and a block number"
      area="${BASH_REMATCH[1]}" kn="${BASH_REMATCH[2]}"
      [ -n "${AUDIT_AREA_SEEN[$area]:-}" ] || {
        AUDIT_AREA_SEEN["$area"]=1
        audit_area_load "$AUDIT_DIR" "$area" || AUDIT_AREA_SEEN["$area"]=missing
      }
      [ "${AUDIT_AREA_SEEN[$area]}" != missing ] \
        || die "ranked.md line $from_ln: From: $src names $area.md, which is not in the run directory"
      [ "${AUDIT_AB[$src]+set}" = set ] \
        || die "ranked.md line $from_ln: From: $src names finding $kn, which $area.md lacks"
      audit_fields_split "${AUDIT_AB[$src]}" "${AUDIT_ABL[$src]}"
      if [ -z "$first" ]; then
        first=1
        bl=("${AUDIT_FL[@]}") bv=("${AUDIT_FV[@]}")
        for i in "${!AUDIT_FL[@]}"; do bw[i]="$area.md line ${AUDIT_FN[i]}"; done
      fi
      for i in "${!AUDIT_FL[@]}"; do
        [ "${AUDIT_FL[i]}" != Location ] || locs+="${AUDIT_FV[i]},"
        [ "${AUDIT_FL[i]}" = Location ] && [ -z "$restated" ] || continue
        audit_list_split lw "${AUDIT_FV[i]}"
        while IFS= read -r loc; do
          [ -n "$loc" ] || continue
          lk="$n:loc:$loc"
          [ -n "${AUDIT_FWHERE[$lk]:-}" ] || AUDIT_FWHERE["$lk"]="$area.md line ${AUDIT_FN[i]}"
        done <<<"$lw"
      done
    done <<<"$sources"
  fi
  for i in "${!rl[@]}"; do
    label="${rl[i]}" value="${rv[i]}"
    k="$(array_index bl "$label")"
    if [ -n "$k" ]; then
      bv[k]="$value" bw[k]="${rw[i]}"
    else
      bl+=("$label") bv+=("$value") bw+=("${rw[i]}")
    fi
  done
  if [ -z "$restated" ] && [ -n "$locs" ]; then
    audit_list_split sl "$locs"
    locline=""
    while IFS= read -r loc; do
      [ -n "$loc" ] || continue
      list_has "$locline" "$loc" || locline+="${locline:+$'\n'}$loc"
    done <<<"$sl"
    locline="${locline//$'\n'/, }"
    k="$(array_index bl Location)"
    if [ -n "$k" ]; then bv[k]="$locline"; else bl+=(Location) bv+=("$locline") bw+=("ranked.md line $from_ln"); fi
  fi
  AUDIT_FIELDS[n]=""
  for i in "${!bl[@]}"; do
    AUDIT_FIELDS[n]+="${bl[i]}$AUDIT_US${bv[i]}$AUDIT_RS"
    AUDIT_FWHERE["$n:${bl[i]}"]="${bw[i]}"
  done
}

# audit_field_get <n> <label> <var>: resolved finding <n>'s field <label> into
# <var>; returns 1, setting nothing, when it has none.
audit_field_get() {
  local rec rest="${AUDIT_FIELDS[$1]}"
  while [ -n "$rest" ]; do
    rec="${rest%%"$AUDIT_RS"*}"
    rest="${rest#*"$AUDIT_RS"}"
    if [ "${rec%%"$AUDIT_US"*}" = "$2" ]; then
      printf -v "$3" '%s' "${rec#*"$AUDIT_US"}"
      return 0
    fi
  done
  return 1
}

# audit_where <n> <label> <block line> <var>: where resolved finding <n>'s field
# <label> was written, as `<file> line <k>`, into <var>: the ranked file or the
# area file the value came from. Falls back to the block's own line.
audit_where() {
  local w="${AUDIT_FWHERE["$1:$2"]:-}"
  [ -n "$w" ] || w="ranked.md line $3"
  printf -v "$4" '%s' "$w"
}

# audit_ref_find <text> <phrase_var> <line_var>: looks in <text>, outside
# inline backtick spans and fenced blocks and without regard to letter case, for
# a reference to a report's numbering: finding, findings, candidate or
# candidates followed by a number (an optional # before it), or "this report".
# A paragraph's lines read as one, as the report and the issue body show them,
# so a reference split by a line wrap is found too. Returns 0 with the phrase
# as written in <phrase_var> and the 1-based line it starts on in <line_var>;
# returns 1 when there is none. "the report" is not one.
audit_ref_find() {
  local line low rest ln=0 fence="" pre bt='`' para="" pos i at span pad
  local hash="#" re
  local -a starts=() lns=()
  re="(^|[^a-z0-9_])((findings?|candidates?)[[:space:]]+${hash}?[0-9]+|this[[:space:]]+report)(\$|[^a-z0-9_])"
  while IFS= read -r line || [ -n "$line" ]; do
    ln=$((ln + 1))
    if [[ $line == "$AUDIT_FENCE"* ]] || [[ -z ${line//[[:space:]]/} ]]; then
      if [ -n "$para" ]; then
        # an inline span, which may wrap, is blanked to as many spaces
        rest="$para" low=""
        while [[ $rest == *"$bt"*"$bt"* ]]; do
          low+="${rest%%"$bt"*}"
          rest="${rest#*"$bt"}"
          span="${rest%%"$bt"*}"
          printf -v pad '%*s' $((${#span} + 2)) ''
          low+="$pad"
          rest="${rest#*"$bt"}"
        done
        low="${low}${rest}"
        low="${low,,}"
        if [[ $low =~ $re ]]; then
          pre="${low%%"${BASH_REMATCH[0]}"*}"
          pos=$((${#pre} + ${#BASH_REMATCH[1]}))
          printf -v "$2" '%s' "${para:pos:${#BASH_REMATCH[2]}}"
          for i in "${!starts[@]}"; do
            [ "${starts[i]}" -le "$pos" ] || break
            at="${lns[i]}"
          done
          printf -v "$3" '%s' "$at"
          return 0
        fi
        para="" starts=() lns=()
      fi
      if [[ $line == "$AUDIT_FENCE"* ]]; then
        if [ -n "$fence" ]; then fence=""; else fence=1; fi
      fi
      continue
    fi
    [ -z "$fence" ] || continue
    if [ -n "$para" ]; then starts+=("$((${#para} + 1))"); else starts+=(0); fi
    lns+=("$ln")
    para+="${para:+ }$line"
  done <<<"$1"$'\n'
  return 1
}

# audit_ranked_read <dir>: reads and checks the run directory <dir>: its
# record, its ranked file, and every area file a From: names. Sets AUDIT_DIR,
# AUDIT_KIND, AUDIT_COMMIT, AUDIT_SCOPE, AUDIT_AREAS, AUDIT_NONE, AUDIT_TOP,
# AUDIT_TOP_TEXT, AUDIT_NOTE_HEAD, AUDIT_NOTE_TEXT, AUDIT_COUNT and the
# per-finding arrays above. Dies on the first thing that does not hold.
audit_ranked_read() {
  local dir="$1" key val arg i n expect=0 scopes=0 areas=0 tops=0 nones=0 ln body
  local over overs cat locfield locs loc title top_ln=0 other at
  declare -gA AUDIT_AB AUDIT_ABL AUDIT_AREA_SEEN AUDIT_FWHERE
  AUDIT_AB=() AUDIT_ABL=() AUDIT_AREA_SEEN=() AUDIT_FWHERE=()
  AUDIT_DIR="$dir" AUDIT_KIND="" AUDIT_COMMIT="" AUDIT_SCOPE="" AUDIT_AREAS="" AUDIT_NONE=""
  AUDIT_TOP="" AUDIT_TOP_TEXT="" AUDIT_NOTE_HEAD=() AUDIT_NOTE_TEXT=() AUDIT_COUNT=0
  AUDIT_TITLE=() AUDIT_CATEGORY=() AUDIT_LOCS=() AUDIT_LINKS=() AUDIT_FIELDS=()
  orch_load filed-finding

  [ -f "$dir/record" ] || die "$dir holds no audit run record: make a run with orch.sh audit begin"
  while read -r key val; do
    case "$key" in
      kind) AUDIT_KIND="$val" ;;
      commit) AUDIT_COMMIT="$val" ;;
    esac
  done <"$dir/record"
  [ -n "$AUDIT_KIND" ] && [ -n "$AUDIT_COMMIT" ] || die "$dir/record names no kind or no commit"
  [ -f "$dir/ranked.md" ] || die "$dir holds no ranked.md"

  audit_ranked_sections "$dir/ranked.md"
  local -a bodies=() starts=()
  for i in "${!AUDIT_SK[@]}"; do
    ln="${AUDIT_SL[i]}" arg="${AUDIT_SA[i]}"
    trim_split "${AUDIT_ST[i]}" body
    case "${AUDIT_SK[i]}" in
      scope)
        scopes=$((scopes + 1))
        [ "$scopes" -eq 1 ] || die "ranked.md line $ln: a second @@ scope"
        [ -n "$arg" ] || die "ranked.md line $ln: @@ scope names no scope"
        AUDIT_SCOPE="$arg" ;;
      areas)
        areas=$((areas + 1))
        [ "$areas" -eq 1 ] || die "ranked.md line $ln: a second @@ areas"
        [[ $arg =~ ^[0-9]+$ ]] || die "ranked.md line $ln: @@ areas takes a count, not '$arg'"
        AUDIT_AREAS="$arg" ;;
      note)
        [ -n "$arg" ] || die "ranked.md line $ln: @@ note names no heading"
        AUDIT_NOTE_HEAD+=("$arg") AUDIT_NOTE_TEXT+=("$body") ;;
      top)
        tops=$((tops + 1))
        [ "$tops" -eq 1 ] || die "ranked.md line $ln: a second @@ top"
        [[ $arg =~ ^[0-9]+$ ]] || die "ranked.md line $ln: @@ top takes a finding number, not '$arg'"
        AUDIT_TOP="$arg" AUDIT_TOP_TEXT="$body" top_ln="$ln" ;;
      none)
        nones=$((nones + 1))
        [ "$nones" -eq 1 ] || die "ranked.md line $ln: a second @@ none"
        AUDIT_NONE=1 ;;
      finding)
        expect=$((expect + 1))
        [[ $arg =~ ^[0-9]+$ ]] && [ "$arg" -eq "$expect" ] \
          || die "ranked.md line $ln: expected @@ finding $expect, found '$arg': findings are numbered from 1 in order"
        bodies[expect]="${AUDIT_ST[i]}" starts[expect]=$((ln + 1)) ;;
    esac
    case "${AUDIT_SK[i]}" in
      scope | areas | none)
        [ -z "$body" ] || die "ranked.md line $ln: text after @@ ${AUDIT_SK[i]}" ;;
    esac
  done
  AUDIT_COUNT="$expect"
  [ "$scopes" -eq 1 ] || die "ranked.md has no @@ scope line"
  [ "$areas" -eq 1 ] || die "ranked.md has no @@ areas line"
  [ $((tops + nones)) -eq 1 ] || die "ranked.md needs exactly one of @@ top and @@ none"
  if [ -n "$AUDIT_NONE" ]; then
    [ "$AUDIT_COUNT" -eq 0 ] || die "ranked.md has @@ none and findings"
    return 0
  fi
  [ "$AUDIT_COUNT" -ge 1 ] || die "ranked.md has @@ top and no findings"
  [ "$AUDIT_TOP" -ge 1 ] && [ "$AUDIT_TOP" -le "$AUDIT_COUNT" ] \
    || die "ranked.md line $top_ln: @@ top names finding $AUDIT_TOP, which the file lacks"

  for ((n = 1; n <= AUDIT_COUNT; n++)); do
    ln=$((starts[n] - 1))
    audit_finding_resolve "$n" "${bodies[n]}" "${starts[n]}"
    audit_field_get "$n" Title title || die "ranked.md line $ln: finding $n has no Title:"
    audit_where "$n" Title "$ln" at
    [ -n "$title" ] && [[ $title != *$'\n'* ]] || die "$at: finding $n's Title: is not one line"
    audit_field_get "$n" Category cat || die "ranked.md line $ln: finding $n has no Category:"
    audit_where "$n" Category "$ln" at
    is_filed_category "$cat" || die "$at: finding $n's Category: '$cat' is not one of $FILED_CATEGORIES"
    audit_field_get "$n" Location locfield || die "ranked.md line $ln: finding $n has no Location:"
    audit_where "$n" Location "$ln" at
    audit_list_split locs "$locfield"
    [ -n "$locs" ] || die "$at: finding $n has no location"
    while IFS= read -r loc; do
      [ -n "$loc" ] || continue
      finding_location_ok "$loc" \
        || die "${AUDIT_FWHERE["$n:loc:$loc"]:-$at}: finding $n's location '$loc' is not <file>:<line> or <file>:<start>-<end>"
    done <<<"$locs"
    local frest="${AUDIT_FIELDS[n]}" frec flabel fvalue fphrase fline
    while [ -n "$frest" ]; do
      frec="${frest%%"$AUDIT_RS"*}"
      frest="${frest#*"$AUDIT_RS"}"
      flabel="${frec%%"$AUDIT_US"*}" fvalue="${frec#*"$AUDIT_US"}"
      [ "$flabel" != From ] && [ "$flabel" != Overlaps ] || continue
      audit_where "$n" "$flabel" "$ln" at
      ! audit_ref_find "$fvalue" fphrase fline \
        || die "$at: finding $n's $flabel: says '$fphrase' (line $fline of the field): a finding must read alone, so name no other finding by number and never this report; restate the field in the ranked block"
    done
    AUDIT_TITLE[n]="$title" AUDIT_CATEGORY[n]="$cat" AUDIT_LOCS[n]="${locs%$'\n'}"
    if audit_field_get "$n" Overlaps over; then
      audit_where "$n" Overlaps "$ln" at
      audit_list_split overs "$over"
      while IFS= read -r other; do
        [ -n "$other" ] || continue
        [[ $other =~ ^[0-9]+$ ]] && [ "$other" -ge 1 ] && [ "$other" -le "$AUDIT_COUNT" ] && [ "$other" -ne "$n" ] \
          || die "$at: finding $n overlaps '$other', which is not another finding of the file"
        AUDIT_LINKS[n]+=" $other"
        AUDIT_LINKS[other]+=" $n"
      done <<<"$overs"
    fi
  done
  for ((n = 1; n <= AUDIT_COUNT; n++)); do
    audit_nums_union "AUDIT_LINKS[$n]" "${AUDIT_LINKS[n]:-}" ""
  done
}

# audit_esc <var> <text>: <text> with & < > " and ' made HTML-safe, into <var>.
# The replacements are quoted so a bash 5.2 & in them stays a letter.
audit_esc() {
  local s="$2" amp='&' lt='<' gt='>' dq='"' sq="'"
  s="${s//"$amp"/"&amp;"}"
  s="${s//"$lt"/"&lt;"}"
  s="${s//"$gt"/"&gt;"}"
  s="${s//"$dq"/"&quot;"}"
  s="${s//"$sq"/"&#39;"}"
  printf -v "$1" '%s' "$s"
}

# audit_inline <text>: prints <text> escaped, each inline backtick span (a
# backtick, text, a backtick) as <code>.
audit_inline() {
  local rest="$1" pre span e out=""
  while [[ $rest == *'`'*'`'* ]]; do
    pre="${rest%%'`'*}"
    rest="${rest#*'`'}"
    span="${rest%%'`'*}"
    rest="${rest#*'`'}"
    audit_esc e "$pre"
    out+="$e"
    audit_esc e "$span"
    out+="<code>$e</code>"
  done
  audit_esc e "$rest"
  printf '%s' "$out$e"
}

# audit_md_render <text>: prints <text> as HTML, in the one small markup set:
# every character escaped; a blank line ends a paragraph; a fenced block is
# preformatted code, a fenced block tagged mermaid a Mermaid diagram; an inline
# backtick span is code.
audit_md_render() {
  local line fence="" tag="" para="" code="" code_n=0 e
  while IFS= read -r line || [ -n "$line" ]; do
    if [ -n "$fence" ]; then
      if [[ $line == "$AUDIT_FENCE"* ]]; then
        audit_esc e "$code"
        if [ "$tag" = mermaid ]; then
          printf '<pre class="mermaid">%s</pre>\n' "$e"
        else
          printf '<pre class="overflow-x-auto bg-gray-100 p-3 rounded text-sm"><code>%s</code></pre>\n' "$e"
        fi
        fence="" code="" code_n=0
      else
        if [ "$code_n" -gt 0 ]; then code+=$'\n'; fi
        code+="$line"
        code_n=$((code_n + 1))
      fi
    elif [[ $line == "$AUDIT_FENCE"* ]]; then
      [ -z "$para" ] || { printf '<p class="my-2">%s</p>\n' "$(audit_inline "$para")"; para=""; }
      trim_split "${line#"$AUDIT_FENCE"}" tag
      fence=1
    elif [[ -z ${line//[[:space:]]/} ]]; then
      [ -z "$para" ] || { printf '<p class="my-2">%s</p>\n' "$(audit_inline "$para")"; para=""; }
    else
      if [ -n "$para" ]; then para+=$'\n'; fi
      para+="$line"
    fi
  done <<<"$1"
  [ -z "$para" ] || printf '<p class="my-2">%s</p>\n' "$(audit_inline "$para")"
  if [ -n "$fence" ]; then
    audit_esc e "$code"
    printf '<pre class="overflow-x-auto bg-gray-100 p-3 rounded text-sm"><code>%s</code></pre>\n' "$e"
  fi
}

# audit_page_render: prints the report page for the run audit_ranked_read left
# in the AUDIT_* globals. It holds no clock time and nothing random.
audit_page_render() {
  local e n i j rec label value rest loc
  audit_esc e "$AUDIT_KIND"
  printf '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
  printf '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
  printf '<title>Audit report: %s</title>\n' "$e"
  printf '<script src="https://cdn.tailwindcss.com"></script>\n'
  printf '<script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>\n'
  printf '<script>mermaid.initialize({ startOnLoad: true });</script>\n'
  printf '</head>\n<body class="bg-white text-gray-900 max-w-4xl mx-auto p-6">\n'
  printf '<header class="mb-6">\n<h1 class="text-2xl font-bold">Audit report: %s</h1>\n' "$e"
  e="$(audit_inline "$AUDIT_SCOPE")"
  printf '<dl class="mt-3 grid grid-cols-4 gap-2">\n<dt class="font-semibold">Scope</dt><dd class="col-span-3">%s</dd>\n' "$e"
  printf '<dt class="font-semibold">Areas</dt><dd class="col-span-3">%s</dd>\n' "$AUDIT_AREAS"
  audit_esc e "$AUDIT_COMMIT"
  printf '<dt class="font-semibold">Commit</dt><dd class="col-span-3"><code>%s</code></dd>\n</dl>\n' "$e"
  for i in "${!AUDIT_NOTE_HEAD[@]}"; do
    e="$(audit_inline "${AUDIT_NOTE_HEAD[i]}")"
    printf '<section class="mt-4">\n<h2 class="text-lg font-semibold">%s</h2>\n' "$e"
    audit_md_render "${AUDIT_NOTE_TEXT[i]}"
    printf '</section>\n'
  done
  printf '</header>\n<main>\n'
  if [ -n "$AUDIT_NONE" ]; then
    printf '<p class="text-lg">The audit found nothing: no findings were kept.</p>\n'
  else
    e="$(audit_inline "${AUDIT_TITLE[AUDIT_TOP]}")"
    printf '<section id="top" class="mb-8 p-4 border-l-4 border-blue-500 bg-blue-50">\n'
    printf '<h2 class="text-lg font-semibold">Top recommendation</h2>\n'
    printf '<p class="my-2"><a class="text-blue-700 underline" href="#finding-%s">Finding %s: %s</a></p>\n' \
      "$AUDIT_TOP" "$AUDIT_TOP" "$e"
    audit_md_render "$AUDIT_TOP_TEXT"
    printf '</section>\n'
    for ((n = 1; n <= AUDIT_COUNT; n++)); do
      e="$(audit_inline "${AUDIT_TITLE[n]}")"
      printf '<article id="finding-%s" class="mb-8">\n' "$n"
      printf '<h2 class="text-xl font-semibold">%s. %s</h2>\n' "$n" "$e"
      audit_esc e "${AUDIT_CATEGORY[n]}"
      printf '<p class="my-1"><span class="inline-block px-2 py-0.5 rounded bg-gray-200 text-sm">%s</span></p>\n' "$e"
      rest="${AUDIT_FIELDS[n]}"
      while [ -n "$rest" ]; do
        rec="${rest%%"$AUDIT_RS"*}"
        rest="${rest#*"$AUDIT_RS"}"
        label="${rec%%"$AUDIT_US"*}" value="${rec#*"$AUDIT_US"}"
        case "$label" in From | Title | Category | Overlaps) continue ;; esac
        audit_esc e "$label"
        printf '<h3 class="mt-3 font-semibold">%s</h3>\n' "$e"
        if [ "$label" = Location ]; then
          printf '<ul class="list-disc ml-6">\n'
          while IFS= read -r loc; do
            audit_esc e "$loc"
            printf '<li><code>%s</code></li>\n' "$e"
          done <<<"${AUDIT_LOCS[n]}"
          printf '</ul>\n'
        else
          audit_md_render "$value"
        fi
      done
      if [ -n "${AUDIT_LINKS[n]// /}" ]; then
        printf '<h3 class="mt-3 font-semibold">Overlaps</h3>\n<ul class="list-disc ml-6">\n'
        for ((j = 1; j <= AUDIT_COUNT; j++)); do
          word_listed "${AUDIT_LINKS[n]}" "$j" || continue
          e="$(audit_inline "${AUDIT_TITLE[j]}")"
          printf '<li><a class="text-blue-700 underline" href="#finding-%s">Finding %s: %s</a></li>\n' "$j" "$j" "$e"
        done
        printf '</ul>\n'
      fi
      printf '</article>\n'
    done
  fi
  printf '</main>\n</body>\n</html>\n'
}

# audit_report <dir> <out.html>: renders the audit run <dir> into <out.html>
# and prints its path. Every check of the ranked file comes before anything is
# written; the page goes to a temporary file beside <out.html> and is moved into
# place, so a refusal or a failed write leaves an earlier report as it was.
audit_report() {
  [ $# -eq 2 ] || die "$(audit_usage)"
  local dir="$1" out="$2" outdir page
  audit_ranked_read "$dir"
  case "$out" in
    */*) outdir="${out%/*}" ;;
    *) outdir="." ;;
  esac
  [ -d "$outdir" ] || die "the directory for the report does not exist: $outdir"
  [ ! -d "$out" ] || die "the report path is a directory: $out"
  page="$(audit_page_render)" || die "cannot write the report beside $out"
  file_write_atomic "$out" "$page"$'\n' 2>/dev/null || die "cannot write the report beside $out"
  note "$out"
}

# audit_file_usage: the usage line, its categories read from the Filed finding
# module's list. A function, not a variable: filed-finding.sh may not be loaded
# when audit.sh is, so a string built at source time could not read the list.
audit_file_usage() {
  orch_load filed-finding
  local cats="${FILED_CATEGORIES// /|}"
  printf 'usage: orch.sh audit file <title> --category <%s> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]\n' "$cats"
}

# audit_open_listing <var>: the open issues' numbers and titles, one
# tab-separated pair per line, into <var>; dies naming the failed read.
audit_open_listing() {
  local err
  gh_capture "$1" err adapter_issues_open_titles \
    || gh_die "list the open issues" "$err"
}

# audit_open_find <listing> <title> <var>: the number of the open issue in
# <listing> (audit_open_listing's) whose title is exactly <title>, into <var>;
# returns 1, setting nothing, when there is none.
audit_open_find() {
  local num name
  while IFS=$'\t' read -r num name; do
    [ -n "$num" ] || continue
    if [ "$name" = "$2" ]; then
      printf -v "$3" '%s' "$num"
      return 0
    fi
  done <<<"$1"
  return 1
}

# audit_triage_ready <var>: the repo's needs-triage label into <var>, made if
# it is missing.
audit_triage_ready() {
  triage_label_into "$1" needs-triage
  triage_label_ensure "${!1}"
}

# audit_file <title> --category <c> --finding-file <f> --location <loc>...:
# files one finding as a GitHub issue and prints its number. Every check - the
# title, the finding file, the category, the locations, a reference to a
# report's numbering in the title or the finding, HEAD's SHA and the round
# trip of the rendered body - comes before any GitHub read or write. An
# open issue with exactly the title files nothing: its number is printed, with
# the already-open line on stderr, and the exit is 0.
audit_file() {
  [ $# -ge 1 ] || die "$(audit_file_usage)"
  local title="$1" finding="" category="" locations=() i
  shift
  finding_flags_parse "$(audit_file_usage)" "--category --finding-file --location" "$@"
  for i in "${!FINDING_FLAGS[@]}"; do
    case "${FINDING_FLAGS[i]}" in
      --category)
        [ -z "$category" ] || die "$(audit_file_usage)"
        category="${FINDING_VALUES[i]}" ;;
      --finding-file)
        [ -z "$finding" ] || die "$(audit_file_usage)"
        finding="${FINDING_VALUES[i]}" ;;
      --location) locations+=("${FINDING_VALUES[i]}") ;;
    esac
  done
  [ -n "$finding" ] && [ -n "$category" ] && [ "${#locations[@]}" -gt 0 ] || die "$(audit_file_usage)"

  is_filed_category "$category" || die "$(audit_file_usage)"
  local loc sha body_file n existing existing_n triage
  finding_input_check "$title" "$finding"
  local refp refl
  ! audit_ref_find "$title" refp refl \
    || die "the title says '$refp': a finding must read alone, so name no other finding by number and never this report"
  ! audit_ref_find "$(cat "$finding")" refp refl \
    || die "$finding line $refl says '$refp': a finding must read alone, so name no other finding by number and never this report"
  for loc in "${locations[@]}"; do
    finding_location_check "$loc"
  done
  sha="$(git rev-parse --verify HEAD 2>/dev/null)" || die "cannot read the HEAD commit"

  finding_body_file_new body_file
  audit_body_render "$finding" "$sha" "${locations[@]}" >"$body_file"
  local got_locs got_shas want_locs
  audit_body_parse "$(cat "$body_file")" got_locs got_shas
  want_locs="$(printf '%s\n' "${locations[@]}")"$'\n'
  [ "$got_locs" = "$want_locs" ] \
    || die "the rendered body does not parse back: locations (given '${want_locs%$'\n'}', parsed '${got_locs%$'\n'}')"
  [ "$got_shas" = "$sha"$'\n' ] \
    || die "the rendered body does not parse back: audited at (given '$sha', parsed '${got_shas%$'\n'}')"

  # An open issue with this exact title is the finding already filed.
  audit_open_listing existing
  if audit_open_find "$existing" "$title" existing_n; then
    warn "#$existing_n is already open with this title; nothing filed"
    note "$existing_n"
    return 0
  fi

  audit_triage_ready triage
  category_label_ensure "$category"
  gh_or_die --out n "create the issue" \
    adapter_issue_create "$title" "$body_file" "$triage" "$category"
  note "$n"
}

# audit_batch_body <n>: prints the issue body of ranked finding <n>, from the
# AUDIT_* globals: each field other than the steering four and Location as a
# paragraph with its label in bold, one **Location:** line per location, then
# the **Audited at:** line carrying the commit audit begin recorded; each
# paragraph followed by a blank line.
audit_batch_body() {
  local n="$1" rest="${AUDIT_FIELDS[$1]}" rec label
  local -a locs=()
  while [ -n "$rest" ]; do
    rec="${rest%%"$AUDIT_RS"*}"
    rest="${rest#*"$AUDIT_RS"}"
    label="${rec%%"$AUDIT_US"*}"
    case "$label" in From | Title | Category | Overlaps | Location) continue ;; esac
    printf '**%s:** %s\n\n' "$label" "${rec#*"$AUDIT_US"}"
  done
  mapfile -t locs <<<"${AUDIT_LOCS[n]}"
  audit_body_tail "$AUDIT_COMMIT" "${locs[@]}"
}

# audit_body_norm <var> <text>: <text> with its carriage returns and trailing
# newlines dropped, into <var>.
audit_body_norm() {
  local s="${2//$'\r'/}"
  newlines_strip s
  printf -v "$1" '%s' "$s"
}

# audit_nums_union <var> <a> <b>: the numbers of the space-separated lists <a>
# and <b>, each once, ascending and space-separated, into <var>.
audit_nums_union() {
  local out=() w i
  for w in $2 $3; do
    w=$((10#$w))
    ! word_listed "${out[*]:-}" "$w" || continue
    i="${#out[@]}"
    while [ "$i" -gt 0 ] && [ "${out[i - 1]}" -gt "$w" ]; do
      out[i]="${out[i - 1]}"
      i=$((i - 1))
    done
    out[i]="$w"
  done
  printf -v "$1" '%s' "${out[*]:-}"
}

# audit_file_batch <dir> <numbers>: files the ranked findings <numbers> (comma
# separated) of the audit run <dir> as issues, in number order, then writes
# each linked issue's **Related:** paragraph. Every check - the ranked file's
# reader, the numbers, the bodies' round trip - comes before any GitHub read or
# write. Prints, per finding, its number, its issue number and filed or open,
# tab-separated. Each line is printed as its finding gets its issue number, so a
# failure partway leaves the lines of the findings already filed.
audit_file_batch() {
  [ $# -eq 2 ] || die "$(audit_usage)"
  local dir="$1" item n j picked=() want="" seen="" cat
  audit_ranked_read "$dir"
  audit_list_split want "$2"
  [ -n "$want" ] || die "$(audit_usage)"
  while IFS= read -r item; do
    [ -n "$item" ] || continue
    [[ $item =~ ^[0-9]+$ ]] || die "'$item' is not a finding number"
    item=$((10#$item))
    [ "$item" -ge 1 ] && [ "$item" -le "$AUDIT_COUNT" ] \
      || die "the ranked file has no finding $item"
    ! word_listed "$seen" "$item" || die "finding $item is given twice"
    seen+=" $item"
  done <<<"$want"
  for ((n = 1; n <= AUDIT_COUNT; n++)); do
    ! word_listed "$seen" "$n" || picked+=("$n")
  done

  local -A base=() issue=() state=() ensured=()
  local body_file got_locs got_shas
  for n in "${picked[@]}"; do
    audit_body_norm "base[$n]" "$(audit_batch_body "$n")"
    audit_body_parse "${base[$n]}" got_locs got_shas
    [ "$got_locs" = "${AUDIT_LOCS[n]}"$'\n' ] \
      || die "the rendered body does not parse back: locations of finding $n"
    [ "$got_shas" = "$AUDIT_COMMIT"$'\n' ] \
      || die "the rendered body does not parse back: audited at of finding $n"
  done
  finding_body_file_new body_file

  local existing existing_n triage="" made
  audit_open_listing existing
  for n in "${picked[@]}"; do
    if audit_open_find "$existing" "${AUDIT_TITLE[n]}" existing_n; then
      issue[$n]="$existing_n" state[$n]=open
      printf '%s\t%s\t%s\n' "$n" "$existing_n" open
      continue
    fi
    [ -n "$triage" ] || audit_triage_ready triage
    cat="${AUDIT_CATEGORY[n]}"
    if [ -z "${ensured[$cat]:-}" ]; then
      category_label_ensure "$cat"
      ensured[$cat]=1
    fi
    printf '%s\n\n' "${base[$n]}" >"$body_file"
    gh_or_die --out made "create the issue" \
      adapter_issue_create "${AUDIT_TITLE[n]}" "$body_file" "$triage" "$cat"
    issue[$n]="$made" state[$n]=filed
    existing+=$'\n'"$made"$'\t'"${AUDIT_TITLE[n]}"
    printf '%s\t%s\t%s\n' "$n" "$made" filed
  done

  local links nums have cur raw tail unioned num
  for n in "${picked[@]}"; do
    links=""
    for j in "${picked[@]}"; do
      if word_listed "${AUDIT_LINKS[n]}" "$j" && [ "${issue[$j]}" != "${issue[$n]}" ]; then
        links+="${issue[$j]} "
      fi
    done
    [ -n "$links" ] || continue
    have=""
    if [ "${state[$n]}" = open ]; then
      gh_or_die --out raw "read issue #${issue[$n]}" adapter_issue_body "${issue[$n]}"
      audit_body_norm cur "$raw"
      tail="${cur#"${base[$n]}"$'\n\n**Related:** '}"
      if [ "$cur" = "${base[$n]}" ]; then
        have=""
      elif [ "$tail" != "$cur" ] && [[ $tail =~ ^#[0-9]+(\ #[0-9]+)*$ ]]; then
        audit_nums_union have "${tail//#/}" ""
      else
        warn "#${issue[$n]} was edited since it was filed; its Related line is not written"
        continue
      fi
    fi
    audit_nums_union unioned "$have" "$links"
    [ "$unioned" != "$have" ] || continue
    nums=""
    for num in $unioned; do nums+="#$num "; done
    printf '%s\n\n**Related:** %s\n\n' "${base[$n]}" "${nums% }" >"$body_file"
    gh_or_die "write issue #${issue[$n]}'s Related line" \
      adapter_issue_body_edit "${issue[$n]}" "$body_file"
  done
}

cmd_audit() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin) audit_begin "$@" ;;
    report) audit_report "$@" ;;
    file)
      if [ "${1:-}" = --run ]; then audit_file_batch "${@:2}"; else audit_file "$@"; fi ;;
    *) die "$(audit_usage)" ;;
  esac
}
