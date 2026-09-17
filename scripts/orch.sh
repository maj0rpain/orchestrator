#!/usr/bin/env bash
#
# orch.sh - deterministic operations for the orchestrator plugin.
#
# Everything in this file has exactly one right answer: reading and writing
# state, validating handoffs, resolving the default branch, archiving. Prose
# instructions re-derive these slightly differently every session, so they live
# here instead. Judgment lives in the flow skill; mechanism lives here.
#
# Usage: orch.sh <command> [args]   (run `orch.sh help` for the list)

set -euo pipefail

readonly ORCH_DIR_NAME=".orchestrator"
readonly PHASES="spec implement review done"
readonly LABELS_DOC="docs/agents/triage-labels.md"
readonly LABEL_LIMIT=1000

# How long `review ci` waits, and how often it looks. Overridable through the
# environment rather than through positional arguments: the 60-second grace is
# what stops a repo whose checks have not registered yet being declared CI-less,
# and a test that could not turn it down would take a minute to prove it works.
# The environment keeps those knobs out of the documented command surface.
ORCH_CI_GRACE="${ORCH_CI_GRACE:-60}"
ORCH_CI_TIMEOUT="${ORCH_CI_TIMEOUT:-900}"
ORCH_CI_INTERVAL="${ORCH_CI_INTERVAL:-10}"

