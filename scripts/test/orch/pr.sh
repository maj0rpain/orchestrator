# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fake_pull <n>: seeds #n as an open pull request, which gh's issue reads
# answer for too.
fake_pull() { fake_issue "$1" open; : >"$ORCH_GH_FAKE_STORE/issues/$1/pull"; }

# fake_pr_body <n> <text>: seeds PR #n's body, byte for byte.
fake_pr_body() { printf '%s' "$2" >"$ORCH_GH_FAKE_STORE/prs/$1/body"; }

# fake_pr_comment <n> <author> <created-at> <body>: seeds a comment on PR #n,
# after any it has.
fake_pr_comment() { fake_comment_seed "$ORCH_GH_FAKE_STORE/prs/$1/comments" "$2" "$3" "$4"; }

# fake_prs: every PR number the store holds, in order, space-separated.
fake_prs() { ls "$ORCH_GH_FAKE_STORE/prs" 2>/dev/null | sort -n | tr '\n' ' '; }

# PR #n read back from the store: its head branch and its title.
fake_pr_head_of()  { cat "$ORCH_GH_FAKE_STORE/prs/$1/head" 2>/dev/null; }
fake_pr_title_of() { cat "$ORCH_GH_FAKE_STORE/prs/$1/title" 2>/dev/null; }

# --- pr open -----------------------------------------------------------------
# PR #15 merged without closing #14 because the agent's body opened with a verb
# GitHub does not read as a closer. pr open owns the keyword instead, so no
# agent-chosen wording can leave a spec issue open again.
#
# open_pr's create goes through the store-backed fake (fake_github), and the
# PR it opened is read back from the store - the fixture gh's log stays empty, proving
# it never spawns a real gh subprocess. The real operation is pinned in "gh
# adapter contract".
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
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no issue" "$st" 1
assert_contains "with the guard branch create uses" "$out" \
  "no issue recorded in state - the spec phase must publish one first"

"$ORCH" state set issue 16
fake_github
fake_next_pr 23
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "and records it in state" "$("$ORCH" state get pr)" "23"
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

fake_fail adapter_pr_create 'a pull request for branch "orch/16-propen" into branch "main" already exists'
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "passing gh's reason through" "$out" "already exists"
assert_contains "naming the branch it would have opened from" "$out" "orch/16-propen"
assert_contains "and the issue it would have closed" "$out" "#16"
assert_eq "opening nothing" "$(fake_prs)" "23 "
# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_pr_create $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "a failed open still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not open the PR for branch orch/16-propen (issue #16): HTTP 502: Bad Gateway"
fake_unfail
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
writeln 'Implements the thing.' >"$body"
out="$("$ORCH" pr open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no branch" "$st" 1
assert_contains "with the exact require_branch die message" "$out" \
  "no branch recorded in state"
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
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

fake_github
fake_next_pr 23
out="$("$ORCH" pr publish 16 "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number GitHub gave it" "$out" "23"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "opens against the default branch" "$(fake_pr_base_of 23)" "main"
assert_eq "not as a draft" "$(fake_pr_draft_of 23)" "no"
assert_eq "and from the current branch" "$(fake_pr_head_of 23)" "quick/16-widgets"
body_recorded="$(fake_pr_body_of 23)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."
assert_eq "pushes the current branch" \
  "$(git -C "$bare" rev-parse --quiet --verify refs/heads/quick/16-widgets >/dev/null && echo pushed || echo missing)" \
  "pushed"

out="$("$ORCH" pr publish abc "Title" "$body" 2>&1)"; st=$?
assert_status "refuses an issue that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"

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
assert_first_line "--draft: its body still opens with the closing keyword" \
  "$(fake_pr_body_of 24)" "Closes #16"

out="$("$ORCH" pr publish 16 "Title" "$body" --ready 2>&1)"; st=$?
assert_status "an unknown option is refused" "$st" 1
assert_contains "naming it" "$out" "unknown option: --ready"
assert_eq "opening nothing" "$(fake_prs)" "23 24 "

help="$("$ORCH" help)"
assert_contains "help documents --draft" "$help" "pr publish <issue> <title> <body-file> [--draft]"
restore_suite_env

# --- pr draft (#967) ------------------------------------------------------------
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
fake_fail adapter_pr_state_draft $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "an unreadable PR exits 2" "$st" 2
assert_eq "relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not read PR #57: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_prs_open $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "an unreadable PR list exits 2" "$st" 2
fake_unfail

pd_state="$(git rev-parse --show-toplevel)/.orchestrator/state.json"
mkdir -p "$(dirname "$pd_state")"
for p in spec implement review; do
  printf '{"slug":"x","phase":"%s","issue":30,"branch":"quick/12-foo"}\n' "$p" >"$pd_state"
  out="$("$ORCH" pr draft 2>"$errf")"; st=$?
  assert_status "a branch an active flow holds at $p is refused" "$st" 2
  assert_eq "with the flow-held message at $p" "$(cat "$errf")" \
    "orch: the active flow holds quick/12-foo at phase $p - its PR changes state only through the review loop"
  assert_eq "leaving the PR ready at $p" "$(fake_pr_draft_of 57)" "no"
