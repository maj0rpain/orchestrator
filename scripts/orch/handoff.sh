# shellcheck shell=bash
# handoff.sh - orch.sh's handoff command: handoff path, validate and section.
# Its tests: scripts/test/orch/handoff.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The phase table: the one statement of the flow's phases' order and of what
# each one consumes. One row per recorded state phase, its cells split by `|`:
# the phase, the handoff it consumes, the writer (the phase that wrote that
# handoff - an explicit column, never parsed out of the file name; plan is a
# writer only, never a state phase), and that handoff's required sections,
# split by `;`. done consumes nothing, so its cells are stored empty, and every
# lookup by handoff file skips a row whose handoff is empty. A plain string,
# read line by line: no associative or parallel arrays, so bash 3.2 runs it.
# The phase is the row key, always the first column, which is all phase_list
# reads; the other columns are stated only in phase_cell's read, and every
# other helper reads the table through those two. Every phase sequence derives
# from it. A per-phase `case` that gives each phase its own message or
# requirement (phase advance, review pass, spec review) may name phases.
readonly PHASE_TABLE='spec|01-plan.md|plan|Decisions;Rejected alternatives;Constraints;Open assumptions
implement|02-spec.md|spec|Spec issue;Seams;Spec review changelog;Ticket breakdown
review|03-implement.md|implement|PR;Spec issue;Base SHA;Deviations;Verification
done|||'

# The table's phases, space-separated, in flow order - what orch.sh sets
# PHASES from.
phase_list() {
  local phase list=""
  while IFS='|' read -r phase _; do
    list="${list:+$list }$phase"
  done <<<"$PHASE_TABLE"
  printf '%s\n' "$list"
}

# phase_cell <column> <phase>: <phase>'s cell in <column> of the table, the
# column named handoff, writer or sections. Nothing, and non-zero, when the
# cell is empty or the table does not hold <phase>; an unknown column dies.
phase_cell() {
  local phase handoff writer sections cell
  case "$1" in
    handoff|writer|sections) ;;
    *) die "unknown phase table column: $1" ;;
  esac
  while IFS='|' read -r phase handoff writer sections; do
    [ "$phase" = "$2" ] || continue
    case "$1" in
      handoff)  cell="$handoff" ;;
      writer)   cell="$writer" ;;
      sections) cell="$sections" ;;
    esac
    [ -n "$cell" ] || return 1
    printf '%s\n' "$cell"
    return 0
  done <<<"$PHASE_TABLE"
  return 1
}

# handoffs_due <phase>: the handoffs consumed by every row up to and including
# <phase>, one per line - every handoff a flow at <phase> has written. A phase
# the table does not hold prints nothing.
handoffs_due() {
  local phase handoff due=""
  for phase in $(phase_list); do
    if handoff="$(phase_cell handoff "$phase")"; then due="$due$handoff"$'\n'; fi
    if [ "$phase" = "$1" ]; then
      printf '%s' "$due"
      return 0
    fi
  done
}

# handoffs_written_from <phase>: the handoffs whose writer is <phase> or a
# phase after it, one per line, in table order - the ones a step back to
# <phase> makes stale. plan, a writer though no row, gives every handoff;
# nothing for a name the writer column does not hold.
handoffs_written_from() {
  local phase handoff found=0
  for phase in $(phase_list); do
    handoff="$(phase_cell handoff "$phase")" || continue
    [ "$(phase_cell writer "$phase")" != "$1" ] || found=1
    if [ "$found" = 1 ]; then printf '%s\n' "$handoff"; fi
  done
}

# phase_next <phase>: the phase after <phase>. Nothing, and non-zero, at the
# last row or for a phase the table does not hold.
phase_next() {
  local phase found=0
  for phase in $(phase_list); do
    if [ "$found" = 1 ]; then
      printf '%s\n' "$phase"
      return 0
    fi
    [ "$phase" != "$1" ] || found=1
  done
  return 1
}

