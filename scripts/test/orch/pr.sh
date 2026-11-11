# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fake_pull <n>: seeds #n as an open pull request, which gh's issue reads
# answer for too.
fake_pull() { fake_issue "$1" open; : >"$ORCH_GH_FAKE_STORE/issues/$1/pull"; }

# fake_prs: every PR number the store holds, in order, space-separated.
fake_prs() { ls "$ORCH_GH_FAKE_STORE/prs" 2>/dev/null | sort -n | tr '\n' ' '; }

# PR #n read back from the store: its head branch and its title.
fake_pr_head_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/head" 2>/dev/null; }
fake_pr_title_of() { cat "$ORCH_GH_FAKE_STORE/prs/$1/title" 2>/dev/null; }

# fake_pr_labels_of <n>: PR #n's label names read back from the store, one
# per line.
fake_pr_labels_of() { cat "$ORCH_GH_FAKE_STORE/prs/$1/labels" 2>/dev/null || true; }

# fake_pr_label_drop <name>: every later PR opened with label <name> is stored
# without it, as a gh whose label mutation did not land (#1299).
fake_pr_label_drop() { printf '%s\n' "$1" >>"$ORCH_GH_FAKE_STORE/pr_label_drops"; }

# pr_body_without <line>: prints the path of a fresh PR body, pr_body_complete's
# with every line that is exactly <line> dropped.
pr_body_without() {
  local full cut
  full="$(mktemp)" && cut="$(mktemp)" || return 1
  pr_body_complete "$full"
  grep -vxF -- "$1" "$full" >"$cut"
  printf '%s\n' "$cut"
}

# PR_BODY_PIECES: each line pr_body_complete writes that pr open and pr
# publish require (#1387), a tab, and the piece the refusal names without it.
PR_BODY_PIECES="$(printf '%s\t%s\n' \
  '## Summary' 'no ## Summary heading' \
  '## Evidence' 'no ## Evidence heading' \
  '## Merge Danger' 'no ## Merge Danger heading' \
  '**Door:** two-way' 'no **Door:** line under ## Merge Danger' \
  '**Blast Radius:** the widget module' 'no **Blast Radius:** line under ## Merge Danger')"

# PR_BODY_REFUSED: the opening of every PR-body refusal, before its file.
PR_BODY_REFUSED="orch: the PR body does not meet the PR-writing standard - no PR was opened:"

# --- pr open -----------------------------------------------------------------
# PR #15 merged without closing #14 because the agent's body opened with a verb
# GitHub does not read as a closer. pr open owns the keyword instead, so no
# agent-chosen wording can leave a spec issue open again.
#
# open_pr's create goes through the store-backed fake (fake_github), and the
# PR it opened is read back from the store - the fixture gh's log stays empty,
# proving it never spawns a real gh subprocess. The real operation is pinned in
# "gh adapter contract".
echo
echo "pr open"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init propen >/dev/null
git checkout -q -b orch/16-propen
state_fixture branch orch/16-propen
body="$(mktemp)"
pr_body_complete "$body"

out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no issue" "$st" 1
assert_contains "with the guard branch create uses" "$out" \
  "no issue recorded in state - the spec phase must publish one first"
out="$("$ORCH" pr open "Title" "$(pr_body_without '## Summary')" 2>&1)"; st=$?
assert_eq "the recorded issue is checked before the body's standard" "$out" \
  "orch: no issue recorded in state - the spec phase must publish one first"

"$ORCH" state set issue 16
fake_github
fake_issue 16 open
fake_next_pr 23

# The PR-writing standard (#1387): a body lacking a piece of the human layer
# is refused before anything is pushed, created or recorded.
state_before="$(mktemp)"
cp .orchestrator/state.json "$state_before"
while IFS=$'\t' read -r piece named; do
  out="$("$ORCH" pr open "Title" "$(pr_body_without "$piece")" 2>&1)"; st=$?
  assert_status "a body without '$piece' is refused" "$st" 1
  assert_contains "naming the missing piece" "$out" "$named"
done <<<"$PR_BODY_PIECES"
bare_body="$(mktemp)"
writeln 'Implements the thing.' >"$bare_body"
out="$("$ORCH" pr open "Title" "$bare_body" 2>&1)"; st=$?
assert_status "a body with no piece at all is refused" "$st" 1
assert_eq "naming every missing piece in one message" "$out" \
  "$PR_BODY_REFUSED no ## Summary heading; no ## Evidence heading; no ## Merge Danger heading; no **Door:** line under ## Merge Danger; no **Blast Radius:** line under ## Merge Danger"
assert_eq "a refused body pushes nothing" \
  "$(origin_branch_state "$bare" orch/16-propen)" \
  "missing"
assert_eq "creates no PR" "$(fake_prs)" ""
assert_eq "writes no PR marker" "$(pr_marker_of orch/16-propen)" ""
assert_eq "and records no PR in state" \
  "$(cmp -s "$state_before" .orchestrator/state.json && echo same || echo changed)" "same"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "and records it in state" "$("$ORCH" state get pr)" "23"
assert_eq "and on the branch, so a busy check stays local (#1200)" \
  "$(pr_marker_of orch/16-propen)" "23"
assert_eq "opening it as a draft" "$(fake_pr_draft_of 23)" "yes"
assert_eq "from the flow's branch" "$(fake_pr_head_of 23)" "orch/16-propen"
assert_eq "under the title given" "$(fake_pr_title_of 23)" "Title"
body_recorded="$(fake_pr_body_of 23)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_eq "and targets the flow's base, the default branch" "$(fake_pr_base_of 23)" "main"
assert_eq "leaves a blank line before the original body" \
  "$(printf '%s\n' "$body_recorded" | sed -n 2p)" ""
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "the create call never reached a real gh subprocess" \
  "$(gh_calls)" "0"

# Open tickets (#1734): pr open leaves a PR alone while the spec issue has open
# sub-issues, on both the create and the update path.
fake_next_issue 800
tbody="$(mktemp)"; writeln 'Build it.' >"$tbody"
ot="$("$ORCH" ticket publish 16 "T" "$tbody")"
prs_before="$(fake_prs)"
title_before="$(fake_pr_title_of 23)"
out="$("$ORCH" pr open "Changed" "$body" 2>&1)"; st=$?
assert_status "open tickets: pr open refuses with a PR recorded" "$st" 1
assert_contains "naming pr open" "$out" \
  "orch: #16 still has open tickets: #$ot - run the driver loop (orch.sh ticket next 16) or close them, then run pr open again"
assert_eq "and leaves that PR unedited" "$(fake_pr_title_of 23)" "$title_before"
state_fixture pr ""
git config --unset "branch.orch/16-propen.orchestrator-pr"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "open tickets: pr open refuses with no PR recorded" "$st" 1
assert_contains "naming pr open (create path)" "$out" "then run pr open again"
assert_eq "and creates no PR" "$(fake_prs)" "$prs_before"
fake_fail adapter_sub_issues
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "pr open refuses when GitHub cannot be read" "$st" 1
assert_contains "naming the failure" "$out" "orch: gh could not list sub-issues of #16"
assert_eq "and creates no PR when unreadable" "$(fake_prs)" "$prs_before"
fake_unfail
"$ORCH" ticket close "$ot" >/dev/null
state_fixture pr 23
git config "branch.orch/16-propen.orchestrator-pr" 23
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "pr open passes once the tickets are closed" "$st" 0
assert_eq "and updates the recorded PR" "$out" "23"
assert_eq "creating no PR" "$(fake_prs)" "$prs_before"

git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_fail adapter_pr_create 'a pull request for branch "orch/16-propen" into branch "main" already exists'
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_eq "writing no PR marker on the branch" "$(pr_marker_of orch/16-propen)" ""
assert_contains "passing gh's reason through" "$out" "already exists"
assert_contains "naming the branch it would have opened from" "$out" "orch/16-propen"
assert_contains "and the issue it would have closed" "$out" "#16"
assert_eq "opening nothing" "$(fake_prs)" "23 "
# gh's reason rides on orch's own line, first line only (#846).
assert_gh_dies "a failed open still exits 1" adapter_pr_create "$GH_502" 1 \
  "orch: gh could not open the PR for branch orch/16-propen (issue #16): HTTP 502: Bad Gateway" \
  "$ORCH" pr open "Title" "$body"

# --label (#1299), as pr publish takes it: the draft PR carries each label
# from creation, read back once it is recorded in state and on the branch.
fake_unfail
state_fixture pr ""
errf="$(mktemp)"
fake_next_pr 40
out="$("$ORCH" pr open "Title" "$body" --label no-version-bump --label "needs review" 2>"$errf")"; st=$?
assert_status "--label: opens the PR" "$st" 0
assert_eq "--label: prints the PR number" "$out" "40"
assert_eq "--label: carrying each label" "$(fake_pr_labels_of 40)" "$(writeln no-version-bump 'needs review')"
assert_eq "--label: still a draft" "$(fake_pr_draft_of 40)" "yes"

for bad_args in "--label" "--label --label" "--draft"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  out="$("$ORCH" pr open "Title" "$body" $bad_args 2>&1)"; st=$?
  assert_status "'$bad_args' is refused" "$st" 1
  assert_contains "naming it" "$out" "${bad_args%% *}"
done
assert_eq "no refused option opened a PR" "$(fake_prs)" "23 40 "

git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_next_pr 41
fake_pr_label_drop no-version-bump
fake_pr_label_drop "needs review"
out="$("$ORCH" pr open "Title" "$body" --label no-version-bump --label "needs review" 2>"$errf")"; st=$?
assert_status "labels that did not land fail the command" "$st" 1
assert_eq "printing nothing on stdout" "$out" ""
assert_eq "naming the PR and each missing label" "$(cat "$errf")" \
  "orch: PR #41 is open but lacks the labels 'no-version-bump', 'needs review' - add them by hand"
assert_eq "the PR is still recorded in state" "$("$ORCH" state get pr)" "41"
assert_eq "and on the branch" "$(pr_marker_of orch/16-propen)" "41"