die()  { printf 'orch: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }
# Several answers here are one line of prose followed by detail lines, and it is
# always the first line that carries the verdict.
first_line() { printf '%s\n' "$1" | sed -n 1p; }

# The one normalisation a slug gets: lowercase, non-alphanumeric runs collapsed
# to a single hyphen, trimmed, dying if nothing survives. `init` and `cmd_slug`
# both call this rather than each carrying their own copy of the sed expression
# and the empty-result check - and a caller outside this file (the
# quick-implement skill) reaches it through `orch.sh slug` instead of
# re-deriving the algorithm as prose.
normalize_slug() {
  local slug
  slug="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || die "slug is empty after normalisation"
  printf '%s\n' "$slug"
}

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
readonly ROOT
readonly ORCH="$ROOT/$ORCH_DIR_NAME"
readonly STATE="$ORCH/state.json"
readonly HANDOFF_DIR="$ORCH/handoff"
readonly REVIEW_DIR="$ORCH/review"

require_state() {
  [ -f "$STATE" ] || die "no active flow ($ORCH_DIR_NAME/state.json not found). Run /orchestrator:start first."
}

# Prints the flow's PR number, or dies. Every review command that reaches GitHub
# needs it and none of them can do anything useful without it.
#
# Call it as a bare assignment on its own line - `local pr` then `pr="$(require_pr)"`.
# The `die` runs inside the caller's command substitution and so exits only the
# subshell; what actually stops the command is `set -e` on the failed assignment.
# Fold it into `local pr="$(require_pr)"` or an `if`, and `set -e` no longer
# applies: the caller carries on with an empty PR number.
require_pr() {
  local pr
  pr="$(jq -r '.pr // ""' "$STATE")"
  [ -n "$pr" ] || die "no PR recorded in state - the implement phase opens it"
  printf '%s\n' "$pr"
}

# Prints the flow's spec issue number, or dies. branch-create, pr-open, and
# every spec op need it before touching GitHub. Same calling convention as
# require_pr - assign it bare on its own line so `set -e` catches the die.
require_issue() {
  local issue
  issue="$(jq -r '.issue // ""' "$STATE")"
  [ -n "$issue" ] || die "no issue recorded in state - the spec phase must publish one first"
  printf '%s\n' "$issue"
}

# --- environment ------------------------------------------------------------

# Locate the newest installed mattpocock-skills plugin. Resolved by glob at
# runtime and never pinned: the version in the cache path changes under us.
# No array: bash 3.2 cannot tell an empty array from an unset one, so
# ${#hits[@]} on a machine with no plugin installed aborts the subshell under
# `set -u` - on the one code path doctor exists to report.
find_mattpocock() {
  local p hits=""
  for p in "$HOME"/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/implement/SKILL.md; do
    if [ -f "$p" ]; then hits="$hits$p"$'\n'; fi
  done
  [ -n "$hits" ] || return 1
  printf '%s' "$hits" | sort -V | tail -1 | sed 's|/skills/engineering/implement/SKILL.md$||'
}

# Ask GitHub first. refs/remotes/origin/HEAD is a *local cached pointer* frozen at
# clone time - in a clone taken while a feature branch was checked out it names
# that branch, which would silently base every feature branch off the wrong place.
# It is a fallback for repos gh cannot answer for, not the primary source.
default_branch() {
  local b
  b="$(gh repo view --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)" || true
  if [ -z "$b" ]; then
    b="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')" || true
  fi
  [ -n "$b" ] || b="main"
  printf '%s\n' "$b"
}

# Ignore the flow directory without touching a tracked .gitignore, so running
# the orchestrator in an unfamiliar repo never dirties its working tree.
exclude_orch_dir() {
  local ex
  ex="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF "$ORCH_DIR_NAME/" "$ex" 2>/dev/null || printf '%s\n' "$ORCH_DIR_NAME/" >>"$ex"
}

# The mattpocock skills the flow depends on are `disable-model-invocation: true`,
# so the Skill tool cannot reach them. Their SKILL.md files are plain markdown
# and can be read and followed directly - this resolves one by name.
cmd_mp_skill() {
  local name="${1:-}" mp p
  mp="$(find_mattpocock)" || die "mattpocock-skills plugin not installed"
  if [ -z "$name" ]; then printf '%s\n' "$mp"; return 0; fi
  for p in "$mp/skills"/*/"$name"/SKILL.md; do
    if [ -f "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  die "no such mattpocock skill: $name"
}

# --- doctor -----------------------------------------------------------------
#
# Sourced rather than inlined: a change to how checks register, gate, or count
# then concentrates in doctor.sh instead of sharing file scope with the flow
# commands below.
source "$(dirname "${BASH_SOURCE[0]}")/doctor.sh"

# --- state ------------------------------------------------------------------

cmd_init() {
  local usage="usage: orch.sh init <slug> [--issue N]"
  local slug="${1:-}" issue=""
  [ -n "$slug" ] || die "$usage"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --issue)
        issue="${2:-}"
        [ -n "$issue" ] || die "$usage"
        case "$issue" in
          ''|*[!0-9]*) die "--issue wants a plain issue number, got: $issue" ;;
        esac
        shift 2 ;;
      *) die "$usage" ;;
    esac
  done
  slug="$(normalize_slug "$slug")"
  if [ -f "$STATE" ]; then
    die "a flow is already active (slug: $(jq -r .slug "$STATE"), phase: $(jq -r .phase "$STATE")).
     One flow at a time - finish it, or run /orchestrator:abort."
  fi
  # Adoption is validated before anything is written, mirroring how
  # branch-create and pr-open die on their own preconditions rather than
  # letting a whole phase run against an issue that cannot back it.
  [ -z "$issue" ] || validate_adopted_issue "$issue"
  mkdir -p "$HANDOFF_DIR" "$REVIEW_DIR"
  exclude_orch_dir
  # The budget is null until the review loop asks a human for one, and `review
  # begin` reads null as the default. The flake rerun is seeded here rather than
  # at the review phase because its allowance belongs to the flow: one per flow,
  # spent or not, so that one refilled each iteration could not become an
  # infinite retry loop. issue is seeded from --issue when given; state.json
  # carries no field for whether it was adopted or published - nothing
  # downstream reads that distinction.
  jq -n --arg slug "$slug" --arg now "$(now)" --arg issue "$issue" '{
    slug: $slug, phase: "spec", issue: (if $issue == "" then null else ($issue | tonumber) end),
    branch: null, pr: null, base_sha: null, budget: null, iteration: 0,
    flake_rerun_used: false, redo_count: 0, created: $now, updated: $now
  }' >"$STATE"
  note "$slug"
}

cmd_slug() {
  local raw="${1:-}" slug
  [ -n "$raw" ] || die "usage: orch.sh slug <text>"
  slug="$(normalize_slug "$raw")"
  note "$slug"
}

cmd_state() {
  local op="${1:-get}"
  shift || true
  case "$op" in
    get)
      require_state
      if [ $# -gt 0 ]; then jq -r --arg k "$1" '.[$k] // "" | tostring' "$STATE"; else cat "$STATE"; fi
      ;;
    set)
      require_state
      [ $# -eq 2 ] || die "usage: orch.sh state set <key> <value>"
      local tmp; tmp="$(mktemp)"
      jq --arg k "$1" --arg v "$2" --arg now "$(now)" '
        .[$k] = (if $v == "null" then null
                 elif ($v | test("^[0-9]+$")) then ($v | tonumber)
                 else $v end)
        | .updated = $now' "$STATE" >"$tmp"
      mv "$tmp" "$STATE"
      ;;
    *) die "unknown state op: $op (want get|set)" ;;
  esac
}

# --- handoffs ---------------------------------------------------------------

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
    02-spec.md)      printf '%s\n' '## Spec issue' '## Seams' '## Spec review changelog' ;;
    03-implement.md) printf '%s\n' '## PR' '## Spec issue' '## Base SHA' '## Deviations' '## Verification' ;;
    *) die "unknown handoff file: $1" ;;
  esac
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
      local file="$1" report line failed=0
      [ -f "$file" ] || die "handoff not found: $file"
      report="$(handoff_report "$file")" || failed=1
      while IFS= read -r line; do
        case "$line" in
          "ok "*)   note "ok    ${line#ok }" ;;
          "FAIL "*) note "FAIL  ${line#FAIL }" ;;
        esac
      done <<<"$report"
      return "$failed"
      ;;
    *) die "unknown handoff op: ${op:-<none>} (want path|validate)" ;;
  esac
}

# --- review -----------------------------------------------------------------

# The bound belongs here rather than in the skill's prose: a session that has
# spent four iterations arguing with itself is exactly the one that would
# re-remember five as six. The number itself is the human's, read from state;
# this is only what it reads as when nobody has set one - a flow started before
# the key existed, or a value nothing can count.
readonly DEFAULT_BUDGET=5

review_budget() {
  local b
  b="$(jq -r '.budget // ""' "$STATE")"
  case "$b" in ''|*[!0-9]*) b="$DEFAULT_BUDGET" ;; esac
  printf '%s\n' "$b"
}

# The severity label a filed finding carries, so triage can filter on it. It is
# this plugin's own, so --force is safe: on the current gh that updates a label
# that exists rather than failing on it, and filing works on a repo that has
# never seen the label and on one that has, with no listing step in between.
severity_label_ensure() {
  gh label create "$1" --force --color "$2" --description "$3" >/dev/null \
    || die "gh could not create label $1"
}

# The triage label is the repo's, not ours: created only where it is missing,
# and never rewritten, because a maintainer's colour and description on it are
# theirs to keep. A create that fails because the label exists is the common
# case and is ignored; one that fails for any other reason surfaces two lines
# later, when `gh issue create` cannot apply the label.
triage_label_ensure() {
  gh label create "$1" --color e4e669 --description "Not yet triaged" >/dev/null 2>&1 || true
}

# Float comparison and addition, in awk, because the timings are overridable and
# the tests turn them down to fractions of a second; bash arithmetic is integer
# only and would read a grace of 0.3 as 0. A fractional `sleep` is a GNU/BSD
# extension rather than POSIX, which is a line this file can hold because the
# fractions only ever come from a test - the shipped defaults are whole seconds.
float_lt()  { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }
float_add() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.3f\n", a + b }'; }

# awk compares a number against a non-numeric string as strings, which makes
# every `float_lt` above true and the poll loop endless. A zero interval is the
# same hazard by a different route: `sleep 0` returns at once and never advances
# the clock the loop sleeps on, leaving it to poll a rate-limited API as fast as
# GitHub will answer. The three knobs are read once, here, before anything
# sleeps on one of them.
require_ci_knobs() {
  local k v
  for k in ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL; do
    eval "v=\$$k"
    case "$v" in
      ''|*[!0-9.]*|*.*.*|.) die "$k is not a number: $v" ;;
    esac
  done
  # Every character is a zero or the point, so the value is zero however it was
  # written - and a glob cannot say that without also matching 0.05.
  case "${ORCH_CI_INTERVAL//[0.]/}" in
    '') die "ORCH_CI_INTERVAL must be greater than zero: $ORCH_CI_INTERVAL" ;;
  esac
}

# The larger of the wall clock and the time this loop has spent asleep. The wall
# clock alone is whole seconds, which a sub-second override never reaches; the
# sleep total alone ignores however long each `gh` call took, which would stretch
# a 15-minute cap well past 15 minutes on a slow connection.
ci_elapsed() { awk -v w="$(( $(date +%s) - $1 ))" -v s="$2" 'BEGIN { print (w > s) ? w : s }'; }

# One turn of the poll loop: wait, then advance both clocks. It assigns to the
# caller's `slept` and `elapsed`, which bash scopes dynamically - threading two
# counters back out through a subshell's stdout would cost more than it explains.
ci_tick() {
  sleep "$ORCH_CI_INTERVAL"
  slept="$(float_add "$slept" "$ORCH_CI_INTERVAL")"
  elapsed="$(ci_elapsed "$started" "$slept")"
}

# One look at the PR's checks, classified. Prints the classification on the first
# line and any detail on the lines after it, indented like doctor's remedies.
#
# The buckets carry this, not the exit status. `gh pr checks` documents exit 8
# for pending checks, but it returns through its JSON exporter before it reaches
# the code that sets 8 or 1 - so with `--json`, which is the only way this
# function asks, gh exits 0 whatever the checks are doing. The `8)` arm below is
# kept against a gh that stops doing that, and is not the path taken.
#
# What the exit status does still carry is the difference between a repo with no
# checks at all and an API that would not answer, and only the error *text*
# separates those two. Getting that distinction backwards is what would make the
# loop declare a CI-having repo CI-less.
ci_probe() {
  local pr="$1" scope="$2" out st=0 buckets failed name
  if [ "$scope" = required ]; then
    out="$(gh pr checks "$pr" --required --json bucket,name,state 2>&1)" || st=$?
  else
    out="$(gh pr checks "$pr" --json bucket,name,state 2>&1)" || st=$?
  fi
  case "$st" in
    0) ;;
    8) note pending; return 0 ;;
    *)
      case "$out" in
        *"no checks reported"*|*"no required checks"*) note none; return 0 ;;
        *) note unreachable; note "      $(first_line "$out")"; return 0 ;;
      esac ;;
  esac
  # jq's failure and jq's empty answer both arrive as an empty string, and they
  # mean opposite things: an empty array is a repo with no checks, which passes,
  # while output jq cannot read is an answer nobody has, which must not. Kept
  # apart here, because conflating them marks a PR ready over unread checks.
  if ! buckets="$(printf '%s' "$out" | jq -r '.[].bucket' 2>/dev/null)"; then
    note unreachable
    note "      gh pr checks answered with something jq could not read"
    return 0
  fi
  if [ -z "$buckets" ]; then note none; return 0; fi
  failed="$(printf '%s' "$out" | jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | .name' 2>/dev/null)" || failed=""
  if [ -n "$failed" ]; then
    note failing
    while IFS= read -r name; do [ -z "$name" ] || note "      $name"; done <<<"$failed"
    return 0
  fi
  if printf '%s\n' "$buckets" | grep -qx pending; then note pending; return 0; fi
  note green
}

# Classifies the review loop's last iteration against its budget - the one
# answer `review terminal` and doctor's `check_flow_review_terminal` both read,
# rather than each re-deriving which iteration counts as done. Checked with
# the same section_body/required-heading pattern handoff_report already uses,
# not a second implementation of it. Prints the classification word on the
# first line, and for `stop`, the recorded reason on the lines after it.
# Exit status is 0 for ready/stop, non-zero for none/pending/interrupted - a
# single boolean a caller can act on without re-deriving which words count as
# terminal.
review_terminal_state() {
  require_state
  local i b path first rest
  i="$(jq -r '.iteration // 0' "$STATE")"
  b="$(review_budget)"
  if [ "$i" -eq 0 ]; then note none; return 1; fi
  if [ "$i" -lt "$b" ]; then note pending; return 1; fi
  path="$(cmd_review path "$i")"
  if [ ! -f "$path" ] || [ -z "$(section_body "$path" '## Terminal state' | tr -d '[:space:]')" ]; then
    note interrupted
    return 1
  fi
  first="$(section_body "$path" '## Terminal state' | sed -n '1p')"
  rest="$(section_body "$path" '## Terminal state' | tail -n +2)"
  case "$first" in
    ready) note ready; return 0 ;;
    stop)
      note stop
      [ -z "$rest" ] || printf '%s\n' "$rest"
      return 0 ;;
    *) note interrupted; return 1 ;;
  esac
}

cmd_review() {
  local op="${1:-}"
  shift || true
  case "$op" in
    begin)
      require_state
      local n budget
      n=$(( $(jq -r '.iteration // 0' "$STATE") + 1 ))
      budget="$(review_budget)"
      [ "$n" -le "$budget" ] || \
        die "budget of $budget iterations spent - stop the loop and report, do not start another"
      cmd_state set iteration "$n"
      note "$n"
      ;;
    path)
      require_state
      [ $# -le 1 ] || die "usage: orch.sh review path [iteration]"
      local n
      n="${1:-$(jq -r '.iteration // 0' "$STATE")}"
      case "$n" in ''|*[!0-9]*) die "not an iteration number: $n" ;; esac
      # Base 10 explicitly: printf reads a zero-padded argument as octal, and
      # `08` is not a number in base 8.
      n=$((10#$n))
      # Flat, and numbered on across every loop the flow runs: one flow, one
      # trail, and nothing is ever moved aside for a loop that comes later.
      mkdir -p "$REVIEW_DIR"
      printf '%s/iteration-%02d.md\n' "$REVIEW_DIR" "$n"
      ;;
    file)
      require_state
      [ $# -eq 4 ] && [ "$3" = --body-file ] \
        || die "usage: orch.sh review file <major|nit> <title> --body-file <file>"
      local severity="$1" title="$2" body="$4" colour triage url
      case "$severity" in
        major) colour=d93f0b ;;
        nit)   colour=c5def5 ;;
        *) die "not a severity that gets filed: $severity (want major or nit - the loop fixes blocking)" ;;
      esac
      [ -n "$title" ] || die "the title is empty"
      [ -f "$body" ] || die "body file not found: $body"
      severity_label_ensure "review:$severity" "$colour" "Review finding filed at $severity severity"
      triage="$(triage_label_for needs-triage)"
      triage_label_ensure "$triage"
      # The title carries no severity prefix: the label holds it, where triage
      # can change it, and the title reads as an issue.
      url="$(gh issue create --title "$title" --body-file "$body" \
        --label "review:$severity" --label "$triage")" \
        || die "gh could not create the issue"
      # Prints the number alone: the record cites a number, and the caller
      # would otherwise be parsing a URL out of prose every time.
      note "${url##*/}"
      ;;
    ready)
      require_state
      local pr
      pr="$(require_pr)"
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      gh pr ready "$pr" >/dev/null 2>&1 \
        || die "gh could not mark PR #$pr ready - the flow stays in review"
      cmd_state set phase done
      note "$pr"
      ;;
    ci)
      require_state
      local pr started slept=0 elapsed=0 res verdict
      require_ci_knobs
      pr="$(require_pr)"
      started="$(date +%s)"
      while :; do
        # Branch protection's required checks decide it wherever it names any.
        # When nothing required has reported, gh's message cannot tell "this repo
        # requires nothing" from "what it requires has not registered yet" - so
        # the grace is spent waiting on the required set, and only once it runs
        # out does the net widen to every check on the commit. Widening sooner is
        # how an unrelated green check gets mistaken for a required one that
        # never arrived, and the PR marked ready over it.
        res="$(ci_probe "$pr" required)"
        verdict="$(first_line "$res")"
        if [ "$verdict" = none ]; then
          if float_lt "$elapsed" "$ORCH_CI_GRACE"; then ci_tick; continue; fi
          res="$(ci_probe "$pr" all)"
          verdict="$(first_line "$res")"
        fi
        case "$verdict" in
          green)       printf '%s\n' "$res"; return 0 ;;
          # Reported, not fixed: which failure is worth a flake rerun is a
          # judgement, and the budget for it belongs to the flow.
          failing)     printf '%s\n' "$res"; return 1 ;;
          unreachable) printf '%s\n' "$res"; return 1 ;;
          # Only reachable with the grace already spent: nothing required
          # reported, and then nothing at all reported either.
          none)        printf '%s\n' "$res"; return 0 ;;
          pending)
            if float_lt "$elapsed" "$ORCH_CI_TIMEOUT"; then ci_tick; continue; fi
            # Still pending at the cap is an answer we do not have, not a green
            # one. The loop stops rather than marking a PR ready over something
            # nothing ever verified.
            note unreachable
            note "      checks were still pending after ${ORCH_CI_TIMEOUT}s"
            return 1 ;;
          # Unreachable while ci_probe prints one of the five words above, and
          # the arm that keeps it that way: an unrecognised answer with no arm
          # would fall through to the next pass with nothing to wait on, and
          # spin this loop silently on the one command built to be bounded.
          *)
            note unreachable
            note "      unrecognised answer from gh pr checks: $verdict"
            return 1 ;;
        esac
      done
      ;;
    terminal)
      require_state
      [ $# -eq 0 ] || die "usage: orch.sh review terminal"
      review_terminal_state
      ;;
    retire)
      require_state
      [ $# -eq 1 ] || die "usage: orch.sh review retire <n>"
      local n="$1" dest f
      case "$n" in ''|*[!0-9]*) die "not a redo number: $n" ;; esac
      dest="$REVIEW_DIR/pre-redo-$n"
      [ ! -e "$dest" ] || die "$dest already exists - redo_count should only increase"
      mkdir -p "$REVIEW_DIR"
      for f in "$REVIEW_DIR"/iteration-*.md; do
        [ -e "$f" ] || continue
        mkdir -p "$dest"
        mv "$f" "$dest/"
      done
      note "$dest"
      ;;
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|ci|ready|terminal|retire)" ;;
  esac
}

