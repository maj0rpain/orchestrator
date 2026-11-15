# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# rebasing [dir]: prints rebasing when a rebase is in progress in dir (default:
# the current directory), none otherwise.
rebasing() {
  [ -d "$(git -C "${1:-.}" rev-parse --absolute-git-dir)/rebase-merge" ] && echo rebasing || echo none
}

# --- ticket-worktree (#619) ---------------------------------------------------
# A ticket's own worktree on its own ticket branch, under the checkout's
# .orchestrator/worktrees/. Checked through what git shows afterwards -
# branches, tips, worktrees, the exclude file - never orch.sh's internals.
echo
echo "ticket-worktree"
tw_repo
top="$(git rev-parse --show-toplevel)"
tip="$(git rev-parse HEAD)"
out="$("$ORCH" ticket-worktree add 7)"; st=$?
assert_status "add succeeds" "$st" 0
assert_eq "add prints the worktree's absolute path" "$out" "$top/.orchestrator/worktrees/t7"
assert_eq "the worktree is a top level of its own" \
  "$(git -C "$out" rev-parse --show-toplevel)" "$top/.orchestrator/worktrees/t7"
assert_eq "it is checked out on <current-branch>--t<n>" \
  "$(git -C "$out" branch --show-current)" "orch/5-feature--t7"
assert_eq "the ticket branch forks from the current branch's tip" \
  "$(git rev-parse orch/5-feature--t7)" "$tip"
assert_eq "the forked-from branch is recorded on the ticket branch" \
  "$(git config --get branch.orch/5-feature--t7.orchestrator-ticket-parent)" "orch/5-feature"
assert_eq "the current checkout stays on its branch" "$(git branch --show-current)" "orch/5-feature"
assert_eq "add excludes .orchestrator/" "$(exclude_count .orchestrator/)" "1"
assert_eq "add excludes .scratch/" "$(exclude_count .scratch/)" "1"
assert_eq "the ticket worktree stays out of git status" "$(git status --porcelain)" ""

"$ORCH" ticket-worktree add 8 >/dev/null
assert_eq "a second add writes .orchestrator/ no second time" "$(exclude_count .orchestrator/)" "1"
assert_eq "a second add writes .scratch/ no second time" "$(exclude_count .scratch/)" "1"

out="$("$ORCH" ticket-worktree list)"; st=$?
assert_status "list succeeds" "$st" 0
assert_eq "list prints <n> <path> for each ticket worktree" "$out" \
  "$(printf '7 %s\n8 %s' "$top/.orchestrator/worktrees/t7" "$top/.orchestrator/worktrees/t8")"

out="$(PATH="$(worktree_list_fails_bin):$PATH" "$ORCH" ticket-worktree list 2>&1)"; st=$?
assert_status "list dies when the checkouts cannot be read (#1333)" "$st" 1
assert_contains "naming the checkouts" "$out" "orch: could not read the checkouts"

out="$("$ORCH" ticket-worktree add 7 2>&1)"; st=$?
assert_status "add refuses an existing worktree" "$st" 1
assert_contains "naming it" "$out" ".orchestrator/worktrees/t7"

git worktree remove "$top/.orchestrator/worktrees/t8"
out="$("$ORCH" ticket-worktree add 8 2>&1)"; st=$?
assert_status "add refuses an existing ticket branch" "$st" 1
assert_contains "naming the branch" "$out" "orch/5-feature--t8 already exists"
assert_eq "and adds no worktree" "$(on_disk .orchestrator/worktrees/t8)" "absent"
git branch -q -D orch/5-feature--t8

out="$("$ORCH" ticket-worktree add 0 2>&1)"; st=$?
assert_status "add refuses a ticket number that is not a positive integer" "$st" 1
out="$("$ORCH" ticket-worktree add 2>&1)"; st=$?
assert_status "add refuses a missing ticket number" "$st" 1

git checkout -q --detach
out="$("$ORCH" ticket-worktree add 9 2>&1)"; st=$?
assert_status "add refuses a detached HEAD" "$st" 1
git checkout -q orch/5-feature

