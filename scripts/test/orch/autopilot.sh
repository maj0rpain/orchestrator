# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# tick_calls: how many sessions the launcher has been asked for.
tick_calls() { local n; n="$(grep -c '^argv:' "$launcher_dir/calls" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
# local_fields <iso>: the limit file's UTC timestamp as "<epoch> <%H> <%a>" in
# local time.
local_fields() {
  local e
  e="$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s)"
  printf '%s %s\n' "$e" "$(date -d "@$e" '+%H %a' 2>/dev/null || date -r "$e" '+%H %a')"
}
# dead_pid: the pid of a process that has exited.
dead_pid() { sleep 0 & local p=$!; wait "$p"; printf '%s\n' "$p"; }


# --- autopilot ---------------------------------------------------------------
# The clone-scoped autopilot settings, the autopilot-session check and the
# host gate tick and watch share.
echo
echo "autopilot"
new_repo >/dev/null
fakebin="$(mktemp -d)"
printf '#!/bin/sh\nexit 0\n' >"$fakebin/claude"; chmod +x "$fakebin/claude"

out="$("$ORCH" autopilot show 2>&1)"; st=$?
assert_status "autopilot show succeeds with nothing set" "$st" 0
assert_contains "the permission mode has no default" "$out" "orchestrator.autopilot.permission-mode (none) (unset)"
assert_contains "the cap defaults to 3" "$out" "orchestrator.autopilot.cap 3 (default)"
assert_contains "the handle defaults to the repo's owner" "$out" "orchestrator.autopilot.handle o (default)"
assert_contains "the rounds default to 2" "$out" "orchestrator.autopilot.rounds 2 (default)"
assert_contains "the budget defaults to 3" "$out" "orchestrator.autopilot.budget 3 (default)"

out="$(GH_REPO=acme/widgets "$ORCH" autopilot show 2>&1)"
assert_contains "the handle follows GH_REPO's owner" "$out" "orchestrator.autopilot.handle acme (default)"

git config orchestrator.autopilot.permission-mode acceptEdits
git config orchestrator.autopilot.cap 05
git config orchestrator.autopilot.handle octo
git config orchestrator.autopilot.rounds 4
git config orchestrator.autopilot.budget 7
out="$("$ORCH" autopilot show 2>&1)"
assert_contains "a set mode shows with its source" "$out" "orchestrator.autopilot.permission-mode acceptEdits (local)"
assert_contains "a set cap is a plain integer" "$out" "orchestrator.autopilot.cap 5 (local)"
assert_contains "a set handle wins over the owner" "$out" "orchestrator.autopilot.handle octo (local)"
assert_contains "a set rounds shows" "$out" "orchestrator.autopilot.rounds 4 (local)"
assert_contains "a set budget shows" "$out" "orchestrator.autopilot.budget 7 (local)"

for m in default acceptEdits plan dontAsk bypassPermissions; do
  git config orchestrator.autopilot.permission-mode "$m"
  "$ORCH" autopilot show >/dev/null 2>&1; st=$?
  assert_status "permission mode $m is accepted" "$st" 0
done
for kv in permission-mode=yolo permission-mode=Plan cap=0 cap=-1 cap=many rounds=0 rounds=1x budget=0 budget=two; do
  k="${kv%%=*}"; v="${kv#*=}"
  git config orchestrator.autopilot.permission-mode plan
  git config "orchestrator.autopilot.$k" "$v"
  out="$("$ORCH" autopilot show 2>&1)"; st=$?
  assert_status "autopilot show dies on $k=$v" "$st" 1
  assert_contains "naming the key" "$out" "orchestrator.autopilot.$k"
  assert_contains "and the value $v" "$out" "is $v"
  git config --unset-all "orchestrator.autopilot.$k"
done
git config --unset-all orchestrator.autopilot.permission-mode
git config --unset-all orchestrator.autopilot.cap
git config --unset-all orchestrator.autopilot.rounds
git config --unset-all orchestrator.autopilot.budget
git config --unset-all orchestrator.autopilot.handle

out="$("$ORCH" autopilot show extra 2>&1)"; st=$?
assert_status "autopilot show refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh autopilot show"
out="$("$ORCH" autopilot bogus 2>&1)"; st=$?
assert_status "autopilot bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown autopilot op"

ORCH_AUTOPILOT=1 "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 0 under ORCH_AUTOPILOT=1" "$st" 0
env -u ORCH_AUTOPILOT "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 1 without ORCH_AUTOPILOT" "$st" 1
ORCH_AUTOPILOT=0 "$ORCH" autopilot active; st=$?
assert_status "autopilot active exits 1 under ORCH_AUTOPILOT=0" "$st" 1

# The gate: host first, then the permission mode.
noclaude_path="$(
  new=""; IFS=:; for d in $PATH; do [ -x "$d/claude" ] || new="$new:$d"; done; printf '%s' "${new#:}")"
