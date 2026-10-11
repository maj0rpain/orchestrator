# shellcheck shell=bash
# handoff.sh - orch.sh's handoff command: handoff path, validate and section.
# Its tests: scripts/test/orch/handoff.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# Every review loop, however many the flow has run, reads the implement
# handoff, so the four facts a loop runs on have exactly one authority.
handoff_file_for() {
  case "$1" in
    spec)      printf '01-plan.md\n' ;;
    implement) printf '02-spec.md\n' ;;
    review)    printf '03-implement.md\n' ;;
    *) die "no handoff defined for phase: $1" ;;
  esac
}

# A handoff missing a required section means the next phase runs blind, so the
# boundary is where it must fail - the context to fix it still exists there.
handoff_required() {
  case "$1" in
    01-plan.md)      printf '%s\n' '## Decisions' '## Rejected alternatives' '## Constraints' '## Open assumptions' ;;
    02-spec.md)      printf '%s\n' '## Spec issue' '## Seams' '## Spec review changelog' '## Ticket breakdown' ;;
    03-implement.md) printf '%s\n' '## PR' '## Spec issue' '## Base SHA' '## Deviations' '## Verification' ;;
    *) die "unknown handoff file: $1" ;;
  esac
  if host_fallbacks_required; then printf '%s\n' '## Host fallbacks'; fi
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