# A failed git worktree add: .orchestrator/worktrees is a file, so no
# worktree can be made under it.
tw_repo
mkdir -p .orchestrator && : >.orchestrator/worktrees
out="$("$ORCH" ticket-worktree add 3 2>&1)"; st=$?
assert_status "add dies when the worktree cannot be added" "$st" 1
assert_eq "and leaves no ticket branch behind" \
  "$(git branch --list 'orch/5-feature--t3')" ""
assert_eq "nor its recorded parent" \
  "$(git config --get branch.orch/5-feature--t3.orchestrator-ticket-parent)" ""
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "1"
assert_eq "it still wrote the exclude entry first" "$(exclude_count .orchestrator/)" "1"

tw_repo
out="$("$ORCH" ticket-worktree list)"; st=$?
assert_status "list with no ticket worktrees exits 0" "$st" 0
assert_eq "and prints nothing" "$out" ""

# From a linked worktree: the exclude entry lands in the clone's shared
# info/exclude, and the ticket worktree under the linked checkout's own top
# level; each checkout lists only its own.
tw_repo
main_top="$(git rev-parse --show-toplevel)"
linked="$(mktemp -d)/linked"
git worktree add -q -b orch/6-other "$linked"
"$ORCH" ticket-worktree add 2 >/dev/null
cd "$linked" || exit 1
out="$("$ORCH" ticket-worktree add 4)"; st=$?
assert_status "add succeeds from a linked worktree" "$st" 0
assert_eq "under the linked checkout's own top level" "$out" "$linked/.orchestrator/worktrees/t4"
assert_eq "it writes the clone's shared info/exclude" \
  "$(exclude_count .orchestrator/)" "1"
assert_eq "and keeps the linked checkout's git status clean" "$(git status --porcelain)" ""
assert_eq "the linked checkout lists only its own ticket worktree" \
  "$("$ORCH" ticket-worktree list)" "4 $linked/.orchestrator/worktrees/t4"
cd "$main_top" || exit 1
assert_eq "the main checkout ignores the linked checkout's ticket worktree" \
  "$("$ORCH" ticket-worktree list)" "2 $main_top/.orchestrator/worktrees/t2"

# remove
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
out="$("$ORCH" ticket-worktree remove 7)"; st=$?
assert_status "remove of a merged, clean ticket succeeds" "$st" 0
assert_eq "it removes the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and git no longer records it" "$(git worktree list | wc -l | tr -d ' ')" "1"
assert_eq "it deletes the ticket branch" "$(git branch --list 'orch/5-feature--t7')" ""
assert_eq "remove then list prints nothing" "$("$ORCH" ticket-worktree list)" ""

wt="$("$ORCH" ticket-worktree add 7)"
echo dirty >"$wt/README.md"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a dirty worktree" "$st" 1
assert_contains "saying it is dirty" "$out" \
  "orch: ticket worktree $wt is dirty - commit or discard its changes first; it is never removed with force"
assert_eq "leaving the worktree in place" "$([ -f "$wt/README.md" ] && cat "$wt/README.md")" "dirty"
assert_eq "and the branch" \
  "$(git rev-parse --verify --quiet refs/heads/orch/5-feature--t7 >/dev/null && echo present)" "present"
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged still refuses a dirty worktree" "$st" 1
assert_eq "leaving the worktree in place" "$([ -f "$wt/README.md" ] && cat "$wt/README.md")" "dirty"
assert_eq "and the branch" \
  "$(git rev-parse --verify --quiet refs/heads/orch/5-feature--t7 >/dev/null && echo present)" "present"
git -C "$wt" checkout -q -- README.md
echo new >"$wt/untracked.txt"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "an untracked file counts as dirty" "$st" 1
rm "$wt/untracked.txt"

