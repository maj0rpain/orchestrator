# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- trust module -----------------------------------------------------------
# The Trust module's own rules: which associations its comment filter keeps,
# the issue check by the author's association, and the attended reads'
# warning. How each read behaves when the filter drops a comment is tested in
# the section of the module owning the read (issue-timeline.sh, ...). The
# comment filter is read directly, through the Comments module's read of a
# PR's comments (comments_trusted_read pr), and the issue check and its
# warning through `init --issue`.
echo
echo "trust module"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec
# tr_comments_read: PR #9's comments as the comment filter keeps them, the
# array comments_trusted_read pr assigns, on stdout; the filter's stderr line
# left as it is.
tr_comments_read() {
  # shellcheck disable=SC2016
  sourced_orch eval 'comments_trusted_read pr 9 tr_kept tr_why; printf "%s" "$tr_kept"'
}

tr_assocs_trusted="OWNER MEMBER COLLABORATOR"
tr_assocs_untrusted="CONTRIBUTOR FIRST_TIME_CONTRIBUTOR FIRST_TIMER MANNEQUIN NONE"

# The comment filter's associations: one comment per association on PR #9,
# read once; a kept one is in the array the read assigns. The Issue timeline's
# section covers how timeline_read uses the filter.
fake_pr 9 open topic main
tr_i=0
for assoc in $tr_assocs_trusted $tr_assocs_untrusted; do
  tr_i=$((tr_i + 1))
  fake_pr_comment 9 "user$tr_i" "2026-09-0${tr_i}T10:00:00Z" "written by $assoc" "$assoc"
done
tr_file="$(mktemp)"
tr_text="$(tr_comments_read 2>"$tr_file")"
tr_err="$(cat "$tr_file")"
for assoc in $tr_assocs_trusted; do
  assert_contains "a $assoc comment is kept" "$tr_text" "written by $assoc"
done
for assoc in $tr_assocs_untrusted; do
  assert_not_contains "a $assoc comment is dropped" "$tr_text" "written by $assoc"
done
assert_eq "and the dropped ones are reported once, naming the PR" "$tr_err" \
  'orch: ignored 5 comment(s) from untrusted authors on #9'

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

# The JSON array the filter hands jq is built as the module loads, on an empty
# PATH, so it starts no process.
tr_json="$(PATH='' "$BASH" -c 'source "$1/scripts/orch/trust.sh"; printf "%s" "$TRUST_ASSOCIATIONS_JSON"' _ "$PLUGIN_ROOT")"
assert_eq "the array is built at load, with no process on PATH" "$tr_json" '["OWNER", "MEMBER", "COLLABORATOR"]'

# The comment filter and the issue check agree on a lower-case association and
# an empty one (the trusted ones and NONE are asserted above).
fake_pr 9 open topic main
fake_pr_comment 9 someone "2026-09-01T10:00:00Z" "said by owner" owner
fake_pr_comment 9 someone "2026-09-02T10:00:00Z" "said by empty" ""
printf '\n' >"$ORCH_GH_FAKE_STORE/prs/9/comments/2/association"
tr_case_text="$(tr_comments_read 2>/dev/null)"
for tr_a in owner ""; do
  tr_label="${tr_a:-empty}"
  tr_kept=no; [[ "$tr_case_text" != *"said by $tr_label"* ]] || tr_kept=yes
  tr_checked=no; [ -n "$(tr_fetch stranger "$tr_a")" ] || tr_checked=yes
  assert_eq "association '$tr_label': the filter and the issue check agree" "$tr_kept" "$tr_checked"
  assert_eq "association '$tr_label' is not trusted" "$tr_kept" no
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
# them. The commands using it (side-checkout.sh, autopilot.sh) test only their
# own exit codes and verdicts.
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
