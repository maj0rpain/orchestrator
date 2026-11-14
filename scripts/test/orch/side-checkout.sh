# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# archived_count <top> <slug>: how many archive directories for <slug> the main
# checkout at <top> holds.
archived_count() { find "$1/.orchestrator/archive" -maxdepth 1 -name "*-$2" 2>/dev/null | wc -l | tr -d ' '; }

# archive_block / archive_unblock: make the main checkout's archive directory
# unwritable - a file stands where it goes - and put it back.
archive_block() {
  mv "$top/.orchestrator/archive" "$top/.orchestrator/archive.kept"
  : >"$top/.orchestrator/archive"
}
archive_unblock() {
  rm "$top/.orchestrator/archive"
  mv "$top/.orchestrator/archive.kept" "$top/.orchestrator/archive"
}

# sp_branch <branch>: kept or gone, by whether the local branch exists.
sp_branch() { if git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then echo kept; else echo gone; fi; }
# sp_branch_off <path> <branch>: puts the side checkout at <path> on a new
# branch with one commit of its own, never merged into main locally - as a
# squash merge on GitHub leaves it.
sp_branch_off() {
  git -C "$1" checkout -q -b "$2"
  git -C "$1" commit -q --allow-empty -m "work on $2"
}

# --- side-checkout (#722) -----------------------------------------------------
# A side checkout: a worktree the plugin makes under the main checkout's
# .orchestrator/checkouts/<slug>, on no branch at origin/<base>, carrying the
# ownership marker in its own git folder. Checked through what git and the
# file system show afterwards, against a real clone of a bare origin.
echo
echo "side-checkout"
# sc_marker <path>: whether the worktree at <path> carries the ownership marker.
sc_marker() {
  if [ -f "$(git -C "$1" rev-parse --absolute-git-dir)/orchestrator-side-checkout" ]; then
    echo marked; else echo unmarked; fi
}

sc_clone
top="$(git rev-parse --show-toplevel)"
# origin's main moves on after the clone, so only a fetch lands add on its tip.
git -C "$sc_seed" commit -q --allow-empty -m "main moves on"
git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/main
moved_tip="$(git -C "$sc_seed" rev-parse HEAD)"
out="$(orch_gh_failing side-checkout add alpha 2>/dev/null)"; st=$?
assert_status "add succeeds" "$st" 0
assert_eq "add prints the side checkout's path" "$out" "$top/.orchestrator/checkouts/alpha"
assert_eq "the side checkout is a worktree of its own" \
  "$(git -C "$out" rev-parse --show-toplevel)" "$top/.orchestrator/checkouts/alpha"
assert_eq "on no branch" "$(git -C "$out" branch --show-current)" ""
assert_eq "at origin/<base>'s tip, freshly fetched" "$(git -C "$out" rev-parse HEAD)" "$moved_tip"
assert_eq "carrying the ownership marker" "$(sc_marker "$out")" "marked"
assert_eq "the marker is empty" \
  "$(wc -c <"$(git -C "$out" rev-parse --absolute-git-dir)/orchestrator-side-checkout" | tr -d ' ')" "0"
assert_eq "the main checkout stays on its branch" "$(git branch --show-current)" "main"
assert_eq "in a fresh clone, git status in the main checkout shows nothing new" \
  "$(git status --porcelain)" ""
assert_eq "add excludes .orchestrator/" "$(exclude_count .orchestrator/)" "1"

out="$(orch_gh_failing side-checkout add alpha 2>&1)"; st=$?
assert_status "add refuses an existing path" "$st" 1
assert_contains "naming it" "$out" "$top/.orchestrator/checkouts/alpha"
mkdir -p .orchestrator/checkouts/stray
out="$(orch_gh_failing side-checkout add stray 2>&1)"; st=$?
assert_status "add refuses a path that exists without being a worktree" "$st" 1
assert_eq "and makes no worktree there" "$(git worktree list | wc -l | tr -d ' ')" "2"
rmdir .orchestrator/checkouts/stray
# The fixture helper keeps a failing add's error on stderr, and its status.
err="$(sc_add alpha 2>&1 >/dev/null)"; st=$?
assert_status "sc_add returns a failing add's status" "$st" 1
assert_contains "and prints add's error on stderr" "$err" "$top/.orchestrator/checkouts/alpha"

# The base branch in effect, not the checkout's branch.
git -C "$sc_seed" push -q "$sc_origin" HEAD~1:refs/heads/uat
uat_tip="$(git -C "$sc_seed" rev-parse HEAD~1)"
git config orchestrator.base uat
out="$(orch_gh_failing side-checkout add on-uat 2>/dev/null)"
assert_eq "add forks from the base branch in effect" "$(git -C "$out" rev-parse HEAD)" "$uat_tip"
git worktree remove "$out"

# A stray local branch named origin/main must not stand in for origin's tip.
git branch origin/main "$(git rev-list --max-parents=0 HEAD | tail -1)"
git config --unset orchestrator.base
out="$(orch_gh_failing side-checkout add stray 2>/dev/null)"
assert_eq "add forks from origin's tip, not a stray origin/main branch" \
  "$(git -C "$out" rev-parse HEAD)" "$moved_tip"
git worktree remove "$out"
git branch -q -D origin/main

# A failed fetch dies before any worktree exists.
git config orchestrator.base nosuch
out="$(orch_gh_failing side-checkout add nofetch 2>&1)"; st=$?
assert_status "add dies when the base branch cannot be fetched" "$st" 1
assert_contains "naming the base branch" "$out" "nosuch"
assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/nofetch)" "absent"
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "2"
git config --unset orchestrator.base

# A failed marker write takes the fresh worktree back out: a post-checkout hook
# makes the marker's name a directory, so no file can be written there.
writeln '#!/bin/sh' 'mkdir "$(git rev-parse --absolute-git-dir)/orchestrator-side-checkout"' 'exit 0' \
  >.git/hooks/post-checkout
chmod +x .git/hooks/post-checkout
out="$(orch_gh_failing side-checkout add nomarker 2>&1)"; st=$?
assert_status "add dies when the marker cannot be written" "$st" 1
assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/nomarker)" "absent"
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "2"
rm .git/hooks/post-checkout

# list: marked worktrees only, each with its flow or its branch.
out="$(orch_gh_failing side-checkout list)"; st=$?
assert_status "list succeeds" "$st" 0
assert_eq "a side checkout before a branch is made lists (no branch)" "$out" \
  "alpha $top/.orchestrator/checkouts/alpha (no branch)"
beta="$(sc_add beta)"
git -C "$beta" checkout -q -b quick/3-beta
gamma="$(sc_add gamma)"
(cd "$gamma" && orch_gh_failing init gamma-flow >/dev/null && orch_gh_failing state set issue 12)
delta="$(sc_add delta)"
(cd "$delta" && orch_gh_failing init delta-flow >/dev/null)
# Neither a hand-made worktree, even one holding a flow, nor a ticket worktree
# is a side checkout.
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
orch_gh_failing ticket-worktree add 4 >/dev/null
# git lists linked worktrees in no fixed order, so the lines are sorted.
out="$(orch_gh_failing side-checkout list | sort)"
assert_eq "list prints each side checkout's flow, branch, or (no branch)" "$out" \
  "$(writeln "alpha $top/.orchestrator/checkouts/alpha (no branch)" \
             "beta $top/.orchestrator/checkouts/beta branch quick/3-beta" \
             "delta $top/.orchestrator/checkouts/delta flow delta-flow spec (no issue)" \
             "gamma $top/.orchestrator/checkouts/gamma flow gamma-flow spec #12")"
assert_not_contains "never a hand-made worktree" "$out" "$hand"
assert_not_contains "never a ticket worktree" "$out" "worktrees/t4"
assert_eq "from a side checkout, list prints the same" "$(cd "$beta" && orch_gh_failing side-checkout list | sort)" "$out"
assert_eq "add from a side checkout still nests under the main checkout" \
  "$(cd "$beta" && orch_gh_failing side-checkout add epsilon 2>/dev/null)" "$top/.orchestrator/checkouts/epsilon"
git worktree remove "$top/.orchestrator/checkouts/epsilon"
orch_gh_failing ticket-worktree remove 4 --unmerged
assert_eq "git status in the main checkout still shows nothing new" "$(git status --porcelain)" ""

# archive and init over a done flow in the main checkout skip checkouts/.
orch_gh_failing init main-flow >/dev/null
dest="$(orch_gh_failing archive)"; st=$?
assert_status "archive in the main checkout succeeds beside side checkouts" "$st" 0
assert_eq "it moves no side checkout into the archive" "$(on_disk "$dest/checkouts")" "absent"
assert_eq "checkouts/ stays in place" "$(on_disk .orchestrator/checkouts/alpha)" "present"
assert_eq "each side checkout stays where git recorded it" \
  "$(git -C .orchestrator/checkouts/gamma rev-parse --show-toplevel)" "$top/.orchestrator/checkouts/gamma"
assert_eq "with its flow untouched" "$(cd "$gamma" && orch_gh_failing state get slug)" "gamma-flow"
orch_gh_failing init done-flow >/dev/null
state_fixture phase "done"
out="$(orch_gh_failing init next-flow)"; st=$?
assert_status "init over a done flow succeeds beside side checkouts" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n 1p)"
assert_eq "it archives no side checkout" "$(on_disk "$archived/checkouts")" "absent"
assert_eq "each side checkout stays where git recorded it" \
  "$(git -C .orchestrator/checkouts/beta branch --show-current)" "quick/3-beta"
assert_eq "and side-checkout list is unchanged" "$(orch_gh_failing side-checkout list | wc -l | tr -d ' ')" "4"

# A side checkout made for a quick implementation records its issue (#874).
qi="$(orch_gh_failing side-checkout add quick-one --issue 123 2>/dev/null)"; st=$?
assert_status "add --issue succeeds" "$st" 0
assert_eq "add --issue prints the side checkout's path" "$qi" "$top/.orchestrator/checkouts/quick-one"
out="$(cd "$qi" && orch_gh_failing side-checkout issue)"; st=$?
assert_status "side-checkout issue succeeds in a side checkout made with --issue" "$st" 0
assert_eq "printing the recorded issue" "$out" "123"
mkdir -p "$qi/sub"
assert_eq "from a folder inside it too" "$(cd "$qi/sub" && orch_gh_failing side-checkout issue)" "123"
rmdir "$qi/sub"
assert_contains "list appends quick #N before a branch exists" \
  "$(orch_gh_failing side-checkout list)" "quick-one $qi (no branch) quick #123"
git -C "$qi" checkout -q -b quick/123-quick-one
assert_contains "and after a branch is checked out" \
  "$(orch_gh_failing side-checkout list)" "quick-one $qi branch quick/123-quick-one quick #123"
