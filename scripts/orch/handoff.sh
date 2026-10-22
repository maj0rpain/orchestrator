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

# The single statement of what a valid handoff is: one line per required
# section, each `ok <heading>` or `FAIL <problem>`. doctor's flow-state check
# reads the same answer rather than writing a second one that can drift from it.
# <name> is the handoff file name the sections are looked up by, the file's own
# basename unless given: an autopilot scratch file is not named as its handoff.
# The plan's `## Autopilot` block is checked, and required, in an autopilot
# session or when the third argument is `autopilot` (autopilot start).
handoff_report() {
  local file="$1" base heading required failed=0
  base="${2:-$(basename "$file")}"
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
  if [ "$base" = 01-plan.md ] && { autopilot_active || [ "${3:-}" = autopilot ]; }; then
    autopilot_block_report "$file" || failed=1
  fi
  return "$failed"
}

# Check one handoff and relay the verdict in the aligned `ok    ` / `FAIL  `
# form: every FAIL line, and the ok lines too when the second argument is `ok`.
# A missing file is one FAIL line and status 2, an invalid one status 1, so a
# caller can pick its remedy without testing the file again. It never dies -
# the status is the verdict, and each caller keeps its own reaction to it.
# The third and fourth arguments are handoff_report's <name> and `autopilot`
# switch.
handoff_check() {
  local file="$1" show_ok="${2:-}" report line failed=0
  if [ ! -f "$file" ]; then
    note "FAIL  handoff not found: $file"
    return 2
  fi
  report="$(handoff_report "$file" "${3:-}" "${4:-}")" || failed=1
  while IFS= read -r line; do
    case "$line" in
      "ok "*)   [ "$show_ok" = ok ] && note "ok    ${line#ok }" ;;
      "FAIL "*) note "FAIL  ${line#FAIL }" ;;
    esac
  done <<<"$report"
  return "$failed"
}

# handoff_marker <name> [retired]: the first line of a handoff's comment, the
# hidden tag that makes an issue comment the handoff <name>: `01-plan`,
# `02-spec` or `03-implement`.
handoff_marker() { printf '<!-- orch:handoff %s%s -->\n' "$1" "${2:+ $2}"; }

# handoff_name_check <name>: dies unless <name> is a handoff the table holds,
# its file name without the `.md`.
handoff_name_check() {
  local phase handoff names=""
  for phase in $(phase_list); do
    handoff="$(phase_cell handoff "$phase")" || continue
    [ "${handoff%.md}" != "$1" ] || return 0
    names="${names:+$names|}${handoff%.md}"
  done
  die "unknown handoff name: $1 (want $names)"
}

# handoff_comment_post <issue> <name> <file>: posts <file>, already validated,
# as a new comment on <issue> under <name>'s marker. The newest tagged comment
# is the handoff, so a post never edits an earlier one.
handoff_comment_post() {
  local issue="$1" name="$2" file="$3" body
  body="$(mktemp)" || die "could not create a temp file for the handoff comment"
  { handoff_marker "$name"; cat "$file"; } >"$body"
  gh_or_die "post the $name handoff on issue #$issue" adapter_issue_comment "$issue" "$body" \
    || { rm -f "$body"; return 1; }
  rm -f "$body"
}

# handoff_comment_fetch <issue> <name> <file>: writes the body of <issue>'s
# newest comment tagged for <name>, marker stripped, to <file>. Non-zero, and
# <file> untouched, when there is none or the newest is tagged retired.
handoff_comment_fetch() {
  local issue="$1" name="$2" file="$3" json raw
  gh_or_die --out json "read the comments of issue #$issue" adapter_issue_json "$issue"
  raw="$(jq -j --arg m "$(handoff_marker "$name")" --arg r "$(handoff_marker "$name" retired)" '
    [.comments[] | select((.body | split("\n")[0] | rtrimstr("\r")) as $l | $l == $m or $l == $r)]
    | last | .body // empty' <<<"$json")" || die "could not read issue #$issue's comments"
  [ -n "$raw" ] || return 1
  [ "$(printf '%s\n' "${raw%%$'\n'*}" | tr -d '\r')" != "$(handoff_marker "$name" retired)" ] || return 1
  mkdir -p "$(dirname "$file")"
  case "$raw" in
    *$'\n'*) printf '%s\n' "${raw#*$'\n'}" >"$file" ;;
    *) : >"$file" ;;
  esac
}

