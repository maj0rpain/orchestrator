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

# Names a flow command so any host can act on it. Plugin commands are
# unverified on Junie (docs/host-capabilities.md), so off Claude Code each also
# names the orch-flow section it routes to - the same fallback the skills
# offer. On Claude Code the message stays as it was before 1.0.0 (#121 story 2).
flow_cmd() {
  local section
  case "$1" in
    start) section="Starting a flow" ;;
    next)  section="Next phase" ;;
    redo)  section="Redo" ;;
    abort) section="Abort" ;;
    *) die "flow_cmd: unknown command: $1" ;;
  esac
  if [ "$(host_detect)" = claude ]; then
    printf "/orchestrator:%s" "$1"
  else
    printf "/orchestrator:%s (or orch-flow's %s section)" "$1" "$section"
  fi
}

require_state() {
  [ -f "$STATE" ] || die "no active flow ($ORCH_DIR_NAME/state.json not found). Run $(flow_cmd start) first."
}

# Fetches a required state field via jq, dies with $3 if it comes back empty,
# and otherwise writes it into the variable named by $1 - a caller-named
# out-param via `printf -v` rather than a nameref: bash 3.2 has neither
# `local -n` nor `declare -n`, and this file promises to still run there (the
# same idiom `d_gate` uses in doctor.sh).
#
# Call it as a bare statement on its own line - `local pr; require_pr pr` -
# never folded into `$(...)`. A caller-named out-param has no result to
# capture with `pr="$(require_pr)"` in the first place, so that old shape no
# longer compiles into anything that reads state; the only thing left to write
# is the bare form, and `die` in that form runs directly in the caller's flow
# rather than inside a command substitution subshell, so `set -e` actually
# stops it instead of the caller carrying on with an empty value.
require_field() {
  local __rf_out="$1" __rf_filter="$2" __rf_msg="$3" __rf_val
  __rf_val="$(jq -r "$__rf_filter" "$STATE")"
  [ -n "$__rf_val" ] || die "$__rf_msg"
  printf -v "$__rf_out" '%s' "$__rf_val"
}

# Every review command that reaches GitHub needs the flow's PR number and none
# of them can do anything useful without it.
require_pr() { require_field "$1" '.pr // ""' "no PR recorded in state - the implement phase opens it"; }

# branch create, pr open, and every spec op need the flow's spec issue number
# before touching GitHub.
require_issue() { require_field "$1" '.issue // ""' "no issue recorded in state - the spec phase must publish one first"; }

# pr open and redo review both need the flow's branch before touching GitHub.
require_branch() { require_field "$1" '.branch // ""' "no branch recorded in state"; }

# --- mattpocock-skills lookup ------------------------------------------------
#
# Each supported host installs mattpocock-skills somewhere else, in another
# shape, so the lookup is one place that knows them all. Shared by mp-skill and
# doctor so the two can never disagree about where the skills are. Checked in
# this order, and the first location present wins outright - skills are never
# mixed across installs, so a partial install is reported rather than papered
# over with whatever version some other host left behind:
#
#   override - $ORCHESTRATOR_MATTPOCOCK_ROOT, for an install none of the below
#              describe. Authoritative when set: a bad value fails rather than
#              falling through to something the user did not ask for.
#   claude   - Claude's plugin cache, namespaced by marketplace and version.
#              Resolved by glob, never pinned: the version changes under us,
#              and the newest wins.
#   junie    - Junie's extension cache under ~/.junie/extensions/, flat and
#              un-namespaced (#121, from a real install). Whether an extension
#              sits at the top level or one directory down is unverified, so
#              both are checked.
#   agents   - the `skills` CLI store. ~/.agents/skills is shared with every
#              other skill the CLI installed, so only the entries its lockfile
#              records as mattpocock-skills' count - a same-named skill from
#              another plugin is never run in its place.
#
# Only user-level locations count. A project's own .agents/skills is ignored:
# a cloned repo must not be able to substitute the instructions the flow runs.
#
# No arrays: bash 3.2 cannot tell an empty array from an unset one, so
# ${#hits[@]} on a machine with nothing installed aborts the subshell under
# `set -u` - on the one code path doctor exists to report.

MP_PLUGIN="mattpocock-skills"
MP_LOCK_REL=".agents/.skill-lock.json"

# True when the skills CLI lockfile records $1 as a mattpocock-skills skill, or
# with no argument, when it records any. jq missing reads as "records nothing".
mp_agents_owns() {
  local lock="$HOME/$MP_LOCK_REL"
  [ -f "$lock" ] || return 1
  if [ -n "${1:-}" ]; then
    jq -e --arg n "$1" --arg p "$MP_PLUGIN" \
      '(.skills // {})[$n].pluginName == $p' "$lock" >/dev/null 2>&1
  else
    jq -e --arg p "$MP_PLUGIN" \
      'any((.skills // {})[]; .pluginName == $p)' "$lock" >/dev/null 2>&1
  fi
}