out="$(cd "$top/.orchestrator/checkouts/alpha" && orch_gh_failing side-checkout issue 2>&1)"; st=$?
assert_status "side-checkout issue exits 1 in a side checkout made without --issue" "$st" 1
assert_not_contains "and list appends nothing for it" \
  "$(orch_gh_failing side-checkout list | grep '^alpha ')" "quick #"
out="$(orch_gh_failing side-checkout issue 2>&1)"; st=$?
assert_status "side-checkout issue exits 1 in the main checkout" "$st" 1
printf 'abc\n' >"$(git -C "$qi" rev-parse --absolute-git-dir)/orchestrator-side-checkout"
out="$(cd "$qi" && orch_gh_failing side-checkout issue 2>&1)"; st=$?
assert_status "side-checkout issue exits 1 when the marker is not a plain number" "$st" 1
assert_not_contains "and list appends nothing for it" \
  "$(orch_gh_failing side-checkout list | grep '^quick-one ')" "quick #"
out="$(cd "$qi" && orch_gh_failing side-checkout issue extra 2>&1)"; st=$?
assert_status "side-checkout issue refuses arguments with exit 2, never a 'none'" "$st" 2
git worktree remove "$qi"
git branch -q -D quick/123-quick-one

# A ticket worktree carrying a copied marker is no side checkout (#1110).
marked="$(marked_ticket_worktree 41)"
out="$(cd "$marked" && orch_gh_failing side-checkout issue 2>&1)"; st=$?
assert_status "side-checkout issue exits 1 in a ticket worktree carrying a copied marker" "$st" 1
git worktree remove "$marked"
git branch -q -D main--t41

worktrees_before="$(git worktree list | wc -l | tr -d ' ')"
for issue_arg in "" "12a" "#5"; do
  if [ -z "$issue_arg" ]; then out="$(orch_gh_failing side-checkout add badissue --issue 2>&1)"; st=$?
  else out="$(orch_gh_failing side-checkout add badissue --issue "$issue_arg" 2>&1)"; st=$?; fi
  assert_status "add refuses --issue '$issue_arg'" "$st" 1
  assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/badissue)" "absent"
  assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "$worktrees_before"
done
assert_contains "naming what it wants" \
  "$(orch_gh_failing side-checkout add badissue --issue 12a 2>&1)" "--issue wants a plain issue number, got: 12a"
out="$(orch_gh_failing side-checkout add badissue --bogus 2>&1)"; st=$?
assert_status "add refuses an unknown flag" "$st" 1

# A failed write of the issue takes the fresh worktree back out.
writeln '#!/bin/sh' 'mkdir "$(git rev-parse --absolute-git-dir)/orchestrator-side-checkout"' 'exit 0' \
  >.git/hooks/post-checkout
chmod +x .git/hooks/post-checkout
out="$(orch_gh_failing side-checkout add noissue --issue 7 2>&1)"; st=$?
assert_status "add --issue dies when the issue cannot be written" "$st" 1
assert_eq "leaving no side checkout" "$(on_disk .orchestrator/checkouts/noissue)" "absent"
assert_eq "nor any worktree" "$(git worktree list | wc -l | tr -d ' ')" "$worktrees_before"
rm .git/hooks/post-checkout

out="$(orch_gh_failing side-checkout add 2>&1)"; st=$?
assert_status "add refuses a missing slug" "$st" 1
out="$(orch_gh_failing side-checkout list extra 2>&1)"; st=$?
assert_status "list refuses arguments" "$st" 1
out="$(orch_gh_failing side-checkout bogus 2>&1)"; st=$?
assert_status "side-checkout bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown side-checkout op"
out="$(orch_gh_failing help 2>&1)"
assert_contains "side-checkout add is in the usage text" "$out" "side-checkout add <slug>"
assert_contains "side-checkout list is in the usage text" "$out" "side-checkout list"
assert_contains "side-checkout add --issue is in the usage text" "$out" "side-checkout add <slug> [--issue N]"
assert_contains "side-checkout issue is in the usage text" "$out" "side-checkout issue"
assert_contains "the CLI conventions' noun table has a side-checkout row" \
  "$(grep '^| `side-checkout`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`add`, `list`'
assert_contains "naming the issue verb" \
  "$(grep '^| `side-checkout`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`issue`'
assert_eq "docs/how-it-works.md names side-checkout add --issue" \
  "$(grep -c 'side-checkout add <slug> --issue' "$PLUGIN_ROOT/docs/how-it-works.md" | tr -d ' ')" "1"
assert_eq "docs/how-it-works.md names side-checkout issue" \
  "$(grep -c 'orch.sh side-checkout issue' "$PLUGIN_ROOT/docs/how-it-works.md" | tr -d ' ')" "1"
restore_suite_env

# --- status lists every checkout (#725) ---------------------------------------
# status keeps its full detail on this checkout's flow, then lists one line
# for every other checkout holding a flow, and every side checkout without
# one. Checked through status's output against real worktrees of a clone.
echo
echo "status lists every checkout"
# st_others: the lines status prints under "other checkouts:", sorted - git
# lists linked worktrees in no fixed order.
st_others() { sed -n '/^other checkouts:$/,$p' | sed 1d | sort; }

sc_clone
top="$(git rev-parse --show-toplevel)"
out="$(orch_gh_failing status)"
assert_eq "with no flow and no other checkout, status prints only the no-flow line" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"
assert_contains "and that line is the no-flow line" "$out" "No active flow."
orch_gh_failing init main-flow >/dev/null
orch_gh_failing state set issue 7
alone="$(orch_gh_failing status)"
assert_not_contains "with no other checkout, status lists none" "$alone" "other checkouts"
# Ticket worktrees hold no flow and carry no marker.
orch_gh_failing ticket-worktree add 4 >/dev/null
assert_eq "a ticket worktree never appears" "$(orch_gh_failing status)" "$alone"

alpha="$(sc_add alpha)"
beta="$(sc_add beta)"
git -C "$beta" checkout -q -b quick/3-beta
gamma="$(sc_add gamma)"
(cd "$gamma" && orch_gh_failing init gamma-flow >/dev/null && orch_gh_failing state set issue 12)
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
# A hand-made worktree with no flow is not the plugin's to list.
bare_hand="$(mktemp -d)/bare-hand"
git worktree add -q -b bare-hand "$bare_hand"

out="$(orch_gh_failing status)"; st=$?
assert_status "status in the main checkout succeeds" "$st" 0
assert_eq "it keeps its full detail on this checkout's flow" \
  "$(printf '%s\n' "$out" | sed '/^other checkouts:$/,$d')" "$alone"
assert_eq "it lists each side checkout and each hand-made worktree holding a flow" \
  "$(printf '%s\n' "$out" | st_others)" \
  "$(writeln "  $alpha (no branch)" \
             "  $beta branch quick/3-beta" \
             "  $gamma flow gamma-flow spec #12" \
             "  $hand flow hand-flow spec (no issue)" | sort)"
assert_not_contains "never a hand-made worktree without a flow" "$out" "$bare_hand"
assert_not_contains "never a ticket worktree" "$out" "worktrees/t4"
# Each checkout is classified in a subshell, yet every module loads once.
assert_loads_once "status with three side checkouts" orch_gh_failing status

out="$(cd "$gamma" && orch_gh_failing status)"
assert_contains "status in a side checkout shows its own flow in full" "$out" "flow:      gamma-flow"
assert_contains "with its own issue" "$out" "issue:     12"
assert_eq "and lists the others, the main checkout's flow among them" \
  "$(printf '%s\n' "$out" | st_others)" \
  "$(writeln "  $top flow main-flow spec #7" \
             "  $alpha (no branch)" \
             "  $beta branch quick/3-beta" \
             "  $hand flow hand-flow spec (no issue)" | sort)"

orch_gh_failing ticket-worktree remove 4 --unmerged
orch_gh_failing archive >/dev/null
out="$(orch_gh_failing status)"
assert_eq "with no flow here, status prints No active flow. first" \
  "$(printf '%s\n' "$out" | sed -n 1p | cut -c1-15)" "No active flow."
assert_eq "and still lists the others" "$(printf '%s\n' "$out" | st_others | wc -l | tr -d ' ')" "4"

# A quick implementation in the main checkout keeps no state and carries no
# marker, so it never appears.
git checkout -q -b quick/9-main
out="$(cd "$beta" && orch_gh_failing status)"
assert_not_contains "a quick implementation in the main checkout never appears" "$out" "$top "
assert_not_contains "nor its branch" "$out" "quick/9-main"

# A side checkout whose state.json is truncated is listed plainly, by status
# and by side-checkout list, with no jq text.
(cd "$gamma" && state_truncate 10)
out="$(orch_gh_failing status 2>&1)"
assert_contains "status lists an unreadable side checkout plainly" "$out" "$gamma flow (state.json cannot be read)"
assert_not_contains "status prints no jq text" "$out" "parse error"
out="$(orch_gh_failing side-checkout list 2>&1)"
assert_contains "side-checkout list says the same" "$out" "gamma $gamma flow (state.json cannot be read)"
assert_not_contains "list prints no jq text" "$out" "parse error"
restore_suite_env

# --- side-checkout archive and remove (#724) ----------------------------------
# git worktree remove deletes ignored files, .orchestrator/ included, so a side
# checkout's flow is archived into the main checkout before its worktree goes.
# Checked through the archive and worktrees left on disk, and the output.
echo
echo "side-checkout archive and remove"

sc_clone
top="$(git rev-parse --show-toplevel)"

# archive in a clean side checkout, run from inside it.
alpha="$(sc_add alpha)"
(cd "$alpha" && orch_gh_failing init alpha-flow >/dev/null)
complete_handoff "$(cd "$alpha" && orch_gh_failing handoff path spec)"
out="$(cd "$alpha" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a clean side checkout succeeds" "$st" 0
assert_eq "it leaves the archive in the main checkout's .orchestrator/archive/" \
  "$(archived_count "$top" alpha-flow)" "1"
assert_eq "with the flow's handoffs in it" \
  "$(on_disk "$(find "$top/.orchestrator/archive" -maxdepth 1 -name '*-alpha-flow')/handoff/01-plan.md")" "present"
assert_contains "it prints the archive's full path" "$out" "$top/.orchestrator/archive/"
assert_eq "the worktree is gone from disk" "$(on_disk "$alpha")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$alpha"