git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_next_pr 60
fake_label_names No-Version-Bump; rm -f "$ORCH_GH_FAKE_STORE/pr_label_drops"
out="$("$ORCH" pr open "Title" "$body" --label no-version-bump 2>"$errf")"; st=$?
assert_status "a label landed in the repo's casing is not reported missing" "$st" 0
assert_eq "and the PR carries the repo's casing" "$(fake_pr_labels_of 60)" "No-Version-Bump"
fake_label_names; rm -rf "$ORCH_GH_FAKE_STORE/prs/60"
git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_next_pr 42
fake_fail adapter_pr_labels "$GH_502"
out="$("$ORCH" pr open "Title" "$body" --label ci 2>"$errf")"; st=$?
assert_status "a failed label read fails the command" "$st" 1
assert_eq "printing nothing on stdout" "$out" ""
assert_eq "naming the PR and relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not read the labels of PR #42, open and recorded on its branch: HTTP 502: Bad Gateway"
assert_eq "the PR is still recorded in state" "$("$ORCH" state get pr)" "42"
assert_eq "and on the branch" "$(pr_marker_of orch/16-propen)" "42"

git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_fail adapter_pr_create "could not add label: 'nope' not found"
out="$("$ORCH" pr open "Title" "$body" --label nope 2>&1)"; st=$?
assert_status "an unknown label fails the create" "$st" 1
assert_eq "relaying gh's reason" "$out" \
  "orch: gh could not open the PR for branch orch/16-propen (issue #16): could not add label: 'nope' not found"
assert_eq "recording no PR in state" "$("$ORCH" state get pr)" ""
assert_eq "nor on the branch" "$(pr_marker_of orch/16-propen)" ""
assert_eq "opening nothing" "$(fake_prs)" "23 40 41 42 "
fake_unfail

# A push origin rejects stops pr open before any create (#1300): open_pr runs
# inside $(...), where set -e is off, so a failed push used to fall through
# to the create and its misleading GraphQL error.
git commit -q --allow-empty -m "unpushed work"
origin_rejects "$bare"
state_before="$(mktemp)"
cp .orchestrator/state.json "$state_before"
fake_next_pr 43
out="$("$ORCH" pr open "Title" "$body" 2>"$errf")"; st=$?
assert_status "a rejected push fails pr open" "$st" 1
assert_eq "naming the branch, that no PR was opened, and git's reason" "$(cat "$errf")" \
  "orch: could not push branch orch/16-propen to origin - no PR was opened: ! [remote rejected] orch/16-propen -> orch/16-propen (pre-receive hook declined)"
assert_eq "creating no PR" "$(fake_prs)" "23 40 41 42 "
assert_eq "writing no PR marker" "$(pr_marker_of orch/16-propen)" ""
assert_eq "and leaving the flow state byte for byte" \
  "$(cmp -s "$state_before" .orchestrator/state.json && echo same || echo changed)" "same"
rm -f "$bare/hooks/pre-receive"

# A restart past the PR's creation (#1609): state.pr names the flow's open PR,
# so pr open updates it instead of creating a second one.
fake_unfail
fake_pr 50 open orch/16-propen main
fake_pr_body 50 "old body"
printf 'old title\n' >"$ORCH_GH_FAKE_STORE/prs/50/title"
printf 'keep-me\n' >"$ORCH_GH_FAKE_STORE/prs/50/labels"
state_fixture pr 50
prs_before="$(fake_prs)"
out="$("$ORCH" pr open "New title" "$body" --label ci 2>"$errf")"; st=$?
assert_status "restart: updates the recorded PR" "$st" 0
assert_eq "restart: prints its number" "$out" "50"
assert_eq "restart: creates no PR" "$(fake_prs)" "$prs_before"
assert_eq "restart: sets the title" "$(fake_pr_title_of 50)" "New title"
assert_first_line "restart: sets the body, issue line first" "$(fake_pr_body_of 50)" "Closes #16"
assert_eq "restart: adds the missing label and removes none" \
  "$(fake_pr_labels_of 50)" "$(writeln keep-me ci)"
out="$("$ORCH" pr open "New title" "$body" --label ci --label keep-me 2>"$errf")"; st=$?
assert_status "restart: a rerun repeats every write" "$st" 0
assert_eq "restart: adding no label twice" "$(fake_pr_labels_of 50)" "$(writeln keep-me ci)"
# A label the PR carries in another casing is neither re-added nor missing.
out="$("$ORCH" pr open "New title" "$body" --label CI --label Keep-Me 2>"$errf")"; st=$?
assert_status "restart: labels carried in another casing pass" "$st" 0
assert_eq "restart: re-adding no label carried in another casing" \
  "$(fake_pr_labels_of 50)" "$(writeln keep-me ci)"

# The restart's issue line follows the base the recorded PR targets, not the
# flow's recorded base (#2548); a differing base warns once and carries on.
assert_not_contains "restart: a PR on the flow's base prints no base warning" "$(cat "$errf")" "targets"
fake_pr 50 open orch/16-propen uat
state_fixture pr 50
out="$("$ORCH" pr open "New title" "$body" 2>"$errf")"; st=$?
assert_status "restart: a PR retargeted to uat succeeds" "$st" 0
assert_first_line "restart: a PR on uat gets Refs" "$(fake_pr_body_of 50)" "Refs #16"
assert_eq "restart: warning names the PR and both bases" "$(cat "$errf")" \
  "orch: PR #50 targets uat, not the flow's base main - its issue line follows the PR's base"
fake_pr 50 open orch/16-propen ''
state_fixture pr 50
out="$("$ORCH" pr open "New title" "$body" 2>"$errf")"; st=$?
assert_status "restart: an empty PR base succeeds" "$st" 0
assert_first_line "restart: an empty PR base follows the flow's base" "$(fake_pr_body_of 50)" "Closes #16"
assert_eq "restart: an empty PR base prints no warning" "$(cat "$errf")" ""
fake_pr 50 open orch/16-propen main
state_fixture pr 50
state_fixture base uat
out="$("$ORCH" pr open "New title" "$body" 2>"$errf")"; st=$?
assert_status "restart: a PR on main under a uat flow succeeds" "$st" 0
assert_first_line "restart: a PR on main gets Closes" "$(fake_pr_body_of 50)" "Closes #16"
assert_eq "restart: the converse warning" "$(cat "$errf")" \
  "orch: PR #50 targets main, not the flow's base uat - its issue line follows the PR's base"
state_fixture base main
printf 'keep-me\nci\n' >"$ORCH_GH_FAKE_STORE/prs/50/labels"
fake_pr_body 50 "old body"

for closed in closed merged; do
  fake_pr 51 "$closed" orch/16-propen uat
  fake_pr_body 51 "untouched"
  printf 'untouched title\n' >"$ORCH_GH_FAKE_STORE/prs/51/title"
  state_fixture pr 51
  out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
  assert_status "restart: a $closed recorded PR fails pr open" "$st" 1
  assert_contains "restart: naming the PR" "$out" "PR #51"
  assert_contains "restart: the refusal message is unchanged" "$out" \
    "PR #51, recorded in state, is $(printf '%s' "$closed" | tr a-z A-Z), not open - no PR was opened or updated"
  assert_not_contains "restart: a refused PR prints no base warning" "$out" "targets"
  assert_eq "restart: a $closed PR's body is unwritten" "$(fake_pr_body_of 51)" "untouched"
  assert_eq "restart: a $closed PR's title is unwritten" "$(fake_pr_title_of 51)" "untouched title"
  assert_eq "restart: creating none" "$(fake_prs)" "${prs_before}51 "
  rm -rf "$ORCH_GH_FAKE_STORE/prs/51"
done
fake_pr 51 open some-other-branch main
state_fixture pr 51
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "restart: a recorded PR on another branch fails pr open" "$st" 1
assert_contains "restart: naming the PR" "$out" "PR #51"
assert_eq "restart: creating none" "$(fake_prs)" "${prs_before}51 "
rm -rf "$ORCH_GH_FAKE_STORE/prs/51"

fake_pr_body 50 "untouched body"
state_fixture pr 50
git commit -q --allow-empty -m "more unpushed work"
origin_rejects "$bare"
out="$("$ORCH" pr open "Rejected title" "$body" --label other 2>&1)"; st=$?
assert_status "restart: a rejected push fails pr open" "$st" 1
assert_eq "restart: leaving the title" "$(fake_pr_title_of 50)" "New title"
assert_eq "restart: and the body" "$(fake_pr_body_of 50)" "untouched body"
assert_eq "restart: and the labels" "$(fake_pr_labels_of 50)" "$(writeln keep-me ci)"
rm -f "$bare/hooks/pre-receive"

fake_fail adapter_pr_label_add "$GH_502"
out="$("$ORCH" pr open "Third title" "$body" --label other 2>&1)"; st=$?
assert_status "restart: a failed label write fails pr open" "$st" 1
assert_contains "restart: naming the label" "$out" "'other'"
assert_contains "restart: and the writes that landed" "$out" "title"
assert_eq "restart: the title did land" "$(fake_pr_title_of 50)" "Third title"
fake_unfail
fake_fail adapter_pr_title_edit "$GH_502"
out="$("$ORCH" pr open "Fourth title" "$body" 2>&1)"; st=$?
assert_status "restart: a failed title write fails pr open" "$st" 1
assert_contains "restart: naming the title" "$out" "title"
fake_unfail
fake_fail adapter_pr_body_edit "$GH_502"
out="$("$ORCH" pr open "Fifth title" "$body" 2>&1)"; st=$?
assert_status "restart: a failed body write fails pr open" "$st" 1
assert_contains "restart: naming the body" "$out" "body"
assert_contains "restart: and the title that landed" "$out" "title"

# A tag named like the branch outranks it as a bare push source (#2337).
git config --unset "branch.orch/16-propen.orchestrator-pr"
state_fixture pr ""
fake_next_pr 90
git tag orch/16-propen
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR beside a tag named like the branch" "$st" 0
assert_eq "and prints the PR number" "$out" "90"
git tag -d orch/16-propen >/dev/null

fake_unfail

assert_contains "help documents --label" "$("$ORCH" help)" \
  "pr open <title> <body-file> [--label <name>]..."
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

# require_branch's die message is the other half of require_field's coverage
# (#79) alongside "refuses when state has no issue" above - a fresh flow with
# an issue recorded but no branch yet is exactly the gap between init and
# branch create.
echo
echo "pr open (missing branch)"
new_repo >/dev/null
"$ORCH" init nobranch >/dev/null
"$ORCH" state set issue 21
body="$(mktemp)"
pr_body_complete "$body"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no branch" "$st" 1
assert_contains "with the exact require_branch die message" "$out" \
  "no branch recorded in state"
