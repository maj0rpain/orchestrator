# shellcheck shell=bash
# branch.sh - orch.sh's branch command: create, off, busy, base-sha, sync and
# retire.
# Its tests: scripts/test/orch/branch.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# Forking a named branch off a base branch has exactly one right answer -
# decide the start point with new_branch_start (origin's tip when origin
# answered, or, only when origin could not be asked, the local fallback;
# refusing - a taken name, a base gone from origin, a failed fetch - is the
# ways it fails), then check out that start point with fork_new_branch - so
# both branch create (a flow's own naming and state) and branch off (a quick
# implementation's, which keeps no state) share it rather than each
# hand-rolling the fetch/checkout-fallback idiom. The caller names
# the base: a flow's is the one it recorded at init. The caller also names
# the remedy for a base origin says is gone ($3), since only a flow has a
# base it can correct.
checkout_new_branch() {
  local start
  new_branch_start start "$@"
  fork_new_branch "$1" "$start"
}

# new_branch_start <start_var> <name> <base> [<remedy>]: decides the start
# point, the ref the branch forks from, and returns it through the caller-named
# <start_var>, named in full so a local branch or tag called origin/<base>
# cannot capture it: refs/remotes/origin/<base> after a fetch that worked; when
# origin could not be asked, that remote-tracking ref if it exists, else the
# local refs/heads/<base>. It dies when the name is taken, the base is gone from
# origin, or the fetch fails while origin has the base (could not fetch <base>
# from origin). It is checkout_new_branch's first half, alone, so a caller with
# something to write first (branch create's discard) runs it before.
new_branch_start() {
  local __nbs_out="$1" name="$2" base="$3" remedy="${4:-start again on another base branch}"
  local __nbs_start
  if git rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then die "branch $name already exists"; fi
  if git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null; then
    __nbs_start="refs/remotes/origin/$base"
  else
    # Only an origin that could not be asked earns the local fallback: one
    # that answered "no such branch" means the base is gone, and forking from
    # a stale local copy of it would build on work nobody will merge; one
    # that has the base but failed the fetch could leave a stale ref.
    local st=0
    origin_has_branch "$base" || st=$?
    [ "$st" -ne 2 ] || die "base branch $base does not exist on origin - push it, or $remedy"
    [ "$st" -ne 0 ] || die "could not fetch $base from origin"
    if git rev-parse --verify --quiet "refs/remotes/origin/$base" >/dev/null; then
      __nbs_start="refs/remotes/origin/$base"
    else
      __nbs_start="refs/heads/$base"
    fi
  fi
  printf -v "$__nbs_out" '%s' "$__nbs_start"
}

# fork_new_branch <name> <start>: the checkout half, after
# new_branch_start decided the start point: checks out exactly that start
# point, with no fallback of its own.
fork_new_branch() {
  local name="$1" start="$2" err
  # --no-track: the base is recorded in the branch's own config, so the
  # upstream branch.autoSetupMerge would set is never wanted; pr publish sets
  # the real one on the first push.
  capture_err err git checkout -q --no-track -b "$name" "$start" \
    || die "could not create $name from $start: $err"
}

# branch_upstream <branch>: prints <branch>'s upstream ref in full
# (refs/remotes/origin/<b>), or returns 1 when it has none. The one place an
# upstream is read, never through --abbrev-ref: that abbreviates an ambiguous
# name - beside a local branch or tag named origin/<b> - to remotes/origin/<b>
# instead of the bare short name (#1331).
branch_upstream() {
  git rev-parse --symbolic-full-name --verify --quiet "$1@{upstream}" 2>/dev/null
}

# --- plugin-made branches: config keys, names and the verdict --------------
# The one home of every orchestrator-* git config key and of every plugin
# branch name: no other module spells a key or builds or matches a name. A
# getter prints the value, or nothing and returns non-zero when the key is
# unset; a setter returns the status of its git config write.