# archive in a dirty side checkout: the archive succeeds, the worktree stays.
beta="$(sc_add beta)"
(cd "$beta" && orch_gh_failing init beta-flow >/dev/null)
echo wip >"$beta/wip.txt"
out="$(cd "$beta" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a dirty side checkout succeeds" "$st" 0
assert_eq "it archives into the main checkout" "$(archived_count "$top" beta-flow)" "1"
assert_eq "and leaves the worktree in place" "$(on_disk "$beta/wip.txt")" "present"
assert_contains "reporting why it was kept" "$out" "could not remove side checkout $beta"
assert_contains "naming the remove command" "$out" "side-checkout remove beta"
assert_eq "no flow is left in it" "$(on_disk "$beta/.orchestrator/state.json")" "absent"

# init over a done flow in a side checkout archives to the main checkout and
# keeps the worktree, where the new flow lives.
gamma="$(sc_add gamma)"
(cd "$gamma" && orch_gh_failing init old-flow >/dev/null && state_fixture phase "done")
out="$(cd "$gamma" && orch_gh_failing init new-flow 2>&1)"; st=$?
assert_status "init over a done flow in a side checkout succeeds" "$st" 0
assert_eq "it archives the old flow into the main checkout" "$(archived_count "$top" old-flow)" "1"
assert_eq "and nothing into the side checkout's own archive" \
  "$(on_disk "$gamma/.orchestrator/archive")" "absent"
assert_eq "the worktree stays" "$(git -C "$gamma" rev-parse --show-toplevel)" "$gamma"
assert_eq "holding the new flow" "$(cd "$gamma" && orch_gh_failing state get slug)" "new-flow"

# archive in a hand-made worktree archives in place and leaves it.
hand="$(mktemp -d)/hand"
git worktree add -q -b hand "$hand"
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null)
out="$(cd "$hand" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a hand-made worktree succeeds" "$st" 0
assert_eq "it archives in place" "$(archived_count "$hand" hand-flow)" "1"
assert_eq "not into the main checkout" "$(archived_count "$top" hand-flow)" "0"
assert_eq "the worktree stays" "$(git -C "$hand" rev-parse --show-toplevel)" "$hand"
assert_not_contains "with no removal reported" "$out" "side checkout"

# archive in a ticket worktree carrying a copied marker archives in place and
# leaves it, as a ticket worktree's, never as a side checkout's (#1110).
marked="$(marked_ticket_worktree 42)"
worktrees_before="$(git worktree list | wc -l | tr -d ' ')"
(cd "$marked" && orch_gh_failing init marked-flow >/dev/null)
out="$(cd "$marked" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a ticket worktree carrying a copied marker succeeds" "$st" 0
assert_eq "it archives into that worktree's own archive" "$(archived_count "$marked" marked-flow)" "1"
assert_eq "not into the main checkout" "$(archived_count "$top" marked-flow)" "0"
assert_eq "and removes no worktree" "$(git worktree list | wc -l | tr -d ' ')" "$worktrees_before"
git worktree remove "$marked"
git branch -q -D main--t42

# When git worktree list fails, nothing is archived: archive and init die, the
# flow left in place (#1110). A git on PATH that fails `worktree list` alone is
# enough.
worktree_list_fails="$(worktree_list_fails_bin)"
(cd "$hand" && orch_gh_failing init walk-flow >/dev/null && state_fixture phase "done")
out="$(cd "$hand" && PATH="$worktree_list_fails:$PATH" orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "could not read the checkouts - nothing was archived"
assert_eq "archiving nothing" "$(archived_count "$hand" walk-flow)" "0"
out="$(cd "$hand" && PATH="$worktree_list_fails:$PATH" orch_gh_failing init next-walk-flow 2>&1)"; st=$?
assert_status "init over a done flow dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "could not read the checkouts - nothing was archived or written"
assert_eq "archiving nothing" "$(archived_count "$hand" walk-flow)" "0"
assert_eq "the flow stays" "$(cd "$hand" && orch_gh_failing state get slug)" "walk-flow"
# When git worktree list fails, every other command that reads it stops, rather
# than reading it as no checkouts (#1333).
out="$(PATH="$worktree_list_fails:$PATH" orch_gh_failing side-checkout list 2>&1)"; st=$?
assert_status "side-checkout list dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "orch: could not read the checkouts"
out="$(PATH="$worktree_list_fails:$PATH" orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "side-checkout prune dies when the walk fails" "$st" 1
assert_contains "saying nothing was removed" "$out" "orch: could not read the checkouts - nothing was removed"
out="$(PATH="$worktree_list_fails:$PATH" orch_gh_failing side-checkout add walk-add 2>&1)"; st=$?
assert_status "side-checkout add dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "orch: could not read the checkouts - git worktree list failed"
out="$(PATH="$worktree_list_fails:$PATH" orch_gh_failing side-checkout remove walk-rm 2>&1)"; st=$?
assert_status "side-checkout remove dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "orch: could not read the checkouts - git worktree list failed"
out="$(PATH="$worktree_list_fails:$PATH" orch_gh_failing status 2>&1)"; st=$?
assert_status "status dies when the walk fails" "$st" 1
assert_contains "naming the checkouts" "$out" "orch: could not read the checkouts"

# side-checkout remove: every refusal before anything moves.
out="$(orch_gh_failing side-checkout remove nosuch 2>&1)"; st=$?
assert_status "remove refuses an unknown slug" "$st" 1
assert_contains "naming it" "$out" "no side checkout nosuch"
unmarked="$top/.orchestrator/checkouts/unmarked"
git worktree add -q --detach "$unmarked"
(cd "$unmarked" && orch_gh_failing init unmarked-flow >/dev/null)
out="$(orch_gh_failing side-checkout remove unmarked 2>&1)"; st=$?
assert_status "remove refuses a worktree without the marker" "$st" 1
assert_contains "saying it is left alone" "$out" "left alone"
assert_eq "its flow is not moved" "$(on_disk "$unmarked/.orchestrator/state.json")" "present"
assert_eq "nor its worktree removed" "$(on_disk "$unmarked")" "present"
# A side checkout made by add whose marker is then deleted: remove and list
# read the marker through the same rule, so both see it as no side checkout.
unmade="$(sc_add unmade)"
rm "$(git -C "$unmade" rev-parse --absolute-git-dir)/orchestrator-side-checkout"
out="$(orch_gh_failing side-checkout remove unmade 2>&1)"; st=$?
assert_status "remove refuses a side checkout whose marker was deleted" "$st" 1
assert_contains "saying it carries no marker" "$out" "carries no side-checkout marker"
assert_eq "its worktree is not removed" "$(on_disk "$unmade")" "present"
assert_not_contains "and list leaves it out" "$(orch_gh_failing side-checkout list)" "$unmade"
(cd "$gamma" && git checkout -q -b quick/5-gamma)
echo wip >"$gamma/wip.txt"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses untracked files" "$st" 1
assert_contains "naming the side checkout" "$out" "$gamma"
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
rm "$gamma/wip.txt"
echo changed >>"$gamma/$(git -C "$gamma" ls-files | awk -v n=1 'NR<=n')"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses uncommitted changes" "$st" 1
assert_contains "saying so" "$out" \
  "orch: side checkout $gamma has uncommitted changes or untracked files - commit or discard them first; it is never removed with force"
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
git -C "$gamma" checkout -q -- .
# A git status that cannot run is a refusal naming git's error, never a clean
# tree.
break_index "$gamma"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
restore_index "$gamma"
assert_status "remove refuses when git status cannot run" "$st" 1
assert_contains "naming git's error" "$out" "git status failed - cannot check the working tree: "
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
assert_eq "nor its worktree removed" "$(on_disk "$gamma")" "present"
# #974: a ticket worktree left under a side checkout holding a flow is refused
# once, through the archive, before anything moves.
(cd "$gamma" && orch_gh_failing ticket-worktree add 6 >/dev/null)
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses a ticket worktree under a side checkout holding a flow" "$st" 1
assert_contains "naming it" "$out" "$gamma/.orchestrator/worktrees/t6"
assert_contains "with ticket-worktree remove as the remedy" "$out" "orch.sh ticket-worktree remove 6"
assert_first_line "its refusal's first line carries one prefix (#1718)" "$out" \
  "orch: ticket worktrees are left under $gamma - moving them would break git's record of them:"
assert_eq "and the refusal arrives whole" "$(printf '%s\n' "$out" | tail -n 1)" \
  "     Remove each with orch.sh ticket-worktree remove <n> first."
assert_eq "its flow is not archived" "$(archived_count "$top" new-flow)" "0"
assert_eq "its flow stays in place" "$(on_disk "$gamma/.orchestrator/state.json")" "present"
assert_eq "nor its worktree removed" "$(on_disk "$gamma")" "present"
assert_eq "its branch is kept" \
  "$(git rev-parse --verify --quiet refs/heads/quick/5-gamma >/dev/null && echo kept || echo gone)" "kept"
assert_eq "the ticket worktree stays where git recorded it" \
  "$(git -C "$gamma/.orchestrator/worktrees/t6" rev-parse --show-toplevel)" "$gamma/.orchestrator/worktrees/t6"
(cd "$gamma" && orch_gh_failing ticket-worktree remove 6 >/dev/null)
# And under a side checkout holding no flow, the same refusal.
zeta="$(sc_add zeta)"
git -C "$zeta" checkout -q -b quick/6-zeta
(cd "$zeta" && orch_gh_failing ticket-worktree add 7 >/dev/null)
archives_before="$(ls "$top/.orchestrator/archive" 2>/dev/null | wc -l)"
out="$(orch_gh_failing side-checkout remove zeta 2>&1)"; st=$?
assert_status "remove refuses a ticket worktree under a side checkout holding no flow" "$st" 1
assert_contains "naming it" "$out" "$zeta/.orchestrator/worktrees/t7"
assert_contains "with ticket-worktree remove as the remedy" "$out" "orch.sh ticket-worktree remove 7"
assert_eq "nothing is archived" "$(ls "$top/.orchestrator/archive" 2>/dev/null | wc -l)" "$archives_before"
assert_eq "its worktree is not removed" "$(on_disk "$zeta")" "present"
assert_eq "its branch is kept" \
  "$(git rev-parse --verify --quiet refs/heads/quick/6-zeta >/dev/null && echo kept || echo gone)" "kept"
assert_eq "the ticket worktree stays where git recorded it" \
  "$(git -C "$zeta/.orchestrator/worktrees/t7" rev-parse --show-toplevel)" "$zeta/.orchestrator/worktrees/t7"
(cd "$zeta" && orch_gh_failing ticket-worktree remove 7 >/dev/null)
orch_gh_failing side-checkout remove zeta >/dev/null 2>&1