git -C "$wt" commit -q --allow-empty -m "ticket work"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses an unmerged branch" "$st" 1
assert_contains "saying it is unmerged" "$out" "not merged"
assert_eq "leaving the worktree in place" "$(on_disk "$wt")" "present"
assert_eq "and the branch at its tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
# No recorded forked-from branch: remove cannot judge the branch merged.
git config --unset branch.orch/5-feature--t7.orchestrator-ticket-parent
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a branch that records no forked-from branch" "$st" 1
assert_contains "saying so, with the --unmerged hint" "$out" \
  "orch: branch orch/5-feature--t7 records no forked-from branch - pass --unmerged to discard it"
assert_eq "leaving the worktree in place" "$(on_disk "$wt")" "present"
assert_eq "and the branch at its tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
out="$("$ORCH" ticket-worktree remove 7 --unmerged)"; st=$?
assert_status "remove --unmerged discards a clean worktree's unmerged branch" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""

# teardown_of <n> [flag...]: reads ticket <n>'s facts, then calls
# ticket_worktree_teardown on them, in one sourced shell.
teardown_of() { sourced_orch_script 'ticket_facts "$1" f; shift; ticket_worktree_teardown f "$@"' "$@"; }
# ticket_worktree_teardown, the one site that tears a worktree down. Called
# through teardown_of (the facts read, then the teardown); checked through
# what git shows.
# Left mid-rebase - a ticket conflict's resolution that failed: --unmerged
# aborts the rebase first, returning the ticket branch to its committed tip,
# then removes the clean worktree with no force.
wt="$("$ORCH" ticket-worktree add 7)"
echo ticket >"$wt/feature.txt" && git -C "$wt" commit -qam "ticket edit"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
echo parent >feature.txt && git commit -qam "parent edit"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
echo leftover >"$wt/untracked.txt"
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "teardown --unmerged of a mid-rebase worktree still refuses it dirty" "$st" 1
assert_contains "saying it is dirty" "$out" "ticket worktree $wt is dirty"
assert_eq "having aborted its rebase first" \
  "$(rebasing "$wt")" "none"
assert_eq "returning the ticket branch to its committed tip" \
  "$(git -C "$wt" rev-parse HEAD) $(git -C "$wt" branch --show-current)" "$ticket_tip orch/5-feature--t7"
assert_eq "and removing nothing with force" "$(on_disk "$wt")" "present"
rm "$wt/untracked.txt"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "teardown --unmerged of a clean mid-rebase worktree succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""
git reset -q --hard HEAD~1

# Without --unmerged a rebase left in progress is not aborted.
wt="$("$ORCH" ticket-worktree add 7)"
echo ticket >"$wt/feature.txt" && git -C "$wt" commit -qam "ticket edit"
echo parent >feature.txt && git commit -qam "parent edit"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown without --unmerged refuses a mid-rebase worktree" "$st" 1
assert_eq "leaving its rebase in progress" "$(rebasing "$wt")" "rebasing"
git -C "$wt" rebase --abort
git reset -q --hard HEAD~1

# The CLI too: remove --unmerged on a worktree left mid-rebase (HEAD detached)
# aborts the rebase before it reads the branch, then removes the worktree.
echo parent >feature.txt && git commit -qam "parent edit"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged of a mid-rebase worktree succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""
git reset -q --hard HEAD~1
wt="$("$ORCH" ticket-worktree add 7)"
echo ticket >"$wt/feature.txt" && git -C "$wt" commit -qam "ticket edit"

# Dirty and unmerged refusals, then --discard under the label ticket #<n>.
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown refuses an unmerged branch" "$st" 1
assert_contains "saying it is not merged" "$out" "not merged into orch/5-feature"
assert_eq "leaving the worktree in place" "$(on_disk "$wt")" "present"
echo dirty >"$wt/README.md"
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "teardown refuses a dirty worktree" "$st" 1
assert_eq "leaving the worktree and the branch" \
  "$(on_disk "$wt")$(git branch --list 'orch/5-feature--t7' | tr -d ' +')" "presentorch/5-feature--t7"