# --- spec -------------------------------------------------------------------

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the three ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
cmd_spec() {
  local op="${1:-}"
  shift || true
  require_state
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment> <file>"
  local file="$1" issue
  issue="$(require_issue)"
  case "$op" in
    fetch)
      # Written beside the target and moved into place only once gh has
      # answered: a failed fetch that left a partial file behind is a body a
      # lens would read as the spec.
      local tmp
      mkdir -p "$(dirname "$file")"
      tmp="$(mktemp "$file.XXXXXX")"
      if ! gh issue view "$issue" --json body --jq .body >"$tmp"; then
        rm -f "$tmp"
        die "gh could not read the body of issue #$issue"
      fi
      mv "$tmp" "$file"
      ;;
    update|comment)
      [ -f "$file" ] || die "body file not found: $file"
      local verb=edit did="replace the body of"
      if [ "$op" = comment ]; then verb=comment; did="comment on"; fi
      # --body-file, never --body: a spec carries tables, fences, and `#nn`
      # references, and a heredoc through a shell is where those get mangled.
      gh issue "$verb" "$issue" --body-file "$file" >/dev/null \
        || die "gh could not $did issue #$issue"
      ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment)" ;;
  esac
}

# --- git / github -----------------------------------------------------------

# Forking a named branch off the default branch has exactly one right answer -
# fetch it, then check it out, falling back to the local ref if origin was
# unreachable - so both branch-create (a flow's own naming and state) and
# branch-off (a quick implementation's, which keeps no state) share it rather
# than each hand-rolling the fetch/checkout-fallback idiom.
checkout_new_branch() {
  local name="$1" base
  if git rev-parse --verify --quiet "$name" >/dev/null; then die "branch $name already exists"; fi
  base="$(default_branch)"
  git fetch --quiet origin "$base" 2>/dev/null || true
  git checkout -q -b "$name" "origin/$base" 2>/dev/null || git checkout -q -b "$name" "$base"
}

