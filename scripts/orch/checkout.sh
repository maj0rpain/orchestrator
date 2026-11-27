# shellcheck shell=bash
# checkout.sh - the Checkout module: a concept module with no orch.sh noun of
# its own, holding the facts about the repo's checkouts - the main checkout and
# the branch a checkout holds - that every other module reads. The checkout
# scan, kind classification and ticket-worktree listing are orch/checkout.py's,
# read by the converted nouns.
# Its tests: scripts/test/orch/checkout.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# checkout_parse: one `git worktree list --porcelain` (run from the current
# directory), read into the caller's `paths` list and
# matching `branches` list (git's own branch record, or - on a detached HEAD),
# which bash scopes dynamically. The one place the porcelain format is read.
# Fails when git worktree list fails.
checkout_parse() {
  local list line
  list="$(git worktree list --porcelain)" || return
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) paths+=("${line#worktree }"); branches+=("-") ;;
      "branch refs/heads/"*) branches[${#branches[@]} - 1]="${line#branch refs/heads/}" ;;
    esac
  done <<<"$list"
}

# The main checkout: the first entry git worktree list prints, unclassified -
# one git process, no marker read, no flow state. Fails, printing nothing,
# when the list fails or is empty.
main_checkout() {
  local paths=() branches=()
  checkout_parse || return 1
  [ "${#paths[@]}" -gt 0 ] || return 1
  printf '%s\n' "${paths[0]}"
}

# main_checkout_or_die: what main_checkout prints, or die "could not read the
# checkouts - git worktree list failed", the one place that message is spelled
# (checkouts_unreadable). Called in a substitution, where die exits only the
# subshell, so every caller carries the status out (|| exit $?).
checkouts_unreadable() { die "could not read the checkouts - git worktree list failed"; }
main_checkout_or_die() {
  main_checkout || checkouts_unreadable
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

# current_branch_or_die [<suffix>]: assigns the current branch to the caller's
# `branch`, which bash scopes dynamically, or dies with "not on a branch
# (detached HEAD)" and <suffix>. Called as a bare statement, so the die stops
# the caller.
current_branch_or_die() {
  # shellcheck disable=SC2034 # the caller's, scoped dynamically
  branch="$(checkout_branch)" || die "not on a branch (detached HEAD)${1-}"
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
#           (branch.<b>.orchestrator-pr); a detached HEAD never does, nor
#           does a branch a redo retired
#           (branch.<b>.orchestrator-retired, as branch retire records)
#   tree    changes outside the planning allowlist, as dirty_outside_allowlist
#           defines them
# The tree is read only when no earlier signal holds; a tree that cannot be
# read exits 1, never read as free or busy. Called as a bare statement, so
# that exit stops the caller.
checkout_busy() {
  local line_var="$1" remedy_var="$2" signals="${*:3}" fslug fphase flow_signal="" b dirty busy_line="" busy_remedy=""
  # The flow signal: one read of the slug and phase. A state file that cannot
  # be read counts as a running flow; a done phase is no flow.
  if word_listed "$signals" flow && [ -f "$STATE" ]; then
    if state_get_many_in "$STATE" fslug=slug fphase=phase; then
      [ "$fphase" = "done" ] || flow_signal=active
    else
      flow_signal=unreadable
    fi
  fi
  if [ -n "$flow_signal" ]; then
    if [ "$flow_signal" = active ]; then
      busy_line="busy: a flow is mid-pipeline (slug: $fslug, phase: $fphase)"
      busy_remedy="One flow at a time - finish it, or run $(flow_cmd abort)."
    else
      busy_line="busy: a flow's state.json cannot be read"
      busy_remedy="Run orch.sh doctor --flow, or $(flow_cmd abort)."
    fi
  elif word_listed "$signals" branch && b="$(checkout_branch)" \
    && branch_records_base "$b" \
    && ! branch_is_retired "$b" \
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

# refuse_busy_checkout <signal>...: the refusal shared by branch off and branch
# create, so neither ever moves another implementation's branch or carries its
# uncommitted edits; init, a converted noun, refuses through orch/checkout.py's
# copy. Checks the signals named, as checkout_busy
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

# checkout_gitdir_into <var> <path>: sets <var> to the absolute git folder of
# the checkout at <path>, read from its own git pointer without starting git
# for a readable pointer: <path>/.git is the git folder itself in a main
# worktree, and in a linked worktree a file whose "gitdir: <dir>" line names
# it, <dir> relative to <path> when it is not absolute, its . and .. parts
# resolved. When that read fails (the pointer is missing, unreadable or names
# no folder holding a HEAD, or <path> is no checkout's root) it asks git -C
# <path> rev-parse --absolute-git-dir, git's stderr silenced, so a failed
# resolve prints nothing. Fails, <var> untouched, only when git fails too.
checkout_gitdir_into() {
  local _cg_base="$2" _cg_ptr _cg_dir _cg_line=""
  case "$_cg_base" in /*) ;; *) _cg_base="$PWD/$_cg_base" ;; esac
  _cg_ptr="$_cg_base/.git"
  _cg_dir="$_cg_ptr"
  while :; do
    if [ -f "$_cg_ptr" ]; then
      { IFS= read -r _cg_line || [ -n "$_cg_line" ]; } 2>/dev/null <"$_cg_ptr" || break
      case "$_cg_line" in "gitdir: "?*) _cg_dir="${_cg_line#gitdir: }" ;; *) break ;; esac
      case "$_cg_dir" in /*) ;; *) _cg_dir="$_cg_base/$_cg_dir" ;; esac
      case "$_cg_dir" in
        */../*|*/./*|*/..|*/.)
          local _cg_out="" _cg_part _cg_parts
          IFS=/ read -ra _cg_parts <<<"$_cg_dir"
          for _cg_part in "${_cg_parts[@]}"; do
            case "$_cg_part" in
              ''|.) ;;
              ..) _cg_out="${_cg_out%/*}" ;;
              *) _cg_out="$_cg_out/$_cg_part" ;;
            esac
          done
          _cg_dir="$_cg_out" ;;
      esac
    fi
    [ -f "$_cg_dir/HEAD" ] || break
    printf -v "$1" '%s' "$_cg_dir"
    return 0
  done
  _cg_dir="$(git -C "$2" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  printf -v "$1" '%s' "$_cg_dir"
}