out="$(PATH="$(git_fails_bin '*" reset "*'):$PATH" teardown_of 7 --unmerged --discard 2>&1)"; st=$?
assert_status "teardown --discard dies when the discard fails" "$st" 1
assert_contains "under the label ticket #7" "$out" "orch: ticket #7: git reset --hard failed in $wt"
assert_eq "removing nothing" "$(on_disk "$wt")" "present"
out="$(teardown_of 7 --unmerged --discard 2>&1)"; st=$?
assert_status "teardown --discard throws the dirty work away and succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""

wt="$("$ORCH" ticket-worktree add 7)"
echo dirty >"$wt/README.md"
out="$(teardown_of 7 --discard 2>&1)"; st=$?
assert_status "teardown --discard of a merged branch succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"

# Branch only: the worktree is gone but the branch is left.
wt="$("$ORCH" ticket-worktree add 7)"
git worktree remove "$wt"
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown of a merged branch whose worktree is gone succeeds" "$st" 0
assert_eq "deleting the branch" "$(git branch --list 'orch/5-feature--t7')" ""
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m work
git worktree remove "$wt"
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown of an unmerged branch alone refuses" "$st" 1
assert_eq "keeping the branch" "$(git branch --list 'orch/5-feature--t7' | tr -d ' +')" "orch/5-feature--t7"
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "teardown --unmerged of an unmerged branch alone succeeds" "$st" 0
assert_eq "deleting the branch" "$(git branch --list 'orch/5-feature--t7')" ""
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown with neither worktree nor branch dies" "$st" 1
assert_contains "naming the ticket" "$out" "no ticket worktree or branch for ticket 7"

# Strict arguments.
out="$(sourced_orch ticket_worktree_teardown 2>&1)"; st=$?
assert_status "teardown without a prefix dies" "$st" 1
assert_contains "with its usage" "$out" "usage: ticket_worktree_teardown <prefix> [--unmerged] [--discard]"
out="$(sourced_orch ticket_worktree_teardown f --bogus 2>&1)"; st=$?
assert_status "teardown dies on an unknown flag" "$st" 1
assert_contains "naming it" "$out" "--bogus"
out="$(sourced_orch ticket_worktree_teardown f g 2>&1)"; st=$?
assert_status "teardown dies on a second positional argument" "$st" 1
assert_contains "naming it" "$out" "unexpected argument: g"

# A removal step that fails: the teardown prints its own message and returns
# that step's status (10 for the worktree, 11 for the branch), the two
# differing from each other and from 0, 1, 2 and 3.
wt="$("$ORCH" ticket-worktree add 7)"
out="$(PATH="$(git_fails_bin '*" worktree remove "*'):$PATH" teardown_of 7 2>&1)"; st=$?
assert_status "teardown returns the worktree step's status when the worktree cannot be removed" "$st" 10
assert_contains "printing its message" "$out" "orch: could not remove ticket worktree $wt"
assert_eq "leaving the worktree and the branch" \
  "$(on_disk "$wt")$(git branch --list 'orch/5-feature--t7' | tr -d ' +')" "presentorch/5-feature--t7"
out="$(PATH="$(git_fails_bin '*" branch -q -D "*'):$PATH" teardown_of 7 2>&1)"; st=$?
assert_status "teardown returns the branch step's status when the branch cannot be deleted" "$st" 11
assert_contains "printing its message" "$out" "orch: could not delete branch orch/5-feature--t7"
assert_eq "leaving the branch and the worktree gone" \
  "$(on_disk "$wt")$(git branch --list 'orch/5-feature--t7' | tr -d ' +')" "absentorch/5-feature--t7"
git branch -q -D orch/5-feature--t7

# The CLI: remove exits 1 with the teardown's message on either failed step.
wt="$("$ORCH" ticket-worktree add 7)"
out="$(PATH="$(git_fails_bin '*" worktree remove "*'):$PATH" "$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove exits 1 when the worktree cannot be removed" "$st" 1
assert_contains "printing the teardown's message" "$out" "orch: could not remove ticket worktree $wt"
out="$(PATH="$(git_fails_bin '*" branch -q -D "*'):$PATH" "$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove exits 1 when the branch cannot be deleted" "$st" 1
assert_contains "printing the teardown's message" "$out" "orch: could not delete branch orch/5-feature--t7"
git branch -q -D orch/5-feature--t7

