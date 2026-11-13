# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fresh_dir: a new empty directory's physical path, as git records it.
fresh_dir() { (cd "$(mktemp -d)" && pwd -P); }

# --- checkout (#1078) ---------------------------------------------------------
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

# checkouts_main <walk>: the main checkout from a walk already held (#1702).
walk_held="$(sourced_orch checkouts)"
assert_eq "checkouts_main prints the first line's path" \
  "$(sourced_orch checkouts_main "$walk_held")" "$top"
out="$(sourced_orch checkouts_main "")"; st=$?
assert_status "checkouts_main fails on an empty walk" "$st" 1
assert_eq "checkouts_main prints nothing on an empty walk" "$out" ""

# checkouts_or_die / main_checkout_or_die: what the plain queries print, or the
# message for when git worktree list fails.
nowalk="$(nowalk_bin)"
assert_eq "checkouts_or_die prints the walk" "$(sourced_orch checkouts_or_die)" "$walk_held"
assert_eq "main_checkout_or_die prints the main checkout" \
  "$(cd "$side" && sourced_orch main_checkout_or_die)" "$top"
out="$(PATH="$nowalk:$PATH" sourced_orch checkouts_or_die 2>&1)"; st=$?
assert_status "checkouts_or_die dies on a failed walk" "$st" 1
assert_contains "checkouts_or_die names the walk failure" "$out" \
  "orch: could not read the checkouts - git worktree list failed"
out="$(PATH="$nowalk:$PATH" sourced_orch main_checkout_or_die 2>&1)"; st=$?
assert_status "main_checkout_or_die dies on a failed walk" "$st" 1
assert_contains "main_checkout_or_die names the walk failure" "$out" \
  "orch: could not read the checkouts - git worktree list failed"
out="$(PATH="$nowalk:$PATH" sourced_orch branch_checkout gone 2>&1)"; st=$?
assert_status "branch_checkout dies on a failed walk" "$st" 1
assert_contains "branch_checkout names the walk failure" "$out" \
  "orch: could not read the checkouts - git worktree list failed"

# checkout_kind <path>: the kind checkout_classify gives the checkout holding
# <path> (#1110).
assert_eq "checkout_kind: a ticket worktree carrying a copied marker is ticket" \
  "$(sourced_orch checkout_kind "$top/.orchestrator/worktrees/t9")" "ticket"
assert_eq "checkout_kind: a side checkout is side" "$(sourced_orch checkout_kind "$side")" "side"
mkdir -p "$side/sub"
assert_eq "checkout_kind: a folder inside a side checkout is side" \
  "$(sourced_orch checkout_kind "$side/sub")" "side"
rmdir "$side/sub"
assert_eq "checkout_kind: the main checkout is main" "$(sourced_orch checkout_kind "$top")" "main"
assert_eq "checkout_kind: a hand-made worktree is hand-made" \
  "$(sourced_orch checkout_kind "$handmade")" "hand-made"

outside="$(fresh_dir)"
out="$(sourced_orch_script 'cd "$1" && checkouts' "$outside" 2>/dev/null)"; st=$?
assert_ne "checkouts outside a repo fails" "$st" 0
assert_eq "and prints nothing" "$out" ""
out="$(sourced_orch_script 'cd "$1" && checkout_kind "$1"' "$outside" 2>/dev/null)"; st=$?
assert_ne "checkout_kind outside a repo fails" "$st" 0
assert_eq "and checkout_kind prints nothing" "$out" ""

# Cost: git's own trace counts the processes a lookup spawns. GIT_TRACE is
# exported only after orch.sh is sourced, whose own rev-parse is not counted.
trace_file="$(mktemp)"
# trace_lookup <dir> <function> [<arg>]: runs the function from <dir>, traced
# into $trace_file, which it prints through.
trace_lookup() {
  : >"$trace_file"
  (cd "$1" && sourced_orch_script 'export GIT_TRACE="$1"; shift; "$@"' "$trace_file" "${@:2}")
}
trace_git() { grep -c "trace: built-in: git $1" "$trace_file"; }
trace_lookup "$side" main_checkout >/dev/null
assert_eq "main_checkout spawns one git process" "$(trace_git '')" "1"
trace_lookup "$top" checkout_kind "$side" >/dev/null
assert_eq "checkout_kind on a side checkout reads its git dir from the pointer, starting no git for it" "$(trace_git 'rev-parse --absolute-git-dir')" "0"
assert_eq "checkout_kind on a side checkout spawns two git processes" "$(trace_git '')" "2"
for dir in "$top" "$top/.orchestrator/worktrees/t9"; do
  trace_lookup "$dir" checkout_kind "$dir" >/dev/null
  assert_eq "checkout_kind on ${dir##*/} reads no git dir" "$(trace_git 'rev-parse --absolute-git-dir')" "0"
  assert_eq "checkout_kind on ${dir##*/} spawns two git processes" "$(trace_git '')" "2"
done
out="$(PATH="$nowalk:$PATH" sourced_orch main_checkout 2>/dev/null)"; st=$?
assert_status "main_checkout fails on a failed walk" "$st" 1
assert_eq "and main_checkout prints nothing" "$out" ""
out="$(PATH="$nowalk:$PATH" sourced_orch checkout_kind "$side" 2>/dev/null)"; st=$?
assert_status "checkout_kind fails on a failed walk" "$st" 1
assert_eq "and checkout_kind prints nothing" "$out" ""

# checkout_holding shows a checkout whose state.json cannot be parsed plainly,
# with no jq text.
(cd "$flowed" && state_truncate 1)
out="$(sourced_orch checkout_holding "$flowed" 2>&1)"
assert_eq "checkout_holding: an unreadable state.json is shown plainly" "$out" "flow (state.json cannot be read)"

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
out="$(cd "$detached" && cbod die2 2>&1)"; st=$?
assert_status "current_branch_or_die die2 exits 2" "$st" 2
assert_eq "with the bare message" "$out" "orch: not on a branch (detached HEAD)"
out="$(cd "$detached" && cbod die ' - nothing was synced' 2>&1)"; st=$?
assert_status "current_branch_or_die die <suffix> exits 1" "$st" 1
assert_eq "with the suffix appended" "$out" "orch: not on a branch (detached HEAD) - nothing was synced"
out="$(cd "$detached" && cbod ' - x' 2>&1)"; st=$?
assert_status "a lone suffix argument exits 1" "$st" 1
assert_eq "and is taken as the suffix" "$out" "orch: not on a branch (detached HEAD) - x"

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