# Each key is spelled once, in its <key>_key function; its getter and setter
# both go through it.
branch_base_key() { printf 'branch.%s.orchestrator-base\n' "$1"; }
branch_base_sha_key() { printf 'branch.%s.orchestrator-base-sha\n' "$1"; }
branch_pr_key() { printf 'branch.%s.orchestrator-pr\n' "$1"; }
# branch_retired_key <branch>: the key branch retire records on a branch a redo
# retired, so no name says it (#2550).
branch_retired_key() { printf 'branch.%s.orchestrator-retired\n' "$1"; }
# forked_from_key <branch>: the git config key that records the branch ticket
# branch <branch> was forked from.
forked_from_key() { printf 'branch.%s.orchestrator-ticket-parent\n' "$1"; }

branch_base_get() { git config --get "$(branch_base_key "$1")" 2>/dev/null; }
branch_base_set() { git config "$(branch_base_key "$1")" "$2"; }
branch_base_sha_get() { git config --get "$(branch_base_sha_key "$1")" 2>/dev/null; }
branch_base_sha_set() { git config "$(branch_base_sha_key "$1")" "$2"; }
branch_pr_get() { git config --get "$(branch_pr_key "$1")" 2>/dev/null; }
branch_pr_set() { git config "$(branch_pr_key "$1")" "$2"; }
branch_retired_set() { git config "$(branch_retired_key "$1")" true; }
# branch_is_retired <branch>: succeeds when a redo retired <branch>.
branch_is_retired() { [ "$(git config --get "$(branch_retired_key "$1")" 2>/dev/null)" = true ]; }

# forked_from_branch <branch>: prints the forked-from branch recorded on
# ticket branch <branch> (its ticket parent), or prints nothing and returns
# non-zero when none is recorded.
forked_from_branch() { git config --get "$(forked_from_key "$1")" 2>/dev/null; }
forked_from_set() { git config "$(forked_from_key "$1")" "$2"; }

# Name builders. A flow's branch from its issue and slug, its redo form from
# that and a redo count, a ticket branch from its forked-from branch and
# ticket number, and a quick implementation's branch from issue and slug.
branch_name_flow() { printf 'orch/%s-%s\n' "$1" "$2"; }
branch_name_redo() { printf '%s-redo-%s\n' "$(branch_name_flow "$1" "$2")" "$3"; }
branch_name_ticket() { printf '%s--t%s\n' "$1" "$2"; }
branch_name_quick() { printf 'quick/%s-%s\n' "$1" "$2"; }