# add dies before acting where git's record of the checkouts cannot be read.
out="$(PATH="$(worktree_list_fails_bin):$PATH" "$ORCH" ticket-worktree add 7 2>&1)"; st=$?
assert_status "add dies where the checkouts cannot be read" "$st" 1
assert_eq "creating no branch and no worktree" \
  "$(on_disk "$wt")$(git branch --list 'orch/5-feature--t7')" "absent"

# A worktree switched to another branch: removed, that branch survives, and
# the ticket branch is deleted.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" checkout -q -b elsewhere
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown of a worktree on another branch succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "keeping the other branch" "$(git branch --list elsewhere | tr -d ' ')" "elsewhere"
assert_eq "deleting the ticket branch" "$(git branch --list 'orch/5-feature--t7')" ""
git branch -q -D elsewhere

# Ticket branch gone: refused with the worktree kept, removed under --unmerged.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" checkout -q --detach
git branch -q -D orch/5-feature--t7
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown refuses a worktree whose ticket branch is gone" "$st" 1
assert_eq "leaving the worktree" "$(on_disk "$wt")" "present"
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "teardown --unmerged removes a detached worktree whose ticket branch is gone" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"

# A detached current checkout dies with the worktree untouched.
wt="$("$ORCH" ticket-worktree add 7)"
echo dirty >"$wt/README.md"
git checkout -q --detach
out="$(teardown_of 7 --unmerged --discard 2>&1)"; st=$?
assert_status "teardown from a detached checkout dies" "$st" 1
assert_contains "saying so" "$out" "not on a branch (detached HEAD)"
assert_eq "leaving the work untouched" "$(cat "$wt/README.md")" "dirty"
git checkout -q orch/5-feature
git -C "$wt" checkout -q -- README.md
"$ORCH" ticket-worktree remove 7 >/dev/null

# A leftover t<n> directory that is no worktree: git would resolve it to the
# enclosing checkout, so --unmerged must not abort that checkout's rebase.
git checkout -q -b orch/5-side
echo side >feature.txt && git commit -qam "side edit"
git checkout -q orch/5-feature
echo main >feature.txt && git commit -qam "main edit"
git rebase -q orch/5-side >/dev/null 2>&1
mkdir -p .orchestrator/worktrees/t9
out="$("$ORCH" ticket-worktree remove 9 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged of a leftover non-worktree t<n> dir refuses" "$st" 1
assert_eq "leaving the enclosing checkout's rebase in progress" \
  "$(rebasing)" "rebasing"
git rebase --abort
rmdir .orchestrator/worktrees/t9
git reset -q --hard HEAD~1
git branch -q -D orch/5-side

# Merged into its forked-from branch, but invoked from another branch: the
# ticket branch is <current branch>--t<n>, so remove judges that one, finds
# it missing, and refuses with the worktree kept.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git merge -q --ff-only orch/5-feature--t7
git checkout -q -b orch/5-elsewhere HEAD~1
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove from another branch refuses, judging that branch's ticket branch" "$st" 1
assert_eq "keeping the worktree" "$(on_disk "$wt")" "present"
git checkout -q orch/5-feature
"$ORCH" ticket-worktree remove 7 >/dev/null
git branch -q -D orch/5-elsewhere

out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a ticket with no worktree" "$st" 1
out="$("$ORCH" ticket-worktree remove 7 --bogus 2>&1)"; st=$?
assert_status "remove refuses an unknown flag" "$st" 1
# A ticket worktree whose directory was deleted outside git: git still records
# it, the listing names it, and remove clears the record and the branch.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git merge -q --ff-only orch/5-feature--t7
other_wt="$(mktemp -d)/other"
git worktree add -q -b gone-other "$other_wt"
rm -rf "$other_wt"
rm -rf "$wt"
assert_eq "a deleted-directory worktree is still listed" "$("$ORCH" ticket-worktree list)" "7 $wt"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove of a merged ticket whose directory is gone succeeds with no flag" "$st" 0
assert_eq "git no longer records it" "$(git worktree list --porcelain | grep -c "worktree $wt\$")" "0"
assert_eq "the listing is empty" "$("$ORCH" ticket-worktree list)" ""
assert_eq "the ticket branch is gone" "$(git branch --list 'orch/5-feature--t7')" ""
assert_eq "another stale record is still listed by git" \
  "$(git worktree list --porcelain | grep -c "worktree $other_wt\$")" "1"
