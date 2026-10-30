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
# fake_last_comment_of <n>: the body of issue #n's newest comment in the gh
# fake's store (newest by numeric comment order); the issue holds a comment.
fake_last_comment_of() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1/comments"
  cat "$d/$(ls "$d" | sort -n | tail -n 1)/body"
}
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
assert_status "answer for a phase never asked exits 2, never no reply's 1" "$st" 2
fake_fail adapter_issue_json "HTTP 500"
out="$("$ORCH" autopilot answer spec "$ans" 2>&1)"; st=$?
assert_status "a failed comment read exits 2, never no reply's 1" "$st" 2
assert_contains "naming the read" "$out" "read the comments of issue #7"
fake_unfail
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
assert_eq "the oldest first" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "issue-7 issue-8 "
assert_eq "the third waits" "$(fake_labels_of 9)" "orch:spec ready-for-agent "

# the slug: the issue title alone, whole words, at most 40 characters
pickup_titled() { # <issue> <title>: ticks over the issue; prints its side checkout's basename and its flow's slug
  fake_issue "$1" open ready-for-agent orch:spec; printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/title"
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
assert_eq "a long title is cut to whole words" "$(pickup_titled 21 'Agent settings: repeated kind/host switches and duplicated listing remedy builders (9 findings)')" "agent-settings-repeated-kind-host agent-settings-repeated-kind-host"
assert_eq "a short title is used whole" "$(pickup_titled 22 'Fix the widget')" "fix-the-widget fix-the-widget"
assert_eq "a first word over 40 characters is cut at 40" "$(pickup_titled 23 'Aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeee rest')" "aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd"
assert_eq "an all-punctuation title is untitled" "$(pickup_titled 24 '!!! ???')" "untitled untitled"
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
printf 'Needs ready\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
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
printf 'Blocked add\n' >"$ORCH_GH_FAKE_STORE/issues/8/title"
mkdir -p "$top/.orchestrator/checkouts/blocked-add" "$top/.orchestrator/checkouts/blocked-add-8"
"$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed side-checkout add does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 8)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step" "$(fake_comments_of 8)" "step side-checkout add failed"
assert_eq "and the claim is released" "$(fake_claim_held 8)" free

# a failed plan-comment post is a failure, the claim released
fake_issue 9 open ready-for-agent orch:spec
printf 'No plan\n' >"$ORCH_GH_FAKE_STORE/issues/9/title"
fake_fail_times adapter_issue_comment 1 "HTTP 500 comment"
tick_tmp="$(mktemp -d)"
TMPDIR="$tick_tmp" "$ORCH" autopilot tick >/dev/null 2>&1; st=$?
assert_status "a failed plan-comment post does not stop the tick" "$st" 0
assert_eq "the issue is needs-human" "$(fake_labels_of 9)" "needs-human orch:spec ready-for-agent "
assert_contains "naming the step and the gh reason" "$(fake_comments_of 9)" "step minimal plan comment failed: orch: gh could not post the 01-plan handoff on issue #9: HTTP 500 comment"
assert_eq "leaving no temp file from the post" "$(ls -A "$tick_tmp")" ""
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

# the claim identity: with ORCH_HOST_ID set, only claims of that id are this
# host's
fake_issue 14 open ready-for-agent orch:spec orch:running
fake_claim_seed 14 autopilot-abc123 "$(dead_pid)"
fake_issue 15 open ready-for-agent orch:spec orch:running
fake_claim_seed 15 "$(hostname)" "$(dead_pid)"
ORCH_HOST_ID=autopilot-abc123 "$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "a claim of ORCH_HOST_ID is cleaned" "$(fake_claim_held 14)" free
assert_eq "the hostname's claim is then another identity's, left alone" "$(fake_claim_held 15)" held
rm -f "$ORCH_GH_FAKE_STORE/claims/15"

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
(cd "$top/.orchestrator/checkouts/needs-ready" && state_fixture phase spec)
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
reset_iso="$(iso_of "$reset_epoch")"
ndjson_with "Claude AI usage limit reached|$reset_epoch" >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_eq "the session that hit the limit starts one session" "$(tick_calls)" "1"
assert_contains "its failure comment names the usage limit" "$(fake_comments_of 7)" "usage limit"
assert_contains "and the reset time" "$(fake_comments_of 7)" "$reset_iso"
fake_issue 8 open ready-for-agent orch:spec; printf 'Limit 8\n' >"$ORCH_GH_FAKE_STORE/issues/8/title"
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
# a message without a reset time pauses for an hour
fake_issue 8 open ready-for-agent orch:spec
ndjson_with 'Claude AI usage limit reached' >"$launcher_dir/out"; printf '1\n' >"$launcher_dir/exit"; rm -f "$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1
read -r limit_epoch _ < <(local_fields "$(cat "$top/.orchestrator/autopilot/limit")")
assert_eq "no reset time in the message: one hour on" "$(( (limit_epoch - $(date +%s) + 30) / 3600 ))" "1"
assert_contains "the comment still names the usage limit" "$(fake_comments_of 8)" "usage limit"
last_body="$(fake_last_comment_of 8)"
assert_contains "the comment says the session gave no reset time" "$last_body" "it gave no reset time, so the watcher falls back to a one-hour limit pause, until $(cat "$top/.orchestrator/autopilot/limit")."
assert_not_contains "and names no reset it does not have" "$last_body" "resets"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: the rate limit event -------------------------------------
# The session's log is NDJSON with plain-text lines mixed in; the limit file's
# reset comes from the last rate_limit_event (#1463).
echo
echo "autopilot tick rate limit event"
tick_fixture
top="$(git rev-parse --show-toplevel)"
fake_issue 7 open ready-for-agent orch:spec; printf 'Event 7\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
limit_file="$top/.orchestrator/autopilot/limit"
printf '7\n' >"$launcher_dir/release"; : >"$launcher_dir/out"
"$ORCH" autopilot tick >/dev/null 2>&1   # makes the side checkout
rm -f "$launcher_dir/release" "$launcher_dir/calls" "$limit_file"
# event_session <exit>: a fresh run of issue 7 over the launcher's canned log,
# the limit file absent.
event_session() {
  [ -d "$limit_file" ] || rm -f "$limit_file"
  fake_issue 7 open ready-for-agent orch:spec orch:running
  fake_claim_seed 7
  printf '%s\n' "$1" >"$launcher_dir/exit"
  out="$("$ORCH" autopilot run 7 2>&1)"; st=$?
}
now_epoch="$(date +%s)"
r1=$((now_epoch + 3600)); r2=$((now_epoch + 7200)); r3=$((now_epoch + 90000))

# early pause
rl_event allowed 0.9 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 0
assert_eq "a five-hour utilization of 0.9 writes its reset on a successful session" "$(cat "$limit_file")" "$(iso_of "$r1")"
event_session 3
assert_eq "and on a failure that is no usage limit" "$(cat "$limit_file")" "$(iso_of "$r1")"
assert_not_contains "that failure names no usage limit" "$(fake_comments_of 7)" "usage limit"
printf '7\n' >"$launcher_dir/release"
event_session 0
assert_eq "and on a session that released its claim" "$(cat "$limit_file")" "$(iso_of "$r1")"
rl_event rejected 1 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 1
assert_eq "a rejecting event of a released claim marks no issue" "$(fake_labels_of 7)" "orch:running orch:spec ready-for-agent "
assert_not_contains "and posts no limit stop comment" "$(fake_comments_of 7)" "usage limit"
rm -f "$launcher_dir/release"
# a failed limit-file write is noted and changes nothing else
rm -f "$limit_file"; mkdir "$limit_file"
rl_event allowed 0.2 "$r1" rejected 1 "$r1" >"$launcher_dir/out"
event_session 1
assert_status "a run whose limit-file write fails succeeds" "$st" 0
assert_contains "the failure is noted on stderr" "$out" "could not write the limit file"
assert_eq "a limit stop alone gives one note" "$(grep -c "could not write the limit file" <<<"$out")" "1"
event_log="$(ls "$top/.orchestrator/autopilot/logs"/7-spec-*.log | tail -1)"
assert_contains "and in the session log" "$(cat "$event_log")" "could not write the limit file"
assert_eq "the issue is still limited" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
assert_eq "its claim released" "$(fake_claim_held 7)" free
assert_contains "with its usage limit comment" "$(fake_comments_of 7)" "usage limit"
rmdir "$limit_file"

# a failed early-pause write on its own leaves the session's outcome as it was
rm -f "$limit_file"; mkdir "$limit_file"
rl_event allowed 0.95 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 3
assert_status "a run whose early-pause write fails succeeds" "$st" 0
assert_contains "the failure is noted on stderr" "$out" "could not write the limit file"
assert_eq "an ordinary failure is still needs-human" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_contains "with its ordinary failure comment" "$(fake_comments_of 7)" "Autopilot failed in the spec phase"
assert_contains "and the new failure-comment wording" "$(fake_comments_of 7)" 'nothing is retried automatically except a usage-limit stop labelled `orch:limited`'
assert_not_contains "that names no usage limit" "$(fake_comments_of 7)" "usage limit"
assert_eq "its claim released" "$(fake_claim_held 7)" free
rmdir "$limit_file"
# a failed write on one session with both pauses notes once per write
rm -f "$limit_file"; mkdir "$limit_file"
rl_event rejected 1 "$r1" allowed 0.2 "$r3" >"$launcher_dir/out"
event_session 1
assert_eq "both pauses with an unwritable limit file give two notes" "$(grep -c "could not write the limit file" <<<"$out")" "2"
rmdir "$limit_file"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot tick: limited issues -------------------------------------------
# A usage-limit stop is waited out as orch:limited, at most twice in a row per
# phase (#1463).
echo
echo "autopilot tick limited issues"
tick_fixture
top="$(git rev-parse --show-toplevel)"
limit_file="$top/.orchestrator/autopilot/limit"
lim_reset=$(( $(date +%s) + 3600 ))
lim_iso="$(iso_of "$lim_reset")"
# lim_relabel <n> <label>...: issue #n's labels set; title, comments kept.
lim_relabel() { local n="$1"; shift; printf '%s\n' "$@" >"$ORCH_GH_FAKE_STORE/issues/$n/labels"; }
# lim_fresh: issue #7 with no comments and a running spec phase, and no limit
# file.
lim_fresh() {
  rm -rf "$ORCH_GH_FAKE_STORE/issues/7/comments"; rm -f "$limit_file"
  lim_relabel 7 orch:spec ready-for-agent orch:running
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
fake_issue 7 open ready-for-agent orch:spec; printf 'Lim 7\n' >"$ORCH_GH_FAKE_STORE/issues/7/title"
printf '7\n' >"$launcher_dir/release"
"$ORCH" autopilot tick >/dev/null 2>&1   # makes the side checkout
rm -f "$launcher_dir/release" "$launcher_dir/calls"
lim_relabel 7 orch:spec ready-for-agent orch:running
limit_run 7 >/dev/null
assert_eq "a first limit stop leaves orch:limited, not needs-human" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
assert_eq "and releases the claim" "$(fake_claim_held 7)" free
assert_eq "its comment opens with the marker" "$(fake_last_comment_of 7 | head -n 1)" "<!-- orch:limited spec -->"
assert_contains "gives the reset time" "$(fake_comments_of 7)" "$lim_iso"
assert_contains "and the retry number" "$(fake_comments_of 7)" "retry 1 of 2, started once the limit pause has passed"
assert_contains "and the log path" "$(fake_comments_of 7)" "/autopilot/logs/7-spec-"
lim_relabel 7 orch:spec ready-for-agent orch:running
limit_run 7 >/dev/null
assert_contains "the second stop is retry 2 of 2" "$(fake_comments_of 7)" "retry 2 of 2"
assert_eq "and still limited" "$(fake_labels_of 7)" "orch:limited orch:spec ready-for-agent "
lim_relabel 7 orch:spec ready-for-agent orch:limited orch:running
rm -f "$limit_file"
limit_run 7 >/dev/null
assert_eq "the third in a row is needs-human, without orch:limited" "$(fake_labels_of 7)" "needs-human orch:spec ready-for-agent "
assert_contains "its failure comment names the usage limit and the cap" "$(fake_comments_of 7)" "the third in a row in the spec phase"
assert_eq "it still writes the limit file" "$(cat "$limit_file")" "$lim_iso"

LABELS_HUMAN="needs-human orch:spec ready-for-agent "

# a rejecting rate_limit_event with no resetsAt names the fallback pause too
lim_fresh
limit_run 7 "$(rl_event rejected 1 null allowed 0.2 null)" >/dev/null
assert_contains "an event with no resetsAt: the comment names the fallback pause" "$(fake_comments_of 7)" "it gave no reset time, so the watcher falls back to a one-hour limit pause, until $(cat "$limit_file")."
assert_not_contains "and no reset" "$(fake_comments_of 7)" "resets"
# a no-reset limit stop whose five-hour window is at 90% with its reset far off:
# the comment names the one-hour fallback pause, the file the early-pause reset
lim_fresh
far_epoch=$(( $(date +%s) + 14400 ))
limit_run 7 "$({ rl_event allowed 0.9 "$far_epoch" allowed 0.2 "$far_epoch"; echo 'Claude AI usage limit reached'; })" >/dev/null
assert_contains "no reset, early pause later: the comment names the one-hour fallback" "$(fake_last_comment_of 7)" "falls back to a one-hour limit pause, until "
assert_not_contains "and not the early-pause reset" "$(fake_last_comment_of 7)" "$(iso_of "$far_epoch")"
assert_eq "while the limit file holds the early-pause reset" "$(cat "$limit_file")" "$(iso_of "$far_epoch")"
LIM_SPEC="$(marker_of limited spec)
stopped"
# the third stop in a row, on a message with no reset: says so, names no pause
lim_fresh
fake_comment 7 o 2026-01-01T00:00:00Z "$LIM_SPEC"
fake_comment 7 o 2026-01-01T00:00:01Z "$LIM_SPEC"
limit_run 7 "$(ndjson_with 'Claude AI usage limit reached')" >/dev/null
assert_contains "the third in a row, no reset: says the session gave no reset time" "$(fake_comments_of 7)" "the session gave no reset time"
assert_contains "and is the third-in-a-row failure" "$(fake_comments_of 7)" "the third in a row in the spec phase"
assert_not_contains "naming no pause" "$(fake_comments_of 7)" "$(cat "$limit_file")"
# unreadable comments, on a message with no reset
lim_fresh
fake_fail adapter_issue_comments_json "HTTP 500 comments"
limit_run 7 "$(ndjson_with 'Claude AI usage limit reached')" >/dev/null
fake_unfail
assert_contains "unreadable comments, no reset: says the session gave no reset time" "$(fake_comments_of 7)" "the session gave no reset time"
assert_contains "and names the failed read" "$(fake_comments_of 7)" "comments could not be read"
assert_not_contains "naming no pause time" "$(fake_comments_of 7)" "$(cat "$limit_file")"

# comments that cannot be read take the failure path, and still write the reset
lim_fresh
fake_fail adapter_issue_comments_json "HTTP 500 comments"
limit_run 7 >/dev/null
fake_unfail
assert_eq "a failed comment read ends with needs-human" "$(fake_labels_of 7)" "$LABELS_HUMAN"
assert_contains "naming the failed read" "$(fake_comments_of 7)" "comments could not be read"
assert_eq "and the limit file is written" "$(cat "$limit_file")" "$lim_iso"

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
rm -rf "$ORCH_GH_FAKE_STORE/issues/7/comments"
fake_issue 7 open ready-for-agent orch:spec orch:limited
fake_issue 6 open ready-for-agent orch:spec orch:limited
fake_issue 5 open ready-for-agent orch:spec; printf 'Lim 5\n' >"$ORCH_GH_FAKE_STORE/issues/5/title"; printf 'Lim 6\n' >"$ORCH_GH_FAKE_STORE/issues/6/title"
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
rm -f "$ORCH_GH_FAKE_STORE/claims/6"
# a failed removal is a failed step
fake_issue 6 open ready-for-agent orch:spec orch:limited
fake_fail_times adapter_issue_relabel 1 "HTTP 500"
rm -f "$launcher_dir/calls"
"$ORCH" autopilot tick >/dev/null 2>&1
fake_unfail
assert_eq "a failed orch:limited removal ends with needs-human and no orch:limited" "$(fake_labels_of 6)" "$LABELS_HUMAN"
assert_eq "and starts no session for it" "$(tick_calls)" "0"

# a limit file in another clone's autopilot directory starts no pause
other_clone="$(mktemp -d)"
git clone -q "$top" "$other_clone/clone" >/dev/null 2>&1
mkdir -p "$other_clone/clone/.orchestrator/autopilot"
printf '%s\n' "$lim_iso" >"$other_clone/clone/.orchestrator/autopilot/limit"
rm -f "$limit_file" "$launcher_dir/calls"
fake_issue 8 open ready-for-agent orch:spec; printf 'Lim 8\n' >"$ORCH_GH_FAKE_STORE/issues/8/title"
printf '8\n' >"$launcher_dir/release"; printf '0\n' >"$launcher_dir/exit"; : >"$launcher_dir/out"
"$ORCH" autopilot tick >/dev/null 2>&1
assert_contains "another clone's limit file starts no pause" "$(grep '^dir:' "$launcher_dir/calls" | sed 's#.*/##' | tr '\n' ' ')" "lim-8"
rm -rf "$other_clone"

# autopilot questions does not list a limited issue
fake_issue 30 open ready-for-agent orch:spec orch:limited
assert_not_contains "autopilot questions lists no limited issue" "$("$ORCH" autopilot questions 2>&1)" "30"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- autopilot questions, reply and resume ------------------------------------
# The three verbs behind /orchestrator:questions: they hold no flow state, so
# the repo here is a bare checkout with an origin and no state.json.
echo
echo "autopilot questions, reply and resume"
new_repo >/dev/null
fake_github
# post_stop <issue> <refusal|failure> <phase> <detail>: a stop comment as
# autopilot_stop itself words it.
post_stop() { bash -c 'source "$1"; shift; "$@"' _ "$ORCH" autopilot_stop "$@" >/dev/null 2>&1; }
# question_of <phase>: a question comment body of that phase.
question_of() { printf '%s\n@o\n\n1. Keep it? Recommended: yes\n' "$(marker_of question "$1")"; }
url_of() { printf 'https://github.com/o/r/issues/%s#issuecomment-%s' "$1" "$2"; }

assert_eq "no state.json exists in the checkout" "$(on_disk .orchestrator/state.json)" absent
out="$("$ORCH" autopilot questions 2>&1)"; st=$?
assert_status "nothing labelled needs-human exits 0" "$st" 0
assert_contains "saying nothing is pending" "$out" "nothing pending"
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
post_stop 14 failure implement "step x failed"
# neither comment: the phase comes from the earliest phase label
fake_issue 15 open needs-human orch:review orch:implement
# a question then a stop, and a stop then a question
fake_issue 16 open needs-human orch:spec
fake_comment 16 o 2026-01-01T00:00:00Z "$(question_of spec)"
post_stop 16 refusal spec "no plan"
fake_issue 17 open needs-human orch:spec
post_stop 17 refusal spec "no plan"
fake_comment 17 o 2026-01-09T00:00:00Z "$(question_of spec)"
# a stop comment in the legacy form, seeded raw, is still a stop
fake_issue 24 open needs-human orch:spec
fake_comment 24 o 2026-01-01T00:00:00Z "Autopilot refused to run the review phase: no pr"
fake_issue 25 open needs-human orch:spec
fake_comment 25 o 2026-01-01T00:00:00Z "Autopilot failed in the implement phase: boom"
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
assert_eq "a legacy-form refusal comment is a stop, in its own phase" "$(grep "^24$tab" <<<"$out")" "24${tab}stop${tab}review${tab}$(url_of 24 1)"
assert_eq "a legacy-form failure comment is a stop, in its own phase" "$(grep "^25$tab" <<<"$out")" "25${tab}stop${tab}implement${tab}$(url_of 25 1)"
assert_eq "a marked failure comment is a stop, in its own phase" "$(grep "^26$tab" <<<"$out")" "26${tab}stop${tab}review${tab}$(url_of 26 1)"
assert_eq "an issue with no phase label, orch:done, closed or not needs-human is left out" \
  "$(cut -f1 <<<"$out" | tr "\n" " ")" "11 12 13 14 15 16 17 24 25 26 "
# a comment that only mentions the marker is no question
fake_issue 23 open needs-human orch:spec
fake_comment 23 o 2026-01-01T00:00:00Z $'see the marker\n<!-- orch:question spec -->'
out="$("$ORCH" autopilot questions 2>&1)"
assert_contains "a marker off the first line is no question" "$out" "23${tab}stop${tab}spec${tab}"
# autopilot_stop opens its comment with the hidden marker line, prose beneath
fake_issue 40 open ready-for-agent orch:spec
post_stop 40 refusal spec "no plan"
assert_eq "a refusal comment opens with the hidden marker line" "$(fake_comments_of 40 | head -1)" "$(marker_of refusal spec)"
assert_contains "and keeps its prose beneath" "$(fake_comments_of 40 | sed -n 2p)" "Autopilot refused to run the spec phase: no plan"
fake_issue 41 open ready-for-agent orch:spec
post_stop 41 failure review "boom"
assert_eq "a failure comment opens with the hidden marker line" "$(fake_comments_of 41 | head -1)" "$(marker_of failure review)"
assert_contains "and keeps its prose beneath" "$(fake_comments_of 41 | sed -n 2p)" "Autopilot failed in the review phase: boom"
fake_issue 42 open ready-for-agent orch:spec
bash -c 'source "$1"; shift; "$@"' _ "$ORCH" autopilot_stop 42 failure "" boom >/dev/null 2>&1; st=$?
assert_status "an empty phase dies" "$st" 1
bash -c 'source "$1"; shift; "$@"' _ "$ORCH" autopilot_limit_stop 42 "" "" "" 1 log >/dev/null 2>&1; st=$?
assert_status "a limit stop of an empty phase dies" "$st" 1
assert_eq "an empty phase writes no comment and changes no label" "$(fake_comments_of 42)$(fake_labels_of 42)" "orch:spec ready-for-agent "
for n in 11 12 13 14 15 16 17 18 19 20 21 23 24 25 26 40 41 42; do rm -rf "$ORCH_GH_FAKE_STORE/issues/$n"; done
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
assert_contains "with gh's reason" "$out" "HTTP 500"
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
assert_contains "saying the comment landed" "$out" "comment landed"
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

# --- autopilot_phase_labels_text joins the phase labels (#1563) ---------------
echo
echo "autopilot phase labels text"
new_repo >/dev/null
out="$(sourced_orch autopilot_phase_labels_text "$(printf 'bug\nready-for-agent')" 2>&1)"
assert_eq "no phase label prints nothing" "$out" ""
out="$(sourced_orch autopilot_phase_labels_text "$(printf 'bug\norch:review')" 2>&1)"
assert_eq "one phase label prints that label" "$out" "orch:review"
out="$(sourced_orch autopilot_phase_labels_text "$(printf 'orch:review\nbug\norch:spec')" 2>&1)"
assert_eq "two phase labels print in table order, space-separated" "$out" "orch:spec orch:review"

# --- autopilot limit count (the retry count) ---------------------------------
# autopilot_limit_count called directly over seeded comments (#1463, #1695).
echo
echo "autopilot limit count"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec
# the count stops at a refusal, failure, question or handoff comment and at a
# limit stop comment of another phase, and skips other comments
LIM_SPEC="$(marker_of limited spec)
stopped"
count_case() { # <label> <expected count> <comment>...: seeded oldest first
  local label="$1" want="$2" c
  shift 2
  rm -rf "$ORCH_GH_FAKE_STORE/issues/7/comments"
  for c in "$@"; do fake_comment 7 o 2026-01-01T00:00:00Z "$c"; done
  # shellcheck disable=SC2016 # expanded by the inner bash
  assert_eq "$label" "$(sourced_orch_script 'autopilot_limit_count 7 spec got && printf %s "$got"')" "$want"
}
count_case "two stops in a row are counted" 2 "$LIM_SPEC" "$LIM_SPEC"
count_case "other comments between them are skipped" 2 "$LIM_SPEC" "just a note" "$LIM_SPEC" "another note"
count_case "a failure comment resets the count" 0 "$LIM_SPEC" "$LIM_SPEC" "Autopilot failed in the spec phase: x"
count_case "a refusal comment resets it" 0 "$LIM_SPEC" "$LIM_SPEC" "Autopilot refused to run the spec phase: x"
count_case "a question comment resets it" 0 "$LIM_SPEC" "$LIM_SPEC" "$(marker_of question spec)
@o"
count_case "a handoff comment resets it" 0 "$LIM_SPEC" "$LIM_SPEC" "$(marker_of handoff 01-plan)
x"
count_case "a limit stop comment of another phase resets it" 1 "$LIM_SPEC" "$(marker_of limited implement)
x" "$LIM_SPEC"
count_case "a marked failure comment resets it" 0 "$LIM_SPEC" "$LIM_SPEC" "$(marker_of failure spec)
x"
count_case "a marked refusal comment resets it" 0 "$LIM_SPEC" "$LIM_SPEC" "$(marker_of refusal spec)
x"
count_case "a handoff first line without its closing is no handoff" 2 "$LIM_SPEC" "<!-- orch:handoff 01-plan
x" "$LIM_SPEC"
fake_fail adapter_issue_comments_json "HTTP 500 comments"
sourced_orch_script 'autopilot_limit_count 7 spec got' 2>/dev/null; st=$?
fake_unfail
assert_status "unreadable comments return non-zero" "$st" 1

# --- autopilot pause store ----------------------------------------------------
echo
echo "autopilot pause store"
tick_fixture
pm="$(git rev-parse --show-toplevel)"; pl="$(mktemp)"
future_iso="$(iso_of "$(( $(date +%s) + 7200 ))")"; later_iso="$(iso_of "$(( $(date +%s) + 9000 ))")"
mkdir -p "$pm/.orchestrator/autopilot"; pf="$pm/.orchestrator/autopilot/limit"
out="$(sourced_orch autopilot_pause_until "$pm" 2>&1)"; st=$?
assert_status "no limit file: not paused" "$st" 1
assert_eq "and nothing printed" "$out" ""
sourced_orch autopilot_pause_extend "$pm" "$future_iso" "$pl"; st=$?
assert_status "extend succeeds" "$st" 0
assert_eq "extend records the time" "$(cat "$pf")" "$future_iso"
sourced_orch autopilot_pause_extend "$pm" "$later_iso" "$pl"
assert_eq "extend replaces an earlier time" "$(cat "$pf")" "$later_iso"
sourced_orch autopilot_pause_extend "$pm" "$future_iso" "$pl"
assert_eq "extend keeps a later time" "$(cat "$pf")" "$later_iso"
printf 'garbage\n' >"$pf"
sourced_orch autopilot_pause_extend "$pm" "$future_iso" "$pl"
assert_eq "extend replaces an unparsable time" "$(cat "$pf")" "$future_iso"
out="$(sourced_orch autopilot_pause_until "$pm" 2>&1)"; st=$?
assert_status "a future time pauses" "$st" 0
assert_contains "and the note names it" "$out" "usage limit: no issue is picked up until $future_iso"
printf '2020-01-01T00:00:00Z\n' >"$pf"
sourced_orch autopilot_pause_until "$pm" >/dev/null 2>&1; st=$?
assert_status "a passed time does not pause" "$st" 1
assert_eq "and removes the file" "$(on_disk "$pf")" absent
printf 'garbage\n' >"$pf"
sourced_orch autopilot_pause_until "$pm" >/dev/null 2>&1; st=$?
assert_status "an unparsable time does not pause" "$st" 1
assert_eq "and removes the file too" "$(on_disk "$pf")" absent
rm -f "$pf"; mkdir "$pf"
out="$(sourced_orch autopilot_pause_extend "$pm" "$future_iso" "$pl" 2>&1)"; st=$?
assert_status "a failed write still returns 0" "$st" 0
assert_contains "noting it on stderr" "$out" "could not write the limit file"
assert_contains "and in the log" "$(cat "$pl")" "could not write the limit file"
rm -rf "$pf"

# --- autopilot session end (the classifier) ----------------------------------
# autopilot_session_end <log> <held>, called directly over log files: each case
# asserts all four values (#1695).
echo
echo "autopilot session end"
new_repo >/dev/null
se_dir="$(mktemp -d)"; se_log="$se_dir/session.log"
# se_end <held>: the classifier over $se_log, as "outcome|reset|early|limit".
se_end() {
  sourced_orch_script 'outcome=x reset=x early=x limit=x; autopilot_session_end "$1" "$2"; printf "%s|%s|%s|%s\n" "$outcome" "$reset" "$early" "$limit"' "$se_log" "$1"
}
# se_check <label> <held> <outcome> <reset> <early> <limit>: asserts all four.
se_check() { assert_eq "$1" "$(se_end "$2")" "$3|$4|$5|$6"; }
# se_check_hour_fallback <outcome label> <limit label>: over $se_log held, the
# outcome is limited with no reset or early pause, and the limit is one hour on,
# within the clock read around the call.
se_check_hour_fallback() {
  local before after got o rs er lm lim_epoch
  before="$(date +%s)"; got="$(se_end 1)"; after="$(date +%s)"
  IFS='|' read -r o rs er lm <<<"$got"
  read -r lim_epoch _ < <(local_fields "$lm")
  assert_eq "$1" "$o|$rs|$er" "limited||"
  assert_eq "$2" "$([ "$lim_epoch" -ge $((before + 3600)) ] && [ "$lim_epoch" -le $((after + 3600)) ] && echo yes)" yes
}
now_epoch="$(date +%s)"
r1=$((now_epoch + 3600)); r2=$((now_epoch + 7200)); r3=$((now_epoch + 90000))
i1="$(iso_of "$r1")"; i2="$(iso_of "$r2")"; i3="$(iso_of "$r3")"

# wordings
ndjson_with "Claude AI usage limit reached|$r2" >"$se_log"
se_check "\"usage limit reached|<epoch>\" is limited, with that reset" 1 limited "$i2" "" "$i2"
for wording in "Claude Opus usage limit reached" "5-hour limit reached" "Weekly limit reached"; do
  ndjson_with "$wording" >"$se_log"
  se_check_hour_fallback "\"$wording\" is limited, with no reset or early pause" "and its limit is one hour on"
done
for wording in "iteration limit reached" "API rate limit reached, retrying"; do
  ndjson_with "$wording" >"$se_log"
  se_check "\"$wording\" is a failure" 1 failure "" "" ""
done

# resets <time>
ndjson_with '5-hour limit reached ∙ resets 3pm' >"$se_log"
IFS='|' read -r o rs er lm <<<"$(se_end 1)"
read -r rs_epoch rs_hour _ < <(local_fields "$rs")
assert_eq "\"resets 3pm\" is limited, its limit the reset, no early pause" "$o|$lm|$er" "limited|$rs|"
assert_eq "the reset is 15:00 local" "$rs_hour" 15
assert_eq "within the next day" "$([ "$rs_epoch" -gt "$(date +%s)" ] && [ "$rs_epoch" -le "$(( $(date +%s) + 86400 + 3600 ))" ] && echo yes)" yes
ndjson_with 'Weekly limit reached ∙ resets Mon 9am' >"$se_log"
IFS='|' read -r o rs er lm <<<"$(se_end 1)"
read -r rs_epoch rs_hour rs_day < <(local_fields "$rs")
assert_eq "\"resets Mon 9am\" is limited, its limit the reset" "$o|$lm|$er" "limited|$rs|"
assert_eq "the reset is a Monday at 09:00 local" "$rs_day $rs_hour" "Mon 09"
assert_eq "within the next week" "$([ "$rs_epoch" -gt "$(date +%s)" ] && [ "$rs_epoch" -le "$(( $(date +%s) + 7 * 86400 + 3600 ))" ] && echo yes)" yes

# where the text is found
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"Claude AI usage limit reached"}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":"Weekly limit reached"}]}}' >"$se_log"
se_check "limit wording only in assistant text or tool results is a failure" 1 failure "" "" ""
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}' \
  "{\"type\":\"result\",\"is_error\":true,\"result\":\"Claude AI usage limit reached|$r2\"}" >"$se_log"
