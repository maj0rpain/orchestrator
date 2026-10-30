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
restore_suite_env
