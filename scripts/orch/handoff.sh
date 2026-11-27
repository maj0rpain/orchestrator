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
# read line by line.
# The phase is the row key, always the first column, which is all phase_list
# reads; the other columns are stated only in phase_cell's read, and every
# other helper reads the table through those two. Every phase sequence derives
# from it. A per-phase `case` that gives each phase its own message or
# requirement (phase advance, review pass, spec review) may name phases.
readonly PHASE_TABLE='spec|01-plan.md|plan|Decisions;Rejected alternatives;Constraints;Open assumptions
implement|02-spec.md|spec|Spec issue
review|03-implement.md|implement|PR;Spec issue;Base SHA;Deviations;Verification
done|||'

# The table's phases, space-separated, in flow order - what PHASES, below, is
# set from.
phase_list() {
  local phase list=""
  while IFS='|' read -r phase _; do
    list="${list:+$list }$phase"
  done <<<"$PHASE_TABLE"
  printf '%s\n' "$list"
}

# The flow's phases, space-separated in flow order: read inside functions only
# (the state writer's phase guard). Set when this
# module is sourced, from the phase table above.
PHASES="$(phase_list)"
# shellcheck disable=SC2034 # read by other modules, each calling orch_load handoff first
readonly PHASES

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
# exactly <heading>, up to the next `## ` heading. A line inside a code fence,
# delimiters included, is never a heading: it neither opens nor closes a
# section, and inside the open one it is part of the body.
section_body() {
  awk -v h="$2" "$FENCE_AWK"'
    { f = fenced($0) }
    !f && $0 == h { inside = 1; next }
    !f && /^## / { inside = 0 }
    inside { print }' "$1"
}

# section_count <file> <heading>: the number of lines of <file> exactly equal
# to <heading> outside any code fence.
section_count() {
  awk -v h="$2" "$FENCE_AWK"'
    { f = fenced($0) }
    !f && $0 == h { n++ }
    END { print n + 0 }' "$1"
}

# autopilot_block_values <file> <key>: the value of each `<key>: <value>` line
# in <file>'s `## Autopilot` section, trimmed, one per line.
autopilot_block_values() {
  section_body "$1" '## Autopilot' | sed -n "s/^$2:[[:space:]]*\\(.*[^[:space:]]\\)[[:space:]]*\$/\\1/p"
}

# autopilot_block_report <file>: the plan's `## Autopilot` block, in
# handoff_report's lines - `ok ## Autopilot`, or one FAIL line per problem -
# and non-zero when any failed. The block is `Rounds` and `Budget`, each one
# line holding a whole number of 1 or more.
autopilot_block_report() {
  local file="$1" key values failed=0
  if [ "$(section_count "$file" '## Autopilot')" -eq 0 ]; then
    printf 'FAIL missing section: ## Autopilot\n'
    return 1
  fi
  for key in Rounds Budget; do
    values="$(autopilot_block_values "$file" "$key")"
    if [ -z "$values" ]; then
      printf 'FAIL ## Autopilot has no %s line (want "%s: <n>")\n' "$key" "$key"; failed=1
    elif [ "$(wc -l <<<"$values" | tr -d ' ')" -gt 1 ]; then
      printf 'FAIL ## Autopilot repeats its %s line\n' "$key"; failed=1
    elif ! is_positive_int "$values"; then
      printf 'FAIL ## Autopilot %s is %s - it must be a whole number of 1 or more\n' "$key" "$values"; failed=1
    fi
  done
  [ "$failed" = 1 ] || printf 'ok ## Autopilot\n'
  return "$failed"
}

# The bash statement of what a valid handoff is: one line per required
# section, each `ok <heading>` or `FAIL <problem>`. The Python package's copy,
# handoff_report in scripts/orch_py/orch/handoff.py, which phase advance and
# doctor's flow-state check run, is pinned to this one by the golden handoffs of
# scripts/orch_py/tests/handoff_report/, run through both.
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
    if [ "$(section_count "$file" "$heading")" -eq 0 ]; then
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