cmd_branch_create() {
  require_state
  local slug issue name
  slug="$(jq -r .slug "$STATE")"
  issue="$(require_issue)"
  name="orch/${issue}-${slug}"
  checkout_new_branch "$name"
  cmd_state set branch "$name"
  cmd_state set base_sha "$(git rev-parse HEAD)"
  note "$name"
}

# A quick implementation keeps no state, so it has nothing to derive a name
# from and nothing to record one in - the caller passes the full name and gets
# a checked-out branch back, nothing else.
cmd_branch_off() {
  [ $# -eq 1 ] || die "usage: orch.sh branch-off <name>"
  checkout_new_branch "$1"
  note "$1"
}

cmd_branch() {
  local op="${1:-}"
  shift || true
  case "$op" in
    retire)
      [ $# -eq 2 ] || die "usage: orch.sh branch retire <old> <new>"
      local old="$1" new="$2" upstream="" old_ok=1 new_ok=1
      git rev-parse --verify --quiet "$old" >/dev/null 2>&1 || old_ok=0
      git rev-parse --verify --quiet "$new" >/dev/null 2>&1 || new_ok=0
      if [ "$old_ok" = 1 ] && [ "$new_ok" = 1 ]; then
        die "branch $new already exists"
      elif [ "$old_ok" = 0 ] && [ "$new_ok" = 0 ]; then
        die "branch $old does not exist"
      elif [ "$old_ok" = 1 ]; then
        upstream="$(git rev-parse --abbrev-ref --verify --quiet "$old@{upstream}" 2>/dev/null)" || upstream=""
        git branch -m "$old" "$new"
      else
        # $old is already gone and $new already exists: a previous call's
        # local rename succeeded and it died on the remote push or delete
        # below - resume from there instead of failing on "$old does not
        # exist", the unretryable state issue #63 named. Reaching this state
        # is only possible by way of the upstream branch below, since a
        # no-upstream retire has no later step left to die on - so the
        # remote steps still needing doing is a safe assumption here.
        upstream=origin
      fi
      # A leftover remote ref under the un-suffixed name is exactly what the
      # next implement attempt's branch-create/pr-open will reuse, and their
      # plain push is not a force-push - so the old ref's delete is not
      # optional, and both failures die rather than leaving origin out of
      # sync with what this rename just did locally.
      if [ -n "$upstream" ]; then
        # The rename above is local-only and free to undo - if the push
        # never lands, undoing it is what keeps `$old` a real, retryable
        # branch instead of a name a retry can no longer find.
        git push -q -u origin "$new" \
          || { git branch -m "$new" "$old"; die "could not push $new to origin"; }
        if ! git push -q origin --delete "$old" 2>/dev/null; then
          # Already gone - a previous call's delete already succeeded before
          # something else failed - is not an error to retry into; only a
          # ref that is still there and won't go is.
          git ls-remote --exit-code origin "refs/heads/$old" >/dev/null 2>&1 \
            && die "could not delete origin/$old"
        fi
      fi
      note "$new"
      ;;
    *) die "unknown branch op: ${op:-<none>} (want retire)" ;;
  esac
}

