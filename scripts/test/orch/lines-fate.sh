# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- lines_fate ---------------------------------------------------------------
# What became of a range of lines at a ref since a commit filed them, asked
# directly: lines_fate called in a shell that sourced orch.sh, against one git
# repository with no origin, no second clone and no GitHub fake. The cases the
# scan used to prove through a printed line live here, keeping fate and,
# for changed, its commit.

echo
echo "lines_fate"
new_repo >/dev/null
git remote remove origin
git checkout -q -B main
lf_seq() { local i; for i in $(seq 1 "$2"); do echo "$1 line $i"; done; }
# lf_edit <file> <sed script> <message>: commits the edit to src/<file> on the
# checked-out branch, printing its SHA.
lf_edit() {
  sed -i "$2" "src/$1"
  git commit -qam "$3"
  git rev-parse HEAD
}
# lf_branch_head <branch> <base sha> <file> <sed script>: a PR head off <base
# sha> that edits src/<file>, on a branch of its own the default branch never
# merges; prints its SHA, leaving main checked out.
lf_branch_head() {
  git checkout -q -b "$1" "$2"
  lf_edit "$3" "$4" "the PR's own edit"
  git checkout -q main
}
# lf_squash_head <n> <file> <line>: a PR head off $filed_sha that inserts <line>
# on top of src/<file>, then the squash commit that lands the same edit on main;
# prints the PR head's SHA, left on main.
lf_squash_head() {
  lf_branch_head "pr$1" "$filed_sha" "$2" "1i $3"
  lf_edit "$2" "1i $3" "the PR, squash-merged" >/dev/null
}
# lf_case <name> <filed sha> <file> <start> <end>: one case, asked of main.
lf_cases="$(mktemp)"
# lf_case_in <file> <name> <sha> <file> <start> <end> [<bin>]: a case row.
lf_case_in() { (IFS=$'\t'; printf '%s\n' "${*:2}") >>"$1"; }
lf_case() { lf_case_in "$lf_cases" "$@"; }

mkdir -p src
lf_seq app 12 >src/app.sh
lf_seq other 4 >src/other.sh
git add -A && git commit -qm "the reviewed code"
head_sha="$(git rev-parse HEAD)"
fix_sha="$(lf_edit app.sh 's/^app line 3$/app line 3, fixed/' "fix line 3")"
reword_sha="$(lf_edit app.sh 's/^app line 11$/app line 11, reworded/' "reword line 11")"
lf_case fixed "$head_sha" src/app.sh 3 3
lf_case untouched "$head_sha" src/app.sh 6 6
lf_case reversed "$head_sha" src/app.sh 3 1
lf_case pastend "$head_sha" src/app.sh 40 41

# A PR head that edited the file and never reached the default branch.
unmerged_sha="$(lf_branch_head pr11 "$head_sha" other.sh 's/^other line 2$/other line 2, on the PR only/')"
lf_case unmerged "$unmerged_sha" src/other.sh 2 2

# A head with no history in common with main: no merge base, so the newest
# commit touching the file stands in.
git checkout -q --orphan unrelated
{ echo "other line 1"; echo "an unrelated line"; echo "other line 2"; } >src/other.sh
git add src/other.sh
git commit -qm "an unrelated history"
unrelated_sha="$(git rev-parse HEAD)"
git checkout -q -f main
lf_case nomergebase "$unrelated_sha" src/other.sh 2 2

# A file whose later hunks come both before and after the finding's line, with
# far more diff after it than a pipe buffer holds.
lf_seq "big file" 6000 >src/big.sh
git add src/big.sh
git commit -qm "a big file"
big_sha="$(git rev-parse HEAD)"
{ lf_seq inserted 5; cat src/big.sh; } >big.tmp && mv big.tmp src/big.sh
git commit -qam "insert five lines on top"
shifted_fix_sha="$(lf_edit big.sh 's/^big file line 10$/big file line 10, fixed/' "fix the shifted line")"
lf_edit big.sh '200,$ s/$/, rewritten in bulk/' "rewrite everything below" >/dev/null
lf_case big "$big_sha" src/big.sh 10 10

