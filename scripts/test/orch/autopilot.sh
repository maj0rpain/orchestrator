# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# iso_of <epoch>: epoch seconds as a UTC timestamp, GNU or BSD date.
iso_of() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
# rl_event <5h status> <5h utilization> <5h reset> <7d status> <7d utilization>
# <7d reset>: a rate_limit_event line.
rl_event() {
  printf '{"type":"rate_limit_event","rate_limit_info":{"status":"%s","resetsAt":%s,"rateLimitType":"seven_day","utilization":%s,"unifiedWindows":{"five_hour":{"utilization":%s,"resetsAt":%s,"status":"%s"},"seven_day":{"utilization":%s,"resetsAt":%s,"status":"%s"}}}}\n' \
    "$4" "$6" "$5" "$2" "$3" "$1" "$5" "$6" "$4"
}
# ndjson_with <line>: a session log of NDJSON lines with <line> as a plain text
# line among them, and a rate_limit_event that rejects nothing.
ndjson_with() {
  printf '%s\n' '{"type":"system","subtype":"init"}' "$(rl_event allowed 0.1 4102444800 allowed 0.1 4102444800)" \
    "$1" '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}'
}
# tick_calls: how many sessions the launcher has been asked for.
tick_calls() { local n; n="$(grep -c '^argv:' "$launcher_dir/calls" 2>/dev/null)"; printf '%s\n' "${n:-0}"; }
# local_fields <iso>: the limit file's UTC timestamp as "<epoch> <%H> <%a>" in
# local time.
local_fields() {
  local e
  e="$(date -u -d "$1" +%s 2>/dev/null || date -u -j -f %Y-%m-%dT%H:%M:%SZ "$1" +%s)"
  printf '%s %s\n' "$e" "$(date -d "@$e" '+%H %a' 2>/dev/null || date -r "$e" '+%H %a')"
}
# fake_issue_drop <n>...: each issue is gone from the store.
fake_issue_drop() { local n; for n in "$@"; do rm -rf "$ORCH_GH_FAKE_STORE/issues/$n"; done; }
# fake_claim_release <issue>: the store holds no claim on it.
fake_claim_release() { rm -f "$ORCH_GH_FAKE_STORE/claims/$1"; }
# fake_last_comment_of <n>: the body of issue #n's newest comment in the gh
# fake's store (newest by numeric comment order); the issue holds a comment.
fake_last_comment_of() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1/comments"
  cat "$d/$(ls "$d" | sort -n | tail -n 1)/body"
}
# live_record <pid>: the pidfile record of a running process, read from /proc
# independently of orch.sh (the start time is stat's field after the command).
live_record() { printf '%s %s\n' "$1" "$(sed 's/^.*) //' "/proc/$1/stat" | cut -d' ' -f20)"; }
# dead_pid: the pid of a process that has exited.
dead_pid() { sleep 0 & local p=$!; wait "$p"; printf '%s\n' "$p"; }


# --- autopilot ---------------------------------------------------------------
# The clone-scoped autopilot settings and the autopilot-session check.
echo
echo "autopilot"
new_repo >/dev/null

out="$("$ORCH" autopilot show 2>&1)"; st=$?
assert_status "autopilot show succeeds with nothing set" "$st" 0
assert_contains "the permission mode has no default" "$out" "orchestrator.autopilot.permission-mode (none) (unset)"
assert_contains "the cap defaults to 3" "$out" "orchestrator.autopilot.cap 3 (default)"
assert_contains "the handle defaults to the repo's owner" "$out" "orchestrator.autopilot.handle o (default)"
assert_contains "the rounds default to 2" "$out" "orchestrator.autopilot.rounds 2 (default)"
assert_contains "the budget defaults to 3" "$out" "orchestrator.autopilot.budget 3 (default)"
assert_contains "the model has no default" "$out" "orchestrator.autopilot.model (none) (unset)"
assert_contains "nor has the effort" "$out" "orchestrator.autopilot.effort (none) (unset)"

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

git config orchestrator.autopilot.model opus
git config --global orchestrator.autopilot.effort inherit
out="$("$ORCH" autopilot show 2>&1)"
assert_contains "a set model shows with its source" "$out" "orchestrator.autopilot.model opus (local)"
assert_contains "a stored inherit shows as inherit" "$out" "orchestrator.autopilot.effort inherit (global)"
git config --global --unset-all orchestrator.autopilot.effort
for kv in "model=gpt|sonnet|opus|haiku|fable|inherit" "effort=extreme|low|medium|high|xhigh|max|inherit" "model=Opus|sonnet|opus|haiku|fable|inherit"; do
  k="${kv%%=*}"; rest="${kv#*=}"; v="${rest%%|*}"; allowed="${rest#*|}"
  git config "orchestrator.autopilot.$k" "$v"
  out="$("$ORCH" autopilot show 2>&1)"; st=$?
  assert_status "autopilot show dies on $k=$v" "$st" 1
  assert_contains "naming the key" "$out" "orchestrator.autopilot.$k is $v"
  assert_contains "and the allowed values for $k" "$out" "want $allowed"
  git config --unset-all "orchestrator.autopilot.$k"
done
git config --unset-all orchestrator.autopilot.model
git config --unset-all orchestrator.autopilot.effort

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
assert_eq "naming the missing plan" "$out" "orch: issue #7 has no 01-plan handoff comment"

fake_issue 8 open
out="$("$ORCH" autopilot start 8 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue without ready-for-agent" "$st" 1
assert_contains "naming the label" "$out" "ready-for-agent"
assert_eq "writing nothing" "$(fake_comments_of 8)$(fake_labels_of 8)" ""
fake_issue 9 open ready-for-agent orch:review
fake_fail adapter_issue_state_labels "HTTP 502"
out="$("$ORCH" autopilot start 9 "$planf" 2>&1)"; st=$?
fake_unfail
assert_status "start on a failed issue read dies" "$st" 1
assert_eq "in one line naming gh and the reason" "$(printf '%s\n' "$out" | grep -c .)|${out#orch: gh could not read issue #9: }" "1|HTTP 502"
out="$("$ORCH" autopilot start 9 "$planf" 2>&1)"; st=$?
assert_status "start refuses an issue with a phase label" "$st" 1
assert_contains "naming the label" "$out" "orch:review"
assert_eq "writing nothing" "$(fake_comments_of 9)" ""
fake_issue 9 open ready-for-agent
bad_plan="$(mktemp -d)/01-plan.md"; complete_handoff "$bad_plan"
out="$("$ORCH" autopilot start 9 "$bad_plan" 2>&1)"; st=$?
assert_status "start refuses a plan with no Autopilot block" "$st" 1
assert_contains "naming it" "$out" "## Autopilot"
assert_contains "and that nothing was posted" "$out" "is not valid - nothing posted"
assert_eq "writing nothing" "$(fake_comments_of 9)$(fake_labels_of 9)" "ready-for-agent "

# a failed plan post dies with the reason, adds no label and leaves no temp file
start_tmp="$(mktemp -d)"
fake_fail adapter_issue_comment "HTTP 502 post"
out="$(TMPDIR="$start_tmp" "$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
fake_unfail
assert_status "a failed plan post dies" "$st" 1
assert_contains "showing the gh reason" "$out" "HTTP 502 post"
assert_eq "adding no phase label" "$(fake_labels_of 7)" "ready-for-agent "
assert_eq "leaving no temp file" "$(ls -A "$start_tmp")" ""

# a failure after the comment leaves the issue unlabelled and names the comment
fake_fail adapter_issue_relabel "HTTP 502"
out="$("$ORCH" autopilot start 7 "$planf" 2>&1)"; st=$?
assert_status "a failed label add dies" "$st" 1
assert_contains "naming the comment posted" "$out" "posted the 01-plan comment on issue #7"
assert_contains "and that the issue is unlabelled, so no watcher picks it up" "$out" "the issue is unlabelled, so no watcher picks it up"
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
printf 'old answer\n' >"$ans"
out="$("$ORCH" autopilot answer spec "$ans" 2>&1)"; st=$?
assert_status "answer with no reply exits 1" "$st" 1
assert_contains "saying so" "$out" "no reply"
assert_eq "and leaves an existing answer file as it was" "$(cat "$ans")" "old answer"
fake_comment 7 o 2026-01-02T00:00:00Z "1: A"
fake_comment 7 o 2026-01-03T00:00:00Z "thanks"
"$ORCH" autopilot answer spec "$ans" >/dev/null 2>&1; st=$?
assert_status "answer with a reply succeeds" "$st" 0
assert_eq "the answer file is the question, then each later comment after a --- line" "$(cat "$ans"; printf x)" "@o

1. Keep it? Recommended: yes

