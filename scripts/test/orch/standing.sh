# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# sourced_rc <script>: runs the script in a shell that sourced orch.sh, then
# prints its exit status as "rc=<n>" on a last line.
sourced_rc() { sourced_orch_script 'rc=0; ( '"$1"' ) || rc=$?; echo "rc=$rc"' 2>&1; }

# fake_fail_once_after <operation> <n> [stderr]: the next n calls of the
# operation succeed, the one after fails once, then it succeeds again - a run
# of writes that fails at one step and goes on.
fake_fail_once_after() {
  fake_fail_after "$1" "$2" "${3-}"
  fake_fail_times "$1" 1 "${3-}"
}

# --- Standing module ---------------------------------------------------------
# The Standing module's read, Pickup rule, label verdict and claim reads, called
# through a sourced orch.sh against the gh fake.

echo
echo "standing"
new_repo >/dev/null
fake_github

fake_issue 5 open orch:review needs-human bug
out="$(sourced_rc 'standing_read 5 && echo "$STANDING_STATE|$STANDING_PHASE|$STANDING_PHASE_LABELS|$STANDING_RUNNING|$STANDING_HUMAN|$STANDING_LIMITED"')"
assert_eq "standing_read gives state, live phase, phase-label text and the three flags" "$out" "OPEN|review|orch:review|0|1|0
rc=0"
fake_issue 6 closed orch:done orch:spec orch:running orch:limited
out="$(sourced_rc 'standing_read 6 && echo "$STANDING_STATE|$STANDING_PHASE|$STANDING_PHASE_LABELS|$STANDING_RUNNING|$STANDING_HUMAN|$STANDING_LIMITED"')"
assert_eq "the live phase skips done, the label text keeps table order, running and limited read 1" "$out" "CLOSED|spec|orch:spec orch:done|1|0|1
rc=0"
fake_issue 7 open Orch:Spec Needs-Human Orch:Running orch:Limited
out="$(sourced_rc 'standing_read 7 && echo "$STANDING_PHASE|$STANDING_RUNNING|$STANDING_HUMAN|$STANDING_LIMITED"')"
assert_eq "standing_read finds the phase and the three flags under any label casing" "$out" "spec|1|1|1
rc=0"
fake_fail adapter_issue_state_labels "HTTP 502"
out="$(sourced_rc 'standing_read 5; echo "reason=$STANDING_REASON"')"
assert_eq "a failed standing_read keeps the reason in STANDING_REASON and prints nothing" "$out" "reason=HTTP 502
rc=0"
out="$(sourced_rc 'standing_read 5')"
assert_contains "and its status is non-zero" "$out" "rc=1"
out="$(sourced_rc 'standing_human_guard 5')"
assert_eq "a guard read failing dies in one line naming gh and the reason" "$out" "orch: gh could not read issue #5: HTTP 502
rc=1"
sp0="$(mktemp -d)/01-plan.md"; plan_file "$sp0" $'Rounds: 4\nBudget: 5'
out="$(sourced_rc "standing_start 5 $sp0")"
assert_eq "start failing on the read dies in one line naming gh and the reason" "$out" "orch: gh could not read issue #5: HTTP 502
rc=1"
fake_unfail

# The phase-redo rule
assert_eq "a flow labelled implement whose checkout moved to review is redone as review" "$(sourced_rc 'standing_redo_phase implement review')" "review
rc=0"
assert_eq "a flow labelled spec whose checkout moved to implement is redone as spec" "$(sourced_rc 'standing_redo_phase spec implement')" "spec
rc=0"
for pair in "spec review" "review spec" "review done" "done review" "spec done" "implement implement" "review implement"; do
  assert_eq "no redo for labelled/recorded $pair: nothing printed, status 1" "$(sourced_rc "standing_redo_phase $pair")" "rc=1"
done

assert_eq "the redo rule reads as a sentence" "$(sourced_rc 'standing_redo_rule')" "a step back from review to implement or from implement to spec
rc=0"
out="$(sourced_rc 'STANDING_REDO_PAIRS="done:review:review"; standing_redo_phase done review; standing_redo_phase implement review; standing_redo_rule')"
assert_eq "a different table is followed by the lookup and the describer" "$out" "review
a step back from review to done
rc=0"

