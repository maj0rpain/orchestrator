# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- Standing module ---------------------------------------------------------
# The Standing module's read, Pickup rule, label verdict and claim reads, called
# through a sourced orch.sh against the gh fake.

echo
echo "standing"
new_repo >/dev/null
fake_github

# st <script>: runs the script in a shell that sourced orch.sh, then prints its
# exit status as "rc=<n>" on a last line.
st() { sourced_orch_script 'rc=0; ( '"$1"' ) || rc=$?; echo "rc=$rc"' 2>&1; }

fake_issue 5 open orch:review needs-human bug
out="$(st 'standing_read 5 && echo "$STANDING_STATE|$STANDING_PHASE|$STANDING_PHASE_LABELS|$STANDING_RUNNING|$STANDING_HUMAN|$STANDING_LIMITED"')"
assert_eq "standing_read gives state, live phase, phase-label text and the three flags" "$out" "OPEN|review|orch:review|0|1|0
rc=0"
fake_issue 6 closed orch:done orch:spec orch:running orch:limited
out="$(st 'standing_read 6 && echo "$STANDING_STATE|$STANDING_PHASE|$STANDING_PHASE_LABELS|$STANDING_RUNNING|$STANDING_HUMAN|$STANDING_LIMITED"')"
assert_eq "the live phase skips done, the label text keeps table order, running and limited read 1" "$out" "CLOSED|spec|orch:spec orch:done|1|0|1
rc=0"
fake_fail adapter_issue_state_labels "HTTP 502"
out="$(st 'standing_read 5; echo "reason=$STANDING_REASON"')"
assert_eq "a failed standing_read returns non-zero with the reason on stderr" "$out" "HTTP 502
reason=HTTP 502
rc=0"
out="$(st 'standing_read 5')"
assert_contains "and its status is non-zero" "$out" "rc=1"
fake_unfail

# Pickup rule, the label half
pickable() { st "standing_read $1 && standing_pickable" | tail -n 1; }
fake_issue 10 open orch:spec
assert_eq "an open issue with a live phase and no running or needs-human label is pickable" "$(pickable 10)" "rc=0"
fake_issue 11 open orch:spec orch:running
assert_eq "a running issue is not pickable" "$(pickable 11)" "rc=1"
fake_issue 12 open orch:spec needs-human
assert_eq "an issue waiting on the human is not pickable" "$(pickable 12)" "rc=1"
fake_issue 13 closed orch:spec
assert_eq "a closed issue is not pickable" "$(pickable 13)" "rc=1"
fake_issue 14 open orch:done
assert_eq "an issue whose only phase label is done is not pickable" "$(pickable 14)" "rc=1"
fake_issue 15 open orch:spec orch:limited
assert_eq "a limited issue is pickable: the limit pause is the tick's own check" "$(pickable 15)" "rc=0"

# label verdict
verdict() { sourced_orch_script 'standing_label_verdict "$1" "$2" v t; echo "$v|$t"' "$(printf "%b" "$1")" "$2"; }
assert_eq "no phase label gives none and no text" "$(verdict 'bug' review)" "none|"
assert_eq "the recorded phase's label alone agrees" "$(verdict 'bug\norch:review' review)" "agrees|orch:review"
assert_eq "another phase's label disagrees" "$(verdict 'orch:spec' review)" "disagrees|orch:spec"
assert_eq "two phase labels disagree, in table order" "$(verdict 'orch:review\norch:spec' review)" "disagrees|orch:spec orch:review"

# phase labels text (#1563)
out="$(sourced_orch standing_phase_labels_text "$(printf 'bug\nready-for-agent')" 2>&1)"
assert_eq "no phase label prints nothing" "$out" ""
out="$(sourced_orch standing_phase_labels_text "$(printf 'bug\norch:review')" 2>&1)"
assert_eq "one phase label prints that label" "$out" "orch:review"
out="$(sourced_orch standing_phase_labels_text "$(printf 'orch:review\nbug\norch:spec')" 2>&1)"
assert_eq "two phase labels print in table order, space-separated" "$out" "orch:spec orch:review"

