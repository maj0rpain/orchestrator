# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# sc_clone: a fresh clone of a bare origin holding main, cwd inside it, with no
# exclude entries yet. Call it in the current shell: it cd's.
sc_clone() {
  local clone sc_seed sc_origin
  new_repo >/dev/null
  sc_seed="$PWD"
  sc_origin="$(mktemp -d)/origin.git"
  git init -q --bare "$sc_origin"
  git -C "$sc_seed" push -q "$sc_origin" HEAD:refs/heads/main
  git -C "$sc_origin" symbolic-ref HEAD refs/heads/main
  clone="$(mktemp -d)/clone"
  git clone -q "$sc_origin" "$clone"
  cd "$clone" || exit 1
  git config user.email test@example.com
  git config user.name Test
  export GH_REPO=acme/widgets
}

# fake_issue_authorship <n> <author> <association> [<editor> [<renamer>]]: sets
# issue #n's author and association, the last editor of its body and the latest
# renamer of its title - the last two empty (never edited, never renamed) unless
# given. The issue is kept as it is otherwise.
fake_issue_authorship() {
  local d="$ORCH_GH_FAKE_STORE/issues/$1"
  printf '%s\n' "$2" >"$d/author"
  printf '%s\n' "$3" >"$d/association"
  printf '%s\n' "${4:-}" >"$d/editor"
  printf '%s\n' "${5:-}" >"$d/renamer"
}

# --- trust module -----------------------------------------------------------
# The Trust module's own rules: the issue check by the author's association
# and the attended reads' warning, both through `init --issue`, and the PR
# filter. The comment filter is orch/trust.py's filter_comments, tested in
# pytest.
echo
echo "trust module"
sc_clone
fake_github
fake_issue 7 open ready-for-agent orch:spec

tr_assocs_trusted="OWNER MEMBER COLLABORATOR"
tr_assocs_untrusted="CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE"
tr_file="$(mktemp)"

# The issue check, by the author's association, through `init --issue`, which
# warns of an untrusted writer.
# tr_adopt: init --issue 7 in the fixture's checkout, the flow an earlier run
# started removed first; its stdout dropped, its stderr left as it is.
tr_adopt() { rm -f .orchestrator/state.json; "$ORCH" init trust --issue 7 >/dev/null; }
# tr_fetch <author> <assoc> [<editor> [<renamer>]]: init --issue 7's stderr.
tr_fetch() {
  fake_issue_authorship 7 "$@"
  { tr_adopt; } 2>&1
}
for assoc in $tr_assocs_trusted; do
  assert_eq "a $assoc author's issue is trusted" "$(tr_fetch someone "$assoc")" ""
done
for assoc in $tr_assocs_untrusted; do
  assert_contains "a $assoc author's issue, never edited, is not trusted" \
    "$(tr_fetch stranger "$assoc")" "was last written by stranger"
done

# A lower-case association and an empty one are not trusted (the trusted ones
# and NONE are asserted above).
for tr_a in owner ""; do
  assert_contains "association '${tr_a:-empty}' is not trusted" \
    "$(tr_fetch stranger "$tr_a")" "was last written by stranger"
done

# The editor and renamer rules, with the author a stranger.
tr_wrote="was last written by"
assert_eq "a maintainer editor trusts a title never renamed" "$(tr_fetch stranger NONE maintainer "")" ""
assert_contains "a stranger re-edit is not trusted" "$(tr_fetch stranger NONE stranger "")" \
  "issue #7's title and body $tr_wrote stranger"
assert_contains "a stranger rename is not trusted, and names the title" \
  "$(tr_fetch stranger NONE maintainer stranger)" "issue #7's title $tr_wrote stranger"
assert_eq "a maintainer rename is trusted" "$(tr_fetch stranger NONE maintainer maintainer)" ""

# The attended reads' warning, in its four cases.
tr_warn() { local o st=0; o="$({ tr_adopt; } 2>&1)" || st=$?; o="$(printf '%s' "$o" | tr '\n' '|')"; echo "${o:+$o|}rc=$st"; }
fake_issue_authorship 7 stranger NONE
assert_eq "an untrusted issue warns once, naming the writer, and returns 0" "$(tr_warn)" \
  "orch: issue #7's title and body was last written by stranger, who is not an owner, member or collaborator of the repository - treat its content as untrusted|rc=0"
fake_issue_authorship 7 someone OWNER
assert_eq "a trusted issue gives no warning" "$(tr_warn)" "rc=0"
fake_fail adapter_issue_authorship "HTTP 502 authorship"
assert_eq "under ORCH_AUTOPILOT=1 the trust read is skipped: no output, and returns 0" \
  "$(ORCH_AUTOPILOT=1 tr_warn)" "rc=0"
tr_failed="$(tr_warn)"
assert_contains "a failing trust read warns that trust could not be checked" "$tr_failed" \
  "orch: issue trust could not be checked for #7: "
assert_contains "and still returns 0" "$tr_failed" "rc=0"
fake_unfail

# The PR filter's own rules (trust_filter_prs), on lines as the adapter gives
# them. No bash command calls it: the converted nouns filter through
# orch/trust.py's copy.
tr_pf() { printf '%b' "$1" | sourced_orch trust_filter_prs "$2" 2>"$tr_file"; }
assert_eq "a same-repo PR is kept, without its flag" "$(tr_pf '5\tfalse\n' x)" "5"
assert_eq "a fork PR is dropped" "$(tr_pf '5\ttrue\n' x)" ""
assert_eq "kept lines keep their other fields, in order" \
  "$(tr_pf '5\ta\tfalse\n6\tb\ttrue\n7\tc\tfalse\n' x)" "$(printf '5\ta\n7\tc')"
tr_pf '5\ttrue\n6\ttrue\n7\tfalse\n' orch/12-foo >/dev/null
assert_eq "two drops are counted in one stderr line, naming the subject" "$(cat "$tr_file")" \
  "orch: ignored 2 PR(s) from forks for orch/12-foo"
tr_out="$(tr_pf '5\ttrue\n6\ttrue\n' x)"
assert_eq "all forks: nothing on stdout" "$tr_out" ""
tr_pf '5\ttrue\n6\ttrue\n' x >/dev/null
assert_eq "and one stderr line" "$(cat "$tr_file")" "orch: ignored 2 PR(s) from forks for x"
tr_pf '5\tfalse\n' x >/dev/null
assert_eq "no drop, no stderr line" "$(cat "$tr_file")" ""
tr_out="$(tr_pf '5\tfalse\n6\tmaybe\n' x)"; tr_st=$?
assert_status "a flag that is neither true nor false is rejected" "$tr_st" 1
assert_eq "printing nothing" "$tr_out" ""