# remove archives the flow into the main checkout, removes the worktree, and
# keeps the branch.
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove succeeds on a clean side checkout" "$st" 0
assert_eq "it archives the flow into the main checkout" "$(archived_count "$top" new-flow)" "1"
assert_eq "the worktree is gone" "$(on_disk "$gamma")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$gamma"
assert_eq "the branch is kept" \
  "$(git rev-parse --verify --quiet refs/heads/quick/5-gamma >/dev/null && echo kept || echo gone)" "kept"


# A failing git worktree remove: the archive stands, and remove exits 1. A
# locked worktree is one git refuses to remove without force.
eps="$(sc_add eps)"
(cd "$eps" && orch_gh_failing init eps-flow >/dev/null)
sp_branch_off "$eps" quick/9-eps
git worktree lock "$eps"
out="$(orch_gh_failing side-checkout remove eps 2>&1)"; st=$?
assert_status "remove exits 1 when the worktree cannot be removed" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $eps"
assert_eq "the archive stands" "$(archived_count "$top" eps-flow)" "1"
assert_eq "the worktree stays" "$(on_disk "$eps")" "present"
assert_eq "the branch is kept" "$(sp_branch quick/9-eps)" "kept"
git worktree unlock "$eps"

out="$(orch_gh_failing side-checkout remove 2>&1)"; st=$?
assert_status "remove refuses a missing slug" "$st" 1
assert_contains "side-checkout remove is in the usage text" "$(orch_gh_failing help)" "side-checkout remove <slug>"

# CLI callers, archive failure: an archive that cannot be written removes
# nothing; archive and remove print the error unchanged and exit 1.
for caller in archive remove; do
  af="$(sc_add "af-$caller")"
  (cd "$af" && orch_gh_failing init "af-$caller-flow" >/dev/null)
  archive_block
  if [ "$caller" = archive ]; then
    out="$(cd "$af" && orch_gh_failing archive 2>&1)"; st=$?
  else
    out="$(orch_gh_failing side-checkout remove "af-$caller" 2>&1)"; st=$?
  fi
  archive_unblock
  assert_status "$caller exits 1 when the archive cannot be written" "$st" 1
  assert_contains "$caller prints the archive error unchanged" "$out" "orch: could not create the archive directory"
  assert_contains "$caller names the main checkout's archive" "$out" "$top/.orchestrator/archive/"
  assert_not_contains "$caller prints the error with one prefix" "$out" "orch: orch: "
  assert_eq "$caller leaves the worktree" "$(on_disk "$af/.orchestrator/state.json")" "present"
done

# side_checkout_remove_worktree and side_checkout_archive_and_remove:
# Each function through the sourced module, one case per policy and outcome.
sf="$(sc_add sf)"
out="$(cd "$top" && sourced_orch side_checkout_remove_worktree "$sf" "$top" "$top" die 2>&1)"; st=$?
assert_status "remove_worktree removes a clean checkout" "$st" 0
assert_eq "noting it and no close-the-session note" "$out" "removed side checkout $sf"
assert_eq "the worktree is gone" "$(on_disk "$sf")" "absent"
sf="$(sc_add sf)"
out="$(cd "$top" && sourced_orch side_checkout_remove_worktree "$sf" "$top" "$sf/sub" warn 2>&1)"
assert_contains "remove_worktree tells the human to close a session that ran inside" "$out" "close this session"
sf="$(sc_add sf)"
echo wip >"$sf/wip.txt"
refusal="could not remove side checkout $sf: fatal: '$sf' contains modified or untracked files, use --force to delete it - left as it stands. Commit or discard its changes, then run orch.sh side-checkout remove sf."
out="$(cd "$top" && sourced_orch side_checkout_remove_worktree "$sf" "$top" "$top" die 2>&1)"; st=$?
assert_status "die dies on a refusal" "$st" 1
assert_eq "with the one refusal message" "$out" "orch: $refusal"
out="$(cd "$top" && sourced_orch side_checkout_remove_worktree "$sf" "$top" "$top" warn 2>&1)"; st=$?
assert_status "warn returns 1 on a refusal" "$st" 1
assert_eq "with the same message" "$out" "orch: $refusal"
assert_eq "the worktree stays" "$(on_disk "$sf/wip.txt")" "present"
rm "$sf/wip.txt"

(cd "$sf" && orch_gh_failing init sf-flow >/dev/null)
out="$(cd "$top" && sourced_orch_script 'side_checkout_archive_and_remove "$1" "$2" "$2" die && echo "rc=0"; echo "out=$archive_out"' "$sf" "$top" 2>&1)"
assert_contains "archive_and_remove returns 0" "$out" "rc=0"
assert_eq "the flow is archived in the main checkout, the worktree gone" \
  "$(archived_count "$top" sf-flow)$(on_disk "$sf")" "1absent"
assert_contains "archive_out holds the archive's path" "$out" "out=.orchestrator/archive/"
sf="$(sc_add sf)"
(cd "$sf" && orch_gh_failing init sf2-flow >/dev/null)
echo wip >"$sf/wip.txt"
out="$(cd "$top" && sourced_orch_script 'side_checkout_archive_and_remove "$1" "$2" "$2" warn || echo "rc=$?"' "$sf" "$top" 2>&1)"
assert_contains "warn policy returns 1 for a refused removal" "$out" "rc=1"
assert_eq "the archive stands" "$(archived_count "$top" sf2-flow)" "1"
sf="$(sc_add sf3)"
(cd "$sf" && orch_gh_failing init sf3-flow >/dev/null)
archive_block
for policy in die warn; do
  out="$(cd "$top" && sourced_orch_script 'side_checkout_archive_and_remove "$1" "$2" "$2" "$3" || echo "rc=$?"; echo "out=$archive_out"' "$sf" "$top" "$policy" 2>&1)"
  assert_contains "an archive failure returns 2 under $policy" "$out" "rc=2"
  assert_contains "keeping the error in archive_out" "$out" "out=orch: could not create the archive directory"
done
archive_unblock
assert_eq "and removes nothing" "$(on_disk "$sf/.orchestrator/state.json")" "present"
restore_suite_env

# --- side-checkout prune (#726) -----------------------------------------------
# The finished sweep behind /orchestrator:finish: a side checkout whose PR
# GitHub reports merged into its base, whose tree is clean, and whose flow -
# if any - is at done, is archived into the main checkout, removed, and its
# local branch deleted. Checked through the worktrees, branches and archives
# left on disk, and the report, against the store-backed GitHub fake.
echo
echo "side-checkout prune"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
# Offline while arranging, so each add's own sweep leaves the arrangement be.
fake_offline

# A finished flow side checkout, its PR squash-merged.
fl="$(sc_add fl)"
(cd "$fl" && orch_gh_failing init fl-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/fl-flow && state_fixture pr 41)
sp_branch_off "$fl" orch/fl-flow
fake_pr 41 merged orch/fl-flow main
fake_pr_head 41 "$(git rev-parse orch/fl-flow)"
# A finished quick-implementation side checkout.
qk="$(sc_add qk)"
sp_branch_off "$qk" quick/7-qk
fake_pr 42 merged quick/7-qk main
fake_pr_head 42 "$(git rev-parse quick/7-qk)"
# The main checkout's own finished flow.
orch_gh_failing init main-flow >/dev/null
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 45
fake_pr 45 merged orch/main-flow main

# A side checkout whose state.json is truncated has a verdict that could not be
# read: reported, left in place, with no jq text.
unreadable="$(sc_add bad)"
(cd "$unreadable" && orch_gh_failing init bad-flow >/dev/null && state_truncate 10)
out="$(orch_gh_failing side-checkout prune 2>&1)"
assert_contains "prune reports the unreadable state file" "$out" \
  "could not check $unreadable: could not read $unreadable/.orchestrator/state.json"
assert_not_contains "prune prints no jq text" "$out" "parse error"
assert_eq "the unreadable side checkout stays" "$(on_disk "$unreadable")" "present"
git worktree remove --force "$unreadable"

# GitHub unreachable: nothing is removed.
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when GitHub cannot be read" "$st" 1
assert_contains "saying nothing was removed" "$out" "nothing was removed"
assert_contains "reporting the first unreadable checkout with its reason" "$out" "could not check $fl: could not read GitHub"
assert_contains "and the second, not only the last" "$out" "could not check $qk: could not read GitHub"
assert_eq "the finished flow side checkout stays" "$(on_disk "$fl")" "present"
assert_eq "the finished quick side checkout stays" "$(on_disk "$qk")" "present"
assert_eq "its branch stays" "$(sp_branch quick/7-qk)" "kept"
assert_eq "the main checkout's flow is not archived" "$(on_disk "$top/.orchestrator/state.json")" "present"
fake_online

# A GitHub read that fails with nothing on stderr: the reason says so, rather
# than leaving the verdict ending in a bare colon.
fake_fail adapter_pr_state_draft ''
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when a read fails silently" "$st" 1
assert_contains "the verdict ending gh gave no reason" "$out" \
  "could not check $fl: could not read GitHub: gh gave no reason"
assert_eq "the finished flow side checkout stays" "$(on_disk "$fl")" "present"
fake_unfail

fake_fail adapter_pr_state_draft "$GH_502"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when a read fails" "$st" 1
assert_contains "the verdict carrying gh's first line" "$out" \
  "could not check $fl: could not read GitHub: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_contains "a failed state/draft read removes nothing" "$out" "nothing was removed"
fake_unfail

# The finished-flow check's second read, the PR's refs: the same verdict.
fake_fail adapter_pr_refs "$GH_502"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when the refs read fails" "$st" 1
assert_contains "the refs verdict carrying gh's first line" "$out" \
  "could not check $fl: could not read GitHub: HTTP 502: Bad Gateway"
assert_contains "a failed refs read removes nothing" "$out" "nothing was removed"
assert_eq "the finished flow side checkout stays" "$(on_disk "$fl")" "present"
fake_unfail

# A side checkout with no flow reads the merged-PR list instead: the same
# verdict.
fake_fail adapter_prs_merged "$GH_502"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails when the merged-PR list fails" "$st" 1
assert_contains "the merged-PR list verdict carrying gh's first line" "$out" \
  "could not check $qk: could not read GitHub: HTTP 502: Bad Gateway"
assert_contains "a failed merged-PR list removes nothing" "$out" "nothing was removed"
assert_eq "the finished quick side checkout stays" "$(on_disk "$qk")" "present"
fake_unfail