# The publishing boundary a quick implementation calls instead of hardcoding
# `gh issue create` in skill prose - the same reason `review file` owns its
# own `gh issue create` rather than leaving it to whichever skill files a
# finding. Stateless like branch-off: the caller has no flow to record into,
# so the title and body are its own and nothing here remembers them.
cmd_issue_publish() {
  [ $# -eq 2 ] || die "usage: orch.sh issue-publish <title> <body-file>"
  local title="$1" body_file="$2" url
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  url="$(gh issue create --title "$title" --body-file "$body_file")" \
    || die "gh could not create the issue"
  note "${url##*/}"
}

# Pushing a branch and opening a PR against it has exactly one right answer -
# push, then prefix the body with a Closes line so GitHub links the PR as a
# closer (no agent-chosen wording can leave the issue open again), then create
# the PR - so pr-open (a flow's own, draft, recorded into state) and pr-publish
# (a quick implementation's, not a draft, recording nothing) share it rather
# than each hand-rolling the push/Closes-line/gh-pr-create idiom.
open_pr() {
  local branch="$1" base="$2" issue="$3" title="$4" body_file="$5" draft="$6" tmp pr draft_flag=""
  git push -q -u origin "$branch"
  tmp="$(mktemp)"
  { printf 'Closes #%s\n\n' "$issue"; cat "$body_file"; } >"$tmp"
  # Unquoted on purpose: this is either empty or the one literal flag below,
  # never a value with spaces or glob characters to mis-split.
  [ "$draft" = true ] && draft_flag="--draft"
  if ! gh pr create $draft_flag --base "$base" --head "$branch" \
      --title "$title" --body-file "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "gh could not open the PR"
  fi
  rm -f "$tmp"
  pr="$(gh pr view "$branch" --json number --jq .number)"
  printf '%s\n' "$pr"
}

cmd_pr_open() {
  require_state
  [ $# -eq 2 ] || die "usage: orch.sh pr-open <title> <body-file>"
  local title="$1" body_file="$2" issue branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  issue="$(require_issue)"
  branch="$(jq -r '.branch // ""' "$STATE")"
  [ -n "$branch" ] || die "no branch recorded in state"
  # Draft is the honest signal: the review loop has not run yet, so marking it
  # ready is the loop's success condition rather than a comment nobody reads.
  pr="$(open_pr "$branch" "$(default_branch)" "$issue" "$title" "$body_file" true)"
  cmd_state set pr "$pr"
  note "$pr"
}

# The PR-opening boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - the same reason `issue-publish` owns its own
# `gh issue create` rather than leaving it to skill prose. Stateless like
# branch-off and issue-publish: the caller has no flow to record into, and no
# draft to promote later, since a quick implementation's single-pass review
# already ran before this is called.
cmd_pr_publish() {
  [ $# -eq 3 ] || die "usage: orch.sh pr-publish <issue> <title> <body-file>"
  local issue="$1" title="$2" body_file="$3" branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  pr="$(open_pr "$branch" "$(default_branch)" "$issue" "$title" "$body_file" false)"
  note "$pr"
}

# --- redo ---------------------------------------------------------------

# The full `review -> implement` transition: retire the old branch and PR,
# move the old loop's records aside, and reset the state a fresh implement
# attempt needs - never mid-budget, and never over a loop nobody has confirmed
# actually ended. `flake_rerun_used` is deliberately untouched throughout, per
# docs/adr/0007: it is a per-flow allowance, not a per-loop one.
cmd_redo_review() {
  [ $# -eq 0 ] || die "usage: orch.sh redo review"
  require_state
  local phase i b word slug issue branch pr redo_count new_n new_branch msg
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = review ] || die "flow is not at the review phase - nothing to redo back from"
  i="$(jq -r '.iteration // 0' "$STATE")"
  b="$(review_budget)"
  local state; state="$(review_terminal_state)" || true
  word="$(first_line "$state")"
  case "$word" in
    none)
      die "no review loop has run yet - nothing to redo back from; run /orchestrator:next to start one." ;;
    pending)
      die "the review loop hasn't reached its budget yet (iteration $i of budget $b) - that's what /orchestrator:next is for; redo is for after a loop ends." ;;
    interrupted)
      die "the review loop's last iteration ($i) has no recorded terminal state - the session looks interrupted, not stopped. Resume it with /orchestrator:next; redo only runs once a loop actually ends." ;;
    stop) ;;
    *) die "review_terminal_state answered something redo does not know: $word" ;;
  esac

  slug="$(jq -r .slug "$STATE")"
  issue="$(require_issue)"
  branch="$(jq -r '.branch // ""' "$STATE")"
  [ -n "$branch" ] || die "no branch recorded in state"
  pr="$(require_pr)"
  redo_count="$(jq -r '.redo_count // 0' "$STATE")"

  # A previous call at this same redo can have already retired the branch
  # and recorded it here before dying on the PR close below - branch and
  # redo_count are set together right after a real retire, so if the
  # recorded branch already matches what this redo_count's retire would
  # have produced, the retire already happened: resume at closing the PR
  # instead of retiring an already-retired branch a second time, which
  # issue #63 called out by name as not what a retry should do.
  if [ "$redo_count" -gt 0 ] && [ "$branch" = "orch/${issue}-${slug}-redo-${redo_count}" ]; then
    new_n="$redo_count"
    new_branch="$branch"
  else
    new_n=$(( redo_count + 1 ))
    new_branch="orch/${issue}-${slug}-redo-${new_n}"
    cmd_branch retire "$branch" "$new_branch" >/dev/null
    # Recorded immediately, before the gh call below that can still fail:
    # the rename already happened for real, so state.branch has to track it
    # now rather than keep naming a branch that no longer exists if pr
    # close dies and a retry has to find the real current name.
    cmd_state set branch "$new_branch"
    cmd_state set redo_count "$new_n"
  fi

  msg="$(printf 'This PR was closed by /orchestrator:redo.\n\nThe retired branch is now `%s`.\nA new PR will follow once the redone implement phase reaches pr-open again.\n' "$new_branch")"
  gh pr close "$pr" --comment "$msg" >/dev/null || die "gh could not close PR #$pr"

  cmd_review retire "$new_n" >/dev/null

  cmd_state set branch null
  cmd_state set pr null
  cmd_state set base_sha null
  cmd_state set iteration 0
  cmd_state set phase implement
  note "$new_n"
}

