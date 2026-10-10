# shellcheck shell=bash
# branch.sh - orch.sh's branch command: create, off, base-sha, sync and retire.
# Its tests: scripts/test/orch/branch.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# --- git / github -----------------------------------------------------------

# Forking a named branch off a base branch has exactly one right answer -
# fetch it, then check it out, falling back to the local ref if origin was
# unreachable - so both branch create (a flow's own naming and state) and
# branch off (a quick implementation's, which keeps no state) share it rather
# than each hand-rolling the fetch/checkout-fallback idiom. The caller names
# the base: a flow's is the one it recorded at init. The caller also names
# the remedy for a base origin says is gone ($3), since only a flow has a
# base it can correct.
checkout_new_branch() {
  local name="$1" base="$2" remedy="${3:-start again on another base branch}"
  if git rev-parse --verify --quiet "$name" >/dev/null; then die "branch $name already exists"; fi
  if ! git fetch --quiet origin "$base" 2>/dev/null; then
    # Only an origin that could not be asked earns the local fallback: one
    # that answered "no such branch" means the base is gone, and forking from
    # a stale local copy of it would build on work nobody will merge.
    local st=0
    origin_has_branch "$base" || st=$?
    [ "$st" -ne 2 ] || die "base branch $base does not exist on origin - push it, or $remedy"
  fi
  git checkout -q -b "$name" "origin/$base" 2>/dev/null || git checkout -q -b "$name" "$base"
}

# Records <base> and <sha> as branch <name>'s base and base SHA in its git
# config, where branch sync and branch base-sha read them.
record_branch_base() {
  git config "branch.$1.orchestrator-base" "$2"
  git config "branch.$1.orchestrator-base-sha" "$3"
}

# Besides state, it records the base and base SHA in the branch's git config,
# as branch off does, so branch sync and branch base-sha still find them once
# the flow is done or archived.
cmd_branch_create() {
  require_state
  [ $# -eq 0 ] || die "usage: orch.sh branch create"
  local slug issue name base sha
  slug="$(state_get slug)"
  require_issue issue
  name="orch/${issue}-${slug}"
  base="$(flow_base)"
  checkout_new_branch "$name" "$base" \
    "point this flow at another base: orch.sh base set <branch> --flow"
  sha="$(git rev-parse HEAD)"
  state_write_string branch "$name"
  state_write_string base_sha "$sha"
  record_branch_base "$name" "$base" "$sha"
  note "$name"
}

# A quick implementation keeps no state.json, so it has nothing to derive a
# name from - the caller passes the full name. It forks from the base branch in
# effect and records that base on the branch itself in local git config, so
# pr publish targets it even if the setting moves in the meantime - and records
# the base branch's tip at branching as the branch's base SHA, the meaning a
# flow's base_sha has, for its reviewers to diff from.
cmd_branch_off() {
  [ $# -eq 1 ] || die "usage: orch.sh branch off <name>"
  refuse_beside_active_flow
  local base
  base="$(base_branch)"
  checkout_new_branch "$1" "$base"
  record_branch_base "$1" "$base" "$(git rev-parse HEAD)"
  note "$1"
}

# The current branch's base SHA, as branch off, branch create or branch sync
# recorded it. A branch made
# before that was recorded falls back to the merge-base with its recorded_base,
# preferring origin's copy of it. Only a fallback: a base merged in mid-branch
# moves the merge-base and silently shrinks the diff it bounds.
cmd_branch_base_sha() {
  [ $# -eq 0 ] || die "usage: orch.sh branch base-sha"
  local branch sha base ref
  branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  sha="$(git config --get "branch.$branch.orchestrator-base-sha" 2>/dev/null)" || sha=""
  if [ -n "$sha" ]; then note "$sha"; return; fi
  base="$(recorded_base "$branch")"
  if git rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
    ref="refs/remotes/origin/$base"
  elif git rev-parse --verify --quiet "refs/heads/$base" >/dev/null; then
    ref="refs/heads/$base"
  else
    die "base branch $base of $branch is neither on origin nor local - no base SHA to fall back to"
  fi
  git merge-base HEAD "$ref" || die "$branch shares no history with base branch $base"
}

# Brings the current plugin-made branch up to date with its base branch: merges
# origin's tip of that base into it - never a rebase, never the local base -
# moves its base SHA to that tip, and pushes when it has an upstream. A
# plugin-made branch is the one this checkout's flow holds, whose base is the
# flow's, or one whose git config records a base (branch off, branch create);
# never the base branch in effect, which recorded_base falls back to. Exit 3 is
# a conflict, the merge left in progress for a resolver, with nothing else
# moved; every refusal is exit 1 with nothing moved. A failed push is the one
# exit 1 after something moved: the merge and base SHA stand, and a rerun -
# nothing left to merge - retries the push, as it finishes a resolved conflict.
cmd_branch_sync() {
  [ $# -eq 0 ] || die "usage: orch.sh branch sync"
  local branch base held="" tip remote
  branch="$(git symbolic-ref --quiet --short HEAD)" \
    || die "not on a branch (detached HEAD) - nothing was synced"
  if [ -f "$STATE" ] && [ "$(state_get branch)" = "$branch" ]; then
    held=1
    base="$(flow_base)"
  else
    base="$(git config --get "branch.$branch.orchestrator-base" 2>/dev/null)" \
      || die "$branch is not a branch the plugin made: no flow here holds it and it records no base - nothing was synced"
  fi
  [ "$branch" != "$base" ] || die "$branch is its own base branch - nothing was synced"
  if git rev-parse --quiet --verify MERGE_HEAD >/dev/null; then
    die "a merge is in progress on $branch - commit it (or git merge --abort), then rerun orch.sh branch sync"
  fi
  require_clean_tree "$ROOT" "the working tree is dirty - commit or discard its changes first; nothing was synced"
  git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null \
    || die "could not fetch $base from origin - nothing was synced"
  tip="$(git rev-parse "refs/remotes/origin/$base")"
  if ! git merge --quiet --no-edit "origin/$base" >/dev/null 2>&1; then
    if git rev-parse --quiet --verify MERGE_HEAD >/dev/null; then
      warn "merging origin/$base into $branch hit a conflict - the merge is left in progress; resolve and commit it, then rerun orch.sh branch sync"
      exit 3
    fi
    die "git could not merge origin/$base into $branch"
  fi
  git config "branch.$branch.orchestrator-base-sha" "$tip"
  [ -z "$held" ] || state_write_string base_sha "$tip"
  # Its own upstream only: branch create and branch off fork from origin's
  # base, which git sets as the new branch's upstream until it is first pushed.
  if [ "$(git config --get "branch.$branch.merge" 2>/dev/null)" = "refs/heads/$branch" ]; then
    remote="$(git config --get "branch.$branch.remote" 2>/dev/null)" || remote=origin
    git push --quiet "$remote" "refs/heads/$branch:refs/heads/$branch" 2>/dev/null \
      || die "could not push $branch - the merge and base SHA are recorded; rerun orch.sh branch sync to push"
  fi
  note "$branch synced with origin/$base at $tip"
}

cmd_branch() {
  local op="${1:-}"
  shift || true
  case "$op" in
    create) cmd_branch_create "$@" ;;
    off)    cmd_branch_off "$@" ;;
    base-sha) cmd_branch_base_sha "$@" ;;
    sync)   cmd_branch_sync "$@" ;;
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
    *) die "unknown branch op: ${op:-<none>} (want create|off|base-sha|sync|retire)" ;;
  esac
}