out="$("$ORCH" pr open "Title" "$(pr_body_without '## Summary')" 2>&1)"; st=$?
assert_eq "the recorded branch is checked before the body's standard" "$out" \
  "orch: no branch recorded in state"

restore_suite_env

# --- pr publish --------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh pr create` in skill prose - stateless like branch off and issue publish,
# and not a draft like pr open is, since a quick implementation's review pass
# already ran before this is called.
echo
echo "pr publish"
new_repo >/dev/null
git remote set-url origin https://github.com/acme/widgets.git
gh_fixture
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main
git checkout -q -b quick/16-widgets
body="$(mktemp)"
pr_body_complete "$body"

fake_github
for n in 16 17 18 19 20 21 22 24 25; do fake_issue "$n" open; done
fake_next_pr 23
out="$("$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "records no state" "$(on_disk .orchestrator/state.json)" "absent"
assert_eq "opens against the default branch" "$(fake_pr_base_of 23)" "main"
assert_eq "not as a draft" "$(fake_pr_draft_of 23)" "no"
assert_eq "and from the current branch" "$(fake_pr_head_of 23)" "quick/16-widgets"
assert_eq "records the PR on the branch, so a busy check stays local (#1200)" \
  "$(pr_marker_of quick/16-widgets)" "23"
body_recorded="$(fake_pr_body_of 23)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "pushes the current branch" \
  "$(origin_branch_state "$bare" quick/16-widgets)" \
  "pushed"

out="$("$ORCH" pr publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses an issue that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
out="$("$ORCH" pr publish abc "Title" "$(pr_body_without '## Summary')" 2>&1)"; st=$?
assert_eq "the issue argument is checked before the body's standard" "$out" \
  "orch: issue must be a plain issue number, got: abc"

out="$("$ORCH" pr publish 16 "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1

fake_fail adapter_pr_create
out="$("$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming the branch it would have opened from" "$out" "quick/16-widgets"
assert_contains "and the issue it would have closed" "$out" "#16"

# --draft (#967): a quick implementation whose review pass met a spec question
# opens its PR as a draft, so a human rules on it before it goes ready.
fake_fail adapter_pr_create $'HTTP 422: Draft pull requests are not supported in this repository.\nsecond line'
out="$("$ORCH" pr publish 16 "Title" "$body" --draft 2>&1)"; st=$?
assert_status "--draft: a gh that will not open the draft fails it" "$st" 1
assert_eq "--draft: relaying gh's reason" "$out" \
  "orch: gh could not open the PR for branch quick/16-widgets (issue #16): HTTP 422: Draft pull requests are not supported in this repository."
assert_eq "--draft: opening nothing" "$(fake_prs)" "23 "
fake_unfail
fake_next_pr 24
out="$("$ORCH" pr publish 16 "Title" "$body" --draft 2>&1)"; st=$?
assert_status "--draft: opens the PR" "$st" 0
assert_eq "--draft: prints the PR number" "$out" "24"
assert_eq "--draft: as a draft" "$(fake_pr_draft_of 24)" "yes"
assert_eq "--draft: records the draft PR on the branch too" \
  "$(pr_marker_of quick/16-widgets)" "24"
assert_first_line "--draft: its body still opens with the closing keyword" \
  "$(fake_pr_body_of 24)" "Closes #16"

out="$("$ORCH" pr publish 16 "Title" "$body" --ready 2>&1)"; st=$?
assert_status "an unknown option is refused" "$st" 1
assert_contains "naming it" "$out" "unknown option: --ready"
assert_eq "opening nothing" "$(fake_prs)" "23 24 "

# A PR that was never created leaves no marker, so the branch still counts as
# holding its checkout (#1200).
git checkout -q -b quick/17-gadgets
fake_fail adapter_pr_create
out="$("$ORCH" pr publish 17 "Title" "$body" 2>&1)"; st=$?
assert_status "a failed create on a fresh branch fails" "$st" 1
assert_eq "and writes no PR marker on it" "$(pr_marker_of quick/17-gadgets)" ""
out="$("$ORCH" pr publish 17 "Title" "$body" --draft 2>&1)"; st=$?
assert_status "--draft: a failed create on a fresh branch fails" "$st" 1
assert_eq "--draft: and writes no PR marker on it" "$(pr_marker_of quick/17-gadgets)" ""
fake_unfail

# --label (#1299): a PR carries the labels the repo requires from creation,
# so CI's first run sees them, and each is read back once the PR is recorded.
git checkout -q -b quick/18-labels
errf="$(mktemp)"
fake_next_pr 30
fake_fail adapter_pr_labels
out="$("$ORCH" pr publish 18 "Title" "$body" 2>"$errf")"; st=$?
assert_status "no labels: opens the PR" "$st" 0
assert_eq "no labels: reading no labels back" "$out" "30"
fake_unfail
fake_next_pr 31
out="$("$ORCH" pr publish 18 "Title" "$body" --label no-version-bump 2>"$errf")"; st=$?
assert_status "--label: opens the PR" "$st" 0
assert_eq "--label: prints the PR number" "$out" "31"
assert_eq "--label: carrying the label" "$(fake_pr_labels_of 31)" "no-version-bump"
fake_next_pr 32
out="$("$ORCH" pr publish 18 "Title" "$body" --label no-version-bump --draft --label "needs review" 2>"$errf")"; st=$?
assert_status "--label twice, around --draft: opens the PR" "$st" 0
assert_eq "--label twice: carrying both labels" "$(fake_pr_labels_of 32)" "$(writeln no-version-bump 'needs review')"
assert_eq "--label before --draft: as a draft" "$(fake_pr_draft_of 32)" "yes"
fake_next_pr 33
out="$("$ORCH" pr publish 18 "Title" "$body" --draft --label no-version-bump 2>"$errf")"; st=$?
assert_status "--draft before --label: opens the PR" "$st" 0
assert_eq "--draft before --label: as a draft" "$(fake_pr_draft_of 33)" "yes"
assert_eq "--draft before --label: carrying the label" "$(fake_pr_labels_of 33)" "no-version-bump"

for bad_args in "--label" "--label --draft"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  out="$("$ORCH" pr publish 18 "Title" "$body" $bad_args 2>&1)"; st=$?
  assert_status "'$bad_args' is refused" "$st" 1
  assert_contains "naming --label" "$out" "--label needs a label name"
done
out="$("$ORCH" pr publish 18 "Title" "$body" --label "" 2>&1)"; st=$?
assert_status "an empty --label is refused" "$st" 1
assert_contains "naming --label" "$out" "--label needs a label name"
assert_eq "no refused --label opened a PR" "$(fake_prs)" "23 24 30 31 32 33 "

git checkout -q -b quick/19-dropped
fake_next_pr 34
fake_pr_label_drop "needs review"
out="$("$ORCH" pr publish 19 "Title" "$body" --label no-version-bump --label "needs review" 2>"$errf")"; st=$?
assert_status "a label that did not land fails the command" "$st" 1
assert_eq "printing nothing on stdout" "$out" ""
assert_eq "naming the PR and the missing label" "$(cat "$errf")" \
  "orch: PR #34 is open but lacks the label 'needs review' - add it by hand"
assert_eq "the PR is still recorded on the branch" "$(pr_marker_of quick/19-dropped)" "34"

git checkout -q -b quick/20-unread
fake_next_pr 35
fake_fail adapter_pr_labels "$GH_502"
out="$("$ORCH" pr publish 20 "Title" "$body" --label no-version-bump 2>"$errf")"; st=$?
assert_status "a failed label read fails the command" "$st" 1
assert_eq "printing nothing on stdout" "$out" ""
assert_eq "naming the PR and relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not read the labels of PR #35, open and recorded on its branch: HTTP 502: Bad Gateway"
assert_eq "the PR is still recorded on the branch" "$(pr_marker_of quick/20-unread)" "35"
fake_unfail

git checkout -q -b quick/21-typo
fake_fail adapter_pr_create "could not add label: 'no-verison-bump' not found"
out="$("$ORCH" pr publish 21 "Title" "$body" --label no-verison-bump 2>&1)"; st=$?
assert_status "an unknown label fails the create" "$st" 1
assert_eq "relaying gh's reason" "$out" \
  "orch: gh could not open the PR for branch quick/21-typo (issue #21): could not add label: 'no-verison-bump' not found"
assert_eq "writing no PR marker" "$(pr_marker_of quick/21-typo)" ""
assert_eq "opening nothing" "$(fake_prs)" "23 24 30 31 32 33 34 35 "
fake_unfail

# A failed push stops pr publish before any create, relaying git's reason
# (#1300).
git checkout -q -b quick/22-rejected
origin_rejects "$bare"
fake_next_pr 36
out="$("$ORCH" pr publish 22 "Title" "$body" 2>&1)"; st=$?
assert_status "a rejected push fails pr publish" "$st" 1
assert_eq "naming the branch, that no PR was opened, and git's reason" "$out" \
  "orch: could not push branch quick/22-rejected to origin - no PR was opened: ! [remote rejected] quick/22-rejected -> quick/22-rejected (pre-receive hook declined)"
assert_eq "creating no PR" "$(fake_prs)" "23 24 30 31 32 33 34 35 "
assert_eq "writing no PR marker" "$(pr_marker_of quick/22-rejected)" ""
rm -f "$bare/hooks/pre-receive"

# An unreadable body file stops pr publish before any create, naming the file,
# so no PR opens with only its closing line (#1335).
if [ "$(id -u)" -ne 0 ]; then
  git checkout -q -b quick/23-unreadable
  unreadable="$(mktemp)"
  writeln 'Implements the thing.' >"$unreadable"
  chmod 000 "$unreadable"
  out="$("$ORCH" pr publish 23 "Title" "$unreadable" 2>&1)"; st=$?
  assert_status "an unreadable body file fails pr publish" "$st" 1
  assert_eq "naming the file" "$out" "orch: could not read the PR body from $unreadable - no PR was opened"
  assert_eq "creating no PR" "$(fake_prs)" "23 24 30 31 32 33 34 35 "
  chmod 644 "$unreadable"
  rm -f "$unreadable"
fi

