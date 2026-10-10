# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- finding-triage scan -------------------------------------------------------
# The scan sorts each open filed finding still in needs-triage against the
# default branch: whether the code its **Location:** names, at the PR's head
# SHA, has changed since. The issues come from the store-backed fake
# (fake_github); the git side is a real fixture: a bare origin, a
# local clone that holds only the filing-time commit, and a second clone that
# pushes everything after it, so the scan has to fetch the default branch to
# see it.
echo
echo "finding-triage scan"
new_repo >/dev/null
git checkout -q -B main
seq_lines() { local i; for i in $(seq 1 "$2"); do echo "$1 line $i"; done; }
mkdir -p src
seq_lines app 12 >src/app.sh
seq_lines other 4 >src/other.sh
seq_lines gone 3 >src/gone.sh
git add -A && git commit -qm "the reviewed code"
head_sha="$(git rev-parse HEAD)"
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin main
git -C "$bare" symbolic-ref HEAD refs/heads/main
git fetch -q origin
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
# Everything after the filing, made in a second clone and pushed: a fix on
# app.sh's line 3, then an unrelated edit further down the same file, then
# gone.sh deleted - and, under refs/pull/8/head alone, a PR head commit the
# local clone has never seen, as a squash merge leaves it.
work="$(mktemp -d)/work"
git clone -q "$bare" "$work"
git -C "$work" config user.email test@example.com
git -C "$work" config user.name Test
git -C "$work" checkout -q main
sed -i 's/^app line 3$/app line 3, fixed/' "$work/src/app.sh"
git -C "$work" commit -qam "fix line 3"
fix_sha="$(git -C "$work" rev-parse HEAD)"
sed -i 's/^app line 11$/app line 11, reworded/' "$work/src/app.sh"
git -C "$work" commit -qam "reword line 11"
reword_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" rm -q src/gone.sh
git -C "$work" commit -qm "drop gone.sh"
git -C "$work" push -q origin main
git -C "$work" checkout -q -b pr8 "$head_sha"
echo "notes" >"$work/notes.txt"
git -C "$work" add notes.txt
git -C "$work" commit -qm "a later PR head"
pr_head_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin HEAD:refs/pull/8/head
origin_main="$(git -C "$bare" rev-parse main)"

fake_github
# finding <n> <labels, comma-separated> <location line|-> [pr] [state]: one
# issue in the fake's store, its body in the closer's filed shape.
finding() {
  local labels=()
  IFS=, read -r -a labels <<<"$2"
  fake_issue "$1" "${5:-open}" "${labels[@]}"
  if [ "$3" = - ]; then
    fake_issue_body "$1" "$(writeln 'A finding written by hand, with no labelled lines.')"
  else
    fake_issue_body "$1" "$(writeln '## Finding' '' '> The reviewer said this.' '' '**Axis:** Standards' '' \
      '**Severity:** nit - a reason.' '' "**Location:** $3" '' \
      "**PR:** https://github.com/acme/widgets/pull/${4:-7}" '' \
      '**Why not fixed in the loop:** found in the final iteration.')"
  fi
}
finding 1 "review:nit,needs-triage" "\`src/other.sh:2\` at $head_sha"
finding 2 "review:major,needs-triage,bug" "\`src/app.sh:3\` at $head_sha"
finding 3 "review:nit,needs-triage" "\`src/app.sh:40\` (and \`:41\`) at $head_sha"
finding 4 "review:nit,needs-triage" "\`src/gone.sh:1\` at $head_sha"
finding 5 "review:major,needs-triage" "\`src/app.sh:3\` at 0123456789abcdef0123456789abcdef01234567"
finding 6 "review:nit,needs-triage" -
finding 7 "review:nit,needs-triage" "\`src/other.sh:2\` at $pr_head_sha" 8
finding 8 "review:nit,ready-for-agent" "\`src/other.sh:2\` at $head_sha"
finding 9 "review:nit,needs-triage" "\`src/other.sh:2\` at $head_sha" 7 CLOSED
finding 10 "needs-triage" "\`src/other.sh:2\` at $head_sha"
scan() { orch_gh_failing finding-triage scan "$@"; }
# line_of <n> <out>: the scan's line for issue n.
line_of() { printf '%s\n' "$2" | awk -F'\t' -v n="$1" '$1 == n'; }
field_of() { line_of "$1" "$3" | cut -f"$2"; }

before_refs="$(git for-each-ref refs/heads)"
before_head="$(git rev-parse HEAD) $(git symbolic-ref -q HEAD)"
before_tree="$(git status --porcelain)"
before_store="$(fake_snapshot)"
out="$(scan 2>&1)"; st=$?
assert_status "scans the open filed findings" "$st" 0
assert_eq "one tab-separated line of six fields per finding" \
  "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 6' | wc -l | tr -d ' ')" "0"
assert_eq "and no field is ever empty" \
  "$(printf '%s\n' "$out" | awk -F'\t' '{ for (i = 1; i <= NF; i++) if ($i == "") e++ } END { print e + 0 }')" "0"
assert_eq "an unchanged file's finding: issue, PR, location, result, - for no detail, triage state" \
  "$(line_of 1 "$out")" "$(printf '1\t7\tsrc/other.sh:2\tunchanged\t-\tneeds-triage')"
assert_eq "a finding whose lines a later commit fixed is changed" "$(field_of 2 4 "$out")" "changed"
assert_eq "naming that commit's full SHA, not the newer one elsewhere in the file" \
  "$(field_of 2 5 "$out")" "$fix_sha"
assert_eq "a line range the file no longer reaches is changed too" "$(field_of 3 4 "$out")" "changed"
assert_eq "naming the newest commit touching the file" "$(field_of 3 5 "$out")" "$reword_sha"
assert_eq "a deleted file's finding is gone" "$(field_of 4 4 "$out")" "gone"
assert_eq "with - for no detail" "$(field_of 4 5 "$out")" "-"
assert_eq "an unreachable head SHA is unknown" "$(field_of 5 4 "$out")" "unknown"
assert_contains "saying the SHA was unreachable" "$(field_of 5 5 "$out")" "unreachable"
assert_eq "a body without the labelled lines is unknown" "$(field_of 6 4 "$out")" "unknown"
assert_contains "saying the body does not parse" "$(field_of 6 5 "$out")" "Location"
assert_eq "a SHA only the PR's head ref holds is fetched, not unknown" "$(field_of 7 4 "$out")" "unchanged"
assert_eq "naming that PR" "$(field_of 7 2 "$out")" "8"
assert_eq "an already triaged finding is not scanned" "$(line_of 8 "$out")" ""
assert_eq "nor a closed one" "$(line_of 9 "$out")" ""
assert_eq "nor an issue that is not a filed finding" "$(line_of 10 "$out")" ""
# Every result path's exact line, pinned byte for byte.
assert_eq "a changed finding's exact line" \
  "$(line_of 2 "$out")" "$(printf '2\t7\tsrc/app.sh:3\tchanged\t%s\tneeds-triage' "$fix_sha")"
assert_eq "a gone finding's exact line" \
  "$(line_of 4 "$out")" "$(printf '4\t7\tsrc/gone.sh:1\tgone\t-\tneeds-triage')"
assert_eq "an unreachable head SHA's exact line" "$(line_of 5 "$out")" \
  "$(printf '5\t7\tsrc/app.sh:3\tunknown\thead SHA 0123456789abcdef0123456789abcdef01234567 is unreachable, even after fetching refs/pull/7/head\tneeds-triage')"
