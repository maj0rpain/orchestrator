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

die()  { printf 'orch: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*"; }
now()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository"
readonly ROOT
readonly ORCH="$ROOT/$ORCH_DIR_NAME"
readonly STATE="$ORCH/state.json"
readonly HANDOFF_DIR="$ORCH/handoff"

require_state() {
  [ -f "$STATE" ] || die "no active flow ($ORCH_DIR_NAME/state.json not found). Run /orchestrator:start first."
}

# --- environment ------------------------------------------------------------

# Locate the newest installed mattpocock-skills plugin. Resolved by glob at
# runtime and never pinned: the version in the cache path changes under us.
find_mattpocock() {
  local p
  local -a hits=()
  for p in "$HOME"/.claude/plugins/cache/*/mattpocock-skills/*/skills/engineering/implement/SKILL.md; do
    if [ -f "$p" ]; then hits+=("$p"); fi
  done
  [ ${#hits[@]} -gt 0 ] || return 1
  printf '%s\n' "${hits[@]}" | sort -V | tail -1 | sed 's|/skills/engineering/implement/SKILL.md$||'
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

cmd_precheck() {
  local failed=0 mp
  if [ ! -f "$ROOT/docs/agents/issue-tracker.md" ]; then
    note "FAIL  docs/agents/issue-tracker.md is missing."
    note "      Run /mattpocock-skills:setup-matt-pocock-skills first - to-spec and"
    note "      code-review both read it, so the flow would die at the spec phase."
    failed=1
  else
    note "ok    issue tracker configured"
  fi
  if mp="$(find_mattpocock)"; then
    note "ok    mattpocock-skills found at ${mp/#$HOME/\~}"
  else
    note "FAIL  mattpocock-skills plugin not installed."
    note "      /plugin marketplace add anthropics/claude-plugins"
    note "      /plugin install mattpocock-skills"
    failed=1
  fi
  if command -v gh >/dev/null 2>&1; then
    note "ok    gh CLI present"
  else
    note "FAIL  gh CLI not found - needed to publish specs and open the PR."
    failed=1
  fi
  if command -v jq >/dev/null 2>&1; then
    note "ok    jq present"
  else
    note "FAIL  jq not found - orch.sh needs it."
    failed=1
  fi
  return "$failed"
}

# --- state ------------------------------------------------------------------

cmd_init() {
  local slug="${1:-}"
  [ -n "$slug" ] || die "usage: orch.sh init <slug>"
  slug="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
  [ -n "$slug" ] || die "slug is empty after normalisation"
  if [ -f "$STATE" ]; then
    die "a flow is already active (slug: $(jq -r .slug "$STATE"), phase: $(jq -r .phase "$STATE")).
     One flow at a time - finish it, or run /orchestrator:abort."
  fi
  mkdir -p "$HANDOFF_DIR" "$ORCH/review"
  exclude_orch_dir
  jq -n --arg slug "$slug" --arg now "$(now)" '{
    slug: $slug, phase: "spec", issue: null, branch: null,
    pr: null, base_sha: null, iteration: 0, created: $now, updated: $now
  }' >"$STATE"
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
    validate) cmd_state_validate ;;
    *) die "unknown state op: $op (want get|set|validate)" ;;
  esac
}

# Catch drift between the state file and the world it describes, so a stale
# flow surfaces as one clear message instead of confusion three phases later.
cmd_state_validate() {
  require_state
  local failed=0 phase branch pr
  jq -e . "$STATE" >/dev/null 2>&1 || die "state.json is not valid JSON"

  phase="$(jq -r .phase "$STATE")"
  case " $PHASES " in
    *" $phase "*) note "ok    phase: $phase" ;;
    *) note "FAIL  unknown phase: $phase"; failed=1 ;;
  esac

  branch="$(jq -r '.branch // ""' "$STATE")"
  if [ -n "$branch" ]; then
    if git rev-parse --verify --quiet "$branch" >/dev/null; then
      note "ok    branch: $branch"
    else
      note "FAIL  branch $branch no longer exists. Abort the flow, or recreate it."
      failed=1
    fi
  fi

  pr="$(jq -r '.pr // ""' "$STATE")"
  if [ -n "$pr" ]; then
    local pr_state
    pr_state="$(gh pr view "$pr" --json state --jq .state 2>/dev/null)" || pr_state=""
    case "$pr_state" in
      OPEN)   note "ok    PR #$pr open" ;;
      MERGED) note "ok    PR #$pr merged" ;;
      CLOSED) note "FAIL  PR #$pr is closed."; failed=1 ;;
      *)      note "FAIL  PR #$pr could not be read from GitHub."; failed=1 ;;
    esac
  fi
  return "$failed"
}