done
printf '{"slug":"x","phase":"done","issue":30,"branch":"quick/12-foo"}\n' >"$pd_state"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "a done flow on the branch lets it through" "$st" 0
printf '{"slug":"x","phase":"review","issue":12,"branch":"orch/12-x"}\n' >"$pd_state"
rm -f "$ORCH_GH_FAKE_STORE/prs/57/draft"
out="$("$ORCH" pr draft 2>"$errf")"; st=$?
assert_status "an active flow on another branch lets it through" "$st" 0
rm -f "$pd_state"

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

# --- pr ready (#967) ------------------------------------------------------------
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

out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "a PR already ready exits 0" "$st" 0
assert_eq "saying so" "$out" "PR #57 is already ready"

fake_pr_draft 57
fake_fail adapter_pr_ready $'HTTP 403: Resource not accessible by integration\nsecond line'
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "a failed promotion exits 2" "$st" 2
assert_eq "relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not mark PR #57 ready: HTTP 403: Resource not accessible by integration"
assert_eq "leaving the PR a draft" "$(fake_pr_draft_of 57)" "yes"
fake_unfail
fake_fail adapter_pr_state_draft $'HTTP 502: Bad Gateway\nsecond line'
out="$("$ORCH" pr ready 2>"$errf")"; st=$?
assert_status "an unreadable PR exits 2" "$st" 2
assert_eq "relaying gh's reason" "$(cat "$errf")" \
  "orch: gh could not read PR #57: HTTP 502: Bad Gateway"
fake_unfail

pr_state="$(git rev-parse --show-toplevel)/.orchestrator/state.json"
mkdir -p "$(dirname "$pr_state")"
for p in spec implement review; do
  printf '{"slug":"x","phase":"%s","issue":30,"branch":"quick/12-foo"}\n' "$p" >"$pr_state"
  out="$("$ORCH" pr ready 2>"$errf")"; st=$?
  assert_status "a branch an active flow holds at $p is refused" "$st" 2
  assert_eq "with the flow-held message at $p" "$(cat "$errf")" \
    "orch: the active flow holds quick/12-foo at phase $p - its PR changes state only through the review loop"
  assert_eq "leaving the PR a draft at $p" "$(fake_pr_draft_of 57)" "yes"
done
rm -f "$pr_state"

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

# --- pr release -----------------------------------------------------------------
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
writeln 'Ships the uat project.' '' 'Some detail.' >"$body"
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
fake_fail adapter_prs_open $'HTTP 502: Bad Gateway\nsecond line'
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a failed open-PR list exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not list the open PRs from uat into main: HTTP 502: Bad Gateway"
fake_unfail
fake_pr 57 closed uat main
fake_fail adapter_prs_merged_bodies "HTTP 502: Bad Gateway"
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "with the release PR closed, only open PRs from uat into main counted" "$st" 1
assert_contains "it goes on to read the merged PRs" "$out" "gh could not list the PRs merged into uat"
fake_fail adapter_prs_merged_bodies $'HTTP 502: Bad Gateway\nsecond line'
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a failed merged-PR list exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not list the PRs merged into uat: HTTP 502: Bad Gateway"
rm -rf "$ORCH_GH_FAKE_STORE/prs" "$ORCH_GH_FAKE_STORE/fail"

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
  "$(fake_pr_body_of 71)" "$(writeln 'Closes #5' 'Closes #6' 'Closes #7' 'Closes #9' '' 'Ships the uat project.' '' 'Some detail.')"
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
fake_fail adapter_pr_create $'HTTP 502: Bad Gateway\nsecond line'
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a failed release-PR open exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not open the release PR from uat into main: HTTP 502: Bad Gateway"
fake_unfail
# The state read for each issue on a Closes line: #5 is the first referenced.
fake_fail adapter_issue_state $'HTTP 502: Bad Gateway\nsecond line'
out="$(release "Release" "$body" 2>&1)"; st=$?
assert_status "a failed Closes-line state read exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$out" \
  "orch: gh could not read the state of issue #5: HTTP 502: Bad Gateway"
assert_eq "opening no PR" "$(fake_prs)" "62 63 64 65 71 "
fake_unfail