# Lines main later deleted outright: one file per case, all filed at one commit,
# each deleted by its own commit after it.
for f in whole end start middle later two replaced squashed split; do lf_seq "$f" 30 >"src/del_$f.sh"; done
git add src
git commit -qm "the code the deletions are filed against"
filed_sha="$(git rev-parse HEAD)"
whole_sha="$(lf_edit del_whole.sh '8,12d' "delete the whole range")"
end_sha="$(lf_edit del_end.sh '18,25d' "delete the range's end")"
start_sha="$(lf_edit del_start.sh '5,12d' "delete the range's start")"
middle_sha="$(lf_edit del_middle.sh '14,16d' "delete the range's middle")"
later_del_sha="$(lf_edit del_later.sh '8,12d' "delete before a later edit")"
later_edit_sha="$(lf_edit del_later.sh 's/^later line 1$/later line 1, reworded/' "a later, unrelated edit")"
lf_edit del_two.sh '18,20d' "delete the range's end first" >/dev/null
two_sha="$(lf_edit del_two.sh '10,12d' "then delete its start")"
replaced_sha="$(lf_edit del_replaced.sh '9,11c\replaced line' "replace three lines with one")"
squash_head_sha="$(lf_squash_head 37 del_squashed.sh 'squashed pr line')"
squashed_sha="$(lf_edit del_squashed.sh '9,13d' "delete the squash-merged lines")"
lf_edit del_squashed.sh 's/^squashed line 30$/squashed line 30, reworded/' "a later edit to the squashed file" >/dev/null
split_head_sha="$(lf_squash_head 38 del_split.sh 'split pr line')"
split_sha="$(lf_edit del_split.sh '9,10d;12,13d' "delete the squash-merged lines in two hunks")"
lf_case del_whole "$filed_sha" src/del_whole.sh 10 10
lf_case del_end "$filed_sha" src/del_end.sh 10 20
lf_case del_start "$filed_sha" src/del_start.sh 10 20
lf_case del_middle "$filed_sha" src/del_middle.sh 10 20
lf_case del_later "$filed_sha" src/del_later.sh 10 10
lf_case del_two "$filed_sha" src/del_two.sh 10 20
lf_case del_replaced "$filed_sha" src/del_replaced.sh 10 10
lf_case del_squashed "$squash_head_sha" src/del_squashed.sh 11 11
lf_case del_split "$split_head_sha" src/del_split.sh 9 13

# A deletion main made of lines held by a head off its history, for the case
# whose merge-base lookup fails: the head edits another line, main deletes.
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13; do lf_seq "um$i" 20 >"src/um$i.sh"; done
lf_seq mb 30 >src/mb.sh
git add src
git commit -qm "the code the unmerged PRs edit"
unm_base="$(git rev-parse HEAD)"
mb_head_sha="$(lf_branch_head mbpr "$unm_base" mb.sh '1c\pr replaced')"
mb_del_sha="$(lf_edit mb.sh '8,12d' "delete mb's lines")"
lf_case mb_deleted "$mb_head_sha" src/mb.sh 10 10

