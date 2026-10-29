# shellcheck shell=bash
# ticket-worktree.sh - orch.sh's ticket-worktree command: add, list and remove.
# Its tests: scripts/test/orch/ticket-worktree.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# A ticket's own worktree on its own ticket branch, so ticket subagents of one
# breakdown can build at once without sharing a working tree (ADR-0036). Each
# lives under the current checkout's top level - inside the session's project
# directory, so an implementer's edits draw no permission prompt - and is kept
# out of git status by the clone's exclude file.

# The ticket number <n> names, or die: digits only, not zero.
ticket_worktree_number() {
  case "$1" in
    ''|*[!0-9]*|0*) die "not a ticket number: ${1:-<none>} (want a positive integer)" ;;
  esac
  printf '%s\n' "$1"
}

# Where ticket worktrees live: under the checkout's .orchestrator/ folder.
readonly TICKET_WORKTREES="$ORCH/worktrees"

# ticket_worktree_path <n>: prints the path of ticket #<n>'s worktree.
ticket_worktree_path() { printf '%s/t%s\n' "$TICKET_WORKTREES" "$1"; }

# forked_from_key <branch>: the git config key that records the branch ticket
# branch <branch> was forked from - the one place code spells it out.
forked_from_key() { printf 'branch.%s.orchestrator-ticket-parent\n' "$1"; }

# forked_from_branch <branch>: prints the forked-from branch recorded on
# ticket branch <branch>, or prints nothing and returns non-zero when none is
# recorded.
forked_from_branch() { git config --get "$(forked_from_key "$1")" 2>/dev/null; }

# Prints <n> <path> for every ticket worktree under the checkout at <root>;
# dies when the checkouts cannot be read, never reading that as none.
ticket_worktrees_under() {
  local list _kind _flow _branch path name
  list="$(checkouts_or_die)" || exit $?
  while read -r _kind _flow _branch path; do
    checkout_ticket_path "$path" "$1" || continue
    name="${path##*/}"
    note "${name#t} $path"
  done <<<"$list"
}

# refuse_ticket_worktrees <root>: dies, naming every ticket worktree under the
# checkout at <root>, when any is left: moving .orchestrator/ wholesale would
# break git's record of each one, and removing the checkout would delete them.
refuse_ticket_worktrees() {
  local left
  # Its die exits only the substitution, so its status is carried out here.
  left="$(ticket_worktrees_under "$1")" || exit $?
  [ -n "$left" ] || return 0
  die "ticket worktrees are left under $1 - moving them would break git's record of them:
$(while read -r n path; do printf '       %s (orch.sh ticket-worktree remove %s)\n' "$path" "$n"; done <<<"$left")
     Remove each with orch.sh ticket-worktree remove <n> first."
}

# is_ticket_worktree <path>: whether a worktree sits at <path> itself - git
# would resolve a leftover t<n> directory to the enclosing checkout instead.
is_ticket_worktree() { [ "$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" = "$1" ]; }

# Resolves ticket <n>'s worktree for a command that acts on an existing one:
# dies unless <n> is a ticket number whose worktree exists and is on a branch.
# It assigns to the caller's `n`, `path` and `branch`, which bash scopes
# dynamically, and is called as a bare statement so `die` stops the caller.
ticket_worktree_resolve() {
  n="$(ticket_worktree_number "$1")"
  path="$(ticket_worktree_path "$n")"
  is_ticket_worktree "$path" \
    || die "no ticket worktree for ticket $n at $path"
  branch="$(checkout_branch "$path")" \
    || die "ticket worktree $path is not on a branch (detached HEAD)"
}

# ticket_branch_merged <branch>: whether ticket branch <branch> records a
# forked-from branch and is an ancestor of it - the one merged check.
ticket_branch_merged() {
  local parent
  parent="$(forked_from_branch "$1")" || return 1
  git merge-base --is-ancestor "$1" "$parent" 2>/dev/null
}

