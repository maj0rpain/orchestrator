# --- base --------------------------------------------------------------------
# The checkout-wide base branch setting and its one resolver. A typo here is
# silent in the worst way - work quietly forks from and targets a branch nobody
# will merge - so set must refuse anything origin does not have.
echo
echo "base"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# orch_gh_failing's gh cannot answer, so default-branch settles on origin/HEAD -
# pinned above rather than left to this machine's gh.
base_setting() { git config --get orchestrator.base || echo "<unset>"; }

out="$(orch_gh_failing base show)"; st=$?
assert_status "show succeeds with nothing set" "$st" 0
assert_eq "show names the default branch as the source when nothing is set" "$out" "main (default)"

out="$(orch_gh_failing base set nosuch 2>&1)"; st=$?
assert_status "set refuses a branch missing from origin" "$st" 1
assert_contains "names the missing branch" "$out" "nosuch"
assert_eq "a refused set leaves the config untouched" "$(base_setting)" "<unset>"

out="$(orch_gh_failing base set uat 2>&1)"; st=$?
assert_status "set accepts a branch origin has" "$st" 0
assert_eq "set writes orchestrator.base" "$(base_setting)" "uat"
assert_eq "show names the setting as the source" "$(orch_gh_failing base show)" "uat (set)"
assert_eq "default-branch still names the default branch" "$(orch_gh_failing default-branch)" "main"

wt="$(mktemp -d)/wt"
git worktree add -q "$wt" -b base-wt
assert_eq "every worktree of the clone shares the setting" "$(cd "$wt" && orch_gh_failing base show)" "uat (set)"
git worktree remove --force "$wt"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set refuses when origin cannot be reached to verify" "$st" 1
assert_eq "an unverified set leaves the config untouched" "$(base_setting)" "uat"
bare_origin "$bare"

out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set accepts the default branch's own name" "$st" 0
assert_eq "setting the default branch acts as clearing" "$(base_setting)" "<unset>"
assert_eq "show then reports the default source" "$(orch_gh_failing base show)" "main (default)"

orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing base clear 2>&1)"; st=$?
assert_status "clear succeeds when a setting exists" "$st" 0
assert_eq "clear removes the setting" "$(base_setting)" "<unset>"
out="$(orch_gh_failing base clear 2>&1)"; st=$?
assert_status "clear succeeds when nothing was set" "$st" 0

out="$(orch_gh_failing base 2>&1)"; st=$?
assert_status "refuses a missing verb" "$st" 1
out="$(orch_gh_failing base set 2>&1)"; st=$?
assert_status "set refuses with no branch" "$st" 1
rm -rf "$(dirname "$bare")"

# --- a flow's base branch -------------------------------------------------------
# A flow fixes its base branch at init, so a later `base set` never moves the
# flow's fork point or its PR. uat carries a commit main does not, so where the
# flow branch forked from is visible in its history.
echo
echo "a flow's base branch"
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

orch_gh_failing init nobase >/dev/null
assert_eq "init records the default branch as base when nothing is set" \
  "$(orch_gh_failing state get base)" "main"
rm -rf .orchestrator

orch_gh_failing base set uat >/dev/null
orch_gh_failing init flowbase >/dev/null
assert_eq "init records the base branch setting" "$(orch_gh_failing state get base)" "uat"

out="$(orch_gh_failing base set uat 2>&1)"
assert_not_contains "set says nothing more when the active flow already has that base" \
  "$out" "keeps its own base branch"
out="$(orch_gh_failing base set main 2>&1)"; st=$?
assert_status "set still succeeds while a flow with another base is active" "$st" 0
assert_contains "and notes that the active flow keeps its own base branch" \
  "$out" "flowbase keeps its own base branch: uat"
assert_eq "the flow's recorded base is untouched" "$(orch_gh_failing state get base)" "uat"

# base set --flow: the explicit correction of the flow's own base, allowed only
# while the flow has no branch. The checkout's setting is never its target.
checkout_setting() { git config --get orchestrator.base || echo "<unset>"; }
orch_gh_failing base set uat >/dev/null
out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow accepts the flag after the branch name" "$st" 0
assert_eq "and reports the flow's new base" "$out" "main (flow)"
assert_eq "storing the default branch's own name literally" "$(orch_gh_failing state get base)" "main"
assert_eq "leaving the checkout's base branch setting unchanged" "$(checkout_setting)" "uat"
orch_gh_failing base clear >/dev/null
out="$(orch_gh_failing base set --flow uat 2>&1)"; st=$?
assert_status "base set --flow accepts the flag before the branch name" "$st" 0
assert_eq "in the spec phase it prints the branch and its flow source" "$out" "uat (flow)"
assert_eq "state get base reads the corrected base" "$(orch_gh_failing state get base)" "uat"
assert_eq "and the unset checkout setting stays unset" "$(checkout_setting)" "<unset>"
for name in null 007; do
  git push -q origin "HEAD:refs/heads/$name"
  orch_gh_failing base set "$name" --flow >/dev/null
  assert_eq "base set --flow stores a branch named $name literally" \
    "$(orch_gh_failing state get base)" "$name"
done
state_fixture updated "sentinel"
orch_gh_failing base set uat --flow >/dev/null
assert_ne "base set --flow stamps updated" "$(orch_gh_failing state get updated)" "sentinel"