git config orchestrator.autopilot.permission-mode plan
out="$(PATH="$fakebin:$PATH" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate passes with claude on PATH, a mode set and no host signal" "$st" 0
out="$(PATH="$fakebin:$PATH" ORCHESTRATOR_HOST=junie sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses on Junie" "$st" 1
assert_contains "saying autopilot is Claude Code only" "$out" "autopilot is Claude Code only"
out="$(PATH="$noclaude_path" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses with no claude on PATH" "$st" 1
assert_contains "saying autopilot is Claude Code only" "$out" "autopilot is Claude Code only"
git config --unset-all orchestrator.autopilot.permission-mode
out="$(PATH="$fakebin:$PATH" sourced_orch autopilot_gate 2>&1)"; st=$?
assert_status "the gate refuses with no permission mode set" "$st" 1
assert_contains "naming the key" "$out" "orchestrator.autopilot.permission-mode"

out="$("$ORCH" help 2>&1)"
assert_contains "autopilot show is in the usage text" "$out" "autopilot show"
assert_contains "autopilot active is in the usage text" "$out" "autopilot active"
assert_contains "the CLI conventions' noun table has an autopilot row" \
  "$(grep '^| `autopilot`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`active`'
assert_contains "host-capabilities has the headless-session row" \
  "$(grep '^| Start a headless session' "$PLUGIN_ROOT/docs/host-capabilities.md")" '`claude -p`'
restore_suite_env

# --- autopilot rounds, budget and start ---------------------------------------
# The plan comment's `## Autopilot` block, and the planning close's last step.
echo
echo "autopilot start"
fake_flow autopilot-start
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent
planf="$(mktemp -d)/01-plan.md"
plan_file "$planf" $'Rounds: 4\nBudget: 5'

out="$("$ORCH" autopilot rounds 2>&1)"; st=$?
assert_status "rounds with no plan comment dies" "$st" 1
assert_contains "naming the missing plan" "$out" "no 01-plan handoff"

fake_issue 8 open
out="$("$ORCH" autopilot start 8 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue without ready-for-agent" "$st" 1
assert_contains "naming the label" "$out" "ready-for-agent"
assert_eq "writing nothing" "$(fake_comments_of 8)$(fake_labels_of 8)" ""
fake_issue 9 open ready-for-agent orch:review
out="$("$ORCH" autopilot start 9 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue with a phase label" "$st" 1
assert_contains "naming the label" "$out" "orch:review"
assert_eq "writing nothing" "$(fake_comments_of 9)" ""
fake_issue 9 open ready-for-agent
bad_plan="$(mktemp -d)/01-plan.md"; complete_handoff "$bad_plan"
out="$("$ORCH" autopilot start 9 "$bad_plan" 2>&1)"; st=$?
assert_status "start refuses a plan with no Autopilot block" "$st" 1
assert_contains "naming it" "$out" "## Autopilot"
assert_eq "writing nothing" "$(fake_comments_of 9)$(fake_labels_of 9)" "ready-for-agent "

# a failure after the comment leaves the issue unlabelled and names the comment
fake_fail adapter_issue_relabel "HTTP 502"
out="$("$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
assert_status "a failed label add dies" "$st" 1
assert_contains "naming the comment posted" "$out" "posted the 01-plan comment on issue #7"
assert_eq "leaving the issue without a phase label" "$(fake_labels_of 7)" "ready-for-agent "
assert_eq "the comment is there" "$(fake_comments_of 7 | head -1)" "<!-- orch:handoff 01-plan -->"
fake_unfail

# a re-run on an unlabelled issue posts a newer plan comment, then labels last
sed -i 's/^Rounds: 4/Rounds: 6/' "$planf"
"$ORCH" autopilot start 7 "$planf" >/dev/null 2>&1; st=$?
assert_status "a re-run on an unlabelled issue succeeds" "$st" 0
assert_eq "posting a second plan comment" "$(ls "$ORCH_GH_FAKE_STORE/issues/7/comments" | wc -l | tr -d ' ')" "2"
assert_eq "and adding orch:spec" "$(fake_labels_of 7)" "orch:spec ready-for-agent "
out="$("$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
assert_status "a run on a labelled issue refuses" "$st" 1
assert_contains "naming the label" "$out" "orch:spec"

assert_eq "autopilot rounds prints the newest plan comment's Rounds" "$("$ORCH" autopilot rounds)" "6"
assert_eq "autopilot budget prints its Budget" "$("$ORCH" autopilot budget)" "5"
out="$("$ORCH" autopilot start 7 2>&1)"; st=$?
assert_contains "start's usage line" "$out" "usage: orch.sh autopilot start <issue> <plan-file>"
restore_suite_env

