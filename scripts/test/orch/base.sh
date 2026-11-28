# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# pr_body_complete <file>: writes to <file> a PR body carrying every piece pr
# open and pr publish require (#1387) - ## Summary, ## Evidence, and ## Merge
# Danger with its **Door:** and **Blast Radius:** lines - its Summary holding
# 'Implements the thing.' and 'Some detail.'.
pr_body_complete() {
  writeln '## Summary' '' 'Implements the thing.' '' 'Some detail.' '' \
    '## Evidence' '' 'make test - pass' '' \
    '## Merge Danger' '' '**Door:** two-way' '**Blast Radius:** the widget module' >"$1"
}

# fake_next_pr <n>: the number the next PR opened takes.
fake_next_pr() { printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/next_pr"; }

# PR #n read back from the store: its base branch and body.
fake_pr_base_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/base" 2>/dev/null; }
fake_pr_body_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/body" 2>/dev/null; }

# GH_FAILING: a PATH directory holding a gh that fails - a fixture gh given no
# reply - for a repo whose origin GitHub cannot answer for (a local bare repo):
# the default branch settles on origin/HEAD, so a test running orch.sh with it
# first on PATH (orch_gh_failing) pins that rather than leaving it to this
# machine's gh.
GH_FAILING="$(gh_fixture && printf '%s\n' "$GH_FIXTURE/bin")"

# orch_gh_failing <args>...: runs orch.sh with the failing fixture gh first
# on PATH.
orch_gh_failing() { PATH="$GH_FAILING:$PATH" "$ORCH" "$@"; }

# --- a flow's base branch -----------------------------------------------------
# A flow fixes its base branch at init, so a later `base set` never moves the
# flow's fork point or its PR. uat carries a commit main does not, so where the
# flow branch forked from is visible in its history. base set's own checks and
# messages are the Python noun's tests; these run it end to end.
echo
echo "a flow's base branch"
new_repo >/dev/null
fresh_bare_origin bare
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
orch_gh_failing base clear >/dev/null

# A flow init recorded on the default branch, corrected to uat before it
# branches: only the correction can make branch create fork from uat's tip,
# since neither the init-recorded base nor the unset checkout setting names it.
rm -rf .orchestrator
orch_gh_failing init flowbase >/dev/null
assert_eq "a flow started with nothing set records the default branch" \
  "$(orch_gh_failing state get base)" "main"
orch_gh_failing base set uat --flow >/dev/null
assert_eq "state get base reads the corrected base" "$(orch_gh_failing state get base)" "uat"
orch_gh_failing state set issue 7
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "branch create succeeds" "$st" 0
assert_eq "the flow's next branch create forks from the corrected base's tip" \
  "$(git rev-parse HEAD)" "$uat_tip"
assert_eq "base_sha is the recorded base's tip" "$(orch_gh_failing state get base_sha)" "$uat_tip"
assert_contains "status prints the flow's base branch" "$(orch_gh_failing status)" "base:      uat"

body="$(mktemp)"
pr_body_complete "$body"
fake_github
fake_issue 7 open
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
state_fixture_drop base
assert_contains "status shows the default branch for a state with no base" \
  "$(orch_gh_failing status)" "base:      main"
git checkout -q main
out="$(orch_gh_failing branch create 2>&1)"; st=$?
assert_status "and branch create still forks it" "$st" 0
assert_eq "from the default branch" "$(git rev-parse HEAD)" "$main_tip"

assert_contains "orch.sh help lists base set --flow" "$(orch_gh_failing help)" "base set <branch> --flow"
# shellcheck disable=SC2154 # assigned by fresh_bare_origin
rm -rf "$(dirname "$bare")"
restore_suite_env
