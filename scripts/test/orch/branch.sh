# --- branch create -----------------------------------------------------------
# Unlike branch off's caller-named branch, this one derives its own name from
# state - slug plus the recorded issue - and records both `branch` and
# `base_sha` for pr open and redo review to read back later via require_branch.
# Like branch off, it also records the base and base SHA in the branch's git
# config, so branch sync and branch base-sha find them once the flow is gone.
echo
echo "branch create"
new_repo_with_origin
orch_gh_failing init bcreate >/dev/null
orch_gh_failing state set issue 11
before_sha="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch create)"
assert_eq "derives the branch name from slug and the recorded issue" "$out" "orch/11-bcreate"
assert_eq "checks the new branch out" "$(git branch --show-current)" "orch/11-bcreate"
assert_eq "records the branch in state" "$(orch_gh_failing state get branch)" "orch/11-bcreate"
assert_eq "records the fork point as base_sha" "$(orch_gh_failing state get base_sha)" "$before_sha"
assert_eq "records the flow's base in the branch's git config" \
  "$(git config --get branch.orch/11-bcreate.orchestrator-base)" "$(orch_gh_failing state get base)"
assert_eq "and the fork point as its base SHA there" \
  "$(git config --get branch.orch/11-bcreate.orchestrator-base-sha)" "$before_sha"

# --- branch off --------------------------------------------------------------
# A quick implementation keeps no state, so this is the primitive it shares
# with a flow's own branch create: same fetch/checkout-fallback idiom, naming
# and recording left entirely to the caller.
echo
echo "branch off"
# default-branch resolves through git symbolic-ref as a fallback - give the
# repo one rather than letting the answer depend on this machine's git
# init.defaultBranch.
new_repo_with_origin
out="$(orch_gh_failing branch off "quick/9-widgets")"
assert_eq "prints the branch it made" "$out" "quick/9-widgets"
assert_eq "checks it out" "$(git branch --show-current)" "quick/9-widgets"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

out="$(orch_gh_failing branch off "quick/9-widgets" 2>&1)"; st=$?
assert_status "refuses a name that already exists" "$st" 1
assert_contains "names the branch" "$out" "quick/9-widgets already exists"

out="$(orch_gh_failing branch off 2>&1)"; st=$?
assert_status "refuses with no name" "$st" 1

# #720: a quick implementation must never move an active flow's checkout off
# its branch, so branch off refuses beside a flow mid-pipeline exactly as init
# does - same exit code 3, same message - and checks nothing out.
for phase in spec implement review; do
  new_repo_with_origin
  orch_gh_failing init busy >/dev/null
  state_fixture phase "$phase"
  before="$(git branch --show-current)"
  out="$(orch_gh_failing branch off quick/4-beside 2>&1)"; st=$?
  assert_status "refuses beside a flow at $phase with exit 3" "$st" 3
  assert_contains "with init's message ($phase)" "$out" "a flow is already active (slug: busy, phase: $phase)."
  assert_contains "and init's remedy ($phase)" "$out" "One flow at a time"
  assert_eq "checks nothing out ($phase)" "$(git branch --show-current)" "$before"
  assert_eq "creates no branch ($phase)" \
    "$(git rev-parse --verify --quiet refs/heads/quick/4-beside >/dev/null && echo made || echo none)" "none"
done

new_repo_with_origin
orch_gh_failing init finished >/dev/null
state_fixture phase "done"
out="$(orch_gh_failing branch off quick/4-after)"; st=$?
assert_status "a done flow does not block branch off" "$st" 0
assert_eq "which checks the branch out as before" "$(git branch --show-current)" "quick/4-after"

# --- a quick implementation's base branch --------------------------------------
# A quick implementation keeps no state.json, so branch off records the base
# branch it forked from on the branch itself - pr publish then targets that
# base even if the setting moved in the meantime, and falls back to the setting
# for a branch created before anything was recorded.
echo
echo "a quick implementation's base branch"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b uat
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git checkout -q -
git branch -q -D uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
uat_tip="$(git rev-parse origin/uat)"
main_tip="$(git rev-parse origin/main)"
recorded_base() { git config --get "branch.$1.orchestrator-base" || echo "<unset>"; }

orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing branch off quick/5-uat 2>&1)"; st=$?
assert_status "branch off succeeds" "$st" 0
assert_eq "branch off forks from the base branch in effect" "$(git rev-parse HEAD)" "$uat_tip"
assert_eq "and records it on the branch" "$(recorded_base quick/5-uat)" "uat"

