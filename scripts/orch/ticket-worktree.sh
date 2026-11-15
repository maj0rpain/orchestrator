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

# Prints <n> <path> for every ticket worktree under the checkout at <root>;
# dies when the checkouts cannot be read, never reading that as none.
ticket_worktrees_under() {
  local path name paths=()
  # shellcheck disable=SC2034 # checkout_parse fills it
  local branches=()
  checkout_parse || checkouts_unreadable
  for path in "${paths[@]}"; do
    checkout_ticket_path "$path" "$1" || continue
    name="${path##*/}"
    note "${name#t} $path"
  done
}

# refuse_ticket_worktrees <root> <reason>: dies, naming every ticket worktree
# under the checkout at <root> and the command that removes each, when any is
# left. <reason>, required, is the clause after the dash: why the caller
# cannot proceed.
refuse_ticket_worktrees() {
  local left reason="$2"
  # Its die exits only the substitution, so its status is carried out here.
  left="$(ticket_worktrees_under "$1")" || exit $?
  [ -n "$left" ] || return 0
  die "ticket worktrees are left under $1 - $reason:
$(while read -r n path; do printf '       %s (orch.sh ticket-worktree remove %s)\n' "$path" "$n"; done <<<"$left")
     Remove each with orch.sh ticket-worktree remove <n> first."
}

# ticket_facts <n> <prefix>: reads everything about ticket <n> once and only
# reports, each fact into the caller's variable <prefix>_<name> (printf -v),
# and writes no variable outside that prefix. <n> is already validated by the
# caller. The facts:
#   <prefix>_n          <n>, so the helpers handed only the prefix can name it
#   <prefix>_path       where ticket <n>'s ticket worktree lives
#   <prefix>_worktree   the worktree state, one word: worktree (one sits at the
#                       path), gone (git's record names the path and nothing is
#                       there), occupied (git's record names the path and
#                       something that is not a worktree is there) or none (a
#                       leftover directory with no record behind it is none)
#   <prefix>_wt_branch  the branch checked out in the ticket worktree; empty
#                       during a rebase and in every state but worktree
#   <prefix>_parent     this checkout's current branch; empty on a detached HEAD
#   <prefix>_own_branch the ticket's own branch <parent>--t<n>; ""
#                       when parent is empty
#   <prefix>_own_exists yes or no: whether own_branch exists
# Reads git's record of the checkouts on every call and dies, exit 1, only
# when it cannot be read, never reading that as none. Called as a bare
# statement, so that die stops the caller.
ticket_facts() {
  local _tf_n="$1" _tf_prefix="$2" _tf_path _tf_state=none _tf_wt="" _tf_parent="" _tf_own="" _tf_exists=no
  local paths=()
  local branches=()
  _tf_path="$(ticket_worktree_path "$_tf_n")"
  checkout_parse || checkouts_unreadable
  local _tf_i=-1 _tf_k
  for _tf_k in "${!paths[@]}"; do
    [ "${paths[_tf_k]}" = "$_tf_path" ] && { _tf_i=$_tf_k; break; }
  done
  if [ "$(git -C "$_tf_path" rev-parse --show-toplevel 2>/dev/null)" = "$_tf_path" ]; then
    _tf_state=worktree
    # checkout_parse stores "-" for a detached checkout; read as empty.
    if [ "$_tf_i" -ge 0 ] && [ "${branches[_tf_i]}" != "-" ]; then _tf_wt="${branches[_tf_i]}"; fi
  elif [ "$_tf_i" -ge 0 ]; then
    if [ -e "$_tf_path" ] || [ -L "$_tf_path" ]; then _tf_state=occupied; else _tf_state=gone; fi
  fi
  orch_load branch
  _tf_parent="$(checkout_branch)" || _tf_parent=""
  if [ -n "$_tf_parent" ]; then
    _tf_own="$(branch_name_ticket "$_tf_parent" "$_tf_n")"
    if git rev-parse --verify --quiet "refs/heads/$_tf_own" >/dev/null; then _tf_exists=yes; fi
  fi
  printf -v "${_tf_prefix}_n" %s "$_tf_n"
  printf -v "${_tf_prefix}_path" %s "$_tf_path"
  printf -v "${_tf_prefix}_worktree" %s "$_tf_state"
  printf -v "${_tf_prefix}_wt_branch" %s "$_tf_wt"
  printf -v "${_tf_prefix}_parent" %s "$_tf_parent"
  printf -v "${_tf_prefix}_own_branch" %s "$_tf_own"
  printf -v "${_tf_prefix}_own_exists" %s "$_tf_exists"
}