Reply like \`1: A\`.

Reply in one comment like \`1: A, 2: recommended, 3: <free text>\` (\`all: recommended\` accepts everything).

---
1: A
---
thanks
x"
kept="$(cat "$ans")"
out="$("$ORCH" autopilot answer implement "$ans" 2>&1)"; st=$?
assert_status "answer for a phase never asked exits 2, never no reply's 1" "$st" 2
assert_contains "naming the phase" "$out" "has no implement question comment"
assert_eq "and leaves the answer file as it was" "$(cat "$ans")" "$kept"
fake_fail adapter_issue_json "HTTP 500"
out="$("$ORCH" autopilot answer spec "$ans" 2>&1)"; st=$?
assert_status "a failed comment read exits 2, never no reply's 1" "$st" 2
assert_contains "naming the read" "$out" "read the comments of issue #7"
fake_unfail
# a question ending in the text noreply is read as any other (#1723)
fake_issue 8 open ready-for-agent orch:spec
"$ORCH" state set issue 8 >/dev/null
fake_comment 8 o 2026-01-01T00:00:00Z "<!-- orch:question spec -->
Keep it? noreply"
ans8="$(mktemp)"
out="$("$ORCH" autopilot answer spec "$ans8" 2>&1)"; st=$?
assert_status "a question ending in noreply, unanswered, exits 1" "$st" 1
assert_contains "saying no reply" "$out" "no reply"
fake_comment 8 o 2026-01-02T00:00:00Z "1: A"
"$ORCH" autopilot answer spec "$ans8" >/dev/null 2>&1; st=$?
assert_status "once a reply follows it succeeds" "$st" 0
assert_eq "and keeps the question's text with the reply" "$(cat "$ans8")" "Keep it? noreply
---
1: A"
"$ORCH" state set issue 7 >/dev/null
# a failed label add leaves the claim held and names the comment
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7
fake_fail adapter_issue_relabel "HTTP 500"
out="$(ORCH_AUTOPILOT=1 "$ORCH" autopilot ask spec "$q" 2>&1)"; st=$?
assert_status "a failed needs-human add dies" "$st" 1
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
fake_issue_title 7 "Add the widget"
printf '7\n' >"$launcher_dir/release"
# The caller's own ceiling must not reach the session.
out="$(CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=600000 "$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "a tick over one hand-labelled issue succeeds" "$st" 0
calls="$(cat "$launcher_dir/calls" 2>/dev/null)"
side7="$top/.orchestrator/checkouts/add-the-widget"
assert_contains "asking in words for orch-flow's Next phase" "$calls" "orchestrator:orch-flow skill's Next phase"
assert_contains "with ORCH_AUTOPILOT=1" "$calls" "autopilot:1"
assert_contains "with the Explore and Plan agents disabled" "$calls" "explore-plan:1"
assert_contains "with a 2-hour background wait, whatever the caller sets" "$calls" "bg-wait:7200000"
# Every argument but the second, the prompt, which the line above matches.
assert_eq "the session runs claude -p with the permission mode and the lean flags" "$(grep '^arg:' "$launcher_dir/calls" | sed -n '1p;3,$p' | tr '\n' '|')" \
  "arg:-p|arg:--permission-mode|arg:acceptEdits|arg:--tools|arg:Agent,Skill,Bash,Read,Edit,Write,Grep,Glob,SendMessage,AskUserQuestion|arg:--settings|arg:{\"disableBundledSkills\":true,\"enabledPlugins\":{\"plugin-authoring@builtin\":false}}|arg:--strict-mcp-config|arg:--exclude-dynamic-system-prompt-sections|arg:--output-format|arg:stream-json|arg:--verbose|"
assert_not_contains "no --model when the key is unset" "$calls" "arg:--model"
assert_not_contains "and no --effort" "$calls" "arg:--effort"
assert_contains "in the side checkout, slugged by the title" "$calls" "dir:$side7"
assert_contains "after orch:running was added" "$calls" "labels:7:orch:running orch:spec ready-for-agent "
assert_eq "the flow adopted issue 7" "$(cd "$side7" && "$ORCH" state get issue)" "7"
assert_contains "the hand-labelled issue got the minimal plan comment" "$(fake_comments_of 7)" "<!-- orch:handoff 01-plan -->"
assert_contains "carrying the repo defaults" "$(fake_comments_of 7)" "Rounds: 2"
assert_contains "and the budget" "$(fake_comments_of 7)" "Budget: 3"
assert_contains "and the adoption decision" "$(fake_comments_of 7)" "adopted to be reviewed as it stands"
assert_eq "the labels exist with their colour and description" "$(fake_labels)" "needs-human	d93f0b	Waiting on the human
orch:done	c2e0c6	Autopilot flow: done
orch:implement	0e8a16	Autopilot flow: implement phase next
orch:limited	c5def5	Autopilot session stopped on a usage limit; retried after the reset
orch:review	5319e7	Autopilot flow: review phase next
orch:running	fbca04	Autopilot session running
orch:spec	1d76db	Autopilot flow: spec phase next"
assert_eq "a session that released its claim leaves no needs-human" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_eq "and no claim" "$(fake_claim_held 7)" free
assert_eq "its run pidfile is gone" "$(on_disk "$top/.orchestrator/autopilot/run/7.pid")" absent
logs="$(ls "$top/.orchestrator/autopilot/logs" 2>/dev/null)"
assert_eq "one log, named <issue>-<phase>-<UTC timestamp>.log" \
  "$(grep -cE '^7-spec-[0-9]{8}-[0-9]{6}\.log$' <<<"$logs")" "1"

# a set model and effort reach the launch; inherit passes neither
printf '' >"$launcher_dir/calls"
git config orchestrator.autopilot.model opus
git config orchestrator.autopilot.effort inherit
fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_contains "a set model is passed" "$(grep '^arg:' "$launcher_dir/calls" | tr '\n' '|')" "arg:--model|arg:opus|"
assert_not_contains "an inherit effort is not passed" "$(cat "$launcher_dir/calls")" "arg:--effort"
git config orchestrator.autopilot.effort high
printf '' >"$launcher_dir/calls"
fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_contains "a set effort is passed" "$(grep '^arg:' "$launcher_dir/calls" | tr '\n' '|')" "arg:--effort|arg:high|"
git config --unset-all orchestrator.autopilot.model
git config --unset-all orchestrator.autopilot.effort

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
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7 "$(hostname)" "$$"
"$ORCH" autopilot run 7 >/dev/null 2>&1
assert_eq "a released claim and a non-zero exit is no failure" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_not_contains "and posts no failure comment" "$(fake_comments_of 7)" "Autopilot failed"
released_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "its exit code is recorded in the session log" "$(cat "$released_log")" "session exited 3 with its claim released"

# one that exited zero with its claim still held is a failure too
rm -f "$launcher_dir/release"; printf '0\n' >"$launcher_dir/exit"
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7 "$(hostname)" "$$"
"$ORCH" autopilot run 7 >/dev/null 2>&1
assert_eq "a clean exit with the claim held is needs-human" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_eq "its claim is released" "$(fake_claim_held 7)" free
clean_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "the failure comment names the log" "$(fake_comments_of 7 | tail -4)" "log: $clean_log"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: the cap, lost claims and the order ---------------------
echo
echo "autopilot tick pickup"
tick_fixture
for n in 9 7 8; do fake_issue "$n" open ready-for-agent orch:spec; fake_issue_title "$n" "Issue $n"; done
printf '7 8 9\n' >"$launcher_dir/release"
git config orchestrator.autopilot.cap 2
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a tick under a cap of 2 succeeds" "$st" 0
assert_eq "it starts two sessions" "$(tick_calls)" "2"
assert_eq "the oldest first" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "issue-7 issue-8 "
assert_eq "the third waits" "$(fake_labels_of 9)" "orch:spec ready-for-agent "

# the slug: the issue title alone, whole words, at most 40 characters
pickup_titled() { # <issue> <title>: ticks over the issue; prints its side checkout's basename and its flow's slug
  fake_issue "$1" open ready-for-agent orch:spec; fake_issue_title "$1" "$2"
  printf '%s\n' "$1" >"$launcher_dir/release"
  local before side; before="$(ls "$top/.orchestrator/checkouts" 2>/dev/null)"
  "$ORCH" autopilot tick >/dev/null 2>&1
  side="$(comm -13 <(printf '%s\n' "$before") <(ls "$top/.orchestrator/checkouts") | head -1)"
  [ -n "$side" ] || { echo none; return; }
  side="$top/.orchestrator/checkouts/$side"
  printf '%s %s\n' "$(basename "$side")" "$(cd "$side" && "$ORCH" state get slug)"
}
top="$(git rev-parse --show-toplevel)"
git config orchestrator.autopilot.cap 5
fake_issue_drop 9
for n in 21 22 23 24; do fake_issue "$n" open ready-for-agent orch:spec; done
fake_issue_title 21 'Agent settings: repeated kind/host switches and duplicated listing remedy builders (9 findings)'
fake_issue_title 22 'Fix the widget'
fake_issue_title 23 'Aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeee rest'
fake_issue_title 24 '!!! ???'
printf '21 22 23 24\n' >"$launcher_dir/release"
printf '' >"$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the slug tick starts exactly the four slug issues" "$(tick_calls)" "4"
side_of() { # <issue>: prints the basename of the side checkout recording the issue and its flow's slug, or none
  local d
  for d in "$top"/.orchestrator/checkouts/*/; do
    [ "$(cd "$d" && "$ORCH" state get issue 2>/dev/null)" = "$1" ] || continue
    printf '%s %s\n' "$(basename "$d")" "$(cd "$d" && "$ORCH" state get slug)"
    return
  done
  echo none
}
assert_eq "a long title is cut to whole words" "$(side_of 21)" "agent-settings-repeated-kind-host agent-settings-repeated-kind-host"
assert_eq "a short title is used whole" "$(side_of 22)" "fix-the-widget fix-the-widget"
assert_eq "a first word over 40 characters is cut at 40" "$(side_of 23)" "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd"
assert_eq "an all-punctuation title is untitled" "$(side_of 24)" "untitled untitled"
assert_eq "a clash with another issue's side checkout appends the issue" "$(pickup_titled 25 'Fix the widget')" "fix-the-widget-25 fix-the-widget-25"
# a re-pickup reuses a legacy-named side checkout and its slug
(cd "$top" && "$ORCH" side-checkout add 26-legacy-title --issue 26 >/dev/null 2>&1)
assert_eq "a re-pickup reuses a legacy-named side checkout" "$(pickup_titled 26 'Legacy title')" "none"
assert_eq "no second checkout is made for it" "$(printf '%s\n' "$top"/.orchestrator/checkouts/*legacy* | wc -l | tr -d ' ')" "1"
assert_eq "and the flow was initialised under the legacy slug" "$(cd "$top/.orchestrator/checkouts/26-legacy-title" && "$ORCH" state get slug)" "26-legacy-title"

# claims of other hosts count against the cap; a lost claim skips the issue
printf '' >"$launcher_dir/calls"
git config orchestrator.autopilot.cap 3
fake_issue 7 open ready-for-agent orch:spec; fake_issue 8 open ready-for-agent orch:spec
fake_claim_seed 7 otherhost "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fake_claim_seed 90 otherhost "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '8\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a claim lost to another host skips its issue, the cap leaving room for one" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "issue-8 "
assert_eq "the lost claim stays theirs" "$(fake_claim_held 7)" held
assert_eq "and its issue untouched" "$(fake_labels_of 7)" "orch:spec ready-for-agent "
fake_claim_release 7; fake_claim_release 90

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
for name in model effort; do
  git config "orchestrator.autopilot.$name" gpt
  out="$("$ORCH" autopilot tick 2>&1)"; st=$?
  assert_status "tick refuses an autopilot $name outside the list" "$st" 1
  assert_contains "naming the $name key and value" "$out" "orchestrator.autopilot.$name is gpt"
  assert_eq "before starting any session, for the $name" "$(tick_calls)" "0"
  git config --unset-all "orchestrator.autopilot.$name"
done
noclaude_path="$(
  new=""; IFS=:; for d in $PATH; do [ -x "$d/claude" ] || new="$new:$d"; done; printf '%s' "${new#:}")"
out="$(PATH="$noclaude_path" "$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "tick refuses with no claude on PATH" "$st" 1
assert_contains "saying autopilot is Claude Code only" "$out" "autopilot is Claude Code only"
assert_eq "before starting any session, with no claude" "$(tick_calls)" "0"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: side checkouts, refusals and failed steps ----------------
echo
echo "autopilot tick failures"
tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open orch:spec
fake_issue_title 7 "Needs ready"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "an init refusal does not stop the tick" "$st" 0
assert_eq "it starts no session" "$(tick_calls)" "0"
assert_eq "the issue is needs-human" "$(fake_labels_of 7)" "needs-human orch:spec "
assert_eq "its claim is released" "$(fake_claim_held 7)" free
assert_contains "the comment names the failed step" "$(fake_comments_of 7)" "step init failed"
assert_contains "and the phase" "$(fake_comments_of 7)" "spec phase"
assert_eq "the side checkout is kept" "$(on_disk "$top/.orchestrator/checkouts/needs-ready")" present
assert_eq "holding no flow" "$(on_disk "$top/.orchestrator/checkouts/needs-ready/.orchestrator/state.json")" absent
fake_issue 7 open ready-for-agent orch:spec
printf '7\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the next pickup reuses the side checkout and runs init again" "$(tick_calls)" "1"
assert_eq "one side checkout" "$("$ORCH" side-checkout list | wc -l | tr -d ' ')" "1"
assert_eq "now holding the flow" "$(on_disk "$top/.orchestrator/checkouts/needs-ready/.orchestrator/state.json")" present

# a forward skip is refused: label review, recorded phase spec
fake_issue 7 open ready-for-agent orch:review
printf '' >"$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a forward skip starts no session" "$(tick_calls)" "0"
assert_eq "and is needs-human" "$(fake_labels_of 7)" "needs-human orch:review ready-for-agent "
assert_contains "the comment names the recorded phase" "$(fake_comments_of 7 | tail -3)" "last moved to phase spec"
assert_eq "the claim is released" "$(fake_claim_held 7)" free
# a step back from done is refused
side7="$top/.orchestrator/checkouts/needs-ready"
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
fake_issue_title 8 "Blocked add"
mkdir -p "$top/.orchestrator/checkouts/blocked-add" "$top/.orchestrator/checkouts/blocked-add-8"
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed side-checkout add does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 8)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step" "$(fake_comments_of 8)" "step side-checkout add failed"
assert_eq "and the claim is released" "$(fake_claim_held 8)" free

# a failed plan-comment post is a failure, the claim released
fake_issue 9 open ready-for-agent orch:spec
fake_issue_title 9 "No plan"
fake_fail_times adapter_issue_comment 1 "HTTP 500 comment"
tick_tmp="$(mktemp -d)"
TMPDIR="$tick_tmp" "$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed plan-comment post does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 9)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step and the gh reason" "$(fake_comments_of 9)" "step minimal plan comment failed: orch: gh could not post the 01-plan handoff on issue #9: HTTP 500 comment"
assert_eq "leaving no temp file from the post" "$(ls -A "$tick_tmp")" ""
assert_eq "and the claim is released" "$(fake_claim_held 9)" free
assert_eq "with no session started" "$(tick_calls)" "0"

# a failed orch:running write in pickup keeps standing_begin's own wording
fake_issue 21 open ready-for-agent orch:spec
fake_issue_title 21 "Begin fails"
fake_fail_times adapter_issue_relabel 1 "HTTP 500"
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
fake_unfail
assert_status "a failed orch:running write does not stop the tick" "$st" 0
assert_contains "the comment names the step and the reason" "$(fake_comments_of 21)" "Autopilot failed in the spec phase: step adding orch:running failed: HTTP 500"
assert_eq "and the claim is released" "$(fake_claim_held 21)" free

# a die inside a subshell step fails that step only, and a cd never leaks
fake_issue 20 open ready-for-agent orch:spec orch:running
out="$(sourced_orch_script 'start="$PWD"; autopilot_pickup_step 20 spec failure "step minimal plan comment failed" autopilot_in_subshell die "could not read the comments" || echo "went on:$?"; autopilot_pickup_step 20 spec failure "step init failed" autopilot_in_subshell cd / || true; echo "cwd-kept:$([ "$PWD" = "$start" ] && echo yes || echo no)"' 2>&1)"
assert_contains "a die inside a step does not end the tick" "$out" "went on:1"
assert_contains "the step's stop names the die" "$(fake_comments_of 20)" "step minimal plan comment failed: "
assert_contains "a cd inside a step does not move the tick" "$out" "cwd-kept:yes"

# the step runner words a silent failure as today's stops did
fake_issue 76 open orch:spec orch:running; fake_claim_seed 76
sourced_orch_script 'autopilot_pickup_step 76 spec failure "step init failed" false' >/dev/null 2>&1
assert_contains "a step failing silently gets gh's no-reason wording after its detail" "$(fake_comments_of 76)" "Autopilot failed in the spec phase: step init failed: gh gave no reason"
fake_issue 78 open orch:spec orch:running; fake_claim_seed 78
sourced_orch_script 'autopilot_pickup_step 78 spec failure "step reading the recorded phase failed" autopilot_pickup_recorded /nonexistent' >/dev/null 2>&1
assert_contains "a failed recorded-phase read stops with the reader's reason after the detail" "$(fake_comments_of 78)" "Autopilot failed in the spec phase: step reading the recorded phase failed: "
assert_contains "and that reason is the reader's own message" "$(fake_comments_of 78)" "Could not open file /nonexistent"

# a failed mktemp is a temp-file failure, never gh's: the command is not run
fake_issue 79 open orch:spec orch:running; fake_claim_seed 79
ran_marker="$(mktemp -u)"
# (a file marks the first call: each runs in a $(...) subshell)
first_call_marker="$(mktemp -u)"
out="$(sourced_orch_script 'rc=0; ( mktemp() { [ -e "'"$first_call_marker"'" ] || { : >"'"$first_call_marker"'"; return 1; }; command mktemp "$@"; }; autopilot_pickup_step 79 spec failure "step init failed" touch "'"$ran_marker"'" ) || rc=$?; echo "rc=$rc"' 2>&1)"
assert_contains "a failed runner mktemp returns 1" "$out" "rc=1"
assert_contains "and stops the issue worded as a temp-file failure" "$(fake_comments_of 79)" "Autopilot failed in the spec phase: step init failed: could not create a temp file for the step's stderr"
assert_eq "releasing the claim" "$(fake_claim_held 79)" free
assert_eq "without running the command" "$([ -e "$ran_marker" ] && echo ran || echo not-run)" not-run
rm -f "$ran_marker" "$first_call_marker"

# stale claims of this host are failures; other hosts' are left alone
fake_issue 10 open ready-for-agent orch:spec orch:running
fake_claim_seed 10 "$(hostname)" "$(dead_pid)"
fake_issue 11 open ready-for-agent orch:spec orch:running
fake_claim_seed 11 otherhost "$(dead_pid)"
fake_issue 12 open ready-for-agent orch:spec orch:running
fake_claim_seed 12 "$(hostname)" "$(dead_pid)"
mkdir -p "$top/.orchestrator/autopilot/run"
live_record "$$" >"$top/.orchestrator/autopilot/run/12.pid"
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

# a live pid with another start time is stale in the run pidfile and in the tick
# record; a live tick record keeps the claim; no file at all is gone
rundir="$top/.orchestrator/autopilot/run"
fake_issue 16 open ready-for-agent orch:spec orch:running
fake_claim_seed 16 "$(hostname)" "$$"
printf '%s 1\n' "$$" >"$rundir/16.pid"
printf '%s 1\n' "$$" >"$rundir/16.tick"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a run pidfile with another start time releases the claim" "$(fake_claim_held 16)" free
assert_eq "and removes both files" "$(find "$rundir" -name '16.*' | wc -l | tr -d ' ')" 0
fake_issue 17 open ready-for-agent orch:spec orch:running
fake_claim_seed 17 "$(hostname)" "$$"
printf '%s 1\n' "$$" >"$rundir/17.tick"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a tick record with another start time releases the claim" "$(fake_claim_held 17)" free
fake_issue 18 open ready-for-agent orch:spec orch:running
fake_claim_seed 18 "$(hostname)" "$$"
live_record "$$" >"$rundir/18.tick"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a live tick record keeps the claim" "$(fake_claim_held 18)" held
rm -f "$rundir/18.tick"; fake_claim_release 18
fake_issue 19 open ready-for-agent orch:spec orch:running
fake_claim_seed 19 "$(hostname)" "$$"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a claim with neither file is released" "$(fake_claim_held 19)" free

# a tick writes its own record to run/<issue>.tick, over an older one
printf 'old\n' >"$rundir/20.tick"
sourced_orch autopilot_tick_record 20 >/dev/null 2>&1
[[ "$(cat "$rundir/20.tick")" =~ ^[0-9]+\ [^\ ]+$ ]] && shape=record || shape=other
assert_eq "the tick record is a pid and start time, over an older one" "$shape" record
rm -f "$rundir/20.tick"

# the claim identity: with ORCH_HOST_ID set, only claims of that id are this
# host's
fake_issue 14 open ready-for-agent orch:spec orch:running
fake_claim_seed 14 autopilot-abc123 "$(dead_pid)"
fake_issue 15 open ready-for-agent orch:spec orch:running
fake_claim_seed 15 "$(hostname)" "$(dead_pid)"
ORCH_HOST_ID=autopilot-abc123 "$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a claim of ORCH_HOST_ID is cleaned" "$(fake_claim_held 14)" free
assert_eq "the hostname's claim is then another identity's, left alone" "$(fake_claim_held 15)" held
fake_claim_release 15

# a stop that dies partway dies with the claim ref's reason; Standing owns the
# writes that landed and the held claim
fake_issue 13 open ready-for-agent orch:spec orch:running
fake_claim_seed 13 "$(hostname)" "$(dead_pid)"
fake_fail adapter_claim_delete "HTTP 500"
out="$("$ORCH" autopilot tick 2>&1)"; st=$?
assert_status "stale-claim cleanup with a failed claim delete dies" "$st" 1
assert_contains "naming the claim ref" "$out" "delete the claim ref"
fake_unfail
fake_claim_seed 13 otherhost
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
rm -f "$top/.orchestrator/autopilot/run/7.pid"; fake_claim_release 7
# the run removes the tick's record once its own pidfile is written
fake_issue 7 open ready-for-agent orch:spec orch:running
fake_claim_seed 7 "$(hostname)" 111
live_record "$$" >"$top/.orchestrator/autopilot/run/7.tick"
tick_seen_launcher="$(mktemp)"
printf '#!/bin/sh\nrm -f "%s/claims/7"\nexit 0\n' "$ORCH_GH_FAKE_STORE" >"$tick_seen_launcher"
chmod +x "$tick_seen_launcher"
ORCH_AUTOPILOT_LAUNCHER="$tick_seen_launcher" "$ORCH" autopilot run 7 >/dev/null 2>&1
assert_eq "autopilot run removes run/<issue>.tick" "$([ -e "$top/.orchestrator/autopilot/run/7.tick" ] && echo there || echo gone)" gone
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
live_record "$$" >"$pidfile"
out="$("$ORCH" autopilot watch 2>&1)"; st=$?
assert_status "a second watch of the same clone is refused" "$st" 1
assert_contains "naming the live one" "$out" "already running"
assert_eq "and leaves the live one's pidfile" "$(cat "$pidfile")" "$(live_record "$$")"

# a live pid with another start time (a container restart's pid 1) is stale, and
# so is a bare pid
printf '%s 1\n' "$$" >"$pidfile"
out="$(sourced_orch autopilot_record_alive "$(cat "$pidfile")" 2>&1)"; st=$?
assert_status "a live pid with a different start time is not alive" "$st" 1
out="$(sourced_orch autopilot_record_alive "$$" 2>&1)"; st=$?
assert_status "a bare-pid line is stale" "$st" 1

# a pidfile naming a live pid with another start time does not block a watch
printf '%s 1\n' "$$" >"$pidfile"
"$ORCH" autopilot watch --every 1 >/dev/null 2>&1 &
other_watch=$!
for _ in $(seq 1 60); do [ "$(cat "$pidfile" 2>/dev/null)" = "$(live_record "$other_watch")" ] && break; sleep 0.1; done
assert_eq "a pidfile with another start time is replaced" "$(cat "$pidfile" 2>/dev/null)" "$(live_record "$other_watch")"
kill -TERM "$other_watch"; wait "$other_watch" 2>/dev/null

# one watch, started over a dead pidfile while every tick fails
printf '%s\n' "$(dead_pid)" >"$pidfile"
fake_fail adapter_label_upsert "HTTP 500 label"
"$ORCH" autopilot watch --every 1 >/dev/null 2>"$watch_log" &
watch_pid=$!
for _ in $(seq 1 60); do [ "$(cat "$pidfile" 2>/dev/null)" = "$(live_record "$watch_pid")" ] && [ "$(grep -c 'the tick failed' "$watch_log")" -ge 2 ] && break; sleep 0.1; done
assert_eq "a dead pidfile is replaced" "$(cat "$pidfile" 2>/dev/null)" "$(live_record "$watch_pid")"
kill -0 "$watch_pid" 2>/dev/null; st=$?
assert_status "watch survives a failed tick" "$st" 0
assert_contains "reporting it with its exit status" "$(cat "$watch_log")" "the tick failed (exit 1)"
assert_eq "and ticking again after it" "$([ "$(grep -c 'the tick failed' "$watch_log")" -ge 2 ] && echo yes)" "yes"
kill -TERM "$watch_pid"; wait "$watch_pid" 2>/dev/null
assert_eq "an interrupted watch removes its pidfile" "$(on_disk "$pidfile")" absent
fake_unfail

# TERM mid-tick: the tick is held in the gh fake; the watch removes its pidfile
# and TERMs the tick at once, then exits 0 once the tick has gone
printf '%s\n' "$(dead_pid)" >"$pidfile"
mkdir -p "$ORCH_GH_FAKE_STORE/hold"
mkfifo "$ORCH_GH_FAKE_STORE/hold/adapter_label_upsert"
rm -f "$ORCH_GH_FAKE_STORE/held"
"$ORCH" autopilot watch --every 1 >/dev/null 2>&1 &
watch_pid=$!
for _ in $(seq 1 100); do [ -s "$ORCH_GH_FAKE_STORE/held" ] && break; sleep 0.1; done
tick_pid="$(cat "$ORCH_GH_FAKE_STORE/held" 2>/dev/null)"
assert_eq "the held tick's pid is known" "$([[ "$tick_pid" =~ ^[0-9]+$ ]] && echo yes)" yes
kill -TERM "$watch_pid"
wait "$watch_pid" 2>/dev/null; st=$?
assert_status "a watch termed mid-tick exits 0" "$st" 0
assert_eq "and removes its pidfile" "$(on_disk "$pidfile")" absent
kill -0 "${tick_pid:-none}" 2>/dev/null; st=$?
assert_status "and the tick it was running is gone" "$st" 1
printf 'x\n' >"$ORCH_GH_FAKE_STORE/hold/adapter_label_upsert" &
sleep 0.2; kill $! 2>/dev/null
rm -rf "$ORCH_GH_FAKE_STORE/hold"

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
fake_issue 7 open ready-for-agent orch:spec; fake_issue_title 7 "Limit 7"
reset_epoch="$(( $(date +%s) + 7200 ))"
reset_iso="$(iso_of "$reset_epoch")"
ndjson_with "Claude AI usage limit reached|$reset_epoch" >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the session that hit the limit starts one session" "$(tick_calls)" "1"
assert_contains "its failure comment names the usage limit" "$(fake_comments_of 7)" "usage limit"
assert_contains "and the reset time" "$(fake_comments_of 7)" "$reset_iso"
fake_issue 8 open ready-for-agent orch:spec; fake_issue_title 8 "Limit 8"
assert_eq "it writes the limit file" "$(cat "$top/.orchestrator/autopilot/limit")" "$reset_iso"
assert_eq "and the issue is limited, not needs-human" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
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
assert_eq "and pickup resumes with the limited issue first, then the next" "$(tick_calls)" "3"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: the rate limit event -------------------------------------
# The session's log is NDJSON with plain-text lines mixed in; the limit file's
# reset comes from the last rate_limit_event (#1463).
echo
echo "autopilot tick rate limit event"
tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open ready-for-agent orch:spec; fake_issue_title 7 "Event 7"
limit_file="$top/.orchestrator/autopilot/limit"
printf '7\n' >"$launcher_dir/release"; : >"$launcher_dir/out"
"$ORCH" autopilot tick >/dev/null 2>&1   # makes the side checkout
rm -f "$launcher_dir/release" "$launcher_dir/calls" "$limit_file"
# event_session <exit>: a fresh run of issue 7 over the launcher's canned log,
# the limit file removed unless a test made it a directory.
event_session() {
  [ -d "$limit_file" ] || rm -f "$limit_file"
  fake_issue 7 open ready-for-agent orch:spec orch:running
  fake_claim_seed 7
  printf '%s\n' "$1" >"$launcher_dir/exit"
  out="$("$ORCH" autopilot run 7 2>&1)"; st=$?
}
now_epoch="$(date +%s)"
r1=$((now_epoch + 3600)); r2=$((now_epoch + 7200)); r3=$((now_epoch + 90000))

# a session that released its claim is left alone whatever its log and exit code
printf '7\n' >"$launcher_dir/release"
rl_event rejected 1 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 1
assert_eq "a rejecting event of a released claim marks no issue" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_not_contains "and posts no limit stop comment" "$(fake_comments_of 7)" "usage limit"
rm -f "$launcher_dir/release"

# a failed write on one session with both pauses is noted once
rm -f "$limit_file"; mkdir "$limit_file"
rl_event rejected 1 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 1
assert_eq "both pauses with an unwritable limit file give one note" "$(grep -c "could not write the limit file" <<<"$out")" "1"
rmdir "$limit_file"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: limited issues -------------------------------------------
# A usage-limit stop is waited out as orch:limited, at most twice in a row per
# phase (#1463).
echo
echo "autopilot tick limited issues"
tick_fixture
LABELS_HUMAN="needs-human orch:spec ready-for-agent "
top="$(git rev-parse --show-toplevel)"
limit_file="$top/.orchestrator/autopilot/limit"
lim_reset=$(( $(date +%s) + 3600 ))
lim_iso="$(iso_of "$lim_reset")"
# lim_fresh: issue #7 with no comments and a running spec phase, and no limit
# file.
lim_fresh() {
  fake_comments_clear 7; rm -f "$limit_file"
  fake_issue_relabel 7 orch:spec ready-for-agent orch:running
}
# limit_run <issue> [<out>]: a run of <issue>'s session, its claim held by a
# dead process, that ends on the limit: the launcher prints <out>, by default
# a rejecting event that resets at $lim_reset.
limit_run() {
  local out="${2:-$(rl_event rejected 1 "$lim_reset" allowed 0.2 "$lim_reset")}"
  fake_claim_seed "$1" "$(hostname)" "$(dead_pid)"
  printf '%s\n' "$out" >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"
  "$ORCH" autopilot run "$1" 2>&1
}
fake_issue 7 open ready-for-agent orch:spec; fake_issue_title 7 "Lim 7"
printf '7\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1   # makes the side checkout
rm -f "$launcher_dir/release" "$launcher_dir/calls"
fake_issue_relabel 7 orch:spec ready-for-agent orch:running
limit_run 7 >/dev/null
assert_eq "a first limit stop leaves orch:limited, not needs-human" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
assert_eq "and releases the claim" "$(fake_claim_held 7)" free
assert_eq "its comment opens with the marker" "$(fake_last_comment_of 7 | head -n 1)" "<!-- orch:limited spec -->"
assert_contains "gives the reset time" "$(fake_comments_of 7)" "$lim_iso"
assert_eq "and writes the limit file" "$(cat "$limit_file")" "$lim_iso"
# a session that ends on no limit is a failure
lim_fresh
limit_run 7 "$(ndjson_with 'iteration limit reached')" >/dev/null
assert_eq "a session that hit no limit ends with needs-human" "$(fake_labels_of 7)" "$LABELS_HUMAN"
assert_eq "and writes no limit file" "$(on_disk "$limit_file")" absent

# a failed label edit or comment leaves the claim held; the next tick's cleanup
# sends the issue to needs-human
for op in adapter_issue_relabel adapter_issue_comment; do
  lim_fresh
  fake_fail "$op" "HTTP 500"
  out="$(limit_run 7)"; st=$?
  fake_unfail
  assert_status "a limit stop whose $op fails dies" "$st" 1
  assert_eq "$op: the claim is still held" "$(fake_claim_held 7)" held
  rm -f "$limit_file"
  "$ORCH" autopilot tick >/dev/null 2>&1
  assert_eq "$op: the next tick ends with needs-human and no orch:limited" "$(fake_labels_of 7)" "$LABELS_HUMAN"
done

# pickup: no session under the pause; after it, oldest first under the cap, and
# orch:limited removed after the claim is won
fake_comments_clear 7
fake_issue 7 open ready-for-agent orch:spec orch:limited
fake_issue 6 open ready-for-agent orch:spec orch:limited
fake_issue 5 open ready-for-agent orch:spec; fake_issue_title 5 "Lim 5"; fake_issue_title 6 "Lim 6"
rm -f "$launcher_dir/calls"
printf '%s\n' "$lim_iso" >"$limit_file"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "under the limit pause no session starts" "$(tick_calls)" "0"
assert_eq "and the limited issue keeps its label" "$(fake_labels_of 6)" "orch:limited orch:spec ready-for-agent "
printf '2020-01-01T00:00:00Z\n' >"$limit_file"
printf '5 6 7\n' >"$launcher_dir/release"; printf '0\n' >"$launcher_dir/exit"; : >"$launcher_dir/out"
git config orchestrator.autopilot.cap 2
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "after the pause two sessions start, oldest first" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "lim-5 lim-6 "
assert_contains "the limited issue's session sees orch:running and no orch:limited" "$(grep '^labels:6:' "$launcher_dir/calls" | tail -1)" "labels:6:orch:running orch:spec ready-for-agent "
assert_eq "the one over the cap keeps orch:limited" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
git config --unset orchestrator.autopilot.cap
# a lost claim leaves orch:limited in place
fake_issue 6 open ready-for-agent orch:spec orch:limited
fake_claim_seed 6 otherhost 1
rm -f "$launcher_dir/calls"; fake_issue 7 open ready-for-agent orch:spec
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a lost claim leaves orch:limited in place" "$(fake_labels_of 6)" "orch:limited orch:spec ready-for-agent "
fake_claim_release 6
# a failed removal is a failed step
fake_issue 6 open ready-for-agent orch:spec orch:limited
fake_fail_times adapter_issue_relabel 1 "HTTP 500"
rm -f "$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
fake_unfail
assert_eq "a failed orch:limited removal ends with needs-human and no orch:limited" "$(fake_labels_of 6)" "$LABELS_HUMAN"
assert_eq "and starts no session for it" "$(tick_calls)" "0"

# an early step failing on a limited issue ends with needs-human only
fake_issue 9 open orch:spec orch:limited
fake_issue_title 9 "Lim 9 needs ready"
rm -f "$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a failed init on a limited issue ends with needs-human and no orch:limited" "$(fake_labels_of 9)" "needs-human orch:spec "
assert_contains "naming the init step" "$(fake_comments_of 9)" "step init failed"

# a limit file in another clone's autopilot directory starts no pause
other_clone="$(mktemp -d)"
git clone -q "$top" "$other_clone/clone" >/dev/null 2>&1
mkdir -p "$other_clone/clone/.orchestrator/autopilot"
printf '%s\n' "$lim_iso" >"$other_clone/clone/.orchestrator/autopilot/limit"
rm -f "$limit_file" "$launcher_dir/calls"
fake_issue 8 open ready-for-agent orch:spec; fake_issue_title 8 "Lim 8"
printf '8\n' >"$launcher_dir/release"; printf '0\n' >"$launcher_dir/exit"; : >"$launcher_dir/out"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_contains "another clone's limit file starts no pause" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "lim-8"
rm -rf "$other_clone"

# autopilot questions does not list a limited issue
fake_issue 30 open ready-for-agent orch:spec orch:limited
assert_not_contains "autopilot questions lists no limited issue" "$("$ORCH" autopilot questions 2>&1)" "30"
fake_issue 31 open needs-human orch:spec
fake_fail adapter_issue_state_labels "HTTP 502"
out="$("$ORCH" autopilot questions 2>&1)"; st=$?
assert_eq "questions failing on a label read dies in one line naming gh and the reason" "$(printf "%s\n" "$out" | grep -c .)|${out#orch: gh could not read the labels of issue #*: }" "1|HTTP 502"
fake_unfail
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot questions, reply and resume ------------------------------------
# The three verbs behind /orchestrator:questions: they hold no flow state, so
# the repo here is a bare checkout with an origin and no state.json.
echo
echo "autopilot questions, reply and resume"
new_repo >/dev/null
fake_github
# question_of <phase>: a question comment body of that phase.
question_of() { printf '%s\n@o\n\n1. Keep it? Recommended: yes\n' "$(marker_of question "$1")"; }
url_of() { printf 'https://github.com/o/r/issues/%s#issuecomment-%s' "$1" "$2"; }

assert_eq "no state.json exists in the checkout" "$(on_disk .orchestrator/state.json)" absent
out="$("$ORCH" autopilot questions 2>&1)"; st=$?
assert_status "nothing labelled needs-human exits 0" "$st" 0
assert_eq "saying nothing is pending, the label text included" "$out" "nothing pending: no open needs-human issue of an autopilot flow"
assert_eq "in one line" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "1"

# a pending question
fake_issue 11 open needs-human orch:spec
fake_comment 11 o 2026-01-01T00:00:00Z "$(question_of spec)"
# several earlier questions: only the newest counts, across phases
fake_issue 12 open needs-human orch:review
fake_comment 12 o 2026-01-01T00:00:00Z "$(question_of spec)"
fake_comment 12 o 2026-01-02T00:00:00Z "$(question_of implement)"
fake_comment 12 o 2026-01-03T00:00:00Z "$(question_of review)"
# replied: a comment follows the question
fake_issue 13 open needs-human orch:implement
fake_comment 13 o 2026-01-01T00:00:00Z "$(question_of implement)"
fake_comment 13 h 2026-01-02T00:00:00Z "1: A"
# a stop with the comment's phase differing from the label
fake_issue 14 open needs-human orch:review
sourced_orch standing_stop 14 failure implement "step x failed" >/dev/null 2>&1
# neither comment: the phase comes from the earliest phase label
fake_issue 15 open needs-human orch:review orch:implement
# a question then a stop, and a stop then a question
fake_issue 16 open needs-human orch:spec
fake_comment 16 o 2026-01-01T00:00:00Z "$(question_of spec)"
sourced_orch standing_stop 16 refusal spec "no plan" >/dev/null 2>&1
fake_issue 17 open needs-human orch:spec
sourced_orch standing_stop 17 refusal spec "no plan" >/dev/null 2>&1
fake_comment 17 o 2026-01-09T00:00:00Z "$(question_of spec)"
# a marked stop comment
fake_issue 26 open needs-human orch:spec
fake_comment 26 o 2026-01-01T00:00:00Z "$(marker_of failure review)
detail"
# left out: no phase label, orch:done, closed, and not needs-human
fake_issue 18 open needs-human ready-for-agent
fake_issue 19 open needs-human orch:done
fake_issue 20 closed needs-human orch:spec
fake_issue 21 open orch:spec
fake_comment 21 o 2026-01-01T00:00:00Z "$(question_of spec)"
out="$("$ORCH" autopilot questions 2>&1)"; st=$?
assert_status "listing succeeds" "$st" 0
tab=$'\t'
assert_eq "a pending question" "$(grep "^11$tab" <<<"$out")" "11${tab}question${tab}spec${tab}$(url_of 11 1)"
assert_eq "the newest of several questions decides, in its own phase" "$(grep "^12$tab" <<<"$out")" "12${tab}question${tab}review${tab}$(url_of 12 3)"
assert_eq "a question with a reply is replied" "$(grep "^13$tab" <<<"$out")" "13${tab}replied${tab}implement${tab}$(url_of 13 1)"
assert_eq "a stop comment's phase wins over the label's" "$(grep "^14$tab" <<<"$out")" "14${tab}stop${tab}implement${tab}$(url_of 14 1)"
assert_eq "no comment at all is a stop in the earliest labelled phase, URL empty" "$(grep "^15$tab" <<<"$out")" "15${tab}stop${tab}implement${tab}"
assert_eq "a stop after a question is a stop" "$(grep "^16$tab" <<<"$out")" "16${tab}stop${tab}spec${tab}$(url_of 16 2)"
assert_eq "a question after a stop is a question" "$(grep "^17$tab" <<<"$out")" "17${tab}question${tab}spec${tab}$(url_of 17 2)"
assert_eq "a marked failure comment is a stop, in its own phase" "$(grep "^26$tab" <<<"$out")" "26${tab}stop${tab}review${tab}$(url_of 26 1)"
assert_eq "an issue with no phase label, orch:done, closed or not needs-human is left out" \
  "$(cut -f1 <<<"$out" | tr "\n" " ")" "11 12 13 14 15 16 17 26 "
for n in 11 12 13 14 15 16 17 18 19 20 21 26; do fake_issue_drop "$n"; done
fake_issue 11 open needs-human orch:spec
fake_issue 12 open needs-human orch:spec
fake_fail adapter_issue_comments_json "$GH_502"
out="$("$ORCH" autopilot questions 2>/dev/null)"; st=$?
assert_status "an adapter read failure dies" "$st" 1
assert_eq "listing nothing" "$out" ""
fake_unfail
fake_fail adapter_issues_labelled "$GH_502"
"$ORCH" autopilot questions >/dev/null 2>&1; st=$?
assert_status "a failed listing dies" "$st" 1
fake_unfail

# usage
for v in "questions x" "reply 11" "reply" "resume" "resume 11 x"; do
  out="$("$ORCH" autopilot $v 2>&1)"; st=$?
  assert_status "autopilot $v dies" "$st" 1
  assert_contains "with its usage" "$out" "orch: usage: orch.sh autopilot ${v%% *}"
done

# resume
fake_issue 30 open needs-human orch:spec
"$ORCH" autopilot resume 30 >/dev/null 2>&1; st=$?
assert_status "resume succeeds" "$st" 0
assert_eq "removing only needs-human" "$(fake_labels_of 30)" "orch:spec "
out="$("$ORCH" autopilot resume 30 2>&1)"; st=$?
assert_status "resume without the label dies" "$st" 1
assert_contains "naming needs-human" "$out" "needs-human"

# no repo to work on: the remedy reaches the caller on the read path too
savepath="$PATH"; gh_fixture; PATH="$savepath"
norepo_plan="$(mktemp -d)/p.md"; printf 'plan\n' >"$norepo_plan"
for norepo_args in "resume 5" "start 5 $norepo_plan"; do
  # shellcheck disable=SC2086
  out="$(orch_no_repo autopilot $norepo_args 2>&1)"; st=$?
  assert_status "autopilot $norepo_args with no repo fails" "$st" 1
  assert_contains "autopilot $norepo_args with no repo prints the remedy" "$out" "$repo_remedy"
done
fake_issue 31 closed needs-human orch:spec
out="$("$ORCH" autopilot resume 31 2>&1)"; st=$?
assert_status "resume on a closed issue dies" "$st" 1
assert_contains "saying closed" "$out" "closed"
assert_eq "leaving its labels" "$(fake_labels_of 31)" "needs-human orch:spec "
out="$("$ORCH" autopilot resume 999 2>&1)"; st=$?
assert_status "resume on a missing issue dies" "$st" 1
fake_issue 32 open needs-human orch:spec
fake_fail adapter_issue_relabel "HTTP 500"
out="$("$ORCH" autopilot resume 32 2>&1)"; st=$?
assert_status "resume on an adapter failure dies" "$st" 1
assert_eq "with its own wording and gh's reason" "$out" "orch: gh could not remove needs-human from issue #32: HTTP 500"
fake_unfail
fake_issue 33 open needs-human orch:spec
fake_fail adapter_issue_state_labels "HTTP 502"
out="$("$ORCH" autopilot resume 33 2>&1)"; st=$?
assert_status "resume on a failed issue read dies" "$st" 1
assert_eq "in one line naming gh and the reason" "$(printf '%s\n' "$out" | grep -c .)|${out#orch: gh could not read issue #33: }" "1|HTTP 502"
fake_unfail

# reply
r="$(mktemp)"; printf '1: Yes, keep it\n' >"$r"
fake_issue 40 open needs-human orch:spec
fake_comment 40 o 2026-01-01T00:00:00Z "$(question_of spec)"
"$ORCH" autopilot reply 40 "$r" >/dev/null 2>&1; st=$?
assert_status "reply succeeds" "$st" 0
assert_eq "posting the file as a comment" "$(fake_comments_of 40 | tail -1)" "1: Yes, keep it"
assert_eq "and removing needs-human" "$(fake_labels_of 40)" "orch:spec "
# posts before removing the label: a failed removal leaves the comment
fake_issue 41 open needs-human orch:spec
fake_comment 41 o 2026-01-01T00:00:00Z "$(question_of spec)"
fake_fail adapter_issue_relabel "HTTP 500"
out="$("$ORCH" autopilot reply 41 "$r" 2>&1)"; st=$?
assert_status "a failed label removal dies" "$st" 1
assert_eq "saying the comment landed, with the reason" "$out" "orch: the reply comment landed on issue #41, but needs-human could not be removed: HTTP 500"
assert_eq "the comment is there" "$(fake_comments_of 41 | tail -1)" "1: Yes, keep it"
fake_unfail
# a failed post leaves the label
fake_issue 42 open needs-human orch:spec
fake_comment 42 o 2026-01-01T00:00:00Z "$(question_of spec)"
fake_fail adapter_issue_comment "HTTP 500"
"$ORCH" autopilot reply 42 "$r" >/dev/null 2>&1; st=$?
assert_status "a failed post dies" "$st" 1
assert_eq "leaving the label" "$(fake_labels_of 42)" "needs-human orch:spec "
fake_unfail
# refusals post nothing
fake_issue 43 open orch:spec
fake_comment 43 o 2026-01-01T00:00:00Z "$(question_of spec)"
out="$("$ORCH" autopilot reply 43 "$r" 2>&1)"; st=$?
assert_status "reply without needs-human is refused" "$st" 1
assert_contains "naming it" "$out" "needs-human"
assert_eq "posting nothing" "$(fake_comments_of 43 | grep -c 'Yes, keep')" "0"
fake_issue 44 open needs-human orch:spec
fake_comment 44 o 2026-01-01T00:00:00Z "$(question_of spec)"
fake_comment 44 h 2026-01-02T00:00:00Z "1: A"
out="$("$ORCH" autopilot reply 44 "$r" 2>&1)"; st=$?
assert_status "reply after a comment followed the question is refused" "$st" 1
assert_eq "posting nothing" "$(fake_comments_of 44 | grep -c 'Yes, keep')" "0"
assert_eq "and keeping the label" "$(fake_labels_of 44)" "needs-human orch:spec "
fake_issue 45 open needs-human orch:spec
out="$("$ORCH" autopilot reply 45 "$r" 2>&1)"; st=$?
assert_status "reply with no question comment is refused" "$st" 1
fake_issue 46 open needs-human orch:spec
fake_comment 46 o 2026-01-01T00:00:00Z "$(question_of spec)"
out="$("$ORCH" autopilot reply 46 "$TMPDIR/none-$$" 2>&1)"; st=$?
assert_status "a missing file is refused" "$st" 1
: >"$r.empty"
out="$("$ORCH" autopilot reply 46 "$r.empty" 2>&1)"; st=$?
assert_status "an empty file is refused" "$st" 1
assert_eq "posting nothing" "$(fake_comments_of 46 | wc -l | tr -d ' ')" "3"
assert_eq "keeping the label" "$(fake_labels_of 46)" "needs-human orch:spec "

restore_suite_env

# --- autopilot_phase_arg refuses two adjacent phases (#1546) ------------------
echo
echo "autopilot phase argument"
new_repo >/dev/null
out="$(sourced_orch autopilot_phase_arg "spec implement" 2>&1)"; st=$?
assert_status "autopilot_phase_arg refuses two adjacent phases" "$st" 1
assert_eq "with its not-a-flow-phase message" "$out" \
  "orch: not a flow phase: spec implement (want spec|implement|review|done)"

# --- autopilot start-time reader ----------------------------------------------
echo
echo "autopilot start time"
new_repo >/dev/null
a="$(sourced_orch autopilot_proc_start "$$")"; b="$(sourced_orch autopilot_proc_start "$$")"
assert_eq "the /proc branch gives the same start time twice" "$a" "$b"
assert_eq "as one whitespace-free token" "$(printf '%s' "$a" | tr -d '[:space:]')" "$a"
empty_proc="$(mktemp -d)"
if command -v ps >/dev/null 2>&1; then
  a="$(ORCH_PROC_DIR="$empty_proc" sourced_orch autopilot_proc_start "$$")"; b="$(ORCH_PROC_DIR="$empty_proc" sourced_orch autopilot_proc_start "$$")"
  assert_eq "the ps branch gives the same start time twice" "$a" "$b"
  assert_eq "and one whitespace-free token" "$(printf '%s' "$a" | tr -d '[:space:]')" "$a"
  assert_eq "which is not empty" "$([ -n "$a" ] && echo yes)" yes
else
  skip "the ps branch gives the same start time twice" "no ps on this machine (the autopilot image ships no procps)"
fi
out="$(sourced_orch autopilot_pid_write "$(dead_pid)" "$empty_proc/f" 2>&1)"; st=$?
assert_status "writing a record for an unreadable process fails" "$st" 1
assert_contains "naming the pid" "$out" "orch: could not read the start time of pid"

# --- autopilot pause store ----------------------------------------------------
echo
echo "autopilot pause store"
tick_fixture
pause_main="$(git rev-parse --show-toplevel)"
future_iso="$(iso_of "$(( $(date +%s) + 7200 ))")"
mkdir -p "$pause_main/.orchestrator/autopilot"; pause_file="$pause_main/.orchestrator/autopilot/limit"
out="$(sourced_orch autopilot_pause_until "$pause_main" 2>&1)"; st=$?
assert_status "no limit file: not paused" "$st" 1
assert_eq "and nothing printed" "$out" ""
printf '%s\n' "$future_iso" >"$pause_file"
out="$(sourced_orch autopilot_pause_until "$pause_main" 2>&1)"; st=$?
assert_status "a future time pauses" "$st" 0
assert_contains "and the note names it" "$out" "usage limit: no issue is picked up until $future_iso"
printf '2020-01-01T00:00:00Z\n' >"$pause_file"
sourced_orch autopilot_pause_until "$pause_main" >/dev/null 2>&1; st=$?
assert_status "a passed time does not pause" "$st" 1
assert_eq "and removes the file" "$(on_disk "$pause_file")" absent
printf 'garbage\n' >"$pause_file"
sourced_orch autopilot_pause_until "$pause_main" >/dev/null 2>&1; st=$?
assert_status "an unparsable time does not pause" "$st" 1
assert_eq "and removes the file too" "$(on_disk "$pause_file")" absent

# --- autopilot session end ----------------------------------------------------
# autopilot_session_end, called directly over a log file, a claim in the gh fake
# and the clone's limit file: every case asserts what it leaves behind (#1818).
echo
echo "autopilot session end"
tick_fixture
top="$(git rev-parse --show-toplevel)"
limit_file="$top/.orchestrator/autopilot/limit"
fake_issue 7 open ready-for-agent orch:spec; fake_issue_title 7 "End 7"
se_dir="$(mktemp -d)"; se_log="$se_dir/session.log"
se_claim_fields="$(hostname)"$'\t'"1"$'\t'"spec"$'\t'"2026-01-01T00:00:00Z"
LABELS_HUMAN="needs-human orch:spec ready-for-agent "
LABELS_LIMITED="orch:limited orch:spec ready-for-agent "
# se_fresh: issue 7 running its spec phase, no comments, its claim held, no
# limit file.
se_fresh() {
  fake_comments_clear 7
  fake_issue_relabel 7 orch:spec ready-for-agent orch:running
  fake_claim_seed 7
  rm -rf "$limit_file"; mkdir -p "$top/.orchestrator/autopilot"
}
# se_end <rc> [<mine>]: Session end over $se_log for issue 7's spec phase; its
# stderr in $se_out, its status in $se_st.
se_end() {
  se_out="$(sourced_orch_script 'autopilot_session_end 7 spec "$1" "$2" "$3"' "$se_log" "$1" "${2-}" 2>&1)"; se_st=$?
}
# se_kind: what the issue was left with: limited, failure (needs-human) or
# released (neither).
se_kind() {
  case "$(fake_labels_of 7)" in
    "$LABELS_LIMITED") echo limited ;;
    "$LABELS_HUMAN") echo failure ;;
    *) echo released ;;
  esac
}
# se_limit: the limit file's contents, absent when there is none.
se_limit() { if [ -f "$limit_file" ]; then cat "$limit_file"; else echo absent; fi; }
# se_check <label> <kind> <limit file>: a fresh held session over $se_log, exit
# code 1, left the issue as <kind> and the limit file as given.
se_check() {
  se_fresh; se_end 1
  assert_eq "$1" "$(se_kind)|$(se_limit)" "$2|$3"
}
# se_check_hour_fallback <label>: a fresh held session over $se_log gave no
# reset time: a limit stop with the limit pause one hour on, its comment naming
# that fallback pause and no reset.
se_check_hour_fallback() {
  local before after limit_epoch
  before="$(date +%s)"; se_fresh; se_end 1; after="$(date +%s)"
  read -r limit_epoch _ < <(local_fields "$(se_limit)")
  assert_eq "$1: a limit stop" "$(se_kind)" limited
  assert_eq "$1: with a limit pause one hour on" "$([ "$limit_epoch" -ge $((before + 3600)) ] && [ "$limit_epoch" -le $((after + 3600)) ] && echo yes)" yes
  assert_contains "$1: its comment names the fallback pause" "$(fake_last_comment_of 7)" "it gave no reset time, so the watcher falls back to a one-hour limit pause, until $(se_limit)."
  assert_not_contains "$1: and no reset" "$(fake_last_comment_of 7)" "resets"
}
now_epoch="$(date +%s)"
r1=$((now_epoch + 3600)); r2=$((now_epoch + 7200)); r3=$((now_epoch + 90000))
i1="$(iso_of "$r1")"; i2="$(iso_of "$r2")"; i3="$(iso_of "$r3")"

# wordings
ndjson_with "Claude AI usage limit reached|$r2" >"$se_log"
se_check "\"usage limit reached|<epoch>\" is a limit stop at that reset" limited "$i2"
assert_contains "its comment names the reset" "$(fake_last_comment_of 7)" "which resets $i2"
for wording in "Claude Opus usage limit reached" "5-hour limit reached" "Weekly limit reached"; do
  ndjson_with "$wording" >"$se_log"
  se_check_hour_fallback "\"$wording\""
done
for wording in "iteration limit reached" "API rate limit reached, retrying"; do
  ndjson_with "$wording" >"$se_log"
  se_check "\"$wording\" is a failure, with no limit file" failure absent
done
assert_contains "the failure comment names the exit code and the log" "$(fake_last_comment_of 7)" "the session exited with code 1; log: $se_log"

# resets <time>
ndjson_with '5-hour limit reached ∙ resets 3pm' >"$se_log"
se_fresh; se_end 1
read -r reset_epoch reset_hour _ < <(local_fields "$(se_limit)")
assert_eq "\"resets 3pm\" is a limit stop" "$(se_kind)" limited
assert_eq "the reset is 15:00 local" "$reset_hour" 15
assert_eq "within the next day" "$([ "$reset_epoch" -gt "$(date +%s)" ] && [ "$reset_epoch" -le "$(( $(date +%s) + 86400 + 3600 ))" ] && echo yes)" yes
assert_contains "the comment names the same reset" "$(fake_last_comment_of 7)" "which resets $(se_limit)"
ndjson_with 'Weekly limit reached ∙ resets Mon 9am' >"$se_log"
se_fresh; se_end 1
read -r reset_epoch reset_hour reset_day < <(local_fields "$(se_limit)")
assert_eq "\"resets Mon 9am\" is a Monday at 09:00 local" "$reset_day $reset_hour" "Mon 09"
assert_eq "within the next week" "$([ "$reset_epoch" -gt "$(date +%s)" ] && [ "$reset_epoch" -le "$(( $(date +%s) + 7 * 86400 + 3600 ))" ] && echo yes)" yes

# where the text is found
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Claude AI usage limit reached"}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":"Weekly limit reached"}]}}' >"$se_log"
se_check "limit wording only in assistant text or tool results is a failure" failure absent
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' \
  "{\"type\":\"result\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$r2\"}" >"$se_log"
se_check "a limit message in the last result event is a limit stop" limited "$i2"
printf '%s\n' "{\"type\":\"result\",\"result\":\"all done\"}" "plain Claude AI usage limit reached|$r2" >"$se_log"
se_check "a plain-text line is read with the result text" limited "$i2"

# rate-limit events
{ echo 'stderr noise line'; rl_event rejected 1 "$r1" allowed_warning 0.8 "$r3"; echo 'another note'; } >"$se_log"
se_check "a rejecting five-hour window gives its reset" limited "$i1"
rl_event rejected 1 "$r1" rejected 0.8 "$r3" >"$se_log"
se_check "the latest of several rejecting windows decides" limited "$i3"
{ rl_event rejected 1 "$r1" allowed 0.8 "$r3"; rl_event allowed 0.5 "$r1" allowed 0.8 "$r3"; } >"$se_log"
se_check "a rejecting event followed by an allowed one is a failure" failure absent
rl_event rejected 1 null allowed 0.2 null >"$se_log"
se_check_hour_fallback "a rejecting event with no resetsAt"

# early pause, whatever the outcome
rl_event allowed 0.9 "$r1" allowed 0.2 "$r3" >"$se_log"
se_check "utilization 0.9 writes the early pause on a failure" failure "$i1"
se_fresh; fake_claim_release 7; se_end 0 "$se_claim_fields"
assert_eq "and on a released claim" "$(se_kind)|$(se_limit)" "released|$i1"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":%s,"rateLimitType":"five_hour","utilization":0.95}}\n' "$r1" >"$se_log"
se_check "a top-level five-hour window at 0.95 gives it" failure "$i1"
rl_event allowed 0.89 "$r1" allowed 0.2 "$r3" >"$se_log"
se_check "0.89 gives none" failure absent
rl_event allowed 0.5 "$r1" allowed_warning 0.97 "$r3" >"$se_log"
se_check "a high seven-day utilization alone gives none" failure absent

# both pauses present: the later is written, each stop keeps its own reset
{ rl_event allowed 0.95 "$r3" allowed 0.2 "$r3"; echo "Claude AI usage limit reached|$r1"; } >"$se_log"
se_check "early pause the later: the limit file holds it" limited "$i3"
assert_contains "while the comment names the session's own reset" "$(fake_last_comment_of 7)" "which resets $i1"
{ rl_event allowed 0.95 "$r1" allowed 0.2 "$r3"; echo "Claude AI usage limit reached|$r3"; } >"$se_log"
se_check "limit pause the later: the limit file holds it" limited "$i3"

# the pause store keeps a later time and replaces an earlier or unparsable one
ndjson_with "Claude AI usage limit reached|$r1" >"$se_log"
se_fresh; printf '%s\n' "$i2" >"$limit_file"; se_end 1
assert_eq "a later reset already recorded is kept" "$(se_limit)" "$i2"
se_fresh; printf '%s\n' "$(iso_of "$((now_epoch - 100))")" >"$limit_file"; se_end 1
assert_eq "an earlier one is replaced" "$(se_limit)" "$i1"
se_fresh; printf 'garbage\n' >"$limit_file"; se_end 1
assert_eq "an unparsable one is replaced" "$(se_limit)" "$i1"

# a failed write is noted once, on stderr and in the log, and changes no outcome
rl_event allowed 0.95 "$r1" rejected 1 "$r3" >"$se_log"
se_fresh; rm -rf "$limit_file"; mkdir "$limit_file"; se_end 1
assert_status "a session end whose limit-file write fails succeeds" "$se_st" 0
assert_eq "both pauses with an unwritable limit file give one note" "$(grep -c "could not write the limit file" <<<"$se_out")" "1"
assert_contains "also in the session log" "$(cat "$se_log")" "could not write the limit file"
assert_eq "the issue is still limited" "$(se_kind)" limited
assert_eq "its claim released" "$(fake_claim_held 7)" free
rmdir "$limit_file"
rl_event allowed 0.95 "$r1" allowed 0.2 "$r3" >"$se_log"
se_fresh; rm -rf "$limit_file"; mkdir "$limit_file"; se_end 3
assert_contains "a failed early-pause write is noted on stderr" "$se_out" "could not write the limit file"
assert_eq "and the failure stop stands" "$(se_kind)" failure
rmdir "$limit_file"

# the held rule
ndjson_with "Claude AI usage limit reached|$r2" >"$se_log"
se_fresh; se_end 1 "$se_claim_fields"
assert_eq "a claim unchanged since before the session is held: a limit stop" "$(se_kind)" limited
se_fresh; fake_claim_release 7; se_end 1 "$se_claim_fields"
assert_eq "a released claim is released: no stop, no limit file" "$(se_kind)|$(se_limit)|$(fake_comments_of 7)" "released|absent|"
assert_contains "with the released note on stderr" "$se_out" "autopilot run: issue #7's session exited 1 with its claim released"
assert_contains "and in the log" "$(cat "$se_log")" "autopilot run: issue #7's session exited 1 with its claim released"
se_fresh; fake_claim_seed 7 "$(hostname)" 1 2026-02-02T00:00:00Z plan; se_end 1 "$se_claim_fields"
assert_eq "the next phase's claim taken is released" "$(se_kind)|$(se_limit)|$(fake_claim_held 7)" "released|absent|held"
se_fresh; se_end 1 ""
assert_eq "no claim before but one after is held" "$(se_kind)" limited
se_fresh; fake_claim_release 7; rl_event rejected 0.95 "$r1" allowed 0.2 "$r3" >"$se_log"; se_end 1 "$se_claim_fields"
assert_eq "released over a rejecting log: only the early pause, no stop" "$(se_kind)|$(se_limit)|$(fake_comments_of 7)" "released|$i1|"

# the limit stop comment: retry number, log, and the failure comment's wording
ndjson_with "Claude AI usage limit reached|$r2" >"$se_log"
se_fresh; se_end 1
assert_contains "a first limit stop is retry 1 of 2" "$(fake_last_comment_of 7)" "retry 1 of 2, started once the limit pause has passed"
assert_contains "its comment names the log" "$(fake_last_comment_of 7)" "$se_log"
se_fresh; fake_comment 7 o 2026-01-01T00:00:00Z "$(marker_of limited spec)
stopped"; se_end 1
assert_eq "a second stop in a row is limited" "$(se_kind)" limited
assert_contains "and retry 2 of 2" "$(fake_last_comment_of 7)" "retry 2 of 2"
ndjson_with "iteration limit reached" >"$se_log"
se_fresh; se_end 1
assert_contains "the failure comment says only a limit stop is retried" "$(fake_last_comment_of 7)" 'nothing is retried automatically except a usage-limit stop labelled `orch:limited`'
assert_not_contains "and names no usage limit" "$(fake_last_comment_of 7)" "usage limit"

# no reset, an early pause the later: the comment keeps the one-hour fallback
far_epoch=$((now_epoch + 14400))
{ rl_event allowed 0.9 "$far_epoch" allowed 0.2 "$far_epoch"; echo 'Claude AI usage limit reached'; } >"$se_log"
se_fresh; se_end 1
assert_contains "no reset, early pause later: the comment names the one-hour fallback" "$(fake_last_comment_of 7)" "falls back to a one-hour limit pause, until "
assert_not_contains "and not the early-pause reset" "$(fake_last_comment_of 7)" "$(iso_of "$far_epoch")"
assert_eq "while the limit file holds the early-pause reset" "$(se_limit)" "$(iso_of "$far_epoch")"

# the limit stop's failure fallbacks
ndjson_with "Claude AI usage limit reached|$r2" >"$se_log"
LIM_SPEC="$(marker_of limited spec)
stopped"
se_fresh
fake_comment 7 o 2026-01-01T00:00:00Z "$LIM_SPEC"
fake_comment 7 o 2026-01-01T00:00:01Z "$LIM_SPEC"
se_end 1
assert_eq "the third limit stop in a row takes the failure stop" "$(se_kind)" failure
assert_contains "naming the cap" "$(fake_last_comment_of 7)" "the third in a row in the spec phase"
assert_eq "and still writes the limit file" "$(se_limit)" "$i2"
se_fresh; fake_fail adapter_issue_comments_json "HTTP 500 comments"; se_end 1; fake_unfail
assert_eq "unreadable comments take the failure stop" "$(se_kind)" failure
assert_contains "naming the failed read" "$(fake_last_comment_of 7)" "comments could not be read"
assert_eq "and still write the limit file" "$(se_limit)" "$i2"
# the same two fallbacks over a log with no reset
ndjson_with 'Claude AI usage limit reached' >"$se_log"
se_fresh
fake_comment 7 o 2026-01-01T00:00:00Z "$LIM_SPEC"
fake_comment 7 o 2026-01-01T00:00:01Z "$LIM_SPEC"
se_end 1
assert_contains "the third in a row, no reset: the session gave no reset time" "$(fake_last_comment_of 7)" "the session gave no reset time"
se_fresh; fake_fail adapter_issue_comments_json "HTTP 500 comments"; se_end 1; fake_unfail
assert_contains "unreadable comments, no reset: the session gave no reset time" "$(fake_last_comment_of 7)" "the session gave no reset time"

# claims or the checkout that cannot be read: nothing is touched
se_fresh; before="$(fake_snapshot)"
fake_fail adapter_claim_list "HTTP 500 claims"; se_end 1 "$se_claim_fields"; fake_unfail
assert_status "unreadable claims die" "$se_st" 1
assert_contains "naming the claims" "$se_out" "could not list the claims on origin"
assert_eq "leaving labels, comments and claim untouched" "$(fake_snapshot)" "$before"
assert_eq "and no limit file" "$(se_limit)" absent
rm -rf "$se_dir"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND
