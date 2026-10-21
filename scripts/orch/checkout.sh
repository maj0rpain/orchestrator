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

# The main checkout: the first checkout the walk prints. Fails, printing
# nothing, when the walk fails or prints nothing.
main_checkout() {
  local list _kind _flow _branch path
  list="$(checkouts)" && [ -n "$list" ] || return 1
  read -r _kind _flow _branch path <<<"${list%%$'\n'*}"
  printf '%s\n' "$path"
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
# one place `git symbolic-ref --quiet --short HEAD` is spelled.
checkout_branch() { git -C "${1:-.}" symbolic-ref --quiet --short HEAD; }

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

# checkout_busy <var> <held-var> <signal>...: assigns to <var> the one line
# naming what makes this checkout a busy checkout - one holding work a new
# branch must not move - or empty when it is free, and to <held-var> the name
# of the signal that holds (flow, branch or tree), or empty. Reads local git
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
  local var="$1" held_var="$2" signals=" ${*:3} " b dirty busy_line="" busy_signal=""
  if [[ "$signals" == *" flow "* ]] && flow_active; then
    busy_signal=flow
    busy_line="busy: a flow is mid-pipeline (slug: $(state_get slug), phase: $(state_get phase))"
  elif [[ "$signals" == *" branch "* ]] && b="$(checkout_branch)" \
    && git config --get "branch.$b.orchestrator-base" >/dev/null 2>&1 \
    && ! git config --get "branch.$b.orchestrator-pr" >/dev/null 2>&1; then
    busy_signal=branch
    busy_line="busy: branch $b has no PR yet"
  elif [[ "$signals" == *" tree "* ]]; then
    dirty="$(dirty_outside_allowlist)" || exit 1
    [ -z "$dirty" ] || {
      busy_signal=tree
      busy_line="busy: the working tree has changes outside the planning allowlist: ${dirty//$'\n'/, }"
    }
  fi
  printf -v "$var" '%s' "$busy_line"
  printf -v "$held_var" '%s' "$busy_signal"
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
  local line signal remedy
  checkout_busy line signal "$@"
  [ -n "$signal" ] || return 0
  case "$signal" in
    flow) remedy="One flow at a time - finish it, or run $(flow_cmd abort)." ;;
    branch) remedy="Open its PR, or switch off it." ;;
    tree) remedy="Commit, stash, or discard these changes." ;;
  esac
  warn "$line
     $remedy"
  exit 3
}