# ticket_branch_merged_or_die <branch> <what>: dies unless ticket_branch_merged
# holds, shared by ticket-worktree remove and ticket close. Each refusal ends
# "pass --unmerged to <what>", <what> naming the command's act.
ticket_branch_merged_or_die() {
  local parent
  parent="$(forked_from_branch "$1")" \
    || die "branch $1 records no forked-from branch - pass --unmerged to $2"
  ticket_branch_merged "$1" \
    || die "branch $1 is not merged into $parent - merge it first, or pass --unmerged to $2"
}

# Forks <current-branch>--t<n> from the current branch's tip, records the
# forked-from branch on it, and checks it out at .orchestrator/worktrees/t<n>.
# The exclude entry is written before the branch exists; anything failing
# after that takes the worktree and the branch back out before dying.
cmd_ticket_worktree_add() {
  [ $# -eq 1 ] || die "usage: orch.sh ticket-worktree add <n>"
  local n parent branch path
  n="$(ticket_worktree_number "$1")"
  current_branch_or_die
  parent="$branch"
  branch="$parent--t$n"
  path="$(ticket_worktree_path "$n")"
  [ ! -e "$path" ] || die "ticket worktree $path already exists"
  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    die "branch $branch already exists"
  fi
  exclude_orch_dirs
  git branch -q --no-track "$branch" HEAD || die "could not create branch $branch"
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

# ticket_worktree_teardown <n> [--unmerged] [--discard]: the one site that
# tears ticket <n>'s worktree down. The branch is the worktree's own, else -
# the worktree already gone - <current branch>--t<n>. --discard first discards
# the work in the worktree under the label "ticket #<n>". --unmerged aborts a
# rebase in progress there (returning the branch to its committed tip) and
# skips the merged check, which otherwise runs before anything is removed. A
# dirty worktree is refused and nothing is ever forced; the worktree is then
# removed and the branch deleted with -D (the merged check, when it applies,
# already proved it merged into its forked-from branch, where -d would judge
# it against this checkout's HEAD). With the branch alone left, it is deleted.
# Every refusal or failed step dies naming what failed, leaving what already
# happened in place.
ticket_worktree_teardown() {
  local n="" unmerged=0 discard=0 path branch have_wt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=1 ;;
      --discard) discard=1 ;;
      *) n="$1" ;;
    esac
    shift
  done
  n="$(ticket_worktree_number "$n")"
  path="$(ticket_worktree_path "$n")"
  # Only a worktree at $path itself: a leftover t<n> directory's enclosing
  # checkout is not ours to discard, abort or remove.
  if is_ticket_worktree "$path"; then
    have_wt=1
    [ "$discard" = 0 ] || discard_work_in "$path" "ticket #$n"
    if [ "$unmerged" = 1 ] && rebase_in_progress "$path"; then
      git -C "$path" rebase --abort \
        || die "could not abort the rebase in progress in ticket worktree $path"
    fi
    branch="$(checkout_branch "$path")" \
      || die "ticket worktree $path is not on a branch (detached HEAD)"
    require_clean_tree "$path" \
      "ticket worktree $path is dirty - commit or discard its changes first; it is never removed with force"
  else
    current_branch_or_die
    branch="$branch--t$n"
    git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
      || die "no ticket worktree or branch for ticket $n at $path"
  fi
  [ "$unmerged" = 1 ] || ticket_branch_merged_or_die "$branch" "discard it"
  if [ "$have_wt" = 1 ]; then
    git worktree remove "$path" || die "could not remove ticket worktree $path"
  fi
  git branch -q -D "$branch" || die "could not delete branch $branch"
}

# Removes ticket <n>'s worktree and deletes its branch, never with --force:
# argument parsing over ticket_worktree_teardown, dying when there is no
# worktree.
cmd_ticket_worktree_remove() {
  local n="" unmerged=() path
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=(--unmerged) ;;
      -*) die "unknown flag: $1 (usage: orch.sh ticket-worktree remove <n> [--unmerged])" ;;
      *) [ -z "$n" ] || die "usage: orch.sh ticket-worktree remove <n> [--unmerged]"; n="$1" ;;
    esac
    shift
  done
  n="$(ticket_worktree_number "$n")"
  path="$(ticket_worktree_path "$n")"
  is_ticket_worktree "$path" || die "no ticket worktree for ticket $n at $path"
  ticket_worktree_teardown "$n" ${unmerged[@]+"${unmerged[@]}"}
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