# handoff_comment_body <name> <file> <body-var>: builds the body of a handoff
# comment, <name>'s marker then <file>, already validated, in a temp file, and
# assigns its path to <body-var>. The caller removes it. Dies when the temp
# file cannot be made.
handoff_comment_body() {
  local name="$1" file="$2" made
  temp_file_make made || die "could not create a temp file for the handoff comment"
  { marked_comment_write handoff "$name"; cat "$file"; } >"$made"
  printf -v "$3" '%s' "$made"
}

# handoff_comment_post <issue> <name> <file>: posts <file>, already validated,
# silently as a new comment on <issue> under <name>'s marker, through
# adapter_issue_comment; `handoff post` and the minimal plan post use it. The
# newest tagged comment is the handoff, so a post never edits an earlier one.
# The temp body is removed on every path. Returns non-zero, with
# `orch: gh could not post ...: <reason>` on stderr, when the post fails; each
# caller chooses its reaction.
handoff_comment_post() {
  local issue="$1" name="$2" file="$3" body gh_err
  handoff_comment_body "$name" "$file" body
  if gh_capture_err gh_err adapter_issue_comment "$issue" "$body"; then
    rm -f "$body"
    return 0
  fi
  rm -f "$body"
  warn "gh could not post the $name handoff on issue #$issue: $(gh_reason "$gh_err")"
  return 1
}

# handoff_comment_post_url <issue> <name> <file> <url-var>: the post of
# handoff_comment_post through adapter_issue_comment_url, assigning the posted
# comment's URL to <url-var>, empty where gh printed none. Its one caller, the
# bash `autopilot start`, went with the bash autopilot noun; the Python one
# posts through orch/handoff.py's copy. Same failure contract as
# handoff_comment_post.
handoff_comment_post_url() {
  local issue="$1" name="$2" file="$3" body gh_err posted_url=""
  handoff_comment_body "$name" "$file" body
  if gh_capture posted_url gh_err adapter_issue_comment_url "$issue" "$body"; then
    rm -f "$body"
    printf -v "$4" '%s' "$posted_url"
    return 0
  fi
  rm -f "$body"
  warn "gh could not post the $name handoff on issue #$issue: $(gh_reason "$gh_err")"
  return 1
}

# The Handoff store: where a flow's handoffs live, behind one interface with a
# file adapter (interactive: files in the handoff directory) and a comment
# adapter (autopilot: marked comments on the issue). Its one operation here is
# path; the retire a redo makes is the Python redo noun's
# (scripts/orch_py/orch/handoff.py's handoff_retire). handoff_store is the one
# place that chooses the adapter, per call, so a test toggling ORCH_AUTOPILOT
# between commands keeps working.

# handoff_store: prints the adapter this session's handoffs live in, `comment`
# in an autopilot session and `file` otherwise.
handoff_store() {
  if autopilot_active; then printf 'comment\n'; else printf 'file\n'; fi
}

# handoff_comment_missing <issue> <name> [<hint>]: dies, naming the handoff
# <name> missing: `issue #<issue> has no <name> handoff comment`. A <hint>
# follows ` - post it with handoff post `.
handoff_comment_missing() {
  die "issue #$1 has no $2 handoff comment${3:+ - post it with handoff post $3}"
}

# handoff_comment_status <status> <issue> <name> [<hint>]: a handoff comment
# read's reaction to its status - nothing on 0, handoff_comment_missing on 1,
# exit 1 on any other: a failed write, its line already on stderr, so it never
# reads as a missing handoff.
handoff_comment_status() {
  case "$1" in
    0) ;;
    1) handoff_comment_missing "$2" "$3" "${4:-}" ;;
    *) exit 1 ;;
  esac
}

# handoff_comment_write <name> <file>: writes the body of the newest comment
# tagged for <name> in the last timeline read, marker stripped, to <file>. No gh
# call. Returns 1, <file> untouched, when there is none or the newest is
# tagged retired; 2, <file> untouched, after one `orch: could not write <file>`
# line on stderr, when the write fails. Never dies.
handoff_comment_write() {
  orch_load issue-timeline
  local name="$1" file="$2" raw
  timeline_handoff "$name" || return 1
  raw="$(timeline_body "$TIMELINE_HANDOFF_INDEX")"
  file_write_atomic "$file" "${raw:+$raw$'\n'}" 2>/dev/null || { warn "could not write $file"; return 2; }
}

