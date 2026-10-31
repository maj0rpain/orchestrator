# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- issue-timeline module --------------------------------------------------
# The Issue timeline module's queries, called through a sourced orch.sh over
# comment histories seeded in the gh fake. Each case reads the history, then
# asserts a query's answer; none looks at the module's arrays.
echo
echo "issue-timeline module"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec

# tl_seed <comment>...: issue #7's comments, oldest first.
tl_seed() {
  local c
  fake_comments_clear 7
  for c in "$@"; do fake_comment 7 o 2026-01-01T00:00:00Z "$c"; done
}
# tl <script>: reads issue #7's timeline, runs the script, and prints its
# output on one line (newlines as "|"), then "rc=<status>" of the script.
tl() {
  sourced_orch_script 'rc=0; ( timeline_read 7; '"$1"' ) || rc=$?; echo "rc=$rc"' 2>&1 | tr '\n\t' '|~' | sed 's/|$//'
}
# tl_exact <script>: the script's stdout after a read, in brackets, trailing
# newlines kept.
tl_exact() {
  sourced_orch_script 'timeline_read 7; out="$('"$1"'; printf x)"; printf "[%s]" "${out%x}"' 2>&1
}

U="https://github.com/o/r/issues/7#issuecomment"
Q_SPEC="$(marker_of question spec)
what?"
Q_IMPL="$(marker_of question implement)
which?"
STOP_F="$(marker_of failure spec)
it failed"
STOP_R="$(marker_of refusal implement)
refused"
LIM_SPEC="$(marker_of limited spec)
stopped"
LIM_IMPL="$(marker_of limited implement)
stopped"
HO_A="$(marker_of handoff 01-plan)"$'\nthe plan\n\n'
HO_A_RETIRED="$(marker_of handoff 01-plan retired)
Retired"

# question: pending / replied / none, per phase and across phases
tl_seed "intro"
assert_eq "no question comment: none" "$(tl 'timeline_question spec')" "rc=1"
assert_eq "no question comment: not replied" "$(tl 'timeline_replied spec')" "rc=1"
tl_seed "$Q_SPEC"
assert_eq "a question with nothing after it is pending" "$(tl 'timeline_question spec; timeline_replied spec')" "0~spec~$U-1|rc=1"
assert_eq "the question of another phase is none" "$(tl 'timeline_question implement')" "rc=1"
tl_seed "$Q_SPEC" "the answer"
assert_eq "a comment after the question replies to it" "$(tl 'timeline_replied spec')" "rc=0"
tl_seed "$Q_SPEC" "$Q_IMPL"
assert_eq "the phase's question is found past another phase's newer one" "$(tl 'timeline_question spec')" "0~spec~$U-1|rc=0"
assert_eq "a question of another phase after it counts as a comment after it" "$(tl 'timeline_replied spec')" "rc=0"
assert_eq "the newest question of any phase is the last" "$(tl 'timeline_question')" "1~implement~$U-2|rc=0"
tl_seed "$Q_SPEC" "reply" "$Q_SPEC"
assert_eq "the newest question of a phase wins" "$(tl 'timeline_question spec')" "2~spec~$U-3|rc=0"

# the comments after the question
tl_seed "$Q_SPEC" "one"
assert_eq "one reply is printed bare after a --- line" "$(tl_exact 'timeline_answers spec')" "[
---
one]"
tl_seed "$Q_SPEC" $'one\n' "two"
assert_eq "several replies are joined by --- lines, trailing newlines kept" "$(tl_exact 'timeline_answers spec')" "[
---
one

---
two]"
tl_seed "$Q_SPEC"
assert_eq "no reply: nothing" "$(tl_exact 'timeline_answers spec')" "[]"

# the latest stop
tl_seed "intro"
assert_eq "no stop: none" "$(tl 'timeline_stop')" "rc=1"
tl_seed "$STOP_F" "note"
assert_eq "a failure comment is a stop" "$(tl 'timeline_stop')" "0~failure~spec~$U-1|rc=0"
tl_seed "$STOP_F" "$STOP_R" "note"
assert_eq "the newest stop wins" "$(tl 'timeline_stop')" "1~refusal~implement~$U-2|rc=0"
tl_seed "$STOP_F" "$LIM_SPEC"
assert_eq "a limit stop is not a stop" "$(tl 'timeline_stop')" "0~failure~spec~$U-1|rc=0"
tl_seed "Autopilot refused to run the plan phase: nope" "x"
assert_eq "a legacy prose-opened refusal is a stop" "$(tl 'timeline_stop')" "0~refusal~plan~$U-1|rc=0"
tl_seed "Autopilot failed in the review phase: boom" "x"
assert_eq "a legacy prose-opened failure is a stop" "$(tl 'timeline_stop')" "0~failure~review~$U-1|rc=0"
tl_seed "$STOP_F" "$Q_SPEC"
assert_eq "a question newer than a stop leaves the stop answered as it was" "$(tl 'timeline_stop')" "0~failure~spec~$U-1|rc=0"
assert_eq "and is itself the newest question" "$(tl 'timeline_question')" "1~spec~$U-2|rc=0"
tl_seed "$Q_SPEC" "$STOP_F"
assert_eq "a stop newer than a question leaves the question answered as it was" "$(tl 'timeline_question')" "0~spec~$U-1|rc=0"
assert_eq "and is itself the latest stop" "$(tl 'timeline_stop')" "1~failure~spec~$U-2|rc=0"