# --- handoffs ---------------------------------------------------------------

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
    03-implement.md) printf '%s\n' '## PR' '## Spec issue' '## Base SHA' '## Deviations' ;;
    *) die "unknown handoff file: $1" ;;
  esac
}

section_body() {
  awk -v h="$2" '$0 == h { inside = 1; next } /^## / { inside = 0 } inside { print }' "$1"
}

cmd_handoff() {
  local op="${1:-}"
  shift || true
  case "$op" in
    path)
      [ $# -eq 1 ] || die "usage: orch.sh handoff path <phase>"
      printf '%s/%s\n' "$HANDOFF_DIR" "$(handoff_file_for "$1")"
      ;;
    validate)
      [ $# -eq 1 ] || die "usage: orch.sh handoff validate <file>"
      local file="$1" base failed=0 heading
      [ -f "$file" ] || die "handoff not found: $file"
      base="$(basename "$file")"
      while IFS= read -r heading; do
        if ! grep -qxF "$heading" "$file"; then
          note "FAIL  missing section: $heading"
          failed=1
        elif [ -z "$(section_body "$file" "$heading" | tr -d '[:space:]')" ]; then
          note "FAIL  empty section: $heading"
          failed=1
        else
          note "ok    $heading"
        fi
      done < <(handoff_required "$base")
      return "$failed"
      ;;
    *) die "unknown handoff op: ${op:-<none>} (want path|validate)" ;;
  esac
}

# --- git / github -----------------------------------------------------------

cmd_branch_create() {
  require_state
  local slug issue base name
  slug="$(jq -r .slug "$STATE")"
  issue="$(jq -r '.issue // ""' "$STATE")"
  [ -n "$issue" ] || die "no issue recorded in state - the spec phase must publish one first"
  name="orch/${issue}-${slug}"
  if git rev-parse --verify --quiet "$name" >/dev/null; then die "branch $name already exists"; fi
  base="$(default_branch)"
  git fetch --quiet origin "$base" 2>/dev/null || true
  git checkout -q -b "$name" "origin/$base" 2>/dev/null || git checkout -q -b "$name" "$base"
  cmd_state set branch "$name"
  cmd_state set base_sha "$(git rev-parse HEAD)"
  note "$name"
}

cmd_pr_open() {
  require_state
  [ $# -eq 2 ] || die "usage: orch.sh pr-open <title> <body-file>"
  local title="$1" body_file="$2" branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  branch="$(jq -r '.branch // ""' "$STATE")"
  [ -n "$branch" ] || die "no branch recorded in state"
  git push -q -u origin "$branch"
  # Draft is the honest signal: the review loop has not run yet, so marking it
  # ready is the loop's success condition rather than a comment nobody reads.
  gh pr create --draft --base "$(default_branch)" --head "$branch" \
    --title "$title" --body-file "$body_file" >/dev/null
  pr="$(gh pr view "$branch" --json number --jq .number)"
  cmd_state set pr "$pr"
  note "$pr"
}

# --- lifecycle --------------------------------------------------------------

cmd_status() {
  if [ ! -f "$STATE" ]; then
    note "No active flow. Run /orchestrator:start from an approved plan."
    return 0
  fi
  local slug phase issue branch pr iteration
  slug="$(jq -r .slug "$STATE")";       phase="$(jq -r .phase "$STATE")"
  issue="$(jq -r '.issue // "-"' "$STATE")";  branch="$(jq -r '.branch // "-"' "$STATE")"
  pr="$(jq -r '.pr // "-"' "$STATE")";  iteration="$(jq -r .iteration "$STATE")"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "branch:    $branch"
  note "PR:        $pr"
  note "review:    iteration $iteration"
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

  precheck                    verify tracker config, mattpocock-skills, gh, jq
  mp-skill [name]             path to a mattpocock SKILL.md (or the plugin root)
  default-branch              resolve the base branch feature branches fork from
  init <slug>                 start a flow (refuses if one is active)
  state get [key]             print state.json, or one key
  state set <key> <value>     update one key
  state validate              check state against git/GitHub reality
  handoff path <phase>        print the handoff path for a phase
  handoff validate <file>     check required sections exist and are non-empty
  branch-create               create orch/<issue>-<slug> off the default branch
  pr-open <title> <body-file> push and open a draft PR
  status                      human-readable summary
  archive                     move the live flow into .orchestrator/archive/
USAGE
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    precheck)      cmd_precheck "$@" ;;
    mp-skill)      cmd_mp_skill "$@" ;;
    default-branch) default_branch ;;
    init)          cmd_init "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    branch-create) cmd_branch_create "$@" ;;
    pr-open)       cmd_pr_open "$@" ;;
    status)        cmd_status "$@" ;;
    archive)       cmd_archive "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

main "$@"