# The PR-writing standard (#1387): pr publish refuses a body lacking a piece
# of the human layer, or carrying one that is invalid, before any push. It
# reads structure only: fenced lines are not headings, and the Door and Blast
# Radius lines count only under ## Merge Danger.
git checkout -q -b quick/24-standard
bad_body="$(mktemp)"
writeln '## Summary' '' 'Did it.' '' '## Evidence' '' 'make test - pass' '' \
  '## Merge Danger' '' '**Door:** maybe' '**Blast Radius:** the widget module' >"$bad_body"
out="$("$ORCH" pr publish 24 "Title" "$bad_body" 2>&1)"; st=$?
assert_status "a Door value other than one-way or two-way is refused" "$st" 1
assert_eq "naming the bad value" "$out" \
  "$PR_BODY_REFUSED **Door:** value 'maybe' is not one-way or two-way"
writeln '## Summary' '' 'Did it.' '' '## Evidence' '' 'make test - pass' '' \
  '## Merge Danger' '' '**Door:** one-way' '**Door:** two-way' '**Blast Radius:**' >"$bad_body"
out="$("$ORCH" pr publish 24 "Title" "$bad_body" 2>&1)"; st=$?
assert_status "a second Door line and an empty Blast Radius are refused" "$st" 1
assert_eq "naming both" "$out" \
  "$PR_BODY_REFUSED a second **Door:** line under ## Merge Danger; an empty **Blast Radius:** value"
writeln '## Summary' '' '```markdown' '## Evidence' '```' '' \
  '**Door:** two-way' '**Blast Radius:** the widget module' '' \
  '## Merge Danger' '' '~~~~' '**Door:** two-way' '~~~~' >"$bad_body"
out="$("$ORCH" pr publish 24 "Title" "$bad_body" 2>&1)"; st=$?
assert_status "pieces only inside a fence or outside Merge Danger are refused" "$st" 1
assert_eq "counting each as missing" "$out" \
  "$PR_BODY_REFUSED no ## Evidence heading; no **Door:** line under ## Merge Danger; no **Blast Radius:** line under ## Merge Danger"
writeln '## Summary' '' '   ~~~' '## Evidence' '~~~' '' '## Merge Danger' '' \
  '**Door:** two-way' '**Blast Radius:** the widget module' >"$bad_body"
out="$("$ORCH" pr publish 24 "Title" "$bad_body" 2>&1)"; st=$?
assert_status "an Evidence heading only inside an indented fence is refused" "$st" 1
assert_eq "naming the missing Evidence heading alone" "$out" "$PR_BODY_REFUSED no ## Evidence heading"
reordered_body="$(mktemp)"
writeln '## Merge Danger' '' '**Blast Radius:** the widget module' '**Door:** one-way' '' \
  '## Evidence' '' '```' 'not a fence end: ````' '```' '' '## Summary' '' 'Did it.' >"$reordered_body"
fake_next_pr 37
out="$("$ORCH" pr publish 24 "Title" "$reordered_body" 2>&1)"; st=$?
assert_status "a body with every piece, in any order, opens the PR" "$st" 0
assert_eq "printing its number" "$out" "37"
git checkout -q -b quick/25-refused
out="$("$ORCH" pr publish 25 "Title" "$(pr_body_without '## Summary')" 2>&1)"; st=$?
assert_status "a refused body on a fresh branch fails" "$st" 1
assert_eq "pushing nothing" \
  "$(origin_branch_state "$bare" quick/25-refused)" \
  "missing"
assert_eq "creating no PR" "$(fake_prs)" "23 24 30 31 32 33 34 35 37 "
assert_eq "and writing no PR marker" "$(pr_marker_of quick/25-refused)" ""
git checkout -q --detach
out="$("$ORCH" pr publish 25 "Title" "$(pr_body_without '## Summary')" 2>&1)"; st=$?
assert_eq "the current branch is checked before the body's standard" "$out" \
  "orch: not on a branch (detached HEAD)"
git checkout -q quick/25-refused


# Open tickets (#1734): pr publish creates no PR while <issue> has open
# sub-issues.
fake_issue 61 open
fake_next_issue 810
tbody="$(mktemp)"; writeln 'Build it.' >"$tbody"
pt="$("$ORCH" ticket publish 61 "T" "$tbody")"
prs_before="$(fake_prs)"
out="$("$ORCH" pr publish 61 "Title" "$body" 2>&1)"; st=$?
assert_status "open tickets: pr publish refuses" "$st" 1
assert_contains "naming pr publish" "$out" \
  "orch: #61 still has open tickets: #$pt - run the driver loop (orch.sh ticket next 61) or close them, then run pr publish again"
assert_eq "and creates no PR" "$(fake_prs)" "$prs_before"
fake_fail adapter_sub_issues
out="$("$ORCH" pr publish 61 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish refuses when GitHub cannot be read" "$st" 1
assert_contains "naming the failure" "$out" "orch: gh could not list sub-issues of #61"
assert_eq "and creates no PR when GitHub cannot be read" "$(fake_prs)" "$prs_before"
fake_unfail
"$ORCH" ticket close "$pt" >/dev/null
out="$("$ORCH" pr publish 61 "Title" "$body" 2>&1)"; st=$?
assert_status "pr publish passes once the tickets are closed" "$st" 0

help="$("$ORCH" help)"
assert_contains "help documents --draft and --label" "$help" \
  "pr publish <issue> <title> <body-file> [--draft] [--label <name>]..."
restore_suite_env

# --- pr draft (#967) ----------------------------------------------------------
# Turns the current branch's open PR into a draft, for a standalone review pass
# that leaves a spec question unruled. Stateless, with pr comment's exit codes.
echo
echo "pr draft (#967)"
new_repo >/dev/null
git checkout -q -b quick/12-foo
fake_github
fake_pr 50 open quick/99-other main
fake_pr 51 closed quick/12-foo main
fake_pr 52 merged quick/12-foo main
errf="$(mktemp)"

out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "turning no closed or merged PR into a draft" \
  "$(fake_pr_draft_of 51)$(fake_pr_draft_of 52)" "nono"

fake_pr 57 open quick/12-foo main
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "turns the branch's open PR into a draft" "$st" 0
assert_eq "saying so" "$out" "PR #57 is now a draft"
assert_eq "the PR is a draft" "$(fake_pr_draft_of 57)" "yes"
assert_eq "the other branch's PR untouched" "$(fake_pr_draft_of 50)" "no"

out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "a PR already a draft exits 0" "$st" 0
assert_eq "saying so" "$out" "PR #57 is already a draft"
assert_eq "and stays a draft" "$(fake_pr_draft_of 57)" "yes"

rm -f "$ORCH_GH_FAKE_STORE/prs/57/draft"
fake_fail adapter_pr_draft $'HTTP 422: Draft pull requests are not supported in this repository.\nsecond line'
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "a failed conversion exits 2" "$st" 2
assert_eq "relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not turn PR #57 into a draft: HTTP 422: Draft pull requests are not supported in this repository."
assert_eq "leaving the PR ready" "$(fake_pr_draft_of 57)" "no"
fake_unfail
assert_gh_dies "an unreadable PR exits 2" adapter_pr_state_draft "$GH_502" 2 \
  "orch: gh could not read PR #57: HTTP 502: Bad Gateway" \
  "$ORCH" pr draft
fake_fail adapter_prs_open "$GH_502"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "an unreadable PR list exits 2" "$st" 2
fake_unfail

state_file="$(git rev-parse --show-toplevel)/.orchestrator/state.json"
mkdir -p "$(dirname "$state_file")"
for p in spec implement review; do
  printf '{"slug":"x","phase":"%s","issue":30,"branch":"quick/12-foo"}\n' "$p" >"$state_file"
  out="$("$ORCH" pr draft 2>"$errf")"; st=$?
  assert_status "a branch an active flow holds at $p is refused" "$st" 2
  assert_eq "with the flow-held message at $p" "$(cat "$errf")" \
    "orch: the active flow holds quick/12-foo at phase $p - its PR changes state only through the review loop"
  assert_eq "leaving the PR ready at $p" "$(fake_pr_draft_of 57)" "no"
done
printf '{"slug":"x","phase":"done","issue":30,"branch":"quick/12-foo"}\n' >"$state_file"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "a done flow on the branch lets it through" "$st" 0
printf '{"slug":"x","phase":"review","issue":12,"branch":"orch/12-x"}\n' >"$state_file"
rm -f "$ORCH_GH_FAKE_STORE/prs/57/draft"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "an active flow on another branch lets it through" "$st" 0
rm -f "$ORCH_GH_FAKE_STORE/prs/57/draft"
printf '{\n' >"$state_file"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_state_unreadable "a state.json that cannot be read (#1334)" 2 "$(cat "$errf")" "$st"
assert_eq "leaving the PR ready" "$(fake_pr_draft_of 57)" "no"
rm -f "$state_file"

out="$("$ORCH" pr draft extra 2>"$errf")"; st=$?
assert_status "an argument exits 2" "$st" 2
assert_eq "with its usage" "$(cat "$errf")" "orch: usage: orch.sh pr draft"
git checkout -q --detach
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "a detached HEAD exits 2" "$st" 2
assert_eq "saying so" "$(cat "$errf")" "orch: not on a branch (detached HEAD)"
rm -f "$errf"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr draft" "$help" "pr draft "

# --- pr ready (#967) ----------------------------------------------------------
# Marks the current branch's open PR ready, for a standalone review pass once
# every spec question holding it in draft is ruled. Stateless, with pr
# comment's exit codes.
echo
echo "pr ready (#967)"
new_repo >/dev/null
git checkout -q -b quick/12-foo
fake_github
fake_pr 50 open quick/99-other main
fake_pr_draft 50
fake_pr 51 closed quick/12-foo main
fake_pr_draft 51
fake_pr 52 merged quick/12-foo main
fake_pr_draft 52
errf="$(mktemp)"

out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "marking no closed or merged PR ready" \
  "$(fake_pr_draft_of 51)$(fake_pr_draft_of 52)" "yesyes"

fake_pr 57 open quick/12-foo main
fake_pr_draft 57
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "marks the branch's open draft PR ready" "$st" 0
assert_eq "saying so" "$out" "PR #57 is now ready"
assert_eq "the PR is no longer a draft" "$(fake_pr_draft_of 57)" "no"
assert_eq "the other branch's PR untouched" "$(fake_pr_draft_of 50)" "yes"

fake_checks_clear
fake_checks 57 required failing
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "a PR already ready exits 0" "$st" 0
assert_eq "saying so" "$out" "PR #57 is already ready"
assert_eq "reading no checks" "$(fake_checks_reads 57)" "0"

