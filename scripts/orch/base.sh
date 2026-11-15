# shellcheck shell=bash
# base.sh - orch.sh's base command: the checkout's base branch setting and a
# flow's own base, with the branch helpers every module calls
# (default_branch_into, origin_has_branch, require_on_origin). The readers
# (default_branch_into, base_branch_into, recorded_base_into) set a
# caller-named variable in the caller's own shell, so the first read memoises
# the answer (DEFAULT_BRANCH, DEFAULT_BRANCH_SOURCE) for the rest of that
# shell, with nothing to arrange beforehand. A reader that runs inside a $(...)
# subshell memoises only for that subshell, which never hands its variables
# back. default_branch_seed is the memo's one writer; default_branch_local is
# the memo-free local fallback doctor calls.
# Its tests: scripts/test/orch/base.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# default_branch_local: prints origin/HEAD's branch (read in full, never
# --short: a local branch named origin/<b> makes the short name
# remotes/origin/<b>; valid branch names only), else the literal guess main.
# Returns 0 when origin/HEAD named the branch, 1 when it fell back to main.
# Never asks GitHub and sets no memo variable: the one home of the local
# fallback rule, used by default_branch_seed and by doctor.
default_branch_local() {
  local head_ref b
  head_ref="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null)" || head_ref=""
  b="${head_ref#refs/remotes/origin/}"
  if is_branch_name "$b"; then printf '%s\n' "$b"; return 0; fi
  printf '%s\n' main
  return 1
}

# default_branch_seed [<github-answer>]: the one writer of the default-branch
# memo. Sets DEFAULT_BRANCH (the name) and DEFAULT_BRANCH_SOURCE in the current
# shell: github (the answer, when it is a valid branch name), else origin-head
# (origin/HEAD, via default_branch_local) or fallback (the literal guess main,
# also via default_branch_local). Asks GitHub nothing and ignores any existing
# memo.
default_branch_seed() {
  local answer="${1:-}" b
  if is_branch_name "$answer"; then
    b="$answer"
    DEFAULT_BRANCH_SOURCE=github
  elif b="$(default_branch_local)"; then
    DEFAULT_BRANCH_SOURCE=origin-head
  else
    DEFAULT_BRANCH_SOURCE=fallback
  fi
  DEFAULT_BRANCH="$b"
}

# default_branch_resolve: seeds the memo through default_branch_seed, with
# GitHub's answer when it can get one.
# Private to the readers. Memoised in the shell that runs it: it returns at
# once, asking nothing, when DEFAULT_BRANCH_SOURCE is already set in the
# current shell.
#
# Ask GitHub first. refs/remotes/origin/HEAD is a *local cached pointer* frozen
# at clone time - in a clone taken while a feature branch was checked out it
# names that branch, which would silently base every feature branch off the
# wrong place. It is a fallback for repos gh cannot answer for, not the primary
# source. Each candidate counts only when it is a valid branch name, so noise
# around gh's answer - or a failed gh's output - falls through to the next
# (#465).
#
# GitHub is asked only when the repo resolves - adapter_repo_default_branch
# takes it positionally, since `gh repo view` ignores GH_REPO - and a checkout
# with none falls through to the local pointer rather than dying: the answer
# has always been best-effort, and init and base show ask it before anything
# needs GitHub.
default_branch_resolve() {
  local b=""
  [ -z "${DEFAULT_BRANCH_SOURCE:-}" ] || return 0
  if repo_resolve; then
    b="$(adapter_repo_default_branch "$REPO_NAME" 2>/dev/null)" || b=""
  fi
  default_branch_seed "$b"
}

# default_branch_into <var> [<source-var>]: sets <var> to the default branch's
# name and, with a second variable, <source-var> to the memo's source (github,
# origin-head or fallback), in the caller's shell. Never fails.
default_branch_into() {
  default_branch_resolve
  printf -v "$1" '%s' "$DEFAULT_BRANCH"
  if [ -n "${2:-}" ]; then printf -v "$2" '%s' "$DEFAULT_BRANCH_SOURCE"; fi
  return 0
}

# Whether $1 is a valid branch name (git check-ref-format --branch rejects an
# empty one).
is_branch_name() {
  git check-ref-format --branch "$1" >/dev/null 2>&1
}

# The base branch in effect now: the checkout's orchestrator.base setting, else
# the default branch. The one answer every fork, PR target and doctor check
# asks for - default_branch_into keeps meaning GitHub's default branch alone.
# Local git config rather than state.json or a tracked file: it outlives
# abort and archiving, every worktree of the clone shares it, and it never
# travels with a push.
base_setting() { git config --get orchestrator.base 2>/dev/null || true; }
# base_branch_into <var>: sets <var> to the base branch - the configured one,
# else the default branch - in the caller's shell. Never fails.
base_branch_into() {
  local _bb_b
  _bb_b="$(base_setting)"
  if [ -n "$_bb_b" ]; then printf -v "$1" '%s' "$_bb_b"; else default_branch_into "$1"; fi
}