# Pickup rule, the label half
pickable() { sourced_rc "standing_read $1 && standing_pickable" | tail -n 1; }
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
out="$(sourced_rc 'standing_claims_read; echo "${STANDING_CLAIM_ISSUES[*]}|${STANDING_CLAIM_HOST[21]}|${STANDING_CLAIM_PID[21]}|${STANDING_CLAIM_PHASE[21]}|${STANDING_CLAIM_STARTED[21]}"')"
assert_eq "the claims read keys host, pid, phase and start by issue" "$out" "20 21|other-host|7|implement|2026-01-01T00:00:00Z
rc=0"
out="$(sourced_rc 'standing_claims_read; standing_claim_fields 20; standing_claim_fields 99; echo "none=$?"')"
assert_eq "a claim is looked up by its issue, and an unclaimed issue has none" "$out" "$(printf '%s\t%s\t%s\t%s' "$(hostname)" 8 spec 2026-02-02T00:00:00Z)
none=1
rc=0"
fake_fail adapter_claim_list "boom"
out="$(sourced_rc 'standing_claims_read')"
assert_eq "a failed claim list dies with today's message" "$out" "orch: could not list the claims on origin: boom
rc=1"
out="$(sourced_rc 'standing_claims_read --quiet')"
assert_eq "the quiet claim read fails with no message" "$out" "rc=1"
fake_unfail

# claim: exits 0, 2 and 1, and supplies the host id
out="$(ORCH_HOST_ID=autopilot-abc123 sourced_rc 'standing_claim 30 spec 1; echo "host=${STANDING_CLAIM_HOST[30]-}"; standing_claims_read; echo "host=${STANDING_CLAIM_HOST[30]}"')"
assert_eq "claim takes the claim, recording ORCH_HOST_ID" "$out" "host=
host=autopilot-abc123
rc=0"
out="$(ORCH_HOST_ID="" sourced_rc 'standing_claim 31 spec 1; standing_claims_read; echo "${STANDING_CLAIM_HOST[31]}"')"
assert_eq "and the hostname when it is empty" "$out" "$(hostname)
rc=0"
out="$(sourced_rc 'standing_claim 30 review 2')"
assert_eq "claim of a held issue loses the race with exit 2" "$out" "rc=2"
fake_fail adapter_claim_create "HTTP 500"
out="$(sourced_rc 'standing_claim 32 spec 1')"
assert_eq "any other failure exits 1 with the reason on stderr" "$out" "HTTP 500
rc=1"
fake_unfail

# --- Standing transitions ---------------------------------------------------
# Each transition driven against the fake, read back through standing_read and
# the fake's read-back helpers. tr_standing <n>: the issue's live phase,
# running, needs-human and limited flags as "phase|running|human|limited".
tr_standing() { sourced_rc "standing_read $1 && echo \"\$STANDING_PHASE|\$STANDING_RUNNING|\$STANDING_HUMAN|\$STANDING_LIMITED\"" | awk -v n=1 'NR<=n'; }
tr_seed() { fake_issue "$1" open "${@:2}"; fake_claim_seed "$1"; }
echo
echo "standing transitions"
fake_flow standing-transitions

# sync request
tr_seed 49 orch:done
out="$(sourced_rc 'standing_sync_request 49')"
assert_eq "sync request adds orch:sync and keeps orch:done" "$(fake_labels_of 49)" "orch:done orch:sync "
assert_first_line "and reads back as a sync request" "$(sourced_rc 'standing_read 49 && echo "$STANDING_SYNC|$STANDING_PHASE"')" "1|"