fake_offline
# An open PR.
op="$(sc_add op)"
sp_branch_off "$op" quick/8-op
fake_pr 43 open quick/8-op main
# A dirty tree, its PR merged.
dt="$(sc_add dt)"
sp_branch_off "$dt" quick/9-dt
fake_pr 44 merged quick/9-dt main
fake_pr_head 44 "$(git rev-parse quick/9-dt)"
echo wip >"$dt/wip.txt"
# A flow not at done.
nd="$(sc_add nd)"
(cd "$nd" && orch_gh_failing init nd-flow >/dev/null && state_fixture phase implement)
# A finished side checkout whose PR was a true merge: its branch is an
# ancestor of main.
tm="$(sc_add tm)"
sp_branch_off "$tm" quick/17-tm
git merge -q --no-ff --no-edit quick/17-tm
fake_pr 56 merged quick/17-tm main
fake_pr_head 56 "$(git rev-parse quick/17-tm)"
# A side checkout still on no branch.
nb="$(sc_add nb)"
# Flows at done whose recorded PR is still open, and closed unmerged: their
# verdict names the PR's state in lowercase.
po="$(sc_add po)"
(cd "$po" && orch_gh_failing init po-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/po-flow && state_fixture pr 61)
sp_branch_off "$po" orch/po-flow
fake_pr 61 open orch/po-flow main
pc="$(sc_add pc)"
(cd "$pc" && orch_gh_failing init pc-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/pc-flow && state_fixture pr 62)
sp_branch_off "$pc" orch/pc-flow
fake_pr 62 closed orch/pc-flow main
# The main checkout's flow's branch, made only after tm's merge has landed on
# main.
git checkout -q -b orch/main-flow
# A hand-made worktree holding a finished flow.
hand="$(mktemp -d)/hand"
git worktree add -q -b orch/hand-flow "$hand" main
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/hand-flow && state_fixture pr 46)
fake_pr 46 merged orch/hand-flow main
fake_pr_head 46 "$(git rev-parse orch/hand-flow)"

fake_online

# A tag named as the main checkout's branch makes git's short branch name
# ambiguous; the report still names the branch as git branch --show-current
# does.
git tag orch/main-flow
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds" "$st" 0
assert_eq "the finished flow side checkout is gone" "$(on_disk "$fl")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$fl"
assert_eq "its flow archived into the main checkout" "$(archived_count "$top" fl-flow)" "1"
assert_eq "its squash-merged local branch is gone" "$(sp_branch orch/fl-flow)" "gone"
assert_eq "the finished quick side checkout is gone" "$(on_disk "$qk")" "absent"
assert_eq "its local branch is gone" "$(sp_branch quick/7-qk)" "gone"
assert_eq "the true-merged side checkout is gone" "$(on_disk "$tm")" "absent"
assert_eq "its merged local branch is gone" "$(sp_branch quick/17-tm)" "gone"
assert_contains "the removals are reported" "$out" "removed side checkout $qk"
assert_eq "an open PR's side checkout stays" "$(on_disk "$op")" "present"
assert_contains "skipped with its reason" "$out" "skipped $op: no merged PR from quick/8-op into main"
assert_eq "a dirty side checkout stays" "$(on_disk "$dt/wip.txt")" "present"
assert_eq "with its branch" "$(sp_branch quick/9-dt)" "kept"
assert_contains "skipped with its reason" "$out" "skipped $dt: uncommitted changes or untracked files"
assert_eq "a flow not at done stays" "$(on_disk "$nd/.orchestrator/state.json")" "present"
assert_contains "skipped with its reason" "$out" "skipped $nd: flow nd-flow is at implement, not done"
assert_eq "a side checkout on no branch stays" "$(on_disk "$nb")" "present"
assert_contains "skipped with its reason" "$out" "skipped $nb: no branch"
assert_contains "a done flow whose PR is open is skipped as open" "$out" "skipped $po: PR #61 is open"
assert_contains "and one whose PR is closed as closed" "$out" "skipped $pc: PR #62 is closed"
assert_eq "the main checkout's finished flow is archived in place" "$(archived_count "$top" main-flow)" "1"
assert_eq "its state is gone" "$(on_disk "$top/.orchestrator/state.json")" "absent"
assert_eq "its branch is still checked out" "$(git branch --show-current)" "orch/main-flow"
assert_contains "which is reported by its full branch name" "$out" "in place - orch/main-flow is still checked out"
assert_eq "the live side checkouts were not moved by that archive" "$(on_disk "$op")" "present"
assert_eq "a hand-made worktree's flow is untouched" "$(on_disk "$hand/.orchestrator/state.json")" "present"
assert_eq "and the worktree stays" "$(on_disk "$hand")" "present"
assert_eq "with its branch" "$(sp_branch orch/hand-flow)" "kept"
assert_contains "reported as left alone" "$out" "$hand: not a side checkout, left alone"
restore_suite_env

# --- side-checkout prune: edge cases (#726) -----------------------------------
# The prune cases that need no checkout of the main section, on a clone of their
# own: each arranges the side checkouts it names.
echo
echo "side-checkout prune edge cases"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
git checkout -q -b orch/main-flow
mkdir -p "$top/.orchestrator/archive"

# A failure after the archive is reported, that checkout stays, and the sweep
# moves on. A locked worktree is one git refuses to remove without force.
fake_offline
lk="$(sc_add lk)"
(cd "$lk" && orch_gh_failing init lk-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/lk-flow && state_fixture pr 47)
sp_branch_off "$lk" orch/lk-flow
fake_pr 47 merged orch/lk-flow main
fake_pr_head 47 "$(git rev-parse orch/lk-flow)"
git worktree lock "$lk"
q2="$(sc_add q2)"
sp_branch_off "$q2" quick/10-q2
fake_pr 48 merged quick/10-q2 main
fake_pr_head 48 "$(git rev-parse quick/10-q2)"
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when a removal fails" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $lk"
assert_eq "the archive stands" "$(archived_count "$top" lk-flow)" "1"
assert_eq "the locked worktree stays" "$(on_disk "$lk")" "present"
assert_eq "with its branch" "$(sp_branch orch/lk-flow)" "kept"
assert_eq "the sweep moves on to the next" "$(on_disk "$q2")" "absent"
git worktree unlock "$lk"

# The whole sweep asks GitHub for the default branch once, however many side
# checkouts it walks and closes: counted at the adapter's stand-in.
fake_offline
c1="$(sc_add c1)"
sp_branch_off "$c1" quick/11-c1
fake_pr 49 merged quick/11-c1 main
fake_pr_head 49 "$(git rev-parse quick/11-c1)"
c2="$(sc_add c2)"
sp_branch_off "$c2" quick/12-c2
fake_pr 50 merged quick/12-c2 main
fake_pr_head 50 "$(git rev-parse quick/12-c2)"
fake_online
pr_reads="$(mktemp)"
fake_default_branch main
out="$(counted_adapter_run "$pr_reads" "$(counting_defs adapter_repo_default_branch branch)" \
  orch_gh_failing side-checkout prune 2>&1)"
assert_eq "prune reaches the default-branch read exactly once" "$(log_count "$pr_reads")" "1"
assert_contains "and still removes the first finished side checkout" "$out" "removed side checkout $c1"
assert_contains "and the second" "$out" "removed side checkout $c2"

# #974: a finished side checkout holding a flow with a ticket worktree under
# it cannot have its flow archived: it is reported and kept with its branch.
fake_offline
tw="$(sc_add tw)"
(cd "$tw" && orch_gh_failing init tw-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/tw-flow && state_fixture pr 49)
sp_branch_off "$tw" orch/tw-flow
fake_pr 49 merged orch/tw-flow main
fake_pr_head 49 "$(git rev-parse orch/tw-flow)"
(cd "$tw" && orch_gh_failing ticket-worktree add 8 >/dev/null)
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when a ticket worktree blocks an archive" "$st" 1
assert_contains "reporting the side checkout as not archived" "$out" \
  "could not archive the flow in side checkout $tw: ticket worktrees are left under $tw"
assert_contains "and left as it stands" "$out" "- left as it stands"
assert_not_contains "with one prefix" "$out" ": orch: "
assert_not_contains "on one line, without the refusal's later lines" "$out" \
  "Remove each with orch.sh ticket-worktree remove"
assert_eq "its flow is not archived" "$(archived_count "$top" tw-flow)" "0"
assert_eq "the side checkout stays" "$(on_disk "$tw/.orchestrator/state.json")" "present"
assert_eq "with its branch" "$(sp_branch orch/tw-flow)" "kept"
(cd "$tw" && orch_gh_failing ticket-worktree remove 8 >/dev/null)
orch_gh_failing side-checkout prune >/dev/null 2>&1

# A branch -D that fails is reported, the sweep exits 1, and the removal and
# archive stand. The flow's recorded branch is one the main checkout holds.
fake_offline
db="$(sc_add db)"
(cd "$db" && orch_gh_failing init db-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/main-flow && state_fixture pr 58)
sp_branch_off "$db" quick/11-db
fake_pr 58 merged orch/main-flow main
fake_pr_head 58 "$(git rev-parse orch/main-flow)"
dd="$(sc_add dd)"
sp_branch_off "$dd" quick/14-dd
fake_pr 63 merged quick/14-dd main
fake_pr_head 63 "$(git rev-parse quick/14-dd)"
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when the branch cannot be deleted" "$st" 1
assert_contains "warning of it" "$out" "could not delete branch orch/main-flow: "
assert_eq "the worktree is removed" "$(on_disk "$db")" "absent"
assert_eq "the branch stays" "$(sp_branch orch/main-flow)" "kept"
assert_eq "the sweep moves on to the next" "$(on_disk "$dd")" "absent"
git branch -q -D quick/11-db

# #1333: an archive that cannot be written stops before the side checkout, its
# state or its branch go. The archive root is the main checkout's.
fake_offline
ab="$(sc_add ab)"
(cd "$ab" && orch_gh_failing init ab-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/ab-flow && state_fixture pr 57)
sp_branch_off "$ab" orch/ab-flow
fake_pr 57 merged orch/ab-flow main
fake_pr_head 57 "$(git rev-parse orch/ab-flow)"
ac="$(sc_add ac)"
sp_branch_off "$ac" quick/12-ac
fake_pr 59 merged quick/12-ac main
fake_pr_head 59 "$(git rev-parse quick/12-ac)"
fake_online
archive_block
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
archive_unblock
assert_status "prune exits 1 when the archive cannot be written" "$st" 1
assert_contains "warning with one prefix, naming the archive path" "$out" \
  "orch: could not archive the flow in side checkout $ab: could not create the archive directory $top/.orchestrator/archive/"
assert_not_contains "and no second prefix" "$out" ": orch: "
assert_eq "the sweep carries on with a flowless one" "$(on_disk "$ac")" "absent"
assert_eq "the side checkout stays" "$(on_disk "$ab")" "present"
assert_eq "with its state" "$(on_disk "$ab/.orchestrator/state.json")" "present"
assert_eq "and its branch" "$(sp_branch orch/ab-flow)" "kept"
orch_gh_failing side-checkout prune >/dev/null 2>&1