# phases_from <phase>: <phase> and every phase after it, one per line, in
# table order. Nothing, and non-zero, for a phase the table does not hold.
phases_from() {
  local phase found=0
  for phase in $(phase_list); do
    [ "$phase" != "$1" ] || found=1
    if [ "$found" = 1 ]; then printf '%s\n' "$phase"; fi
  done
  [ "$found" = 1 ]
}

# Every review loop, however many the flow has run, reads the implement
# handoff, so the four facts a loop runs on have exactly one authority.
handoff_file_for() {
  phase_cell handoff "$1" || die "no handoff defined for phase: $1"
}

# A handoff missing a required section means the next phase runs blind, so the
# boundary is where it must fail - the context to fix it still exists there.
handoff_required() {
  local phase handoff sections
  for phase in $(phase_list); do
    handoff="$(phase_cell handoff "$phase")" || continue
    [ "$handoff" = "$1" ] || continue
    sections="$(phase_cell sections "$phase")" || sections=""
    while [ -n "$sections" ]; do
      printf '## %s\n' "${sections%%;*}"
      case "$sections" in
        *";"*) sections="${sections#*;}" ;;
        *) sections="" ;;
      esac
    done
    if host_fallbacks_required; then printf '%s\n' '## Host fallbacks'; fi
    return 0
  done
  die "unknown handoff file: $1"
}

# A flow started before 1.0.0 wrote its handoffs without Host fallbacks, and
# its state.json has no host_fallbacks field. It keeps validating as it did, so
# upgrading mid-flow breaks nothing; every flow init starts now requires the
# section. With no state at all there is no older flow to spare.
host_fallbacks_required() {
  [ ! -f "$STATE" ] || [ "$(state_get host_fallbacks 2>/dev/null)" = true ]
}

# section_body <file> <heading>: prints the lines of <file> under the line
# exactly <heading>, up to the next `## ` heading.
section_body() {
  awk -v h="$2" '$0 == h { inside = 1; next } /^## / { inside = 0 } inside { print }' "$1"
}

# section_entries <file> <heading>: the entries under <heading> in <file>, as
# text_entries splits them. The known-items builders copy these, and do no
# matching.
section_entries() {
  section_body "$1" "$2" | text_entries
}

# text_entries: the entries of the text on stdin, one per line - each
# top-level `- ` bullet joined with its indented continuation lines by single
# spaces, its leading `- ` stripped, and each non-blank line at the margin that
# is no bullet as an entry of its own. An entry reading None, None. or None
# declined. is a source saying it has nothing, and is dropped.
text_entries() {
  awk '
    function flush() {
      if (entry != "" && entry !~ /^None( declined)?\.?$/) print entry
      entry = ""; bullet = 0
    }
    { sub(/[[:space:]]+$/, "") }
    /^$/ { next }
    /^- / { flush(); entry = substr($0, 3); sub(/^[[:space:]]+/, "", entry); bullet = 1; next }
    /^[[:space:]]/ {
      line = $0; sub(/^[[:space:]]+/, "", line)
      if (bullet) entry = entry " " line; else { flush(); entry = line; flush() }
      next
    }
    { flush(); entry = $0; flush() }
    END { flush() }'
}

# entries_append <var> <file> <heading> [<tag>]: appends to <var> one `- `
# bullet line per entry under <heading> in <file> - every entry of the whole
# file when <heading> is empty - each ending ` - <tag>` when <tag> is given.
entries_append() {
  local _ea_entry _ea_tag="${4:+ - $4}"
  while IFS= read -r _ea_entry; do
    printf -v "$1" '%s- %s%s\n' "${!1}" "$_ea_entry" "$_ea_tag"
  done < <(if [ -n "$3" ]; then section_entries "$2" "$3"; else text_entries <"$2"; fi)
}