assert_eq "a body with no Location line: its exact line" "$(line_of 6 "$out")" \
  "$(printf '6\t-\t-\tunknown\tbody does not parse: no **Location:** line naming `<file>:<line>` at <SHA>\tneeds-triage')"
assert_eq "the findings come in issue order" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 "
assert_ne "lists the major findings still in needs-triage" "$(line_of 5 "$out")" ""
assert_ne "and the nit ones" "$(line_of 6 "$out")" ""
assert_eq "writes nothing to GitHub" "$(fake_snapshot)" "$before_store"
assert_eq "fetches the default branch first" "$(git rev-parse origin/main)" "$origin_main"
assert_eq "and leaves the branches as they were" "$(git for-each-ref refs/heads)" "$before_refs"
assert_eq "HEAD too" "$(git rev-parse HEAD) $(git symbolic-ref -q HEAD)" "$before_head"
assert_eq "and the working tree" "$(git status --porcelain)" "$before_tree"

out="$(scan --pr 8 2>&1)"; st=$?
assert_status "narrows to one source PR" "$st" 0
assert_eq "scanning only that PR's findings" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "7 "

out="$(scan 2 2>&1)"; st=$?
assert_status "scans one explicit finding" "$st" 0
assert_eq "and only it" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "2 "
out="$(scan 9 2>&1)"; st=$?
assert_status "refuses an explicit finding that is closed" "$st" 1
assert_contains "saying so" "$out" "not open"
out="$(scan 8 2>&1)"; st=$?
assert_status "refuses one already triaged" "$st" 1
assert_contains "naming the missing triage label" "$out" "needs-triage"
out="$(scan 10 2>&1)"; st=$?
assert_status "refuses an issue that is not a filed finding" "$st" 1
assert_contains "naming the missing severity label" "$out" "review:"
out="$(scan 2 --pr 8 2>&1)"; st=$?
assert_status "takes an issue or a PR, not both" "$st" 1

# --all, the re-check: every open filed finding whatever its triage label.
# The sixth column names the triage-role labels each carries, in role order.
finding 20 "review:nit" "\`src/other.sh:2\` at $head_sha"
finding 21 "review:major,ready-for-human,bug,needs-info" "\`src/other.sh:2\` at $head_sha" 21
finding 22 "review:nit,wontfix" "\`src/gone.sh:1\` at $head_sha"
finding 23 "review:nit,ready-for-agent,needs-triage" "\`src/other.sh:2\` at $head_sha" 21
out="$(scan --all 2>&1)"; st=$?
assert_status "scans every open filed finding" "$st" 0
assert_eq "whatever its triage label, closed ones and non-findings still left out" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 8 20 21 22 23 "
assert_eq "one tab-separated line of six fields per finding (--all)" \
  "$(printf '%s\n' "$out" | awk -F'\t' 'NF != 6' | wc -l | tr -d ' ')" "0"
assert_eq "an untriaged-by-label finding's state is -" \
  "$(line_of 20 "$out")" "$(printf '20\t7\tsrc/other.sh:2\tunchanged\t-\t-')"
assert_eq "a triaged finding's state is its label" "$(field_of 8 6 "$out")" "ready-for-agent"
assert_eq "several are comma-joined in role order, not label order" \
  "$(field_of 21 6 "$out")" "needs-info,ready-for-human"
assert_eq "needs-triage leads the roles" "$(field_of 23 6 "$out")" "needs-triage,ready-for-agent"
assert_eq "an open wontfix finding is listed, its state wontfix" \
  "$(line_of 22 "$out")" "$(printf '22\t7\tsrc/gone.sh:1\tgone\t-\twontfix')"
out="$(scan 2>&1)"
assert_eq "without --all, only the findings in needs-triage" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 23 "
assert_eq "each with its state too" "$(field_of 23 6 "$out")" "needs-triage,ready-for-agent"
# Each finding is read once, body and labels together: neither the body-only
# nor the state-and-labels read is called.
fake_fail adapter_issue_body "body read alone"
fake_fail adapter_issue_state_labels "state and labels read alone"
out="$(scan --all 2>&1)"; st=$?
assert_status "reads each finding through one call for body and labels" "$st" 0
assert_eq "listing them all" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 8 20 21 22 23 "
out="$(scan --all 8 2>&1)"; st=$?
assert_status "an explicit finding is read through that one call too" "$st" 0
fake_unfail
fake_fail adapter_issue_state_labels_body $'HTTP 502: Bad Gateway\nsecond line'
out="$(scan --all 2>&1)"; st=$?
assert_status "a listed finding gh cannot read dies" "$st" 1
assert_contains "naming the issue, with gh's line" "$out" "gh could not read issue #1: HTTP 502: Bad Gateway"
fake_unfail
fake_fail adapter_issues_labelled $'HTTP 502: Bad Gateway\nsecond line'
out="$(scan 2>&1)"; st=$?
assert_status "a findings list gh cannot read dies" "$st" 1
assert_contains "naming the list, with gh's line" "$out" \
  "orch: gh could not list the review:major findings: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
fake_unfail

out="$(scan --all --pr 21 2>&1)"; st=$?
assert_status "--all narrows to one source PR" "$st" 0
assert_eq "listing that PR's findings whatever their label" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "21 23 "
out="$(scan --pr 21 2>&1)"
assert_eq "while without --all only its findings in needs-triage" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "23 "
out="$(scan --all 8 2>&1)"; st=$?
assert_status "--all accepts an explicit finding already triaged" "$st" 0
assert_eq "scanning only it" "$(line_of 8 "$out")" "$(printf '8\t7\tsrc/other.sh:2\tunchanged\t-\tready-for-agent')"
assert_eq "and nothing else" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "8 "
out="$(scan 8 --all 2>&1)"; st=$?
assert_status "--all may follow the issue" "$st" 0
out="$(scan --all 9 2>&1)"; st=$?
assert_status "--all still refuses a closed finding" "$st" 1
assert_contains "saying so (--all)" "$out" "not open"
out="$(scan --all 10 2>&1)"; st=$?
assert_status "--all still refuses an issue that is not a filed finding" "$st" 1
assert_contains "naming the missing severity label (--all)" "$out" "review:"
for args in "--all 8 --pr 21" "--all --all" "--all --pr" "--all x"; do
  # shellcheck disable=SC2086 # each args string is split on purpose
  out="$(scan $args 2>&1)"; st=$?
  assert_status "refuses scan $args" "$st" 1
  assert_contains "with the usage (scan $args)" "$out" "usage: orch.sh finding-triage scan [--all] [<issue> | --pr <n>]"
done
for n in 20 21 22 23; do fake_issue "$n" closed; done

# A blocking finding is fixed in the loop, never filed: an explicit issue
# labelled review:blocking is not a filed finding.
finding 12 "review:blocking,needs-triage" "\`src/other.sh:2\` at $head_sha"
out="$(scan 12 2>&1)"; st=$?
assert_status "refuses an explicit issue whose severity is never filed" "$st" 1
assert_contains "naming the filed severities" "$out" "review:major"
fake_issue 12 closed

# A PR head that edited the file and never reached the default branch: the
# file differs, yet no commit since the filing touched it there, so the scan
# names no commit older than the filing.
git -C "$work" checkout -q -b pr11 "$head_sha"
sed -i 's/^other line 2$/other line 2, on the PR only/' "$work/src/other.sh"
git -C "$work" commit -qam "an unmerged PR edit"
unmerged_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin HEAD:refs/pull/11/head
finding 11 "review:nit,needs-triage" "\`src/other.sh:2\` at $unmerged_sha" 11
out="$(scan 11 2>&1)"; st=$?
assert_status "scans a finding filed on a PR edit that never landed" "$st" 0
assert_eq "it is unknown, not changed by a commit older than the filing" "$(field_of 11 4 "$out")" "unknown"
assert_contains "saying no commit since the filing touched the file" "$(field_of 11 5 "$out")" "no commit"
assert_eq "its exact line" "$(line_of 11 "$out")" \
  "$(printf '11\t11\tsrc/other.sh:2\tunknown\tno commit on the default branch since %s touched src/other.sh - the difference is commits that never reached it\tneeds-triage' "$unmerged_sha")"