# --- autopilot ask and answer -------------------------------------------------
# The question comment, the reply read back, claim release (#1457).
echo
echo "autopilot ask and answer"
fake_flow autopilot-ask
export ORCHESTRATOR_HOST=claude
"$ORCH" state set issue 7 >/dev/null
state_fixture phase spec
# ask and answer
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
q="$(mktemp)"; printf '1. Keep it? Recommended: yes\n\nReply like `1: A`.\n' >"$q"
ORCH_AUTOPILOT=1 "$ORCH" autopilot ask spec "$q" >/dev/null 2>&1; st=$?
assert_status "autopilot ask succeeds" "$st" 0
assert_eq "the question is tagged and mentions the handle" "$(fake_comments_of 7 | head -2 | tr '\n' ' ')" "<!-- orch:question spec --> @o "
assert_contains "carrying the question" "$(fake_comments_of 7)" "1. Keep it?"
assert_contains "and the reply format" "$(fake_comments_of 7)" 'Reply in one comment like `1: A, 2: recommended, 3: <free text>` (`all: recommended` accepts everything).'
assert_eq "adding needs-human, dropping orch:running" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_eq "and releasing the claim" "$(fake_claim_held 7)" free
ans="$(mktemp)"
out="$("$ORCH" autopilot answer spec "$ans" 2>&1)"; st=$?
assert_status "answer with no reply exits 1" "$st" 1
assert_contains "saying so" "$out" "no reply"
fake_comment 7 o 2026-01-02T00:00:00Z "1: A"
fake_comment 7 o 2026-01-03T00:00:00Z "thanks"
"$ORCH" autopilot answer spec "$ans" >/dev/null 2>&1; st=$?
assert_status "answer with a reply succeeds" "$st" 0
assert_contains "writing the question" "$(cat "$ans")" "1. Keep it?"
assert_contains "and the reply" "$(cat "$ans")" "1: A"
assert_contains "and every later comment" "$(cat "$ans")" "thanks"
out="$("$ORCH" autopilot answer implement "$ans" 2>&1)"; st=$?
assert_status "answer for a phase never asked dies" "$st" 1
# a failed label add leaves the claim held and names the comment
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
fake_fail adapter_issue_relabel "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" autopilot ask spec "$q" 2>&1)"; st=$?
assert_status "a failed needs-human add dies" "$st" 1
assert_contains "naming the comment that landed" "$out" "posted the spec question comment"
assert_eq "the claim stays held" "$(fake_claim_held 7)" held
fake_unfail
restore_suite_env

# --- autopilot tick and run ---------------------------------------------------
# One pass of the watcher and the session wrapper it starts, against the gh
# fake, a real clone with a bare origin, and a fake session launcher (#1458).
echo
echo "autopilot tick"

tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open ready-for-agent orch:spec
printf 'Add the widget\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
printf '7\n' >"$launcher_dir/release"
# The caller's own ceiling must not reach the session.
out="$(CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=600000 "$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a tick over one hand-labelled issue succeeds" "$st" 0
calls="$(cat "$launcher_dir/calls" 2>/dev/null)"
side7="$top/.orchestrator/checkouts/7-add-the-widget"
assert_contains "asking in words for orch-flow's Next phase" "$calls" "orchestrator:orch-flow skill's Next phase"
assert_contains "with ORCH_AUTOPILOT=1" "$calls" "autopilot:1"
assert_contains "with the Explore and Plan agents disabled" "$calls" "explore-plan:1"
assert_contains "with a 2-hour background wait, whatever the caller sets" "$calls" "bg-wait:7200000"
# Every argument but the second, the prompt, which the line above matches.
assert_eq "the session runs claude -p with the permission mode and the lean flags" "$(grep '^arg:' "$launcher_dir/calls" | sed -n '1p;3,$p' | tr '\n' '|')" \
  "arg:-p|arg:--permission-mode|arg:acceptEdits|arg:--tools|arg:Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage,AskUserQuestion|arg:--settings|arg:{\"disableBundledSkills\":true,\"enabledPlugins\":{\"plugin-authoring@builtin\":false}}|arg:--strict-mcp-config|arg:--exclude-dynamic-system-prompt-sections|"
assert_contains "in the side checkout, slugged <n>-<title>" "$calls" "dir:$side7"
assert_contains "after orch:running was added" "$calls" "labels:7:orch:running orch:spec ready-for-agent "
assert_eq "the flow adopted issue 7" "$(cd "$side7" && "$ORCH" state get issue)" "7"
assert_contains "the hand-labelled issue got the minimal plan comment" "$(fake_comments_of 7)" "<!-- orch:handoff 01-plan -->"
assert_contains "carrying the repo defaults" "$(fake_comments_of 7)" "Rounds: 2"
assert_contains "and the budget" "$(fake_comments_of 7)" "Budget: 3"
assert_contains "and the adoption decision" "$(fake_comments_of 7)" "adopted to be reviewed as it stands"
assert_eq "the six labels exist with their colour and description" "$(fake_labels)" "needs-human	d93f0b	Waiting on the human
orch:done	c2e0c6	Autopilot flow: done
orch:implement	0e8a16	Autopilot flow: implement phase next
orch:review	5319e7	Autopilot flow: review phase next
orch:running	fbca04	Autopilot session running
orch:spec	1d76db	Autopilot flow: spec phase next"
assert_eq "a session that released its claim leaves no needs-human" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_eq "and no claim" "$(fake_claim_held 7)" free
assert_eq "its run pidfile is gone" "$(on_disk "$top/.orchestrator/autopilot/run/7.pid")" absent
logs="$(ls "$top/.orchestrator/autopilot/logs" 2>/dev/null)"
assert_eq "one log, named <issue>-<phase>-<UTC timestamp>.log" \
  "$(grep -cE '^7-spec-[0-9]{8}-[0-9]{6}\.log$' <<<"$logs")" "1"