# The full `implement -> spec` transition. Defaults to keeping the existing
# spec issue and re-reviewing it as-is - the same path an adopted issue
# already takes through the spec phase's step 0. Only `--new-issue` closes the
# old one and clears state.issue, so to-spec runs again from scratch.
cmd_redo_spec() {
  require_state
  local phase new_issue=0
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = implement ] || die "flow is not at the implement phase - nothing to redo back from"
  case "${1:-}" in
    "") ;;
    --new-issue) new_issue=1; shift ;;
    *) die "usage: orch.sh redo spec [--new-issue]" ;;
  esac
  [ $# -eq 0 ] || die "usage: orch.sh redo spec [--new-issue]"
  if [ "$new_issue" -eq 1 ]; then
    local issue msg
    issue="$(require_issue)"
    msg="$(printf 'This issue was closed by /orchestrator:redo because the spec itself needed to change.\n\nA fresh issue will follow from to-spec in this same flow.\n')"
    gh issue close "$issue" --comment "$msg" >/dev/null || die "gh could not close issue #$issue"
    cmd_state set issue null
  fi
  cmd_state set phase spec
}

cmd_redo() {
  local op="${1:-}"
  shift || true
  case "$op" in
    review) cmd_redo_review "$@" ;;
    spec)   cmd_redo_spec "$@" ;;
    *) die "unknown redo op: ${op:-<none>} (want review|spec)" ;;
  esac
}

