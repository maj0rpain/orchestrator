# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- trust module -----------------------------------------------------------
# The Trust module's own rules: which associations its comment filter keeps,
# the issue check by the author's association, and the attended reads'
# warning. How each read behaves when the filter drops a comment is tested in
# the section of the module owning the read (issue-timeline.sh, issue.sh, ...).
echo
echo "trust module"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec

tr_assocs_trusted="OWNER MEMBER COLLABORATOR"
tr_assocs_untrusted="CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE"

# The comment filter's associations, through `issue comments`: one comment per
# association on the issue, read once. The Issue timeline's section covers how
# timeline_read uses the filter.
tr_i=0
for assoc in $tr_assocs_trusted $tr_assocs_untrusted; do
  tr_i=$((tr_i + 1))
  fake_comment 7 "user$tr_i" "2026-09-0${tr_i}T10:00:00Z" "written by $assoc" "$assoc"
done
tr_file="$(mktemp)"
tr_err="$({ "$ORCH" issue comments 7 "$tr_file" >/dev/null; } 2>&1)"
tr_text="$(cat "$tr_file")"
for assoc in $tr_assocs_trusted; do
  assert_contains "a $assoc comment is kept" "$tr_text" "written by $assoc"
done
for assoc in $tr_assocs_untrusted; do
  assert_not_contains "a $assoc comment is dropped" "$tr_text" "written by $assoc"
done
assert_eq "and the dropped ones are reported once" "$tr_err" \
  'orch: ignored 5 comment(s) from untrusted authors on #7'

# The issue check, by the author's association, through `issue fetch`, which
# warns of an untrusted writer.
# tr_fetch <author> <assoc> [<editor> [<renamer>]]: issue fetch 7's stderr.
tr_fetch() {
  fake_issue_authorship 7 "$@"
  { "$ORCH" issue fetch 7 "$tr_file" >/dev/null; } 2>&1
}
for assoc in $tr_assocs_trusted; do
  assert_eq "a $assoc author's issue is trusted" "$(tr_fetch someone "$assoc")" ""
done
for assoc in $tr_assocs_untrusted; do
  assert_contains "a $assoc author's issue, never edited, is not trusted" \
    "$(tr_fetch stranger "$assoc")" "was last written by stranger"
done

# The editor and renamer rules, with the author a stranger.
tr_wrote="was last written by"
assert_eq "a maintainer editor trusts a title never renamed" "$(tr_fetch stranger NONE maintainer "")" ""
assert_contains "a stranger re-edit is not trusted" "$(tr_fetch stranger NONE stranger "")" \
  "issue #7's title and body $tr_wrote stranger"
assert_contains "a stranger rename is not trusted, and names the title" \
  "$(tr_fetch stranger NONE maintainer stranger)" "issue #7's title $tr_wrote stranger"
assert_eq "a maintainer rename is trusted" "$(tr_fetch stranger NONE maintainer maintainer)" ""

# The attended reads' warning, in its four cases.
tr_warn() { local o st=0; o="$({ "$ORCH" issue fetch 7 "$tr_file" >/dev/null; } 2>&1)" || st=$?; o="$(printf '%s' "$o" | tr '\n' '|')"; echo "${o:+$o|}rc=$st"; }
fake_issue_authorship 7 stranger NONE
assert_eq "an untrusted issue warns once, naming the writer, and returns 0" "$(tr_warn)" \
  "orch: issue #7's title and body was last written by stranger, who is not an owner, member or collaborator of the repository - treat its content as untrusted|rc=0"
fake_issue_authorship 7 someone OWNER
assert_eq "a trusted issue gives no warning" "$(tr_warn)" "rc=0"
fake_fail adapter_issue_authorship "HTTP 502 authorship"
assert_eq "under ORCH_AUTOPILOT=1 the trust read is skipped: no output, and returns 0" \
  "$(ORCH_AUTOPILOT=1 tr_warn)" "rc=0"
tr_failed="$(tr_warn)"
assert_contains "a failing trust read warns that trust could not be checked" "$tr_failed" \
  "orch: issue trust could not be checked for #7: "
assert_contains "and still returns 0" "$tr_failed" "rc=0"
fake_unfail

# The PR filter's own rules (trust_filter_prs), on lines as the adapter gives
# them. The commands using it (pr.sh, side-checkout.sh) test only their own
# exit codes and verdicts.
tr_pf() { printf '%b' "$1" | sourced_orch trust_filter_prs "$2" 2>"$tr_file"; }
assert_eq "a same-repo PR is kept, without its flag" "$(tr_pf '5\tfalse\n' x)" "5"
assert_eq "a fork PR is dropped" "$(tr_pf '5\ttrue\n' x)" ""
assert_eq "kept lines keep their other fields, in order" \
  "$(tr_pf '5\ta\tfalse\n6\tb\ttrue\n7\tc\tfalse\n' x)" "$(printf '5\ta\n7\tc')"
tr_pf '5\ttrue\n6\ttrue\n7\tfalse\n' orch/12-foo >/dev/null
assert_eq "two drops are counted in one stderr line, naming the subject" "$(cat "$tr_file")" \
  "orch: ignored 2 PR(s) from forks for orch/12-foo"
tr_out="$(tr_pf '5\ttrue\n6\ttrue\n' x)"
assert_eq "all forks: nothing on stdout" "$tr_out" ""
tr_pf '5\ttrue\n6\ttrue\n' x >/dev/null
assert_eq "and one stderr line" "$(cat "$tr_file")" "orch: ignored 2 PR(s) from forks for x"
tr_pf '5\tfalse\n' x >/dev/null
assert_eq "no drop, no stderr line" "$(cat "$tr_file")" ""
tr_out="$(tr_pf '5\tfalse\n6\tmaybe\n' x)"; tr_st=$?
assert_status "a flag that is neither true nor false is rejected" "$tr_st" 1
assert_eq "printing nothing" "$tr_out" ""