git worktree prune
git branch -q -D gone-other

# Unmerged: refused with the record and the branch kept; --unmerged clears both.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "unmerged work"
rm -rf "$wt"
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove of an unmerged ticket whose directory is gone refuses" "$st" 1
assert_contains "saying it is not merged" "$out" "is not merged into"
assert_eq "keeping the listing" "$("$ORCH" ticket-worktree list)" "7 $wt"
assert_eq "and the branch" "$(branch_presence refs/heads/orch/5-feature--t7)" "present"
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "--unmerged clears it" "$st" 0
assert_eq "the record" "$("$ORCH" ticket-worktree list)" ""
assert_eq "and the branch" "$(branch_presence refs/heads/orch/5-feature--t7)" "gone"

# Something at the path that is not a worktree, while git's record names it:
# refused naming the path, before the merged check, nothing removed.
for kind in dir file; do
  wt="$("$ORCH" ticket-worktree add 7)"
  git -C "$wt" commit -q --allow-empty -m "unmerged work"
  rm -rf "$wt"
  if [ "$kind" = dir ]; then mkdir "$wt"; else echo x >"$wt"; fi
  out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
  assert_status "remove with a $kind at the recorded path refuses" "$st" 1
  assert_contains "naming the path" "$out" "$wt"
  assert_contains "saying to delete it and run the command again" "$out" "delete it and run the command again"
  out="$("$ORCH" ticket-worktree remove 7 2>&1)"
  assert_not_contains "before the merged check ($kind)" "$out" "not merged"
  assert_eq "what sits there stays ($kind)" "$(on_disk "$wt")" "present"
  assert_eq "git's record stays ($kind)" "$("$ORCH" ticket-worktree list)" "7 $wt"
  rm -rf "$wt"
  "$ORCH" ticket-worktree remove 7 --unmerged >/dev/null 2>&1
done

# The teardown keeps another branch the record holds, deleting only the
# ticket's own; with the ticket branch gone it refuses, and --unmerged clears.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" checkout -q -b keep-me
git -C "$wt" commit -q --allow-empty -m "other branch work"
git merge -q --ff-only keep-me
rm -rf "$wt"
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown of a gone directory holding another branch succeeds" "$st" 0
assert_eq "keeping the other branch" "$(branch_presence refs/heads/keep-me)" "present"
assert_eq "deleting the ticket branch" "$(branch_presence refs/heads/orch/5-feature--t7)" "gone"
assert_eq "clearing the record" "$("$ORCH" ticket-worktree list)" ""
git reset -q --hard HEAD~1
git branch -q -D keep-me
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" checkout -q --detach
git branch -q -D orch/5-feature--t7
rm -rf "$wt"
out="$(teardown_of 7 2>&1)"; st=$?
assert_status "teardown with the ticket branch gone refuses without --unmerged" "$st" 1
assert_eq "keeping the record" "$("$ORCH" ticket-worktree list)" "7 $wt"
out="$(teardown_of 7 --unmerged 2>&1)"; st=$?
assert_status "and clears the record with --unmerged" "$st" 0
assert_eq "leaving no record" "$("$ORCH" ticket-worktree list)" ""

# ticket_facts, the one read of a ticket's facts, called through the sourced
# orch.sh: each fact is printed and asserted.
tw_repo
top="$(git rev-parse --show-toplevel)"
facts_of() {
  sourced_orch_script 'ticket_facts "$1" f 2>&1 || exit $?
for k in n path worktree wt_branch parent own_branch own_exists; do
  v="f_$k"; printf "%s=%s\n" "$k" "${!v}"
done' "$1"
}
fact() {
	local k v
	while IFS='=' read -r k v; do
		[ "$k" != "$2" ] || printf '%s\n' "$v"
	done <<<"$1"
}
p7="$top/.orchestrator/worktrees/t7"