# --- lifecycle --------------------------------------------------------------

cmd_status() {
  if [ ! -f "$STATE" ]; then
    note "No active flow. Run /orchestrator:start from an approved plan."
    return 0
  fi
  local slug phase issue branch pr iteration redo_count
  slug="$(jq -r .slug "$STATE")";       phase="$(jq -r .phase "$STATE")"
  issue="$(jq -r '.issue // "-"' "$STATE")";  branch="$(jq -r '.branch // "-"' "$STATE")"
  pr="$(jq -r '.pr // "-"' "$STATE")";  iteration="$(jq -r '.iteration // 0' "$STATE")"
  redo_count="$(jq -r '.redo_count // 0' "$STATE")"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "branch:    $branch"
  note "PR:        $pr"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $(review_budget)"
  # Unconditional, like every other line here: a flow that has never been
  # redone still has an answer - 0 - rather than a line that only appears once
  # something has happened.
  note "redo:      $redo_count"
  note ""
  note "handoffs:"
  local f
  for f in "$HANDOFF_DIR"/*.md; do
    [ -e "$f" ] || { note "  (none yet)"; break; }
    note "  ${f#"$ROOT"/}"
  done
}

# Archive rather than delete: the moment you want a handoff back is precisely
# the moment you just threw it away. The directory is git-excluded anyway.
cmd_archive() {
  require_state
  local slug ts dest entry
  slug="$(jq -r .slug "$STATE")"
  ts="$(date -u +%Y%m%d-%H%M%S)"
  dest="$ORCH/archive/$ts-$slug"
  mkdir -p "$dest"
  for entry in "$ORCH"/*; do
    [ -e "$entry" ] || continue
    if [ "$(basename "$entry")" = "archive" ]; then continue; fi
    mv "$entry" "$dest/"
  done
  note "${dest#"$ROOT"/}"
}

cmd_help() {
  cat <<'USAGE'
orch.sh - deterministic operations for the orchestrator flow

  doctor [--env|--flow]       diagnose the machine, the repo, and the active flow
  mp-skill [name]             path to a mattpocock SKILL.md (or the plugin root)
  default-branch              resolve the base branch feature branches fork from
  init <slug> [--issue N]     start a flow (refuses if one is active); --issue
                              adopts an already-open, ready-for-agent issue N
                              as the flow's spec instead of leaving it unset
  slug <text>                 normalise text to the kebab-case slug init would
                              store - lowercase, non-alphanumeric runs collapsed
                              to a hyphen, trimmed
  state get [key]             print state.json, or one key
  state set <key> <value>     update one key
  handoff path <phase>        print the handoff path for a phase
  handoff validate <file>     check required sections exist and are non-empty
  branch-create               create orch/<issue>-<slug> off the default branch
  branch-off <name>            create and check out <name> off the default
                               branch, recording no state - for a quick
                               implementation, which keeps none
  branch retire <old> <new>   rename <old> aside to <new>, republishing it on
                              origin and deleting the old remote ref, without
                              force-pushing over anything
  issue-publish <title> <body-file>
                              create a GitHub issue, recording no state;
                              prints the number - for a quick implementation
                              that needs one
  pr-open <title> <body-file> push and open a draft PR
  pr-publish <issue> <title> <body-file>
                              push the current branch and open a non-draft PR
                              closing <issue>, recording no state; prints the
                              PR number - for a quick implementation whose
                              single-pass review already ran
  review begin                claim the next iteration, refusing once the
                              flow's budget is spent (5 when none is set)
  review path [n]             record path, .orchestrator/review/iteration-NN.md,
                              creating the directory if it is not there yet
  review file <major|nit> <title> --body-file <file>
                              file a finding as a GitHub issue labelled
                              review:<severity> and the repo's needs-triage,
                              creating the labels if missing; prints the number
  review ci                   classify the PR's checks: green, failing, none, or
                              unreachable; exits non-zero on the last two
  review ready                mark the draft PR ready and set the phase to done
  review terminal             classify the last iteration: none, pending,
                              interrupted, ready, or stop; exits non-zero on
                              the first three
  review retire <n>           move every iteration-*.md into pre-redo-<n>/
  spec fetch <file>           write the spec issue's body to <file>
  spec update <file>          replace the spec issue's body with <file>
  spec comment <file>         post <file> as a comment on the spec issue
  redo review                 retire the branch and PR, reset the loop, and
                              step the flow back to implement - refuses unless
                              the review loop has reached a terminal state
  redo spec [--new-issue]     step the flow back to spec, keeping the existing
                              issue by default; --new-issue closes it and
                              clears state.issue so to-spec starts fresh
  status                      human-readable summary
  archive                     move the live flow into .orchestrator/archive/
USAGE
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    doctor)        cmd_doctor "$@" ;;
    mp-skill)      cmd_mp_skill "$@" ;;
    default-branch) default_branch ;;
    init)          cmd_init "$@" ;;
    slug)          cmd_slug "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    branch-create) cmd_branch_create "$@" ;;
    branch-off)    cmd_branch_off "$@" ;;
    branch)        cmd_branch "$@" ;;
    issue-publish) cmd_issue_publish "$@" ;;
    pr-open)       cmd_pr_open "$@" ;;
    pr-publish)    cmd_pr_publish "$@" ;;
    review)        cmd_review "$@" ;;
    spec)          cmd_spec "$@" ;;
    redo)          cmd_redo "$@" ;;
    status)        cmd_status "$@" ;;
    archive)       cmd_archive "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

main "$@"