# Where mattpocock-skills will be read from, as "<kind><TAB><path>", or status 1
# when no location holds it. Kinds are the ones listed above.
mp_location() {
  local p hits=""
  if [ -n "${ORCHESTRATOR_MATTPOCOCK_ROOT:-}" ]; then
    [ -d "$ORCHESTRATOR_MATTPOCOCK_ROOT" ] || return 1
    printf 'override\t%s\n' "${ORCHESTRATOR_MATTPOCOCK_ROOT%/}"
    return 0
  fi
  for p in "$HOME"/.claude/plugins/cache/*/"$MP_PLUGIN"/*/skills; do
    if [ -d "$p" ]; then hits="$hits${p%/skills}"$'\n'; fi
  done
  if [ -n "$hits" ]; then
    printf 'claude\t%s\n' "$(printf '%s' "$hits" | sort -V | tail -1)"
    return 0
  fi
  for p in "$HOME/.junie/extensions/$MP_PLUGIN" "$HOME"/.junie/extensions/*/"$MP_PLUGIN"; do
    if [ -d "$p" ]; then printf 'junie\t%s\n' "$p"; return 0; fi
  done
  if mp_agents_owns; then
    printf 'agents\t%s\n' "$HOME/.agents/skills"
    return 0
  fi
  return 1
}

# The SKILL.md for skill $3 in location $2 of kind $1, or status 1. Plugin-shaped
# locations may file skills under a category (skills/engineering/<name>) or
# flat (skills/<name>); an override may also point straight at a directory of
# skills. A name is a single path segment - never a way out of the location.
mp_skill_path() {
  local kind="$1" root="$2" name="$3" p
  case "$name" in ""|*/*|.*) return 1 ;; esac
  if [ "$kind" = agents ]; then
    mp_agents_owns "$name" || return 1
    p="$root/$name/SKILL.md"
    if [ -f "$p" ]; then printf '%s\n' "$p"; return 0; fi
    return 1
  fi
  for p in "$root/skills"/*/"$name"/SKILL.md "$root/skills/$name/SKILL.md" "$root/$name/SKILL.md"; do
    if [ -f "$p" ]; then printf '%s\n' "$p"; return 0; fi
  done
  return 1
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

# The base branch in effect now: the checkout's orchestrator.base setting, else
# the default branch. The one answer every fork, PR target and doctor check
# asks for - default_branch keeps meaning GitHub's default branch alone.
# Local git config rather than state.json or a tracked file: it outlives
# abort and archiving, every worktree of the clone shares it, and it never
# travels with a push.
base_setting() { git config --get orchestrator.base 2>/dev/null || true; }
base_branch() {
  local b
  b="$(base_setting)"
  if [ -n "$b" ]; then printf '%s\n' "$b"; else default_branch; fi
}
base_source() { if [ -n "$(base_setting)" ]; then echo set; else echo default; fi; }

# The active flow's own base branch, recorded by init. A flow started before
# base was recorded has none, and always forked from the default branch.
flow_base() {
  local b
  b="$(jq -r '.base // ""' "$STATE")"
  if [ -n "$b" ]; then printf '%s
' "$b"; else default_branch; fi
}

# Whether origin has branch $1: 0 yes, 2 origin answered and it does not,
# anything else origin could not be asked. ls-remote's own exit codes carry
# exactly that split, which is the one doctor's severity rule turns on.
origin_has_branch() {
  local st=0
  git ls-remote --quiet --exit-code origin "refs/heads/$1" >/dev/null 2>&1 || st=$?
  return "$st"
}

cmd_base() {
  local op="${1:-}" b st
  shift || true
  case "$op" in
    set)
      [ $# -eq 1 ] || die "usage: orch.sh base set <branch>"
      b="$1"; st=0
      origin_has_branch "$b" || st=$?
      case "$st" in
        0) ;;
        2) die "branch $b does not exist on origin - push it first, or check the name" ;;
        *) die "could not reach origin to check that branch $b exists - nothing was set" ;;
      esac
      # The default branch's own name is no setting at all: storing it would
      # pin today's default and outlive a rename of it.
      if [ "$b" = "$(default_branch)" ]; then
        git config --unset orchestrator.base 2>/dev/null || true
      else
        git config orchestrator.base "$b"
      fi
      note "$(base_branch) ($(base_source))"
      # The setting only reaches flows started after it; say so rather than
      # let the active flow's PR surprise anyone by targeting its old base.
      if [ -f "$STATE" ] && [ "$(jq -r .phase "$STATE")" != done ]; then
        local fb; fb="$(flow_base)"
        [ "$fb" = "$(base_branch)" ] ||
          note "note: the active flow $(jq -r .slug "$STATE") keeps its own base branch: $fb"
      fi
      ;;
    show)
      [ $# -eq 0 ] || die "usage: orch.sh base show"
      note "$(base_branch) ($(base_source))"
      ;;
    clear)
      [ $# -eq 0 ] || die "usage: orch.sh base clear"
      git config --unset orchestrator.base 2>/dev/null || true
      note "$(base_branch) ($(base_source))"
      ;;
    *) die "unknown base op: ${op:-<none>} (want set|show|clear)" ;;
  esac
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
  local name="${1:-}" loc kind root
  loc="$(mp_location)" || die "mattpocock-skills not installed - run: orch.sh doctor --env"
  kind="${loc%%$'\t'*}"; root="${loc#*$'\t'}"
  if [ -z "$name" ]; then printf '%s\n' "$root"; return 0; fi
  mp_skill_path "$kind" "$root" "$name" || die "no such mattpocock skill: $name (looked in $root)"
}

# --- doctor -----------------------------------------------------------------
#
# Sourced rather than inlined: a change to how checks register, gate, or count
# then concentrates in doctor.sh instead of sharing file scope with the flow
# commands below.
source "$(dirname "${BASH_SOURCE[0]}")/doctor.sh"

# The one definition of the planning allowlist, shared with hook-guard.sh so
# the flow-start check and the edit guard can never disagree about it.
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

# --- state ------------------------------------------------------------------

# Prints, one per line, every path with tracked modifications or untracked
# files in this working tree that falls outside the planning allowlist. -z
# keeps unusual file names intact; a rename or copy carries its source path as
# a second record, and both sides count - the source is gone from where it was.
# -uall lists untracked files individually, so a new directory is judged by
# what is in it rather than by its name.
dirty_outside_allowlist() {
  local rec path want_src=0 status
  # Captured first rather than read through a process substitution, whose
  # failure set -e never sees: a git status that cannot run must refuse, not
  # read as a clean tree. A file, not a variable, because the output is
  # NUL-separated.
  status="$(mktemp)"
  git -C "$ROOT" status --porcelain=v1 -z -uall >"$status" \
    || { rm -f "$status"; die "git status failed - cannot check the working tree"; }
  while IFS= read -r -d '' rec; do
    if [ "$want_src" -eq 1 ]; then
      path="$rec"; want_src=0
    else
      path="${rec:3}"
      case "${rec:0:2}" in *R*|*C*) want_src=1 ;; esac
    fi
    planning_allowlisted "$path" || printf '%s\n' "$path"
  done <"$status"
  rm -f "$status"
}

# The git-based backstop from ADR-0013. Where no host hook arms the edit
# guard, planning can edit source unhindered; flow start is where that gets
# caught, before any state exists. Runs against $ROOT, this working tree's own
# top level, so a flow started inside a worktree (ADR-0008) is judged by that
# worktree's changes and not by the checkout it was forked from.
require_clean_outside_allowlist() {
  local dirty
  dirty="$(dirty_outside_allowlist)" || exit 1
  [ -z "$dirty" ] && return 0
  die "the working tree has changes outside the planning allowlist:
$(printf '%s\n' "$dirty" | sed 's/^/       /')
     Planning may only change: $(planning_allowlist_text).
     Commit, stash, or discard these changes, then run init again."
}

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
      *) die "unknown init flag: $1 (want --issue)" ;;
    esac
  done
  slug="$(normalize_slug "$slug")"
  # A "done" flow already succeeded - its handoffs are read by no later phase,
  # so it is not "active" in any sense that matters. init archives it and
  # proceeds instead of refusing; every other phase still blocks a second flow.
  local archive_note=""
  if [ -f "$STATE" ] && [ "$(jq -r .phase "$STATE")" != "done" ]; then
    die "a flow is already active (slug: $(jq -r .slug "$STATE"), phase: $(jq -r .phase "$STATE")).
     One flow at a time - finish it, or run $(flow_cmd abort)."
  fi
  require_clean_outside_allowlist
  # Adoption is validated before anything is written, mirroring how
  # branch create and pr open die on their own preconditions rather than
  # letting a whole phase run against an issue that cannot back it. Validating
  # before archiving a done flow means a bad --issue leaves it untouched and
  # re-runnable rather than archived for nothing.
  [ -z "$issue" ] || validate_adopted_issue "$issue"
  if [ -f "$STATE" ]; then
    archive_note="$(cmd_archive)"
  fi
  mkdir -p "$HANDOFF_DIR" "$REVIEW_DIR"
  exclude_orch_dir
  # The budget is null until the review loop asks a human for one, and `review
  # begin` reads null as the default. The flake rerun is seeded here rather than
  # at the review phase because its allowance belongs to the flow: one per flow,
  # spent or not, so that one refilled each iteration could not become an
  # infinite retry loop. issue is seeded from --issue when given; state.json
  # carries no field for whether it was adopted or published - nothing
  # downstream reads that distinction. host_fallbacks marks a flow whose
  # handoffs must record Host fallbacks (see host_fallbacks_required).
  # base is fixed here and never rewritten - not by redo, not by a later
  # `base set` - so a flow's fork point and PR target cannot move under it.
  jq -n --arg slug "$slug" --arg now "$(now)" --arg issue "$issue" --arg base "$(base_branch)" '{
    slug: $slug, phase: "spec", issue: (if $issue == "" then null else ($issue | tonumber) end),
    base: $base, branch: null, pr: null, base_sha: null, budget: null, iteration: 0,
    flake_rerun_used: false, redo_count: 0, host_fallbacks: true, created: $now, updated: $now
  }' >"$STATE"
  [ -z "$archive_note" ] || note "$archive_note"
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
  [ ! -f "$STATE" ] || [ "$(jq -r '.host_fallbacks // false' "$STATE" 2>/dev/null)" = true ]
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

# --- gh adapter -------------------------------------------------------------
#
# The seam between this file's decision logic and the `gh` CLI. A caller like
# severity_label_ensure below calls an adapter function, never `gh` itself, so
# a test can replace one in-process function instead of faking a `gh` binary
# on PATH. Label creation was the first primitive moved behind it, proving the
# seam on the narrowest possible slice (issue #91, first of the #78
# breakdown); the issue-resource primitives below (view/edit/comment/create/
# close, issue #92) extend the same seam to cmd_spec, cmd_issue_publish,
# cmd_review file, and cmd_redo_spec's issue close - later tickets move the
# rest of this file's `gh` call sites the same way.
#
# ORCH_GH_ADAPTER is an opt-in test knob in the same spirit as the ORCH_CI_*
# ones above, but read differently: not a value substituted at load time, but
# a file sourced immediately after the real adapter functions are defined:
# anything it redefines overrides the corresponding real function for the
# rest of the process, and anything it leaves alone keeps shelling out to the
# real `gh` below. Unset - every normal run - nothing is sourced and behaviour
# is identical to before the seam existed.
adapter_label_create() {
  gh label create "$@"
}

# The spec review's read on an issue's body - and, dynamically, its
# state/labels the same way `gh issue view` itself answers either.
adapter_issue_view() {
  gh issue view "$@"
}

# cmd_spec's update/comment ops pick between these two, the same way it
# already picks `edit` or `comment` as the literal `gh issue` subcommand.
adapter_issue_edit() {
  gh issue edit "$@"
}
adapter_issue_comment() {
  gh issue comment "$@"
}

# Every issue-filing call site but `ticket publish` (out of scope for issue
# #92 - see cmd_ticket_publish) goes through this one primitive.
adapter_issue_create() {
  gh issue create "$@"
}

# cmd_redo_spec's --new-issue path is the one issue-close call this ticket
# moves; `ticket close` keeps its own direct `gh issue close` (also out of
# scope).
adapter_issue_close() {
  gh issue close "$@"
}

# The PR-resource primitives (issue #93, third of the #78 breakdown): open_pr's
# create/view, ci_probe's checks, cmd_review ready's ready, and
# cmd_redo_review's close. doctor.sh's own `gh pr view` calls are a separate
# concern (out of scope, like default_branch and the ticket group's `gh api`
# calls) - only the four call sites named in issue #93 move here.
adapter_pr_create() {
  gh pr create "$@"
}
adapter_pr_view() {
  gh pr view "$@"
}

# ci_probe's one hand on GitHub, called once for the required scope and once
# for the all-checks scope - the exit-8-vs-exit-0 handling and bucket
# classification right around its call sites are unchanged; only the raw `gh
# pr checks` invocation moves here.
adapter_pr_checks() {
  gh pr checks "$@"
}

adapter_pr_ready() {
  gh pr ready "$@"
}
adapter_pr_close() {
  gh pr close "$@"
}

if [ -n "${ORCH_GH_ADAPTER:-}" ]; then
  # shellcheck disable=SC1090
  source "$ORCH_GH_ADAPTER"
fi

# The severity label a filed finding carries, so triage can filter on it. It is
# this plugin's own, so --force is safe: on the current gh that updates a label
# that exists rather than failing on it, and filing works on a repo that has
# never seen the label and on one that has, with no listing step in between.
severity_label_ensure() {
  adapter_label_create "$1" --force --color "$2" --description "$3" >/dev/null \
    || die "gh could not create label $1"
}

# The triage label is the repo's, not ours: created only where it is missing,
# and never rewritten, because a maintainer's colour and description on it are
# theirs to keep. A create that fails because the label exists is the common
# case and is ignored; one that fails for any other reason surfaces two lines
# later, when `gh issue create` cannot apply the label.
triage_label_ensure() {
  adapter_label_create "$1" --color e4e669 --description "Not yet triaged" >/dev/null 2>&1 || true
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
    out="$(adapter_pr_checks "$pr" --required --json bucket,name,state 2>&1)" || st=$?
  else
    out="$(adapter_pr_checks "$pr" --json bucket,name,state 2>&1)" || st=$?
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
      url="$(adapter_issue_create --title "$title" --body-file "$body" \
        --label "review:$severity" --label "$triage")" \
        || die "gh could not create the issue"
      # Prints the number alone: the record cites a number, and the caller
      # would otherwise be parsing a URL out of prose every time.
      note "${url##*/}"
      ;;
    ready)
      require_state
      local pr
      require_pr pr
      # GitHub first, state second. Recording `done` over a PR still sitting in
      # draft would claim a success nobody can see, and the flow would have no
      # phase left to retry it from.
      adapter_pr_ready "$pr" >/dev/null 2>&1 \
        || die "gh could not mark PR #$pr ready - the flow stays in review"
      cmd_state set phase done
      note "$pr"
      ;;
    ci)
      require_state
      local pr started slept=0 elapsed=0 res verdict
      require_ci_knobs
      require_pr pr
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

