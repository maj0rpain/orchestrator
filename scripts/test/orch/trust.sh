# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- trust module -----------------------------------------------------------
# The Trust module's comment filter, observed through the Issue timeline's
# queries over comment histories seeded in the gh fake: a stranger's comment is
# invisible, an owner's equivalent is read.
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
TR_HO="$(marker_of handoff 01-plan)
plan"
TR_HO_RETIRED="$(marker_of handoff 01-plan retired)
Retired"
TR_STOP_F="$(marker_of failure spec)
it failed"
TR_STOP_R="$(marker_of refusal spec)
refused"
TR_LIM="$(marker_of limited spec)
stopped"
TR_WARN='orch: ignored 1 comment(s) from untrusted authors on #7'

# A stranger's marked comment is read as none; an owner's equivalent is read.
fake_comments_clear 7
tr_seed NONE "$TR_Q"
assert_eq "a stranger's question is not a question, and one line says so" \
  "$(tr_run 'timeline_question spec; echo "q=[$TIMELINE_Q_INDEX]"')" "$TR_WARN|q=[]|rc=0"
fake_comments_clear 7
tr_seed OWNER "$TR_Q"
assert_eq "an owner's question is read, and no line is printed" \
  "$(tr_run 'timeline_question spec; echo "q=[$TIMELINE_Q_INDEX]"')" "q=[0]|rc=0"

fake_comments_clear 7
tr_seed OWNER "$TR_HO"
tr_seed NONE "$TR_HO_RETIRED"
assert_eq "a stranger's retired handoff does not kill the live handoff" \
  "$(tr_run 'timeline_handoff 01-plan; echo "h=[$TIMELINE_HANDOFF_INDEX]"')" "$TR_WARN|h=[0]|rc=0"
fake_comments_clear 7
tr_seed NONE "$TR_HO"
assert_eq "a stranger's handoff is not a handoff" \
  "$(tr_run 'timeline_handoff 01-plan; echo "h=[$TIMELINE_HANDOFF_INDEX]"')" "$TR_WARN|h=[]|rc=0"

fake_comments_clear 7
tr_seed NONE "$TR_STOP_F"
tr_seed NONE "$TR_STOP_R"
assert_eq "a stranger's refusal and failure stops are not stops, two ignored" \
  "$(tr_run 'timeline_stop; echo "s=[$TIMELINE_STOP_INDEX]"')" "${TR_WARN/1 /2 }|s=[]|rc=0"
fake_comments_clear 7
tr_seed OWNER "$TR_STOP_F"
assert_eq "an owner's failure stop is a stop" \
  "$(tr_run 'timeline_stop; echo "s=[$TIMELINE_STOP_KIND]"')" "s=[failure]|rc=0"

fake_comments_clear 7
tr_seed OWNER "$TR_LIM"
tr_seed NONE "$TR_LIM"
assert_eq "a stranger's limit stop is not counted" \
  "$(tr_run 'timeline_limit_count spec')" "$TR_WARN|1|rc=0"

# A stranger's reply neither answers a question nor follows it.
fake_comments_clear 7
tr_seed OWNER "$TR_Q"
tr_seed NONE "forged answer"
assert_eq "a stranger's reply does not follow the question" \
  "$(tr_run 'timeline_replied spec')" "$TR_WARN|rc=1"
assert_eq "a stranger's reply is not an answer" \
  "$(tr_run 'timeline_answers spec | wc -c')" "$TR_WARN|0|rc=0"
tr_seed OWNER "real answer"
assert_eq "an owner's reply after it is the only answer" \
  "$(tr_run 'timeline_answers spec; echo')" "$TR_WARN||---|real answer|rc=0"

# Each association.
for assoc in OWNER MEMBER COLLABORATOR; do
  fake_comments_clear 7
  tr_seed "$assoc" "$TR_Q"
  assert_eq "a $assoc comment is read" "$(tr_run 'timeline_question spec')" "rc=0"
  assert_eq "a $assoc comment is not reported" \
    "$(tr_run 'timeline_question spec; echo "q=$TIMELINE_Q_INDEX"')" "q=0|rc=0"
done
for assoc in CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER NONE; do
  fake_comments_clear 7
  tr_seed "$assoc" "$TR_Q"
  assert_eq "a $assoc comment is dropped" \
    "$(tr_run 'timeline_question spec; echo "q=[$TIMELINE_Q_INDEX]"')" "$TR_WARN|q=[]|rc=0"
done