# a plan comment the issue already has is not posted again
printf '' >"$launcher_dir/calls"
fake_issue 7 open ready-for-agent orch:spec
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_eq "no second plan comment: the first is still the only one" \
  "$(ls "$ORCH_GH_FAKE_STORE/issues/7/comments" | wc -l | tr -d ' ')" "1"
assert_eq "the side checkout is reused, not made again" "$("$ORCH" side-checkout list | wc -l | tr -d ' ')" "1"
assert_eq "and the session started in it" "$(grep -c "^dir:$side7\$" "$launcher_dir/calls")" "1"

# a session that exits with its claim held is a failure
rm -f "$launcher_dir/release"
printf 'session output line\n' >"$launcher_dir/out"; printf '3\n' >"$launcher_dir/exit"
fake_issue 7 open ready-for-agent orch:spec
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a tick with a failing session succeeds" "$st" 0
assert_eq "the failed issue is needs-human, no longer running" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_eq "its claim is released" "$(fake_claim_held 7)" free
failed_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "the log holds the session's output" "$(cat "$failed_log")" "session output line"
last_comment="$(fake_comments_of 7 | tail -4)"
assert_contains "the failure comment names the phase" "$last_comment" "spec phase"
assert_contains "the exit code" "$last_comment" "exit"
assert_contains "naming code 3" "$last_comment" "code 3"
assert_contains "and the log path" "$last_comment" "log: $failed_log"
assert_eq "a needs-human issue is not picked up again" "$(tick_calls)" "2"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "still not, on the next tick" "$(tick_calls)" "2"
assert_eq "a failure without the usage-limit message writes no limit file" "$(on_disk "$top/.orchestrator/autopilot/limit")" absent

# one that released its claim, then exited non-zero, is left alone
printf '7\n' >"$launcher_dir/release"
fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a released claim and a non-zero exit is no failure" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_not_contains "and posts no failure comment" "$(fake_comments_of 7)" "Autopilot failed"
released_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "its exit code is recorded in the session log" "$(cat "$released_log")" "session exited 3 with its claim released"

# one that exited zero with its claim still held is a failure too
rm -f "$launcher_dir/release"; printf '0\n' >"$launcher_dir/exit"
fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a clean exit with the claim held is needs-human" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_eq "its claim is released" "$(fake_claim_held 7)" free
clean_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "the failure comment names the log" "$(fake_comments_of 7 | tail -4)" "log: $clean_log"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: the cap, lost claims and the order ---------------------
echo
echo "autopilot tick pickup"
tick_fixture
for n in 9 7 8; do fake_issue "$n" open ready-for-agent orch:spec; printf 'Issue %s\n' "$n" >"$ORCH_GH_FAKE_STORE/issues/$n/title"; done
printf '7 8 9\n' >"$launcher_dir/release"
git config orchestrator.autopilot.cap 2
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a tick under a cap of 2 succeeds" "$st" 0
assert_eq "it starts two sessions" "$(tick_calls)" "2"
assert_eq "the oldest first" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "7-issue-7 8-issue-8 "
assert_eq "the third waits" "$(fake_labels_of 9)" "orch:spec ready-for-agent "

# claims of other hosts count against the cap; a lost claim skips the issue
printf '' >"$launcher_dir/calls"
git config orchestrator.autopilot.cap 3
fake_issue 7 open ready-for-agent orch:spec; fake_issue 8 open ready-for-agent orch:spec
fake_claim_seed 7 otherhost "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fake_claim_seed 90 otherhost "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '8\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a claim lost to another host skips its issue, the cap leaving room for one" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "8-issue-8 "
assert_eq "the lost claim stays theirs" "$(fake_claim_held 7)" held
assert_eq "and its issue untouched" "$(fake_labels_of 7)" "orch:spec ready-for-agent "
rm -f "$ORCH_GH_FAKE_STORE/claims/7" "$ORCH_GH_FAKE_STORE/claims/90"