git checkout -q main
orch_gh_failing base clear >/dev/null
orch_gh_failing branch off quick/6-main >/dev/null
assert_eq "with nothing set, branch off forks from the default branch" "$(git rev-parse HEAD)" "$main_tip"
assert_eq "and records the default branch" "$(recorded_base quick/6-main)" "main"

body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
git checkout -q quick/5-uat
fake_github
fake_next_pr 41
out="$(orch_gh_failing pr publish 5 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish succeeds" "$st" 0
assert_eq "pr publish targets the recorded base over the changed setting" \
  "$(fake_pr_base_of 41)" "uat"
assert_first_line "a quick PR into a non-default base refers to its issue" \
  "$(fake_pr_body_of 41)" "Refs #5"

# A branch made before branch off recorded anything publishes to the setting.
git checkout -q -b quick/7-legacy "$main_tip"
orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing pr publish 7 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish succeeds with nothing recorded" "$st" 0
assert_eq "and falls back to the base branch setting" "$(fake_pr_base_of "$out")" "uat"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# A deleted base branch must not quietly become a fork from a stale local copy.
git update-ref refs/remotes/origin/gone "$main_tip"
git config orchestrator.base gone
out="$(orch_gh_failing branch off quick/8-gone 2>&1)"; st=$?
assert_status "branch off refuses a base branch origin says is gone" "$st" 1
assert_contains "naming the base branch" "$out" \
  "base branch gone does not exist on origin - push it, or start again on another base branch"
assert_not_contains "never pointing at a flow's correction" "$out" "--flow"
assert_eq "and records nothing for the branch it did not make" "$(recorded_base quick/8-gone)" "<unset>"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"

# --- a quick implementation's base SHA (#243) ---------------------------------
# branch off records the base branch's tip at the moment of branching, the same
# meaning a flow's base_sha has, so a quick implementation's reviewers get a
# fixed point that a later merge of the base cannot shrink. A branch made before
# that was recorded falls back to the merge-base with its base branch.
echo
echo "a quick implementation's base SHA (#243)"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
branched_tip="$(git rev-parse origin/main)"
orch_gh_failing branch off quick/1-sha >/dev/null
assert_eq "branch off records the base branch's tip as the base SHA" \
  "$(git config --get branch.quick/1-sha.orchestrator-base-sha)" "$branched_tip"
git commit -q --allow-empty -m "work on the branch"

# The base branch moves on and the branch merges it in.
git checkout -q -b advance "$branched_tip"
git commit -q --allow-empty -m "main moves on"
git push -q origin advance:refs/heads/main
git fetch -q origin
moved_tip="$(git rev-parse origin/main)"
git checkout -q quick/1-sha
git branch -q -D advance
git merge -q --no-edit origin/main
assert_eq "the recorded base SHA is unchanged after the base branch moves on" \
  "$(git config --get branch.quick/1-sha.orchestrator-base-sha)" "$branched_tip"
out="$(orch_gh_failing branch base-sha 2>&1)"; st=$?
assert_status "branch base-sha succeeds" "$st" 0
assert_eq "branch base-sha prints the recorded base SHA" "$out" "$branched_tip"

git config --unset branch.quick/1-sha.orchestrator-base-sha
assert_eq "without a recorded SHA it prints the merge-base with the base branch" \
  "$(orch_gh_failing branch base-sha)" "$(git merge-base HEAD origin/main)"
assert_eq "which here is the base branch's tip it merged" "$(orch_gh_failing branch base-sha)" "$moved_tip"

# No remote-tracking ref for the recorded base branch: the local one answers.
git branch -q localbase "$branched_tip"
git config branch.quick/1-sha.orchestrator-base localbase
assert_eq "with no remote-tracking ref it uses the local base branch" \
  "$(orch_gh_failing branch base-sha)" "$branched_tip"

# Neither key: the base branch in effect, as pr publish does.
git checkout -q -b uat "$branched_tip"
git commit -q --allow-empty -m "uat only"
git push -q origin uat:refs/heads/uat
git fetch -q origin
uat_tip="$(git rev-parse origin/uat)"
git checkout -q -b quick/2-legacy uat
git commit -q --allow-empty -m "legacy work"
git config orchestrator.base uat
assert_eq "with neither key it uses the base branch setting" \
  "$(orch_gh_failing branch base-sha)" "$uat_tip"
