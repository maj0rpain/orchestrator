# --- repo show ----------------------------------------------------------------
# The GitHub repo orch.sh works on (#520): GH_REPO when the caller set it, else
# the checkout's origin - never gh's own default, which in a fork is upstream.
echo
echo "repo show"
new_repo >/dev/null
unset GH_REPO
assert_eq "a fresh test repo resolves to its github.com origin" \
  "$("$ORCH" repo show)" "o/r (origin)"
for url in https://github.com/acme/widgets.git https://github.com/acme/widgets \
           git@github.com:acme/widgets.git git@github.com:acme/widgets \
           ssh://git@github.com/acme/widgets.git ssh://git@github.com/acme/widgets; do
  git remote set-url origin "$url"
  assert_eq "origin $url resolves to acme/widgets" "$("$ORCH" repo show --name)" "acme/widgets"
done
for url in https://ghe.example.com/acme/widgets.git git@ghe.example.com:acme/widgets \
           ssh://git@ghe.example.com/acme/widgets.git; do
  git remote set-url origin "$url"
  assert_eq "origin $url keeps its host" "$("$ORCH" repo show --name)" "ghe.example.com/acme/widgets"
done
git remote set-url origin https://github.com/acme/widgets.git
assert_eq "GH_REPO wins over origin" "$(GH_REPO=fork/widgets "$ORCH" repo show)" "fork/widgets (GH_REPO)"
assert_eq "repo show --name prints GH_REPO bare" \
  "$(GH_REPO=fork/widgets "$ORCH" repo show --name)" "fork/widgets"
assert_eq "repo show names origin as the source" "$("$ORCH" repo show)" "acme/widgets (origin)"
out="$("$ORCH" repo show extra 2>&1)"; st=$?
assert_status "repo show refuses a stray argument" "$st" 1
assert_eq "naming both of its flags" "$out" "orch: usage: orch.sh repo show [--name|--host]"
out="$("$ORCH" repo show --name --host 2>&1)"; st=$?
assert_status "repo show refuses both flags at once" "$st" 1
assert_eq "repo show --host prints github.com for an OWNER/REPO repo" \
  "$("$ORCH" repo show --host)" "github.com"
assert_eq "repo show --host prints the explicit host of a HOST/OWNER/REPO repo" \
  "$(GH_REPO=ghe.example.com/fork/widgets "$ORCH" repo show --host)" "ghe.example.com"
git remote set-url origin git@ghe.example.com:acme/widgets.git
assert_eq "repo show --host reads the host from origin too" \
  "$("$ORCH" repo show --host)" "ghe.example.com"
git remote set-url origin https://github.com/acme/widgets.git
assert_contains "help lists --host under repo show" "$("$ORCH" help)" "repo show [--name|--host]"

# No GH_REPO and no usable origin: local commands still work, repo show fails.
git remote remove origin
"$ORCH" init norepo >/dev/null 2>&1
out="$("$ORCH" state get phase 2>&1)"; st=$?
assert_status "state get works with no repo to resolve" "$st" 0
for args in "" "--name" "--host"; do
  err="$(mktemp)"
  label="repo show${args:+ $args}"
  # shellcheck disable=SC2086 # an empty args is no argument at all, and "a b" is two
  out="$("$ORCH" repo show $args 2>"$err")"; st=$?
  assert_status "$label exits 1 with no repo" "$st" 1
  assert_eq "$label prints nothing on stdout with no repo" "$out" ""
  assert_eq "$label dies with the repo remedy" "$(cat "$err")" \
    "orch: $repo_remedy"
  rm -f "$err"
done
git remote add origin https://example.invalid/notgithub
out="$("$ORCH" repo show 2>/dev/null)"; st=$?
assert_status "an origin with no owner/name path does not resolve" "$st" 1

# --- default-branch ---------------------------------------------------------
# The base every feature branch forks from. Getting this wrong is silent: work
# lands on top of the wrong branch and nothing complains until review.
echo
echo "default-branch"
new_repo >/dev/null

# GitHub's answer comes from the store-backed fake (fake_default_branch); a
# store with none seeded is a repo gh cannot answer for.
fake_github