# issues that are running, needs-human, closed or done are not picked up
printf '' >"$launcher_dir/calls"
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_issue 8 open ready-for-agent orch:spec needs-human
fake_issue 9 closed ready-for-agent orch:spec
fake_issue 10 open ready-for-agent orch:done
fake_issue 11 open ready-for-agent
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "none of them starts a session" "$(tick_calls)" "0"

# a claim create failing for any other reason stops the tick, naming it
fake_issue 7 open ready-for-agent orch:spec
fake_fail adapter_claim_create "HTTP 500 pushing the ref"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a failed claim push stops the tick non-zero" "$st" 1
assert_contains "naming the issue" "$out" "could not claim issue #7"
assert_contains "and the reason" "$out" "HTTP 500 pushing the ref"
fake_unfail
# a failed label upsert stops the tick, naming the label
fake_fail adapter_label_upsert "HTTP 502"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a failed label upsert stops the tick non-zero" "$st" 1
assert_contains "naming a label" "$out" "could not upsert the label orch:spec"
assert_eq "picking nothing up" "$(tick_calls)" "0"
fake_unfail

# the gate
git config --unset-all orchestrator.autopilot.permission-mode
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "tick refuses with no permission mode" "$st" 1
assert_contains "naming the key" "$out" "orchestrator.autopilot.permission-mode"
git config orchestrator.autopilot.permission-mode plan
out="$(ORCHESTRATOR_HOST=junie "$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "tick refuses on Junie" "$st" 1
assert_contains "saying so" "$out" "autopilot is Claude Code only"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: side checkouts, refusals and failed steps ----------------
echo
echo "autopilot tick failures"
tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open orch:spec
printf 'Needs ready\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "an init refusal does not stop the tick" "$st" 0
assert_eq "it starts no session" "$(tick_calls)" "0"
assert_eq "the issue is needs-human" "$(fake_labels_of 7)" "needs-human orch:spec "
assert_eq "its claim is released" "$(fake_claim_held 7)" free
assert_contains "the comment names the failed step" "$(fake_comments_of 7)" "step init failed"
assert_contains "and the phase" "$(fake_comments_of 7)" "spec phase"
assert_eq "the side checkout is kept" "$(on_disk "$top/.orchestrator/checkouts/7-needs-ready")" present
assert_eq "holding no flow" "$(on_disk "$top/.orchestrator/checkouts/7-needs-ready/.orchestrator/state.json")" absent
fake_issue 7 open ready-for-agent orch:spec
printf '7\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the next pickup reuses the side checkout and runs init again" "$(tick_calls)" "1"
assert_eq "one side checkout" "$("$ORCH" side-checkout list | wc -l | tr -d ' ')" "1"
assert_eq "now holding the flow" "$(on_disk "$top/.orchestrator/checkouts/7-needs-ready/.orchestrator/state.json")" present

# a forward skip is refused: label review, recorded phase spec
fake_issue 7 open ready-for-agent orch:review
printf '' >"$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a forward skip starts no session" "$(tick_calls)" "0"
assert_eq "and is needs-human" "$(fake_labels_of 7)" "needs-human orch:review ready-for-agent "
assert_contains "the comment names the recorded phase" "$(fake_comments_of 7 | tail -3)" "last moved to phase spec"
assert_eq "the claim is released" "$(fake_claim_held 7)" free
# a step back from done is refused
side7="$top/.orchestrator/checkouts/7-needs-ready"
(cd "$side7" && state_fixture phase "done")
fake_issue 7 open ready-for-agent orch:implement
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a step back from done starts no session" "$(tick_calls)" "0"
assert_contains "and says why" "$(fake_comments_of 7 | tail -3)" "last moved to phase done"
# two steps back is refused
(cd "$side7" && state_fixture phase review)
fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "two steps back starts no session" "$(tick_calls)" "0"
assert_contains "and says why" "$(fake_comments_of 7 | tail -3)" "last moved to phase review"
# one step back runs redo, and a redo refusal is a refusal
fake_issue 7 open ready-for-agent orch:implement
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a redo refusal starts no session" "$(tick_calls)" "0"
assert_contains "the comment names the redo" "$(fake_comments_of 7 | tail -3)" "redo review refused"
assert_contains "as a refusal" "$(fake_comments_of 7 | tail -3)" "refused to run the implement phase"
assert_eq "leaving needs-human" "$(fake_labels_of 7)" "needs-human orch:implement ready-for-agent "

# one step back that redo accepts starts the new phase's session
(cd "$side7" && state_fixture phase implement)
fake_issue 7 open ready-for-agent orch:spec
printf '7\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a relabel one step back runs redo and starts the new phase's session" "$(tick_calls)" "1"
assert_eq "the flow is back at spec" "$(cd "$side7" && "$ORCH" state get phase)" "spec"
assert_contains "the session starts after orch:running was added" "$(cat "$launcher_dir/calls")" "labels:7:orch:running orch:spec ready-for-agent "
printf '' >"$launcher_dir/calls"