# sync finish, the dropped-intent stop and the failure stop
tr_seed 140 orch:done orch:sync orch:running
sourced_rc 'standing_sync_finish 140' >/dev/null
assert_eq "sync finish removes orch:sync, keeps orch:done, drops running and releases" "$(fake_labels_of 140)|$(fake_claim_held 140)" "orch:done |free"
tr_seed 141 orch:done orch:sync orch:running
sourced_rc 'standing_sync_dropped 141 "- keep the cache flag (see https://x/y#c1)" false' >/dev/null
assert_eq "the dropped-intent stop removes orch:sync, adds needs-human and releases" "$(fake_labels_of 141)|$(fake_claim_held 141)" "needs-human orch:done |free"
assert_first_line "its comment is a failure stop marked sync" "$(fake_comments_of 141)" "$(marker_of failure sync)"
assert_contains "listing the dropped intent" "$(fake_comments_of 141)" "keep the cache flag (see https://x/y#c1)"
assert_contains "saying no reply is needed" "$(fake_comments_of 141)" "No reply is needed"
assert_contains "that removing needs-human accepts the dropped intents" "$(fake_comments_of 141)" "remove needs-human"
assert_contains "and that a rejected drop is restored on the branch before the label comes off" "$(fake_comments_of 141)" "restore it on the branch first"
assert_not_contains "without the bare re-runs-nothing sentence" "$(fake_comments_of 141)" "re-runs nothing"
assert_contains "with auto-sync off, it names the manual sync-now command" "$(fake_comments_of 141)" "To sync again, run \`orch.sh autopilot sync 141\`."
assert_not_contains "and does not say the watcher files the next sync" "$(fake_comments_of 141)" "by itself"
tr_seed 146 orch:done orch:sync orch:running
sourced_rc 'standing_sync_dropped 146 x true' >/dev/null
assert_contains "with auto-sync on, it says the watcher files the next sync itself" "$(fake_comments_of 146)" "files a new sync request by itself"
assert_contains "and still names the sync-now command" "$(fake_comments_of 146)" "or run \`orch.sh autopilot sync 146\` to sync now."
tr_seed 142 orch:done orch:sync orch:running
sourced_rc 'standing_stop 142 failure sync "the resolver gave up"' >/dev/null
assert_eq "the failure stop keeps orch:sync and adds needs-human" "$(fake_labels_of 142)|$(fake_claim_held 142)" "needs-human orch:done orch:sync |free"
assert_contains "naming the sync and the reason" "$(fake_comments_of 142)" "Autopilot failed in the sync: the resolver gave up"
tr_seed 143 orch:done orch:sync orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(sourced_rc 'standing_sync_finish 143')"
assert_contains "sync finish failing on the release names the writes that landed" "$out" "writes that landed: removed orch:sync, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 143)" held
fake_unfail
tr_seed 144 orch:done orch:sync orch:running
fake_fail adapter_issue_comment "HTTP 500"
out="$(sourced_rc 'standing_sync_dropped 144 x false')"
assert_contains "the dropped-intent stop failing on its comment names the label write that landed" "$out" "writes that landed: added needs-human, removed orch:sync; the claim stays held"
fake_unfail
tr_seed 145 orch:done orch:sync orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_sync_dropped 145 x false')"
assert_contains "the dropped-intent stop failing on its relabel says it was also removing orch:sync" "$out" "could not add needs-human, remove orch:sync on issue #145: HTTP 500"
fake_unfail

# finish
tr_seed 50 orch:spec orch:running
out="$(sourced_rc 'standing_finish 50 implement "wrote the spec"')"
assert_eq "finish moves the phase label, drops running and releases the claim" "$(tr_standing 50)|$(fake_claim_held 50)" "implement|0|0|0|free"
assert_eq "finish records the phase in state.json" "$("$ORCH" state get phase)" implement
tr_seed 51 orch:spec orch:running
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
out="$(sourced_rc 'standing_finish 51 review "wrote the spec"')"
assert_contains "finish failing on the running removal names the reason's writes" "$out" "could not remove orch:running on issue #51: HTTP 500 - writes that landed: wrote the spec, moved the phase label to orch:review, recorded phase review; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 51)" held
fake_unfail
tr_seed 52 orch:spec orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(sourced_rc 'standing_finish 52 implement ""')"
assert_contains "finish failing on the claim delete names every write before it" "$out" "could not delete the claim ref on issue #52: HTTP 500 - writes that landed: moved the phase label to orch:implement, recorded phase implement, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 52)" held
fake_unfail
tr_seed 53 orch:spec orch:running
fake_fail adapter_issue_state_labels "HTTP 502"
out="$(sourced_rc 'standing_finish 53 implement "wrote the spec"')"
assert_contains "finish failing on the label read names the seed alone" "$out" "could not read the labels on issue #53: HTTP 502 - writes that landed: wrote the spec; the claim stays held"
fake_unfail