# handoff_comments_retire <issue> <file>...: in an autopilot session, retires
# each named handoff file's comment by posting a newer one tagged retired -
# what moving the file into a pre-redo folder is for an interactive flow. A
# handoff with no comment, or whose newest is already retired, posts nothing,
# so a redo that died partway is finished by the next. A post that fails dies
# naming the comments already posted. Outside an autopilot session it does
# nothing: those handoffs are files.
handoff_comments_retire() {
  local issue="$1" file name scratch body gh_err posted=""
  shift
  autopilot_active || return 0
  scratch="$(mktemp)" || die "could not create a temp file for the handoff check"
  for file in "$@"; do
    name="${file%.md}"
    handoff_comment_fetch "$issue" "$name" "$scratch" || continue
    body="$(mktemp)" || { rm -f "$scratch"; die "could not create a temp file for the retired comment"; }
    { handoff_marker "$name" retired; printf 'Retired by an orchestrator redo: this handoff described work the redo sets aside.\n'; } >"$body"
    capture_err gh_err adapter_issue_comment "$issue" "$body" || {
      rm -f "$scratch" "$body"
      die "could not retire the $name handoff on issue #$issue: $(gh_reason "$gh_err") - comments posted: ${posted:-none}; the recorded phase is unchanged, so a re-run retires the rest"
    }
    rm -f "$body"
    posted="${posted:+$posted, }$name"
  done
  rm -f "$scratch"
}

# handoff_autopilot_only <op>: dies unless this is an autopilot session - the
# only flow whose handoffs are comments.
handoff_autopilot_only() {
  autopilot_active || die "handoff $1 is for an autopilot flow (ORCH_AUTOPILOT=1): an interactive flow keeps its handoffs as files"
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
      if autopilot_active; then
        # The handoff is a comment: fetched into a scratch file, with the
        # earlier ones beside it - a skill reaches a sibling handoff by its
        # directory - where they exist.
        local issue scratch="$HANDOFF_SCRATCH_DIR" earlier
        require_issue issue
        for earlier in $(handoffs_due "$1"); do
          [ "$earlier" = "$file" ] || handoff_comment_fetch "$issue" "${earlier%.md}" "$scratch/$earlier" || true
        done
        handoff_comment_fetch "$issue" "${file%.md}" "$scratch/$file" ||
          die "issue #$issue has no ${file%.md} handoff comment"
        printf '%s/%s\n' "$scratch" "$file"
        return 0
      fi
      printf '%s/%s\n' "$HANDOFF_DIR" "$file"
      ;;
    post)
      [ $# -eq 2 ] || die "usage: orch.sh handoff post <name> <file>"
      handoff_autopilot_only post
      handoff_name_check "$1"
      [ -f "$2" ] || die "handoff not found: $2"
      local issue
      require_issue issue
      handoff_check "$2" "" "$1.md" || die "handoff $2 is not valid - nothing posted"
      handoff_comment_post "$issue" "$1" "$2"
      ;;
    fetch)
      [ $# -eq 2 ] || die "usage: orch.sh handoff fetch <name> <file>"
      handoff_autopilot_only fetch
      handoff_name_check "$1"
      local issue
      require_issue issue
      handoff_comment_fetch "$issue" "$1" "$2" || die "issue #$issue has no $1 handoff comment"
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
    *) die "unknown handoff op: ${op:-<none>} (want path|post|fetch|validate|section)" ;;
  esac
}