# a failed side-checkout add is a failure, the claim released
fake_issue 8 open ready-for-agent orch:spec
printf 'Blocked add\n' >"$ORCH_GH_FAKE_STORE/issues/8/title"
mkdir -p "$top/.orchestrator/checkouts/8-blocked-add"
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed side-checkout add does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 8)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step" "$(fake_comments_of 8)" "step side-checkout add failed"
assert_eq "and the claim is released" "$(fake_claim_held 8)" free

# a failed plan-comment post is a failure, the claim released
fake_issue 9 open ready-for-agent orch:spec
printf 'No plan\n' >"$ORCH_GH_FAKE_STORE/issues/9/title"
fake_fail_times adapter_issue_comment 1 "HTTP 500 comment"
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed plan-comment post does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 9)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step" "$(fake_comments_of 9)" "step minimal plan comment failed"
assert_eq "and the claim is released" "$(fake_claim_held 9)" free
assert_eq "with no session started" "$(tick_calls)" "0"

# stale claims of this host are failures; other hosts' are left alone
fake_issue 10 open ready-for-agent orch:spec orch:running
fake_claim_seed 10 "$(hostname)" "$(dead_pid)"
fake_issue 11 open ready-for-agent orch:spec orch:running
fake_claim_seed 11 otherhost "$(dead_pid)"
fake_issue 12 open ready-for-agent orch:spec orch:running
fake_claim_seed 12 "$(hostname)" "$(dead_pid)"
mkdir -p "$top/.orchestrator/autopilot/run"
printf '%s\n' "$$" >"$top/.orchestrator/autopilot/run/12.pid"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "this host's claim with a dead pid is a failure" "$(fake_labels_of 10)" "needs-human orch:spec ready-for-agent "
assert_contains "with a comment naming the phase" "$(fake_comments_of 10)" "spec phase"
assert_eq "and its claim released" "$(fake_claim_held 10)" free
assert_eq "another host's claim is left alone" "$(fake_claim_held 11)" held
assert_eq "and its labels" "$(fake_labels_of 11)" "orch:running orch:spec ready-for-agent "
assert_eq "a live run pidfile keeps a claim whose tick pid is dead" "$(fake_claim_held 12)" held
printf '%s\n' "$(dead_pid)" >"$top/.orchestrator/autopilot/run/12.pid"
mkdir -p "$top/.orchestrator/autopilot/logs"
: >"$top/.orchestrator/autopilot/logs/12-spec-20250101T000000.log"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a dead run pidfile makes it stale" "$(fake_claim_held 12)" free
assert_contains "the stale comment names the session log" "$(fake_comments_of 12)" "logs/12-spec-20250101T000000.log"
assert_contains "and says no exit code is known" "$(fake_comments_of 12)" "no exit code"

# a stop that dies partway leaves the claim held and names the writes that
# landed
fake_issue 13 open ready-for-agent orch:spec orch:running
fake_claim_seed 13 "$(hostname)" "$(dead_pid)"
fake_fail adapter_claim_delete "HTTP 500"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "stale-claim cleanup with a failed claim delete dies" "$st" 1
assert_contains "naming the claim ref" "$out" "delete the claim ref"
assert_contains "and the writes that landed" "$out" "added needs-human, posted the failure comment, removed orch:running"
assert_eq "the claim is still held" "$(fake_claim_held 13)" held
fake_unfail
fake_fail_after adapter_issue_relabel 1 "HTTP 500"
fake_issue 13 open ready-for-agent orch:spec orch:running
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a failed orch:running removal dies" "$st" 1
assert_contains "naming the writes that landed" "$out" "writes that landed: added needs-human, posted the failure comment;"
assert_eq "the claim is still held after it" "$(fake_claim_held 13)" held
fake_unfail
fake_fail adapter_issue_comment "HTTP 500"
fake_issue 13 open ready-for-agent orch:spec orch:running
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a failed failure comment dies" "$st" 1
assert_contains "naming only the label add" "$out" "writes that landed: added needs-human;"
assert_eq "the claim is still held after that" "$(fake_claim_held 13)" held
fake_unfail
fake_claim_seed 13 otherhost
# a refusal dies the same way
fake_issue 7 open ready-for-agent orch:review
(cd "$top/.orchestrator/checkouts/7-needs-ready" && state_fixture phase spec)
fake_fail adapter_claim_delete "HTTP 500"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a refusal with a failed claim delete dies" "$st" 1
assert_contains "naming the writes that landed" "$out" "added needs-human, posted the refusal comment, removed orch:running"
assert_eq "the claim is still held for the refusal" "$(fake_claim_held 7)" held
fake_unfail
# a session that released its claim exits after the next phase's claim is made:
# the new claim is not this run's to fail, and the new run's pidfile survives
rm -f "$top/.orchestrator/autopilot/limit"
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7 "$(hostname)" 111
overlap_launcher="$(mktemp)"
cat >"$overlap_launcher" <<OVERLAP
#!/bin/sh
rm -f "$ORCH_GH_FAKE_STORE/claims/7"
printf '7\t%s\t222\timplement\t2026-01-02T00:00:00Z\n' "$(hostname)" >"$ORCH_GH_FAKE_STORE/claims/7"
printf '999\n' >"$top/.orchestrator/autopilot/run/7.pid"
exit 1
OVERLAP
chmod +x "$overlap_launcher"
ORCH_AUTOPILOT_LAUNCHER="$overlap_launcher" "$ORCH" autopilot run 7 >/dev/null 2>&1
assert_eq "a newer claim made while the session exits is left held" "$(fake_claim_held 7)" held
assert_eq "and its issue is not failed" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_eq "the newer run's pidfile is not removed by the older run" "$(cat "$top/.orchestrator/autopilot/run/7.pid" 2>/dev/null)" "999"
rm -f "$top/.orchestrator/autopilot/run/7.pid" "$ORCH_GH_FAKE_STORE/claims/7"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot watch ----------------------------------------------------------
# The loop around tick: one instance per clone, a failed tick survived, the
# pidfile gone on interrupt (#1459).
echo
echo "autopilot watch"
tick_fixture
top="$(git rev-parse --show-toplevel)"
pidfile="$(git rev-parse --git-common-dir)/orchestrator/autopilot-watch.pid"
watch_log="$(mktemp)"
mkdir -p "$(dirname "$pidfile")"
printf '%s\n' "$$" >"$pidfile"
out="$("$ORCH" autopilot watch 2>&1)"; st=$?
assert_status "a second watch of the same clone is refused" "$st" 1
assert_contains "naming the live one" "$out" "already running"
assert_eq "and leaves the live one's pidfile" "$(cat "$pidfile")" "$$"