# handoff_comment_fetch <issue> <name> <file>: reads <issue>'s comments, then
# handoff_comment_write. For single-handoff callers.
handoff_comment_fetch() {
  timeline_read_or_die "$1"
  handoff_comment_write "$2" "$3"
}

# handoff_path <phase> <file>: what `handoff path` prints for <file>, the
# handoff <phase> writes.
handoff_path() { "handoff_$(handoff_store)_path" "$@"; }

# File adapter.

# handoff_file_path <phase> <file>: prints the write target,
# $HANDOFF_DIR/<file>; non-zero when the handoff is missing.
handoff_file_path() {
  printf '%s/%s\n' "$HANDOFF_DIR" "$2"
  [ -f "$HANDOFF_DIR/$2" ]
}

# Comment adapter.

# handoff_comment_fetched <file>: prints the scratch path; non-zero when the
# last handoff_comment_fetch_due left no copy.
handoff_comment_fetched() {
  printf '%s/%s\n' "$HANDOFF_SCRATCH_DIR" "$1"
  [ -f "$HANDOFF_SCRATCH_DIR/$1" ]
}

# handoff_comment_fetch_due <phase>: requires the recorded issue, clears the
# scratch copy of every handoff due at <phase>, reads the comments once and
# writes each live one to the scratch directory. A handoff with no live comment
# is absent. A failed read leaves no copy and returns 1, gh's reason in
# TIMELINE_REASON. A copy that cannot be written is absent too, its line on
# stderr, and the loop goes on to write the others, then returns 2.
handoff_comment_fetch_due() {
  local issue due st=0
  require_issue issue
  for due in $(handoffs_due "$1"); do rm -f "$HANDOFF_SCRATCH_DIR/$due"; done
  timeline_read "$issue" || return 1
  for due in $(handoffs_due "$1"); do
    handoff_comment_write "${due%.md}" "$HANDOFF_SCRATCH_DIR/$due" || [ $? -eq 1 ] || st=2
  done
  return "$st"
}

# handoff_comment_path <phase> <file>: fetches everything due at <phase> with
# one read, then resolves <file> from the scratch directory.
handoff_comment_path() {
  local issue st=0
  require_issue issue
  handoff_comment_fetch_due "$1" || st=$?
  [ "$st" -ne 1 ] || timeline_die "$issue"
  [ "$st" -eq 0 ] || exit 1
  handoff_comment_fetched "$2" || handoff_comment_missing "$issue" "${2%.md}"
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
      handoff_path "$1" "$file"
      ;;
    post)
      [ $# -eq 2 ] || die "usage: orch.sh handoff post <name> <file>"
      handoff_autopilot_only post
      handoff_name_check "$1"
      [ -f "$2" ] || die "handoff not found: $2"
      local issue
      require_issue issue
      handoff_check "$2" "" "$1.md" || die "handoff $2 is not valid - nothing posted"
      handoff_comment_post "$issue" "$1" "$2" || exit 1
      ;;
    fetch)
      [ $# -eq 2 ] || die "usage: orch.sh handoff fetch <name> <file>"
      handoff_autopilot_only fetch
      handoff_name_check "$1"
      local issue
      require_issue issue
      local st=0
      handoff_comment_fetch "$issue" "$1" "$2" || st=$?
      handoff_comment_status "$st" "$issue" "$1"
      ;;
    validate)
      [ $# -eq 1 ] || die "usage: orch.sh handoff validate <file>"
      require_state_readable
      handoff_check "$1" ok || return 1
      ;;
    section)
      [ $# -eq 2 ] || die "usage: orch.sh handoff section <file> <heading>"
      local file="$1" heading="## $2"
      [ -f "$file" ] || die "handoff not found: $file"
      local count
      count="$(section_count "$file" "$heading")"
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
