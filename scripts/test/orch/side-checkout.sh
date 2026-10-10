# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# archived_count <top> <slug>: how many archive directories for <slug> the main
# checkout at <top> holds.
archived_count() { find "$1/.orchestrator/archive" -maxdepth 1 -name "*-$2" 2>/dev/null | wc -l | tr -d ' '; }

# --- side-checkout (#722) ------------------------------------------------------
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

worktrees_before="$(git worktree list | wc -l | tr -d ' ')"
for bad in "" "12a" "#5"; do
  if [ -z "$bad" ]; then out="$(orch_gh_failing side-checkout add badissue --issue 2>&1)"; st=$?
  else out="$(orch_gh_failing side-checkout add badissue --issue "$bad" 2>&1)"; st=$?; fi
  assert_status "add refuses --issue '$bad'" "$st" 1
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

# --- status lists every checkout (#725) ----------------------------------------
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
restore_suite_env

# --- side-checkout archive and remove (#724) -----------------------------------
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
complete_plan_handoff "$(cd "$alpha" && orch_gh_failing handoff path spec)"
out="$(cd "$alpha" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a clean side checkout succeeds" "$st" 0
assert_eq "it leaves the archive in the main checkout's .orchestrator/archive/" \
  "$(archived_count "$top" alpha-flow)" "1"
assert_eq "with the flow's handoffs in it" \
  "$(on_disk "$(find "$top/.orchestrator/archive" -maxdepth 1 -name '*-alpha-flow')/handoff/01-plan.md")" "present"
assert_contains "it prints the archive's full path" "$out" "$top/.orchestrator/archive/"
assert_eq "the worktree is gone from disk" "$(on_disk "$alpha")" "absent"
assert_not_contains "and from git's list" "$(git worktree list)" "$alpha"
assert_contains "it tells the human to close the session" "$out" "close this session"

# archive in a dirty side checkout: the archive succeeds, the worktree stays.
beta="$(sc_add beta)"
(cd "$beta" && orch_gh_failing init beta-flow >/dev/null)
echo wip >"$beta/wip.txt"
out="$(cd "$beta" && orch_gh_failing archive 2>&1)"; st=$?
assert_status "archive in a dirty side checkout succeeds" "$st" 0
assert_eq "it archives into the main checkout" "$(archived_count "$top" beta-flow)" "1"
assert_eq "and leaves the worktree in place" "$(on_disk "$beta/wip.txt")" "present"
assert_contains "reporting why it was kept" "$out" "kept side checkout $beta"
assert_contains "naming the remove command" "$out" "side-checkout remove beta"
assert_not_contains "and never tells the human to close the session" "$out" "close this session"
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
echo changed >>"$gamma/$(git -C "$gamma" ls-files | head -1)"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
assert_status "remove refuses uncommitted changes" "$st" 1
assert_contains "saying so" "$out" \
  "orch: side checkout $gamma has uncommitted changes or untracked files - commit or discard them first; it is never removed with force"
assert_eq "its flow is not moved" "$(archived_count "$top" new-flow)" "0"
git -C "$gamma" checkout -q -- .
# A git status that cannot run is a refusal naming git's error, never a clean
# tree.
gidx="$(git -C "$gamma" rev-parse --absolute-git-dir)/index"
cp "$gidx" "$gidx.bak"
printf 'garbage' >"$gidx"
out="$(orch_gh_failing side-checkout remove gamma 2>&1)"; st=$?
mv "$gidx.bak" "$gidx"
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
assert_not_contains "run from the main checkout, no close-the-session message" "$out" "close this session"

# remove of a side checkout holding no flow, run from inside it.
delta="$(sc_add delta)"
out="$(cd "$delta" && orch_gh_failing side-checkout remove delta 2>&1)"; st=$?
assert_status "remove from inside the side checkout succeeds" "$st" 0
assert_eq "the worktree is gone" "$(on_disk "$delta")" "absent"
assert_contains "and the session is told to close" "$out" "close this session"

# A failing git worktree remove: the archive stands, and remove exits 1. A
# locked worktree is one git refuses to remove without force.
eps="$(sc_add eps)"
(cd "$eps" && orch_gh_failing init eps-flow >/dev/null)
git worktree lock "$eps"
out="$(orch_gh_failing side-checkout remove eps 2>&1)"; st=$?
assert_status "remove exits 1 when the worktree cannot be removed" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $eps"
assert_eq "the archive stands" "$(archived_count "$top" eps-flow)" "1"
assert_eq "the worktree stays" "$(on_disk "$eps")" "present"
git worktree unlock "$eps"

out="$(orch_gh_failing side-checkout remove 2>&1)"; st=$?
assert_status "remove refuses a missing slug" "$st" 1
assert_contains "side-checkout remove is in the usage text" "$(orch_gh_failing help)" "side-checkout remove <slug>"
restore_suite_env

