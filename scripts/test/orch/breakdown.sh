# shellcheck shell=bash
# The guard below is never true - it only points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# breakdown_fixture: a healthy_repo with the fake GitHub, issue 50 open, the
# next issue 100, and a three-ticket draft in the global draft: 2 is blocked by
# 1, 3 by 2 and 1. Ends with restore_suite_env in the caller.
breakdown_fixture() {
  healthy_repo
  fake_github
  fake_issue 50 open
  fake_next_issue 100
  draft="$(mktemp)"
  cat >"$draft" <<'DRAFT'
@@ ticket 1 First
Body one.
@@ end
@@ ticket 2 Second
@@ blocked-by 1
Body two.
@@ end
@@ ticket 3 Third
@@ blocked-by 2,1
Body three.
@@ end
DRAFT
}

# --- breakdown publish -------------------------------------------------------
echo
echo "breakdown publish"
breakdown_fixture
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "publishes a first run" "$st" 0
assert_eq "printing the numbers in publishing order" "$out" $'100\n101\n102'
assert_eq "saves the draft" "$(cat .orchestrator/breakdown/50/draft.md)" "$(cat "$draft")"
assert_eq "links every ticket" "$(fake_sub_issues_of 50)" "100 101 102"
assert_eq "maps blockers to published numbers" "$(fake_blockers_of 102)" "100 101"
assert_eq "the marker is written" "$(on_disk .orchestrator/breakdown/50/published)" "present"
assert_eq "state is complete" "$("$ORCH" breakdown state 50)" "complete"
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_eq "a rerun creates nothing more" "$(fake_sub_issues_of 50)" "100 101 102"
restore_suite_env

breakdown_fixture
fake_fail_after adapter_sub_issue_link 1
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a failed link dies" "$st" 1
assert_contains "naming the draft position" "$out" "ticket 2 of the draft"
assert_contains "naming the write" "$out" "gh could not link ticket #101"
assert_eq "no marker" "$(on_disk .orchestrator/breakdown/50/published)" "absent"
assert_eq "the recorded numbers are kept" "$(paste -sd ';' .orchestrator/breakdown/50/numbers)" "1 100 created;1 100 linked;2 101 created"
assert_eq "state is partial" "$("$ORCH" breakdown state 50)" "partial"
fake_unfail
other="$(mktemp)"
printf '@@ ticket 1 Other\nx\n@@ end\n' >"$other"
out="$("$ORCH" breakdown publish 50 "$other" 2>&1)"; st=$?
assert_status "the rerun finishes" "$st" 0
assert_eq "from the saved draft, not the file given, linking rather than creating again" "$out" $'100\n101\n102'
assert_eq "all three linked" "$(fake_sub_issues_of 50)" "100 101 102"
assert_eq "the unlinked ticket got its edge" "$(fake_blockers_of 101)" "100"
assert_eq "marker written" "$(on_disk .orchestrator/breakdown/50/published)" "present"
restore_suite_env

# A ticket created whose link already landed: the resume finds it listed and
# attempts no link (the fake's link is made to fail).
breakdown_fixture
printf '@@ ticket 1 Only\nx\n@@ end\n' >"$draft"
fake_fail adapter_sub_issue_link
"$ORCH" breakdown publish 50 "$draft" >/dev/null 2>&1
fake_unfail
mkdir -p "$ORCH_GH_FAKE_STORE/subs" && echo 100 >>"$ORCH_GH_FAKE_STORE/subs/50"
fake_fail adapter_sub_issue_link
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a resume of an already-linked ticket succeeds without linking again" "$st" 0
fake_unfail
restore_suite_env