# a failing transition names only its own landed writes
tr_seed 54 orch:spec orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(sourced_rc 'standing_pause 54 "wrote the round marker"; true')"
assert_contains "pause failing on its release names its reason and the removal" "$out" "writes that landed: wrote the round marker, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 54)" held
fake_unfail
out="$(sourced_rc 'standing_pause 54 "wrote the round marker"')"
assert_eq "pause releases the claim and leaves the phase label" "$(tr_standing 54)|$(fake_claim_held 54)" "spec|0|0|0|free"
tr_seed 55 orch:spec orch:running
tr_seed 54 orch:spec orch:running
fake_fail_after adapter_claim_delete 1 "HTTP 500"
out="$(sourced_rc 'standing_pause 54 "wrote the round marker"; standing_stop 55 failure spec boom')"
assert_contains "a stop failing in the same shell as an earlier succeeding pause names only its own writes" "$out" "writes that landed: added needs-human, removed orch:limited, posted the failure comment, removed orch:running; the claim stays held"
fake_unfail

# stop
tr_seed 56 orch:spec orch:running orch:limited
sourced_rc 'standing_stop 56 refusal spec "no plan"' >/dev/null
assert_eq "stop adds needs-human, drops limited and running, and releases" "$(tr_standing 56)|$(fake_claim_held 56)" "spec|0|1|0|free"
assert_first_line "and posts the marked stop comment" "$(fake_comments_of 56)" "$(marker_of refusal spec)"
assert_contains "and keeps its prose beneath the marker" "$(fake_comments_of 56 | sed -n 2p)" "Autopilot refused to run the spec phase: no plan"
tr_seed 66 orch:spec orch:running
sourced_rc 'standing_stop 66 failure review "boom"' >/dev/null
assert_first_line "a failure stop opens with its own marked comment" "$(fake_comments_of 66)" "$(marker_of failure review)"
assert_contains "and keeps its prose beneath the marker" "$(fake_comments_of 66 | sed -n 2p)" "Autopilot failed in the review phase: boom"
# cases 57 and 58 also cover the orch:limited removal whether or not the issue
# carries the label: a general stop always passes the removal and the writer
# never reads the labels
tr_seed 57 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_stop 57 failure spec boom')"
assert_contains "stop failing on its first write names none landed" "$out" "could not add needs-human, remove orch:limited on issue #57: HTTP 500 - writes that landed: none; the claim stays held"
fake_unfail
tr_seed 58 orch:spec orch:running
fake_fail adapter_issue_comment "HTTP 500"
out="$(sourced_rc 'standing_stop 58 failure spec boom')"
assert_contains "stop failing on its comment names the label that landed" "$out" "could not post the failure comment on issue #58: HTTP 500 - writes that landed: added needs-human, removed orch:limited; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 58)" held
fake_unfail
tr_seed 59 orch:spec orch:running
out="$(sourced_rc 'standing_stop 59 failure "" boom')"
assert_eq "an empty phase dies" "$(printf %s "$out" | tail -n 1)" "rc=1"
assert_eq "and writes nothing, the claim still held" "$(tr_standing 59)|$(fake_comments_of 59)|$(fake_claim_held 59)" "spec|1|0|0||held"