# --- issue --------------------------------------------------------------
#
# The stateless issue body read/write pair - the same contract
# issue publish/pr publish/ticket publish already offer, extended to a plain
# issue's body given just its number. cmd_spec's fetch/update ops below are
# thin wrappers over these two, resolving the issue number from state exactly
# as they always did, so flow's stateful spec access and quick
# implementation's stateless issue access share one tested code path instead
# of two independently-maintained copies of the same body read/write.
#
# `issue update` stays a dumb "replace the body with these exact bytes"
# primitive - fold-in choreography like fetch-then-append-then-write for
# merging ticket content into a parent belongs in the calling skill's prose,
# not here.

# Written beside the target and moved into place only once gh has answered:
# a failed fetch that left a partial file behind is a body a caller would
# mistake for the issue's actual content.
cmd_issue_fetch() {
  local issue="$1" file="$2" tmp
  mkdir -p "$(dirname "$file")"
  tmp="$(mktemp "$file.XXXXXX")"
  if ! adapter_issue_view "$issue" --json body --jq .body >"$tmp"; then
    rm -f "$tmp"
    die "gh could not read the body of issue #$issue"
  fi
  mv "$tmp" "$file"
}

cmd_issue_update() {
  local issue="$1" file="$2"
  [ -f "$file" ] || die "body file not found: $file"
  # --body-file, never --body: an issue body carries tables, fences, and
  # `#nn` references, and a heredoc through a shell is where those get
  # mangled.
  adapter_issue_edit "$issue" --body-file "$file" >/dev/null \
    || die "gh could not replace the body of issue #$issue"
}

