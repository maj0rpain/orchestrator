# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

guard_line_for() { echo "orch: bash $1 is too old - orch.sh needs bash 4.2 or newer: brew install bash"; }

# --- mp-skill ---------------------------------------------------------------
# The plugin reads no upstream skill any more (ADR-0028), so the resolver is
# gone.
echo
echo "mp-skill"
new_repo >/dev/null
out="$("$ORCH" mp-skill to-spec 2>&1)"; st=$?
assert_status "mp-skill is an unknown command" "$st" 1
assert_contains "and says so" "$out" "unknown command: mp-skill"

# The plugin measures no suite cost (ADR-0063): the noun is gone.
echo
echo "suite-cost is gone"
out="$("$ORCH" suite-cost run -- true 2>&1)"; st=$?
assert_status "suite-cost is an unknown command" "$st" 1
assert_contains "and says so" "$out" "unknown command: suite-cost"
out="$("$ORCH" help 2>&1)"
assert_not_contains "help names no suite-cost" "$out" "suite-cost"

# --- bash version guard -----------------------------------------------------
# orch.sh checks the running bash before it sources anything. The version is
# faked through ORCH_BASH_VERSION, so no bash 3.2 is needed on the machine.
echo
echo "bash version guard"
guard_repo="$(new_repo)"
guard_plain="$(mktemp -d)"
guard_unfaked="$(cd "$guard_repo" && "$ORCH" help 2>&1)"
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

# --- outside a checkout (#931) ------------------------------------------------
# Run from the suite's own non-repo cwd: the death names the cwd and the
# remedy. It comes before dispatch, so any subcommand reaches it, a converted
# noun's included (test_dispatch.py pins that one). The remedy names the
# checkout OLDPWD resolves to, when it resolves to one (#1523); every case pins
# OLDPWD, so the suite's own leftover never decides it.
echo
echo "outside a checkout (#931)"
outside_repo="$(new_repo)"
git -C "$outside_repo" worktree add -q -b side "$outside_repo-wt" 2>/dev/null
mkdir -p "$outside_repo-wt/sub/dir"
outside_plain="$(mktemp -d)"
cd "$SUITE_CWD" || exit 1
outside_generic="orch: not inside a git repository ($PWD) - cd into the repo's checkout (its root or a worktree) and run orch.sh there; a mktemp path is for files, not the working directory"
err="$(OLDPWD="$outside_repo-wt/sub/dir" bash "$ORCH" status 2>&1 >/dev/null)"; st=$?
assert_status "orch.sh outside a git repository exits 1" "$st" 1
assert_eq "an OLDPWD inside a linked worktree names that worktree's toplevel" "$err" \
  "orch: not inside a git repository ($PWD) - cd into the checkout you came from, $outside_repo-wt, and run orch.sh there; a mktemp path is for files, not the working directory"
err="$(OLDPWD="$outside_plain" bash "$ORCH" status 2>&1 >/dev/null)"; st=$?
assert_status "with an OLDPWD outside any repo, exits 1" "$st" 1
assert_eq "an OLDPWD outside any repo gives the generic remedy" "$err" "$outside_generic"
err="$(OLDPWD='' bash "$ORCH" status 2>&1 >/dev/null)"; st=$?
assert_status "with an empty OLDPWD, exits 1" "$st" 1
assert_eq "an empty OLDPWD gives the generic remedy" "$err" "$outside_generic"
