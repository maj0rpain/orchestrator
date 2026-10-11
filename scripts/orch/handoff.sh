# shellcheck shell=bash
# handoff.sh - orch.sh's handoff command: handoff path, validate and section.
# Its tests: scripts/test/orch/handoff.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# The phase table: the one statement of the flow's phases, in flow order, and
# of what each one consumes. One row per recorded state phase, its cells split
# by `|`: the phase, the handoff it consumes, the writer (the phase that wrote
# that handoff - an explicit column, never parsed out of the file name; plan is
# a writer only, never a state phase), and that handoff's required sections,
# split by `;`. done consumes nothing, so its cells are stored empty, and every
# lookup by handoff file skips a row whose handoff is empty. A plain string,
# read line by line: no associative or parallel arrays, so bash 3.2 runs it.
# Every other statement of the phases derives from it, through the helpers
# below.
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

# handoffs_due <phase>: the handoffs consumed by every row up to and including
# <phase>, one per line - every handoff a flow at <phase> has written. A phase
# the table does not hold prints nothing.
handoffs_due() {
  local phase handoff due=""
  while IFS='|' read -r phase handoff _; do
    [ -z "$handoff" ] || due="$due$handoff"$'\n'
    if [ "$phase" = "$1" ]; then
      printf '%s' "$due"
      return 0
    fi
  done <<<"$PHASE_TABLE"
}

# handoffs_after <phase>: the handoffs consumed by every row after <phase>, one
# per line - the ones a step back to <phase> makes stale. Nothing after the
# last handoff's row, or for a phase the table does not hold.
handoffs_after() {
  local phase handoff found=0
  while IFS='|' read -r phase handoff _; do
    if [ "$found" = 1 ] && [ -n "$handoff" ]; then printf '%s\n' "$handoff"; fi
    [ "$phase" != "$1" ] || found=1
  done <<<"$PHASE_TABLE"
}

# phase_next <phase>: the phase after <phase>. Nothing, and non-zero, at the
# last row or for a phase the table does not hold.
phase_next() {
  local phase found=0
  while IFS='|' read -r phase _; do
    if [ "$found" = 1 ]; then
      printf '%s\n' "$phase"
      return 0
    fi
    [ "$phase" != "$1" ] || found=1
  done <<<"$PHASE_TABLE"
  return 1
}

# phase_writer <phase>: the phase that wrote the handoff <phase> consumes.
# Nothing, and non-zero, at done or for a phase the table does not hold.
phase_writer() {
  local phase writer
  while IFS='|' read -r phase _ writer _; do
    if [ "$phase" = "$1" ] && [ -n "$writer" ]; then
      printf '%s\n' "$writer"
      return 0
    fi
  done <<<"$PHASE_TABLE"
  return 1
}

# Every review loop, however many the flow has run, reads the implement
# handoff, so the four facts a loop runs on have exactly one authority.
handoff_file_for() {
  local phase handoff
  while IFS='|' read -r phase handoff _; do
    if [ "$phase" = "$1" ] && [ -n "$handoff" ]; then
      printf '%s\n' "$handoff"
      return 0
    fi
  done <<<"$PHASE_TABLE"
  die "no handoff defined for phase: $1"
}

# A handoff missing a required section means the next phase runs blind, so the
# boundary is where it must fail - the context to fix it still exists there.
handoff_required() {
  local handoff sections
  while IFS='|' read -r _ handoff _ sections; do
    if [ -n "$handoff" ] && [ "$handoff" = "$1" ]; then
      while [ -n "$sections" ]; do
        printf '## %s\n' "${sections%%;*}"
        case "$sections" in
          *";"*) sections="${sections#*;}" ;;
          *) sections="" ;;
        esac
      done
      if host_fallbacks_required; then printf '%s\n' '## Host fallbacks'; fi
      return 0
    fi
  done <<<"$PHASE_TABLE"
  die "unknown handoff file: $1"
}

# A flow started before 1.0.0 wrote its handoffs without Host fallbacks, and
# its state.json has no host_fallbacks field. It keeps validating as it did, so
# upgrading mid-flow breaks nothing; every flow init starts now requires the
# section. With no state at all there is no older flow to spare.
host_fallbacks_required() {
  [ ! -f "$STATE" ] || [ "$(state_get host_fallbacks 2>/dev/null)" = true ]
}

section_body() {
  awk -v h="$2" '$0 == h { inside = 1; next } /^## / { inside = 0 } inside { print }' "$1"
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
