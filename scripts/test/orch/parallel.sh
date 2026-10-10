# --- parallel show -------------------------------------------------------------
# The clone's parallel cap: how many ticket subagents a frontier runs at once.
# The default lives here alone, so the skills never read git config themselves.
echo
echo "parallel show"
new_repo >/dev/null

out="$("$ORCH" parallel show 2>&1)"; st=$?
assert_status "parallel show succeeds with orchestrator.parallel unset" "$st" 0
assert_eq "the cap is 3 when orchestrator.parallel is unset" "$out" "3"

git config orchestrator.parallel 5
out="$("$ORCH" parallel show 2>&1)"; st=$?
assert_status "parallel show succeeds with a positive cap set" "$st" 0
assert_eq "the cap is orchestrator.parallel's value when set" "$out" "5"
git config orchestrator.parallel 1
assert_eq "a cap of 1, sequential, is a valid setting" "$("$ORCH" parallel show 2>&1)" "1"

for v in 0 -2 three 2x; do
  git config --unset-all orchestrator.parallel; git config orchestrator.parallel "$v"
  out="$("$ORCH" parallel show 2>&1)"; st=$?
  assert_status "parallel show dies on orchestrator.parallel=$v" "$st" 1
  assert_contains "naming the key" "$out" "orchestrator.parallel"
  assert_contains "and the value $v" "$out" "$v"
done
git config --unset orchestrator.parallel

out="$("$ORCH" parallel show extra 2>&1)"; st=$?
assert_status "parallel show refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh parallel show"
out="$("$ORCH" parallel bogus 2>&1)"; st=$?
assert_status "parallel bogus is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown parallel op"

out="$("$ORCH" help 2>&1)"
assert_contains "parallel show is in the usage text" "$out" "parallel show"
assert_contains "beside base show" "$(printf '%s\n' "$out" | grep -A3 '^  base clear' | tr '\n' ' ')" "parallel show"
assert_contains "the CLI conventions' noun table has a parallel row" \
  "$(grep '^| `parallel`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`show`'