out="$(facts_of 7)"; st=$?
assert_status "facts of nothing succeeds" "$st" 0
assert_eq "no worktree: the state is none" "$(fact "$out" worktree)" "none"
assert_eq "and the ticket number is kept" "$(fact "$out" n)" "7"
assert_eq "and the path is where it would live" "$(fact "$out" path)" "$p7"
assert_eq "and no branch is checked out there" "$(fact "$out" wt_branch)" ""
assert_eq "the parent is the current branch" "$(fact "$out" parent)" "orch/5-feature"
assert_eq "the own branch is built from it" "$(fact "$out" own_branch)" "orch/5-feature--t7"
assert_eq "and does not exist yet" "$(fact "$out" own_exists)" "no"

mkdir -p "$p7"
out="$(facts_of 7)"
assert_eq "a leftover directory with no record is none" "$(fact "$out" worktree)" "none"
rmdir "$p7"

"$ORCH" ticket-worktree add 7 >/dev/null
out="$(facts_of 7)"
assert_eq "a worktree at the path: the state is worktree" "$(fact "$out" worktree)" "worktree"
assert_eq "its branch is the ticket's own" "$(fact "$out" wt_branch)" "orch/5-feature--t7"
assert_eq "and the own branch exists" "$(fact "$out" own_exists)" "yes"

out="$(PATH="$(worktree_list_fails_bin):$PATH" facts_of 7)"; st=$?
assert_status "the read dies when the checkouts cannot be read, a worktree present" "$st" 1
assert_contains "naming the checkouts" "$out" "could not read the checkouts"
assert_not_contains "never reporting none" "$out" "worktree=none"

git -C "$p7" checkout -q -b other
out="$(facts_of 7)"
assert_eq "another branch checked out: wt_branch is that one" "$(fact "$out" wt_branch)" "other"
assert_eq "and the own branch is still the ticket's" "$(fact "$out" own_branch)" "orch/5-feature--t7"
git -C "$p7" checkout -q orch/5-feature--t7
git branch -q -D other

# Mid-rebase: HEAD is detached in the ticket worktree.
echo ticket >"$p7/feature.txt" && git -C "$p7" commit -qam "ticket edit"
echo parent >feature.txt && git commit -qam "parent edit"
git -C "$p7" rebase -q orch/5-feature >/dev/null 2>&1
out="$(facts_of 7)"
assert_eq "mid-rebase: wt_branch is empty" "$(fact "$out" wt_branch)" ""
assert_eq "and the state is still worktree" "$(fact "$out" worktree)" "worktree"
git -C "$p7" rebase --abort
git reset -q --hard HEAD~1

git -C "$p7" checkout -q --detach
git branch -q -D orch/5-feature--t7
out="$(facts_of 7)"
assert_eq "no ticket branch of its own name: own_exists is no" "$(fact "$out" own_exists)" "no"
assert_eq "yet the state is worktree" "$(fact "$out" worktree)" "worktree"
git worktree remove --force "$p7"

"$ORCH" ticket-worktree add 7 >/dev/null
rm -rf "$p7"
out="$(facts_of 7)"
assert_eq "a record whose directory is gone: the state is gone" "$(fact "$out" worktree)" "gone"
assert_eq "and wt_branch is empty, never the checkout's" "$(fact "$out" wt_branch)" ""
mkdir "$p7"
out="$(facts_of 7)"
assert_eq "a plain directory at a recorded path: occupied" "$(fact "$out" worktree)" "occupied"
assert_eq "and wt_branch is empty" "$(fact "$out" wt_branch)" ""
rmdir "$p7"
git worktree prune
git branch -q -D orch/5-feature--t7
out="$(PATH="$(worktree_list_fails_bin):$PATH" facts_of 7)"; st=$?
assert_status "the read dies on an unreadable record, nothing at the path" "$st" 1
assert_not_contains "never reporting none" "$out" "worktree=none"