# #1718: a main checkout's finished flow whose archive cannot be written is
# warned of with one prefix, and the flow stays.
fake_offline
orch_gh_failing init main-blocked >/dev/null
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 64
fake_pr 64 merged orch/main-flow main
fake_online
archive_block
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
archive_unblock
assert_status "prune exits 1 when the main checkout's archive cannot be written" "$st" 1
assert_contains "warning of it with one prefix" "$out" \
  "orch: could not archive the main checkout's flow: could not create the archive directory $top/.orchestrator/archive/"
assert_not_contains "and no second prefix" "$out" ": orch: "
assert_eq "the main checkout's flow stays" "$(on_disk "$top/.orchestrator/state.json")" "present"
orch_gh_failing side-checkout prune >/dev/null 2>&1

# Each removal reports only its own archive: a flowless side checkout swept
# right after the main checkout's finished flow does not repeat that archive.
fake_offline
orch_gh_failing init main-again >/dev/null
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 51
fake_pr 51 merged orch/main-flow main
q5="$(sc_add q5)"
sp_branch_off "$q5" quick/13-q5
fake_pr 52 merged quick/13-q5 main
fake_pr_head 52 "$(git rev-parse quick/13-q5)"
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds over the main flow and a flowless side checkout" "$st" 0
assert_eq "the flowless side checkout is gone" "$(on_disk "$q5")" "absent"
assert_eq "the main checkout's archive is reported once" \
  "$(printf '%s\n' "$out" | grep -c -- '-main-again$')" "1"

# On a detached main checkout the in-place archive note still prints, with an
# empty branch name, and prune carries on.
fake_offline
orch_gh_failing init main-detached >/dev/null
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 56
fake_pr 56 merged orch/main-flow main
fake_online
git checkout -q --detach
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
git symbolic-ref HEAD refs/heads/orch/main-flow
assert_status "prune succeeds on a detached main checkout" "$st" 0
assert_eq "its finished flow is archived in place" "$(archived_count "$top" main-detached)" "1"
assert_contains "the note still prints, with an empty branch name" "$out" \
  "archived the main checkout's flow in place -  is still checked out"

# A side checkout whose git status cannot run is never called finished: prune
# removes nothing, naming git's error.
fake_offline
q6="$(sc_add q6)"
sp_branch_off "$q6" quick/14-q6
fake_pr 53 merged quick/14-q6 main
fake_pr_head 53 "$(git rev-parse quick/14-q6)"
fake_online
break_index "$q6"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
restore_index "$q6"
assert_status "prune fails when a side checkout's git status cannot run" "$st" 1
assert_contains "naming git's error" "$out" "git status failed - cannot check the working tree: "
assert_contains "and that nothing was removed" "$out" "nothing was removed"
assert_eq "the side checkout stays" "$(on_disk "$q6")" "present"
assert_eq "with its branch" "$(sp_branch quick/14-q6)" "kept"
orch_gh_failing side-checkout prune >/dev/null 2>&1

# A quick implementation is finished by a PR into the base branch off recorded
# for it, not the base in effect now.
git push -q origin main:refs/heads/uat
fake_offline
orch_gh_failing base set uat >/dev/null
rb="$(sc_add rb)"
(cd "$rb" && orch_gh_failing branch off quick/15-rb >/dev/null)
git -C "$rb" commit -q --allow-empty -m "work on rb"
rm2="$(sc_add rm2)"
(cd "$rm2" && orch_gh_failing branch off quick/16-rm2 >/dev/null)
git -C "$rm2" commit -q --allow-empty -m "work on rm2"
orch_gh_failing base set main >/dev/null
fake_pr 54 merged quick/15-rb uat
fake_pr_head 54 "$(git rev-parse quick/15-rb)"
fake_pr 55 merged quick/16-rm2 main
fake_pr_head 55 "$(git rev-parse quick/16-rm2)"
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds after the base setting moved" "$st" 0
assert_eq "a PR merged into the recorded base finishes its side checkout" "$(on_disk "$rb")" "absent"
assert_eq "a PR merged into the base in effect now, not the recorded one, does not" \
  "$(on_disk "$rm2")" "present"
assert_contains "skipped naming the recorded base" "$out" "skipped $rm2: no merged PR from quick/16-rm2 into uat"

# side-checkout add runs the sweep first.
q3="$(sc_add q3)"
sp_branch_off "$q3" quick/11-q3
fake_pr 49 merged quick/11-q3 main
fake_pr_head 49 "$(git rev-parse quick/11-q3)"
out="$(orch_gh_failing side-checkout add after 2>/dev/null)"; st=$?
assert_status "add succeeds after its sweep" "$st" 0
assert_eq "printing only the new path on stdout" "$out" "$top/.orchestrator/checkouts/after"
assert_eq "the sweep removed the finished side checkout" "$(on_disk "$q3")" "absent"
# ... and carries on when the sweep fails.
q4="$(sc_add q4)"
sp_branch_off "$q4" quick/12-q4
fake_pr 50 merged quick/12-q4 main
fake_pr_head 50 "$(git rev-parse quick/12-q4)"
fake_offline
out="$(orch_gh_failing side-checkout add after2 2>&1)"; st=$?
assert_status "add carries on when its sweep fails" "$st" 0
assert_contains "reporting the failed sweep" "$out" "the finished sweep failed"
assert_eq "making the side checkout" "$(on_disk "$top/.orchestrator/checkouts/after2")" "present"
assert_eq "and removing nothing" "$(on_disk "$q4")" "present"
fake_online

out="$(orch_gh_failing side-checkout prune extra 2>&1)"; st=$?
assert_status "prune takes no arguments" "$st" 1
assert_contains "side-checkout prune is in the usage text" "$(orch_gh_failing help)" "side-checkout prune"
assert_contains "the CLI conventions' noun table names prune" \
  "$(grep '^| `side-checkout`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`prune`'
restore_suite_env

# --- archive keeps flow-less directories (#1247) ------------------------------
# A standalone spec review's spec-review/<n>/, a review pass's
# review-pass/<branch>/, the autopilot watcher's autopilot/, the breakdown save
# points under breakdown/ and the saved reports under reports/ belong to no
# flow, so archiving a flow - by any command - leaves them in place; in a side
# checkout being removed they go with the worktree (#1907). Checked through what
# stays under .orchestrator/ and what lands in the archive. Then a scan checks
# every top-level .orchestrator/ entry orch.sh builds is classified as the
# flow's or as belonging to no flow, and fails on one that is neither.
echo
echo "archive keeps flow-less directories"

sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
fake_offline

# fl_seed <root> [side]: gives the flow in the checkout at <root> a handoff, a
# review record, a freely named spec-phase round directory, a flow's spec review
# round directory under spec-rounds/ and its round marker (#1348), and puts a
# standalone spec review's and a review pass's working directories beside it,
# with a breakdown save point and a saved report and, unless <side> is given,
# the autopilot watcher's records (#1907).
fl_seed() {
  local o="$1/.orchestrator"
  mkdir -p "$o/handoff" "$o/review" "$o/round-2" "$o/spec-rounds/1" "$o/spec-review/1244" "$o/review-pass/quick-9-x"
  echo plan >"$o/handoff/01-plan.md"
  echo '40 1 2' >"$o/handoff/spec-round"
  echo changes >"$o/spec-rounds/1/changelog.md"
  echo record >"$o/review/r1.md"
  echo round >"$o/round-2/notes.md"
  echo body >"$o/spec-review/1244/body.md"
  echo report >"$o/review-pass/quick-9-x/pass-1.md"
  mkdir -p "$o/breakdown/1244" "$o/reports"
  echo draft >"$o/breakdown/1244/draft.md"
  echo report >"$o/reports/1244.md"
  [ "${2:-}" = side ] && return 0
  mkdir -p "$o/autopilot/run" "$o/autopilot/logs"
  echo 123 >"$o/autopilot/run/12.pid"
  echo limit >"$o/autopilot/limit"
  echo log >"$o/autopilot/logs/12.log"
}
# fl_kept <label> <root>: every flow-less entry fl_seed wrote is still in place
# under the checkout at <root>, with its files.
fl_kept() {
  assert_eq "$1: spec-review/<n>/ stays in place with its files" \
    "$(on_disk "$2/.orchestrator/spec-review/1244/body.md")" "present"
  assert_eq "$1: review-pass/<branch>/ stays in place with its files" \
    "$(on_disk "$2/.orchestrator/review-pass/quick-9-x/pass-1.md")" "present"
  local f
  for f in autopilot/run/12.pid autopilot/limit autopilot/logs/12.log breakdown/1244/draft.md reports/1244.md; do
    assert_eq "$1: $f stays in place" "$(on_disk "$2/.orchestrator/$f")" "present"
  done
}
# fl_archived <label> <archive-dir>: the flow's own entries landed in
# <archive-dir>, and no flow-less entry did.
fl_archived() {
  local e
  for e in state.json handoff/01-plan.md handoff/spec-round review/r1.md round-2/notes.md spec-rounds/1/changelog.md; do
    assert_eq "$1: the flow's $e is archived" "$(on_disk "$2/$e")" "present"
  done
  assert_eq "$1: no spec-review/ in the archive" "$(on_disk "$2/spec-review")" "absent"
  assert_eq "$1: no review-pass/ in the archive" "$(on_disk "$2/review-pass")" "absent"
  for e in autopilot breakdown reports; do
    assert_eq "$1: no $e/ in the archive" "$(on_disk "$2/$e")" "absent"
  done
}
fl_dest() { find "$top/.orchestrator/archive" -maxdepth 1 -name "*-$1"; }

# archive in the main checkout.
orch_gh_failing init arc-flow >/dev/null
fl_seed "$top"
orch_gh_failing archive >/dev/null; st=$?
assert_status "archive in the main checkout succeeds" "$st" 0
fl_kept "archive" "$top"
fl_archived "archive" "$(fl_dest arc-flow)"
rm -rf "$top/.orchestrator/spec-review" "$top/.orchestrator/review-pass"

# init over a done flow.
orch_gh_failing init old-flow >/dev/null
state_fixture phase "done"
fl_seed "$top"
orch_gh_failing init next-flow >/dev/null; st=$?
assert_status "init over a done flow succeeds" "$st" 0
fl_kept "init" "$top"
fl_archived "init" "$(fl_dest old-flow)"
orch_gh_failing archive >/dev/null
rm -rf "$top/.orchestrator/spec-review" "$top/.orchestrator/review-pass"

