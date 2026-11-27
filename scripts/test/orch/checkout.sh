# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fresh_dir: a new empty directory's physical path, as git records it.
fresh_dir() { (cd "$(mktemp -d)" && pwd -P); }

# --- checkout (#1078) ---------------------------------------------------------
# The Checkout module's reads of the repo's checkouts: the main checkout.
# Checked against real temporary checkouts, through what each prints.
echo
echo "checkout"
sc_clone
top="$(pwd -P)"
git checkout -q -b orch/1-feature
side="$(sc_add alpha)"

assert_eq "main_checkout prints the main checkout from a side checkout" \
  "$(cd "$side" && sourced_orch main_checkout)" "$top"

# main_checkout_or_die: what main_checkout prints, or the message for when git
# worktree list fails.
worktree_list_fails="$(worktree_list_fails_bin)"
assert_eq "main_checkout_or_die prints the main checkout" \
  "$(cd "$side" && sourced_orch main_checkout_or_die)" "$top"
out="$(PATH="$worktree_list_fails:$PATH" sourced_orch main_checkout_or_die 2>&1)"; st=$?
assert_status "main_checkout_or_die dies on a failed walk" "$st" 1
assert_contains "main_checkout_or_die names the walk failure" "$out" \
  "orch: could not read the checkouts - git worktree list failed"

# Cost: git's own trace counts the processes a lookup spawns. GIT_TRACE is
# exported only after orch.sh is sourced, whose own rev-parse is not counted.
trace_file="$(mktemp)"
(cd "$side" && sourced_orch_script 'export GIT_TRACE="$1"; shift; "$@"' "$trace_file" main_checkout) \
  >/dev/null
assert_eq "main_checkout spawns one git process" \
  "$(grep -c "trace: built-in: git " "$trace_file")" "1"
out="$(PATH="$worktree_list_fails:$PATH" sourced_orch main_checkout 2>/dev/null)"; st=$?
assert_status "main_checkout fails on a failed walk" "$st" 1
assert_eq "and main_checkout prints nothing" "$out" ""

# checkout_gitdir_into and the rebase checks on a linked worktree mid-rebase,
# called on its own path and on a subdirectory of it.
new_repo
mkdir sub && echo s >sub/f && git add sub && git commit -qm sub
rb_base="$(git symbolic-ref --short HEAD)"
clash_commits rb-topic
rbw="$(fresh_dir)/rbw"
git worktree add -q "$rbw" rb-topic
rbgd="$(git -C "$rbw" rev-parse --absolute-git-dir)"
git -C "$rbw" rebase "$rb_base" >/dev/null 2>&1
out="$(sourced_orch rebase_in_progress "$rbw")"; st=$?
assert_status "rebase_in_progress answers yes on a linked worktree mid-rebase" "$st" 0
out="$(sourced_orch rebase_in_progress "$rbw/sub")"; st=$?
assert_status "rebase_in_progress answers yes on a subdirectory of it" "$st" 0
out="$(cd "$rbw/sub" && sourced_orch checkout_branch_or_rebasing)"
assert_eq "checkout_branch_or_rebasing from the subdirectory prints the branch being rebased" "$out" "rb-topic"
out="$(sourced_orch_script 'v=earlier; checkout_gitdir_into v "$1"; printf %s "$v"' "$rbw" 2>&1)"
assert_eq "checkout_gitdir_into sets its variable to the linked worktree's git folder" "$out" "$rbgd"
nogit="$(fresh_dir)"
errf="$(mktemp)"
out="$(sourced_orch_script 'v=earlier; st=0; checkout_gitdir_into v "$1" 2>"$2" || st=$?; printf "st=%s %s" "$st" "$v"' "$nogit" "$errf")"
assert_eq "checkout_gitdir_into on no checkout prints nothing on stderr" "$(<"$errf")" ""
assert_eq "checkout_gitdir_into on no checkout fails and keeps the variable" "$out" "st=1 earlier"

# --- checkout current branch (#1079) ------------------------------------------
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
out="$(cd "$detached" && cbod ' - nothing was synced' 2>&1)"; st=$?
assert_status "current_branch_or_die <suffix> exits 1" "$st" 1
assert_eq "with the suffix appended" "$out" "orch: not on a branch (detached HEAD) - nothing was synced"

# --- checkout busy, redo-retired branch (#1981) -------------------------------
# The branch signal ignores a current branch a redo retired - one carrying
# branch.<b>.orchestrator-retired, as branch retire records - which still
# records a base and no PR. A live orch/ branch with no PR stays busy, whatever
# its slug ends in (#2550).
echo
echo "checkout busy redo"
busy_remedy="Open its PR, or switch off it."
busy_line="busy: branch orch/42-cap-redo-3 has no PR yet"
new_repo_with_origin
git checkout -q -b orch/7-feature
git config branch.orch/7-feature.orchestrator-base main
orch_gh_failing branch retire orch/7-feature orch/7-feature-redo-1 >/dev/null
out="$(orch_gh_failing branch busy 2>&1)"; st=$?
assert_status "a branch branch retire made, with a base and no PR, is free" "$st" 0
assert_eq "and prints nothing" "$out" ""

# branch off and init on the retired branch are not refused as busy.
out="$(orch_gh_failing branch off quick/9-beside 2>&1)"; st=$?
assert_status "branch off on a retired branch is not refused as busy" "$st" 0
git checkout -q orch/7-feature-redo-1
out="$(orch_gh_failing init beside-redo 2>&1)"; st=$?
assert_status "init on a retired branch is not refused as busy" "$st" 0

new_repo_with_origin
orch_gh_failing init own >/dev/null
orch_gh_failing state set issue 12
default="$(git branch --show-current)"
git checkout -q -b orch/6-earlier
git config branch.orch/6-earlier.orchestrator-base "$default"
orch_gh_failing branch retire orch/6-earlier orch/6-earlier-redo-2 >/dev/null
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create on a retired branch is not refused as busy" "$st" 0

# A live flow branch whose slug ends in -redo-<n> is not retired (#2550).
new_repo_with_origin
git checkout -q -b orch/42-cap-redo-3
git config branch.orch/42-cap-redo-3.orchestrator-base main
out="$(orch_gh_failing branch busy 2>&1)"; st=$?
assert_status "branch busy on a live -redo-<n>-slug flow branch exits 3" "$st" 3
assert_contains "with the busy line" "$out" "$busy_line"
out="$(orch_gh_failing branch off quick/9-x 2>&1)"; st=$?
assert_status "branch off on it exits 3" "$st" 3
assert_contains "with the busy line (branch off)" "$out" "$busy_line"
assert_contains "and the remedy (branch off)" "$out" "$busy_remedy"
out="$(orch_gh_failing init cap 2>&1)"; st=$?
assert_status "init on it exits 3" "$st" 3
assert_contains "with the busy line (init)" "$out" "$busy_line"
assert_contains "and the remedy (init)" "$out" "$busy_remedy"
new_repo_with_origin
orch_gh_failing init own3 >/dev/null
orch_gh_failing state set issue 14
default="$(git branch --show-current)"
git checkout -q -b orch/42-cap-redo-3
git config branch.orch/42-cap-redo-3.orchestrator-base "$default"
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create on it exits 3" "$st" 3
assert_contains "with the busy line (branch create)" "$out" "$busy_line"
assert_contains "and the remedy (branch create)" "$out" "$busy_remedy"
out="$(orch_gh_failing init cap 2>&1)"; st=$?
assert_status "init in a busy checkout beside the active flow exits 3" "$st" 3
restore_suite_env