fake_issue 11 closed

# A finding whose lines the scan follows to the default branch, where later
# commits touched only other lines of its file (line 3's fix, line 11's
# reword): its lines are unchanged, so no commit is named.
finding 14 "review:nit,needs-triage" "\`src/app.sh:6\` at $head_sha" 14
out="$(scan 14 2>&1)"; st=$?
assert_status "scans a finding whose file changed only elsewhere" "$st" 0
assert_eq "its followed, untouched lines are unchanged, with - for no detail" \
  "$(line_of 14 "$out")" "$(printf '14\t14\tsrc/app.sh:6\tunchanged\t-\tneeds-triage')"
fake_issue 14 closed

# A body with its **Location:** line but no **PR:** line does not parse either.
fake_issue 16 open review:nit needs-triage
fake_issue_body 16 "$(writeln '## Finding' '' "**Location:** \`src/other.sh:2\` at $head_sha")"
out="$(scan 16 2>&1)"; st=$?
assert_status "scans a finding whose body names no PR" "$st" 0
assert_eq "it is unknown, its exact line naming the missing PR line" "$(line_of 16 "$out")" \
  "$(printf '16\t-\tsrc/other.sh:2\tunknown\tbody does not parse: no **PR:** line ending in a pull request URL\tneeds-triage')"
fake_issue 16 closed

# A finding whose file later gets hunks both before and after its line, with
# far more diff after the matching hunk than a pipe buffer holds: the line
# mapping stops reading the diff early, and the scan must still finish. Lines
# inserted above the finding shift it; only the commit that touched the
# shifted line is the answer, the bulk rewrite below it is not.
git -C "$work" checkout -q main
seq_lines "big file" 6000 >"$work/src/big.sh"
git -C "$work" add src/big.sh
git -C "$work" commit -qm "a big file"
big_sha="$(git -C "$work" rev-parse HEAD)"
{ seq_lines inserted 5; cat "$work/src/big.sh"; } >"$work/big.tmp" && mv "$work/big.tmp" "$work/src/big.sh"
git -C "$work" commit -qam "insert five lines on top"
sed -i 's/^big file line 10$/big file line 10, fixed/' "$work/src/big.sh"
git -C "$work" commit -qam "fix the shifted line"
shifted_fix_sha="$(git -C "$work" rev-parse HEAD)"
sed -i '200,$ s/$/, rewritten in bulk/' "$work/src/big.sh"
git -C "$work" commit -qam "rewrite everything below"
git -C "$work" push -q origin main
finding 13 "review:nit,needs-triage" "\`src/big.sh:10\` at $big_sha" 13
out="$(scan 13 2>&1)"; st=$?
assert_status "scans a finding whose file has a large diff after its line" "$st" 0
assert_eq "it is changed" "$(field_of 13 4 "$out")" "changed"
assert_eq "naming the commit that touched the shifted line" "$(field_of 13 5 "$out")" "$shifted_fix_sha"
fake_issue 13 closed

# Findings whose filed lines the default branch later deleted outright: never
# unchanged, whatever lines survive around them, and named by the commit that
# deleted them. One file per case, all filed at one commit, each deleted by
# its own commit after it.
git -C "$work" checkout -q main
for f in whole end start middle later two replaced squashed; do seq_lines "$f" 30 >"$work/src/del_$f.sh"; done
git -C "$work" add src
git -C "$work" commit -qm "the code the deletions are filed against"
filed_sha="$(git -C "$work" rev-parse HEAD)"
# del_commit <file> <sed script> <message>: commits the edit, printing its SHA.
del_commit() {
  sed -i "$2" "$work/src/$1"
  git -C "$work" commit -qam "$3"
  git -C "$work" rev-parse HEAD
}
whole_sha="$(del_commit del_whole.sh '8,12d' "delete the whole range")"
end_sha="$(del_commit del_end.sh '18,25d' "delete the range's end")"
start_sha="$(del_commit del_start.sh '5,12d' "delete the range's start")"
middle_sha="$(del_commit del_middle.sh '14,16d' "delete the range's middle")"
later_del_sha="$(del_commit del_later.sh '8,12d' "delete before a later edit")"
del_commit del_later.sh 's/^later line 1$/later line 1, reworded/' "a later, unrelated edit" >/dev/null
del_commit del_two.sh '18,20d' "delete the range's end first" >/dev/null
two_sha="$(del_commit del_two.sh '10,12d' "then delete its start")"
replaced_sha="$(del_commit del_replaced.sh '9,11c\replaced line' "replace three lines with one")"
# A PR head off the default branch, as a squash merge leaves it: it inserts a
# line on top of del_squashed.sh, the squash commit lands the same edit on
# main, a later commit deletes the filed line, and a last one edits another.
git -C "$work" checkout -q -b pr37 "$filed_sha"
sed -i '1i squashed pr line' "$work/src/del_squashed.sh"
git -C "$work" commit -qam "the PR's own edit"
squash_head_sha="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin HEAD:refs/pull/37/head
git -C "$work" checkout -q main
del_commit del_squashed.sh '1i squashed pr line' "the PR, squash-merged" >/dev/null
squashed_sha="$(del_commit del_squashed.sh '9,13d' "delete the squash-merged lines")"
del_commit del_squashed.sh 's/^squashed line 30$/squashed line 30, reworded/' "a later edit to the squashed file" >/dev/null
git -C "$work" push -q origin main
finding 30 "review:nit,needs-triage" "\`src/del_whole.sh:10\` at $filed_sha" 30
finding 31 "review:nit,needs-triage" "\`src/del_end.sh:10-20\` at $filed_sha" 31
finding 32 "review:nit,needs-triage" "\`src/del_start.sh:10-20\` at $filed_sha" 32
finding 33 "review:nit,needs-triage" "\`src/del_middle.sh:10-20\` at $filed_sha" 33
finding 34 "review:nit,needs-triage" "\`src/del_later.sh:10\` at $filed_sha" 34
finding 35 "review:nit,needs-triage" "\`src/del_two.sh:10-20\` at $filed_sha" 35
finding 36 "review:nit,needs-triage" "\`src/del_replaced.sh:10\` at $filed_sha" 36
finding 37 "review:nit,needs-triage" "\`src/del_squashed.sh:11\` at $squash_head_sha" 37
out="$(scan --pr 30 2>&1)"; st=$?
assert_status "scans a finding whose lines were deleted" "$st" 0
assert_eq "a whole deleted range is changed, naming the deleting commit" \
  "$(line_of 30 "$out")" "$(printf '30\t30\tsrc/del_whole.sh:10\tchanged\t%s\tneeds-triage' "$whole_sha")"
out="$(scan --pr 31 2>&1)"
assert_eq "a range whose end was deleted is changed, naming the deleting commit" \
  "$(line_of 31 "$out")" "$(printf '31\t31\tsrc/del_end.sh:10-20\tchanged\t%s\tneeds-triage' "$end_sha")"
out="$(scan --pr 32 2>&1)"
assert_eq "a range whose start was deleted is changed, naming the deleting commit" \
  "$(line_of 32 "$out")" "$(printf '32\t32\tsrc/del_start.sh:10-20\tchanged\t%s\tneeds-triage' "$start_sha")"
out="$(scan --pr 33 2>&1)"
assert_eq "a range whose middle was deleted is changed, naming the deleting commit" \
  "$(line_of 33 "$out")" "$(printf '33\t33\tsrc/del_middle.sh:10-20\tchanged\t%s\tneeds-triage' "$middle_sha")"
out="$(scan --pr 34 2>&1)"
assert_eq "a later, unrelated edit to the file does not displace the deleting commit" \
  "$(line_of 34 "$out")" "$(printf '34\t34\tsrc/del_later.sh:10\tchanged\t%s\tneeds-triage' "$later_del_sha")"
out="$(scan --pr 35 2>&1)"
assert_eq "lines deleted across two commits name the later one" \
  "$(line_of 35 "$out")" "$(printf '35\t35\tsrc/del_two.sh:10-20\tchanged\t%s\tneeds-triage' "$two_sha")"
out="$(scan --pr 36 2>&1)"
assert_eq "a line replaced, not deleted, is changed, naming the replacing commit" \
  "$(line_of 36 "$out")" "$(printf '36\t36\tsrc/del_replaced.sh:10\tchanged\t%s\tneeds-triage' "$replaced_sha")"
out="$(scan --pr 37 2>&1)"
assert_eq "a finding filed at a squash-merged PR head names the deleting commit, not the squash" \
  "$(line_of 37 "$out")" "$(printf '37\t37\tsrc/del_squashed.sh:11\tchanged\t%s\tneeds-triage' "$squashed_sha")"
for n in 30 31 32 33 34 35 36 37; do fake_issue "$n" closed; done

# Each severity's list is cut off at the issue-list limit; a list that
# reaches it may be missing findings past it, and the scan says so on stderr
# while it carries on. Open in needs-triage here: two major findings (2, 5)
# and five nit ones (1, 3, 4, 6, 7).
err="$(mktemp)"
out="$(ORCH_ISSUE_LIST_LIMIT=5 scan 2>"$err")"; st=$?
assert_status "a list at the issue-list limit does not stop the scan" "$st" 0
assert_contains "warns that the nit list reached the limit, naming the label and the limit" "$(cat "$err")" \
  "orch: review:nit findings reached the issue-list limit of 5 - any past it are missing from this scan"
assert_not_contains "but not the major list, below it" "$(cat "$err")" "review:major"
assert_eq "and still prints its lines" "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "1 2 3 4 5 6 7 "
out="$(ORCH_ISSUE_LIST_LIMIT=6 scan 2>"$err")"; st=$?
assert_status "scans with every list one below the limit" "$st" 0
assert_not_contains "and gives no warning" "$(cat "$err")" "issue-list limit"
rm -f "$err"

# The triage label is the repo's name for the role, as review file files it.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' >docs/agents/triage-labels.md
finding 15 "review:nit,triage me" "\`src/other.sh:2\` at $head_sha"
out="$(scan 2>&1)"
assert_eq "lists under the repo's own name for needs-triage, and only it" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "15 "
assert_eq "its state the repo's label for the role" "$(field_of 15 6 "$out")" "triage me"
# A needs-triage label beginning with '-' is a label, never a grep option.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `-triage`            | Evaluate it |' >docs/agents/triage-labels.md
finding 17 "review:nit,-triage" "\`src/other.sh:2\` at $head_sha"
out="$(scan 17 2>&1)"; st=$?
assert_status "scans an explicit finding whose needs-triage label begins with '-'" "$st" 0
assert_eq "listing it, its state the repo's label" "$(line_of 17 "$out")" "$(printf '17\t7\tsrc/other.sh:2\tunchanged\t-\t-triage')"
fake_issue 17 closed
rm docs/agents/triage-labels.md

finding 18 "review:nit,needs-triage" "\`src/other.sh:2\` at $head_sha"
fake_fail adapter_issue_state_labels_body $'HTTP 502: Bad Gateway\nsecond line'
before_store="$(fake_snapshot)"
out="$(scan 18 2>&1)"; st=$?
assert_status "an explicit finding gh cannot read dies" "$st" 1
assert_contains "naming the issue, with gh's line" "$out" "gh could not read issue #18: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "listing nothing" "$(printf '%s\n' "$out" | grep -c "$(printf '\t')")" "0"
assert_eq "and changing nothing" "$(fake_snapshot)" "$before_store"
fake_unfail
fake_issue 18 closed
restore_suite_env

# --- finding-triage apply ------------------------------------------------------
# Apply is finding triage's one write to GitHub: the comment, with the AI
# disclaimer on top, then the labels and, for the closing outcomes, the close.
# The store-backed fake (fake_github) applies each comment, label edit and
# close to the issue it holds, so what an outcome leaves on the issue is read
# back from the issue itself, as is the category label apply creates.
echo
echo "finding-triage apply"
new_repo >/dev/null
fake_github
tab="$(printf '\t')"
comment="$(mktemp)"
writeln 'Fixed by abc1234 on main.' >"$comment"
disclaimer='> *This was generated by AI during triage.*'
# triaged <n> <labels, comma-separated>: one filed finding in the fake's store.
triaged() {
  local labels=()
  IFS=, read -r -a labels <<<"$2"
  fake_issue "$1" open "${labels[@]}"
  fake_issue_body "$1" '**Axis:** Spec'
}
apply() { orch_gh_failing finding-triage apply "$@"; }

for outcome in close-fixed wontfix ready-for-agent ready-for-human; do
  triaged 2 "review:major,needs-triage,bug"
  case "$outcome" in
    close-fixed|wontfix) out="$(apply 2 "$outcome" --comment-file "$comment" 2>&1)"; st=$? ;;
    *) out="$(apply 2 "$outcome" --category bug --comment-file "$comment" 2>&1)"; st=$? ;;
  esac
  assert_status "applies $outcome" "$st" 0
  assert_eq "posting the comment under the AI disclaimer ($outcome)" \
    "$(fake_comments_of 2)" "$(writeln "$disclaimer" '' 'Fixed by abc1234 on main.')"
done

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 close-fixed --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a fixed finding" "$st" 0
assert_eq "closed" "$(fake_state_of 2)" "CLOSED"
assert_eq "as completed" "$(fake_reason_of 2)" "completed"
assert_eq "out of needs-triage, with no state label added" "$(fake_labels_of 2)" "bug review:major "

triaged 3 "review:nit,needs-triage,enhancement"
out="$(apply 3 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a finding as wontfix" "$st" 0
assert_eq "closed" "$(fake_state_of 3)" "CLOSED"
assert_eq "as not planned" "$(fake_reason_of 3)" "not planned"
assert_eq "out of needs-triage and into wontfix" "$(fake_labels_of 3)" "enhancement review:nit wontfix "

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding to an agent" "$st" 0
assert_eq "out of needs-triage, into ready-for-agent, its severity and category kept" \
  "$(fake_labels_of 2)" "bug ready-for-agent review:major "
assert_eq "and left open" "$(fake_state_of 2)" "OPEN"

triaged 2 "review:major,needs-triage,bug"
out="$(apply 2 ready-for-human --category enhancement --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding to a human, flipping its category" "$st" 0
assert_eq "leaving exactly the one category asked for" \
  "$(fake_labels_of 2)" "enhancement ready-for-human review:major "
assert_contains "creating that category's label with GitHub's default colour and description" \
  "$(fake_labels)" "enhancement${tab}a2eeef${tab}New feature or request"

# A finding already out of needs-triage leaves apply nothing to remove: a
# close needs no relabel, and a relabel removes nothing.
triaged 5 "review:minor,bug"
fake_fail adapter_issue_relabel
out="$(apply 5 close-fixed --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a fixed finding not in needs-triage, with no relabel" "$st" 0
assert_eq "its labels as they were" "$(fake_labels_of 5)" "bug review:minor "
assert_eq "as completed" "$(fake_state_of 5) $(fake_reason_of 5)" "CLOSED completed"
fake_github
triaged 5 "review:minor,bug"
out="$(apply 5 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_status "closes a finding not in needs-triage as wontfix" "$st" 0
assert_eq "into wontfix" "$(fake_labels_of 5)" "bug review:minor wontfix "
triaged 5 "review:minor,bug"
out="$(apply 5 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "sends a finding not in needs-triage to an agent" "$st" 0
assert_eq "into ready-for-agent" "$(fake_labels_of 5)" "bug ready-for-agent review:minor "

# A finding filed before categories were has none: apply gives it one.
triaged 4 "review:nit,needs-triage"
out="$(apply 4 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "categorises a finding filed with no category" "$st" 0
assert_eq "with the one asked for" "$(fake_labels_of 4)" "bug ready-for-agent review:nit "

for outcome in ready-for-agent ready-for-human; do
  triaged 2 "review:major,needs-triage,bug"
  before_store="$(fake_snapshot)"
  out="$(apply 2 "$outcome" --comment-file "$comment" 2>&1)"; st=$?
  assert_status "refuses $outcome with no category" "$st" 1
  assert_contains "naming --category ($outcome)" "$out" "--category"
  assert_eq "touching nothing ($outcome)" "$(fake_snapshot)" "$before_store"
done
for outcome in close-fixed wontfix; do
  before_store="$(fake_snapshot)"
  out="$(apply 2 "$outcome" --category bug --comment-file "$comment" 2>&1)"; st=$?
  assert_status "refuses a category on $outcome" "$st" 1
  assert_contains "naming --category ($outcome)" "$out" "--category"
  assert_eq "touching nothing ($outcome)" "$(fake_snapshot)" "$before_store"
done
out="$(apply 2 ready-for-agent --category feature --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses a category that is neither bug nor enhancement" "$st" 1
assert_eq "in exactly these words" "$out" "orch: unknown --category 'feature' - expected bug or enhancement"
out="$(apply 2 ready-for-human --category "" --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses an empty category" "$st" 1
assert_eq "in its own words" "$out" "orch: ready-for-human needs --category <bug|enhancement>"
out="$(apply 2 promote --comment-file "$comment" 2>&1)"; st=$?
assert_status "refuses an unknown outcome" "$st" 1
out="$(apply 2 close-fixed 2>&1)"; st=$?
assert_status "refuses no comment file" "$st" 1
out="$(apply 2 close-fixed --comment-file /nonexistent/comment.md 2>&1)"; st=$?
assert_status "refuses a comment file that is not there" "$st" 1

# A category label gh will not create - most often because the repo has it -
# does not stop apply, and the repo's own is never overwritten.
triaged 2 "review:major,needs-triage,bug"
fake_label bug 123456 "The repo's own bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "a category label the repo has already does not stop apply" "$st" 0
assert_eq "the labels are still applied" "$(fake_labels_of 2)" "bug ready-for-agent review:major "
assert_contains "and the repo's own is left as it is" "$(fake_labels)" "bug${tab}123456${tab}The repo's own bug"

# Any other failed gh call does, with gh's first line right after what failed.
for case in "adapter_issue_comment|wontfix|comment on" "adapter_issue_relabel|wontfix|relabel" \
            "adapter_issue_close|wontfix|close" "adapter_issue_relabel|close-fixed|relabel" \
            "adapter_issue_close|close-fixed|close" "adapter_issue_relabel|ready-for-agent|relabel"; do
  IFS='|' read -r op outcome verb <<<"$case"
  category_args=()
  [ "$outcome" != ready-for-agent ] || category_args=(--category bug)
  fake_github
  triaged 2 "review:major,needs-triage,bug"
  fake_fail "$op" $'HTTP 502: Bad Gateway\nsecond line'
  out="$(apply 2 "$outcome" ${category_args[@]+"${category_args[@]}"} --comment-file "$comment" 2>&1)"; st=$?
  assert_status "dies when gh fails ($op, $outcome)" "$st" 1
  assert_eq "saying what failed, with gh's line ($op, $outcome)" "$out" \
    "orch: gh could not $verb issue #2: HTTP 502: Bad Gateway"
done
fake_github
triaged 2 "review:major,needs-triage,bug"
fake_fail_times adapter_issue_relabel 9
out="$(apply 2 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_status "a silent relabel failure dies" "$st" 1
assert_eq "saying gh gave no reason" "$out" "orch: gh could not relabel issue #2: gh gave no reason"

# A failed read stops apply before it writes anything.
fake_github
triaged 2 "review:major,needs-triage,bug"
fake_fail adapter_issue_state_labels $'HTTP 502: Bad Gateway\nsecond line'
before_store="$(fake_snapshot)"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "a failed read dies" "$st" 1
assert_contains "naming the issue, with gh's line" "$out" "gh could not read issue #2: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "changing nothing" "$(fake_snapshot)" "$before_store"
fake_unfail

# An already-triaged finding is settled cleanly: whatever the outcome, every
# other triage-role label it carries goes, and none it lacks is named - gh
# refuses to remove a label the repo does not have. The removes are read off a
# relabel that records them, at the gh boundary, before the fake applies it.
relabel_log="$(mktemp)"
traced_adapter="$(mktemp)"
writeln "source $(printf %q "$GH_ADAPTER_FAKE")" \
        'eval "fake_relabel_applied() $(declare -f adapter_issue_relabel | tail -n +2)"' \
        'adapter_issue_relabel() {' \
        '  local a prev=""' \
        '  for a in "$@"; do [ "$prev" != --remove ] || printf "%s\n" "$a" >>"$RELABEL_LOG"; prev="$a"; done' \
        '  fake_relabel_applied "$@"' \
        '}' >"$traced_adapter"
traced_apply() {
  : >"$relabel_log"
  RELABEL_LOG="$relabel_log" ORCH_GH_ADAPTER="$traced_adapter" orch_gh_failing finding-triage apply "$@"
}
removed_labels() { sort "$relabel_log" | tr '\n' ' '; }
for outcome in close-fixed wontfix ready-for-agent ready-for-human; do
  case "$outcome" in
    close-fixed|wontfix) category_args=() ;;
    *) category_args=(--category bug) ;;
  esac
  # Every other triage role at once, with the outcome's own among them.
  triaged 6 "review:major,needs-triage,needs-info,ready-for-agent,ready-for-human,wontfix,bug"
  out="$(traced_apply 6 "$outcome" ${category_args[@]+"${category_args[@]}"} --comment-file "$comment" 2>&1)"; st=$?
  assert_status "settles a finding carrying every triage role ($outcome)" "$st" 0
  case "$outcome" in
    close-fixed) left="bug review:major " ;;
    wontfix) left="bug review:major wontfix " ;;
    *) left="bug $outcome review:major " ;;
  esac
  assert_eq "leaving only the state $outcome sets" "$(fake_labels_of 6)" "$left"
  # One other role apiece: ready-for-agent, or ready-for-human for ready-for-agent.
  other=ready-for-agent
  [ "$outcome" != ready-for-agent ] || other=ready-for-human
  triaged 7 "review:minor,$other,bug"
  out="$(traced_apply 7 "$outcome" ${category_args[@]+"${category_args[@]}"} --comment-file "$comment" 2>&1)"; st=$?
  assert_status "settles a finding already triaged to $other ($outcome)" "$st" 0
  assert_eq "removing only the label it carries ($outcome)" "$(removed_labels)" "$other "
  case "$outcome" in
    close-fixed) left="bug review:minor " ;;
    wontfix) left="bug review:minor wontfix " ;;
    *) left="bug $outcome review:minor " ;;
  esac
  assert_eq "out of $other ($outcome)" "$(fake_labels_of 7)" "$left"
done
# A finding still in needs-triage names needs-triage alone.
triaged 8 "review:major,needs-triage,bug"
out="$(traced_apply 8 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_eq "a finding in needs-triage removes needs-triage alone" "$(removed_labels)" "needs-triage "
# A finding already carrying the outcome's label keeps it.
triaged 9 "review:major,ready-for-agent,bug"
out="$(traced_apply 9 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_eq "re-applying a finding's own state removes nothing" "$(removed_labels)" ""
assert_eq "and keeps that state" "$(fake_labels_of 9)" "bug ready-for-agent review:major "
# A failed relabel of a triaged finding still dies, after the comment.
triaged 7 "review:minor,ready-for-agent,bug"
fake_fail adapter_issue_relabel "HTTP 502: Bad Gateway"
out="$(traced_apply 7 ready-for-human --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_status "a failed relabel of a triaged finding dies" "$st" 1
assert_contains "saying so" "$out" "gh could not relabel issue #7: HTTP 502: Bad Gateway"
assert_eq "after the comment is posted" "$(fake_comments_of 7)" \
  "$(writeln "$disclaimer" '' 'Fixed by abc1234 on main.')"
assert_eq "and before the labels change" "$(fake_labels_of 7)" "bug ready-for-agent review:minor "
fake_unfail
rm -f "$relabel_log" "$traced_adapter"

# Every state label is the repo's name for the role.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `afk`                | Agent it    |' \
        '| `wontfix`                  | `nope`               | Not doing   |' >docs/agents/triage-labels.md
triaged 2 "review:major,triage me,bug"
out="$(apply 2 ready-for-agent --category bug --comment-file "$comment" 2>&1)"; st=$?
assert_eq "moves a finding between the repo's own triage labels" "$(fake_labels_of 2)" "afk bug review:major "
triaged 3 "review:nit,triage me,enhancement"
out="$(apply 3 wontfix --comment-file "$comment" 2>&1)"; st=$?
assert_eq "wontfix included" "$(fake_labels_of 3)" "enhancement nope review:nit "
rm docs/agents/triage-labels.md
restore_suite_env

# --- finding-triage bundle -----------------------------------------------------
# Bundle is finding triage's write for a group of already-triaged findings: one
# new bundle issue, and every member commented and closed as its duplicate.
# The store-backed fake (fake_github) holds what reached GitHub, so the bundle
# and each member are read back from it. The git side is a bare origin, for
# the scan --all run that shows the members gone from it.
echo
echo "finding-triage bundle"
new_repo >/dev/null
git checkout -q -B main
bundle_bare="$(mktemp -d)/origin.git"
git init -q --bare "$bundle_bare"
bare_origin "$bundle_bare"
git push -q origin main
git -C "$bundle_bare" symbolic-ref HEAD refs/heads/main
fake_github
tab="$(printf '\t')"
disclaimer='> *This was generated by AI during triage.*'
bundle_body="$(mktemp)"
writeln '## #11 - First finding' '' 'Its claim.' '' '## #12 - Second finding' '' 'Its claim.' >"$bundle_body"
# member <n> <labels, comma-separated> [state]: one filed finding in the fake's
# store.
member() {
  local labels=()
  IFS=, read -r -a labels <<<"$2"
  fake_issue "$1" "${3:-open}" "${labels[@]}"
  fake_issue_body "$1" '**Axis:** Spec'
}
bundle() { orch_gh_failing finding-triage bundle "$@"; }
# new_bundle <state> <category> <member>...: the new form, titled "Area".
new_bundle() {
  local state="$1" category="$2"
  shift 2
  bundle --title "Area (2 findings)" --body-file "$bundle_body" --state "$state" --category "$category" "$@"
}

assert_contains "help lists the new bundle form" "$("$ORCH" help)" \
  "finding-triage bundle --title <t> --body-file <f> --state <ready-for-agent|ready-for-human>"
assert_contains "and the --into form" "$("$ORCH" help)" "finding-triage bundle --into <B> <member>..."

# Argument errors die with the usage, writing nothing.
member 11 "review:major,ready-for-agent,bug"
member 12 "review:nit,ready-for-agent,enhancement"
before_store="$(fake_snapshot)"
for args in "" \
  "--body-file $bundle_body --state ready-for-agent --category bug 11 12" \
  "--title T --state ready-for-agent --category bug 11 12" \
  "--title T --body-file $bundle_body --category bug 11 12" \
  "--title T --body-file $bundle_body --state ready-for-agent 11 12" \
  "--title T --body-file $bundle_body --state needs-info --category bug 11 12" \
  "--title T --body-file $bundle_body --state ready-for-agent --category bug 11 x12" \
  "--title T --body-file $bundle_body --state ready-for-agent --category bug" \
  "--title T --body-file $bundle_body --state ready-for-agent --category bug --frobnicate 11 12" \
  "--title" \
  "--into 20 --title T 11" "--into 20 --body-file $bundle_body 11" \
  "--into 20 --state ready-for-agent 11" "--into 20 --category bug 11" \
  "--into x 11" "--into 20"; do
  # shellcheck disable=SC2086 # each case is a word list on purpose
  out="$(bundle $args 2>&1)"; st=$?
  assert_status "refuses '$args'" "$st" 1
  assert_contains "with the usage ('$args')" "$out" "usage: orch.sh finding-triage bundle"
done
unset args
out="$(bundle --title T --body-file /nonexistent/body.md --state ready-for-agent --category bug 11 12 2>&1)"; st=$?
assert_status "refuses a body file that is not there" "$st" 1
assert_contains "naming it" "$out" "/nonexistent/body.md"
# A category that is neither bug nor enhancement dies as apply's does - and
# before the body file is checked.
out="$(bundle --title T --body-file "$bundle_body" --state ready-for-agent --category feature 11 12 2>&1)"; st=$?
assert_status "refuses a category that is neither bug nor enhancement" "$st" 1
assert_eq "in apply's words" "$out" "orch: unknown --category 'feature' - expected bug or enhancement"
out="$(bundle --title T --body-file /nonexistent/body.md --state ready-for-agent --category feature 11 12 2>&1)"; st=$?
assert_status "refuses a bad category with a missing body file" "$st" 1
assert_eq "naming the category first" "$out" "orch: unknown --category 'feature' - expected bug or enhancement"
assert_eq "no argument error wrote anything" "$(fake_snapshot)" "$before_store"

# Each member is checked before any write; a refusal names the member and why.
# refused <name> <wants> <command>...: <command> (new_bundle ... or bundle
# --into ...) refused, its output naming <wants>, with the store as it was.
refused() {
  local name="$1" wants="$2"
  shift 2
  before_store="$(fake_snapshot)"
  out="$("$@" 2>&1)"; st=$?
  assert_status "refuses $name" "$st" 1
  assert_contains "saying so ($name)" "$out" "$wants"
  assert_eq "writing nothing ($name)" "$(fake_snapshot)" "$before_store"
}
member 11 "review:major,ready-for-agent,bug"
member 13 "review:nit,ready-for-agent,bug" closed
refused "a closed member" "issue #13 is not open" new_bundle ready-for-agent bug 11 13
member 13 "review:minor,ready-for-agent,bug"
refused "a member with no filed-severity review label" "issue #13 is not a filed finding" new_bundle ready-for-agent bug 11 13
member 13 "ready-for-agent,bug"
refused "a member with no review label" "issue #13 is not a filed finding" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,needs-triage,bug"
refused "a needs-triage member" "issue #13 carries 'needs-triage'" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,needs-info,ready-for-agent,bug"
refused "a needs-info member" "issue #13 carries 'needs-info'" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,wontfix,ready-for-agent,bug"
refused "a wontfix member" "issue #13 carries 'wontfix'" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,bug"
refused "a member with no triage label" "issue #13 carries neither 'ready-for-agent' nor 'ready-for-human'" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,ready-for-agent,ready-for-human,bug"
refused "a member in both ready states" "issue #13 carries both 'ready-for-agent' and 'ready-for-human'" new_bundle ready-for-human bug 11 13
refused "a new bundle of one member" "a new bundle needs at least 2 members" new_bundle ready-for-agent bug 11
refused "a member named twice" "issue #11 is named twice" new_bundle ready-for-agent bug 11 11
member 13 "review:nit,ready-for-human,enhancement"
refused "ready-for-agent with a ready-for-human member" \
  "--state ready-for-agent, but issue #13 carries 'ready-for-human'" new_bundle ready-for-agent bug 11 13
refused "enhancement with a bug member" \
  "--category enhancement, but issue #11 carries 'bug'" new_bundle ready-for-human enhancement 11 13
# A member with two faults is refused for the one checked first: the member
# check before the state, the state before the category.
member 13 "review:nit,needs-triage,ready-for-human,bug"
refused "a needs-triage, ready-for-human member under ready-for-agent" \
  "issue #13 carries 'needs-triage'" new_bundle ready-for-agent bug 11 13
member 13 "review:nit,ready-for-human,bug"
refused "a ready-for-human, bug member under ready-for-agent enhancement" \
  "--state ready-for-agent, but issue #13 carries 'ready-for-human'" new_bundle ready-for-agent enhancement 13 11
member 13 "review:nit,ready-for-human,enhancement"
fake_fail adapter_issue_state_labels "HTTP 502: Bad Gateway"
refused "a member gh cannot read" "gh could not read issue #11: HTTP 502: Bad Gateway" new_bundle ready-for-human bug 11 13
fake_unfail

# Before bundling, scan --all lists the members.
member 14 "review:nit,needs-triage"
out="$(orch_gh_failing finding-triage scan --all 2>&1)"; st=$?
assert_status "scan --all runs before bundling" "$st" 0
assert_eq "listing every open finding, the members among them" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "11 12 13 14 "

# Success: a stricter state and category than the members' are allowed, and
# both the finding-bundle and the bug label are created where missing.
fake_next_issue 20
out="$(new_bundle ready-for-human bug 11 13 2>&1)"; st=$?
assert_status "bundles two members" "$st" 0
assert_eq "printing the bundle's number alone" "$out" "20"
assert_eq "the bundle is open" "$(fake_state_of 20)" "OPEN"
assert_eq "titled as given" "$(fake_title_of 20)" "Area (2 findings)"
assert_eq "its body as given" "$(fake_body_of 20)" "$(cat "$bundle_body")"
assert_eq "labelled finding-bundle, the state and the category, and no review label" \
  "$(fake_labels_of 20)" "bug finding-bundle ready-for-human "
assert_contains "the finding-bundle label created where missing" "$(fake_labels)" \
  "finding-bundle${tab}c5def5${tab}Several filed findings worked as one"
assert_contains "and the bug label" "$(fake_labels)" "bug${tab}d73a4a${tab}Something isn't working"
for m in 11 13; do
  assert_eq "member #$m commented under the AI disclaimer" "$(fake_comments_of "$m")" \
    "$(writeln "$disclaimer" '' 'Bundled into #20')"
  assert_eq "member #$m closed as a duplicate" "$(fake_state_of "$m") $(fake_reason_of "$m")" "CLOSED duplicate"
  assert_eq "of the bundle (#$m)" "$(fake_duplicate_of "$m")" "20"
done
assert_eq "member #11 keeps its labels" "$(fake_labels_of 11)" "bug ready-for-agent review:major "
assert_eq "member #13 keeps its labels" "$(fake_labels_of 13)" "enhancement ready-for-human review:nit "
unset m

# After it, scan --all lists neither the bundle nor its members.
out="$(orch_gh_failing finding-triage scan --all 2>&1)"; st=$?
assert_status "scan --all runs after bundling" "$st" 0
assert_eq "listing neither the bundle nor its closed members" \
  "$(printf '%s\n' "$out" | cut -f1 | tr '\n' ' ')" "12 14 "

# A finding-bundle label gh will not create - the repo has it - does not stop
# a bundle, and the repo's own is left as it is.
member 15 "review:major,ready-for-agent,bug"
member 16 "review:nit,ready-for-agent,bug"
fake_label finding-bundle 123456 "The repo's own"
fake_fail adapter_label_create
fake_next_issue 21
out="$(new_bundle ready-for-agent bug 15 16 2>&1)"; st=$?
assert_status "a failed finding-bundle label create still bundles where the label exists" "$st" 0
assert_eq "labelled as asked" "$(fake_labels_of 21)" "bug finding-bundle ready-for-agent "
assert_contains "the repo's own label left as it is" "$(fake_labels)" "finding-bundle${tab}123456${tab}The repo's own"
assert_eq "its members closed into it" "$(fake_duplicate_of 15) $(fake_duplicate_of 16)" "21 21"
fake_unfail

# A failed bundle create touches no member.
member 17 "review:major,ready-for-agent,bug"
member 18 "review:nit,ready-for-agent,enhancement"
fake_fail adapter_issue_create $'HTTP 502: Bad Gateway\nsecond line'
out="$(new_bundle ready-for-agent bug 17 18 2>&1)"; st=$?
assert_status "a failed bundle create dies" "$st" 1
assert_eq "with gh's line, saying no member was touched" "$out" \
  "orch: gh could not create the bundle issue: HTTP 502: Bad Gateway - no member was touched"
for m in 17 18; do
  assert_eq "member #$m left open" "$(fake_state_of "$m")" "OPEN"
  assert_eq "and uncommented (#$m)" "$(fake_comments_of "$m")" ""
done
unset m
fake_unfail
fake_fail_times adapter_issue_create 9
out="$(new_bundle ready-for-agent bug 17 18 2>&1)"; st=$?
assert_status "a silent bundle create failure dies" "$st" 1
assert_eq "saying gh gave no reason" "$out" \
  "orch: gh could not create the bundle issue: gh gave no reason - no member was touched"
fake_unfail

# A member failure stops the bundle part-way: it dies naming the bundle and
# the members left open, with the --into command that resumes, and that
# command finishes the job - no second bundle, never an edit to the bundle,
# and exactly one `Bundled into #B` comment on every member.
# partial <name> <B> <wants> <left> [adapter]: a new bundle #B of members 31,
# 32 and 33 dies with <wants>, leaving <left> (space-separated) open; the
# fake's failure is seeded by the caller, and <adapter> stands in for the
# fake where given.
partial() {
  local name="$1" b="$2" wants="$3" left="$4" adapter="${5:-$GH_ADAPTER_FAKE}" m
  for m in 31 32 33; do member "$m" "review:major,ready-for-agent,bug"; done
  fake_next_issue "$b"
  out="$(ORCH_GH_ADAPTER="$adapter" new_bundle ready-for-agent bug 31 32 33 2>&1)"; st=$?
  fake_unfail
  assert_status "$name dies" "$st" 1
  assert_contains "$name: saying what failed" "$out" "$wants"
  assert_not_contains "$name: with gh's first line only" "$out" "second line"
  assert_contains "$name: naming the bundle and the members left open" "$out" \
    "bundle #$b: "
  assert_contains "$name: listing the members left open" "$out" "members left open: #${left// / #};"
  assert_contains "$name: with the --into command that resumes" "$out" \
    "resume with: orch.sh finding-triage bundle --into $b $left"
  for m in $left; do
    assert_eq "$name: member #$m left open" "$(fake_state_of "$m")" "OPEN"
  done
  resumed "$name" "$b" "$left"
}
# resumed <name> <B> <members>: --into <B> <members> finishes the bundle,
# leaving B as it was and creating no other issue.
resumed() {
  local name="$1" b="$2" m before_b before_issues
  # shellcheck disable=SC2086 # the members are a word list on purpose
  set -- $3
  before_b="$(fake_title_of "$b")|$(fake_body_of "$b")|$(fake_labels_of "$b")|$(fake_comments_of "$b")"
  before_issues="$(fake_issues)"
  out="$(bundle --into "$b" "$@" 2>&1)"; st=$?
  assert_status "$name: --into finishes the job" "$st" 0
  assert_eq "$name: creating no second bundle" "$(fake_issues)" "$before_issues"
  assert_eq "$name: and never editing the bundle" \
    "$(fake_title_of "$b")|$(fake_body_of "$b")|$(fake_labels_of "$b")|$(fake_comments_of "$b")" "$before_b"
  for m in 31 32 33; do
    assert_eq "$name: member #$m commented exactly once" "$(fake_comments_of "$m")" \
      "$(writeln "$disclaimer" '' "Bundled into #$b")"
    assert_eq "$name: member #$m closed as a duplicate of the bundle" \
      "$(fake_state_of "$m") $(fake_reason_of "$m") $(fake_duplicate_of "$m")" "CLOSED duplicate $b"
  done
}
fake_fail_after adapter_issue_comment 1 $'HTTP 502: Bad Gateway\nsecond line'
partial "a failed comment" 40 \
  "orch: bundle #40: gh could not comment on member #32: HTTP 502: Bad Gateway - members left open: #32 #33; resume with: orch.sh finding-triage bundle --into 40 32 33" "32 33"