# ticket_facts_require_worktree <prefix> <state>...: dies, "no ticket worktree
# for ticket <n> at <path>", unless the worktree state in <prefix>'s facts is
# one of the <state>s its caller accepts.
ticket_facts_require_worktree() {
  local state_var="$1_worktree" n_var="$1_n" path_var="$1_path" s
  shift
  for s in "$@"; do
    [ "${!state_var}" != "$s" ] || return 0
  done
  die "no ticket worktree for ticket ${!n_var} at ${!path_var}"
}

# ticket_facts_require_wt_branch <prefix>: dies unless the ticket worktree in
# <prefix>'s facts is on a branch.
ticket_facts_require_wt_branch() {
  local branch_var="$1_wt_branch" path_var="$1_path"
  [ -n "${!branch_var}" ] \
    || die "ticket worktree ${!path_var} is not on a branch (detached HEAD)"
}

# ticket_facts_require_parent <prefix>: dies unless this checkout is on a
# branch, through current_branch_or_die so that message keeps its one home.
# That helper assigns the caller's `branch`, so the local `branch` below takes
# its write and no caller's variable is touched.
ticket_facts_require_parent() {
  # shellcheck disable=SC2034 # current_branch_or_die assigns it, so it stays local
  local parent_var="$1_parent" branch
  [ -z "${!parent_var}" ] || return 0
  current_branch_or_die
}