se_check "a limit message in the last result event is limited" 1 limited "$i2" "" "$i2"
printf '%s\n' "{\"type\":\"result\",\"result\":\"all done\"}" "plain Claude AI usage limit reached|$r2" >"$se_log"
se_check "a plain-text line is read with the result text" 1 limited "$i2" "" "$i2"

# rate-limit events
{ echo 'stderr noise line'; rl_event rejected 1 "$r1" allowed_warning 0.8 "$r3"; echo 'another note'; } >"$se_log"
se_check "a rejecting five-hour window gives its reset" 1 limited "$i1" "$i1" "$i1"
rl_event rejected 1 "$r1" rejected 0.8 "$r3" >"$se_log"
se_check "the latest of several rejecting windows decides" 1 limited "$i3" "$i1" "$i3"
{ rl_event rejected 1 "$r1" allowed 0.8 "$r3"; rl_event allowed 0.5 "$r1" allowed 0.8 "$r3"; } >"$se_log"
se_check "a rejecting event followed by an allowed one is a failure" 1 failure "" "" ""
rl_event rejected 1 null allowed 0.2 null >"$se_log"
se_check_hour_fallback "a rejecting event with no resetsAt: limited, no reset, no early pause" "and a limit pause one hour on, within the clock read around the call"

# early pause, whatever the outcome
rl_event allowed 0.9 "$r1" allowed 0.2 "$r3" >"$se_log"
se_check "utilization 0.9 gives the early pause on a failure" 1 failure "" "$i1" ""
se_check "and on a released claim" 0 released "" "$i1" ""
{ rl_event allowed 0.9 "$r1" allowed 0.2 "$r3"; echo "Claude AI usage limit reached|$r2"; } >"$se_log"
se_check "and on a limited session, the limit pause apart" 1 limited "$i2" "$i1" "$i2"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","resetsAt":%s,"rateLimitType":"five_hour","utilization":0.95}}\n' "$r1" >"$se_log"
se_check "a top-level five-hour window at 0.95 gives it" 1 failure "" "$i1" ""
rl_event allowed 0.89 "$r1" allowed 0.2 "$r3" >"$se_log"
se_check "0.89 gives none" 1 failure "" "" ""
rl_event allowed 0.5 "$r1" allowed_warning 0.97 "$r3" >"$se_log"
se_check "a high seven-day utilization alone gives none" 1 failure "" "" ""

# both pauses present
{ rl_event allowed 0.95 "$r3" allowed 0.2 "$r3"; echo "Claude AI usage limit reached|$r1"; } >"$se_log"
se_check "early pause the later: each value holds its own" 1 limited "$i1" "$i3" "$i1"
{ rl_event allowed 0.95 "$r1" allowed 0.2 "$r3"; echo "Claude AI usage limit reached|$r3"; } >"$se_log"
se_check "limit pause the later: each value holds its own" 1 limited "$i3" "$i1" "$i3"

# released claims
rl_event rejected 0.95 "$r1" allowed 0.2 "$r3" >"$se_log"
se_check "a released claim with a rejecting event is released, with its early pause only" 0 released "" "$i1" ""
rm -rf "$se_dir"