# limit stops in a row
tl_seed "$LIM_SPEC" "$LIM_SPEC"
assert_eq "two limit stops in a row are counted" "$(tl 'timeline_limit_count spec')" "2|rc=0"
tl_seed
assert_eq "no comments count none" "$(tl 'timeline_limit_count spec')" "0|rc=0"
tl_seed "$LIM_SPEC" "just a note" "$LIM_SPEC" "another note"
assert_eq "unmarked comments between them are skipped" "$(tl 'timeline_limit_count spec')" "2|rc=0"
tl_seed "$LIM_SPEC" "$LIM_SPEC" "$Q_SPEC"
assert_eq "a question comment ends the streak" "$(tl 'timeline_limit_count spec')" "0|rc=0"
tl_seed "$LIM_SPEC" "$LIM_SPEC" "$HO_A"
assert_eq "a handoff comment ends it" "$(tl 'timeline_limit_count spec')" "0|rc=0"
tl_seed "$LIM_SPEC" "$LIM_IMPL" "$LIM_SPEC"
assert_eq "a limit stop of another phase ends it" "$(tl 'timeline_limit_count spec')" "1|rc=0"
tl_seed "$LIM_SPEC" "$LIM_SPEC" "$STOP_F"
assert_eq "a failure comment ends it" "$(tl 'timeline_limit_count spec')" "0|rc=0"
tl_seed "$LIM_SPEC" "$LIM_SPEC" "$(marker_of refusal spec)
x"
assert_eq "a refusal comment ends it" "$(tl 'timeline_limit_count spec')" "0|rc=0"
tl_seed "$STOP_F" "$LIM_SPEC"
assert_eq "a stop older than the streak does not count" "$(tl 'timeline_limit_count spec')" "1|rc=0"

# handoffs
tl_seed "intro" "$HO_A"
assert_eq "a live handoff is found" "$(tl 'timeline_handoff 01-plan')" "1|rc=0"
assert_eq "its body is exact, trailing newlines kept" "$(tl_exact 'timeline_body 1')" "[the plan

]"
assert_eq "a handoff of another name is missing" "$(tl 'timeline_handoff 02-build')" "rc=1"
tl_seed "$HO_A" "$HO_A_RETIRED"
assert_eq "a retired newest handoff is not live" "$(tl 'timeline_handoff 01-plan')" "rc=1"
tl_seed "$HO_A_RETIRED" "$HO_A"
assert_eq "a live handoff newer than a retired one is live" "$(tl 'timeline_handoff 01-plan')" "1|rc=0"
tl_seed "$(marker_of handoff 01-plan)"
assert_eq "a comment of only its marker line has an empty body" "$(tl_exact 'timeline_body 0')" "[]"

# CR-terminated marker lines
tl_seed "<!-- orch:question spec -->"$'\r\nwhat?' "<!-- orch:handoff 01-plan -->"$'\r\nbody'
assert_eq "a CR-terminated question marker is read" "$(tl 'timeline_question spec')" "0~spec~$U-1|rc=0"
assert_eq "a CR-terminated handoff marker is read" "$(tl 'timeline_handoff 01-plan')" "1|rc=0"

# failed reads
tl_seed "$HO_A"
fake_fail adapter_issue_comments_json "HTTP 500 comments"
assert_eq "an unreadable read returns non-zero with gh's reason" \
  "$(sourced_orch_script 'rc=0; timeline_read 7 || rc=$?; echo "rc=$rc reason=$TIMELINE_REASON"' 2>&1)" "rc=1 reason=HTTP 500 comments"
fake_unfail
bad_json='adapter_issue_comments_json() { echo "not json"; }; rc=0; timeline_read 7 || rc=$?; echo "rc=$rc reason=[$TIMELINE_REASON]"'
assert_eq "output that is not JSON returns non-zero with an empty reason" "$(sourced_orch_script "$bad_json" 2>&1)" "rc=1 reason=[]"

# reads in sequence
break_read='break_read() { mkdir -p "$ORCH_GH_FAKE_STORE/fail"; echo x >"$ORCH_GH_FAKE_STORE/fail/adapter_issue_comments_json"; }; '
two_reads="$break_read"'timeline_read 7; timeline_handoff 01-plan; rm -rf "$ORCH_GH_FAKE_STORE/issues/7/comments"; timeline_read 7; rc=0; timeline_handoff 01-plan || rc=$?; echo "rc=$rc"'
assert_eq "two reads in sequence: a handoff live in the first is missing in the second" \
  "$(sourced_orch_script "$two_reads" 2>&1 | tr '\n' '|')" "0|rc=1|"
tl_seed "$Q_SPEC" "$STOP_F" "$HO_A"
good_then_bad="$break_read"'timeline_read 7; break_read; timeline_read 7 || true
for q in "timeline_question" "timeline_stop" "timeline_handoff 01-plan" "timeline_replied"; do
  out=""; rc=0; out="$($q)" || rc=$?; printf "%s[%s]%s " "$q" "$out" "$rc"
done'
fake_unfail
assert_eq "a good read then a failed one: every query answers none" \
  "$(sourced_orch_script "$good_then_bad" 2>&1)" "timeline_question[]1 timeline_stop[]1 timeline_handoff 01-plan[]1 timeline_replied[]1 "
fake_unfail
tl_seed "$LIM_SPEC" "$LIM_SPEC"
assert_eq "and the limit count after it is zero" \
  "$(sourced_orch_script "$break_read"'timeline_read 7; break_read; timeline_read 7 || true; timeline_limit_count spec' 2>&1)" "0"
fake_unfail

restore_suite_env
