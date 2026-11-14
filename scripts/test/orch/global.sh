# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- slug -------------------------------------------------------------------
# The same normalisation init applies to its own slug argument, exposed as a
# primitive so the quick-implement skill can call it instead of restating the
# algorithm as prose.
echo
echo "slug"
new_repo >/dev/null
assert_eq "matches init's own normalisation" "$("$ORCH" slug "My Feature!!")" "my-feature"
out="$("$ORCH" slug "!!!" 2>&1)"; st=$?
assert_status "refuses a slug empty after normalisation" "$st" 1
assert_contains "explains why" "$out" "empty after normalisation"
out="$("$ORCH" slug 2>&1)"; st=$?
assert_status "refuses no argument at all" "$st" 1

# --- archive ----------------------------------------------------------------
echo
echo "archive"
fake_flow my-feature
h="$("$ORCH" handoff path spec)"
complete_handoff "$h"
dest="$("$ORCH" archive)"
assert_contains "archive path carries the slug" "$dest" "my-feature"
assert_eq "archive names its directory <YYYYMMDD-HHMMSS>-<slug>" \
  "$(printf '%s\n' "$dest" | grep -c '^\.orchestrator/archive/[0-9]\{8\}-[0-9]\{6\}-my-feature$')" "1"
assert_eq "live state is cleared" "$(on_disk .orchestrator/state.json)" "absent"
assert_eq "handoff is preserved under archive/" \
  "$(on_disk "$dest/handoff/01-plan.md")" "present"
out="$("$ORCH" status 2>&1)"
assert_contains "status reports no active flow afterwards" "$out" "No active flow"
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "a new flow can start after archiving" "$st" 0

# #622: moving a ticket worktree would break git's record of it, so archive
# refuses while any is left under this checkout, naming each, and moves nothing.
new_repo >/dev/null
"$ORCH" init my-feature >/dev/null
git checkout -q -b orch/1-my-feature
top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 4 >/dev/null
"$ORCH" ticket-worktree add 5 >/dev/null
out="$("$ORCH" archive 2>&1)"; st=$?
assert_status "archive refuses while a ticket worktree exists" "$st" 1
assert_contains "naming the first" "$out" "$top/.orchestrator/worktrees/t4"
assert_contains "naming the second" "$out" "$top/.orchestrator/worktrees/t5"
assert_contains "with ticket-worktree remove as the remedy" "$out" "ticket-worktree remove"
assert_eq "and moves nothing: the state stays" \
  "$(on_disk .orchestrator/state.json)" "present"
assert_eq "no archive directory is made" \
  "$(on_disk .orchestrator/archive)" "absent"
assert_eq "the ticket worktrees stay where git recorded them" \
  "$(git -C .orchestrator/worktrees/t4 rev-parse --show-toplevel)" "$top/.orchestrator/worktrees/t4"
"$ORCH" ticket-worktree remove 4
"$ORCH" ticket-worktree remove 5
out="$("$ORCH" archive)"; st=$?
assert_status "with the ticket worktrees removed, archive moves the flow as before" "$st" 0
assert_eq "live state is cleared" "$(on_disk .orchestrator/state.json)" "absent"
restore_suite_env

# --- mp-skill ---------------------------------------------------------------
# The plugin reads no upstream skill any more (ADR-0028), so the resolver is
# gone.
echo
echo "mp-skill"
new_repo >/dev/null
out="$("$ORCH" mp-skill to-spec 2>&1)"; st=$?
assert_status "mp-skill is an unknown command" "$st" 1
assert_contains "and says so" "$out" "unknown command: mp-skill"

# --- bash version guard -----------------------------------------------------
# orch.sh checks the running bash before it sources anything. The version is
# faked through ORCH_BASH_VERSION, so no bash 3.2 is needed on the machine.
echo
echo "bash version guard"
guard_repo="$(new_repo)"
guard_plain="$(mktemp -d)"
guard_unfaked="$(cd "$guard_repo" && "$ORCH" help 2>&1)"
guard_line_for() { echo "orch: bash $1 is too old - orch.sh needs bash 4.2 or newer: brew install bash"; }
for guard_ver in 3.2 4.1; do
  guard_line="$(guard_line_for "$guard_ver")"
  for guard_cmd in doctor help; do
    guard_out="$(cd "$guard_repo" && ORCH_BASH_VERSION=$guard_ver bash "$ORCH" "$guard_cmd" 2>"$guard_plain/err")"; st=$?
    assert_status "bash $guard_ver stops $guard_cmd with status 1" "$st" 1
    assert_eq "bash $guard_ver $guard_cmd names the version on stderr" "$(cat "$guard_plain/err")" "$guard_line"
    assert_eq "bash $guard_ver $guard_cmd prints nothing on stdout" "$guard_out" ""
  done
  guard_out="$(cd "$guard_plain" && ORCH_BASH_VERSION=$guard_ver bash "$ORCH" help 2>"$guard_plain/err")"; st=$?
  assert_status "bash $guard_ver outside a repo stops with status 1" "$st" 1
  assert_eq "bash $guard_ver outside a repo wins over the repository stop" "$(cat "$guard_plain/err")" "$guard_line"
  assert_eq "bash $guard_ver outside a repo prints nothing on stdout" "$guard_out" ""
done
for guard_ver in 4.2 5.0 10.0 ""; do
  guard_out="$(cd "$guard_repo" && ORCH_BASH_VERSION=$guard_ver bash "$ORCH" help 2>"$guard_plain/err")"; st=$?
  assert_status "bash '$guard_ver' passes the guard" "$st" 0
  assert_eq "bash '$guard_ver' prints nothing on stderr" "$(cat "$guard_plain/err")" ""
  assert_eq "bash '$guard_ver' prints the usual help" "$guard_out" "$guard_unfaked"
done

# The entry script alone, none of its sourced files beside it.
cp "$ORCH" "$guard_plain/orch.sh"
guard_out="$(cd "$guard_plain" && ORCH_BASH_VERSION=3.2 bash ./orch.sh help 2>"$guard_plain/err")"; st=$?
assert_status "a lone entry script stops with status 1" "$st" 1
assert_eq "a lone entry script prints the guard's line, not a missing file" \
  "$(cat "$guard_plain/err")" \
  "$(guard_line_for 3.2)"

# Sourced: the child stops, so the statement after the source line never runs.
guard_out="$(cd "$guard_repo" && ORCH_BASH_VERSION=3.2 bash -c 'source "$1"; echo after-source' _ "$ORCH" 2>"$guard_plain/err")"; st=$?
assert_status "a sourced orch.sh stops its shell with status 1" "$st" 1
assert_eq "a sourced orch.sh prints the guard's line" "$(cat "$guard_plain/err")" \
  "$(guard_line_for 3.2)"
assert_eq "a sourced orch.sh never reaches the next statement" "$guard_out" ""