# known_items_write <path> <deviations> <known>: writes a known-items file to
# <path>, overwriting it - `## Deviations` then `## Known items`, each heading's
# bullet lines, or None. when it has none. Built beside <path> and moved into
# place, so a failed write leaves <path> as it was.
known_items_write() {
  local path="$1" deviations="$2" known="$3" tmp
  [ -n "$deviations" ] || deviations=$'None.\n'
  [ -n "$known" ] || known=$'None.\n'
  tmp="$(mktemp "$path.XXXXXX")" || die "could not create a temp file beside $path"
  printf '## Deviations\n%s## Known items\n%s' "$deviations" "$known" >"$tmp" \
    || { rm -f "$tmp"; die "could not write the known items"; }
  mv "$tmp" "$path" || { rm -f "$tmp"; die "could not write the known items to $path"; }
}

# The single statement of what a valid handoff is: one line per required
# section, each `ok <heading>` or `FAIL <problem>`. doctor's flow-state check
# reads the same answer rather than writing a second one that can drift from it.
handoff_report() {
  local file="$1" base heading required failed=0
  base="$(basename "$file")"
  # Resolved up front, and the failure caught by hand: read straight out of a
  # process substitution, a name this file does not know would die in a subshell
  # nobody checks, the loop would read nothing, and a file with no required
  # sections at all would validate clean.
  required="$(handoff_required "$base")" || return 1
  while IFS= read -r heading; do
    if ! grep -qxF "$heading" "$file"; then
      printf 'FAIL missing section: %s\n' "$heading"
      failed=1
    elif [ -z "$(section_body "$file" "$heading" | tr -d '[:space:]')" ]; then
      printf 'FAIL empty section: %s\n' "$heading"
      failed=1
    else
      printf 'ok %s\n' "$heading"
    fi
  done <<<"$required"
  return "$failed"
}

# Check one handoff and relay the verdict in the aligned `ok    ` / `FAIL  `
# form: every FAIL line, and the ok lines too when the second argument is `ok`.
# A missing file is one FAIL line and status 2, an invalid one status 1, so a
# caller can pick its remedy without testing the file again. It never dies -
# the status is the verdict, and each caller keeps its own reaction to it.
handoff_check() {
  local file="$1" show_ok="${2:-}" report line failed=0
  if [ ! -f "$file" ]; then
    note "FAIL  handoff not found: $file"
    return 2
  fi
  report="$(handoff_report "$file")" || failed=1
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   [ "$show_ok" = ok ] && note "ok    ${line#ok }" ;;
      "FAIL "*) note "FAIL  ${line#FAIL }" ;;
    esac
  done <<<"$report"
  return "$failed"
}

cmd_handoff() {
  local op="${1:-}"
  shift || true
  case "$op" in
    path)
      [ $# -eq 1 ] || die "usage: orch.sh handoff path <phase>"
      # Assign first, print second. `handoff_file_for` dies on a phase it does
      # not know, and inside the printf's own substitution that kills the
      # subshell and leaves printf to succeed - so the caller gets the bare
      # handoff directory and a zero exit, which is worse than no answer.
      local file
      file="$(handoff_file_for "$1")"
      printf '%s/%s\n' "$HANDOFF_DIR" "$file"
      ;;
    validate)
      [ $# -eq 1 ] || die "usage: orch.sh handoff validate <file>"
      handoff_check "$1" ok || return 1
      ;;
    section)
      [ $# -eq 2 ] || die "usage: orch.sh handoff section <file> <heading>"
      local file="$1" heading="## $2"
      [ -f "$file" ] || die "handoff not found: $file"
      local count
      count="$(grep -cxF "$heading" "$file")" || true
      [ "$count" -gt 0 ] || die "section not found: $heading in $file"
      # A handoff with two identical sections is malformed; section_body would
      # print both bodies joined as if they were one.
      [ "$count" -eq 1 ] || die "repeated section: $heading in $file"
      # Trim leading and trailing blank lines, keeping inner ones. A section
      # holding only whitespace prints nothing - the same condition under which
      # handoff_report calls it empty.
      section_body "$file" "$heading" | awk '
        /[^[:space:]]/ { for (; held > 0; held--) print ""; print; seen = 1; next }
        seen { held++ }'
      ;;
    *) die "unknown handoff op: ${op:-<none>} (want path|validate|section)" ;;
  esac
}