# the chain points a command section no longer asserts: each transition's own
# writes, and the claim held when one fails
state_fixture phase spec
tr_seed 90 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_finish 90 implement ""')"
assert_contains "finish failing on the label move names the reason and none landed" "$out" "could not move the phase label to orch:implement on issue #90: HTTP 500 - writes that landed: none; the claim stays held"
assert_eq "the phase stays unrecorded" "$("$ORCH" state get phase)" spec
assert_eq "and the claim stays held" "$(fake_claim_held 90)" held
fake_unfail
tr_seed 91 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_pause 91 "wrote the round marker"')"
assert_contains "pause failing on the running removal names the seed alone" "$out" "could not remove orch:running on issue #91: HTTP 500 - writes that landed: wrote the round marker; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 91)" held
fake_unfail
tr_seed 92 orch:spec orch:running
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
out="$(sourced_rc 'standing_stop 92 failure spec boom')"
assert_contains "stop failing on the running removal names the label add and the comment" "$out" "could not remove orch:running on issue #92: HTTP 500 - writes that landed: added needs-human, removed orch:limited, posted the failure comment; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 92)" held
fake_unfail
tr_seed 93 orch:spec orch:running
fake_fail adapter_claim_delete "HTTP 500"
out="$(sourced_rc 'standing_stop 93 refusal spec "no plan"')"
assert_contains "a refusal stop failing on the claim delete names every write before it" "$out" "could not delete the claim ref on issue #93: HTTP 500 - writes that landed: added needs-human, removed orch:limited, posted the refusal comment, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 93)" held
fake_unfail
tr_seed 94 orch:spec orch:running
state_fixture phase spec
out="$(PATH="$(state_write_fails_bin):$PATH" sourced_rc 'standing_finish 94 implement "wrote the spec"')"
assert_contains "finish failing on its phase write names the chain" "$out" "could not record phase implement in $PWD/.orchestrator/state.json - writes that landed: wrote the spec, moved the phase label to orch:implement; the claim stays held"
assert_eq "the label is one step ahead, running kept" "$(fake_labels_of 94)" "orch:implement orch:running "
assert_eq "the claim stays held" "$(fake_claim_held 94)" held
assert_eq "the phase stays unrecorded" "$("$ORCH" state get phase)" spec
sourced_rc 'standing_finish 94 implement "wrote the spec"' >/dev/null
assert_eq "the re-run leaves the label at the phase, running removed" "$(fake_labels_of 94)" "orch:implement "
assert_eq "and releases the claim" "$(fake_claim_held 94)" free
assert_eq "and records the phase" "$("$ORCH" state get phase)" implement

