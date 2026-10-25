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