out="$(sourced_orch_script 'branch=b path=p n=n parent=pa tbranch=tb
ticket_facts 7 f
printf "%s %s %s %s %s" "$branch" "$path" "$n" "$parent" "$tbranch"' 2>&1)"
assert_eq "a caller's branch, path, n, parent and tbranch survive the read" "$out" "b p n pa tb"

git checkout -q --detach
out="$(facts_of 7)"; st=$?
assert_status "a detached HEAD in the checkout: the read does not die" "$st" 0
assert_eq "parent is empty" "$(fact "$out" parent)" ""
assert_eq "and so is own_branch" "$(fact "$out" own_branch)" ""
out="$(sourced_orch_script 'ticket_facts 7 f; ticket_facts_require_parent f' 2>&1)"; st=$?
assert_status "the parent helper dies there" "$st" 1
assert_contains "with its message" "$out" "not on a branch (detached HEAD)"
git checkout -q orch/5-feature

out="$(sourced_orch_script 'ticket_facts 7 f; ticket_facts_require_worktree f worktree' 2>&1)"; st=$?
assert_status "the worktree helper dies on a state not accepted" "$st" 1
assert_contains "with its message" "$out" "no ticket worktree for ticket 7 at $p7"
out="$(sourced_orch_script 'ticket_facts 7 f; ticket_facts_require_worktree f none gone' 2>&1)"; st=$?
assert_status "and accepts a state it is given" "$st" 0
"$ORCH" ticket-worktree add 7 >/dev/null
git -C "$p7" checkout -q --detach
out="$(sourced_orch_script 'ticket_facts 7 f; ticket_facts_require_wt_branch f' 2>&1)"; st=$?
assert_status "the branch helper dies on a detached ticket worktree" "$st" 1
assert_contains "with its message" "$out" "ticket worktree $p7 is not on a branch (detached HEAD)"
git -C "$p7" checkout -q orch/5-feature--t7
"$ORCH" ticket-worktree remove 7 --unmerged >/dev/null

out="$("$ORCH" ticket-worktree bogus 2>&1)"; st=$?
assert_status "ticket-worktree bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown ticket-worktree op"

out="$("$ORCH" help 2>&1)"
assert_contains "ticket-worktree add is in the usage text" "$out" "ticket-worktree add <n>"
assert_contains "ticket-worktree list is in the usage text" "$out" "ticket-worktree list"
assert_contains "ticket-worktree remove is in the usage text" "$out" "ticket-worktree remove <n> [--unmerged]"
assert_contains "the CLI conventions' noun table has a ticket-worktree row" \
  "$(grep '^| `ticket-worktree`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" \
  '`add`, `list`, `remove`'
restore_suite_env

# --- a ticket branch has no upstream (#1152) ----------------------------------
# Under branch.autoSetupMerge=inherit, a branch made from HEAD would take the
# parent branch's upstream; the ticket branch is local and short-lived, so it
# takes none.
echo
echo "a ticket branch has no upstream (#1152)"
tw_repo
git push -q -u origin orch/5-feature
git config branch.autoSetupMerge inherit
"$ORCH" ticket-worktree add 4 >/dev/null; st=$?
assert_status "add succeeds under autoSetupMerge=inherit" "$st" 0
assert_eq "the ticket branch has no upstream" "$(upstream_of orch/5-feature--t4)" "none"
restore_suite_env

# --- the merged check beside a same-named tag (#2337) -------------------------
# A tag named like a branch outranks it in git's lookup; the merged check
# behind remove must still judge the branches, with the tag at an old commit.
echo
echo "the merged check beside a same-named tag"
tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git merge -q --ff-only orch/5-feature--t7
git tag orch/5-feature HEAD~1
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove accepts a merged ticket beside a tag named like the parent" "$st" 0

tw_repo
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git tag orch/5-feature--t7 HEAD
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses an unmerged ticket beside a tag named like the ticket branch" "$st" 1
assert_contains "saying it is not merged" "$out" "not merged"
restore_suite_env