# branch_issue_of <name>: prints the issue number of a flow or quick branch
# name - the digits after orch/ or quick/ up to the first `-` - and fails
# unless that run is non-empty, all digits and followed by a non-empty slug.
branch_issue_of() {
  local rest issue slug
  case "$1" in
    orch/*) rest="${1#orch/}" ;;
    quick/*) rest="${1#quick/}" ;;
    *) return 1 ;;
  esac
  case "$rest" in *-*) ;; *) return 1 ;; esac
  issue="${rest%%-*}"
  slug="${rest#*-}"
  case "$issue" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$slug" ] || return 1
  printf '%s\n' "$issue"
}

# branch_kind <branch>: prints what kind of branch <branch> is, reading git
# config and the name only. A plugin-made branch is a `ticket` (a ticket
# parent is recorded), a `flow` (a base is recorded and the name is
# orch/<issue>-<slug>, redo form included) or a `quick` (a base is recorded
# and the name is anything else); every other branch is `foreign`.
branch_kind() {
  if forked_from_branch "$1" >/dev/null; then
    echo ticket
  elif branch_base_get "$1" >/dev/null; then
    case "$1" in
      orch/*) if branch_issue_of "$1" >/dev/null; then echo flow; else echo quick; fi ;;
      *) echo quick ;;
    esac
  else
    echo foreign
  fi
}

# branch_records_base <branch>: succeeds when <branch> is a plugin-made branch
# that records a base - a flow's or a quick implementation's branch, never a
# ticket branch - and fails otherwise. Asks branch_kind, the one definition of
# branch kinds.
branch_records_base() {
  case "$(branch_kind "$1")" in flow|quick) return 0 ;; *) return 1 ;; esac
}

# branch_held <branch>: succeeds when this checkout's flow state records
# <branch> as the flow's branch, in any phase. Reads flow state only.
branch_held() {
  [ -f "$STATE" ] && [ "$(state_get branch)" = "$1" ]
}

# discard_own_branch_work <who> <branch>: the Discard rule's prelude and the
# discard in one: proves <branch> is the caller's own, then runs
# discard_flow_branch_work. Own is the branch the flow holds, in any phase;
# else, with an active flow, the flow-branch proof dies on it; with none, a
# `quick` branch. Called as a bare statement, so a die stops the caller.
discard_own_branch_work() {
  local who="$1" b="$2"
  if ! branch_held "$b"; then
    if flow_active; then
      require_flow_branch "$who" "$b"
    elif [ "$(branch_kind "$b")" != quick ]; then
      die "$who: no active flow, and $b is not a quick implementation's branch - nothing was discarded"
    fi
  fi
  discard_flow_branch_work
}

# discard_create_work <name>: the Discard rule's decision for both `branch
# create` paths, <name> being the flow's branch. On the flow's own branch, or a
# detached HEAD with no rebase in progress, it applies discard_flow_branch_work.
# On any other branch - foreign, or plugin-made but not the flow's - it
# discards nothing: a clean tree (no merge or rebase in progress) returns so
# the caller goes on, and a dirty one dies, exit 1, naming that branch.
# Called as a bare statement, so a die stops the caller.
discard_create_work() {
  # shellcheck disable=SC2034 # out-params the caller does not need
  local name="$1" b merging rebasing dirty
  if ! b="$(checkout_branch_or_rebasing "$ROOT")" || [ "$b" = "$name" ]; then
    discard_flow_branch_work
    return
  fi
  if work_to_discard merging rebasing dirty; then
    die "branch create: the current branch $b is not the flow's branch $name - nothing was discarded"
  fi
}

# Records <base> and <sha> as branch <name>'s base and base SHA in its git
# config, where branch sync and branch base-sha read them.
record_branch_base() {
  branch_base_set "$1" "$2"
  branch_base_sha_set "$1" "$3"
}

# A restarted implement phase finds the flow's own branch already made: when
# state.branch records the name it would create and that branch exists, it is
# checked out if not current and printed, with base_sha and the branch's
# recorded base untouched (ADR-0054). Any other existing branch is still
# refused. It refuses a busy checkout with exit 3 - a branch the plugin made
# with no PR yet and not retired by a redo, except the flow's own - but not on
# the flow signal, since the flow mid-pipeline is its own. Uncommitted or
# in-progress work is the discard rule's (discard_create_work, on both paths),
# applied before anything else changes: discarded on the flow's own branch or
# a detached HEAD, or refused in an interactive main checkout; on any other
# branch never discarded, and refused while the tree is dirty or a merge or
# rebase is in progress.
# Besides state, it records the base and base SHA in the branch's git
# config, as branch off does, so branch sync and branch base-sha still find
# them once the flow is done or archived.
cmd_branch_create() {
  require_state
  [ $# -eq 0 ] || die "usage: orch.sh branch create"
  local slug issue name base sha own="" start
  slug="$(state_get slug)"
  require_issue issue
  name="$(branch_name_flow "$issue" "$slug")"
  if branch_held "$name" && git rev-parse --verify --quiet "refs/heads/$name" >/dev/null; then
    own=1
  fi
  if [ -n "$own" ]; then
    discard_create_work "$name"
    [ "$(checkout_branch)" = "$name" ] || git checkout -q "$name" \
      || die "could not check out $name"
    note "$name"
    return
  fi
  refuse_busy_checkout branch
  # The start point comes before the discard, so a refusal exits with
  # nothing written.
  base="$(flow_base)"
  new_branch_start start "$name" "$base" \
    "point this flow at another base: orch.sh base set <branch> --flow"
  discard_create_work "$name"
  fork_new_branch "$name" "$start"
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
# flow's base_sha has, for its reviewers to diff from. It refuses a busy
# checkout with exit 3, every signal applying, so it never moves another
# implementation's branch or carries its uncommitted edits.
cmd_branch_off() {
  [ $# -eq 1 ] || die "usage: orch.sh branch off <name>"
  refuse_busy_checkout flow branch tree
  local base
  base="$(base_branch)"
  checkout_new_branch "$1" "$base"
  record_branch_base "$1" "$base" "$(git rev-parse HEAD)"
  note "$1"
}

# Whether this checkout is a busy checkout, every signal applying: exit 3 with
# the one line naming what holds it, exit 0 printing nothing when it is free,
# exit 1 on a usage error or a working tree that cannot be read. Exit 3 is used
# by no other failure, so a skill can branch on it.
cmd_branch_busy() {
  [ $# -eq 0 ] || die "usage: orch.sh branch busy"
  local line remedy
  checkout_busy line remedy flow branch tree
  [ -z "$line" ] || { note "$line"; exit 3; }
}

# The current branch's base SHA, as branch off, branch create or branch sync
# recorded it. A branch made
# before that was recorded falls back to the merge-base with its recorded_base,
# preferring origin's copy of it. Only a fallback: a base merged in mid-branch
# moves the merge-base and silently shrinks the diff it bounds.
cmd_branch_base_sha() {
  [ $# -eq 0 ] || die "usage: orch.sh branch base-sha"
  local branch sha base ref
  current_branch_or_die
  sha="$(branch_base_sha_get "$branch")" || sha=""
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

# on_origin_base <sha> <base>: succeeds when the local origin/<base> resolves
# and <sha> is on it - its tip or an ancestor of it.
on_origin_base() {
  git rev-parse --verify --quiet "refs/remotes/origin/$2" >/dev/null \
    && git merge-base --is-ancestor "$1" "refs/remotes/origin/$2"
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
# nothing left to merge - retries the push.
# A merge in progress whose MERGE_HEAD is on origin's local base ref is a
# pending base merge a failed sync left: exit 3, nothing fetched or moved, so a
# resolver resumes it; any other merge in progress is refused with exit 1.
# --finish, never a plain rerun, finishes a resolved conflict without
# fetching: HEAD must be a merge commit whose second parent is on the local
# origin/<base> and no merge may be in progress, else exit 1 with nothing
# moved. It records that second parent as the base SHA and pushes, leaving a
# newer base tip for the next sync.
cmd_branch_sync() {
  local finish=""
  case "$*" in
    "") ;;
    --finish) finish=1 ;;
    *) die "usage: orch.sh branch sync [--finish]" ;;
  esac
  local branch base held="" tip remote why mh
  current_branch_or_die ' - nothing was synced'
  require_state_readable
  if branch_held "$branch"; then
    held=1
    base="$(flow_base)"
  else
    if branch_records_base "$branch"; then
      base="$(branch_base_get "$branch")"
    else
      die "$branch is not a branch the plugin made: no flow here holds it and it records no base - nothing was synced"
    fi
  fi
  [ "$branch" != "$base" ] || die "$branch is its own base branch - nothing was synced"
  if [ -n "$finish" ]; then
    if merge_in_progress "$ROOT"; then
      die "a merge is in progress on $branch - commit it (or git merge --abort), then rerun orch.sh branch sync --finish; nothing was synced"
    fi
    tip="$(git rev-parse --verify --quiet "HEAD^2^{commit}")" \
      || die "HEAD of $branch is not a merge commit - nothing to finish; nothing was synced"
    on_origin_base "$tip" "$base" \
      || die "the second parent of HEAD is not on origin/$base - nothing to finish; nothing was synced"
  else
    if merge_in_progress "$ROOT"; then
      mh="$(git rev-parse --verify --quiet MERGE_HEAD)"
      if on_origin_base "$mh" "$base"; then
        warn "a merge of origin/$base into $branch is pending resolution - the merge is left in progress; resolve and commit it, then run orch.sh branch sync --finish"
        exit 3
      fi
      die "a merge is in progress on $branch - commit it (or git merge --abort), then rerun orch.sh branch sync"
    fi
    require_clean_tree "$ROOT" "the working tree is dirty - commit or discard its changes first; nothing was synced"
    git fetch --quiet origin "+refs/heads/$base:refs/remotes/origin/$base" 2>/dev/null \
      || die "could not fetch $base from origin - nothing was synced"
    tip="$(git rev-parse "refs/remotes/origin/$base")"
    if ! git merge --quiet --no-edit "refs/remotes/origin/$base" >/dev/null 2>&1; then
      if merge_in_progress "$ROOT"; then
        warn "merging origin/$base into $branch hit a conflict - the merge is left in progress; resolve and commit it, then run orch.sh branch sync --finish"
        exit 3
      fi
      die "git could not merge origin/$base into $branch"
    fi
  fi
  branch_base_sha_set "$branch" "$tip"
  [ -z "$held" ] || state_write_string base_sha "$tip"
  # Its own upstream only: a branch made before branch create and branch off
  # passed --no-track (#1152) may still track its base until its first push.
  if [ "$(git config --get "branch.$branch.merge" 2>/dev/null)" = "refs/heads/$branch" ]; then
    remote="$(git config --get "branch.$branch.remote" 2>/dev/null)" || remote=origin
    git_push why --quiet "$remote" "refs/heads/$branch:refs/heads/$branch" \
      || die "could not push $branch - the merge and base SHA are recorded; rerun orch.sh branch sync${finish:+ --finish} to push: $why"
  fi
  note "$branch synced with origin/$base at $tip"
}

cmd_branch() {
  local op="${1:-}"
  shift || true
  case "$op" in
    create) cmd_branch_create "$@" ;;
    off)    cmd_branch_off "$@" ;;
    busy)   cmd_branch_busy "$@" ;;
    base-sha) cmd_branch_base_sha "$@" ;;
    sync)   cmd_branch_sync "$@" ;;
    retire)
      [ $# -eq 2 ] || die "usage: orch.sh branch retire <old> <new>"
      local old="$1" new="$2" upstream="" old_ok=1 new_ok=1 why resumed=0 st=0
      git rev-parse --verify --quiet "refs/heads/$old" >/dev/null 2>&1 || old_ok=0
      git rev-parse --verify --quiet "refs/heads/$new" >/dev/null 2>&1 || new_ok=0
      if [ "$old_ok" = 1 ] && [ "$new_ok" = 1 ]; then
        die "branch $new already exists"
      elif [ "$old_ok" = 0 ] && [ "$new_ok" = 0 ]; then
        die "branch $old does not exist"
      elif [ "$old_ok" = 1 ]; then
        upstream="$(branch_upstream "$old")" || upstream=""
        git branch -m "$old" "$new"
      else
        # $old is already gone and $new already exists: a previous call renamed
        # locally (issue #63). That state is also what a completed retire
        # leaves, local-only or not, so it does not say a remote step remains:
        # origin's own answer for $old does. Still there - the previous call
        # died before its remote steps finished, so resume them. Answered no -
        # nothing remote is left and this call changes nothing. Not answered
        # - guess neither way and die, so a rerun can ask again. This call
        # made no rename, so it never rolls one back.
        resumed=1
        origin_has_branch "$old" || st=$?
        case "$st" in
          0) upstream=origin ;;
          2) ;;
          *) die "could not reach origin to check whether $old is still there - nothing was changed; rerun orch.sh branch retire $old $new" ;;
        esac
      fi
      # A leftover remote ref under the un-suffixed name is exactly what the
      # next implement attempt's branch create/pr open will reuse, and their
      # plain push is not a force-push - so the old ref's delete is not
      # optional, and both failures die rather than leaving origin out of
      # sync with the local rename, this call's or a previous one's.
      if [ -n "$upstream" ]; then
        # The fresh arm's rename is local-only and free to undo - if the push
        # never lands, undoing it is what keeps `$old` a real, retryable
        # branch instead of a name a retry can no longer find. The resume arm
        # made no rename in this call, so it leaves it be.
        git_push why -q -u origin "refs/heads/$new:refs/heads/$new" \
          || { [ "$resumed" = 1 ] || git branch -m "$new" "$old"; die "could not push $new to origin: $why"; }
        if ! git_push why -q origin --delete "refs/heads/$old"; then
          # Already gone - a previous call's delete already succeeded before
          # something else failed - is not an error to retry into; only a
          # ref that is still there and won't go is.
          git ls-remote --exit-code origin "refs/heads/$old" >/dev/null 2>&1 \
            && die "could not delete origin/$old: $why"
        fi
      fi
      branch_retired_set "$new" \
        || die "could not record $(branch_retired_key "$new") - $new is retired; rerun orch.sh branch retire $old $new to record it"
      note "$new"
      ;;
    *) die "unknown branch op: ${op:-<none>} (want create|off|busy|base-sha|sync|retire)" ;;
  esac
}