# side-checkout remove of a side checkout holding a done flow.
rmv="$(sc_add rmv)"
(cd "$rmv" && orch_gh_failing init rmv-flow >/dev/null && state_fixture phase "done")
fl_seed "$rmv" side
orch_gh_failing side-checkout remove rmv >/dev/null 2>&1; st=$?
assert_status "side-checkout remove succeeds" "$st" 0
fl_archived "remove" "$(fl_dest rmv-flow)"
assert_eq "remove: the worktree, with its flow-less entries, is gone" "$(on_disk "$rmv")" "absent"

# The finished sweep over the main checkout's finished flow - the trigger
# #1247 hit.
fake_online
orch_gh_failing init swp-flow >/dev/null
git checkout -q -b orch/swp-flow
state_fixture phase "done"; state_fixture branch orch/swp-flow; state_fixture pr 71
fake_pr 71 merged orch/swp-flow main
fake_pr_head 71 "$(git rev-parse orch/swp-flow)"
fl_seed "$top"
orch_gh_failing side-checkout prune >/dev/null 2>&1; st=$?
assert_status "the finished sweep succeeds" "$st" 0
assert_eq "prune: the main checkout's flow is archived in place" "$(archived_count "$top" swp-flow)" "1"
fl_kept "prune" "$top"
fl_archived "prune" "$(fl_dest swp-flow)"
restore_suite_env

# --- side-checkout prune: a covered branch tip (#1906) ------------------------
# The sweep's branch -D is safe only when a merged PR holds everything on the
# branch: a side checkout whose local tip is past every merged PR's head (or
# whose head is not in this repo) is kept, worktree and branch, with a note.
echo
echo "side-checkout prune covered tip"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
fake_offline

# stray_commit <message> [parent]: a commit outside every branch, as a merged
# PR's head the local repo holds - a child of the parent, else a root.
stray_commit() {
  if [ -n "${2:-}" ]; then git commit-tree "$2^{tree}" -p "$2" -m "$1"
  else git commit-tree "$(git hash-object -t tree /dev/null)" -m "$1"; fi
}

# The issue's repro: a merged PR, then a follow-up commit never pushed.
up="$(sc_add up)"
sp_branch_off "$up" quick/31-up
fake_pr 81 merged quick/31-up main
fake_pr_head 81 "$(git rev-parse quick/31-up)"
git -C "$up" commit -q --allow-empty -m "local follow-up, unpushed"
up_head="$(git rev-parse quick/31-up~1)"
# The same on a flow at done.
fp="$(sc_add fp)"
(cd "$fp" && orch_gh_failing init fp-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/fp-flow && state_fixture pr 82)
sp_branch_off "$fp" orch/fp-flow
fake_pr 82 merged orch/fp-flow main
fake_pr_head 82 "$(git rev-parse orch/fp-flow)"
git -C "$fp" commit -q --allow-empty -m "local follow-up, unpushed"
# A tip behind the PR's head.
bh="$(sc_add bh)"
sp_branch_off "$bh" quick/32-bh
fake_pr 83 merged quick/32-bh main
fake_pr_head 83 "$(stray_commit "ahead of the tip" "$(git rev-parse quick/32-bh)")"
# A head this repo does not hold.
ms="$(sc_add ms)"
sp_branch_off "$ms" quick/35-ms
fake_pr 84 merged quick/35-ms main
fake_pr_head 84 1111111111111111111111111111111111111111
# Several merged PRs: an older one's head covers the tip, the newest's does not.
mc="$(sc_add mc)"
sp_branch_off "$mc" quick/33-mc
fake_pr 85 merged quick/33-mc main
fake_pr_head 85 "$(git rev-parse quick/33-mc)"
fake_pr 86 merged quick/33-mc main
fake_pr_head 86 "$(stray_commit "unrelated")"
# Several merged PRs, none covering the tip.
mn="$(sc_add mn)"
sp_branch_off "$mn" quick/34-mn
fake_pr 87 merged quick/34-mn main
fake_pr_head 87 "$(stray_commit "first unrelated")"
fake_pr 88 merged quick/34-mn main
fake_pr_head 88 "$(stray_commit "second unrelated")"
mn_head="$(git rev-parse --short=7 "$(cat "$ORCH_GH_FAKE_STORE/prs/88/head_oid")")"
fake_online

out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds" "$st" 0
assert_eq "a flow-less tip past its merged PR keeps the worktree" "$(on_disk "$up")" "present"
assert_eq "and the branch" "$(sp_branch quick/31-up)" "kept"
assert_contains "the uncovered-tip note names the branch, the PR and its head" "$out" \
  "skipped $up: quick/31-up has commits past PR #81's merged head ${up_head:0:7}"
assert_eq "a done flow's tip past its PR keeps the worktree" "$(on_disk "$fp")" "present"
assert_eq "and the branch" "$(sp_branch orch/fp-flow)" "kept"
assert_contains "with the same note" "$out" "skipped $fp: orch/fp-flow has commits past PR #82's merged head"
assert_eq "a tip behind the PR's head is swept" "$(on_disk "$bh")" "absent"
assert_eq "with its branch" "$(sp_branch quick/32-bh)" "gone"
assert_eq "a head missing locally keeps the worktree" "$(on_disk "$ms")" "present"
assert_eq "and the branch" "$(sp_branch quick/35-ms)" "kept"
assert_contains "the missing-head note tells it to fetch" "$out" \
  "skipped $ms: quick/35-ms: PR #84's head 1111111 is not in this repo - fetch it to let the sweep judge"
assert_eq "an older PR's head covering the tip sweeps it" "$(on_disk "$mc")" "absent"
assert_eq "no PR's head covering the tip keeps it" "$(on_disk "$mn")" "present"
assert_contains "the note names the newest PR" "$out" \
  "skipped $mn: quick/34-mn has commits past PR #88's merged head $mn_head"

# side-checkout add: its opening sweep keeps the uncovered one, and adds.
out="$(orch_gh_failing side-checkout add fresh 2>&1)"; st=$?
assert_status "add succeeds" "$st" 0
assert_eq "its opening sweep kept the uncovered side checkout" "$(on_disk "$up")" "present"
assert_eq "and its branch" "$(sp_branch quick/31-up)" "kept"
assert_eq "and the new one exists" "$(on_disk "$top/.orchestrator/checkouts/fresh")" "present"
restore_suite_env

# fl_classify <scripts-dir>: every top-level .orchestrator/<name> the code in
# <scripts-dir> (orch.sh, flow-state.sh and orch/*.sh) builds - as $ORCH/<name>,
# $ORCH_DIR_NAME/<name>, $home/<name>, or a printf format '%s/<name>' or
# '%s/%s/<name>' on a line naming $ORCH or $ORCH_DIR_NAME - against
# FLOW_LESS_ENTRIES plus the flow's own entries. Prints one line per name on
# neither list and per listed name never found, stating the rule; returns 1
# when it printed any.
FL_FLOW_OWN="state.json handoff review scratch spec-rounds worktrees"
fl_classify() {
  local dir="$1" found listed out
  found="$( { grep -hoE '\$\{?(ORCH|ORCH_DIR_NAME|home)\}?/[a-z][a-z.-]*' "$dir/orch.sh" "$dir/flow-state.sh" "$dir"/orch/*.sh | sed -E 's|.*/||'
    grep -hE "printf '%s/(%s/)?[a-z]" "$dir/orch.sh" "$dir/flow-state.sh" "$dir"/orch/*.sh | grep -E '\$\{?ORCH(_DIR_NAME)?([^A-Za-z_]|$)' |
      grep -oE "'%s/(%s/)?[a-z][a-z.-]*" | sed -E "s|.*/||"; } | sort -u)"
  listed="$( { sourced_orch_script 'printf "%s\n" "${FLOW_LESS_ENTRIES[@]}"'; tr ' ' '\n' <<<"$FL_FLOW_OWN"; } | sort -u)"
  out="$(comm -23 <(printf '%s\n' "$found") <(printf '%s\n' "$listed") | sed 's|.*|.orchestrator/& is built by orch.sh but is on neither FLOW_LESS_ENTRIES nor the flow'"'"'s own entries|'
    comm -13 <(printf '%s\n' "$found") <(printf '%s\n' "$listed") | sed 's|.*|listed entry & was never found in the scan|')"
  [ -z "$out" ] && return 0
  printf '%s\nThe rule: an entry a command creates for work that belongs to no flow goes on FLOW_LESS_ENTRIES (scripts/orch/side-checkout.sh); every other entry is the flow'"'"'s and goes on the test'"'"'s list of the flow'"'"'s own entries.\n' "$out"
  return 1
}

out="$(fl_classify "$PLUGIN_ROOT/scripts")"; st=$?
assert_status "every top-level .orchestrator entry orch.sh builds is classified" "$st" 0
assert_eq "the classification scan reports nothing" "$out" ""

fl_fix="$(mktemp -d)"
mkdir -p "$fl_fix/orch"
cp "$PLUGIN_ROOT/scripts/orch.sh" "$PLUGIN_ROOT/scripts/flow-state.sh" "$fl_fix/"
cp "$PLUGIN_ROOT/scripts/orch/"*.sh "$fl_fix/orch/"
echo 'newthing_dir() { printf "%s\n" "$ORCH/brandnew"; }' >>"$fl_fix/orch/ticket.sh"
out="$(fl_classify "$fl_fix")"; st=$?
assert_status "an unclassified entry fails the classification" "$st" 1
assert_contains "the failure names the entry" "$out" ".orchestrator/brandnew"
assert_contains "the failure states the rule" "$out" "The rule: an entry a command creates"
rm -rf "$fl_fix"

# --- side-checkout prune: fork PRs are not proof (#1979) ----------------------
# A merged PR whose head lives in a fork, from a branch named as the side
# checkout's, is not proof the side checkout is finished.
echo
echo "side-checkout prune fork PRs"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
fake_offline
fk="$(sc_add fk)"
sp_branch_off "$fk" quick/41-fk
fake_pr 91 merged quick/41-fk main
fake_pr_head 91 "$(git rev-parse quick/41-fk)"
fake_pr_cross 91
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds" "$st" 0
assert_eq "a side checkout with only a merged fork PR stays" "$(on_disk "$fk")" "present"
assert_eq "with its branch" "$(sp_branch quick/41-fk)" "kept"
assert_contains "skipped as having no merged PR" "$out" "skipped $fk: no merged PR from quick/41-fk into main"
assert_contains "and the fork PR is reported as ignored" "$out" "ignored 1 PR(s) from forks"

