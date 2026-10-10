# --- ticket-worktree (#619) ----------------------------------------------------
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

out="$("$ORCH" ticket-worktree add 7 2>&1)"; st=$?
assert_status "add refuses an existing worktree" "$st" 1
assert_contains "naming it" "$out" ".orchestrator/worktrees/t7"

git worktree remove "$top/.orchestrator/worktrees/t8"
out="$("$ORCH" ticket-worktree add 8 2>&1)"; st=$?
assert_status "add refuses an existing ticket branch" "$st" 1
assert_contains "naming the branch" "$out" "orch/5-feature--t8 already exists"
assert_eq "and adds no worktree" "$([ -e .orchestrator/worktrees/t8 ] && echo present || echo absent)" "absent"
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
assert_eq "it removes the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
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
assert_eq "leaving the worktree in place" "$([ -d "$wt" ] && echo present || echo absent)" "present"
assert_eq "and the branch at its tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
# No recorded forked-from branch: remove cannot judge the branch merged.
git config --unset branch.orch/5-feature--t7.orchestrator-ticket-parent
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a branch that records no forked-from branch" "$st" 1
assert_contains "saying so, with the --unmerged hint" "$out" \
  "orch: branch orch/5-feature--t7 records no forked-from branch - pass --unmerged to discard it"
assert_eq "leaving the worktree in place" "$([ -d "$wt" ] && echo present || echo absent)" "present"
assert_eq "and the branch at its tip" "$(git rev-parse orch/5-feature--t7)" "$ticket_tip"
out="$("$ORCH" ticket-worktree remove 7 --unmerged)"; st=$?
assert_status "remove --unmerged discards a clean worktree's unmerged branch" "$st" 0
assert_eq "removing the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""

# Left mid-rebase - a ticket conflict's resolution that failed: --unmerged
# aborts the rebase first, returning the ticket branch to its committed tip,
# then removes the clean worktree with no force.
wt="$("$ORCH" ticket-worktree add 7)"
echo ticket >"$wt/feature.txt" && git -C "$wt" commit -qam "ticket edit"
ticket_tip="$(git rev-parse orch/5-feature--t7)"
echo parent >feature.txt && git commit -qam "parent edit"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
echo leftover >"$wt/untracked.txt"
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged of a mid-rebase worktree still refuses it dirty" "$st" 1
assert_eq "having aborted its rebase first" \
  "$([ -d "$(git -C "$wt" rev-parse --absolute-git-dir)/rebase-merge" ] && echo rebasing || echo none)" "none"
assert_eq "returning the ticket branch to its committed tip" \
  "$(git -C "$wt" rev-parse HEAD) $(git -C "$wt" branch --show-current)" "$ticket_tip orch/5-feature--t7"
assert_eq "and removing nothing with force" "$(on_disk "$wt")" "present"
rm "$wt/untracked.txt"
git -C "$wt" rebase -q orch/5-feature >/dev/null 2>&1
out="$("$ORCH" ticket-worktree remove 7 --unmerged 2>&1)"; st=$?
assert_status "remove --unmerged of a clean mid-rebase worktree succeeds" "$st" 0
assert_eq "removing the worktree" "$(on_disk "$wt")" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""
git reset -q --hard HEAD~1

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
  "$([ -d "$(git rev-parse --absolute-git-dir)/rebase-merge" ] && echo rebasing || echo none)" "rebasing"
git rebase --abort
rmdir .orchestrator/worktrees/t9
git reset -q --hard HEAD~1
git branch -q -D orch/5-side

# Merged into its forked-from branch, but not into the branch the invoking
# checkout has checked out: merged is judged against the forked-from branch
# alone, so remove succeeds rather than refusing after the worktree is gone.
wt="$("$ORCH" ticket-worktree add 7)"
git -C "$wt" commit -q --allow-empty -m "ticket work"
git merge -q --ff-only orch/5-feature--t7
git checkout -q -b orch/5-elsewhere HEAD~1
out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove of a ticket merged into its forked-from branch but not HEAD succeeds" "$st" 0
assert_eq "removing the worktree" "$([ -e "$wt" ] && echo present || echo absent)" "absent"
assert_eq "and the branch" "$(git branch --list 'orch/5-feature--t7')" ""
git checkout -q orch/5-feature

out="$("$ORCH" ticket-worktree remove 7 2>&1)"; st=$?
assert_status "remove refuses a ticket with no worktree" "$st" 1
out="$("$ORCH" ticket-worktree remove 7 --bogus 2>&1)"; st=$?
assert_status "remove refuses an unknown flag" "$st" 1
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