# A resume adds only the blocking edges a ticket lacks: ticket 3's first edge
# landed before the first run died, so the rerun, allowed one blocker add,
# adds just the missing one.
breakdown_fixture
fake_fail_after adapter_blocker_add 2
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a failed edge add dies" "$st" 1
assert_contains "naming the draft position" "$out" "ticket 3 of the draft"
assert_eq "ticket 3 is recorded created" "$(tail -n1 .orchestrator/breakdown/50/numbers)" "3 102 created"
fake_unfail
fake_fail_after adapter_blocker_add 1
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a resume with part of the edges present adds only the missing one" "$st" 0
fake_unfail
assert_eq "ticket 3 ends with its full blocker set" "$(fake_blockers_of 102)" "100 101"
assert_eq "marker written" "$(on_disk .orchestrator/breakdown/50/published)" "present"
restore_suite_env

# A ticket whose link and every edge landed but whose linked record did not:
# the resume writes no edge (the fake's blocker add is made to fail).
breakdown_fixture
"$ORCH" breakdown publish 50 "$draft" >/dev/null 2>&1
sed -i '$d' .orchestrator/breakdown/50/numbers
rm -f .orchestrator/breakdown/50/published
fake_fail adapter_blocker_add
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a resume with every edge present writes no edge" "$st" 0
fake_unfail
assert_eq "ticket 3 is recorded linked" "$(tail -n1 .orchestrator/breakdown/50/numbers)" "3 102 linked"
restore_suite_env

# A failed blocker read dies before any add, naming the ticket.
breakdown_fixture
fake_fail_after adapter_blockers 1
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a failed blocker read dies" "$st" 1
assert_contains "naming the draft position" "$out" "ticket 2 of the draft"
assert_contains "naming the read" "$out" "read ticket #101's blockers"
fake_unfail
assert_eq "no edge for ticket 2" "$(fake_blockers_of 101)" ""
assert_eq "ticket 2 is recorded created" "$(tail -n1 .orchestrator/breakdown/50/numbers)" "2 101 created"
restore_suite_env

breakdown_fixture
fake_fail adapter_issue_create
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a failed create dies" "$st" 1
assert_contains "naming the draft position" "$out" "ticket 1 of the draft"
assert_eq "no marker" "$(on_disk .orchestrator/breakdown/50/published)" "absent"
fake_unfail
restore_suite_env

breakdown_fixture
printf '@@ ticket 1 A\n@@ blocked-by 2\nx\n@@ end\n@@ ticket 2 B\n@@ blocked-by 1\ny\n@@ end\n' >"$draft"
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a cycle is refused" "$st" 1
assert_eq "saving nothing" "$(on_disk .orchestrator/breakdown/50)" "absent"
restore_suite_env

# Escaped grammar lines (#1945): one leading backslash is removed from a body
# line of \*@@, and a stray unescaped @@ line dies naming itself.
breakdown_fixture
cat >"$draft" <<'DRAFT'
@@ ticket 1 First
\@@ blocked-by 1
\@@ end
\@@ ticket 9 x
\\@@ x
\a @@ y
@@x
@@-1
@@ end
@@ ticket 2 Second
Two.
@@ end
DRAFT
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "escaped grammar lines publish" "$st" 0
assert_eq "two tickets, no more" "$(fake_sub_issues_of 50)" "100 101"
assert_eq "no blocking edge from an escaped blocked-by" "$(fake_blockers_of 100)" ""
body="$(fake_body_of 100)"
assert_contains "unescaped grammar lines" "$body" $'@@ blocked-by 1\n@@ end\n@@ ticket 9 x\n'
assert_contains "double backslash loses one" "$body" $'\n\\@@ x\n'
assert_contains "backslash not before @@ stays" "$body" $'\n\\a @@ y\n@@x\n@@-1'
restore_suite_env

breakdown_fixture
printf '@@ ticket 1 A\nok\n@@ end\n@@ ticket 2 B\n@@ note hi\n@@ end\n' >"$draft"
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a stray @@ line dies" "$st" 1
assert_contains "naming the line" "$out" "line 5"
assert_contains "with the escape hint" "$out" ' - a body line starting with @@ is written \@@'
assert_eq "publishing nothing" "$(fake_issues)" "50 "
restore_suite_env