# PR heads that never merged: the cases decide by the filed lines, never by the
# file. One file per case, each a 20-line file the PR edits and main then edits
# elsewhere or alike.
lf_unm() { lf_branch_head "unm$1" "$unm_base" "$2" "$3"; }
sha51="$(lf_unm 51 um1.sh '5c\pr replaced')"
sha52="$(lf_unm 52 um2.sh '5a pr added a\npr added b')"
sha53="$(lf_unm 53 um3.sh '6d')"
sha54="$(lf_unm 54 um4.sh '2c\pr replaced')"
sha55="$(lf_unm 55 um5.sh $'8i pr above\n9a pr below')"
sha56="$(lf_unm 56 um6.sh '5c\pr replaced')"
sha57="$(lf_unm 57 um7.sh '5c\pr replaced')"
sha58="$(lf_unm 58 um8.sh '5a pr added a\npr added b')"
sha59="$(lf_unm 59 um9.sh '5a pr added a\npr added b')"
sha60="$(lf_unm 60 um10.sh '2c\pr replaced')"
sha61="$(lf_unm 61 um11.sh '2c\pr replaced')"
sha62="$(lf_unm 62 um12.sh '2c\pr replaced')"
# um13 is um5's twin that main never edits: no commit on the ref touched the
# file since the filed SHA, so the differs-at-all test alone decides.
sha63="$(lf_unm 63 um13.sh $'8i pr above\n9a pr below')"
lf_edit um1.sh 's/^um1 line 15$/um1 line 15, reworded/' "an unrelated edit to um1" >/dev/null
lf_edit um2.sh 's/^um2 line 15$/um2 line 15, reworded/' "an unrelated edit to um2" >/dev/null
lf_edit um3.sh 's/^um3 line 15$/um3 line 15, reworded/' "an unrelated edit to um3" >/dev/null
um4_del_sha="$(lf_edit um4.sh '8,9d' "delete um4's lines")"
lf_edit um4.sh 's/^um4 line 15$/um4 line 15, reworded/' "an unrelated edit to um4" >/dev/null
lf_edit um5.sh 's/^um5 line 15$/um5 line 15, reworded/' "an unrelated edit to um5" >/dev/null
um6_sha="$(lf_edit um6.sh 's/^um6 line 5$/um6 line 5, reworded/' "reword um6's line")"
um7_sha="$(lf_edit um7.sh 's/^um7 line 8$/um7 line 8, reworded/' "reword um7's line")"
um8_sha="$(lf_edit um8.sh 's/^um8 line 6$/um8 line 6, reworded/' "reword um8's line")"
um9_del_sha="$(lf_edit um9.sh '6d' "delete um9's line")"
lf_edit um9.sh 's/^um9 line 15$/um9 line 15, reworded/' "an unrelated edit to um9" >/dev/null
lf_edit um10.sh 's/^um10 line 15$/um10 line 15, reworded/' "an earlier edit to um10" >/dev/null
um10_del_sha="$(lf_edit um10.sh '8,9d' "delete um10's lines")"
um12_sha="$(lf_edit um12.sh 's/^um12 line 15$/um12 line 15, reworded/' "an edit to um12")"
lf_case um51 "$sha51" src/um1.sh 5 5
lf_case um52 "$sha52" src/um2.sh 6 7
lf_case um53 "$sha53" src/um3.sh 5 6
lf_case um54 "$sha54" src/um4.sh 8 9
lf_case um55 "$sha55" src/um5.sh 9 10
lf_case um56 "$sha56" src/um6.sh 5 5
lf_case um57 "$sha57" src/um7.sh 5 8
lf_case um58 "$sha58" src/um8.sh 6 8
lf_case um59 "$sha59" src/um9.sh 6 8
lf_case um60 "$sha60" src/um10.sh 8 9
lf_case um61 "$sha61" src/um11.sh 25 25
lf_case um62 "$sha62" src/um12.sh 25 25
lf_case um63 "$sha63" src/um13.sh 9 10

# A git whose every command of one kind fails: lines_fate still returns 0, each
# failure taking its stand-in. Each case's calls run under its own stand-in git
# (the cases file's sixth column), asked in the same sourced shell as the rest.
# shellcheck disable=SC2016 # globs for the stand-in git, not expansions
{
  lf_case fail_diff "$head_sha" src/app.sh 3 3 "$(git_fails_bin '*" diff "*')"
  lf_case fail_blame "$filed_sha" src/del_later.sh 10 10 "$(git_fails_bin '*" blame "*')"
  lf_case fail_merge_base "$mb_head_sha" src/mb.sh 10 10 "$(git_fails_bin '*" merge-base "*')"
  lf_case fail_cat_file "$head_sha" src/other.sh 2 2 "$(git_fails_bin '*" cat-file "*')"
}

# lf_ask <cases file>: for each case (an optional sixth column names a directory
# put first on PATH for its calls), lines_fate asked once from the root and
# once from src/, its standard output sent to a file; one tab-separated row per
# case: name, fate, detail, status, quiet (yes when nothing was printed from
# either place), the subdirectory's fate, its detail and its status. Every call
# names its out-variables result and detail and is made in the sourced shell
# itself, never inside a command substitution.
# shellcheck disable=SC2016 # expanded by the inner bash
LF_ASK='
  root="$PWD"; out="$(mktemp)"
  while IFS=$'"'"'\t'"'"' read -r -u 3 name sha file start end bin; do
    PATH="${bin:+$bin:}$PATH" lines_fate "$sha" main "$file" "$start" "$end" result detail >"$out"; rc=$?
    quiet=yes; [ ! -s "$out" ] || quiet=no
    first_result="$result" first_detail="$detail"
    cd "$root/src" || exit 1
    PATH="${bin:+$bin:}$PATH" lines_fate "$sha" main "$file" "$start" "$end" result detail >"$out"; sub_rc=$?
    cd "$root" || exit 1
    [ ! -s "$out" ] || quiet=no
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$name" "$first_result" "$first_detail" "$rc" "$quiet" "$result" "$detail" "$sub_rc"
  done 3<"$1"'
