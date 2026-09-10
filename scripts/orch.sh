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

# --- doctor -----------------------------------------------------------------
#
# One diagnostic replacing the two health checks that came before it. Scopes are
# named for the content they cover, never for the caller that asks - `--env` and
# `--flow`, not `--preflight` and `--status` - so a check's home does not move
# when a caller changes.
#
# Every check reports through the reporter trio and always returns 0: the exit
# status comes from the FAIL counter alone. doctor is the thing you run when the
# world is already broken, so no single check may abort the report.

D_OK=0
D_WARN=0
D_FAIL=0
D_GROUPS=0

d_head() { if [ "$D_GROUPS" -gt 0 ]; then note ""; fi; D_GROUPS=$((D_GROUPS + 1)); note "$1"; }
d_ok()   { note "ok    $1"; D_OK=$((D_OK + 1)); }
d_warn() { note "warn  $1"; D_WARN=$((D_WARN + 1)); }
d_fail() { note "FAIL  $1"; D_FAIL=$((D_FAIL + 1)); }

# Remedies are commands, verbatim, never prose: a fix you have to translate out
# of a sentence before you can run it is a fix you postpone.
d_remedy() { local l; for l in "$@"; do note "      $l"; done; }

h_tools()  { d_head "tools"; }
h_auth()   { d_head "auth & remotes"; }
h_plugin() { d_head "plugin environment"; }
h_repo()   { d_head "repo config"; }
h_flow()   { d_head "flow state"; }

# Space-separated in, comma-separated out: a list reads better in a sentence.
d_join() {
  local out="" x
  for x in $1; do
    if [ -n "$out" ]; then out="$out, $x"; else out="$x"; fi
  done
  printf '%s\n' "$out"
}

# Gates. A check whose answer is unavailable reports *skip* rather than a FAIL it
# derived from not knowing, and the skipped group collapses into a single warn
# naming the cause - N warns, or worse N invented FAILs, would bury the one real
# problem underneath them.
D_GH=""            # "ok", or the reason GitHub could not be asked
D_REPO=""          # "<owner/name> <default branch>" as GitHub reports them
D_MP=""            # the mattpocock-skills plugin root, or empty
D_JQ=""            # "ok", or empty when jq is missing
D_GH_SKIPPED=0
D_MP_SKIPPED=0
D_JQ_SKIPPED=0

d_skip_line() {
  local n="$1" noun="$2" cause="$3" word="checks"
  if [ "$n" -eq 0 ]; then return 0; fi
  if [ "$n" -eq 1 ]; then word="check"; fi
  # No remedy: reconnecting to a network is not a command.
  d_warn "$n $noun $word skipped: $cause"
}

d_skip_report() {
  if [ $((D_GH_SKIPPED + D_MP_SKIPPED + D_JQ_SKIPPED)) -eq 0 ]; then return 0; fi
  note ""
  d_skip_line "$D_GH_SKIPPED" "GitHub" "$D_GH"
  d_skip_line "$D_MP_SKIPPED" "skill"  "mattpocock-skills is not installed"
  d_skip_line "$D_JQ_SKIPPED" "flow"   "jq is not installed"
}

# Ask GitHub once, up front: `gh auth status` doubles as the reachability probe
# and one repo view answers two checks. Telling "not authenticated" from "could
# not connect" is the whole basis of the severity rule, and the only signal gh
# offers for it is the text of the failure.
d_probe() {
  local scope="$1" out
  if command -v jq >/dev/null 2>&1; then D_JQ=ok; fi
  D_MP="$(find_mattpocock)" || D_MP=""
  if ! command -v gh >/dev/null 2>&1; then D_GH="gh is not installed"; return 0; fi
  if out="$(gh auth status 2>&1)"; then
    D_GH=ok
  else
    case "$out" in
      *"dial tcp"*|*"lookup "*|*"connection refused"*|*"network is unreachable"*|*imeout*)
        D_GH="GitHub is not reachable" ;;
      *) D_GH="not authenticated" ;;
    esac
  fi
  if [ "$D_GH" = ok ] && [ "$scope" != flow ]; then
    D_REPO="$(gh repo view --json nameWithOwner,defaultBranchRef \
      --jq '.nameWithOwner + " " + (.defaultBranchRef.name // "")' 2>/dev/null)" || D_REPO=""
  fi
}

