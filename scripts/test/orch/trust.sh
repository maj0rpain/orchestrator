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
# warns of an untrusted writer; the pickup's own check of MEMBER and
# COLLABORATOR authors is in the autopilot tick trust section.
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
assert_eq "under ORCH_AUTOPILOT=1 an untrusted issue gives no warning" \
  "$(fake_issue_authorship 7 stranger NONE; ORCH_AUTOPILOT=1 tr_warn)" "rc=0"
fake_fail adapter_issue_authorship "HTTP 502 authorship"
assert_contains "a failing trust read warns that trust could not be checked, and returns 0" "$(tr_warn)" \
  "orch: issue trust could not be checked for #7: "
assert_contains "and still returns 0" "$(tr_warn)" "rc=0"
fake_unfail