# origin/HEAD is a local pointer frozen at clone time; GitHub's answer must win.
git remote set-url origin https://example.invalid/x/y.git
git checkout -q -b some-feature
git update-ref refs/remotes/origin/some-feature HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
fake_default_branch $'trunk\n'
assert_eq "prefers GitHub's answer over a stale origin/HEAD" "$("$ORCH" default-branch)" "trunk"
rm -f "$ORCH_GH_FAKE_STORE/default_branch"
assert_eq "falls back to origin/HEAD when gh cannot answer" "$("$ORCH" default-branch)" "some-feature"
git symbolic-ref -d refs/remotes/origin/HEAD
assert_eq "falls back to main when nothing else answers" "$("$ORCH" default-branch)" "main"

# A tool manager's shim (mise) can print a status line on stdout around gh's
# own answer (#465). Neither a two-line answer nor a failed gh's output may
# become the default branch: only a valid branch name is ever resolved.
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
fake_default_branch $'mise ~/.config/mise/config.toml tools: gh@2.102.0\ntrunk\n'
assert_eq "falls back past a gh answer polluted by a banner line" "$("$ORCH" default-branch)" "some-feature"
fake_default_branch $'trunk\n'
fake_fail adapter_repo_default_branch
assert_eq "ignores the output of a gh that failed" "$("$ORCH" default-branch)" "some-feature"
fake_unfail
fake_default_branch $'\n'
assert_eq "an empty name from gh is no valid branch name" "$("$ORCH" default-branch)" "some-feature"
rm -f "$ORCH_GH_FAKE_STORE/default_branch"
git update-ref refs/remotes/origin/-dash HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/-dash
assert_eq "falls back to main past an origin/HEAD that is no valid branch name" \
  "$("$ORCH" default-branch)" "main"
git symbolic-ref -d refs/remotes/origin/HEAD
git update-ref -d refs/remotes/origin/-dash
restore_suite_env

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

# --sha prints the default SHA: the full SHA of origin/<default> as it stands,
# without fetching - the remote-tracking tip the last fetch set.
new_repo >/dev/null
git checkout -q -B main
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q origin main
git fetch -q origin
fake_github
fake_default_branch $'main\n'
fetched_tip="$(git rev-parse HEAD)"
out="$("$ORCH" default-branch --sha 2>&1)"; st=$?
assert_status "--sha succeeds" "$st" 0
assert_eq "--sha prints the remote-tracking tip's full SHA" "$out" "$fetched_tip"
moved="$(git -C "$bare" -c user.email=test@example.com -c user.name=Test commit-tree "main^{tree}" -p main -m "moved on")"
git -C "$bare" update-ref refs/heads/main "$moved"
assert_ne "the remote's tip has moved on" "$(git -C "$bare" rev-parse main)" "$fetched_tip"
assert_eq "--sha does not fetch: a remote tip that moved since is not reported" \
  "$("$ORCH" default-branch --sha 2>&1)" "$fetched_tip"
assert_eq "and the remote-tracking ref is left where it was" "$(git rev-parse origin/main)" "$fetched_tip"
assert_eq "plain default-branch still prints the name" "$("$ORCH" default-branch 2>&1)" "main"
git update-ref -d refs/remotes/origin/main
out="$("$ORCH" default-branch --sha 2>&1)"; st=$?
assert_status "--sha fails when the remote-tracking ref is missing" "$st" 1
assert_contains "naming the ref" "$out" "refs/remotes/origin/main"
for arg in --name extra; do
  out="$("$ORCH" default-branch "$arg" 2>&1)"; st=$?
  assert_status "refuses any argument but --sha ($arg)" "$st" 1
  assert_eq "with its usage ($arg)" "$out" "orch: usage: orch.sh default-branch [--sha]"
done
out="$("$ORCH" default-branch --sha extra 2>&1)"; st=$?
assert_status "refuses an argument after --sha" "$st" 1
assert_eq "with its usage" "$out" "orch: usage: orch.sh default-branch [--sha]"
restore_suite_env