# The CI gate: one look at the head's checks before a draft turns ready.
gate_try() { # <required answer> <all answer>
  fake_checks_clear
  [ -z "$1" ] || fake_checks 57 required "$1"
  [ -z "$2" ] || fake_checks 57 all "$2"
  fake_pr_draft 57
  out="$("$ORCH" pr ready 2>"$errf")"; st=$?
}
gate_try failing ""
assert_status "a failed required check exits 2" "$st" 2
assert_contains "naming the check" "$(cat "$errf")" "orch: PR #57 has failed checks: build"
assert_eq "leaving the PR a draft" "$(fake_pr_draft_of 57)" "yes"
gate_try green ""
assert_status "green checks exit 0" "$st" 0
assert_eq "reading the checks once" "$(fake_checks_reads 57)" "1"
assert_eq "marking the PR ready" "$(fake_pr_draft_of 57)" "no"
gate_try comma ""
assert_status "a failing check named with a comma exits 2" "$st" 2
assert_eq "the name stays whole" "$(cat "$errf")" "orch: PR #57 has failed checks: build (linux, x64)"
gate_try pending ""
assert_status "a pending check exits 0" "$st" 0
assert_contains "noting it on stderr" "$(cat "$errf")" "checks are still pending"
assert_eq "marking the PR ready over pending" "$(fake_pr_draft_of 57)" "no"
gate_try boom ""
assert_status "unreachable checks exit 2" "$st" 2
assert_contains "relaying the reason" "$(cat "$errf")" "orch: PR #57 checks cannot be read: dial tcp: lookup api.github.com: no such host"
assert_eq "leaving the PR a draft when unreadable" "$(fake_pr_draft_of 57)" "yes"
gate_try "" ""
assert_status "no checks at all exit 0" "$st" 0
assert_eq "marking the PR ready with no checks" "$(fake_pr_draft_of 57)" "no"
gate_try none failing
assert_status "no required checks, every check failing, exits 2" "$st" 2
assert_eq "reading required, then every check" "$(fake_checks_reads 57)" "2"
assert_eq "leaving the PR a draft when all fail" "$(fake_pr_draft_of 57)" "yes"
gate_try none boom
assert_status "no required checks, every check unreachable, exits 2" "$st" 2
assert_contains "relaying the reason from all" "$(cat "$errf")" "dial tcp: lookup api.github.com: no such host"
assert_eq "leaving the PR a draft when all are unreadable" "$(fake_pr_draft_of 57)" "yes"
gate_try green failing
assert_status "green required beside a failing other check exits 0" "$st" 0
assert_eq "marking the PR ready beside a non-required failure" "$(fake_pr_draft_of 57)" "no"
fake_checks_clear

fake_pr_draft 57
fake_fail adapter_pr_ready $'HTTP 403: Resource not accessible by integration\nsecond line'
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "a failed promotion exits 2" "$st" 2
assert_eq "relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not mark PR #57 ready: HTTP 403: Resource not accessible by integration"
assert_eq "leaving the PR a draft" "$(fake_pr_draft_of 57)" "yes"
fake_unfail
assert_gh_dies "an unreadable PR exits 2" adapter_pr_state_draft "$GH_502" 2 \
  "orch: gh could not read PR #57: HTTP 502: Bad Gateway" \
  "$ORCH" pr ready

state_file="$(git rev-parse --show-toplevel)/.orchestrator/state.json"
mkdir -p "$(dirname "$state_file")"
for p in spec implement review; do
  printf '{"slug":"x","phase":"%s","issue":30,"branch":"quick/12-foo"}\n' "$p" >"$state_file"
  out="$("$ORCH" pr ready 2>"$errf")"; st=$?
  assert_status "a branch an active flow holds at $p is refused" "$st" 2
  assert_eq "with the flow-held message at $p" "$(cat "$errf")" \
    "orch: the active flow holds quick/12-foo at phase $p - its PR changes state only through the review loop"
  assert_eq "leaving the PR a draft at $p" "$(fake_pr_draft_of 57)" "yes"
done
printf '{\n' >"$state_file"
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_state_unreadable "a state.json that cannot be read (#1334)" 2 "$(cat "$errf")" "$st"
assert_eq "leaving the PR a draft" "$(fake_pr_draft_of 57)" "yes"
# doctor --flow's remedy for a done flow with a draft PR: the done flow's hold
# does not refuse, so the gate is what answers.
printf '{"slug":"x","phase":"done","issue":30,"branch":"quick/12-foo"}\n' >"$state_file"
fake_checks_clear
fake_checks 57 required failing
fake_pr_draft 57
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "a done flow's branch gets past the guard and is refused at the gate" "$st" 2
assert_contains "naming the failed checks" "$(cat "$errf")" "has failed checks"
assert_eq "leaving the PR a draft behind a done flow" "$(fake_pr_draft_of 57)" "yes"
fake_checks_clear
rm -f "$state_file"

out="$("$ORCH" pr ready extra 2>"$errf")"; st=$?
assert_status "an argument exits 2" "$st" 2
assert_eq "with its usage" "$(cat "$errf")" "orch: usage: orch.sh pr ready"
rm -f "$errf"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr ready" "$help" "pr ready "

# --- pr: unknown op -----------------------------------------------------------
new_repo >/dev/null
out="$("$ORCH" pr bogus 2>&1)"; st=$?
assert_status "pr bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown pr op"
assert_contains "naming both" "$out" "open|publish"

# --- pr release ---------------------------------------------------------------
# The release PR carries the base branch back into the default branch and
# closes every still-open issue whose work reached it - read from the bodies of
# the PRs merged into the base branch, never remembered by a human. Every
# GitHub call goes through the store-backed fake; the real operations are
# pinned in "gh adapter contract".
echo
echo "pr release"
new_repo >/dev/null
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
body="$(mktemp)"
writeln '## Summary' '' 'Ships the uat project.' '' 'Some detail.' >"$body"
release() { orch_gh_failing pr release "$@"; }
# The issues the merged PRs below refer to: #3 and #8 already closed, #62 a
# pull request, not an issue.
fake_github
for n in 5 6 7 9; do fake_issue "$n" open; done
fake_issue 3 closed
fake_issue 8 closed
fake_pull 62

out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses when the base branch is the default branch" "$st" 1
assert_contains "naming it" "$out" "main"
assert_eq "and opens no PR" "$(fake_prs)" ""
summaryless="$(mktemp)"
writeln 'Ships the uat project.' >"$summaryless"
out="$(release "Release" "$summaryless" 2>&1)"; st=$?
assert_eq "the base branch is checked before the body's standard" "$out" \
  "orch: the base branch is the default branch (main) - there is nothing to release; set another with base set"

orch_gh_failing base set uat >/dev/null
# Open PRs that are not a release PR: from uat into another base, and from
# another branch into main.
fake_pr 55 open uat staging
fake_pr 56 open topic main
fake_pr 57 open uat main
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses while a release PR is already open" "$st" 1
assert_contains "printing that PR's number" "$out" "#57"
assert_eq "and opens no second one" "$(fake_prs)" "55 56 57 "
out="$(release "Release" "$summaryless" 2>&1)"; st=$?
assert_eq "an open release PR is checked before the body's standard" "$out" \
  "orch: a release PR from uat into main is already open: #57"
assert_gh_dies "a failed open-PR list exits 1" adapter_prs_open "$GH_502" 1 \
  "orch: gh could not list the open PRs from uat into main: HTTP 502: Bad Gateway" \
  release "Release" "$body"
fake_pr 57 closed uat main
fake_fail adapter_prs_merged_bodies "HTTP 502: Bad Gateway"
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "with the release PR closed, only open PRs from uat into main counted" "$st" 1
assert_contains "it goes on to read the merged PRs" "$out" "gh could not list the PRs merged into uat"
assert_gh_dies "a failed merged-PR list exits 1" adapter_prs_merged_bodies "$GH_502" 1 \
  "orch: gh could not list the PRs merged into uat: HTTP 502: Bad Gateway" \
  release "Release" "$body"
rm -rf "$ORCH_GH_FAKE_STORE/prs"

# Every reference the merged PRs make is to an issue that is already closed.
# A PR merged into another base refers to an open issue, and does not count.
fake_pr 60 merged topic uat
fake_pr_body 60 "Refs #3"
fake_pr 61 merged topic uat
fake_pr_body 61 "No references here."
fake_pr 66 merged topic main
fake_pr_body 66 "Closes #5"
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "refuses when no referenced issue is still open" "$st" 1
assert_contains "saying there is nothing to close" "$out" "nothing to close"
out="$(release "Release" "$summaryless" 2>&1)"; st=$?
assert_eq "nothing to close is checked before the body's standard" "$out" \
  "orch: nothing to close: no PR merged into uat refers to a still-open issue - pass --force to release anyway"
assert_eq "and opens no PR" "$(fake_prs)" "60 61 66 "

fake_next_pr 70
out="$(release --force "Release" "$body" 2>&1)"; st=$?
assert_status "--force releases with nothing to close" "$st" 0
assert_eq "printing the PR number" "$out" "70"
assert_eq "with the caller's body alone" "$(fake_pr_body_of 70)" "$(cat "$body")"
rm -rf "$ORCH_GH_FAKE_STORE/prs"

# Hand-written PRs into uat count too: every keyword, in any case, anywhere in
# the body. #5 is referenced twice and #8 is already closed. Other closing
# forms (fix, closed) are prose, not references, and #62 is an open PR, not
# an issue.
fake_pr 62 merged topic uat
fake_pr_body 62 $'Refs #5\n\nImplements it.'
fake_pr 63 merged topic uat
fake_pr_body 63 $'Summary first.\n\nThis closes #6 and FIXES #7.'
fake_pr 64 merged topic uat
fake_pr_body 64 $'resolves #9\nAlso Refs #5, and Closes #8.\nIt prefixes #4 with nothing.'
fake_pr 65 merged topic uat
fake_pr_body 65 'A quick fix #12, closed #13. Refs #62, an open PR.'
fake_next_pr 71
out="$(release "Release uat" "$body" 2>&1)"; st=$?
assert_status "opens the release PR" "$st" 0
assert_eq "prints its number" "$out" "71"
assert_eq "one Closes line per still-open issue, deduplicated, above the caller's body" \
  "$(fake_pr_body_of 71)" "$(writeln 'Closes #5' 'Closes #6' 'Closes #7' 'Closes #9' '' '## Summary' '' 'Ships the uat project.' '' 'Some detail.')"