# tools ----------------------------------------------------------------------

check_git() {
  if command -v git >/dev/null 2>&1; then d_ok "git present"; return 0; fi
  d_fail "git not found."
  d_remedy "brew install git    # or your platform's package manager"
}

check_gh() {
  if command -v gh >/dev/null 2>&1; then d_ok "gh present"; return 0; fi
  d_fail "gh not found - the spec phase publishes the issue and the PR through it."
  d_remedy "brew install gh    # or your platform's package manager"
}

# Every state operation in this file needs jq, which makes "jq is missing" the
# one message that has to survive without it.
check_jq() {
  if [ "$D_JQ" = ok ]; then d_ok "jq present"; return 0; fi
  d_fail "jq not found - orch.sh reads and writes state.json with it."
  d_remedy "brew install jq    # or your platform's package manager"
}

# A warn, not a FAIL: macOS still ships 3.2 as /bin/bash, and the flow works
# there. The empty-array expansion in find_mattpocock is the known 3.2 landmine.
check_bash() {
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then d_ok "bash ${BASH_VERSION%%(*}"; return 0; fi
  d_warn "bash ${BASH_VERSION%%(*} - orch.sh is written for 4.0 and up."
  d_remedy "brew install bash"
}

# auth & remotes -------------------------------------------------------------

check_origin() {
  local url
  if url="$(git remote get-url origin 2>/dev/null)" && [ -n "$url" ]; then
    d_ok "origin: $url"
    return 0
  fi
  d_fail "no origin remote - the flow pushes the branch and opens the PR there."
  d_remedy "git remote add origin https://github.com/<owner>/<repo>.git"
}

check_gh_auth() {
  case "$D_GH" in
    ok) d_ok "gh authenticated" ;;
    "not authenticated")
      d_fail "gh is not authenticated."
      d_remedy "gh auth login" ;;
    *) D_GH_SKIPPED=$((D_GH_SKIPPED + 1)) ;;
  esac
}

check_gh_repo() {
  if [ "$D_GH" != ok ]; then D_GH_SKIPPED=$((D_GH_SKIPPED + 1)); return 0; fi
  if [ -n "$D_REPO" ]; then d_ok "repo: ${D_REPO%% *}"; return 0; fi
  d_fail "gh cannot resolve this repo - origin may point somewhere you cannot see."
  d_remedy "git remote set-url origin https://github.com/<owner>/<repo>.git"
}

# Worth its own line because getting it wrong is silent: default_branch falls
# back to a local pointer and then to the literal "main", and a feature branch
# forked from the wrong place looks fine until review.
check_default_branch() {
  if [ "$D_GH" != ok ]; then D_GH_SKIPPED=$((D_GH_SKIPPED + 1)); return 0; fi
  local b=""
  case "$D_REPO" in *" "*) b="${D_REPO#* }" ;; esac
  if [ -n "$b" ]; then d_ok "default branch: $b (from GitHub)"; return 0; fi
  d_warn "default branch not resolved from GitHub - falling back to $(default_branch)."
  d_remedy "git remote set-head origin --auto"
}

# plugin environment ---------------------------------------------------------

check_mattpocock() {
  if [ -n "$D_MP" ]; then d_ok "mattpocock-skills: ${D_MP/#$HOME/\~}"; return 0; fi
  d_fail "mattpocock-skills is not installed - the flow reads its skills directly."
  d_remedy "/plugin marketplace add anthropics/claude-plugins" \
           "/plugin install mattpocock-skills"
}

# The check that justifies the feature. find_mattpocock probes a single skill
# file to decide the whole plugin is present, so a partial or restructured
# install passes and the flow then dies at the phase that needed the missing
# one - by which point the session that could have fixed it has been cleared.
MP_SKILLS="to-spec implement code-review handoff"