# lf_assert <rows> <case> <fate> [<commit>]: the case's answer from the root,
# the same answer from a subdirectory, and a status of 0 with nothing printed.
lf_assert() {
  local row n f2 f3 f4 f5 f6 f7 f8
  row="$(awk -F'\t' -v n="$2" '$1 == n' "$1")"
  row="${row//$'\t'/|}" # a tab would fold empty fields away
  IFS='|' read -r n f2 f3 f4 f5 f6 f7 f8 <<<"$row"
  assert_eq "$2: its fate and commit" "$f2	$f3" "$(printf '%s\t%s' "$3" "${4:-}")"
  assert_eq "$2: the same from a subdirectory" "$f6	$f7" "$f2	$f3"
  assert_eq "$2: returns 0 from both places and prints nothing" "$f4	$f5	$f8" "$(printf '0\tyes\t0')"
}

rows="$(mktemp)"
sourced_orch_script "$LF_ASK" "$lf_cases" >"$rows"
assert_eq "every case is answered" "$(wc -l <"$rows" | tr -d ' ')" "$(wc -l <"$lf_cases" | tr -d ' ')"
lf_assert "$rows" fixed changed "$fix_sha"
lf_assert "$rows" untouched unchanged
lf_assert "$rows" reversed changed "$fix_sha"
lf_assert "$rows" pastend changed "$reword_sha"
lf_assert "$rows" unmerged never-reached
lf_assert "$rows" nomergebase changed "$head_sha"
lf_assert "$rows" big changed "$shifted_fix_sha"
lf_assert "$rows" del_whole changed "$whole_sha"
lf_assert "$rows" del_end changed "$end_sha"
lf_assert "$rows" del_start changed "$start_sha"
lf_assert "$rows" del_middle changed "$middle_sha"
lf_assert "$rows" del_later changed "$later_del_sha"
lf_assert "$rows" del_two changed "$two_sha"
lf_assert "$rows" del_replaced changed "$replaced_sha"
lf_assert "$rows" del_squashed changed "$squashed_sha"
lf_assert "$rows" del_split changed "$split_sha"
lf_assert "$rows" um51 never-reached
lf_assert "$rows" um52 never-reached
lf_assert "$rows" um53 never-reached
lf_assert "$rows" um54 changed "$um4_del_sha"
lf_assert "$rows" um55 unchanged
lf_assert "$rows" um56 changed "$um6_sha"
lf_assert "$rows" um57 changed "$um7_sha"
lf_assert "$rows" um58 changed "$um8_sha"
lf_assert "$rows" um59 changed "$um9_del_sha"
lf_assert "$rows" um60 changed "$um10_del_sha"
# A range past the file's end, filed at a head whose own commits changed the
# file, where no commit on main touched it: the stand-in's never-reached arm.
lf_assert "$rows" um61 never-reached
lf_assert "$rows" um62 changed "$um12_sha"
lf_assert "$rows" um63 unchanged
lf_assert "$rows" mb_deleted changed "$mb_del_sha"
lf_assert "$rows" fail_diff changed "$fix_sha"
lf_assert "$rows" fail_blame changed "$later_edit_sha"
lf_assert "$rows" fail_merge_base changed "$mb_del_sha"
lf_assert "$rows" fail_cat_file gone
rm -f "$lf_cases" "$rows"

# Cost: git's own trace counts the diffs of the filed SHA against the ref - one
# per finding, whatever its fate. Each call writes its own trace file, and
# GIT_TRACE is set only for the call, after orch.sh is sourced, whose own start
# is not counted. Both counts are asked in one sourced shell.
# shellcheck disable=SC2016 # expanded by the inner bash
LF_COUNT='
  count() {
    local sha="$1" t o
    t="$(mktemp)" o="$(mktemp)"
    GIT_TRACE="$t" lines_fate "$sha" main "$2" "$3" "$4" result detail >"$o"
    printf "%s %s\n" "$(grep "trace: built-in: git diff " "$t" | grep -- "$sha" | grep -c -w main)" "$([ -s "$o" ] && echo loud || echo quiet)"
    rm -f "$t" "$o"
  }
  count "$1" src/other.sh 2 2
  count "$2" src/del_whole.sh 10 10'
lf_counts="$(sourced_orch_script "$LF_COUNT" "$unmerged_sha" "$filed_sha")"
assert_eq "an off-ref never-reached finding is diffed once, printing nothing" "${lf_counts%%$'\n'*}" "1 quiet"
assert_eq "an on-ref finding whose lines were deleted is diffed once, printing nothing" "${lf_counts#*$'\n'}" "1 quiet"