cmd_issue() {
  local op="${1:-}"
  shift || true
  case "$op" in
    fetch|update)
      [ $# -eq 2 ] || die "usage: orch.sh issue $op <n> <file>"
      local issue="$1" file="$2"
      case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
      if [ "$op" = fetch ]; then cmd_issue_fetch "$issue" "$file"; else cmd_issue_update "$issue" "$file"; fi
      ;;
    publish) cmd_issue_publish "$@" ;;
    *) die "unknown issue op: ${op:-<none>} (want fetch|update|publish)" ;;
  esac
}

# --- spec -------------------------------------------------------------------

# The spec review's one hand on GitHub. The body is the truth the implement
# phase reads, so the three ways it is read and written go through here, where
# they are tested, rather than through a `gh issue edit` in skill prose.
# fetch/update delegate to the issue primitives above; comment has no
# stateless counterpart to delegate to, so it keeps its own call here.
cmd_spec() {
  local op="${1:-}"
  shift || true
  require_state
  [ $# -eq 1 ] || die "usage: orch.sh spec <fetch|update|comment> <file>"
  local file="$1" issue
  require_issue issue
  case "$op" in
    fetch)  cmd_issue_fetch "$issue" "$file" ;;
    update) cmd_issue_update "$issue" "$file" ;;
    comment)
      [ -f "$file" ] || die "body file not found: $file"
      adapter_issue_comment "$issue" --body-file "$file" >/dev/null \
        || die "gh could not comment on issue #$issue"
      ;;
    *) die "unknown spec op: ${op:-<none>} (want fetch|update|comment)" ;;
  esac
}

