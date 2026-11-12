# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- Session log module ------------------------------------------------------
# session_log_read, called through a sourced orch.sh over small logs; each
# case prints the four values it sets.

echo
echo "session log"
new_repo >/dev/null
sl_dir="$(mktemp -d)"
sl_now="$(date +%s)"
sl_a=$((sl_now + 3600)); sl_b=$((sl_now + 7200))
# sl_read <log>...: the four values after reading each log in turn in one
# shell, "<limited>|<reset>|<early>|<reply>" for the last.
sl_read() {
  sourced_orch_script 'for l in "$@"; do session_log_read "$l"; done; printf "%s|%s|%s|%s" "$SESSION_LOG_LIMITED" "$SESSION_LOG_RESET" "$SESSION_LOG_EARLY" "$SESSION_LOG_REPLY"' "$@"
}

rl_event allowed 0.2 "$sl_a" rejected 1 "$sl_b" >"$sl_dir/reject"
assert_eq "a rejecting event is a limit stop at its reset" "$(sl_read "$sl_dir/reject")" "1|$sl_b||"

{ rl_event rejected 1 null allowed 0.2 null; echo "Claude AI usage limit reached|$sl_b"; } >"$sl_dir/noreset"
assert_eq "a rejecting event with no resetsAt decides, with no reset" "$(sl_read "$sl_dir/noreset")" "1|||"

ndjson_with "Claude AI usage limit reached|$sl_b" >"$sl_dir/epoch"
assert_eq "text-only limit message with an epoch" "$(sl_read "$sl_dir/epoch")" "1|$sl_b||"

{ echo '{"type":"result","result":"5-hour limit reached ∙ resets 3pm"}'; echo "Claude AI usage limit reached|$sl_a"; } >"$sl_dir/order"
IFS='|' read -r _ order_reset _ <<<"$(sl_read "$sl_dir/order")"
assert_eq "a result text is read after the plain lines, so its resets time wins" "$([ -n "$order_reset" ] && [ "$order_reset" != "$sl_a" ] && [ "$order_reset" -gt "$sl_now" ] && echo yes)" yes

rl_event allowed 0.95 "$sl_a" allowed 0.2 "$sl_b" >"$sl_dir/early"
assert_eq "an allowed event at 0.95 gives the early pause only" "$(sl_read "$sl_dir/early")" "0||$sl_a|"

printf '%s\n' '{"type":"result","result":"all  done\nnow"}' >"$sl_dir/reply"
assert_eq "a final result text is the reply" "$(sl_read "$sl_dir/reply")" "0|||all done now"

printf '%s\n' 'noise' '{"type":"assistant","message":{"content":[{"type":"text","text":"usage limit reached"}]}}' >"$sl_dir/none"
assert_eq "assistant wording is ignored" "$(sl_read "$sl_dir/none")" "0|||"

assert_eq "a missing log is not a limit stop" "$(sl_read "$sl_dir/absent")" "0|||"

assert_eq "no value carries over to the next call" "$(sl_read "$sl_dir/early" "$sl_dir/none")" "0|||"
assert_eq "nor from a limited log" "$(sl_read "$sl_dir/reject" "$sl_dir/none")" "0|||"
rm -rf "$sl_dir"