assert_eq "from the base branch" "$(fake_pr_head_of 71)" "uat"
assert_eq "into the default branch" "$(fake_pr_base_of 71)" "main"
assert_eq "with the caller's title" "$(fake_pr_title_of 71)" "Release uat"
assert_eq "not as a draft" "$(fake_pr_draft_of 71)" "no"
assert_eq "and pushes nothing" "$(git -C "$bare" for-each-ref --format='%(refname)' | sort | tr '\n' ' ')" \
  "refs/heads/main refs/heads/uat "

fake_pr 71 closed uat main
fake_fail adapter_pr_create
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "naming both branches" "$out" "from uat into main"
assert_gh_dies "a failed release-PR open exits 1" adapter_pr_create "$GH_502" 1 \
  "orch: gh could not open the release PR from uat into main: HTTP 502: Bad Gateway" \
  release "Release" "$body"
# The state read for each issue on a Closes line: #5 is the first referenced.
assert_gh_dies "a failed Closes-line state read exits 1" adapter_issue_state "$GH_502" 1 \
  "orch: gh could not read the state of issue #5: HTTP 502: Bad Gateway" \
  release "Release" "$body"
assert_eq "opening no PR" "$(fake_prs)" "62 63 64 65 71 "

# The PR-writing standard (#1387): a release PR needs ## Summary and nothing
# more, and --force, which only overrides "nothing to close", still checks it.
fake_pr 71 closed uat main
summaryless="$(mktemp)"
writeln 'Ships the uat project.' '' '## Evidence' '' 'make test - pass' >"$summaryless"
out="$(release "Release" "$summaryless" 2>&1)"; st=$?
assert_status "a body without ## Summary is refused" "$st" 1
assert_eq "naming it" "$out" "$PR_BODY_REFUSED no ## Summary heading"
out="$(release --force "Release" "$summaryless" 2>&1)"; st=$?
assert_status "--force: a body without ## Summary is still refused" "$st" 1
assert_eq "--force: naming it" "$out" "$PR_BODY_REFUSED no ## Summary heading"
assert_eq "opening no PR" "$(fake_prs)" "62 63 64 65 71 "
summary_only="$(mktemp)"
writeln '## Summary' '' 'Ships the uat project.' >"$summary_only"
fake_next_pr 72
out="$(release "Release" "$summary_only" 2>&1)"; st=$?
assert_status "a body with only ## Summary opens the release PR" "$st" 0
assert_eq "printing its number" "$out" "72"