# A same-repo merged PR finishes it (the fork PR above, now same-repo,
# finishes its own).
fake_offline
rm "$ORCH_GH_FAKE_STORE/prs/91/cross_repository"
sm="$(sc_add sm)"
sp_branch_off "$sm" quick/42-sm
fake_pr 92 merged quick/42-sm main
fake_pr_head 92 "$(git rev-parse quick/42-sm)"
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_eq "a same-repo merged PR finishes its side checkout" "$(on_disk "$sm")" "absent"

# A flag that is neither true nor false cannot be read.
fake_offline
bf="$(sc_add bf)"
sp_branch_off "$bf" quick/43-bf
fake_pr 93 merged quick/43-bf main
fake_pr_head 93 "$(git rev-parse quick/43-bf)"
fake_pr_cross 93 maybe
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune fails on an unreadable flag" "$st" 1
assert_contains "with the could-not-read verdict" "$out" "could not check $bf: could not read GitHub"
assert_eq "the side checkout stays" "$(on_disk "$bf")" "present"
assert_eq "with its branch" "$(sp_branch quick/43-bf)" "kept"

# --- side-checkout prune: the merged-PR close backstop (#2477) ----------------
# A finished checkout whose merged PR GitHub left its open issue behind gets the
# issue closed before the checkout goes: a flow at done through its recorded
# issue and PR, a flow-less quick branch through its newest merged PR.
echo
echo "side-checkout prune merged-PR close"
sc_clone
fake_github
top="$(git rev-parse --show-toplevel)"
fake_offline

# bf_flow <name> <issue> <pr>: a finished flow side checkout.
bf_flow() {
  local p
  p="$(sc_add "$1")"
  (cd "$p" && orch_gh_failing init "$1-flow" >/dev/null \
    && state_fixture phase "done" && state_fixture branch "orch/$1-flow" \
    && state_fixture pr "$3" && state_fixture issue "$2")
  sp_branch_off "$p" "orch/$1-flow"
  fake_pr "$3" merged "orch/$1-flow" main
  fake_pr_head "$3" "$(git rev-parse "orch/$1-flow")"
  fake_issue "$2" open orch:done
}
# bf_quick <name> <issue> <pr>: a finished flow-less quick side checkout.
bf_quick() {
  local p
  p="$(sc_add "$1")"
  sp_branch_off "$p" "quick/$2-$1"
  fake_pr "$3" merged "quick/$2-$1" main
  fake_pr_head "$3" "$(git rev-parse "quick/$2-$1")"
  fake_issue "$2" open
}

bf_flow ff 601 701; fake_pr_merged 701 3600 601
bf_quick fq 602 702; fake_pr_merged 702 3600 602
bf_quick fg 603 703; fake_pr_merged 703 60 603
bf_flow fb 604 704; fake_pr_merged 704 3600 604
fake_issue 604 closed orch:done
bf_quick fn 609 709; fake_pr_merged 709 3600 99
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds over the missed closes" "$st" 0
assert_eq "a finished flow's open issue is closed" "$(fake_state_of 601)" "CLOSED"
assert_contains "with a comment naming the recorded PR" "$(fake_comments_of 601)" 'PR #701 merged into `main` with `Closes #601`'
assert_eq "the flow's checkout is still removed" "$(on_disk "$(dirname "$top")/ff")" "absent"
assert_eq "a flow-less quick branch's open issue is closed" "$(fake_state_of 602)" "CLOSED"
assert_contains "with a comment naming its newest merged PR" "$(fake_comments_of 602)" "PR #702 merged"
assert_eq "an issue whose PR merged a minute ago stays open" "$(fake_state_of 603)" "OPEN"
assert_contains "with a warning naming the issue and the PR" "$out" "issue #603 is still open: PR #703 merged less than 5 minutes ago"
assert_eq "the checkout inside the grace period is still removed" "$(sp_branch quick/603-fg)" "gone"
assert_eq "an already-closed issue gets no close comment" "$(fake_comments_of 604)" ""
assert_eq "closing references lacking the issue leave it open" "$(fake_state_of 609)" "OPEN"

# A flow-less checkout on a branch that is not quick/<issue>- is skipped.
fake_offline
ot="$(sc_add ot)"
sp_branch_off "$ot" feature/ot
fake_pr 705 merged feature/ot main
fake_pr_head 705 "$(git rev-parse feature/ot)"
fake_pr_merged 705 3600 605
fake_issue 605 open
fake_online
orch_gh_failing side-checkout prune >/dev/null 2>&1
assert_eq "a flow-less checkout on another branch closes nothing" "$(fake_state_of 605)" "OPEN"

# The main checkout's finished flow, archived in place, gets the backstop.
orch_gh_failing init bm-flow >/dev/null
state_fixture phase "done"; state_fixture branch orch/bm-flow; state_fixture pr 706; state_fixture issue 606
fake_pr 706 merged orch/bm-flow main
fake_pr_merged 706 3600 606
fake_issue 606 open orch:done
orch_gh_failing side-checkout prune >/dev/null 2>&1
assert_eq "the main checkout's finished flow closes its issue" "$(fake_state_of 606)" "CLOSED"

# A failed close warns and never blocks the removal.
fake_offline
bf_quick fc 607 707; fake_pr_merged 707 3600 607
fake_online
fake_fail adapter_issue_close "HTTP 500"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "a failed close does not fail prune" "$st" 0
assert_eq "the checkout is still removed" "$(sp_branch quick/607-fc)" "gone"
fake_unfail

# A failed read of the merged PRs warns and never blocks the removal.
fake_offline
bf_quick fr 608 708; fake_pr_merged 708 3600 608
fake_online
fake_fail adapter_prs_merged_closing "HTTP 502"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "a failed merged-PR read does not fail prune" "$st" 0
assert_contains "it warns with gh's reason" "$out" "could not read the merged PRs: HTTP 502"
assert_eq "the issue stays open" "$(fake_state_of 608)" "OPEN"
assert_eq "the checkout is still removed" "$(sp_branch quick/608-fr)" "gone"
fake_unfail

# A side checkout whose state.json is truncated is skipped: the backstop
# returns 0, prints nothing and reads nothing from GitHub.
fake_offline
bf_flow ft 610 710; fake_pr_merged 710 3600 610
ft="$(git worktree list --porcelain | sed -n "s/^worktree //p" | grep "/ft\$")"
(cd "$ft" && state_truncate 10)
fake_online
out="$(bash -c 'source "$1"; shift; side_checkout_close_missed "$@"' _ "$ORCH" "$ft" orch/ft-flow 2>&1)"; st=$?
assert_status "the close backstop on a truncated state.json returns 0" "$st" 0
assert_eq "it prints nothing" "$out" ""
assert_eq "it reads no issue from GitHub, so the open issue is left alone" "$(fake_state_of 610)" "OPEN"

# --- side_checkout_marker reads the worktree's git pointer --------------------
# The marker lookup reads <path>/.git instead of starting git: a main
# worktree's git folder, or the folder a linked worktree's pointer names,
# absolute or relative. A pointer it cannot read asks git.
echo
echo "side_checkout_marker"
healthy_repo
mtop="$PWD"
mlink="$(mktemp -d)/link"
git worktree add -q "$mlink" -b mk-link
mrel="$(mktemp -d)/rel"
git worktree add -q "$mrel" -b mk-rel
mgd="$(git -C "$mlink" rev-parse --absolute-git-dir)"
mrgd="$(git -C "$mrel" rev-parse --absolute-git-dir)"
: >"$mgd/orchestrator-side-checkout"
: >"$mrgd/orchestrator-side-checkout"
: >"$mtop/.git/orchestrator-side-checkout"
mrel_ptr="$(realpath --relative-to="$mrel" "$mrgd")"
printf 'gitdir: %s\n' "$mrel_ptr" >"$mrel/.git"
mplain="$(mktemp -d)/plain"
git worktree add -q "$mplain" -b mk-plain
mnone="$(mktemp -d)"

nogit="$(mktemp -d)"  # an empty PATH directory: no git, no cat, nothing
# One source of orch.sh prints seven lines: the marker of the main, linked
# absolute and linked relative worktrees, the status of the unmarked and the
# non-worktree path, then (PATH emptied) the marker of the main and linked ones.
mapfile -t mk < <(sourced_orch_script '
  printf "%s\n" "$(side_checkout_marker "$1")" "$(side_checkout_marker "$2")" "$(side_checkout_marker "$3")"
  st=0; side_checkout_marker "$4" >/dev/null || st=$?; printf "%s\n" "$st"
  st=0; side_checkout_marker "$5" >/dev/null || st=$?; printf "%s\n" "$st"
  PATH="$6"
  printf "%s\n" "$(side_checkout_marker "$1")" "$(side_checkout_marker "$2")"' \
  "$mtop" "$mlink" "$mrel" "$mplain" "$mnone" "$nogit")
assert_eq "a main worktree's marker" "${mk[0]}" "$mtop/.git/orchestrator-side-checkout"
assert_eq "a linked worktree, pointer absolute" "${mk[1]}" "$mgd/orchestrator-side-checkout"
assert_eq "a linked worktree, pointer relative" "${mk[2]}" "$mrgd/orchestrator-side-checkout"
assert_status "a worktree with no marker" "${mk[3]}" 1
assert_ne "a path that is no worktree" "${mk[4]}" 0
assert_eq "bare PATH, a main worktree" "${mk[5]}" "$mtop/.git/orchestrator-side-checkout"
assert_eq "bare PATH, a linked worktree" "${mk[6]}" "$mgd/orchestrator-side-checkout"

# An unreadable pointer asks git, seen through a counting wrapper.
mwrap="$(counting_bin git)"
mlog="$mwrap/git.log"
mark_counted() { bash -c 'source "$1"; PATH="$2:$PATH"; side_checkout_marker "$3"' _ "$ORCH" "$mwrap" "$1" >/dev/null; }
mptr="$(<"$mlink/.git")"
rm "$mlink/.git"; mkdir "$mlink/.git"
: >"$mlog"
mark_counted "$mlink"
assert_ne "a pointer that is a HEAD-less directory asks git" "$(counting_starts "$mwrap" git)" "0"
rmdir "$mlink/.git"
printf 'not a pointer\n' >"$mlink/.git"
: >"$mlog"
mark_counted "$mlink"
assert_ne "a pointer file with no gitdir line asks git" "$(counting_starts "$mwrap" git)" "0"
chmod 000 "$mlink/.git"
: >"$mlog"
if [ -r "$mlink/.git" ]; then
  skip "a pointer file that cannot be read asks git" "permissions do not bite here, e.g. root"
else
  mark_counted "$mlink"
  assert_ne "a pointer file that cannot be read asks git" "$(counting_starts "$mwrap" git)" "0"
fi
chmod 644 "$mlink/.git"
printf '%s\n' "$mptr" >"$mlink/.git"
restore_suite_env