git config --unset orchestrator.base
assert_eq "and the default branch when nothing is set" \
  "$(orch_gh_failing branch base-sha)" "$branched_tip"

git checkout -q --detach
out="$(orch_gh_failing branch base-sha 2>&1)"; st=$?
assert_status "refuses a detached HEAD" "$st" 1
assert_contains "saying so" "$out" "detached HEAD"
out="$(orch_gh_failing branch base-sha extra 2>&1)"; st=$?
assert_status "refuses arguments" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh branch base-sha"
assert_contains "help documents branch base-sha" "$("$ORCH" help)" "branch base-sha"
rm -rf "$(dirname "$bare")"

# --- branch retire ------------------------------------------------------------
# The rename-aside a redo uses instead of deleting or force-pushing over a
# discarded attempt's commits. The push/delete-remote-ref assertions reuse the
# bare-repo-as-origin fixture branch create and pr open already use.
echo
echo "branch retire"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main

out="$(orch_gh_failing branch retire nosuchbranch new 2>&1)"; st=$?
assert_status "refuses a branch that does not exist" "$st" 1
assert_contains "naming it" "$out" "nosuchbranch does not exist"

git branch old-attempt
git branch taken
out="$(orch_gh_failing branch retire old-attempt taken 2>&1)"; st=$?
assert_status "refuses a destination name already in use" "$st" 1
assert_contains "naming it" "$out" "taken already exists"
git branch -d taken

out="$(orch_gh_failing branch retire old-attempt old-attempt-redo-1 2>&1)"; st=$?
assert_status "renames a branch with no upstream" "$st" 0
assert_eq "prints the new name" "$out" "old-attempt-redo-1"
assert_eq "the old name is gone locally" \
  "$(git rev-parse --verify --quiet old-attempt >/dev/null 2>&1 && echo present || echo gone)" "gone"
assert_eq "the new name exists" \
  "$(git rev-parse --verify --quiet old-attempt-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"

git checkout -q -b to-retire
git push -q -u origin to-retire
out="$(orch_gh_failing branch retire to-retire to-retire-redo-1 2>&1)"; st=$?
assert_status "renames and republishes a branch with an upstream" "$st" 0
assert_eq "prints the new name" "$out" "to-retire-redo-1"
assert_eq "pushes the new name to origin" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire-redo-1 >/dev/null && echo present || echo gone)" "present"
# Not optional: a leftover ref under the un-suffixed name is exactly what the
# next implement attempt's branch create/pr open would collide with.
assert_eq "and deletes the old remote ref" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/to-retire >/dev/null && echo present || echo gone)" "gone"

# The fixture gap named in spec review: no test in the suite forces a real
# `git push` to fail, since the gh-stub exit overrides only apply to gh.
# Pointing origin at a path removed out from under it does.
git checkout -q -b to-fail
git push -q -u origin to-fail
rm -rf "$bare"
out="$(orch_gh_failing branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "dies when the push to origin fails" "$st" 1
assert_contains "with a clear reason" "$out" "could not push"
# The local rename happens before the push is even attempted - issue #63:
# without a rollback, a push failure leaves `old` gone locally with nothing
# a retry could find, even though nothing was ever published.
assert_eq "rolls the local rename back so the old name still exists" \
  "$(git rev-parse --verify --quiet to-fail >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and the new name is not left dangling in its place" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "gone"

# Retrying with the same old/new names must succeed once whatever blocked
# the push clears - issue #63 acceptance criterion 1.
bare2="$(mktemp -d)/origin.git"
git init -q --bare "$bare2"
bare_origin "$bare2"
out="$(orch_gh_failing branch retire to-fail to-fail-redo-1 2>&1)"; st=$?
assert_status "retrying the same rename succeeds once origin is reachable again" "$st" 0
assert_eq "prints the new name" "$out" "to-fail-redo-1"
assert_eq "renames locally" \
  "$(git rev-parse --verify --quiet to-fail-redo-1 >/dev/null 2>&1 && echo present || echo gone)" "present"
assert_eq "and publishes it" \
  "$(git -C "$bare2" rev-parse --quiet --verify refs/heads/to-fail-redo-1 >/dev/null && echo present || echo gone)" "present"