# limit-stop
tr_seed 60 orch:spec orch:running
sourced_rc 'standing_limit_stop 60 spec "" 2026-01-01T01:00:00Z 1 log' >/dev/null
assert_eq "limit-stop adds limited, drops running and releases the claim" "$(tr_standing 60)|$(fake_claim_held 60)" "spec|0|0|1|free"
assert_first_line "and posts the limited comment" "$(fake_comments_of 60)" "$(marker_of limited spec)"
tr_seed 61 orch:spec orch:running
fake_fail adapter_issue_comment "HTTP 500"
out="$(sourced_rc 'standing_limit_stop 61 spec "" 2026-01-01T01:00:00Z 1 log')"
assert_contains "limit-stop failing on its comment names the label that landed" "$out" "could not post the limit stop comment on issue #61: HTTP 500 - writes that landed: added orch:limited; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 61)" held
fake_unfail
tr_seed 67 orch:spec orch:running
fake_comment 67 o 2026-01-01T00:00:00Z "$(marker_of limited spec)"
fake_comment 67 o 2026-01-02T00:00:00Z "$(marker_of limited spec)"
sourced_rc 'standing_limit_stop 67 spec "" 2026-01-01T01:00:00Z 1 log' >/dev/null
assert_eq "the third limit stop in a row takes the failure path: needs-human, not limited, claim released" "$(tr_standing 67)|$(fake_claim_held 67)" "spec|0|1|0|free"
assert_contains "and posts a failure comment naming the third in a row" "$(fake_comments_of 67)" "the third in a row in the spec phase"
assert_contains "and says the session gave no reset time" "$(fake_comments_of 67)" "(the session gave no reset time)"
assert_contains "under the failure marker" "$(fake_comments_of 67)" "$(marker_of failure spec)"
tr_seed 69 orch:spec orch:running
fake_comment 69 o 2026-01-01T00:00:00Z "$(marker_of limited spec)"
sourced_rc 'standing_limit_stop 69 spec "" 2026-01-01T01:00:00Z 1 log' >/dev/null
assert_eq "the second limit stop in a row is still limited" "$(tr_standing 69)|$(fake_claim_held 69)" "spec|0|0|1|free"
assert_contains "and is retry 2 of 2" "$(fake_comments_of 69)" "retry 2 of 2"
tr_seed 70 orch:spec orch:running
fake_fail adapter_issue_comments_json "HTTP 500 comments"
assert_contains "unreadable comments fail the attempt: it dies, naming the read" "$(sourced_rc 'standing_limit_stop 70 spec "" 2026-01-01T01:00:00Z 1 log' 2>&1)" "could not read issue #70's comments to count the stops in a row"
fake_unfail
assert_eq "and leave the labels, comments and claim as they were" "$(fake_comments_of 70)|$(tr_standing 70)|$(fake_claim_held 70)" "|spec|1|0|0|held"
tr_seed 73 orch:spec orch:running
out="$(sourced_rc 'STANDING_STATE_FILE="$(mktemp)"
standing_limit_stop 73 spec "" 2026-01-01T01:00:00Z 1 log
echo "stop-lines=$(grep -c "^stop	" "$STANDING_STATE_FILE")"')"
assert_contains "a limit stop whose read succeeds notes its stop once, not before the read" "$out" "stop-lines=1"
# limit-stop with the GitHub cause: no label added, orch:running removed
tr_seed 95 orch:spec orch:running
sourced_rc 'standing_limit_stop 95 spec 2026-01-01T01:00:00Z 2026-01-01T01:00:00Z 1 log github' >/dev/null
assert_eq "a GitHub limit stop adds no label, drops running and releases the claim" "$(tr_standing 95)|$(fake_claim_held 95)" "spec|0|0|0|free"
assert_first_line "and posts the limited comment with its github cause" "$(fake_comments_of 95)" "$(marker_of limited spec github)"
assert_contains "naming the GitHub API rate limit and its reset" "$(fake_comments_of 95)" "GitHub API rate limit in the spec phase, which resets 2026-01-01T01:00:00Z"
tr_seed 96 orch:spec orch:running
fake_comment 96 o 2026-01-01T00:00:00Z "$(marker_of limited spec github)"
sourced_rc 'standing_limit_stop 96 spec 2026-01-01T01:00:00Z 2026-01-01T01:00:00Z 1 log github' >/dev/null
assert_contains "a GitHub stop after a GitHub stop is retry 2 of 2" "$(fake_comments_of 96)" "Retry 2 of 2"
tr_seed 97 orch:spec orch:running
fake_comment 97 o 2026-01-01T00:00:00Z "$(marker_of limited spec)"
fake_comment 97 o 2026-01-01T00:00:01Z "$(marker_of limited spec github)"
sourced_rc 'standing_limit_stop 97 spec 2026-01-01T01:00:00Z 2026-01-01T01:00:00Z 1 log github' >/dev/null
assert_eq "the third limit stop in a row, whatever its causes, is a needs-human failure stop" "$(tr_standing 97)|$(fake_claim_held 97)" "spec|0|1|0|free"
assert_contains "naming the GitHub cause" "$(fake_comments_of 97)" "stopped on the GitHub API rate limit (resets 2026-01-01T01:00:00Z) and exited with code 1, the third in a row"
# a resumed stop (#2695): the first attempt's comment call lands but reports a
# failure; the second runs with the same state file, after <between>
LOSE_ONCE='eval "orig_$(declare -f adapter_issue_comment)"
adapter_issue_comment() {
  local rc=0
  orig_adapter_issue_comment "$@" || rc=$?
  if [ ! -e "$ORCH_GH_FAKE_STORE/lost" ]; then : >"$ORCH_GH_FAKE_STORE/lost"; return 1; fi
  return $rc
}'
resumed_stop() { # <issue> <between the attempts>
  rm -f "$ORCH_GH_FAKE_STORE/lost"
  sourced_rc "$LOSE_ONCE"'
STANDING_STATE_FILE="$(mktemp)"
(standing_limit_stop '"$1"' spec "" 2026-01-01T01:00:00Z 1 log) || true
'"$2"'
standing_limit_stop '"$1"' spec "" 2026-01-01T01:00:00Z 1 log'
}
stop_comments() { grep -c -x -F "$(marker_of limited spec)" <<<"$(fake_comments_of "$1")" || true; }
tr_seed 71 orch:spec orch:running
resumed_stop 71 ':' >/dev/null
assert_eq "a stop whose comment landed but whose call failed posts no second comment, and releases the claim" "$(stop_comments 71)|$(fake_claim_held 71)" "1|free"
assert_contains "and keeps its count on the next attempt" "$(fake_comments_of 71)" "retry 1 of 2"
tr_seed 72 orch:spec orch:running
out="$(resumed_stop 72 'mkdir -p "$ORCH_GH_FAKE_STORE/fail"; printf "HTTP 500 read\n" >"$ORCH_GH_FAKE_STORE/fail/adapter_issue_comments_json"')"
assert_contains "a failed duplicate-comment check fails the attempt" "$out" "could not read issue #72's comments to check for this stop's comment"
assert_eq "and posts no second comment" "$(stop_comments 72)|$(fake_claim_held 72)" "1|held"
fake_unfail
rm -f "$ORCH_GH_FAKE_STORE/lost"
tr_seed 68 orch:spec orch:running
out="$(sourced_rc 'standing_limit_stop 68 "" "" "" 1 log')"
assert_contains "a limit stop of an empty phase dies" "$out" "rc=1"
assert_eq "and writes no comment and changes no label" "$(fake_comments_of 68)|$(tr_standing 68)|$(fake_claim_held 68)" "|spec|1|0|0|held"