# --- git / github -----------------------------------------------------------

# Forking a named branch off a base branch has exactly one right answer -
# fetch it, then check it out, falling back to the local ref if origin was
# unreachable - so both branch create (a flow's own naming and state) and
# branch off (a quick implementation's, which keeps no state) share it rather
# than each hand-rolling the fetch/checkout-fallback idiom. The caller names
# the base: a flow's is the one it recorded at init.
checkout_new_branch() {
  local name="$1" base="$2"
  if git rev-parse --verify --quiet "$name" >/dev/null; then die "branch $name already exists"; fi
  if ! git fetch --quiet origin "$base" 2>/dev/null; then
    # Only an origin that could not be asked earns the local fallback: one
    # that answered "no such branch" means the base is gone, and forking from
    # a stale local copy of it would build on work nobody will merge.
    local st=0
    origin_has_branch "$base" || st=$?
    [ "$st" -ne 2 ] || die "base branch $base does not exist on origin - push it, or start again on another base branch"
  fi
  git checkout -q -b "$name" "origin/$base" 2>/dev/null || git checkout -q -b "$name" "$base"
}

cmd_branch_create() {
  require_state
  [ $# -eq 0 ] || die "usage: orch.sh branch create"
  local slug issue name
  slug="$(jq -r .slug "$STATE")"
  require_issue issue
  name="orch/${issue}-${slug}"
  checkout_new_branch "$name" "$(flow_base)"
  cmd_state set branch "$name"
  cmd_state set base_sha "$(git rev-parse HEAD)"
  note "$name"
}

# A quick implementation keeps no state, so it has nothing to derive a name
# from and nothing to record one in - the caller passes the full name and gets
# a checked-out branch back, nothing else.
cmd_branch_off() {
  [ $# -eq 1 ] || die "usage: orch.sh branch off <name>"
  checkout_new_branch "$1" "$(default_branch)"
  note "$1"
}

cmd_branch() {
  local op="${1:-}"
  shift || true
  case "$op" in
    create) cmd_branch_create "$@" ;;
    off)    cmd_branch_off "$@" ;;
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
      # next implement attempt's branch create/pr open will reuse, and their
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
    *) die "unknown branch op: ${op:-<none>} (want create|off|retire)" ;;
  esac
}

