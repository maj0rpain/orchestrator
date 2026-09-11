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

# Lists inside doctor are newline-separated, never space-separated: a triage
# label may legally contain a space, and splitting one on whitespace is how a
# diagnostic ends up telling you to create a label called "needs".
d_append() {
  if [ -n "$1" ]; then printf '%s\n%s' "$1" "$2"; else printf '%s' "$2"; fi
}

# Newline-separated in, comma-separated out: a list reads better in a sentence.
d_join() {
  local out="" x
  while IFS= read -r x; do
    if [ -z "$x" ]; then continue; fi
    if [ -n "$out" ]; then out="$out, $x"; else out="$x"; fi
  done <<<"$1"
  printf '%s\n' "$out"
}

# Gates. A check whose answer is unavailable reports *skip* rather than a FAIL it
# derived from not knowing, and the skipped group collapses into a single warn
# naming the cause - N warns, or worse N invented FAILs, would bury the one real
# problem underneath them.
D_GH=""            # "ok", or the reason GitHub could not be asked
D_REPO_NAME=""     # owner/name, as GitHub resolves it
D_REPO_BRANCH=""   # the default branch, as GitHub reports it
D_MP=""            # the mattpocock-skills plugin root, or empty
D_JQ=""            # "ok", or empty when jq is missing
D_STATE=""         # "ok" when state.json parses, or empty
D_GH_SKIPPED=0
D_MP_SKIPPED=0
D_JQ_SKIPPED=0

# A check that needed an answer it could not get counts itself as skipped and
# says nothing of its own, so the group collapses to one line. $1 is the gate's
# answer - "ok" opens it - and $2 names the counter the shut gate collects into.
# Indirect assignment rather than a nameref: bash 3.2 has none, and the bash
# check below promises this file still runs there.
d_gate() {
  if [ "$1" = ok ]; then return 0; fi
  printf -v "$2" '%d' "$(( ${!2} + 1 ))"
  return 1
}

d_gh_gate() { d_probe_gh; d_gate "$D_GH" D_GH_SKIPPED; }

d_skip_line() {
  local n="$1" noun="$2" cause="$3" word="checks"
  if [ "$n" -eq 0 ]; then return 0; fi
  if [ "$n" -eq 1 ]; then word="check"; fi
  # No remedy: reconnecting to a network is not a command.
  d_warn "$n $noun $word skipped: $cause"
}

d_skip_report() {
  if [ $((D_GH_SKIPPED + D_MP_SKIPPED + D_JQ_SKIPPED)) -eq 0 ]; then return 0; fi
  d_head "skipped"
  d_skip_line "$D_GH_SKIPPED" "GitHub" "$D_GH"
  d_skip_line "$D_MP_SKIPPED" "skill"  "mattpocock-skills is not installed"
  d_skip_line "$D_JQ_SKIPPED" "flow"   "jq is not installed"
}

# Ask GitHub at most once, and only when something actually needs it: `gh auth
# status` doubles as the reachability probe. Telling "not authenticated" from
# "could not connect" is the whole basis of the severity rule, and the only
# signal gh offers for it is the text of the failure.
d_probe_gh() {
  local out
  if [ -n "$D_GH" ]; then return 0; fi
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
}

d_probe() {
  local scope="$1" view
  if command -v jq >/dev/null 2>&1; then D_JQ=ok; fi
  # A state file that does not parse invalidates every flow check at once.
  # Settled here so that d_run_flow can report it once, ahead of the list, and
  # the checks that would each have run jq at the same broken file never run.
  if [ "$scope" != env ] && [ "$D_JQ" = ok ] && [ -f "$STATE" ] \
     && jq -e . "$STATE" >/dev/null 2>&1; then
    D_STATE=ok
  fi
  # The flow scope runs on every /orchestrator:next and every status, and a flow
  # with no PR recorded has nothing to ask GitHub. It reaches gh through
  # d_gh_gate instead, which probes on first use, so that run costs no round trip.
  if [ "$scope" = flow ]; then return 0; fi
  D_MP="$(find_mattpocock)" || D_MP=""
  d_probe_gh
  if [ "$D_GH" = ok ]; then
    view="$(gh repo view --json nameWithOwner,defaultBranchRef \
      --jq '.nameWithOwner, (.defaultBranchRef.name // "")' 2>/dev/null)" || view=""
    D_REPO_NAME="$(first_line "$view")"
    D_REPO_BRANCH="$(printf '%s\n' "$view" | sed -n 2p)"
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
# there - find_mattpocock avoids arrays precisely so that it keeps doing so.
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
    *) d_gate "$D_GH" D_GH_SKIPPED || true ;;
  esac
}