# claims
fake_claim_seed 21 other-host 7 2026-01-01T00:00:00Z implement
fake_claim_seed 20 "$(hostname)" 8 2026-02-02T00:00:00Z spec
out="$(st 'standing_claims_read; echo "${STANDING_CLAIM_ISSUES[*]}|${STANDING_CLAIM_HOST[21]}|${STANDING_CLAIM_PID[21]}|${STANDING_CLAIM_PHASE[21]}|${STANDING_CLAIM_STARTED[21]}"')"
assert_eq "the claims read keys host, pid, phase and start by issue" "$out" "20 21|other-host|7|implement|2026-01-01T00:00:00Z
rc=0"
out="$(st 'standing_claims_read; standing_claim_fields 20; standing_claim_fields 99; echo "none=$?"')"
assert_eq "a claim is looked up by its issue, and an unclaimed issue has none" "$out" "$(printf '%s\t%s\t%s\t%s' "$(hostname)" 8 spec 2026-02-02T00:00:00Z)
none=1
rc=0"
out="$(st 'standing_claims_read; for i in "${STANDING_CLAIM_ISSUES[@]}"; do if [ "${STANDING_CLAIM_HOST[$i]}" = "$(standing_host_id)" ]; then echo "mine $i"; fi; done')"
assert_eq "iterating the claims filtered by host finds this host's alone" "$out" "mine 20
rc=0"
fake_fail adapter_claim_list "boom"
out="$(st 'standing_claims_read')"
assert_eq "a failed claim list dies with today's message" "$out" "orch: could not list the claims on origin: boom
rc=1"
out="$(st 'standing_claims_read --quiet')"
assert_eq "the quiet claim read fails with no message" "$out" "rc=1"
fake_unfail

# claim: exits 0, 2 and 1, and supplies the host id
out="$(ORCH_HOST_ID=autopilot-abc123 st 'standing_claim 30 spec 1; echo "host=${STANDING_CLAIM_HOST[30]-}"; standing_claims_read; echo "host=${STANDING_CLAIM_HOST[30]}"')"
assert_eq "claim takes the claim, recording ORCH_HOST_ID" "$out" "host=
host=autopilot-abc123
rc=0"
out="$(ORCH_HOST_ID="" st 'standing_claim 31 spec 1; standing_claims_read; echo "${STANDING_CLAIM_HOST[31]}"')"
assert_eq "and the hostname when it is empty" "$out" "$(hostname)
rc=0"
out="$(st 'standing_claim 30 review 2')"
assert_eq "claim of a held issue loses the race with exit 2" "$out" "rc=2"
fake_fail adapter_claim_create "HTTP 500"
out="$(st 'standing_claim 32 spec 1')"
assert_eq "any other failure exits 1 with the reason on stderr" "$out" "HTTP 500
rc=1"
fake_unfail

# --- Standing transitions ---------------------------------------------------
# Each transition driven against the fake, read back through standing_read and
# the fake's read-back helpers. tr_labels <n>: the issue's labels, one line.
tr_labels() { st "standing_read $1 && echo \"\$STANDING_PHASE|\$STANDING_RUNNING|\$STANDING_HUMAN|\$STANDING_LIMITED\"" | head -n 1; }
tr_seed() { fake_issue "$1" open "${@:2}"; fake_claim_seed "$1"; }
echo
echo "standing transitions"
fake_flow standing-transitions
st() { sourced_orch_script 'rc=0; ( '"$1"' ) || rc=$?; echo "rc=$rc"' 2>&1; }

# finish
tr_seed 50 orch:spec orch:running
out="$(st 'standing_finish 50 implement "wrote the spec"')"
assert_eq "finish moves the phase label, drops running and releases the claim" "$(tr_labels 50)|$(fake_claim_held 50)" "implement|0|0|0|free"
assert_eq "finish records the phase in state.json" "$("$ORCH" state get phase)" implement
tr_seed 51 orch:spec orch:running
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
out="$(st 'standing_finish 51 review "wrote the spec"')"
assert_contains "finish failing on the running removal names the reason's writes" "$out" "could not remove orch:running on issue #51: HTTP 500 - writes that landed: wrote the spec, moved the phase label to orch:review, recorded phase review; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 51)" held
fake_unfail
tr_seed 52 orch:spec orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(st 'standing_finish 52 implement ""')"
assert_contains "finish failing on the claim delete names every write before it" "$out" "could not delete the claim ref on issue #52: HTTP 500 - writes that landed: moved the phase label to orch:implement, recorded phase implement, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 52)" held
fake_unfail
tr_seed 53 orch:spec orch:running
fake_fail adapter_issue_state_labels "HTTP 502"
out="$(st 'standing_finish 53 implement "wrote the spec"')"
assert_contains "finish failing on the label read names the seed alone" "$out" "could not read the labels on issue #53: HTTP 502 - writes that landed: wrote the spec; the claim stays held"
fake_unfail