# one watch, started over a dead pidfile while every tick fails
printf '%s\n' "$(dead_pid)" >"$pidfile"
fake_fail adapter_label_upsert "HTTP 500 label"
"$ORCH" autopilot watch --every 1 >/dev/null 2>"$watch_log" &
watch_pid=$!
for _ in $(seq 1 60); do [ "$(cat "$pidfile" 2>/dev/null)" = "$watch_pid" ] && [ "$(grep -c 'the tick failed' "$watch_log")" -ge 2 ] && break; sleep 0.1; done
assert_eq "a dead pidfile is replaced" "$(cat "$pidfile" 2>/dev/null)" "$watch_pid"
kill -0 "$watch_pid" 2>/dev/null; st=$?
assert_status "watch survives a failed tick" "$st" 0
assert_contains "reporting it with its exit status" "$(cat "$watch_log")" "the tick failed (exit 1)"
assert_eq "and ticking again after it" "$([ "$(grep -c 'the tick failed' "$watch_log")" -ge 2 ] && echo yes)" "yes"
kill -TERM "$watch_pid"; wait "$watch_pid" 2>/dev/null
assert_eq "an interrupted watch removes its pidfile" "$(on_disk "$pidfile")" absent
fake_unfail
out="$("$ORCH" autopilot watch --every 0 2>&1)"; st=$?
assert_status "--every refuses zero" "$st" 1
git config --unset-all orchestrator.autopilot.permission-mode
out="$("$ORCH" autopilot watch 2>&1)"; st=$?
assert_status "watch refuses with no permission mode" "$st" 1
assert_contains "naming the key" "$out" "orchestrator.autopilot.permission-mode"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: the usage limit ------------------------------------------
echo
echo "autopilot tick usage limit"
tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open ready-for-agent orch:spec; printf 'Limit 7\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
reset_epoch="$(( $(date +%s) + 7200 ))"
reset_iso="$(date -u -d "@$reset_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$reset_epoch" +%Y-%m-%dT%H:%M:%SZ)"
printf 'Claude AI usage limit reached|%s\n' "$reset_epoch" >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the session that hit the limit starts one session" "$(tick_calls)" "1"
assert_contains "its failure comment names the usage limit" "$(fake_comments_of 7)" "usage limit"
assert_contains "and the reset time" "$(fake_comments_of 7)" "$reset_iso"
fake_issue 8 open ready-for-agent orch:spec; printf 'Limit 8\n' >"$ORCH_GH_FAKE_STORE/issues/8/title"
assert_eq "it writes the limit file" "$(cat "$top/.orchestrator/autopilot/limit")" "$reset_iso"
assert_eq "and the failed issue is needs-human" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a tick under the limit succeeds" "$st" 0
assert_eq "picking nothing up" "$(tick_calls)" "1"
assert_contains "printing the reset time" "$out" "$reset_iso"
assert_eq "the other issue waits" "$(fake_labels_of 8)" "orch:spec ready-for-agent "
# stale claims are still cleaned while paused
fake_issue 9 open ready-for-agent orch:spec orch:running
fake_claim_seed 9 "$(hostname)" "$(dead_pid)"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a paused tick still cleans stale claims" "$(fake_labels_of 9)" "needs-human orch:spec ready-for-agent "
# once the time has passed, the file goes and pickup resumes
printf '2020-01-01T00:00:00Z\n' >"$top/.orchestrator/autopilot/limit"
: >"$launcher_dir/out"; printf '0\n' >"$launcher_dir/exit"; printf '8\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "once the reset time has passed the file is removed" "$(on_disk "$top/.orchestrator/autopilot/limit")" absent
assert_eq "and pickup resumes" "$(tick_calls)" "2"
# a message without a reset time pauses for an hour
fake_issue 8 open ready-for-agent orch:spec
printf 'Claude AI usage limit reached\n' >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"; rm -f "$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
limit_epoch="$(date -u -d "$(cat "$top/.orchestrator/autopilot/limit")" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$(cat "$top/.orchestrator/autopilot/limit")" +%s)"
assert_eq "no reset time in the message: one hour on" "$(( (limit_epoch - $(date +%s) + 30) / 3600 ))" "1"
assert_contains "the comment still names the usage limit" "$(fake_comments_of 8 | tail -4)" "usage limit"
assert_not_contains "but names no reset time it does not have" "$(fake_comments_of 8 | tail -4)" "resets"
# the other usage-limit wordings are detected, each with the one hour fallback
for wording in "Claude Opus usage limit reached" "5-hour limit reached" "Weekly limit reached"; do
  rm -f "$top/.orchestrator/autopilot/limit"
  fake_issue 8 open ready-for-agent orch:spec
  printf '%s\n' "$wording" >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"
  fake_claim_seed 8
  "$ORCH" autopilot run 8 >/dev/null 2>&1
  assert_eq "\"$wording\" writes the limit file" "$(on_disk "$top/.orchestrator/autopilot/limit")" present
  read -r limit_epoch _ < <(local_fields "$(cat "$top/.orchestrator/autopilot/limit")")
  assert_eq "and pauses an hour on" "$(( (limit_epoch - $(date +%s) + 30) / 3600 ))" "1"