# Whether origin has branch $1: 0 yes, 2 origin answered and it does not,
# anything else origin could not be asked. ls-remote's own exit codes carry
# exactly that split, which is the one doctor's severity rule turns on.
origin_has_branch() {
  local st=0
  git ls-remote --quiet --exit-code origin "refs/heads/$1" >/dev/null 2>&1 || st=$?
  return "$st"
}

# The base branch a branch belongs to: the one branch off recorded for it, else,
# for a branch made before that was recorded, the base branch in effect now.
# The one rule pr publish targets and branch base-sha falls back to, so the PR
# and the SHA its review diffs from never name different bases.
# recorded_base_into <var> <branch> sets <var> to it, in the caller's shell.
recorded_base_into() {
  local _rb_b
  if _rb_b="$(branch_base_get "$2")"; then printf -v "$1" '%s' "$_rb_b"; else base_branch_into "$1"; fi
  return 0
}

# Reads the current base into the named variable and notes "<base> (<source>)".
base_note_into() {
  base_branch_into "$1"
  note "${!1} ($(base_source))"
}
# base_source: prints `set` when a base branch is configured, else `default`.
base_source() { if [ -n "$(base_setting)" ]; then echo set; else echo default; fi; }

# Dies unless origin answers that it has branch $1 - the one check both
# `base set` and `base set --flow` make before writing anything.
require_on_origin() {
  local st=0
  origin_has_branch "$1" || st=$?
  case "$st" in
    0) ;;
    2) die "branch $1 does not exist on origin - push it first, or check the name" ;;
    *) die "could not reach origin to check that branch $1 exists - nothing was set" ;;
  esac
}

# A flow's base is fixed when init seeds it: no redo and no change to the
# checkout setting rewrites it, so its fork point and PR target cannot move
# under it. base set --flow is the one exception: the explicit correction of
# the active flow's own base, allowed only while the flow has no branch -
# before it first branches, or after a redo retires that branch. The
# checks run in a fixed order and the first that fails is reported; nothing is
# written unless all pass. The name is stored literally, the default branch's
# own included: a flow's base is pinned, unlike the checkout setting.
base_set_flow() {
  orch_load state
  local b="$1" branch slug phase
  [ -f "$STATE" ] || die "no active flow - nothing was set"
  state_get_many_in "$STATE" branch=branch slug=slug phase=phase || die "$STATE_UNREADABLE_MSG"
  [ "$phase" != "done" ] || die "no active flow - nothing was set"
  if [ -n "$branch" ]; then
    if [ "$phase" = review ]; then
      die "flow $slug already has branch $branch - its base can change again once $(flow_cmd redo) retires it"
    fi
    die "flow $slug already has branch $branch - its base can no longer change; abort to start again on another base"
  fi
  is_branch_name "$b" || die "$b is not a valid branch name - nothing was set"
  require_on_origin "$b"
  state_write_string base "$b"
  note "$b (flow)"
}

cmd_base() {
  local op="${1:-}" b="" flow=0 a
  shift || true
  case "$op" in
    set)
      # --flow may come before or after the one branch name; anything else is
      # a usage error.
      for a in "$@"; do
        if [ "$a" = --flow ] && [ "$flow" -eq 0 ]; then flow=1
        elif [ -z "$b" ] && [ "$a" != --flow ]; then b="$a"
        else die "usage: orch.sh base set <branch> [--flow]"
        fi
      done
      [ -n "$b" ] || die "usage: orch.sh base set <branch> [--flow]"
      if [ "$flow" -eq 1 ]; then base_set_flow "$b"; return; fi
      # One read of the active flow's phase, base and slug, only when a state
      # file exists, doubles as the readability check.
      local fphase="done" fbase fslug
      if [ -f "$STATE" ]; then
        orch_load state
        state_get_many_in "$STATE" fphase=phase fbase=base fslug=slug || die "$STATE_UNREADABLE_MSG"
      fi
      require_on_origin "$b"
      # The default branch's own name is no setting at all - storing it would
      # pin today's default and outlive a rename of it - but only when GitHub
      # or origin/HEAD named that default. A name matching only the main
      # fallback is a guess, never the default's name, so it is stored.
      local dflt dsrc
      default_branch_into dflt dsrc
      if [ "$b" = "$dflt" ] && [ "$dsrc" != fallback ]; then
        git config --unset orchestrator.base 2>/dev/null || true
      else
        git config orchestrator.base "$b"
      fi
      local cur
      base_note_into cur
      # The setting only reaches flows started after it; say so rather than
      # let the active flow's PR surprise anyone by targeting its old base.
      if [ "$fphase" != "done" ]; then
        local fb; flow_base_fallback_into fb "$fbase"
        [ "$fb" = "$cur" ] ||
          note "note: the active flow $fslug keeps its own base branch: $fb"
      fi
      ;;
    show)
      [ $# -eq 0 ] || die "usage: orch.sh base show"
      local cur
      base_note_into cur
      ;;
    clear)
      [ $# -eq 0 ] || die "usage: orch.sh base clear"
      git config --unset orchestrator.base 2>/dev/null || true
      local cur
      base_note_into cur
      ;;
    *) die "unknown base op: ${op:-<none>} (want set|show|clear)" ;;
  esac
}
