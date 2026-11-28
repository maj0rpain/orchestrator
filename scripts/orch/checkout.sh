# shellcheck shell=bash
# checkout.sh - the Checkout module: a concept module with no orch.sh noun of
# its own, now holding only the main checkout's read - checkout_parse,
# main_checkout, main_checkout_or_die and checkouts_unreadable. They stay in
# bash because the gh adapter's GitHub limit record, a remaining bash caller,
# reads the main checkout through main_checkout_or_die, and they belong to the
# Checkout concept, not to gh. Everything else about the repo's checkouts - the
# checkout scan and kinds, the branch a checkout holds, the busy-checkout
# refusal, whether a merge or a rebase is in progress and the discard rule's
# pieces (ADR-0054) - is orch/checkout.py's, read by the converted nouns.
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
# (checkouts_unreadable). Kept with one bash caller, the gh adapter's limit
# record, which calls it in a substitution with the die message silenced and
# reads its failure as a plain non-zero status.
checkouts_unreadable() { die "could not read the checkouts - git worktree list failed"; }
main_checkout_or_die() {
  main_checkout || checkouts_unreadable
}