# a failing transition names only its own landed writes
fake_issue 54 open orch:spec orch:running; fake_claim_seed 54
fake_fail adapter_claim_delete "HTTP 500"
out="$(st 'standing_pause 54 "wrote the round marker"; true')"
assert_contains "pause failing on its release names its reason and the removal" "$out" "writes that landed: wrote the round marker, removed orch:running; the claim stays held"
fake_unfail
out="$(st 'standing_pause 54 "wrote the round marker"')"
assert_eq "pause releases the claim and leaves the phase label" "$(tr_labels 54)|$(fake_claim_held 54)" "spec|0|0|0|free"
tr_seed 55 orch:spec orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(st 'standing_stop 55 failure spec boom')"
assert_contains "a stop after the pause names only its own writes" "$out" "writes that landed: added needs-human, posted the failure comment, removed orch:running; the claim stays held"
fake_unfail

# stop
tr_seed 56 orch:spec orch:running orch:limited
st 'standing_stop 56 refusal spec "no plan"' >/dev/null
assert_eq "stop adds needs-human, drops limited and running, and releases" "$(tr_labels 56)|$(fake_claim_held 56)" "spec|0|1|0|free"
assert_eq "and posts the marked stop comment" "$(fake_comments_of 56 | head -1)" "$(marker_of refusal spec)"
tr_seed 57 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(st 'standing_stop 57 failure spec boom')"
assert_contains "stop failing on its first write names none landed" "$out" "could not add needs-human on issue #57: HTTP 500 - writes that landed: none; the claim stays held"
fake_unfail
tr_seed 58 orch:spec orch:running
fake_fail adapter_issue_comment "HTTP 500"
out="$(st 'standing_stop 58 failure spec boom')"
assert_contains "stop failing on its comment names the label that landed" "$out" "could not post the failure comment on issue #58: HTTP 500 - writes that landed: added needs-human; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 58)" held
fake_unfail
tr_seed 59 orch:spec orch:running
out="$(st 'standing_stop 59 failure "" boom')"
assert_contains "stop with an empty phase dies before any write" "$(tr_labels 59)|$(fake_comments_of 59)|$(fake_claim_held 59)" "spec|1|0|0|"

# limit-stop
tr_seed 60 orch:spec orch:running
st 'standing_limit_stop 60 spec "" 2026-01-01T01:00:00Z 1 log' >/dev/null
assert_eq "limit-stop adds limited, drops running and releases the claim" "$(tr_labels 60)|$(fake_claim_held 60)" "spec|0|0|1|free"
assert_eq "and posts the limited comment" "$(fake_comments_of 60 | head -1)" "$(marker_of limited spec)"
tr_seed 61 orch:spec orch:running
fake_fail adapter_issue_comment "HTTP 500"
out="$(st 'standing_limit_stop 61 spec "" 2026-01-01T01:00:00Z 1 log')"
assert_contains "limit-stop failing on its comment names the label that landed" "$out" "could not post the limit stop comment on issue #61: HTTP 500 - writes that landed: added orch:limited; the claim stays held"
fake_unfail

