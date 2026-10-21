# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fresh_dir: a new empty directory's physical path, as git records it.
fresh_dir() { (cd "$(mktemp -d)" && pwd -P); }

# --- checkout (#1078) ----------------------------------------------------------
# The Checkout module's walk, checkouts: one line per checkout of the repo,
# <kind> <flow> <branch> <path>, the main checkout first. Checked against real
# temporary checkouts, through what the walk prints.
echo
echo "checkout"
sc_clone
top="$(pwd -P)"
git checkout -q -b orch/1-feature
side="$(sc_add alpha)"
git -C "$side" checkout -q -b side-branch
"$ORCH" ticket-worktree add 7 >/dev/null
(cd "$side" && "$ORCH" ticket-worktree add 3 >/dev/null)
"$ORCH" ticket-worktree add 8 >/dev/null
rm -rf "$top/.orchestrator/worktrees/t8"
spaced="$(fresh_dir)/hand made"
git worktree add -q -b spaced "$spaced"
handmade="$(fresh_dir)/hand"
git worktree add -q -b handmade "$handmade"
flowed="$(fresh_dir)/flowed"
git worktree add -q -b flowed "$flowed"
mkdir -p "$flowed/.orchestrator" && echo '{}' >"$flowed/.orchestrator/state.json"
detached="$(fresh_dir)/detached"
git worktree add -q --detach "$detached"
gone="$(fresh_dir)/gone"
git worktree add -q -b gone "$gone"
rm -rf "$gone"
for name in t0 t01 tfoo t9; do
  git worktree add -q --detach "$top/.orchestrator/worktrees/$name"
done
: >"$(git -C "$top/.orchestrator/worktrees/t9" rev-parse --absolute-git-dir)/orchestrator-side-checkout"

out="$(sourced_orch checkouts)"; st=$?
assert_status "checkouts succeeds" "$st" 0
assert_eq "it prints one line per checkout" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "14"
assert_first_line "the main checkout comes first, as main" "$out" "main 0 orch/1-feature $top"
assert_eq "a side checkout is side, on its branch" \
  "$(has_line "$out" "side 0 side-branch $side")" yes
assert_eq "a ticket worktree in the main checkout is ticket" \
  "$(has_line "$out" "ticket 0 orch/1-feature--t7 $top/.orchestrator/worktrees/t7")" yes
assert_eq "a ticket worktree inside a side checkout is ticket" \
  "$(has_line "$out" "ticket 0 side-branch--t3 $side/.orchestrator/worktrees/t3")" yes
assert_eq "a deleted ticket worktree is still ticket" \
  "$(has_line "$out" "ticket 0 orch/1-feature--t8 $top/.orchestrator/worktrees/t8")" yes
assert_eq "a hand-made worktree is hand-made" \
  "$(has_line "$out" "hand-made 0 handmade $handmade")" yes
assert_eq "a path with a space comes through whole" \
  "$(has_line "$out" "hand-made 0 spaced $spaced")" yes
assert_eq "a checkout holding a flow has flow 1" \
  "$(has_line "$out" "hand-made 1 flowed $flowed")" yes
assert_eq "a detached HEAD has branch -" \
  "$(has_line "$out" "hand-made 0 - $detached")" yes
assert_eq "a deleted hand-made worktree is still listed, hand-made, with its branch" \
  "$(has_line "$out" "hand-made 0 gone $gone")" yes
for name in t0 t01 tfoo; do
  assert_eq "$name under .orchestrator/worktrees is hand-made" \
    "$(has_line "$out" "hand-made 0 - $top/.orchestrator/worktrees/$name")" yes
done
assert_eq "a ticket-path checkout carrying a copied side marker is ticket" \
  "$(has_line "$out" "ticket 0 - $top/.orchestrator/worktrees/t9")" yes

kind=""; path=""
while read -r kind _flow _branch path; do
  [ "$path" = "$spaced" ] && break