fake_fail_after adapter_issue_close 1 $'HTTP 502: Bad Gateway\nsecond line'
partial "a failed close" 41 \
  "orch: bundle #41: gh could not close member #32 as a duplicate: HTTP 502: Bad Gateway - --duplicate-of needs gh 2.102 or newer - members left open: #32 #33; resume with: orch.sh finding-triage bundle --into 41 32 33" "32 33"
fake_fail adapter_issue_comments $'HTTP 502: Bad Gateway\nsecond line'
partial "a failed comments read" 42 \
  "orch: bundle #42: gh could not read member #31's comments: HTTP 502: Bad Gateway - members left open: #31 #32 #33; resume with: orch.sh finding-triage bundle --into 42 31 32 33" "31 32 33"
fake_fail_after adapter_issue_comment 1 ""
partial "a silent failed comment" 48 \
  "orch: bundle #48: gh could not comment on member #32: gh gave no reason - members left open: #32 #33; resume with: orch.sh finding-triage bundle --into 48 32 33" "32 33"
# A failed state read-back dies the same way; the member may in truth be
# closed, so it is not resumed here.
for m in 31 32 33; do member "$m" "review:major,ready-for-agent,bug"; done
fake_next_issue 43
fake_fail_after adapter_issue_state 2 $'HTTP 502: Bad Gateway\nsecond line'
out="$(new_bundle ready-for-agent bug 31 32 33 2>&1)"; st=$?
fake_unfail
assert_status "a failed state read-back dies" "$st" 1
assert_contains "naming the bundle, the member, gh's line and the --into command" "$out" \
  "orch: bundle #43: gh could not read member #33's state back: HTTP 502: Bad Gateway - members left open: #33; resume with: orch.sh finding-triage bundle --into 43 33"
