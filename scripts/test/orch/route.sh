# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- route show ---------------------------------------------------------------
# The default route: the git config key orchestrator.route, read here alone so
# the interview's Closing never calls git config itself.
echo
echo "route show"
new_repo >/dev/null

out="$("$ORCH" route show 2>&1)"; st=$?
assert_status "route show succeeds with orchestrator.route unset" "$st" 0
assert_eq "the route is none when orchestrator.route is unset" "$out" "none"

git config orchestrator.route ""
out="$("$ORCH" route show 2>&1)"; st=$?
assert_status "route show succeeds with an empty value" "$st" 0
assert_eq "an empty value reads as none" "$out" "none"

for v in flow quick blueprint autopilot; do
  git config orchestrator.route "$v"
  out="$("$ORCH" route show 2>&1)"; st=$?
  assert_status "route show succeeds with $v set locally" "$st" 0
  assert_eq "the local value $v is printed" "$out" "$v"
done

git config --unset-all orchestrator.route
git config --global orchestrator.route quick
assert_eq "a global value with no local one is printed" "$("$ORCH" route show 2>&1)" "quick"
git config orchestrator.route blueprint
assert_eq "the local value wins over the global one" "$("$ORCH" route show 2>&1)" "blueprint"
git config --global --unset-all orchestrator.route
git config --unset-all orchestrator.route

git config orchestrator.route sideways
out="$("$ORCH" route show 2>&1)"; st=$?
assert_status "route show dies on an unknown value" "$st" 1
assert_contains "naming the key" "$out" "orchestrator.route"
assert_contains "the value" "$out" "sideways"
assert_contains "the four words" "$out" "flow, quick, blueprint or autopilot"
assert_contains "and the git config remedy" "$out" "git config orchestrator.route <route>"
git config --unset-all orchestrator.route

out="$("$ORCH" route show extra 2>&1)"; st=$?
assert_status "route show refuses an argument" "$st" 1
assert_contains "with its usage line" "$out" "usage: orch.sh route show"
out="$("$ORCH" route bogus 2>&1)"; st=$?
assert_status "route bogus is an unknown op" "$st" 1
assert_contains "with the unknown-op message" "$out" "unknown route op"

out="$("$ORCH" help 2>&1)"
assert_contains "route show is in the usage text" "$out" "route show"
assert_contains "How it works has a Default route subsection" \
  "$(grep '^### Default route' "$PLUGIN_ROOT/docs/how-it-works.md")" "Default route"
