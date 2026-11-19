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

# ticket_facts <n> <array>: reads everything about ticket <n> once and only
# reports, each fact into the caller's associative array <array> (declared
# with `local -A`) under its fact name, and writes nothing else. A <array>
# that is not a declared associative array dies (assoc_array_require), never
# becoming a silent global. <n> is already validated by the caller. The facts:
#   n          <n>, so the helpers handed only the array can name it
#   path       where ticket <n>'s ticket worktree lives
#   worktree   the worktree state, one word: worktree (one sits at the
#              path), gone (git's record names the path and nothing is
#              there), occupied (git's record names the path and
#              something that is not a worktree is there) or none (a
#              leftover directory with no record behind it is none)
#   wt_branch  the branch checked out in the ticket worktree; empty
#              during a rebase and in every state but worktree
#   parent     this checkout's current branch; empty on a detached HEAD
#   own_branch the ticket's own branch <parent>--t<n>; ""
#              when parent is empty
#   own_exists yes or no: whether own_branch exists
# Reads git's record of the checkouts on every call and dies, exit 1, only
# when it cannot be read, never reading that as none. Called as a bare
# statement, so that die stops the caller. Each fact is assigned by eval on
# the validated name, its value passed by reference, never interpolated.
ticket_facts() {
  local _tf_n="$1" _tf_array="$2" _tf_path _tf_state=none _tf_wt="" _tf_parent="" _tf_own="" _tf_exists=no
  local paths=()
  local branches=()
  assoc_array_require ticket_facts "$_tf_array" _tf_
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
  eval "${_tf_array}[n]=\$_tf_n"
  eval "${_tf_array}[path]=\$_tf_path"
  eval "${_tf_array}[worktree]=\$_tf_state"
  eval "${_tf_array}[wt_branch]=\$_tf_wt"
  eval "${_tf_array}[parent]=\$_tf_parent"
  eval "${_tf_array}[own_branch]=\$_tf_own"
  eval "${_tf_array}[own_exists]=\$_tf_exists"
}

# ticket_facts_require_worktree <array> <state>...: dies, "no ticket worktree
# for ticket <n> at <path>", unless the worktree state in <array>'s facts is
# one of the <state>s its caller accepts.
ticket_facts_require_worktree() {
  local state_ref="${1}[worktree]" n_ref="${1}[n]" path_ref="${1}[path]"
  local state="${!state_ref}" n="${!n_ref}" path="${!path_ref}"
  shift
  word_listed "$*" "$state" || die "no ticket worktree for ticket $n at $path"
}

# ticket_facts_require_wt_branch <array>: dies unless the ticket worktree in
# <array>'s facts is on a branch.
ticket_facts_require_wt_branch() {
  local branch_ref="${1}[wt_branch]" path_ref="${1}[path]"
  local wt_branch="${!branch_ref}" path="${!path_ref}"
  [ -n "$wt_branch" ] \
    || die "ticket worktree $path is not on a branch (detached HEAD)"
}

# ticket_facts_require_parent <array>: dies unless this checkout is on a
# branch, through current_branch_or_die so that message keeps its one home.
# That helper assigns the caller's `branch`, so the local `branch` below takes
# its write and no caller's variable is touched.
ticket_facts_require_parent() {
  # shellcheck disable=SC2034 # current_branch_or_die assigns it, so it stays local
  local parent_ref="${1}[parent]" branch
  local parent="${!parent_ref}"
  [ -z "$parent" ] || return 0
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
  local n
  local -A f
  n="$(ticket_worktree_number "$1")"
  ticket_facts "$n" f
  ticket_facts_require_parent f
  local path="${f[path]}" parent="${f[parent]}" own_branch="${f[own_branch]}"
  [ ! -e "$path" ] || die "ticket worktree $path already exists"
  [ "${f[own_exists]}" = no ] || die "branch $own_branch already exists"
  exclude_orch_dirs
  git branch -q --no-track "$own_branch" HEAD || die "could not create branch $own_branch"
  if ! git worktree add -q "$path" "$own_branch" \
     || ! forked_from_set "$own_branch" "$parent"; then
    # A freshly added worktree holds nothing of anyone's, so no force is
    # needed to take it back out; -D deletes the branch's config section too.
    if [ -e "$path" ]; then git worktree remove "$path" 2>/dev/null || true; fi
    git branch -q -D "$own_branch" 2>/dev/null || true
    die "could not add ticket worktree $path - removed branch $own_branch again"
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

# ticket_worktree_teardown <array> [--unmerged] [--discard]: the one site that
# tears a ticket worktree down, from the facts its caller read with
# ticket_facts into <array>; it reads none itself. The branch it deletes is
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
  local facts="" unmerged=0 discard=0 have_wt=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --unmerged) unmerged=1 ;;
      --discard) discard=1 ;;
      -*) die "ticket_worktree_teardown: unknown flag: $1" ;;
      *) [ -z "$facts" ] || die "ticket_worktree_teardown: unexpected argument: $1"; facts="$1" ;;
    esac
    shift
  done
  [ -n "$facts" ] || die "usage: ticket_worktree_teardown <array> [--unmerged] [--discard]"
  ticket_facts_require_parent "$facts"
  local n_ref="${facts}[n]" path_ref="${facts}[path]" state_ref="${facts}[worktree]" \
    own_ref="${facts}[own_branch]" exists_ref="${facts}[own_exists]"
  local n="${!n_ref}" path="${!path_ref}" state="${!state_ref}" own_branch="${!own_ref}" own_exists="${!exists_ref}"
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
  [ "$unmerged" = 1 ] || ticket_branch_merged_or_die "$own_branch" "discard it"
  if [ "$have_wt" = 1 ]; then
    git worktree remove "$path" \
      || { warn "could not remove ticket worktree $path"; return "$TICKET_TEARDOWN_WORKTREE_FAILED"; }
  fi
  if [ "$own_exists" = yes ]; then
    git branch -q -D "$own_branch" \
      || { warn "could not delete branch $own_branch"; return "$TICKET_TEARDOWN_BRANCH_FAILED"; }
  fi
}

# Removes ticket <n>'s worktree and deletes its branch, never with --force:
# argument parsing over ticket_worktree_teardown, dying when there is no
# worktree and exiting 1 when either removal step fails.
cmd_ticket_worktree_remove() {
  local n="" unmerged=() st=0
  local -A f
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