# ask: the issue comes from flow state
ask_seed() { tr_seed "$@"; "$ORCH" state set issue "$1" >/dev/null; }
ask_seed 64 orch:spec orch:running
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_ask spec Q')"
assert_contains "ask failing on the label names the comment that landed" "$out" "could not add needs-human on issue #64: HTTP 500 - writes that landed: posted the spec question comment; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 64)" held
fake_unfail
fake_fail adapter_claim_delete "HTTP 500"
ask_seed 65 orch:spec orch:running
out="$(sourced_rc 'standing_ask spec Q')"
assert_contains "ask failing on the release names all three writes" "$out" "writes that landed: posted the spec question comment, added needs-human, removed orch:running; the claim stays held"
assert_eq "and the claim stays held" "$(fake_claim_held 65)" held
fake_unfail

# start
fake_issue 72 open ready-for-agent
out="$(sourced_rc 'standing_start 72 /nonexistent')"
assert_eq "start refuses a missing plan file, writing nothing" "$(fake_comments_of 72)|$(fake_labels_of 72)" "|ready-for-agent "

# resume
fake_issue 80 open needs-human orch:spec
sourced_rc 'standing_resume 80' >/dev/null
assert_eq "resume removes needs-human" "$(tr_standing 80)" "spec|0|0|0"
fake_issue 81 open needs-human orch:spec
fake_fail adapter_issue_relabel "HTTP 500"
out="$(sourced_rc 'standing_resume 81; echo "reason=$STANDING_REASON"')"
assert_eq "resume failing returns 1 with the reason in STANDING_REASON and prints nothing" "$out" "reason=HTTP 500
rc=0"
out="$(sourced_rc 'standing_resume 81')"
assert_contains "and its status is non-zero" "$out" "rc=1"
fake_unfail

# begin
tr_seed 60 orch:spec orch:limited
out="$(sourced_rc 'standing_begin 60 limited')"
assert_eq "begin on a limited issue drops orch:limited and adds orch:running" "$(tr_standing 60)|$(printf %s "$out")" "spec|1|0|0|rc=0"
tr_seed 61 orch:spec
out="$(sourced_rc 'standing_begin 61')"
assert_eq "begin without limited just adds orch:running" "$(tr_standing 61)|$(printf %s "$out")" "spec|1|0|0|rc=0"
tr_seed 62 orch:spec orch:limited
fake_fail_after adapter_issue_relabel 0 "HTTP 500"
out="$(sourced_rc 'standing_begin 62 limited || echo "reason=$STANDING_REASON"')"
fake_unfail
assert_eq "begin failing on the limited removal sets that step's wording in STANDING_REASON, printing nothing else" "$out" "reason=step removing orch:limited failed: HTTP 500
rc=0"
tr_seed 63 orch:spec orch:limited
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
out="$(sourced_rc 'standing_begin 63 limited || echo "reason=$STANDING_REASON"')"
fake_unfail
assert_eq "begin failing on the running addition sets that step's wording in STANDING_REASON, printing nothing else" "$out" "reason=step adding orch:running failed: HTTP 500
rc=0"
assert_eq "and the removal had landed" "$(tr_standing 63)" "spec|0|0|0"
restore_suite_env