# ask
q="$(mktemp)"; printf '%s\n@o\n\nQ?\n' "$(marker_of question spec)" >"$q"
tr_seed 63 orch:spec orch:running
out="$(st 'standing_ask 63 spec "$(cat '"$q"')"')"
assert_eq "ask posts the question, adds needs-human and releases the claim" "$(tr_labels 63)|$(fake_claim_held 63)|$(fake_comments_of 63 | head -1)" "spec|0|1|0|free|$(marker_of question spec)"
tr_seed 64 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(st 'standing_ask 64 spec Q')"
assert_contains "ask failing on the label names the comment that landed" "$out" "could not add needs-human on issue #64: HTTP 500 - writes that landed: posted the spec question comment; the claim stays held"
fake_unfail
fake_fail adapter_claim_delete "HTTP 500"
tr_seed 65 orch:spec orch:running
out="$(st 'standing_ask 65 spec Q')"
assert_contains "ask failing on the release names all three writes" "$out" "writes that landed: posted the spec question comment, added needs-human, removed orch:running; the claim stays held"
fake_unfail

# start
sp="$(mktemp -d)/01-plan.md"; plan_file "$sp" $'Rounds: 4\nBudget: 5'
fake_issue 70 open
out="$(st 'standing_start 70 '"$sp")"
assert_eq "start refuses an issue without ready-for-agent, writing nothing" "$(fake_comments_of 70)$(fake_labels_of 70)" ""
fake_issue 71 open ready-for-agent orch:review
out="$(st 'standing_start 71 '"$sp")"
assert_eq "start refuses an issue with a phase label, writing nothing" "$(fake_comments_of 71)|$(fake_labels_of 71)" "|orch:review ready-for-agent "
fake_issue 72 open ready-for-agent
out="$(st 'standing_start 72 /nonexistent')"
assert_eq "start refuses a missing plan file, writing nothing" "$(fake_comments_of 72)|$(fake_labels_of 72)" "|ready-for-agent "
fake_issue 73 open ready-for-agent
st 'standing_start 73 '"$sp" >/dev/null
assert_eq "start posts the plan comment and adds the first phase label" "$(tr_labels 73)" "spec|0|0|0"
fake_issue 74 open ready-for-agent
fake_fail adapter_issue_relabel "HTTP 500"
out="$(st 'standing_start 74 '"$sp")"
assert_contains "start failing after its plan comment dies with that message" "$out" "orch: posted the 01-plan comment on issue #74 but adding orch:spec failed: HTTP 500 - the issue is unlabelled, so no watcher picks it up; re-run autopilot start"
assert_eq "and adds no phase label" "$(fake_labels_of 74)" "ready-for-agent "
fake_unfail

# resume
fake_issue 80 open needs-human orch:spec
st 'standing_resume 80' >/dev/null
assert_eq "resume removes needs-human" "$(tr_labels 80)" "spec|0|0|0"
fake_issue 81 open needs-human orch:spec
fake_fail adapter_issue_relabel "HTTP 500"
out="$(st 'standing_resume 81 replied')"
assert_contains "resume failing with replied dies with reply's message" "$out" "orch: the reply comment landed on issue #81, but needs-human could not be removed: HTTP 500"
out="$(st 'standing_resume 81')"
assert_contains "resume failing without it dies with resume's message" "$out" "could not remove needs-human from issue #81"
fake_unfail

# begin
tr_seed 60 orch:spec orch:limited
out="$(st 'standing_begin 60 spec limited')"
assert_eq "begin on a limited issue drops orch:limited and adds orch:running" "$(tr_labels 60)|$(printf %s "$out")" "spec|1|0|0|rc=0"
tr_seed 61 orch:spec
out="$(st 'standing_begin 61 spec')"
assert_eq "begin without limited just adds orch:running" "$(tr_labels 61)|$(printf %s "$out")" "spec|1|0|0|rc=0"
tr_seed 62 orch:spec orch:limited
fake_fail_after adapter_issue_relabel 0 "HTTP 500"
out="$(st 'standing_begin 62 spec limited')"
fake_unfail
assert_contains "begin failing on the limited removal returns 1 with that step's wording" "$out" "step removing orch:limited failed: HTTP 500
rc=1"
tr_seed 63 orch:spec orch:limited
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
out="$(st 'standing_begin 63 spec limited')"
fake_unfail
assert_contains "begin failing on the running addition returns 1 with that step's wording" "$out" "step adding orch:running failed: HTTP 500
rc=1"
assert_eq "and the removal had landed" "$(tr_labels 63)" "spec|0|0|0"
restore_suite_env
