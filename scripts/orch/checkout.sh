# shellcheck shell=bash
# checkout.sh - the Checkout module: a concept module with no orch.sh noun of
# its own, holding the facts about the repo's checkouts - the main checkout,
# side checkouts, ticket worktrees and hand-made worktrees - that every other
# module reads. Its tests: scripts/test/orch/checkout.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# checkouts: the one walk over git worktree list. Prints one line per
# checkout, the main checkout first:
#
#   <kind> <flow> <branch> <path>
#
# <kind> is main for the first entry; ticket for a checkout whose parent
# directory is <checkout>/.orchestrator/worktrees for some listed checkout and
# whose name is t<n>, n a positive integer with no leading zero (whether or not
# it carries a side marker); side for one carrying the side-checkout ownership
# marker; hand-made for anything else - a worktree whose directory is gone
# included, unless its path is a ticket path. <flow> is 1 when the checkout
# holds a flow, else 0. <branch> is git's own record of the checked-out
# branch, or - on a detached HEAD. <path> comes last, so a path with spaces
# survives `read -r kind flow branch path`. Fails, printing nothing, when git
# worktree list fails.
checkouts() {
  local list line i kind flow paths=() branches=()
  list="$(git worktree list --porcelain)" || return
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) paths+=("${line#worktree }"); branches+=("-") ;;
      "branch refs/heads/"*) branches[${#branches[@]} - 1]="${line#branch refs/heads/}" ;;
    esac
  done <<<"$list"
  for i in "${!paths[@]}"; do
    if [ "$i" -eq 0 ]; then
      kind=main
    elif checkout_ticket_path "${paths[i]}" "${paths[@]}"; then
      kind=ticket
    elif side_checkout_marker "${paths[i]}" >/dev/null; then
      kind=side
    else
      kind=hand-made
    fi
    if checkout_has_flow "${paths[i]}"; then flow=1; else flow=0; fi
    printf '%s %s %s %s\n' "$kind" "$flow" "${branches[i]}" "${paths[i]}"
  done
}

# checkout_ticket_path <path> <checkout>...: whether <path> is a ticket
# worktree's path - t<n>, n a positive integer with no leading zero, directly
# under one <checkout>'s .orchestrator/worktrees.
checkout_ticket_path() {
  local path="$1" name="${1##*/}" root
  shift
  case "$name" in t[1-9]*) ;; *) return 1 ;; esac
  case "${name#t}" in *[!0-9]*) return 1 ;; esac
  for root in "$@"; do
    [ "${path%/*}" = "$root/$ORCH_DIR_NAME/worktrees" ] && return 0
  done
  return 1
}

# checkout_kind <path>: prints the walk's kind (main, ticket, side or
# hand-made) for the checkout holding <path> - a folder inside a checkout
# included - the one classification every site that asks a checkout's kind
# reads. Fails, printing nothing, when <path> is in no checkout, the walk
# fails, or no line of it matches.
checkout_kind() {
  local top list kind _flow _branch path
  top="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || return 1
  list="$(cd "$top" && checkouts)" || return 1
  while read -r kind _flow _branch path; do
    [ "$path" = "$top" ] && { printf '%s\n' "$kind"; return 0; }
  done <<<"$list"
  return 1
}

# checkouts_main <walk>: prints the main checkout's path from a walk already
# held: the parse of its first line. Prints nothing and fails on an empty walk.
checkouts_main() {
  local _kind _flow _branch path
  [ -n "$1" ] || return 1
  read -r _kind _flow _branch path <<<"${1%%$'\n'*}"
  printf '%s\n' "$path"
}

# The main checkout: the first checkout the walk prints. Fails, printing
# nothing, when the walk fails or prints nothing.
main_checkout() {
  local list
  list="$(checkouts)" || return 1
  checkouts_main "$list"
}

# checkouts_or_die / main_checkout_or_die: what checkouts / main_checkout
# print, or die "could not read the checkouts - git worktree list failed", the
# one place that message is spelled. Called in a substitution, where die exits
# only the subshell, so every caller carries the status out (|| exit $?).
checkouts_unreadable() { die "could not read the checkouts - git worktree list failed"; }
checkouts_or_die() {
  checkouts || checkouts_unreadable
}
main_checkout_or_die() {
  main_checkout || checkouts_unreadable
}

# The checkout that has <branch> checked out, or nothing: the first checkout
# the walk lists on <branch>, a worktree whose directory is gone included.
# Dies when the checkouts cannot be read; called in a substitution, so its
# caller carries that status out.
branch_checkout() {
  local list _kind _flow branch path
  list="$(checkouts_or_die)" || exit $?
  while read -r _kind _flow branch path; do
    if [ "$branch" = "$1" ]; then note "$path"; return 0; fi
  done <<<"$list"
}