done <<<"$out"
assert_eq "read -r kind flow branch path keeps a spaced path whole" "$kind $path" "hand-made $spaced"

assert_eq "branch_checkout still finds a deleted worktree's branch" \
  "$(sourced_orch branch_checkout gone)" "$gone"
assert_eq "branch_checkout finds a side checkout's branch" \
  "$(sourced_orch branch_checkout side-branch)" "$side"
assert_eq "branch_checkout prints nothing for a branch checked out nowhere" \
  "$(sourced_orch branch_checkout nowhere)" ""
assert_eq "main_checkout prints the main checkout from a side checkout" \
  "$(cd "$side" && sourced_orch main_checkout)" "$top"

outside="$(fresh_dir)"
out="$(bash -c 'source "$1"; cd "$2" && checkouts' _ "$ORCH" "$outside" 2>/dev/null)"; st=$?
assert_ne "checkouts outside a repo fails" "$st" 0
assert_eq "and prints nothing" "$out" ""

# --- checkout current branch (#1079) -------------------------------------------
# The Checkout module's one current-branch read: checkout_branch prints the
# branch checked out, and current_branch_or_die assigns it to the caller's
# branch or dies with the one detached-HEAD message.
echo
echo "checkout current branch"
sc_clone
top="$(pwd -P)"
git checkout -q -b orch/2-feature
detached="$(fresh_dir)/detached"
git worktree add -q --detach "$detached"

assert_eq "checkout_branch prints the current branch" \
  "$(sourced_orch checkout_branch)" "orch/2-feature"
assert_eq "checkout_branch <path> prints the branch checked out there" \
  "$(cd "$detached" && sourced_orch checkout_branch "$top")" "orch/2-feature"
out="$(sourced_orch checkout_branch "$detached")"; st=$?
assert_status "checkout_branch on a detached HEAD returns 1" "$st" 1
assert_eq "and prints nothing" "$out" ""

# #1111: a tag of the branch's name makes git's short name ambiguous
# (heads/<name>); checkout_branch still prints the bare branch name.
git tag orch/2-feature
assert_eq "checkout_branch beside a same-named tag prints the bare branch name" \
  "$(sourced_orch checkout_branch)" "orch/2-feature"
assert_eq "and so does checkout_branch <path>" \
  "$(cd "$detached" && sourced_orch checkout_branch "$top")" "orch/2-feature"
out="$(sourced_orch checkout_branch "$detached")"; st=$?
assert_status "beside the tag a detached HEAD still returns 1" "$st" 1
git tag -d orch/2-feature >/dev/null

# current_branch_or_die run as a bare statement, then $branch printed.
cbod() { bash -c 'source "$1"; shift; current_branch_or_die "$@"; printf "%s\n" "$branch"' _ "$ORCH" "$@"; }
out="$(cbod 2>&1)"; st=$?
assert_status "current_branch_or_die on a branch returns 0" "$st" 0
assert_eq "and sets the caller's branch" "$out" "orch/2-feature"
out="$(cd "$detached" && cbod 2>&1)"; st=$?
assert_status "current_branch_or_die on a detached HEAD exits 1" "$st" 1
assert_eq "with the bare message" "$out" "orch: not on a branch (detached HEAD)"
out="$(cd "$detached" && cbod die2 2>&1)"; st=$?
assert_status "current_branch_or_die die2 exits 2" "$st" 2
assert_eq "with the bare message" "$out" "orch: not on a branch (detached HEAD)"
out="$(cd "$detached" && cbod die ' - nothing was synced' 2>&1)"; st=$?
assert_status "current_branch_or_die die <suffix> exits 1" "$st" 1
assert_eq "with the suffix appended" "$out" "orch: not on a branch (detached HEAD) - nothing was synced"
out="$(cd "$detached" && cbod ' - x' 2>&1)"; st=$?
assert_status "a lone suffix argument exits 1" "$st" 1
assert_eq "and is taken as the suffix" "$out" "orch: not on a branch (detached HEAD) - x"