# The publishing boundary a quick implementation calls instead of hardcoding
# `gh issue create` in skill prose - the same reason `review file` owns its
# own `gh issue create` rather than leaving it to whichever skill files a
# finding. Stateless like branch off: the caller has no flow to record into,
# so the title and body are its own and nothing here remembers them.
cmd_issue_publish() {
  [ $# -eq 2 ] || die "usage: orch.sh issue publish <title> <body-file>"
  local title="$1" body_file="$2" url
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  url="$(adapter_issue_create --title "$title" --body-file "$body_file")" \
    || die "gh could not create the issue"
  note "${url##*/}"
}

# Pushing a branch and opening a PR against it has exactly one right answer -
# push, then prefix the body with the issue line - Closes into the default
# branch, so GitHub links the PR as a closer (no agent-chosen wording can leave
# the issue open again), Refs into any other base - then create the PR - so pr open (a flow's own, draft, recorded into state) and pr publish
# (a quick implementation's, not a draft, recording nothing) share it rather
# than each hand-rolling the push/issue-line/gh-pr-create idiom.
open_pr() {
  local branch="$1" base="$2" issue="$3" title="$4" body_file="$5" draft="$6" tmp pr draft_flag="" keyword=Closes
  git push -q -u origin "$branch"
  # GitHub only acts on a closing keyword when the PR merges into the default
  # branch, so a PR into any other base branch refers to its issue instead of
  # claiming to close it - the release PR is what closes it.
  [ "$base" = "$(default_branch)" ] || keyword=Refs
  tmp="$(mktemp)"
  { printf '%s #%s\n\n' "$keyword" "$issue"; cat "$body_file"; } >"$tmp"
  # Unquoted on purpose: this is either empty or the one literal flag below,
  # never a value with spaces or glob characters to mis-split.
  [ "$draft" = true ] && draft_flag="--draft"
  if ! adapter_pr_create $draft_flag --base "$base" --head "$branch" \
      --title "$title" --body-file "$tmp" >/dev/null; then
    rm -f "$tmp"
    die "gh could not open the PR for branch $branch (issue #$issue)"
  fi
  rm -f "$tmp"
  pr="$(adapter_pr_view "$branch" --json number --jq .number)"
  printf '%s\n' "$pr"
}

cmd_pr_open() {
  require_state
  [ $# -eq 2 ] || die "usage: orch.sh pr open <title> <body-file>"
  local title="$1" body_file="$2" issue branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  require_issue issue
  require_branch branch
  # Draft is the honest signal: the review loop has not run yet, so marking it
  # ready is the loop's success condition rather than a comment nobody reads.
  pr="$(open_pr "$branch" "$(flow_base)" "$issue" "$title" "$body_file" true)"
  cmd_state set pr "$pr"
  note "$pr"
}

# The PR-opening boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - the same reason `issue publish` owns its own
# `gh issue create` rather than leaving it to skill prose. Stateless like
# branch off and issue publish: the caller has no flow to record into, and no
# draft to promote later, since a quick implementation's single-pass review
# already ran before this is called.
cmd_pr_publish() {
  [ $# -eq 3 ] || die "usage: orch.sh pr publish <issue> <title> <body-file>"
  local issue="$1" title="$2" body_file="$3" branch pr
  [ -f "$body_file" ] || die "body file not found: $body_file"
  case "$issue" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $issue" ;; esac
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  pr="$(open_pr "$branch" "$(default_branch)" "$issue" "$title" "$body_file" false)"
  note "$pr"
}

cmd_pr() {
  local op="${1:-}"
  shift || true
  case "$op" in
    open)    cmd_pr_open "$@" ;;
    publish) cmd_pr_publish "$@" ;;
    *) die "unknown pr op: ${op:-<none>} (want open|publish)" ;;
  esac
}

# --- ticket -------------------------------------------------------------
#
# GitHub's native sub-issue and issue-dependency APIs, in one place, so no
# skill prose ever calls `gh api` on these endpoints directly. Stateless
# throughout, like issue publish/pr publish: callable with no state.json,
# since quick implementation keeps none.

# The child's *database id*, not its issue number - both `sub_issues` and
# `dependencies/blocked_by` take the database id, and nowhere else does
# ticket_publish come by it for free.
issue_db_id() {
  gh api "repos/{owner}/{repo}/issues/$1" --jq .id \
    || die "gh could not read issue #$1"
}

# True only once both links read back exactly as published: the parent's
# sub_issues listing contains the child, and the child's blocked_by listing
# is the same set of numbers requested, in any order. Read fresh every call,
# never cached - the caller retries this on a mismatch, and a cached answer
# would just repeat the same wrong verdict.
ticket_links_verified() {
  local parent="$1" child="$2" want="$3" have_children have_blockers
  have_children="$(gh api --paginate "repos/{owner}/{repo}/issues/$parent/sub_issues" --jq '.[].number')" \
    || return 1
  printf '%s\n' "$have_children" | grep -qxF "$child" || return 1
  have_blockers="$(gh api --paginate "repos/{owner}/{repo}/issues/$child/dependencies/blocked_by" --jq '.[].number')" \
    || return 1
  [ "$(printf '%s\n' "$have_blockers" | sort -n)" = "$(printf '%s\n' "$want" | sort -n)" ]
}