# Whether the checkout at <path> holds a flow.
checkout_has_flow() { [ -f "$(flow_state_file "$1")" ]; }

# What the checkout at <path> holds: its flow (flow <slug> <phase> #<issue>),
# else its checked-out branch (branch <name>), else (no branch).
checkout_holding() {
  local state issue issue_label branch
  state="$(flow_state_file "$1")"
  if [ -f "$state" ]; then
    issue="$(state_get_in "$state" issue)"
    if [ -n "$issue" ]; then issue_label="#$issue"; else issue_label="(no issue)"; fi
    note "flow $(state_get_in "$state" slug) $(state_get_in "$state" phase) $issue_label"
  elif branch="$(checkout_branch "$1")"; then
    note "branch $branch"
  else
    note "(no branch)"
  fi
}

# checkout_branch [<path>]: prints the branch checked out in the checkout at
# <path> (default: the current directory); returns 1 on a detached HEAD. The
# one place `git symbolic-ref --quiet HEAD` is spelled: the ref is read in full
# and refs/heads/ stripped, never through --short, which abbreviates a name
# shared with a tag to heads/<name>.
checkout_branch() {
  local ref
  ref="$(git -C "${1:-.}" symbolic-ref --quiet HEAD)" || return 1
  printf '%s\n' "${ref#refs/heads/}"
}

# current_branch_or_die [die|die2] [<suffix>]: assigns the current branch to
# the caller's `branch`, which bash scopes dynamically, or dies through the
# dier (die, unless the first argument is literally die or die2) with
# "not on a branch (detached HEAD)" and <suffix>. Called as a bare statement,
# so the die stops the caller.
current_branch_or_die() {
  local dier=die
  case "${1-}" in die|die2) dier="$1"; shift ;; esac
  branch="$(checkout_branch)" || "$dier" "not on a branch (detached HEAD)${1-}"
}

# checkout_busy <line-var> <remedy-var> <signal>...: assigns to <line-var> the
# one line naming what makes this checkout a busy checkout - one holding work a
# new branch must not move - and to <remedy-var> what to do about it, or both
# empty when it is free. Reads local git
# and state facts only, never GitHub. The signals are checked in this order,
# the first that holds reported, and only those named apply, so each caller
# picks its own (#1198):
#   flow    a flow mid-pipeline (phase not done)
#   branch  the current branch records a base (branch.<b>.orchestrator-base,
#           as branch off and branch create write) but no PR
#           (branch.<b>.orchestrator-pr); a detached HEAD never does
#   tree    changes outside the planning allowlist, as dirty_outside_allowlist
#           defines them
# The tree is read only when no earlier signal holds; a tree that cannot be
# read exits 1, never read as free or busy. Called as a bare statement, so
# that exit stops the caller.
checkout_busy() {
  local line_var="$1" remedy_var="$2" signals="${*:3}" b dirty busy_line="" busy_remedy=""
  if word_listed "$signals" flow && flow_active; then
    busy_line="busy: a flow is mid-pipeline (slug: $(state_get slug), phase: $(state_get phase))"
    busy_remedy="One flow at a time - finish it, or run $(flow_cmd abort)."
  elif word_listed "$signals" branch && b="$(checkout_branch)" \
    && case "$(branch_kind "$b")" in flow|quick) true ;; *) false ;; esac \
    && ! branch_pr_get "$b" >/dev/null; then
    busy_line="busy: branch $b has no PR yet"
    busy_remedy="Open its PR, or switch off it."
  elif word_listed "$signals" tree; then
    dirty="$(dirty_outside_allowlist)" || exit 1
    [ -z "$dirty" ] || {
      busy_line="busy: the working tree has changes outside the planning allowlist: $(list_join "$dirty")"
      busy_remedy="Commit, stash, or discard these changes."
    }
  fi
  printf -v "$line_var" '%s' "$busy_line"
  printf -v "$remedy_var" '%s' "$busy_remedy"
}

# refuse_busy_checkout <signal>...: the refusal shared by branch off, branch
# create and init, so none of them ever moves another implementation's branch
# or carries its uncommitted edits. Checks the signals named, as checkout_busy
# does; in a busy checkout it warns with the line naming what holds it and its
# remedy, and exits 3, a code no other failure of those commands uses, so a
# skill can tell a busy checkout apart from every other refusal. A tree that
# cannot be read exits 1 inside checkout_busy. Called as a bare statement, so
# the exit stops the caller.
refuse_busy_checkout() {
  local line remedy
  checkout_busy line remedy "$@"
  [ -n "$line" ] || return 0
  warn "$line
     $remedy"
  exit 3
}