check_gh_repo() {
  d_gh_gate || return 0
  if [ -n "$D_REPO_NAME" ]; then d_ok "repo: $D_REPO_NAME"; return 0; fi
  d_fail "gh cannot resolve this repo - origin may point somewhere you cannot see."
  d_remedy "git remote set-url origin https://github.com/<owner>/<repo>.git"
}

# Worth its own line because getting it wrong is silent: default_branch falls
# back to a local pointer and then to the literal "main", and a feature branch
# forked from the wrong place looks fine until review.
check_default_branch() {
  d_gh_gate || return 0
  # Silent when the repo itself did not resolve: check_gh_repo has already said
  # so, and a second line derived from the first buries it.
  [ -n "$D_REPO_NAME" ] || return 0
  if [ -n "$D_REPO_BRANCH" ]; then d_ok "default branch: $D_REPO_BRANCH (from GitHub)"; return 0; fi
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
  d_gate "${D_MP:+ok}" D_MP_SKIPPED || return 0
  local name p missing="" found
  for name in $MP_SKILLS; do
    found=""
    for p in "$D_MP/skills"/*/"$name"/SKILL.md; do
      if [ -f "$p" ]; then found=1; break; fi
    done
    if [ -z "$found" ]; then missing="$(d_append "$missing" "$name")"; fi
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
    # A table ends where the pipes stop. Without this, cols still holds the
    # previous table width when the next table begins - a header row arrives a
    # line before the separator that would correct it - so a narrower second
    # table anywhere in the doc leaks its heading out as a label name.
    !/^[[:space:]]*\|/ { cols = 0 }
    /^[[:space:]]*\|/ {
      s = $3
      gsub(/`/, "", s)
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      # The separator row settles the width for the whole table, and only it
      # can. Every separator cell holds a dash run, so an empty field at the
      # end of that row is unambiguously the one a trailing pipe leaves behind
      # - whereas on a data row an empty last field is equally well an empty
      # last cell, and guessing there costs a real label. Markdown lets a row
      # drop its trailing pipe; the leading one the match already requires.
      if (s ~ /^:?-+:?$/) {
        last = $NF
        sub(/^[[:space:]]+/, "", last)
        sub(/[[:space:]]+$/, "", last)
        cols = NF - 1
        if (last == "") cols--
        next
      }
      # cols stays 0 until the separator row, which drops the header with it.
      # Under three columns this is a table of some other shape, where $3 is
      # whichever column happens to sit last and its Meaning text would be read
      # out as a label name and demanded of the repo. A diagnostic may fail to
      # parse a doc; it may not invent an answer from one.
      if (cols < 3) next
      if (s == "") next
      print s
    }' "$ROOT/$LABELS_DOC"
}

# The local name for one of the five triage roles - the right-hand column of
# the row whose left-hand column names it. A repo that customised its
# vocabulary customised this, and filing under the canonical name there would
# create a second label the repo's triage never reads. The role name itself is
# the answer where the doc is missing or does not list it.
triage_label_for() {
  local role="$1" name=""
  if [ -f "$ROOT/$LABELS_DOC" ]; then
    name="$(awk -F'|' -v role="$role" '
      /^[[:space:]]*\|/ {
        l = $2; gsub(/`/, "", l); sub(/^[[:space:]]+/, "", l); sub(/[[:space:]]+$/, "", l)
        r = $3; gsub(/`/, "", r); sub(/^[[:space:]]+/, "", r); sub(/[[:space:]]+$/, "", r)
        if (l == role && r != "") { print r; exit }
      }' "$ROOT/$LABELS_DOC")"
  fi
  printf '%s\n' "${name:-$role}"
}

check_labels_doc() {
  local n
  if [ ! -f "$ROOT/$LABELS_DOC" ]; then
    d_fail "$LABELS_DOC is missing - the spec phase labels its issue from it."
    d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
    return 0
  fi
  n="$(triage_labels | grep -c .)" || n=0
  if [ "$n" -gt 0 ]; then d_ok "$n triage labels documented in $LABELS_DOC"; return 0; fi
  d_fail "$LABELS_DOC lists no triage labels - the spec phase labels its issue from it."
  d_remedy "/mattpocock-skills:setup-matt-pocock-skills"
}

# The other check that justifies the feature: the spec phase applies a label at
# `gh issue create`, so a label the repo does not have kills the phase after the
# whole to-spec exchange has already been spent.
check_labels_exist() {
  d_gh_gate || return 0
  local want have missing="" l n
  want="$(triage_labels)" || want=""
  # Nothing to compare against, and check_labels_doc has already said so. One
  # problem earns one FAIL, never a second derived from the first.
  [ -n "$want" ] || return 0
  if ! have="$(gh label list --limit "$LABEL_LIMIT" --json name --jq '.[].name' 2>/dev/null)"; then
    # One check, one cause, one warn: GitHub answered the auth probe and then
    # would not answer this, which is an absent answer rather than a "no".
    d_warn "the repo's labels could not be listed."
    return 0
  fi
  while IFS= read -r l; do
    if [ -z "$l" ]; then continue; fi
    if ! printf '%s\n' "$have" | grep -qxF "$l"; then missing="$(d_append "$missing" "$l")"; fi
  done <<<"$want"
  if [ -z "$missing" ]; then d_ok "every documented triage label exists on the repo"; return 0; fi
  # Found every one of them is a definitive answer whatever the page held, so
  # the cut-off caveat only ever qualifies a *negative*: a label named as
  # missing because it fell past the boundary is exactly the FAIL that teaches
  # someone to stop reading the word.
  n="$(printf '%s\n' "$have" | grep -c .)" || n=0
  if [ "$n" -ge "$LABEL_LIMIT" ]; then
    d_warn "the repo has more than $LABEL_LIMIT labels - cannot confirm: $(d_join "$missing")"
    return 0
  fi
  d_fail "triage labels missing from the repo: $(d_join "$missing")"
  # Quoted, because a label that needs quoting is exactly the one you would
  # paste wrong.
  while IFS= read -r l; do d_remedy "gh label create \"$l\""; done <<<"$missing"
}

check_git_exclude() {
  local ex
  # Unguarded, and unreachable: the script died at load time if this were not a
  # git repo, so a check for one could only ever report a world that cannot
  # exist. Not covered by d_run's abort warn either - a check runs as the left
  # operand of ||, which disables errexit for its whole body, so a failure here
  # would carry on with a wrong path rather than stop.
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

# Every check below reads state.json through jq, so a missing jq and a file that
# will not parse each settle all of them at once. Both are decided in d_run_flow,
# before any of them runs, rather than in a preamble each check has to remember:
# a check that forgot would run jq at a broken file and report a confident wrong
# ok, and the review group deferred to #2 is meant to be an append to the list.
# Reaching a check at all is now the proof that its preconditions held.

check_state_phase() {
  local phase
  phase="$(jq -r '.phase // ""' "$STATE")"
  case " $PHASES " in
    *" $phase "*) d_ok "phase: $phase" ;;
    *) d_fail "unknown phase: $phase (want one of: $PHASES)"
       d_remedy "/orchestrator:abort" ;;
  esac
}

check_flow_branch() {
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
  local pr pr_state
  pr="$(jq -r '.pr // ""' "$STATE")"
  if [ -z "$pr" ]; then d_ok "PR: not opened yet"; return 0; fi
  d_gh_gate || return 0
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
    problems="$(handoff_report "$path" | grep -v '^ok ' || true)"
    if [ -z "$problems" ]; then d_ok "handoff $f complete"; continue; fi
    while IFS= read -r line; do d_fail "handoff $f: ${line#FAIL }"; done <<<"$problems"
    d_remedy "/orchestrator:redo"
  done
}

FLOW_CHECKS="
h_flow check_state_phase check_flow_branch check_flow_upstream check_flow_pr check_flow_handoffs
"

# A registry's entries, one per line. Splitting a whitespace-separated list is
# where a stray glob character would silently drop a check, so globbing goes off
# across the split and is *restored* rather than switched on - a caller may have
# its own set -f window, and handing globbing back inside one is the very thing
# the window exists to prevent. bash cannot return an argument list from a
# function, so the entries come back newline-separated and callers read them;
# that also keeps this dance in one place rather than at every call site.
d_entries() {
  local glob
  case "$-" in *f*) glob=off ;; *) glob=on ;; esac
  set -f
  set -- $1
  if [ "$glob" = on ]; then set +f; fi
  if [ $# -gt 0 ]; then printf '%s\n' "$@"; fi
}

# How many checks a registry stands for, so a skip line can say so without
# anyone keeping the number in their head. Headers are not checks.
d_count() {
  local n=0 e
  while IFS= read -r e; do
    case "$e" in ""|h_*) ;; *) n=$((n + 1)) ;; esac
  done <<<"$(d_entries "$1")"
  printf '%s\n' "$n"
}

# The gate the flow checks used to carry one at a time, hoisted to the list.
d_run_flow() {
  if [ "$D_JQ" = ok ] && [ "$D_STATE" = ok ]; then
    d_run "$FLOW_CHECKS"
    return 0
  fi
  # Neither path below reaches a check, so neither gets the header out of the
  # registry the way the dispatch above does - and a skip line or a FAIL still
  # belongs under "flow state" like everything else.
  h_flow
  if [ "$D_JQ" != ok ]; then
    D_JQ_SKIPPED=$((D_JQ_SKIPPED + $(d_count "$FLOW_CHECKS")))
    return 0
  fi
  # One problem earns one FAIL. Every check reads this file, so there is nothing
  # left to say about it and nothing that could be said honestly.
  d_fail "$ORCH_DIR_NAME/state.json is not valid JSON."
  d_remedy "/orchestrator:abort"
}

d_run() {
  local entry
  while IFS= read -r entry; do
    if [ -z "$entry" ]; then continue; fi
    # Catches a check that returns non-zero, and nothing else: being the left
    # operand of || suppresses errexit for the whole body, so a check that hits
    # a failing command does not abort here - it carries on with whatever state
    # that left behind. Every check is written to return 0, which is why this
    # arm stays quiet in practice; keeping errexit live while still collecting
    # a status needs the check launched as a background job and waited on, and
    # that waits for the review group in #2 to give it something to protect.
    "$entry" || d_warn "$entry could not run."
  done <<<"$(d_entries "$1")"
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
    if [ ! -f "$STATE" ]; then
      h_flow
      d_ok "no active flow"
    elif [ "$scope" = flow ] && [ "$D_JQ" != ok ]; then
      # --flow never runs the tools group, so nothing else here would report the
      # jq that every check below needs. Skipping all five and still exiting 0
      # is the one answer a diagnostic must never give - and /orchestrator:next
      # gates on exactly that exit code.
      d_run "h_flow check_jq"
    else
      d_run_flow
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
  mkdir -p "$HANDOFF_DIR" "$REVIEW_DIR"
  exclude_orch_dir
  # The budget is null until the review loop asks a human for one, and `review
  # begin` reads null as the default. The flake rerun is seeded here rather than
  # at the review phase because its allowance belongs to the flow: one per flow,
  # spent or not, so that one refilled each iteration could not become an
  # infinite retry loop.
  jq -n --arg slug "$slug" --arg now "$(now)" '{
    slug: $slug, phase: "spec", issue: null, branch: null,
    pr: null, base_sha: null, budget: null, iteration: 0,
    flake_rerun_used: false, created: $now, updated: $now
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
    *) die "unknown review op: ${op:-<none>} (want begin|path|file|ci|ready)" ;;
  esac
}

# --- spec -------------------------------------------------------------------

# Prints the spec issue number, or dies. Same discipline as require_pr: call it
# as a bare assignment on its own line, so `set -e` stops the command when the
# subshell dies.
require_issue() {
  local issue
  issue="$(jq -r '.issue // ""' "$STATE")"
  [ -n "$issue" ] || die "no issue recorded in state - the spec phase must publish one first"
  printf '%s\n' "$issue"
}

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
    update)
      [ -f "$file" ] || die "body file not found: $file"
      # --body-file, never --body: a spec carries tables, fences, and `#nn`
      # references, and a heredoc through a shell is where those get mangled.
      gh issue edit "$issue" --body-file "$file" >/dev/null \
        || die "gh could not replace the body of issue #$issue"
      ;;
    comment)
      [ -f "$file" ] || die "comment file not found: $file"
      gh issue comment "$issue" --body-file "$file" >/dev/null \
        || die "gh could not comment on issue #$issue"
      ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment)" ;;
  esac
}

# --- git / github -----------------------------------------------------------

cmd_branch_create() {
  require_state
  local slug issue base name
  slug="$(jq -r .slug "$STATE")"
  issue="$(require_issue)"
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
  pr="$(jq -r '.pr // "-"' "$STATE")";  iteration="$(jq -r '.iteration // 0' "$STATE")"
  note "flow:      $slug"
  note "phase:     $phase"
  note "issue:     $issue"
  note "branch:    $branch"
  note "PR:        $pr"
  # Against the budget, not alone: "iteration 3" does not say how far along
  # the loop is, and the budget is the one number a human chose.
  note "review:    iteration $iteration of $(review_budget)"
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
  spec fetch <file>           write the spec issue's body to <file>
  spec update <file>          replace the spec issue's body with <file>
  spec comment <file>         post <file> as a comment on the spec issue
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
    review)        cmd_review "$@" ;;
    spec)          cmd_spec "$@" ;;
    status)        cmd_status "$@" ;;
    archive)       cmd_archive "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

main "$@"