assert_not_contains "with gh's first line only" "$out" "second line"
unset m
noop_close_adapter="$(mktemp)"
writeln "source $(printf %q "$GH_ADAPTER_FAKE")" 'adapter_issue_close() { :; }' >"$noop_close_adapter"
partial "a close that reports success but reads back open" 44 \
  "member #31 did not read back as closed" "31 32 33" "$noop_close_adapter"
rm -f "$noop_close_adapter"

# --into checks its members as the new form does - one is enough - and B
# itself, before any write.
member 34 "review:major,ready-for-agent,bug"
member 35 "review:nit,needs-triage"
fake_issue 45 closed finding-bundle ready-for-agent bug
refused "--into: a closed bundle" "bundle #45 is not open" bundle --into 45 34
fake_issue 46 open ready-for-agent bug
refused "--into: an issue without finding-bundle" "issue #46 carries no 'finding-bundle' label" bundle --into 46 34
fake_issue 47 open finding-bundle ready-for-agent bug
refused "--into: a member already closed" "issue #31 is not open" bundle --into 47 34 31
refused "--into: a needs-triage member" "issue #35 carries 'needs-triage'" bundle --into 47 34 35
refused "--into: a member named twice" "issue #34 is named twice" bundle --into 47 34 34
fake_fail adapter_issue_state_labels "HTTP 502: Bad Gateway"
refused "--into: a bundle gh cannot read" "gh could not read issue #47: HTTP 502: Bad Gateway" bundle --into 47 34
fake_unfail
out="$(bundle --into 47 34 2>&1)"; st=$?
assert_status "--into takes a single member" "$st" 0
assert_eq "closing it into the bundle" "$(fake_state_of 34) $(fake_duplicate_of 34)" "CLOSED 47"
# --into checks no member's state or category against the bundle's.
member 36 "review:nit,ready-for-human,enhancement"
out="$(bundle --into 47 36 2>&1)"; st=$?
assert_status "--into takes a ready-for-human, enhancement member" "$st" 0
assert_eq "closing it into the bundle too" "$(fake_state_of 36) $(fake_duplicate_of 36)" "CLOSED 47"