done
# a "resets <time>" message pauses until that next moment, in local time
rm -f "$top/.orchestrator/autopilot/limit"
fake_issue 8 open ready-for-agent orch:spec
printf '5-hour limit reached ∙ resets 3pm\n' >"$launcher_dir/out"
fake_claim_seed 8
"$ORCH" autopilot run 8 >/dev/null 2>&1
read -r limit_epoch limit_hour _ < <(local_fields "$(cat "$top/.orchestrator/autopilot/limit")")
assert_eq "\"resets 3pm\" pauses until 15:00 local" "$limit_hour" "15"
assert_eq "within the next day" "$([ "$limit_epoch" -gt "$(date +%s)" ] && [ "$limit_epoch" -le "$(( $(date +%s) + 86400 + 3600 ))" ] && echo yes)" "yes"
rm -f "$top/.orchestrator/autopilot/limit"
fake_issue 8 open ready-for-agent orch:spec
printf 'Weekly limit reached ∙ resets Mon 9am\n' >"$launcher_dir/out"
fake_claim_seed 8
"$ORCH" autopilot run 8 >/dev/null 2>&1
read -r limit_epoch limit_hour limit_day < <(local_fields "$(cat "$top/.orchestrator/autopilot/limit")")
assert_eq "\"resets Mon 9am\" pauses until a Monday" "$limit_day" "Mon"
assert_eq "at 09:00 local" "$limit_hour" "09"
assert_eq "within the next week" "$([ "$limit_epoch" -gt "$(date +%s)" ] && [ "$limit_epoch" -le "$(( $(date +%s) + 7 * 86400 + 3600 ))" ] && echo yes)" "yes"
# another "limit reached" is no usage limit
for wording in "iteration limit reached" "API rate limit reached, retrying"; do
  rm -f "$top/.orchestrator/autopilot/limit"
  fake_issue 8 open ready-for-agent orch:spec
  printf '%s\n' "$wording" >"$launcher_dir/out"
  fake_claim_seed 8
  "$ORCH" autopilot run 8 >/dev/null 2>&1
  assert_eq "\"$wording\" writes no limit file" "$(on_disk "$top/.orchestrator/autopilot/limit")" absent
done
# a failed session's stop dies partway: the claim stays held, the landed writes
# named
rm -f "$top/.orchestrator/autopilot/limit"
fake_issue 8 open ready-for-agent orch:spec orch:running
printf 'session output line\n' >"$launcher_dir/out"
fake_claim_seed 8
fake_fail adapter_claim_delete "HTTP 500"
out="$("$ORCH" autopilot run 8 2>&1)"; st=$?
assert_status "a session failure whose claim delete fails dies" "$st" 1
assert_contains "naming the writes that landed" "$out" "added needs-human, posted the failure comment, removed orch:running"
assert_eq "the claim is still held" "$(fake_claim_held 8)" held
fake_unfail
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