# Publishes a child issue, links it to <parent> as a native sub-issue, adds a
# native blocking edge for every --blocked-by argument, and applies this
# repo's ready-for-agent label - then verifies every link it just wrote by
# reading it back. One retry on a mismatch; a second failure dies naming the
# ticket rather than falling back to a text-based `Blocked by:` convention,
# since nothing downstream ever reads that fallback.
cmd_ticket_publish() {
  [ $# -ge 3 ] || die "usage: orch.sh ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]"
  local parent="$1" title="$2" body_file="$3" blocked_by="" want="" b
  local ready url child child_id blocker_id
  shift 3
  while [ $# -gt 0 ]; do
    case "$1" in
      --blocked-by) blocked_by="$2"; shift 2 ;;
      *) die "usage: orch.sh ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]" ;;
    esac
  done
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  [ -n "$title" ] || die "the title is empty"
  [ -f "$body_file" ] || die "body file not found: $body_file"
  if [ -n "$blocked_by" ]; then
    want="$(printf '%s\n' "$blocked_by" | tr ',' '\n')"
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      case "$b" in ''|*[!0-9]*) die "--blocked-by must be plain issue numbers, got: $blocked_by" ;; esac
    done <<<"$want"
    # Deduplicated before the write loop and the verify below: GitHub stores a
    # blocking edge once no matter how many times it is requested, so a
    # duplicate in --blocked-by would otherwise make the readback's set
    # permanently smaller than $want and fail verification for a link that is
    # actually correct.
    want="$(printf '%s\n' "$want" | sort -un)"
  fi

  ready="$(triage_label_for ready-for-agent)"
  url="$(gh issue create --title "$title" --body-file "$body_file" --label "$ready")" \
    || die "gh could not create the ticket"
  child="${url##*/}"

  child_id="$(issue_db_id "$child")"
  gh api --method POST "repos/{owner}/{repo}/issues/$parent/sub_issues" \
      -F sub_issue_id="$child_id" >/dev/null \
    || die "gh could not link ticket #$child as a sub-issue of #$parent"

  if [ -n "$want" ]; then
    while IFS= read -r b; do
      [ -z "$b" ] && continue
      blocker_id="$(issue_db_id "$b")"
      gh api --method POST "repos/{owner}/{repo}/issues/$child/dependencies/blocked_by" \
          -F issue_id="$blocker_id" >/dev/null \
        || die "gh could not add a blocking edge from ticket #$child on #$b"
    done <<<"$want"
  fi

  ticket_links_verified "$parent" "$child" "$want" \
    || ticket_links_verified "$parent" "$child" "$want" \
    || die "ticket #$child's sub-issue/blocked-by links did not verify - checked twice, both failed"

  note "$child"
}

# The parent's open sub-issues with zero open blockers
# (issue_dependencies_summary.blocked_by, which already counts open blockers
# only), in the order GitHub published them.
cmd_ticket_next() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket next <parent>"
  local parent="$1" subs
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  subs="$(gh api --paginate "repos/{owner}/{repo}/issues/$parent/sub_issues" \
      --jq '.[] | select(.state == "open") | select(.issue_dependencies_summary.blocked_by == 0) | .number')" \
    || die "gh could not list sub-issues of #$parent"
  if [ -n "$subs" ]; then printf '%s\n' "$subs"; fi
}

cmd_ticket_close() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket close <n>"
  local n="$1"
  case "$n" in ''|*[!0-9]*) die "not a plain issue number: $n" ;; esac
  gh issue close "$n" >/dev/null || die "gh could not close ticket #$n"
}

# Reopens every sub-issue of <parent> that is currently closed, and only
# those - the fix `redo review` needs before handing back to a fresh
# implement phase, whose frontier query would otherwise find nothing.
cmd_ticket_reset() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket reset <parent>"
  local parent="$1" closed n
  case "$parent" in ''|*[!0-9]*) die "parent must be a plain issue number, got: $parent" ;; esac
  closed="$(gh api --paginate "repos/{owner}/{repo}/issues/$parent/sub_issues" \
      --jq '.[] | select(.state == "closed") | .number')" \
    || die "gh could not list sub-issues of #$parent"
  if [ -n "$closed" ]; then
    while IFS= read -r n; do
      [ -z "$n" ] && continue
      gh issue reopen "$n" >/dev/null || die "gh could not reopen ticket #$n"
    done <<<"$closed"
  fi
}

cmd_ticket() {
  local op="${1:-}"
  shift || true
  case "$op" in
    publish) cmd_ticket_publish "$@" ;;
    next)    cmd_ticket_next "$@" ;;
    close)   cmd_ticket_close "$@" ;;
    reset)   cmd_ticket_reset "$@" ;;
    *) die "unknown ticket op: ${op:-<none>} (want publish|next|close|reset)" ;;
  esac
}

# --- redo ---------------------------------------------------------------