# Every state label is the repo's name for the role, checked and applied.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `afk`                | Agent it    |' \
        '| `ready-for-human`          | `hitl`               | Human it    |' >docs/agents/triage-labels.md
member 17 "review:major,afk,bug"
member 18 "review:nit,triage me,enhancement"
refused "a member in the repo's own needs-triage" "issue #18 carries 'triage me'" new_bundle ready-for-agent bug 17 18
member 18 "review:nit,hitl,enhancement"
fake_next_issue 22
out="$(new_bundle ready-for-human bug 17 18 2>&1)"; st=$?
assert_status "bundles members in the repo's own ready labels" "$st" 0
assert_eq "labelling the bundle with the repo's label for its state" \
  "$(fake_labels_of 22)" "bug finding-bundle hitl "
rm docs/agents/triage-labels.md

# The bundle is an ordinary issue afterwards: issue triage takes it as one,
# and init --issue adopts a ready-for-agent bundle.
healthy_repo
out="$("$ORCH" issue triage 21 2>&1)"; st=$?
assert_status "issue triage does not refuse a bundle as a filed finding" "$st" 0
assert_not_contains "naming no filed finding" "$out" "filed finding"
out="$("$ORCH" init adopted --issue 21 2>&1)"; st=$?
assert_status "init --issue adopts a ready-for-agent bundle" "$st" 0
assert_eq "recording it" "$("$ORCH" state get issue)" "21"
rm -f "$bundle_body"
restore_suite_env