breakdown_fixture
printf '@@ ticket 1 A\nok\n@@ end\n@@ ticket 2 B\n@@ ticket 3 C\n@@ end\n' >"$draft"
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "@@ ticket in an unfinished block dies" "$st" 1
assert_contains "naming the line" "$out" "line 5"
assert_contains "with the escape hint" "$out" ' - a body line starting with @@ is written \@@'
assert_eq "publishing nothing" "$(fake_issues)" "50 "
restore_suite_env

# CRLF drafts (#2579): the parser strips a trailing CR from every line, so a
# CRLF draft publishes as its LF form does, with no CR in a title or body.
breakdown_fixture
printf '@@ ticket 1 Alpha\r\nBody line.\r\n\\@@ end\r\n@@ end\r\n\r\n@@ ticket 2 Beta\r\n@@ blocked-by 1\r\nBeta body.\r\n@@ end\r\n' >"$draft"
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a CRLF draft publishes" "$st" 0
assert_eq "printing the numbers in publishing order" "$out" $'100\n101'
assert_eq "maps the CRLF blocker to its published number" "$(fake_blockers_of 101)" "100"
assert_eq "no CR in any title or body" "$(printf '%s%s%s%s' "$(fake_title_of 100)" "$(fake_body_of 100)" "$(fake_title_of 101)" "$(fake_body_of 101)" | grep -c $'\r')" "0"
assert_eq "the CRLF title is clean" "$(fake_title_of 100)" "Alpha"
assert_contains "the escaped line is published unescaped" "$(fake_body_of 100)" $'Body line.\n@@ end'
restore_suite_env

breakdown_fixture
printf '@@ ticket 1 A\nok\n@@ foo\n@@ end\n' >"$draft"
lf_out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
printf '@@ ticket 1 A\r\nok\r\n@@ foo\r\n@@ end\r\n' >"$draft"
crlf_out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; crlf_st=$?
assert_status "a stray @@ line in an LF draft dies" "$st" 1
assert_status "a stray @@ line in a CRLF draft dies" "$crlf_st" 1
assert_contains "naming the stray line" "$crlf_out" "stray grammar line inside ticket"
assert_eq "the LF and CRLF messages are identical" "$crlf_out" "$lf_out"
assert_eq "the CRLF message has no CR" "$(printf '%s' "$crlf_out" | grep -c $'\r')" "0"
restore_suite_env

breakdown_fixture
printf '@@ ticket 1 First\r\nOne.\r\n@@ end\r\n@@ ticket 2 Second\r\n@@ blocked-by 1\r\nTwo.\r\n@@ end\r\n' >"$draft"
fake_fail_after adapter_sub_issue_link 1
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "a CRLF draft's first publish dies partway" "$st" 1
assert_eq "the saved draft keeps its CRs byte for byte" "$(cmp .orchestrator/breakdown/50/draft.md "$draft" && echo same)" "same"
fake_unfail
out="$("$ORCH" breakdown publish 50 "$draft" 2>&1)"; st=$?
assert_status "the rerun on the saved CRLF draft finishes" "$st" 0
assert_eq "both tickets linked" "$(fake_sub_issues_of 50)" "100 101"
assert_eq "no CR in any title or body after the resume" "$(printf '%s%s%s%s' "$(fake_title_of 100)" "$(fake_body_of 100)" "$(fake_title_of 101)" "$(fake_body_of 101)" | grep -c $'\r')" "0"
restore_suite_env

# --- breakdown state ---------------------------------------------------------
echo
echo "breakdown state"
breakdown_fixture
out="$("$ORCH" breakdown state 50 2>&1)"; st=$?
assert_status "no draft, no sub-issues: succeeds" "$st" 0
assert_eq "none" "$out" "none"
fake_issue 60 open
"$ORCH" ticket publish 50 "T" "$draft" >/dev/null 2>&1
out="$("$ORCH" breakdown state 50 2>&1)"
assert_eq "falls back to ticket exists with no draft" "$out" "complete"
fake_fail adapter_sub_issues
out="$("$ORCH" breakdown state 50 2>&1)"; st=$?
assert_status "a failed read exits 2" "$st" 2
fake_unfail
restore_suite_env