out="$(release "Release" 2>&1)"; st=$?
assert_status "refuses a missing body file argument" "$st" 1
assert_contains "with its usage" "$out" "pr release [--force] <title> <body-file>"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- pr comment (#343) --------------------------------------------------------
# A stateless post on the current branch's open PR, so a standalone review pass
# records its declines without calling gh itself. Three outcomes, like ticket
# exists: 0 posted (printing the PR), 1 only for no open PR, 2 for the rest.
echo
echo "pr comment (#343)"
new_repo >/dev/null
git checkout -q -b quick/12-foo
body="$(mktemp)"
writeln '## Review' '' '- `a.sh:3` - declined: out of scope.' >"$body"
prc() { "$ORCH" pr comment "$@"; }
fake_github
# Open PRs that are not this branch's: one from another branch, and a closed
# one from this branch.
fake_pr 50 open quick/99-other main
fake_pr 51 closed quick/12-foo main

out="$(prc "$body" 2>/dev/null)"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "and posts nothing" "$(fake_pr_comments_of 50)$(fake_pr_comments_of 51)" ""

fake_pr 57 open quick/12-foo main
out="$(prc "$body" 2>&1)"; st=$?
assert_status "posts on the branch's open PR" "$st" 0
assert_eq "printing the PR number" "$out" "57"
assert_eq "commenting on that PR, with the file's contents" "$(fake_pr_comments_of 57)" "$(cat "$body")"

fake_fail adapter_prs_open
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a GitHub that cannot be read exits 2" "$st" 2
[ -n "$err" ] && ok "with a reason on stderr" || bad "with a reason on stderr" "stderr was empty"
fake_unfail

fake_fail adapter_pr_comment
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a failed post exits 2" "$st" 2
assert_contains "naming the PR" "$err" "#57"
fake_unfail

err="$(prc /nonexistent/body.md 2>&1 >/dev/null)"; st=$?
assert_status "a missing file exits 2" "$st" 2
assert_contains "naming it" "$err" "/nonexistent/body.md"

err="$(prc 2>&1 >/dev/null)"; st=$?
assert_status "no file argument exits 2" "$st" 2
assert_contains "with its usage" "$err" "usage: orch.sh pr comment <file>"

git checkout -q --detach
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a detached HEAD exits 2" "$st" 2
assert_contains "saying so" "$err" "detached HEAD"

# Each exit-2 failure pinned byte for byte: the exact stderr line with its
# `orch: ` prefix, exit 2, and nothing on stdout (#347). Where gh itself
# failed, the fake's own complaint precedes it, so orch's line is the last.
errf="$(mktemp)"
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "detached HEAD: exit 2" "$st" 2
assert_eq "detached HEAD: exact stderr" "$(cat "$errf")" "orch: not on a branch (detached HEAD)"
assert_eq "detached HEAD: empty stdout" "$out" ""
git checkout -q quick/12-foo

out="$(prc 2>"$errf")"; st=$?
assert_status "no file argument: exit 2" "$st" 2
assert_eq "no file argument: exact stderr" "$(cat "$errf")" "orch: usage: orch.sh pr comment <file>"
assert_eq "no file argument: empty stdout" "$out" ""

out="$(prc /nonexistent/body.md 2>"$errf")"; st=$?
assert_status "missing file: exit 2" "$st" 2
assert_eq "missing file: exact stderr" "$(cat "$errf")" "orch: body file not found: /nonexistent/body.md"
assert_eq "missing file: empty stdout" "$out" ""

fake_fail adapter_prs_open
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "unreadable PR list: exit 2" "$st" 2
assert_eq "unreadable PR list: exact stderr" "$(cat "$errf")" "orch: gh could not list the open PRs from quick/12-foo: fake gh: adapter_prs_open failed"
assert_eq "unreadable PR list: empty stdout" "$out" ""
fake_unfail

fake_fail adapter_pr_comment
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "failed post: exit 2" "$st" 2
assert_eq "failed post: exact stderr" "$(cat "$errf")" "orch: gh could not comment on PR #57: fake gh: adapter_pr_comment failed"
assert_eq "failed post: empty stdout" "$out" ""
fake_unfail

# gh's reason rides on orch's own line, first line only (#846).
assert_gh_dies "unreadable PR list with a reason: exit 2" adapter_prs_open "$GH_502" 2 \
  "orch: gh could not list the open PRs from quick/12-foo: HTTP 502: Bad Gateway" \
  prc "$body"
assert_gh_dies "failed post with a reason: exit 2" adapter_pr_comment "$GH_502" 2 \
  "orch: gh could not comment on PR #57: HTTP 502: Bad Gateway" \
  prc "$body"
assert_gh_dies "a silent failed post: exit 2" adapter_pr_comment '' 2 \
  "orch: gh could not comment on PR #57: gh gave no reason" \
  prc "$body"
rm -f "$errf"
assert_eq "no failed call posted anything" "$(fake_pr_comments_of 57)" "$(cat "$body")"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr comment" "$help" "pr comment <file>"

# --- pr fetch / pr update (#444) ----------------------------------------------
# The PR counterpart of issue fetch/update, on the current branch's open PR, so
# the fixer corrects a PR body without calling gh itself. pr update refuses a
# body that would drop the Closes/Refs line pr open/pr publish wrote.
echo
echo "pr fetch / pr update (#444)"
new_repo >/dev/null
git checkout -q -b orch/12-foo
fake_github
prb() { "$ORCH" pr "$@"; }
# set_pr_body <line>...: PR #57's body, one line each, as writeln writes it.
set_pr_body() { fake_pr_body 57 "$(writeln "$@")"$'\n'; }

out_file="$(mktemp -d)/body.md"
out="$(prb fetch "$out_file" 2>&1)"; st=$?
assert_status "pr fetch with no open PR fails" "$st" 1
assert_contains "saying so" "$out" "no open PR"
newbody="$(mktemp)"
writeln 'Closes #12' '' 'Adds nothing new.' >"$newbody"
out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update with no open PR fails" "$st" 1

fake_pr 56 open orch/99-other main
fake_pr_body 56 "Closes #99"
fake_pr 57 open orch/12-foo main
set_pr_body 'Closes #12' '' 'Adds `quote_meta`, needed for meta#ts.'
out="$(prb fetch "$out_file" 2>&1)"; st=$?
assert_status "pr fetch succeeds" "$st" 0
assert_eq "pr fetch writes the current branch's open PR's body to the file" \
  "$(cat "$out_file")" "$(writeln 'Closes #12' '' 'Adds `quote_meta`, needed for meta#ts.')"

out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update succeeds" "$st" 0
assert_eq "pr update replaces that PR's body with the file" "$(fake_pr_body_of 57)" "$(cat "$newbody")"
assert_eq "and no other" "$(fake_pr_body_of 56)" "Closes #99"
prb fetch "$out_file" >/dev/null 2>&1
assert_eq "a fetch after the update reads the new body back" "$(cat "$out_file")" "$(cat "$newbody")"

fake_pr_body 57 $'Closes #12\r\n\r\nAlpha line.\r\nBeta line.\r\n'
prb fetch "$out_file" >/dev/null 2>&1
assert_eq "pr fetch of a CRLF body writes the same text with LF line endings and no CR" \
  "$(od -c <"$out_file")" "$(printf 'Closes #12\n\nAlpha line.\nBeta line.\n\n' | od -c)"
fake_pr_body 57 $'Closes #12\r\nBeta line.'
prb fetch "$out_file" >/dev/null 2>&1
assert_eq "a CRLF body with no final line ending ends as an LF one does" \
  "$(od -c <"$out_file")" "$(printf 'Closes #12\nBeta line.\n' | od -c)"

set_pr_body 'Refs #12' '' 'Into uat.'
writeln 'Refs #12' '' 'Into uat, corrected.' >"$newbody"
out="$(prb update "$newbody" 2>&1)"; st=$?
assert_status "pr update keeps a Refs line too" "$st" 0
assert_eq "replacing the body" "$(fake_pr_body_of 57)" "$(cat "$newbody")"

set_pr_body 'Closes #12' '' 'Original body.'
before="$(fake_pr_body_of 57)"
for bad_first in 'Adds nothing new.' 'Closes #13' 'Refs #12' ''; do
  { printf '%s\n' "$bad_first"; printf '\nCorrected body.\n'; } >"$newbody"
  err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
  assert_status "pr update refuses a first line of '$bad_first'" "$st" 1
  assert_eq "leaving the body unchanged ('$bad_first')" "$(fake_pr_body_of 57)" "$before"
  assert_contains "naming the line it must keep ('$bad_first')" "$err" "Closes #12"
done

set_pr_body 'Hand-edited, no issue line.'
writeln 'Hand-edited, no issue line.' '' 'More.' >"$newbody"
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "pr update refuses when the PR's body has no Closes/Refs first line" "$st" 1
assert_eq "leaving that body unchanged" "$(fake_pr_body_of 57)" "$(writeln 'Hand-edited, no issue line.')"

set_pr_body 'Closes #12'
err="$(prb update /nonexistent/body.md 2>&1 >/dev/null)"; st=$?
assert_status "pr update refuses a missing file" "$st" 1
assert_contains "naming it" "$err" "/nonexistent/body.md"

err="$(prb fetch 2>&1 >/dev/null)"; st=$?
assert_status "pr fetch with no file argument fails" "$st" 1
assert_contains "with its usage" "$err" "usage: orch.sh pr fetch <file>"
err="$(prb update 2>&1 >/dev/null)"; st=$?
assert_contains "pr update with no file argument gives its usage" "$err" "usage: orch.sh pr update <file>"

writeln 'Closes #12' '' 'x' >"$newbody"
fake_fail adapter_pr_body_edit
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "a failed edit fails" "$st" 1
assert_contains "naming the PR" "$err" "#57"
# gh's reason rides on orch's own line, first line only (#846).
assert_gh_dies "a failed body write still exits 1" adapter_pr_body_edit "$GH_502" 1 \
  "orch: gh could not replace the body of PR #57: HTTP 502: Bad Gateway" \
  prb update "$newbody"
assert_gh_dies "a failed body read in pr update exits 1" adapter_pr_body "$GH_502" 1 \
  "orch: gh could not read the body of PR #57: HTTP 502: Bad Gateway" \
  prb update "$newbody"
assert_gh_dies "a silent failed body read exits 1" adapter_pr_body '' 1 \
  "orch: gh could not read the body of PR #57: gh gave no reason" \
  prb update "$newbody"
assert_gh_dies "a failed read fails" adapter_pr_body "$GH_502" 1 \
  "orch: gh could not read the body of PR #57: HTTP 502: Bad Gateway" \
  prb fetch "$out_file"
assert_eq "leaving the body as it was" "$(fake_pr_body_of 57)" "$(writeln 'Closes #12')"
assert_eq "leaving the target untouched" "$(cat "$out_file")" "$(writeln "Closes #12" "Beta line.")"
assert_eq "and no temp file beside it" "$(ls "$(dirname "$out_file")" | tr '\n' ' ')" "body.md "
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr fetch" "$help" "pr fetch <file>"
assert_contains "help documents pr update" "$help" "pr update <file>"

# --- pr comments (#418) -------------------------------------------------------
# Every comment on the current branch's open PR, in issue comments' format, so a
# standalone review pass reads earlier passes' declines without calling gh
# itself. Three outcomes, like pr comment: 0 written, 1 only for no open PR, 2
# when GitHub cannot be read.
echo
echo "pr comments (#418)"
new_repo >/dev/null
git checkout -q -b quick/18-foo
prcs() { "$ORCH" pr comments "$@"; }
fake_github
pr_comments="$(mktemp -d)/comments.md"

printf 'known content\n' >"$pr_comments"
fake_pr 56 open quick/99-other main
fake_pr_comment 56 pat 2026-10-01T09:00:00Z "Not this one."
out="$(prcs "$pr_comments" 2>/dev/null)"; st=$?
assert_status "no open PR exits 1" "$st" 1
assert_eq "printing nothing" "$out" ""
assert_eq "and writing nothing" "$(cat "$pr_comments")" "known content"

fake_pr 57 open quick/18-foo main
out="$(prcs "$pr_comments" 2>&1)"; st=$?
assert_status "a PR with no comments still succeeds" "$st" 0
assert_eq "leaving an empty file" "$(wc -c <"$pr_comments" | tr -d ' ')" "0"

fake_pr_comment 57 pat 2026-10-01T09:00:00Z $'## Review\n\n- `a.sh:3` - unused helper - declined: out of scope.\n\n## Host fallbacks\n\nNone.'
fake_pr_comment 57 bot 2026-10-02T10:00:00Z "LGTM"
out="$(prcs "$pr_comments" 2>&1)"; st=$?
assert_status "pr comments writes the current branch's open PR's comments" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "in issue comments' format: each opened by its author-and-date marker" \
  "$(cat "$pr_comments")" "$(writeln '<!-- comment @pat 2026-10-01T09:00:00Z -->' \
    '## Review' '' '- `a.sh:3` - unused helper - declined: out of scope.' '' '## Host fallbacks' '' 'None.' '' \
    '<!-- comment @bot 2026-10-02T10:00:00Z -->' 'LGTM')"

# Untrusted authors (#1903): left out, no placeholder; one stderr line says how
# many, and only when some were dropped.
fake_pr_comment 57 rando 2026-10-03T09:00:00Z "Stranger note." NONE
out="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "pr comments succeeds past an untrusted author" "$st" 0
assert_eq "saying how many it ignored" "$out" "orch: ignored 1 comment(s) from untrusted authors on #57"
assert_not_contains "and leaving the stranger's comment out" "$(cat "$pr_comments")" "Stranger"
assert_not_contains "with no placeholder for it" "$(cat "$pr_comments")" "rando"
rm -rf "$ORCH_GH_FAKE_STORE/prs/57/comments/3"
out="$(prcs "$pr_comments" 2>&1 >/dev/null)"
assert_eq "no stderr line when none was dropped" "$out" ""

printf 'known content\n' >"$pr_comments"
fake_fail adapter_prs_open
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "an unreadable PR list exits 2" "$st" 2
assert_eq "and writes nothing" "$(cat "$pr_comments")" "known content"
fake_unfail

assert_gh_dies "unreadable comments exit 2" adapter_pr_comments "$GH_502" 2 \
  "orch: gh could not read the comments of PR #57: HTTP 502: Bad Gateway" \
  prcs "$pr_comments"
assert_eq "leaving the file that was already there unchanged" "$(cat "$pr_comments")" "known content"
assert_gh_dies "comments that fail silently exit 2 too" adapter_pr_comments '' 2 \
  "orch: gh could not read the comments of PR #57: gh gave no reason" \
  prcs "$pr_comments"

err="$(adapter_stood_in 'adapter_pr_comments() { printf "not json\n"; }' prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "a comment object that does not parse exits 2" "$st" 2
assert_eq "naming the PR and its cause" "$err" "orch: could not read the comments of PR #57: its comments did not parse"
assert_eq "leaving the file that was already there unchanged too" "$(cat "$pr_comments")" "known content"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

err="$(prcs 2>&1 >/dev/null)"; st=$?
assert_status "no file argument exits 2" "$st" 2
assert_contains "with its usage" "$err" "usage: orch.sh pr comments <file>"

assert_contains "help documents pr comments" "$("$ORCH" help)" "pr comments <file>"
rm -f "$pr_comments"

# --- pr read (#1573) ----------------------------------------------------------
# The body and diff of the open PR that closes or refers to an issue, for a
# review-phase question's context.
echo
echo "pr read"
new_repo >/dev/null
fake_github
out_file="$(mktemp -d)/pr.md"
out="$("$ORCH" pr read 12 "$out_file" 2>&1)"; st=$?
assert_status "pr read with no PR for the issue fails" "$st" 1
assert_contains "saying so" "$out" "no open PR"
fake_pr 56 open orch/99-other main
fake_pr_body 56 $'Closes #99\n\nNot this one.\n'
fake_pr 57 open orch/12-foo main
fake_pr_body 57 $'Refs #12\n\nAdds the widget.\n'
printf 'diff --git a/w b/w\n+widget\n' >"$ORCH_GH_FAKE_STORE/prs/57/diff"
fake_pr 58 open orch/120-bar main
fake_pr_body 58 $'Closes #120\n'
out="$("$ORCH" pr read 12 "$out_file" 2>&1)"; st=$?
assert_status "pr read finds the PR whose issue line names the issue" "$st" 0
assert_eq "writing its body, a rule, then its diff" "$(cat "$out_file")" \
  "$(printf 'Refs #12\n\nAdds the widget.\n\n---\ndiff --git a/w b/w\n+widget')"
# One listing carries every body: no single-body read is needed, and a second
# listing is never made.
fake_fail adapter_pr_body "HTTP 500"
fake_fail_after adapter_prs_open_bodies 1
out="$("$ORCH" pr read 12 "$out_file" 2>&1)"; st=$?
fake_unfail
assert_status "pr read with no single-body read and one listing still succeeds" "$st" 0
assert_eq "writing the same body, rule and diff" "$(cat "$out_file")" \
  "$(printf 'Refs #12\n\nAdds the widget.\n\n---\ndiff --git a/w b/w\n+widget')"
out="$("$ORCH" pr read 12 2>&1)"; st=$?
assert_status "pr read without a file fails" "$st" 1
assert_contains "with its usage" "$out" "usage: orch.sh pr read <issue> <file>"
err="$(adapter_stood_in 'adapter_prs_open_bodies() { printf "57\t\"Refs #12\"\ttrue\n58\t\"x\"\t\n"; }' "$ORCH" pr read 12 "$out_file" 2>&1 >/dev/null)"; st=$?
assert_status "an unreadable fork flag on any listed line fails" "$st" 1
assert_contains "naming the issue" "$err" "orch: the open PRs for issue #12 could not be read"
err="$(adapter_stood_in 'adapter_prs_open_bodies() { printf "57\tnot json\tfalse\n"; }' "$ORCH" pr read 12 "$out_file" 2>&1 >/dev/null)"; st=$?
assert_status "an undecodable body fails" "$st" 1
assert_contains "naming the issue too" "$err" "orch: the open PRs for issue #12 could not be read"
assert_contains "leaving the existing file untouched" "$(cat "$out_file")" "Adds the widget."
fake_fail adapter_prs_open_bodies "HTTP 502"
out="$("$ORCH" pr read 12 "$out_file" 2>&1)"; st=$?
assert_status "a failed listing fails" "$st" 1
assert_contains "naming the step" "$out" "gh could not list the open PRs"
case "$out" in *"no open PR"*) bad "never as no PR" "" ;; *) ok "never as no PR" ;; esac
fake_unfail
# A first line ending in a carriage return still matches; of two same-repo
# PRs naming the issue the newer is written; a hard body is byte for byte.
fake_pr 70 open orch/13-a main
fake_pr_body 70 $'Closes #13\r\n\r\nOlder.\n'
fake_pr 71 open orch/13-b main
fake_pr_body 71 $'Closes #13\r\n\tTab \\ "q" caf\xc3\xa9 \xe2\x9c\x93\n'
printf 'diff --git a/n b/n\n+newer\n' >"$ORCH_GH_FAKE_STORE/prs/71/diff"
out="$("$ORCH" pr read 13 "$out_file" 2>&1)"; st=$?
assert_status "pr read matches a CRLF first line" "$st" 0
assert_eq "writing the newer PR's body byte for byte, then its diff" "$(cat "$out_file")" \
  "$(printf 'Closes #13\r\n\tTab \\ "q" caf\xc3\xa9 \xe2\x9c\x93\n\n---\ndiff --git a/n b/n\n+newer')"