# --- side-checkout prune (#726) -----------------------------------------------
# The finished sweep behind /orchestrator:finish: a side checkout whose PR
# GitHub reports merged into its base, whose tree is clean, and whose flow -
# if any - is at done, is archived into the main checkout, removed, and its
# local branch deleted. Checked through the worktrees, branches and archives
# left on disk, and the report, against the store-backed GitHub fake.
echo
echo "side-checkout prune"
sp_branch() { if git rev-parse --verify --quiet "refs/heads/$1" >/dev/null; then echo kept; else echo gone; fi; }
# sp_branch_off <path> <branch>: puts the side checkout at <path> on a new
# branch with one commit of its own, never merged into main locally - as a
# squash merge on GitHub leaves it.
sp_branch_off() {
  git -C "$1" checkout -q -b "$2"
  git -C "$1" commit -q --allow-empty -m "work on $2"
}

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
# A finished quick-implementation side checkout.
qk="$(sc_add qk)"
sp_branch_off "$qk" quick/7-qk
fake_pr 42 merged quick/7-qk main
# An open PR.
op="$(sc_add op)"
sp_branch_off "$op" quick/8-op
fake_pr 43 open quick/8-op main
# A dirty tree, its PR merged.
dt="$(sc_add dt)"
sp_branch_off "$dt" quick/9-dt
fake_pr 44 merged quick/9-dt main
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
# The main checkout's own finished flow.
orch_gh_failing init main-flow >/dev/null
git checkout -q -b orch/main-flow
state_fixture phase "done"; state_fixture branch orch/main-flow; state_fixture pr 45
fake_pr 45 merged orch/main-flow main
# A hand-made worktree holding a finished flow.
hand="$(mktemp -d)/hand"
git worktree add -q -b orch/hand-flow "$hand" main
(cd "$hand" && orch_gh_failing init hand-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/hand-flow && state_fixture pr 46)
fake_pr 46 merged orch/hand-flow main

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
fake_unfail

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
assert_contains "which is reported" "$out" "orch/main-flow is still checked out"
assert_eq "the live side checkouts were not moved by that archive" "$(on_disk "$op")" "present"
assert_eq "a hand-made worktree's flow is untouched" "$(on_disk "$hand/.orchestrator/state.json")" "present"
assert_eq "and the worktree stays" "$(on_disk "$hand")" "present"
assert_eq "with its branch" "$(sp_branch orch/hand-flow)" "kept"
assert_contains "reported as left alone" "$out" "$hand: not a side checkout, left alone"

# A failure after the archive is reported, that checkout stays, and the sweep
# moves on. A locked worktree is one git refuses to remove without force.
fake_offline
lk="$(sc_add lk)"
(cd "$lk" && orch_gh_failing init lk-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/lk-flow && state_fixture pr 47)
sp_branch_off "$lk" orch/lk-flow
fake_pr 47 merged orch/lk-flow main
git worktree lock "$lk"
q2="$(sc_add q2)"
sp_branch_off "$q2" quick/10-q2
fake_pr 48 merged quick/10-q2 main
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when a removal fails" "$st" 1
assert_contains "reporting the failure" "$out" "could not remove side checkout $lk"
assert_eq "the archive stands" "$(archived_count "$top" lk-flow)" "1"
assert_eq "the locked worktree stays" "$(on_disk "$lk")" "present"
assert_eq "with its branch" "$(sp_branch orch/lk-flow)" "kept"
assert_eq "the sweep moves on to the next" "$(on_disk "$q2")" "absent"
git worktree unlock "$lk"

# #974: a finished side checkout holding a flow with a ticket worktree under
# it cannot have its flow archived: it is reported and kept with its branch.
fake_offline
tw="$(sc_add tw)"
(cd "$tw" && orch_gh_failing init tw-flow >/dev/null \
  && state_fixture phase "done" && state_fixture branch orch/tw-flow && state_fixture pr 49)
sp_branch_off "$tw" orch/tw-flow
fake_pr 49 merged orch/tw-flow main
(cd "$tw" && orch_gh_failing ticket-worktree add 8 >/dev/null)
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune exits 1 when a ticket worktree blocks an archive" "$st" 1
assert_contains "reporting the side checkout as not archived" "$out" \
  "could not archive the flow in side checkout $tw: "
assert_contains "and left as it stands" "$out" "- left as it stands"
assert_eq "its flow is not archived" "$(archived_count "$top" tw-flow)" "0"
assert_eq "the side checkout stays" "$(on_disk "$tw/.orchestrator/state.json")" "present"
assert_eq "with its branch" "$(sp_branch orch/tw-flow)" "kept"
(cd "$tw" && orch_gh_failing ticket-worktree remove 8 >/dev/null)
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
fake_online
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
assert_status "prune succeeds over the main flow and a flowless side checkout" "$st" 0
assert_eq "the flowless side checkout is gone" "$(on_disk "$q5")" "absent"
assert_eq "the main checkout's archive is reported once" \
  "$(printf '%s\n' "$out" | grep -c -- '-main-again$')" "1"

# A side checkout whose git status cannot run is never called finished: prune
# removes nothing, naming git's error.
fake_offline
q6="$(sc_add q6)"
sp_branch_off "$q6" quick/14-q6
fake_pr 53 merged quick/14-q6 main
fake_online
q6idx="$(git -C "$q6" rev-parse --absolute-git-dir)/index"
cp "$q6idx" "$q6idx.bak"
printf 'garbage' >"$q6idx"
out="$(orch_gh_failing side-checkout prune 2>&1)"; st=$?
mv "$q6idx.bak" "$q6idx"
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
fake_pr 55 merged quick/16-rm2 main
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
out="$(orch_gh_failing side-checkout add after 2>/dev/null)"; st=$?
assert_status "add succeeds after its sweep" "$st" 0
assert_eq "printing only the new path on stdout" "$out" "$top/.orchestrator/checkouts/after"
assert_eq "the sweep removed the finished side checkout" "$(on_disk "$q3")" "absent"
# ... and carries on when the sweep fails.
q4="$(sc_add q4)"
sp_branch_off "$q4" quick/12-q4
fake_pr 50 merged quick/12-q4 main
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