# Idempotent resume: a previous call whose local rename and remote push both
# already succeeded, but whose remote delete of the old ref did not - the
# "Key interfaces" note in issue #63, that retire must resume rather than
# fail on "$old does not exist" when $old really is gone locally already.
bare3="$(mktemp -d)/origin.git"
git init -q --bare "$bare3"
bare_origin "$bare3"
git checkout -q -b to-resume
git push -q -u origin to-resume
git branch -m to-resume to-resume-redo-1
git push -q -u origin to-resume-redo-1
# The old ref is deliberately left on origin, standing in for the failed
# delete a real partial failure would leave behind.
out="$(orch_gh_failing branch retire to-resume to-resume-redo-1 2>&1)"; st=$?
assert_status "resumes rather than failing on the already-gone old name" "$st" 0
assert_eq "prints the new name" "$out" "to-resume-redo-1"
assert_eq "and finishes the delete the earlier attempt left undone" \
  "$(git -C "$bare3" rev-parse --quiet --verify refs/heads/to-resume >/dev/null && echo present || echo gone)" "gone"

# A genuine remote failure on that same delete step still has to die, not
# get swallowed by the resume path's tolerance for an already-gone ref.
bare4="$(mktemp -d)/origin.git"
git init -q --bare "$bare4"
git -C "$bare4" symbolic-ref HEAD refs/heads/to-protect
git -C "$bare4" config receive.denyDeleteCurrentBranch refuse
bare_origin "$bare4"
git checkout -q -b to-protect
git push -q -u origin to-protect
out="$(orch_gh_failing branch retire to-protect to-protect-redo-1 2>&1)"; st=$?
assert_status "dies when the old ref genuinely cannot be deleted" "$st" 1
assert_contains "with a clear reason" "$out" "could not delete origin/to-protect"

out="$(orch_gh_failing branch retire 2>&1)"; st=$?
assert_status "refuses with the wrong number of arguments" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh branch retire"

# --- branch sync (#792) --------------------------------------------------------
# Merges origin's tip of the current plugin-made branch's base into it - never
# rebasing, never the local base - moves its base SHA to that tip, and pushes
# when the branch has an upstream. Exit 3 is a conflict left in progress; every
# refusal is exit 1 with nothing moved. Checked through tips, merge parents,
# git config, state.json and what reached the bare origin.
echo
echo "branch sync"
# bs_advance <file> <content>: commit <content> to <file> on origin's main,
# from the repo origin was pushed from; prints origin's new main tip.
bs_advance() {
  echo "$2" >"$sc_seed/$1"
  git -C "$sc_seed" add "$1" && git -C "$sc_seed" commit -qm "main: $1"
  git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/main
  git -C "$sc_seed" rev-parse HEAD
}
# bs_sha: the current branch's base SHA as its git config records it.
bs_sha() { git config --get "branch.$(git branch --show-current).orchestrator-base-sha"; }
# bs_merging: "yes" when a merge is in progress in this checkout.
bs_merging() { if git rev-parse -q --verify MERGE_HEAD >/dev/null; then echo yes; else echo no; fi; }
# bs_origin_tip <branch>: origin's tip of <branch>, empty when it has none.
bs_origin_tip() { git ls-remote "$sc_origin" "refs/heads/$1" | cut -f1; }

sc_clone
git -C "$sc_seed" checkout -q -b seed-main
git -C "$sc_seed" reset -q --hard "$(git rev-parse origin/main)"
orch_gh_failing init bsync >/dev/null
orch_gh_failing state set issue 11
orch_gh_failing branch create >/dev/null
git commit -q --allow-empty -m "work on the branch"
main_tip="$(git rev-parse origin/main)"
before="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "nothing to merge exits 0" "$st" 0
assert_eq "and makes no commit" "$(git rev-parse HEAD)" "$before"
assert_eq "recording origin's base tip as the base SHA in branch config" "$(bs_sha)" "$main_tip"
assert_eq "and in state.json, since this checkout's flow holds the branch" \
  "$(orch_gh_failing state get base_sha)" "$main_tip"