# ticket_branch_merged <branch>: whether ticket branch <branch> records a
# forked-from branch and is an ancestor of it - the one merged check.
ticket_branch_merged() {
  local parent
  parent="$(forked_from_branch "$1")" || return 1
  git merge-base --is-ancestor "refs/heads/$1" "refs/heads/$parent" 2>/dev/null
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
  local n f_n f_path f_worktree f_wt_branch f_parent f_own_branch f_own_exists
  n="$(ticket_worktree_number "$1")"
  ticket_facts "$n" f
  ticket_facts_require_parent f
  local path="$f_path" parent="$f_parent" tbranch="$f_own_branch"
  [ ! -e "$path" ] || die "ticket worktree $path already exists"
  [ "$f_own_exists" = no ] || die "branch $tbranch already exists"
  exclude_orch_dirs
  git branch -q --no-track "$tbranch" HEAD || die "could not create branch $tbranch"
  if ! git worktree add -q "$path" "$tbranch" \
     || ! forked_from_set "$tbranch" "$parent"; then
    # A freshly added worktree holds nothing of anyone's, so no force is
    # needed to take it back out; -D deletes the branch's config section too.
    if [ -e "$path" ]; then git worktree remove "$path" 2>/dev/null || true; fi
    git branch -q -D "$tbranch" 2>/dev/null || true
    die "could not add ticket worktree $path - removed branch $tbranch again"
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

# The statuses ticket_worktree_teardown returns, one per removal step; each is
# outside 0, 1, 2 and 3, which commands give their own meanings.
TICKET_TEARDOWN_WORKTREE_FAILED=10
TICKET_TEARDOWN_BRANCH_FAILED=11

# ticket_worktree_teardown <prefix> [--unmerged] [--discard]: the one site that
# tears a ticket worktree down, from the facts its caller read with
# ticket_facts into <prefix>; it reads none itself. The branch it deletes is
# always the ticket's own, never one the worktree merely has checked out (that
# one is left in place). --discard first discards the work in the worktree
# under the label "ticket #<n>". --unmerged aborts a rebase in progress there
# and skips the merged check of the ticket branch, which otherwise runs before
# anything is removed. A dirty worktree is refused and nothing is ever forced;
# the worktree is then removed and the ticket branch deleted with -D (the
# merged check, when it applies, already proved it merged into its forked-from
# branch, where -d would judge it against this checkout's HEAD). A refusal
# before anything is removed dies. A failed removal step prints its message and
# returns its own status, TICKET_TEARDOWN_WORKTREE_FAILED or
# TICKET_TEARDOWN_BRANCH_FAILED, leaving what already happened in place.
ticket_worktree_teardown() {
  local prefix="" unmerged=0 discard=0 have_wt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=1 ;;
      --discard) discard=1 ;;
      -*) die "ticket_worktree_teardown: unknown flag: $1" ;;
      *) [ -z "$prefix" ] || die "ticket_worktree_teardown: unexpected argument: $1"; prefix="$1" ;;
    esac
    shift
  done
  [ -n "$prefix" ] || die "usage: ticket_worktree_teardown <prefix> [--unmerged] [--discard]"
  ticket_facts_require_parent "$prefix"
  local n_var="${prefix}_n" path_var="${prefix}_path" state_var="${prefix}_worktree" \
    own_var="${prefix}_own_branch" exists_var="${prefix}_own_exists"
  local n="${!n_var}" path="${!path_var}" state="${!state_var}" tbranch="${!own_var}" own_exists="${!exists_var}"
  # Only a worktree at $path itself: a leftover t<n> directory's enclosing
  # checkout is not ours to discard, abort or remove.
  [ "$state" != occupied ] \
    || die "ticket worktree path $path holds something that is not a worktree, though git's record names it - delete it and run the command again"
  [ "$state" = none ] || have_wt=1
  # A record with its directory gone has nothing to discard, abort or check.
  if [ "$state" = worktree ]; then
    [ "$discard" = 0 ] || discard_work_in "$path" "ticket #$n"
    if [ "$unmerged" = 1 ] && rebase_in_progress "$path"; then
      git -C "$path" rebase --abort \
        || die "could not abort the rebase in progress in ticket worktree $path"
    fi
    require_clean_tree "$path" \
      "ticket worktree $path is dirty - commit or discard its changes first; it is never removed with force"
  elif [ "$state" = none ]; then
    [ "$own_exists" = yes ] \
      || die "no ticket worktree or branch for ticket $n at $path"
  fi
  [ "$unmerged" = 1 ] || ticket_branch_merged_or_die "$tbranch" "discard it"
  if [ "$have_wt" = 1 ]; then
    git worktree remove "$path" \
      || { warn "could not remove ticket worktree $path"; return "$TICKET_TEARDOWN_WORKTREE_FAILED"; }
  fi
  if [ "$own_exists" = yes ]; then
    git branch -q -D "$tbranch" \
      || { warn "could not delete branch $tbranch"; return "$TICKET_TEARDOWN_BRANCH_FAILED"; }
  fi
}

# Removes ticket <n>'s worktree and deletes its branch, never with --force:
# argument parsing over ticket_worktree_teardown, dying when there is no
# worktree and exiting 1 when either removal step fails.
cmd_ticket_worktree_remove() {
  # shellcheck disable=SC2034 # ticket_facts fills the f_ facts
  local n="" unmerged=() st=0 f_n f_path f_worktree f_wt_branch f_parent f_own_branch f_own_exists
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=(--unmerged) ;;
      -*) die "unknown flag: $1 (usage: orch.sh ticket-worktree remove <n> [--unmerged])" ;;
      *) [ -z "$n" ] || die "usage: orch.sh ticket-worktree remove <n> [--unmerged]"; n="$1" ;;
    esac
    shift
  done
  # Only that a worktree or git's record of one exists is required here: its
  # branch cannot be read, while a rebase leaves HEAD detached, until the
  # teardown has aborted the rebase. A record with something else at its path
  # is the teardown's refusal to make.
  n="$(ticket_worktree_number "$n")"
  ticket_facts "$n" f
  ticket_facts_require_worktree f worktree gone occupied
  ticket_worktree_teardown f ${unmerged[@]+"${unmerged[@]}"} || st=$?
  [ "$st" = 0 ] || exit 1
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