fake_fail adapter_pr_diff "HTTP 502"
out="$("$ORCH" pr read 12 "$out_file" 2>&1)"; st=$?
assert_status "a failed diff read fails" "$st" 1
fake_unfail
help="$("$ORCH" help)"
assert_contains "help documents pr read" "$help" "pr read <issue> <file>"
restore_suite_env

# --- pr: fork PRs (#1977) -----------------------------------------------------
# A PR whose head branch lives in a fork (isCrossRepository) is never taken for
# the plugin's own: every lookup by head branch drops it, with one stderr line.
echo
echo "pr: fork PRs (#1977)"
new_repo >/dev/null
git checkout -q -b orch/12-foo
fake_github
forkline="orch: ignored 1 PR(s) from forks for orch/12-foo"
fk_out="$(mktemp -d)/body.md"
fk_new="$(mktemp)"
writeln 'Closes #12' '' 'Corrected.' >"$fk_new"
fk_comment="$(mktemp)"
printf 'a note\n' >"$fk_comment"
fk_comments="$(mktemp)"
errf="$(mktemp)"

# Only a fork PR stands: "no open PR", and the fork PR is left untouched.
fake_pr 60 open orch/12-foo main
fake_pr_cross 60
fake_pr_body 60 $'Closes #12\n\nStranger.'
fake_pr_draft 60
before="$(fake_snapshot)"
for c in "update $fk_new" "comment $fk_comment" "draft" "ready"; do
  # shellcheck disable=SC2086
  out="$("$ORCH" pr $c 2>"$errf")"; st=$?
  assert_status "pr ${c%% *}: only a fork PR exits 1" "$st" 1
  assert_eq "pr ${c%% *}: printing nothing" "$out" ""
  [ "${c%% *}" != update ] || assert_contains "pr update: saying no open PR" "$(cat "$errf")" "no open PR"
done
assert_eq "the fork PR's body, comments and draft state untouched" "$(fake_snapshot)" "$before"
out="$("$ORCH" pr fetch "$fk_out" 2>&1)"; st=$?
assert_status "pr fetch: only a fork PR exits 1" "$st" 1
assert_contains "pr fetch: saying no open PR" "$out" "no open PR"

# A newer fork PR beside the same-repo one: the command acts on the latter.
fake_pr 57 open orch/12-foo main
fake_pr_body 57 $'Closes #12\n\nMine.'
fake_pr_draft 57
fake_pr_comment 57 pat 2026-10-01T09:00:00Z "Mine too."
fake_pr_comment 60 pat 2026-10-02T09:00:00Z "Stranger comment."
fake_pr_draft 60
out="$("$ORCH" pr fetch "$fk_out" 2>"$errf")"; st=$?
assert_status "pr fetch beside a newer fork PR succeeds" "$st" 0
assert_eq "reading the same-repo PR's body" "$(cat "$fk_out")" $'Closes #12\n\nMine.'
assert_eq "and saying one fork PR was ignored" "$(cat "$errf")" "$forkline"

out="$("$ORCH" pr update "$fk_new" 2>"$errf")"; st=$?
assert_status "pr update beside a newer fork PR succeeds" "$st" 0
assert_eq "overwriting the same-repo PR's body" "$(fake_pr_body_of 57)" "$(cat "$fk_new")"
assert_eq "and not the fork PR's" "$(fake_pr_body_of 60)" $'Closes #12\n\nStranger.'

out="$("$ORCH" pr comment "$fk_comment" 2>"$errf")"; st=$?
assert_status "pr comment beside a newer fork PR succeeds" "$st" 0
assert_eq "printing the same-repo PR's number" "$out" "57"
assert_eq "posting nothing on the fork PR" "$(fake_pr_comments_of 60)" "Stranger comment."

out="$("$ORCH" pr comments "$fk_comments" 2>"$errf")"; st=$?
assert_status "pr comments beside a newer fork PR succeeds" "$st" 0
assert_contains "reading the same-repo PR's comments" "$(cat "$fk_comments")" "Mine too."
assert_not_contains "and not the fork PR's" "$(cat "$fk_comments")" "Stranger"

out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "pr ready beside a newer fork PR succeeds" "$st" 0
assert_eq "marking the same-repo PR ready" "$(fake_pr_draft_of 57)" "no"
assert_eq "and not the fork PR" "$(fake_pr_draft_of 60)" "yes"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "pr draft beside a newer fork PR succeeds" "$st" 0
assert_eq "drafting the same-repo PR" "$(fake_pr_draft_of 57)" "yes"

# Two same-repo PRs and a newer fork PR: the newer same-repo PR wins.
fake_pr 58 open orch/12-foo main
fake_pr_body 58 $'Closes #12\n\nNewer mine.'
fake_pr 61 open orch/12-foo main
fake_pr_cross 61
fake_pr_body 61 "Closes #12"
out="$("$ORCH" pr fetch "$fk_out" 2>"$errf")"; st=$?
assert_eq "pr fetch reads the newest same-repo PR" "$(cat "$fk_out")" $'Closes #12\n\nNewer mine.'

rm -rf "$ORCH_GH_FAKE_STORE/prs/60" "$ORCH_GH_FAKE_STORE/prs/61"

# A flag that is neither true nor false: the filter's own rule is in trust.sh;
# here only the command's exit code.
fake_pr_cross 58 maybe
printf 'known content\n' >"$fk_comments"
out="$("$ORCH" pr comments "$fk_comments" 2>"$errf")"; st=$?
assert_status "pr comments with an unreadable flag exits 2" "$st" 2
assert_eq "writing nothing" "$(cat "$fk_comments")" "known content"
fake_pr_cross 58 false

# pr read: a fork PR opening with the issue line is ignored.
rm -rf "$ORCH_GH_FAKE_STORE/prs"/*
rd_file="$(mktemp -d)/pr.md"
fake_pr 70 open orch/12-foo main
fake_pr_body 70 $'Closes #12\n\nMine.'
printf 'mine diff\n' >"$ORCH_GH_FAKE_STORE/prs/70/diff"
fake_pr 71 open stranger/main main
fake_pr_cross 71
fake_pr_body 71 $'Closes #12\n\nStranger.'
out="$("$ORCH" pr read 12 "$rd_file" 2>"$errf")"; st=$?
assert_status "pr read beside a newer fork PR succeeds" "$st" 0
assert_contains "reading the same-repo PR" "$(cat "$rd_file")" "Mine."
assert_not_contains "and not the fork PR" "$(cat "$rd_file")" "Stranger"
assert_eq "saying one fork PR was ignored for the issue" "$(cat "$errf")" "orch: ignored 1 PR(s) from forks for #12"
rm -rf "$ORCH_GH_FAKE_STORE/prs/70"
out="$("$ORCH" pr read 12 "$rd_file" 2>&1)"; st=$?
assert_status "pr read with only the fork PR fails" "$st" 1
assert_contains "with the unchanged message" "$out" "orch: no open PR closes or refers to issue #12"
fake_pr_body 71 $'Closes #99\n\nStranger.'
out="$("$ORCH" pr read 12 "$rd_file" 2>&1)"; st=$?
assert_not_contains "a fork PR naming another issue: no ignored line" "$out" "ignored"

# pr release: a fork's release PR does not block, a same-repo one does.
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin HEAD:refs/heads/main HEAD:refs/heads/uat
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
orch_gh_failing base set uat >/dev/null
fk_rel="$(mktemp)"
writeln '## Summary' '' 'Ships uat.' >"$fk_rel"
rm -rf "$ORCH_GH_FAKE_STORE/prs"
fake_pr 57 open uat main
fake_pr_cross 57 maybe
out="$(orch_gh_failing pr release --force Release "$fk_rel" 2>&1)"; st=$?
assert_status "pr release with an unreadable flag fails" "$st" 1
assert_eq "opening no release PR" "$(fake_prs)" "57 "
fake_pr_cross 57
fake_next_pr 70
out="$(orch_gh_failing pr release --force Release "$fk_rel" 2>"$errf")"; st=$?
assert_status "pr release opens the release PR past a fork's" "$st" 0
assert_eq "printing its number" "$out" "70"
assert_eq "saying one fork PR was ignored" "$(cat "$errf")" "orch: ignored 1 PR(s) from forks for uat"
fake_pr 57 open uat main
out="$(orch_gh_failing pr release --force Release "$fk_rel" 2>&1)"; st=$?
assert_status "pr release still refuses on a same-repo release PR" "$st" 1
assert_eq "with its unchanged message and no ignored line" "$out" \
  "orch: a release PR from uat into main is already open: #70"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"
restore_suite_env