# Whether a merge is in progress in the checkout at <path>.
merge_in_progress() {
  git -C "$1" rev-parse --quiet --verify MERGE_HEAD >/dev/null 2>&1
}

# Whether a rebase is in progress in the checkout at <path>.
rebase_in_progress() {
  local gitdir
  gitdir="$(git -C "$1" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]
}

# checkout_branch_or_rebasing [<path>]: checkout_branch, but a rebase in
# progress - which detaches HEAD - yields the branch it is rebasing, read from
# git's own rebase-merge/rebase-apply head-name record. Returns 1 on a
# detached HEAD with no rebase in progress.
checkout_branch_or_rebasing() {
  local gitdir file ref
  checkout_branch "$@" && return 0
  gitdir="$(git -C "${1:-.}" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  for file in "$gitdir/rebase-merge/head-name" "$gitdir/rebase-apply/head-name"; do
    [ -f "$file" ] || continue
    ref="$(<"$file")"
    case "$ref" in refs/heads/?*) printf '%s\n' "${ref#refs/heads/}"; return 0 ;; esac
  done
  return 1
}

# discard_work_in <path> <who>: the discard sequence every site of the discard
# rule (ADR-0054) runs in the checkout at <path>: a merge or rebase in
# progress is aborted, then the tree is reset and cleaned. Nothing to discard
# changes nothing. A failed step dies "<who>: <git command> failed in <path>".
discard_work_in() {
  local path="$1" who="$2"
  if merge_in_progress "$path"; then
    git -C "$path" merge --abort >/dev/null 2>&1 || die "$who: git merge --abort failed in $path"
  fi
  if rebase_in_progress "$path"; then
    git -C "$path" rebase --abort >/dev/null 2>&1 || die "$who: git rebase --abort failed in $path"
  fi
  git -C "$path" reset --hard -q >/dev/null 2>&1 || die "$who: git reset --hard failed in $path"
  git -C "$path" clean -fdq >/dev/null 2>&1 || die "$who: git clean failed in $path"
}

# require_flow_branch <who> <branch>: dies (exit 1, "nothing was discarded")
# unless <branch> is the branch the flow state records, whatever the phase -
# the proof a discard-rule caller owes before it discards. It never asks
# whether the flow is active: each caller first settles that a flow state
# exists. Called as a bare statement, so the die stops the caller.
require_flow_branch() {
  local who="$1" b="$2" fb
  fb="$(state_get branch)" || die "$who: cannot read the flow's branch from $STATE"
  [ -n "$fb" ] || die "$who: on $b, the active flow records no branch yet - nothing was discarded"
  branch_held "$b" || die "$who: the current branch $b is not the flow's branch $fb - nothing was discarded"
}

# discard_flow_branch_work: the flow-branch case of the discard rule (ADR-0054),
# the one primitive every site meeting uncommitted or in-progress work a dead
# session left on the flow's own branch - or, for ticket reclaim, a quick
# implementation's own branch - applies: branch create now, ticket reclaim and
# review resume next. Each caller first settles that the branch is the one to
# discard on; this primitive checks no ownership. In the current checkout
# ($ROOT): a merge or rebase in progress is aborted, and a tree dirty outside
# the planning allowlist is reset and cleaned. Nothing to discard changes
# nothing. In an interactive flow's main checkout - autopilot_active false and
# checkout_kind main, the one tree a human plausibly edits by hand - it refuses
# instead, exit 1, naming the exact discard command and writing nothing. A
# failed abort, reset or clean dies (exit 1) naming the step. Called as a bare
# statement, so the die stops the caller.
discard_flow_branch_work() {
  local merging="" rebasing="" dirty kind cmds=""
  ! merge_in_progress "$ROOT" || merging=1
  ! rebase_in_progress "$ROOT" || rebasing=1
  dirty="$(dirty_outside_allowlist)" || exit 1
  [ -n "$merging$rebasing$dirty" ] || return 0
  if ! autopilot_active; then
    kind="$(checkout_kind "$ROOT")" || die "could not tell whether $ROOT is the main checkout - nothing was discarded"
    if [ "$kind" = main ]; then
      [ -z "$merging" ] || cmds="git -C \"$ROOT\" merge --abort; "
      [ -z "$rebasing" ] || cmds="${cmds}git -C \"$ROOT\" rebase --abort; "
      die "uncommitted or in-progress work on the flow's branch in the main checkout - discard it yourself ($(list_join "$dirty")${merging:+ merge in progress}): ${cmds}git -C \"$ROOT\" reset --hard && git -C \"$ROOT\" clean -fd"
    fi
  fi
  discard_work_in "$ROOT" "could not discard"
}