check_skills() {
  if [ -z "$D_MP" ]; then D_MP_SKIPPED=$((D_MP_SKIPPED + 1)); return 0; fi
  local name p missing="" found
  for name in $MP_SKILLS; do
    found=""
    for p in "$D_MP/skills"/*/"$name"/SKILL.md; do
      if [ -f "$p" ]; then found=1; break; fi
    done
    if [ -z "$found" ]; then missing="$missing $name"; fi
  done
  if [ -z "$missing" ]; then d_ok "every skill the flow reads resolves"; return 0; fi
  d_fail "mattpocock skills missing: $(d_join "$missing")"
  d_remedy "/plugin marketplace update claude-plugins" \
           "/plugin install mattpocock-skills"
}

check_plugin_root() {
  if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ]; then d_ok "CLAUDE_PLUGIN_ROOT set"; return 0; fi
  # No remedy, because nothing is broken: unset just means orch.sh was run by
  # hand rather than through one of the plugin's commands.
  d_warn "CLAUDE_PLUGIN_ROOT is not set - expected outside a Claude session."
}

# repo config ----------------------------------------------------------------

check_tracker_doc() {
  if [ -f "$ROOT/docs/agents/issue-tracker.md" ]; then d_ok "issue tracker configured"; return 0; fi
  d_fail "docs/agents/issue-tracker.md is missing - to-spec and code-review both read it."
  d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
}

# Parsed, never hardcoded. That file documents its right-hand column as editable,
# so a hardcoded list of the five canonical names would make doctor confidently
# wrong in exactly the repos that customised themselves - the worst thing a
# diagnostic can be. The separator row is what ends the header: everything above
# it is column titles, everything below it is data.
triage_labels() {
  [ -f "$ROOT/$LABELS_DOC" ] || return 0
  awk -F'|' '
    /^[[:space:]]*\|/ {
      if (NF < 3) next
      s = $3
      gsub(/`/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      if (s ~ /^:?-+:?$/) { seen_separator = 1; next }
      if (!seen_separator || s == "") next
      print s
    }' "$ROOT/$LABELS_DOC"
}

check_labels_doc() {
  local n
  n="$(triage_labels | grep -c .)" || n=0
  if [ "$n" -gt 0 ]; then d_ok "$n triage labels documented in $LABELS_DOC"; return 0; fi
  d_fail "$LABELS_DOC lists no triage labels - the spec phase labels its issue from it."
  d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
}

# The other check that justifies the feature: the spec phase applies a label at
# `gh issue create`, so a label the repo does not have kills the phase after the
# whole to-spec exchange has already been spent.
check_labels_exist() {
  if [ "$D_GH" != ok ]; then D_GH_SKIPPED=$((D_GH_SKIPPED + 1)); return 0; fi
  local want have missing="" l
  want="$(triage_labels)" || want=""
  # Nothing to compare against, and check_labels_doc has already said so. One
  # problem earns one FAIL, never a second derived from the first.
  [ -n "$want" ] || return 0
  if ! have="$(gh label list --limit 200 --json name --jq '.[].name' 2>/dev/null)"; then
    d_warn "the repo's labels could not be listed."
    return 0
  fi
  for l in $want; do
    if ! printf '%s\n' "$have" | grep -qxF "$l"; then missing="$missing $l"; fi
  done
  if [ -z "$missing" ]; then d_ok "every documented triage label exists on the repo"; return 0; fi
  d_fail "triage labels missing from the repo: $(d_join "$missing")"
  for l in $missing; do d_remedy "gh label create $l"; done
}

check_git_exclude() {
  local ex
  ex="$(git rev-parse --git-dir)/info/exclude"
  if grep -qxF "$ORCH_DIR_NAME/" "$ex" 2>/dev/null; then
    d_ok "$ORCH_DIR_NAME/ is git-excluded"
    return 0
  fi
  # A warn, not a FAIL: init writes this line, so it only bites someone who
  # arrived mid-flow in a repo that is not theirs.
  d_warn "$ORCH_DIR_NAME/ is not git-excluded - flow state would show as untracked."
  d_remedy "printf '%s\\n' '$ORCH_DIR_NAME/' >>\"\$(git rev-parse --git-dir)/info/exclude\""
}

ENV_CHECKS="
h_tools  check_git check_gh check_jq check_bash
h_auth   check_origin check_gh_auth check_gh_repo check_default_branch
h_plugin check_mattpocock check_skills check_plugin_root
h_repo   check_tracker_doc check_labels_doc check_labels_exist check_git_exclude
"

# flow state -----------------------------------------------------------------

# Every flow check reads state.json, so a missing jq invalidates all of them at
# once. Gate them as a group rather than letting five checks each guess.
d_flow_gate() {
  if [ "$D_JQ" = ok ]; then return 0; fi
  D_JQ_SKIPPED=$((D_JQ_SKIPPED + 1))
  return 1
}

check_state_phase() {
  d_flow_gate || return 0
  if ! jq -e . "$STATE" >/dev/null 2>&1; then
    d_fail "$ORCH_DIR_NAME/state.json is not valid JSON."
    d_remedy "/orchestrator:abort"
    return 0
  fi
  local phase
  phase="$(jq -r '.phase // ""' "$STATE")"
  case " $PHASES " in
    *" $phase "*) d_ok "phase: $phase" ;;
    *) d_fail "unknown phase: $phase (want one of: $PHASES)"
       d_remedy "/orchestrator:abort" ;;
  esac
}

check_flow_branch() {
  d_flow_gate || return 0
  local branch
  branch="$(jq -r '.branch // ""' "$STATE")"
  if [ -z "$branch" ]; then d_ok "branch: not created yet"; return 0; fi
  if git rev-parse --verify --quiet "$branch" >/dev/null; then d_ok "branch: $branch"; return 0; fi
  d_fail "branch $branch no longer exists - the flow has nothing left to build on."
  d_remedy "/orchestrator:abort"
}

# Only from the phase that pushes onwards: before implement, not having pushed
# is correct, and a warning about correct state is how people learn to skim past
# the word.
check_flow_upstream() {
  d_flow_gate || return 0
  local phase branch
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$phase" in implement|review|done) ;; *) return 0 ;; esac
  branch="$(jq -r '.branch // ""' "$STATE")"
  [ -n "$branch" ] || return 0
  # origin/<branch> specifically, not just any upstream: branch-create forks off
  # origin/<default>, which leaves that as the upstream until the first push. An
  # ok there would report a branch nobody can see as pushed.
  local upstream=""
  upstream="$(git rev-parse --abbrev-ref --verify --quiet "$branch@{upstream}" 2>/dev/null)" || upstream=""
  if [ "$upstream" = "origin/$branch" ]; then d_ok "upstream: $upstream"; return 0; fi
  d_warn "branch $branch is not on origin yet."
  d_remedy "git push -u origin $branch"
}

check_flow_pr() {
  d_flow_gate || return 0
  local pr pr_state
  pr="$(jq -r '.pr // ""' "$STATE")"
  if [ -z "$pr" ]; then d_ok "PR: not opened yet"; return 0; fi
  if [ "$D_GH" != ok ]; then D_GH_SKIPPED=$((D_GH_SKIPPED + 1)); return 0; fi
  pr_state="$(gh pr view "$pr" --json state --jq .state 2>/dev/null)" || pr_state=""
  case "$pr_state" in
    OPEN)   d_ok "PR #$pr open" ;;
    MERGED) d_ok "PR #$pr merged" ;;
    CLOSED) d_fail "PR #$pr is closed."; d_remedy "gh pr reopen $pr" ;;
    *)      d_fail "PR #$pr could not be read from GitHub."; d_remedy "gh pr view $pr" ;;
  esac
}

# Pure reuse: what makes a handoff valid lives in handoff_required and
# section_body, and a second statement of it here is how the two answers drift.
# Which handoffs are due is mechanical - phase names what runs *next*, so every
# earlier phase has already written one.
check_flow_handoffs() {
  d_flow_gate || return 0
  local phase files f path problems line
  phase="$(jq -r '.phase // ""' "$STATE")"
  case "$phase" in
    spec)        files="01-plan.md" ;;
    implement)   files="01-plan.md 02-spec.md" ;;
    review|done) files="01-plan.md 02-spec.md 03-implement.md" ;;
    *) return 0 ;;
  esac
  for f in $files; do
    path="$HANDOFF_DIR/$f"
    if [ ! -f "$path" ]; then
      d_fail "handoff $f is missing - the phase that writes it has already run."
      d_remedy "/orchestrator:redo"
      continue
    fi
    problems="$(handoff_problems "$path")" || true
    if [ -z "$problems" ]; then d_ok "handoff $f complete"; continue; fi
    while IFS= read -r line; do d_fail "handoff $f: $line"; done <<<"$problems"
    d_remedy "/orchestrator:redo"
  done
}

FLOW_CHECKS="
h_flow check_state_phase check_flow_branch check_flow_upstream check_flow_pr check_flow_handoffs
"

d_run() {
  local entry
  for entry in $1; do
    # `|| true` on purpose: a check that blows up must cost its own line, not
    # the rest of the report.
    "$entry" || true
  done
}

cmd_doctor() {
  local scope=both
  [ $# -le 1 ] || die "usage: orch.sh doctor [--env|--flow]"
  case "${1:-}" in
    "")     scope=both ;;
    --env)  scope=env ;;
    --flow) scope=flow ;;
    *)      die "unknown doctor flag: $1 (want --env or --flow)" ;;
  esac

  d_probe "$scope"
  if [ "$scope" != flow ]; then d_run "$ENV_CHECKS"; fi
  if [ "$scope" != env ]; then
    # --flow asks about a flow specifically, so having none is a failure there.
    # Bare doctor did not ask, so it states the absence and carries on: an empty
    # answer must never be mistaken for a healthy one.
    if [ "$scope" = flow ]; then require_state; fi
    if [ -f "$STATE" ]; then
      d_run "$FLOW_CHECKS"
    else
      h_flow
      d_ok "no active flow"
    fi
  fi

  d_skip_report
  note ""
  note "$D_OK ok, $D_WARN warn, $D_FAIL FAIL"
  [ "$D_FAIL" -eq 0 ] || return 1
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
    *) die "unknown state op: $op (want get|set)" ;;
  esac
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

# The single statement of what a valid handoff is. doctor's flow-state check
# reads the same answer rather than writing a second one that can drift.
handoff_problems() {
  local file="$1" base heading failed=0
  base="$(basename "$file")"
  while IFS= read -r heading; do
    if ! grep -qxF "$heading" "$file"; then
      printf 'missing section: %s\n' "$heading"
      failed=1
    elif [ -z "$(section_body "$file" "$heading" | tr -d '[:space:]')" ]; then
      printf 'empty section: %s\n' "$heading"
      failed=1
    fi
  done < <(handoff_required "$base")
  return "$failed"
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
      local file="$1" problems line
      [ -f "$file" ] || die "handoff not found: $file"
      problems="$(handoff_problems "$file")" || true
      if [ -z "$problems" ]; then
        note "ok    $(basename "$file"): every required section is present"
        return 0
      fi
      while IFS= read -r line; do note "FAIL  $line"; done <<<"$problems"
      return 1
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

  doctor [--env|--flow]       diagnose the machine, the repo, and the active flow
  mp-skill [name]             path to a mattpocock SKILL.md (or the plugin root)
  default-branch              resolve the base branch feature branches fork from
  init <slug>                 start a flow (refuses if one is active)
  state get [key]             print state.json, or one key
  state set <key> <value>     update one key
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
    doctor)        cmd_doctor "$@" ;;
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
