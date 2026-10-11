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
    elif is_side_checkout "${paths[i]}"; then
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
  elif branch="$(git -C "$1" symbolic-ref --quiet --short HEAD)"; then
    note "branch $branch"
  else
    note "(no branch)"
  fi
}
