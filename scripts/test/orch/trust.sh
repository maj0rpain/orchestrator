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

# tr_run <script>: reads issue #7's timeline, runs the script; its stdout and
# stderr, newlines as "|", then "rc=<status>".
tr_run() {
  sourced_orch_script 'rc=0; ( timeline_read 7; '"$1"' ) || rc=$?; echo "rc=$rc"' 2>&1 | tr '\n' '|' | sed 's/|$//'
}
# tr_seed <association> <comment>: appends a comment by "someone" on issue #7.
tr_seed() { fake_comment 7 someone 2026-01-01T00:00:00Z "$2" "$1"; }

TR_Q="$(marker_of question spec)
what?"
TR_WARN='orch: ignored 1 comment(s) from untrusted authors on #7'

# The comment filter's associations, observed through the Issue timeline's
# question query.
for assoc in OWNER MEMBER COLLABORATOR; do
  fake_comments_clear 7
  tr_seed "$assoc" "$TR_Q"
  assert_eq "a $assoc comment is read, and not reported" \
    "$(tr_run 'timeline_question spec; echo "q=$TIMELINE_Q_INDEX"')" "q=0|rc=0"
done
for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE; do
  fake_comments_clear 7
  tr_seed "$assoc" "$TR_Q"
  assert_eq "a $assoc comment is dropped" \
    "$(tr_run 'timeline_question spec; echo "q=[$TIMELINE_Q_INDEX]"')" "$TR_WARN|q=[]|rc=0"
done

# The issue check, by the author's association: an issue never edited is as
# trusted as its author.
for assoc in OWNER MEMBER COLLABORATOR; do
  fake_issue_authorship 7 someone "$assoc"
  assert_eq "a $assoc author's issue is trusted" \
    "$(sourced_orch_script 'rc=0; trust_issue_check 7 || rc=$?; echo $rc' 2>&1)" "0"
done
for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE; do
  fake_issue_authorship 7 stranger "$assoc"
  assert_eq "a $assoc author's issue, never edited, is not trusted" \
    "$(sourced_orch_script 'rc=0; trust_issue_check 7 || rc=$?; echo $rc' 2>&1)" "1"
done

# The attended reads' warning, in its four cases.
tr_warn() { sourced_orch_script 'trust_warn_issue 7; echo "rc=$?"' 2>&1 | tr '\n' '|' | sed 's/|$//'; }
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