# Clean merge, with the local base branch left behind origin's.
local_main="$(git rev-parse main)"
new_tip="$(bs_advance other.txt from-main)"
before="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a clean merge exits 0" "$st" 0
assert_eq "with a merge commit whose first parent is the prior tip" "$(git rev-parse HEAD^1)" "$before"
assert_eq "and whose second parent is origin's base tip" "$(git rev-parse HEAD^2)" "$new_tip"
assert_eq "the local base branch stayed behind, unmerged" "$(git rev-parse main)" "$local_main"
assert_eq "the branch's prior commits keep their SHAs" "$(git log --format=%s -1 "$before")" "work on the branch"
assert_eq "base SHA moved to the merged tip in branch config" "$(bs_sha)" "$new_tip"
assert_eq "and in state.json" "$(orch_gh_failing state get base_sha)" "$new_tip"
assert_eq "branch base-sha prints the merged base tip" "$(orch_gh_failing branch base-sha)" "$new_tip"
assert_eq "a branch with no upstream is not pushed" "$(bs_origin_tip orch/11-bsync)" ""

# The base the flow records, never the branch config's or the setting's.
git -C "$sc_seed" push -q "$sc_origin" "$new_tip:refs/heads/uat"
git -C "$sc_seed" checkout -q -b seed-uat "$new_tip"
echo uat >"$sc_seed/uat.txt"; git -C "$sc_seed" add uat.txt; git -C "$sc_seed" commit -qm uat
git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/uat
git -C "$sc_seed" checkout -q seed-main
git config branch.orch/11-bsync.orchestrator-base uat
git config orchestrator.base uat
before="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a held branch syncs with the flow's base" "$st" 0
assert_eq "merging nothing from another base" "$(git rev-parse HEAD)" "$before"
assert_eq "and recording the flow's base tip" "$(bs_sha)" "$new_tip"
git config branch.orch/11-bsync.orchestrator-base main
git config --unset orchestrator.base

# With an upstream: pushed, plainly.
git push -q -u origin orch/11-bsync 2>/dev/null
new_tip="$(bs_advance more.txt more)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a branch with an upstream syncs" "$st" 0
assert_eq "and the merge reaches origin" "$(bs_origin_tip orch/11-bsync)" "$(git rev-parse HEAD)"

# Conflict: both sides change the same file.
echo ours >clash.txt; git add clash.txt; git commit -qm "clash: ours"
git push -q 2>/dev/null
new_tip="$(bs_advance clash.txt theirs)"
before="$(git rev-parse HEAD)"; sha_before="$(bs_sha)"; pushed="$(bs_origin_tip orch/11-bsync)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a conflict exits 3" "$st" 3
assert_contains "saying it conflicted" "$out" "conflict"
assert_eq "leaving the merge in progress" "$(bs_merging)" "yes"
assert_eq "the branch tip unmoved" "$(git rev-parse HEAD)" "$before"
assert_eq "the base SHA unmoved in branch config" "$(bs_sha)" "$sha_before"
assert_eq "and in state.json" "$(orch_gh_failing state get base_sha)" "$sha_before"
assert_eq "and origin unmoved" "$(bs_origin_tip orch/11-bsync)" "$pushed"

out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a rerun before the merge is committed refuses" "$st" 1
assert_eq "leaving the merge in progress" "$(bs_merging)" "yes"

# The resolver commits; the rerun finishes the sync.
echo both >clash.txt; git add clash.txt; git commit -q --no-edit
resolved="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a rerun after the resolution is committed exits 0" "$st" 0
assert_eq "with nothing more to merge" "$(git rev-parse HEAD)" "$resolved"
assert_eq "recording the base SHA" "$(bs_sha)" "$new_tip"
assert_eq "and in state.json" "$(orch_gh_failing state get base_sha)" "$new_tip"
assert_eq "and pushing the resolution" "$(bs_origin_tip orch/11-bsync)" "$resolved"

# A failed push: the merge and base SHA stand; a rerun pushes.
new_tip="$(bs_advance push.txt push)"
pushed="$(bs_origin_tip orch/11-bsync)"
git config remote.origin.pushurl "$(mktemp -d)/missing.git"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a failed push exits 1" "$st" 1
assert_contains "saying the push failed" "$out" "push"
assert_eq "with the merge commit made" "$(git rev-parse HEAD^2)" "$new_tip"
assert_eq "and the base SHA recorded" "$(bs_sha)" "$new_tip"
assert_eq "and origin unmoved" "$(bs_origin_tip orch/11-bsync)" "$pushed"
git config --unset remote.origin.pushurl
merged="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a rerun with origin reachable exits 0" "$st" 0
assert_eq "merging nothing more" "$(git rev-parse HEAD)" "$merged"
assert_eq "and pushes" "$(bs_origin_tip orch/11-bsync)" "$merged"

