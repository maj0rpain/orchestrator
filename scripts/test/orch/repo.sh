# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# new_repo_with_origin [branch]: new_repo, plus tracking refs for its origin:
# origin/<branch> (default: the checked-out branch) set to HEAD, and
# origin/HEAD pointing at it. Call it in the current shell, never inside $(...):
# new_repo cd's.
new_repo_with_origin() {
  new_repo >/dev/null
  local b="${1:-$(git branch --show-current)}"
  git update-ref "refs/remotes/origin/$b" HEAD
  git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$b"
}

# --- no repo to resolve ------------------------------------------------------
# The repo and default-branch nouns are Python (orch/repo.py, orch/base.py),
# tested in pytest; the bash repo pin is still read by the bash nouns, which
# must not need a repo for a local command.
echo
echo "no repo to resolve"
new_repo >/dev/null
# No GH_REPO and no usable origin: local commands still work.
git remote remove origin
"$ORCH" init norepo >/dev/null 2>&1
"$ORCH" state get phase >/dev/null 2>&1; st=$?
assert_status "state get works with no repo to resolve" "$st" 0

# --- a tool manager's banner (#465) -------------------------------------------
# A tool manager's shim (mise) can print a status line on stdout around gh's
# own answer: orch.sh silences it, and init's default-branch read never takes
# a polluted answer for a branch.
echo
echo "a tool manager's banner (#465)"
new_repo >/dev/null
# MISE_QUIET reaches every process orch.sh runs, the gh binary included, so a
# child process of orch.sh's own shell sees it.
assert_eq "gh run from orch.sh sees MISE_QUIET=1" \
  "$(env -u MISE_QUIET bash -c 'source "$1"; command printenv MISE_QUIET' _ "$ORCH")" "1"

# origin/HEAD names a branch that is not `main`, so an origin/HEAD fallback
# cannot pass for the final literal-`main` one.
new_repo_with_origin some-feature
fake_github
export GH_REPO=acme/widgets
fake_default_branch $'mise ~/.config/mise/config.toml tools: gh@2.102.0\ntrunk\n'
"$ORCH" init banner >/dev/null
recorded="$("$ORCH" state get base)"
assert_eq "init records origin/HEAD's branch as the base" "$recorded" "some-feature"
restore_suite_env