# The full `review -> implement` transition: retire the old branch and PR,
# reopen the spec issue's closed tickets, move the old loop's records aside,
# and reset the state a fresh implement attempt needs - never mid-budget, and
# never over a loop nobody has confirmed actually ended. `flake_rerun_used` is
# deliberately untouched throughout, per docs/adr/0007: it is a per-flow
# allowance, not a per-loop one.
cmd_redo_review() {
  [ $# -eq 0 ] || die "usage: orch.sh redo review"
  require_state
  local phase i b word slug issue branch pr redo_count new_n new_branch msg
  phase="$(jq -r '.phase // ""' "$STATE")"
  [ "$phase" = review ] || die "flow is not at the review phase - nothing to redo back from"
  i="$(jq -r '.iteration // 0' "$STATE")"
  b="$(review_budget)"
  local terminal; terminal="$(review_terminal_state)" || true
  word="$(first_line "$terminal")"
  case "$word" in
    none)
      die "no review loop has run yet - nothing to redo back from; run $(flow_cmd next) to start one." ;;
    pending)
      die "the review loop hasn't reached its budget yet (iteration $i of budget $b) - that's what $(flow_cmd next) is for; redo is for after a loop ends." ;;
    interrupted)
      die "the review loop's last iteration ($i) has no recorded terminal state - the session looks interrupted, not stopped. Resume it with $(flow_cmd next); redo only runs once a loop actually ends." ;;
    stop) ;;
    *) die "review_terminal_state answered something redo does not know: $word" ;;
  esac

  slug="$(jq -r .slug "$STATE")"
  require_issue issue
  require_branch branch
  require_pr pr
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

  msg="$(printf 'This PR was closed by an orchestrator redo.\n\nThe retired branch is now `%s`.\nA new PR will follow once the redone implement phase reaches pr open again.\n' "$new_branch")"
  adapter_pr_close "$pr" --comment "$msg" >/dev/null || die "gh could not close PR #$pr"

  # The prior implement phase closed every ticket it finished, so the redone
  # implement phase's frontier query (ticket next) would otherwise find
  # nothing and open an empty PR - reopen exactly what ticket close closed.
  cmd_ticket_reset "$issue" >/dev/null

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
    require_issue issue
    msg="$(printf 'This issue was closed by an orchestrator redo because the spec itself needed to change.\n\nA fresh issue will follow from to-spec in this same flow.\n')"
    adapter_issue_close "$issue" --comment "$msg" >/dev/null || die "gh could not close issue #$issue"
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
    note "No active flow. Run $(flow_cmd start) from an approved plan."
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
  note "base:      $(flow_base)"
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
  default-branch              resolve the repo's default branch, as GitHub
                              reports it
  base set <branch>           set this checkout's base branch - the branch
                              flows and quick implementations fork from and
                              open PRs against; refuses a branch origin does
                              not have. Shared by every worktree, never
                              committed; the default branch's name clears it.
                              An active flow keeps the base it started with
  base show                   print the base branch in effect and its source:
                              set, or default
  base clear                  remove the setting, falling back to the default
                              branch; succeeds when nothing was set
  init <slug> [--issue N]     start a flow (refuses if one is active, unless
                              it is done - a done flow is archived and the
                              new one starts over it, or if the working tree
                              has changes outside the planning allowlist);
                              --issue adopts an already-open,
                              ready-for-agent issue N as the flow's spec
                              instead of leaving it unset. Records the base
                              branch in effect as the flow's own
  slug <text>                 normalise text to the kebab-case slug init would
                              store - lowercase, non-alphanumeric runs collapsed
                              to a hyphen, trimmed
  state get [key]             print state.json, or one key
  state set <key> <value>     update one key
  handoff path <phase>        print the handoff path for a phase
  handoff validate <file>     check required sections exist and are non-empty
  branch create               create orch/<issue>-<slug> off the flow's base
                              branch, recorded at init
  branch off <name>           create and check out <name> off the default
                              branch, recording no state - for a quick
                              implementation, which keeps none
  branch retire <old> <new>   rename <old> aside to <new>, republishing it on
                              origin and deleting the old remote ref, without
                              force-pushing over anything
  issue publish <title> <body-file>
                              create a GitHub issue, recording no state;
                              prints the number - for a quick implementation
                              that needs one
  issue fetch <n> <file>      write issue <n>'s body to <file>, recording no
                              state
  issue update <n> <file>     replace issue <n>'s body with <file>, recording
                              no state
  pr open <title> <body-file> push and open a draft PR against the flow's base
                              branch - Closes its issue into the default
                              branch, Refs it into any other
  pr publish <issue> <title> <body-file>
                              push the current branch and open a non-draft PR
                              closing <issue>, recording no state; prints the
                              PR number - for a quick implementation whose
                              single-pass review already ran
  ticket publish <parent> <title> <body-file> [--blocked-by N,N,...]
                              create a ticket, link it as a sub-issue of
                              <parent>, add a blocking edge for every
                              --blocked-by issue, apply ready-for-agent, and
                              verify the links it just wrote by reading them
                              back - recording no state; prints the number
  ticket next <parent>       print <parent>'s open sub-issues with zero open
                              blockers, in the order they were published
  ticket close <n>           close ticket <n>
  ticket reset <parent>      reopen every sub-issue of <parent> that is
                              currently closed, and only those
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
  redo review                 retire the branch and PR, reopen the spec
                              issue's closed tickets, reset the loop, and
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
    base)          cmd_base "$@" ;;
    init)          cmd_init "$@" ;;
    slug)          cmd_slug "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    branch)        cmd_branch "$@" ;;
    issue)         cmd_issue "$@" ;;
    pr)            cmd_pr "$@" ;;
    ticket)        cmd_ticket "$@" ;;
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