for args in "" "--flow" "uat main --flow" "uat --flow --flow" "uat --flaw"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  out="$(orch_gh_failing base set $args 2>&1)"; st=$?
  assert_status "base set refuses the arguments '$args'" "$st" 1
  assert_contains "with its usage line" "$out" "usage: orch.sh base set <branch> [--flow]"
done
out="$(orch_gh_failing base show --flow 2>&1)"; st=$?
assert_status "base show refuses --flow" "$st" 1
assert_contains "with its usage error" "$out" "usage: orch.sh base show"
out="$(orch_gh_failing base clear --flow 2>&1)"; st=$?
assert_status "base clear refuses --flow" "$st" 1
assert_contains "with its usage error" "$out" "usage: orch.sh base clear"

out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"; st=$?
assert_status "base set --flow refuses an invalid branch name" "$st" 1
assert_contains "saying nothing was set" "$out" "bad..name is not a valid branch name - nothing was set"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set nosuch --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a branch missing from origin" "$st" 1
assert_contains "with plain base set's message" "$out" \
  "branch nosuch does not exist on origin - push it first, or check the name"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow refuses when origin cannot be reached" "$st" 1
assert_contains "with plain base set's message" "$out" \
  "could not reach origin to check that branch main exists - nothing was set"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "an invalid name is refused before origin is contacted" "$out" \
  "bad..name is not a valid branch name - nothing was set"
bare_origin "$bare"

# A flow init recorded on the default branch, corrected to uat before it
# branches: only the correction can make branch create fork from uat's tip,
# since neither the init-recorded base nor the unset checkout setting names it.
rm -rf .orchestrator
orch_gh_failing init flowbase >/dev/null
assert_eq "a flow started with nothing set records the default branch" \
  "$(orch_gh_failing state get base)" "main"
orch_gh_failing base set uat --flow >/dev/null
orch_gh_failing state set issue 7
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create succeeds" "$st" 0
assert_eq "the flow's next branch create forks from the corrected base's tip" \
  "$(git rev-parse HEAD)" "$uat_tip"

out="$(orch_gh_failing base set main --flow 2>&1)"; st=$?
assert_status "base set --flow refuses once the flow has a branch" "$st" 1
assert_contains "outside the review phase saying to abort" "$out" \
  "flow flowbase already has branch orch/7-flowbase - its base can no longer change; abort to start again on another base"
assert_eq "leaving the flow's base unchanged" "$(orch_gh_failing state get base)" "uat"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "a branched flow given an invalid name reports the branch refusal" "$out" \
  "flow flowbase already has branch orch/7-flowbase"
assert_eq "base_sha is the recorded base's tip" "$(orch_gh_failing state get base_sha)" "$uat_tip"
assert_contains "status prints the flow's base branch" "$(orch_gh_failing status)" "base:      uat"

body="$(mktemp)"
writeln 'Implements the thing.' >"$body"
fake_github
fake_next_pr 31
out="$(orch_gh_failing pr open "Title" "$body" 2>&1)"; st=$?
assert_status "pr open succeeds" "$st" 0
assert_eq "pr open targets the flow's recorded base" "$(fake_pr_base_of 31)" "uat"
assert_first_line "a PR into a non-default base refers to its issue instead of closing it" \
  "$(fake_pr_body_of 31)" "Refs #7"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# A deleted base branch must not quietly become a fork from a stale local copy.
git update-ref refs/remotes/origin/gone "$main_tip"
git branch -q gone "$main_tip"
state_fixture base gone
orch_gh_failing state set issue 8
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create refuses a base branch origin says is gone" "$st" 1
assert_contains "naming the base branch and the correction" "$out" \
  "base branch gone does not exist on origin - push it, or point this flow at another base: orch.sh base set <branch> --flow"
assert_eq "and creates no branch" \
  "$(git rev-parse --verify --quiet orch/8-flowbase >/dev/null && echo made || echo none)" "none"

# A flow started before base was recorded forked from the default branch.
legacy="$(mktemp)"
jq 'del(.base)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_contains "status shows the default branch for a state with no base" \
  "$(orch_gh_failing status)" "base:      main"
git checkout -q main
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "and branch create still forks it" "$st" 0
assert_eq "from the default branch" "$(git rev-parse HEAD)" "$main_tip"
orch_gh_failing base clear >/dev/null

# A done flow, or none at all, is no active flow to correct.
state_fixture phase "done"
out="$(orch_gh_failing base set uat --flow 2>&1)"; st=$?
assert_status "base set --flow refuses a done flow" "$st" 1
assert_contains "as no active flow" "$out" "no active flow - nothing was set"
assert_eq "leaving its base unchanged" "$(orch_gh_failing state get base)" ""
rm -rf .orchestrator
out="$(orch_gh_failing base set uat --flow 2>&1)"; st=$?
assert_status "base set --flow refuses with no state.json" "$st" 1
assert_contains "as no active flow" "$out" "no active flow - nothing was set"
out="$(orch_gh_failing base set 'bad..name' --flow 2>&1)"
assert_contains "no state.json plus an invalid name reports no active flow" "$out" \
  "no active flow - nothing was set"
assert_eq "and never touches the checkout setting" "$(checkout_setting)" "<unset>"
assert_contains "orch.sh help lists base set --flow" "$(orch_gh_failing help)" "base set <branch> --flow"
rm -rf "$(dirname "$bare")"
