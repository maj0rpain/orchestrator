# shellcheck shell=bash
# ticket-worktree.sh - orch.sh's ticket-worktree command: add, list and remove.
# Its tests: scripts/test/orch/ticket-worktree.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# --- ticket-worktree ----------------------------------------------------------
#
# A ticket's own worktree on its own ticket branch, so ticket subagents of one
# breakdown can build at once without sharing a working tree (ADR-0036). Each
# lives under the current checkout's top level - inside the session's project
# directory, so an implementer's edits draw no permission prompt - and is kept
# out of git status by the clone's exclude file.

# Forks <current-branch>--t<n> from the current branch's tip, records the
# forked-from branch on it, and checks it out at .orchestrator/worktrees/t<n>.
# The exclude entry is written before the branch exists; anything failing
# after that takes the worktree and the branch back out before dying.
cmd_ticket_worktree_add() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket-worktree add <n>"
  local n parent branch path
  n="$(ticket_worktree_number "$1")"
  parent="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
  branch="$parent--t$n"
  path="$(ticket_worktree_path "$n")"
  [ ! -e "$path" ] || die "ticket worktree $path already exists"
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    die "branch $branch already exists"
  fi
  exclude_orch_dirs
  git branch -q "$branch" HEAD || die "could not create branch $branch"
  if ! git worktree add -q "$path" "$branch" \
     || ! git config "$(forked_from_key "$branch")" "$parent"; then
    # A freshly added worktree holds nothing of anyone's, so no force is
    # needed to take it back out; -D deletes the branch's config section too.
    if [ -e "$path" ]; then git worktree remove "$path" 2>/dev/null || true; fi
    git branch -q -D "$branch" 2>/dev/null || true
    die "could not add ticket worktree $path - removed branch $branch again"
  fi
  note "$path"
}

# Prints <n> <path> for every ticket worktree under this checkout's
# .orchestrator/worktrees/, and nothing else: another checkout's ticket
# worktrees are that checkout's business.
cmd_ticket_worktree_list() {
  [ $# -eq 0 ] || die "usage: orch.sh ticket-worktree list"
  ticket_worktrees_under "$ROOT"
}

# Removes ticket <n>'s worktree and deletes its branch, never with --force.
# Both refusals - a dirty worktree, and without --unmerged a branch not merged
# into its forked-from branch - run before anything is removed. With
# --unmerged, a rebase left in progress there (a failed ticket-conflict
# resolution) is aborted first, returning the ticket branch to its committed
# tip, so the worktree is judged clean or dirty as that tip left it.
cmd_ticket_worktree_remove() {
  local n="" unmerged=0 path branch parent
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=1 ;;
      -*) die "unknown flag: $1 (usage: orch.sh ticket-worktree remove <n> [--unmerged])" ;;
      *) [ -z "$n" ] || die "usage: orch.sh ticket-worktree remove <n> [--unmerged]"; n="$1" ;;
    esac
    shift
  done
  if [ "$unmerged" = 1 ]; then
    path="$(ticket_worktree_path "$(ticket_worktree_number "$n")")"
    # Only a worktree at $path itself: git would resolve a leftover t<n>
    # directory to the enclosing checkout, whose rebase is not ours to abort.
    if [ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null)" = "$path" ] \
      && rebase_in_progress "$path"; then
      git -C "$path" rebase --abort \
        || die "could not abort the rebase in progress in ticket worktree $path"
    fi
  fi
  ticket_worktree_resolve "$n"
  require_clean_tree "$path" \
    "ticket worktree $path is dirty - commit or discard its changes first; it is never removed with force"
  if [ "$unmerged" = 0 ]; then
    parent="$(forked_from_branch "$branch")" \
      || die "branch $branch records no forked-from branch - pass --unmerged to discard it"
    git merge-base --is-ancestor "$branch" "$parent" 2>/dev/null \
      || die "branch $branch is not merged into $parent - merge it first, or pass --unmerged to discard it"
  fi
  git worktree remove "$path" || die "could not remove ticket worktree $path"
  # -D, not -d, either way: without --unmerged the merge-base check above
  # already proved the branch merged into its forked-from branch, while -d
  # would judge it against this checkout's HEAD (a ticket branch has no
  # upstream) and could refuse after the worktree is gone.
  git branch -q -D "$branch" || die "could not delete branch $branch"
}

cmd_ticket_worktree() {
  local op="${1:-}"
  shift || true
  case "$op" in
    add)    cmd_ticket_worktree_add "$@" ;;
    list)   cmd_ticket_worktree_list "$@" ;;
    remove) cmd_ticket_worktree_remove "$@" ;;
    *) die "unknown ticket-worktree op: ${op:-<none>} (want add|list|remove)" ;;
  esac
}