# Whether a rebase is in progress in the checkout at <path>.
rebase_in_progress() {
  local gitdir
  checkout_gitdir_into gitdir "$1" || return 1
  [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ]
}

# checkout_branch_or_rebasing [<path>]: checkout_branch, but a rebase in
# progress - which detaches HEAD - yields the branch it is rebasing, read from
# git's own rebase-merge/rebase-apply head-name record. Returns 1 on a
# detached HEAD with no rebase in progress.
checkout_branch_or_rebasing() {
  local gitdir file ref
  checkout_branch "$@" && return 0
  checkout_gitdir_into gitdir "${1:-.}" || return 1
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

# work_to_discard <merging-var> <rebasing-var> <dirty-var>: the one definition
# of "work to discard" in the current checkout ($ROOT): a merge in progress, a
# rebase in progress, a tree dirty outside the planning allowlist. Probes once
# and assigns the merging flag, the rebasing flag and the dirty-path list (as
# dirty_outside_allowlist prints it) to the named variables. Succeeds when any
# is set, fails when none is. A tree that cannot be read exits 1, never read as
# "no work to discard". Called as a bare statement or in a condition; the exit
# stops the caller.
work_to_discard() {
  local merging_v="" rebasing_v="" dirty_v
  ! merge_in_progress "$ROOT" || merging_v=1
  ! rebase_in_progress "$ROOT" || rebasing_v=1
  dirty_v="$(dirty_outside_allowlist)" || exit 1
  printf -v "$1" '%s' "$merging_v"
  printf -v "$2" '%s' "$rebasing_v"
  printf -v "$3" '%s' "$dirty_v"
  [ -n "$merging_v$rebasing_v$dirty_v" ]
}

# discard_flow_branch_work: the flow-branch case of the discard rule (ADR-0054),
# the one primitive every bash site meeting uncommitted or in-progress work a
# dead session left on the flow's own branch - or, for branch create, a
# detached HEAD (a side checkout's, with no rebase in progress) - applies:
# branch create (through discard_create_work, which proves the current branch
# is the flow's or detached; on any other branch it discards nothing); review
# resume and ticket reclaim run its Python copy in orch.checkout. Each caller
# first settles that the branch is the one to discard on; this primitive checks
# no ownership. In the current checkout ($ROOT): a merge or rebase in progress
# is aborted, and a tree dirty outside the planning allowlist is reset and
# cleaned. Nothing to discard changes
# nothing. In an interactive flow's main checkout - autopilot_active false and
# $ROOT's top level main_checkout's path, the one tree a human plausibly edits
# by hand - it refuses instead, exit 1, naming the exact discard command and
# writing nothing; telling the main checkout from the rest reads no marker. A
# failed abort, reset or clean dies (exit 1) naming the step. Called as a bare
# statement, so the die stops the caller.
discard_flow_branch_work() {
  local merging="" rebasing="" dirty top main cmds=""
  work_to_discard merging rebasing dirty || return 0
  if ! autopilot_active; then
    if ! top="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" ||
      ! main="$(cd "$top" && main_checkout)"; then
      die "could not tell whether $ROOT is the main checkout - nothing was discarded"
    fi
    if [ "$top" = "$main" ]; then
      [ -z "$merging" ] || cmds="git -C \"$ROOT\" merge --abort; "
      [ -z "$rebasing" ] || cmds="${cmds}git -C \"$ROOT\" rebase --abort; "
      die "uncommitted or in-progress work on the flow's branch in the main checkout - discard it yourself ($(list_join "$dirty")${merging:+ merge in progress}): ${cmds}git -C \"$ROOT\" reset --hard && git -C \"$ROOT\" clean -fd"
    fi
  fi
  discard_work_in "$ROOT" "could not discard"
}