# Refusals: each exits 1 with nothing moved.
before="$(git rev-parse HEAD)"; sha_before="$(bs_sha)"
new_tip="$(bs_advance refused.txt refused)"
echo dirty >README.md
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "refuses a dirty tree" "$st" 1
assert_contains "saying the tree is dirty" "$out" \
  "orch: the working tree is dirty - commit or discard its changes first; nothing was synced"
assert_eq "moving no tip (dirty tree)" "$(git rev-parse HEAD)" "$before"
assert_eq "and no base SHA (dirty tree)" "$(bs_sha)" "$sha_before"
assert_eq "and leaving the change (dirty tree)" "$(cat README.md)" "dirty"
git checkout -q -- README.md

git checkout -q main
git commit -q --allow-empty -m "local main only"
git checkout -q orch/11-bsync
git config remote.origin.url "$(mktemp -d)/missing.git"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "refuses a failed fetch" "$st" 1
assert_contains "saying the fetch failed" "$out" "fetch"
assert_eq "never merging the local base instead" "$(git rev-parse HEAD)" "$before"
assert_eq "and moving no base SHA (failed fetch)" "$(bs_sha)" "$sha_before"
git config remote.origin.url "$sc_origin"

git checkout -q --detach
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "refuses a detached HEAD" "$st" 1
assert_contains "saying so" "$out" "detached HEAD"
assert_eq "moving nothing (detached HEAD)" "$(git rev-parse HEAD)" "$before"

git checkout -q main
before_main="$(git rev-parse HEAD)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "refuses the base branch itself" "$st" 1
assert_contains "naming it no plugin-made branch" "$out" "main"
assert_eq "moving nothing (base branch)" "$(git rev-parse HEAD)" "$before_main"

git checkout -q -b feature/hand-made
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "refuses a branch with no recorded base" "$st" 1
assert_eq "moving nothing (no recorded base)" "$(git rev-parse HEAD)" "$before_main"
assert_eq "and recording no base SHA" "$(bs_sha)" ""
git config orchestrator.base main
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "even with a base branch setting to fall back to" "$st" 1
git config --unset orchestrator.base
git checkout -q orch/11-bsync

out="$(orch_gh_failing branch sync extra 2>&1)"; st=$?
assert_status "refuses arguments" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh branch sync"

# A done flow's branch, then an archived one's, still finds its base.
state_fixture phase "done"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a done flow's branch syncs" "$st" 0
assert_eq "merging origin's base tip (done flow)" "$(git rev-parse HEAD^2)" "$new_tip"
assert_eq "recording it in state.json (done flow)" "$(orch_gh_failing state get base_sha)" "$new_tip"
orch_gh_failing archive >/dev/null
new_tip="$(bs_advance archived.txt archived)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "an archived flow's branch syncs through its branch config" "$st" 0
assert_eq "merging origin's base tip (archived flow)" "$(git rev-parse HEAD^2)" "$new_tip"
assert_eq "recording it in branch config (archived flow)" "$(bs_sha)" "$new_tip"

# A quick/ branch, which keeps no flow state.
git checkout -q main
orch_gh_failing branch off quick/12-qsync >/dev/null
git commit -q --allow-empty -m "quick work"
new_tip="$(bs_advance quick.txt quick)"
out="$(orch_gh_failing branch sync 2>&1)"; st=$?
assert_status "a quick/ branch syncs through its branch config" "$st" 0
assert_eq "merging origin's base tip (quick)" "$(git rev-parse HEAD^2)" "$new_tip"
assert_eq "recording it as the base SHA (quick)" "$(bs_sha)" "$new_tip"
assert_eq "and branch base-sha prints it" "$(orch_gh_failing branch base-sha)" "$new_tip"
assert_eq "writing no state" "$(on_disk .orchestrator/state.json)" "absent"

assert_contains "help lists branch sync" "$("$ORCH" help)" "branch sync"
cd "$SUITE_CWD" || exit 1
rm -rf "$(dirname "$sc_origin")"
restore_suite_env

# --- branch: unknown op -------------------------------------------------------
new_repo >/dev/null
out="$(orch_gh_failing branch bogus 2>&1)"; st=$?
assert_status "branch bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown branch op"
assert_contains "naming all five" "$out" "create|off|base-sha|sync|retire"