out="$(release "Release" 2>&1)"; st=$?
assert_status "refuses a missing body file argument" "$st" 1
assert_contains "with its usage" "$out" "pr release [--force] <title> <body-file>"
orch_gh_failing base clear >/dev/null
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- pr comment (#343) ----------------------------------------------------------
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
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comment
err="$(prc "$body" 2>&1 >/dev/null)"; st=$?
assert_status "a failed post exits 2" "$st" 2
assert_contains "naming the PR" "$err" "#57"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

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
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comment
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "failed post: exit 2" "$st" 2
assert_eq "failed post: exact stderr" "$(cat "$errf")" "orch: gh could not comment on PR #57: fake gh: adapter_pr_comment failed"
assert_eq "failed post: empty stdout" "$out" ""
rm -rf "$ORCH_GH_FAKE_STORE/fail"

# gh's reason rides on orch's own line, first line only (#846).
fake_fail adapter_prs_open $'HTTP 502: Bad Gateway\nsecond line'
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "unreadable PR list with a reason: exit 2" "$st" 2
assert_eq "carrying only gh's first line" "$(cat "$errf")" \
  "orch: gh could not list the open PRs from quick/12-foo: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_pr_comment $'HTTP 502: Bad Gateway\nsecond line'
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "failed post with a reason: exit 2" "$st" 2
assert_eq "carrying only gh's first line" "$(cat "$errf")" \
  "orch: gh could not comment on PR #57: HTTP 502: Bad Gateway"
fake_unfail
fake_fail_times adapter_pr_comment 9
out="$(prc "$body" 2>"$errf")"; st=$?
assert_status "a silent failed post: exit 2" "$st" 2
assert_eq "ending in gh gave no reason" "$(cat "$errf")" \
  "orch: gh could not comment on PR #57: gh gave no reason"
fake_unfail
rm -f "$errf"
assert_eq "no failed call posted anything" "$(fake_pr_comments_of 57)" "$(cat "$body")"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr comment" "$help" "pr comment <file>"

# --- pr fetch / pr update (#444) -----------------------------------------------
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
fake_fail adapter_pr_body_edit $'HTTP 502: Bad Gateway\nsecond line'
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "a failed body write still exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$err" \
  "orch: gh could not replace the body of PR #57: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_pr_body $'HTTP 502: Bad Gateway\nsecond line'
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "a failed body read in pr update exits 1" "$st" 1
assert_eq "carrying only gh's first line" "$err" \
  "orch: gh could not read the body of PR #57: HTTP 502: Bad Gateway"
fake_fail_times adapter_pr_body 9
err="$(prb update "$newbody" 2>&1 >/dev/null)"; st=$?
assert_status "a silent failed body read exits 1" "$st" 1
assert_eq "ending in gh gave no reason" "$err" \
  "orch: gh could not read the body of PR #57: gh gave no reason"
fake_unfail
fake_fail adapter_pr_body $'HTTP 502: Bad Gateway\nsecond line'
err="$(prb fetch "$out_file" 2>&1 >/dev/null)"; st=$?
assert_status "a failed read fails" "$st" 1
assert_eq "naming the PR, with gh's first line alone (#846)" "$err" \
  "orch: gh could not read the body of PR #57: HTTP 502: Bad Gateway"
assert_eq "leaving the body as it was" "$(fake_pr_body_of 57)" "$(writeln 'Closes #12')"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

help="$("$ORCH" help)"
assert_contains "help documents pr fetch" "$help" "pr fetch <file>"
assert_contains "help documents pr update" "$help" "pr update <file>"

# --- pr comments (#418) --------------------------------------------------------
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

printf 'known content\n' >"$pr_comments"
fake_fail adapter_prs_open
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "an unreadable PR list exits 2" "$st" 2
assert_eq "and writes nothing" "$(cat "$pr_comments")" "known content"
rm -rf "$ORCH_GH_FAKE_STORE/fail"

fake_fail adapter_pr_comments $'HTTP 502: Bad Gateway\nsecond line'
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "unreadable comments exit 2" "$st" 2
assert_eq "naming the PR, with gh's first line alone (#846)" "$err" \
  "orch: gh could not read the comments of PR #57: HTTP 502: Bad Gateway"
assert_eq "leaving the file that was already there unchanged" "$(cat "$pr_comments")" "known content"
rm -rf "$ORCH_GH_FAKE_STORE/fail"
fake_fail_times adapter_pr_comments 9
err="$(prcs "$pr_comments" 2>&1 >/dev/null)"; st=$?
assert_status "comments that fail silently exit 2 too" "$st" 2
assert_eq "saying gh gave no reason" "$err" \
  "orch: gh could not read the comments of PR #57: gh gave no reason"
unset ORCH_GH_ADAPTER ORCH_GH_FAKE_STORE

err="$(prcs 2>&1 >/dev/null)"; st=$?
assert_status "no file argument exits 2" "$st" 2
assert_contains "with its usage" "$err" "usage: orch.sh pr comments <file>"

assert_contains "help documents pr comments" "$("$ORCH" help)" "pr comments <file>"
rm -f "$pr_comments"
