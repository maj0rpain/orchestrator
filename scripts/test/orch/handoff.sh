# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- handoff path -----------------------------------------------------------
echo
echo "handoff path"
fake_flow handoff-path
assert_contains "spec phase reads the plan handoff"      "$("$ORCH" handoff path spec)"      "01-plan.md"
assert_contains "implement phase reads the spec handoff" "$("$ORCH" handoff path implement)" "02-spec.md"
assert_contains "review phase reads the implement handoff" "$("$ORCH" handoff path review)"  "03-implement.md"

# The review skill consumes this inside command substitutions - `dirname "$(...
# handoff path review)"` - so a phase it cannot resolve has to stop the caller
# rather than hand it the bare handoff directory with a zero status.
out="$("$ORCH" handoff path bogus 2>/dev/null)"; st=$?
assert_status "an unknown phase is an error, not a directory" "$st" 1
assert_eq "and prints no path for a caller to use" "$out" ""
restore_suite_env

# --- handoff validate -------------------------------------------------------
echo
echo "handoff validate"
fake_flow handoff-validate
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "passes a complete handoff" "$st" 0

writeln '## Decisions' 'Use X.' '' '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is missing" "$st" 1
assert_contains "names the missing section" "$out" "Rejected alternatives"

# The high-value case: the section the spec writer is most likely to leave as a
# bare heading, which would let already-killed alternatives get re-proposed.
complete_plan_handoff "$h"
writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is present but empty" "$st" 1
assert_contains "reports it as empty, not missing" "$out" "empty section"

writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '   ' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "treats a whitespace-only section as empty" "$st" 1

# A missing file is reported the way an invalid one is - a FAIL line on stdout
# and exit 1, no die - so a reader of FAIL lines sees what phase advance prints.
out="$("$ORCH" handoff validate "$h.missing" 2>/dev/null)"; st=$?
assert_status "fails on a missing handoff" "$st" 1
assert_eq "reports it as a FAIL line on stdout" "$out" "FAIL  handoff not found: $h.missing"

# Every phase records the host capability fallbacks it used (#127,
# docs/host-capabilities.md), so a human reading any handoff can see where a
# host did less than Claude Code would have. "None." is an answer; no section
# is not.
for p in spec implement review; do
  hf="$("$ORCH" handoff path "$p")"
  case "$p" in
    spec) complete_plan_handoff "$hf" ;;
    implement) complete_spec_handoff "$hf" ;;
    review) complete_implement_handoff "$hf" ;;
  esac
  grep -v '^## Host fallbacks$' "$hf" | grep -v '^None (Claude Code)\.$' >"$hf.tmp" && mv "$hf.tmp" "$hf"
  out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
  assert_status "$(basename "$hf") without Host fallbacks is incomplete" "$st" 1
  assert_contains "$(basename "$hf") names the missing Host fallbacks" "$out" "Host fallbacks"
done
# A flow started before 1.0.0 has no host_fallbacks in state.json and wrote
# its handoffs without the section; upgrading mid-flow must not fail them.
# Raw jq, not state_fixture: deleting keys simulates an older release, and the
# Flow state module has no delete operation - one only tests would use.
st_saved="$(cat .orchestrator/state.json)"
jq 'del(.host_fallbacks)' <<<"$st_saved" >.orchestrator/state.json
out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
assert_status "a pre-1.0.0 flow's handoff validates without Host fallbacks" "$st" 0
printf '%s\n' "$st_saved" >.orchestrator/state.json
complete_plan_handoff "$h"
restore_suite_env

# --- handoff section --------------------------------------------------------
# The review loop's driver reads Rejected alternatives and Deviations through
# this rather than reading whole handoffs, so it has to print exactly one
# section's body and nothing of its neighbours.
echo
echo "handoff section"
fake_flow handoff-section
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff section "$h" "Rejected alternatives" 2>&1)"; st=$?
assert_status "prints a named section" "$st" 0
assert_eq "prints only that section's body" "$out" "Y, because Z."

hi="$("$ORCH" handoff path review)"
complete_implement_handoff "$hi"
assert_eq "reads Deviations out of an implement handoff" \
  "$("$ORCH" handoff section "$hi" Deviations)" "None."

hs="$(mktemp)"
writeln '## Decisions' '' '' 'Use X.' '' 'And Y.' '   ' '' \
        '## Rejected alternatives' '  ' '' \
        '## Constraints' 'Must run offline.' >"$hs"
out="$("$ORCH" handoff section "$hs" Decisions)"
assert_eq "trims leading and trailing blank lines, keeps inner ones" \
  "$out" "$(writeln 'Use X.' '' 'And Y.')"
assert_not_contains "does not bleed into the next section" "$out" "Constraints"
out="$("$ORCH" handoff section "$hs" Constraints)"
assert_eq "reads the last section to end of file" "$out" "Must run offline."

out="$("$ORCH" handoff section "$hs" "Rejected alternatives" 2>&1)"; st=$?
assert_status "a whitespace-only section exits 0" "$st" 0
assert_eq "and prints nothing" "$out" ""
cp "$hs" "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"
assert_contains "handoff validate reports that same section as empty" \
  "$out" "empty section: ## Rejected alternatives"
complete_plan_handoff "$h"

out="$("$ORCH" handoff section "$h" "Open questions" 2>&1)"; st=$?
assert_status "a missing heading is an error" "$st" 1
assert_contains "naming the heading" "$out" "Open questions"

# A handoff with two identical sections is malformed: refuse it rather than
# print both bodies joined as if they were one section (see issue #168).
hd="$(mktemp)"
writeln '## X' 'First.' '## Y' 'Between.' '## X' 'Second.' >"$hd"
out="$("$ORCH" handoff section "$hd" X 2>&1)"; st=$?
assert_status "a repeated heading is an error" "$st" 1
assert_contains "naming the repeated heading and the file" "$out" "repeated section: ## X in $hd"
assert_not_contains "and printing no body" "$out" "First."
assert_not_contains "nor the second body" "$out" "Second."
rm -f "$hd"

# The match is on the whole `## <heading>` line: a prefix is not the section.
out="$("$ORCH" handoff section "$h" "Rejected" 2>&1)"; st=$?
assert_status "a heading prefix does not match" "$st" 1

out="$("$ORCH" handoff section "$hs.missing" Decisions 2>&1)"; st=$?
assert_status "a missing file is an error" "$st" 1
assert_contains "naming the file" "$out" "$hs.missing"

out="$("$ORCH" handoff section "$h" 2>&1)"; st=$?
assert_status "too few arguments is an error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh handoff section <file> <heading>"
out="$("$ORCH" handoff section "$h" Decisions extra 2>&1)"; st=$?
assert_status "too many arguments is an error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh handoff section <file> <heading>"

assert_contains "orch.sh help lists handoff section" "$("$ORCH" help)" "handoff section"
out="$("$ORCH" handoff bogus 2>&1)"
assert_contains "an unknown handoff op lists section" "$out" "want path|validate|section"
rm -f "$hs" "$hi"
restore_suite_env

# --- ticket breakdown handoff ------------------------------------------------
# The spec phase's last step publishes tickets as sub-issues of the spec
# issue, so the handoff that follows it must at least name the parent -
# anything less sends implement's `ticket next` query against nothing.
echo
echo "ticket breakdown handoff"
fake_flow ticket-breakdown
h2="$("$ORCH" handoff path implement)"
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a spec handoff with no ticket breakdown is incomplete" "$st" 1
assert_contains "names the section implement would have read" "$out" "Ticket breakdown"

writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' '   ' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a bare Ticket breakdown heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_spec_handoff "$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "passes once the parent issue is recorded" "$st" 0

# A 0/1-ticket breakdown collapses (issue #99/#101): no sub-issue is published,
# so this section names the spec issue itself via a plain-text sentinel rather
# than a parent whose GitHub sub-issues carry the real tickets. It is covered
# today by the same generic non-empty-section check as any other content -
# named explicitly here so the convention doesn't silently rot.
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' \
        '## Ticket breakdown' 'None: work directly against #1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "the collapsed-case sentinel validates like any other content" "$st" 0

# A spec review of several rounds (#871) puts each round's changelog under a
# `### Round <k> of <n>` subheading, with no `## ` line inside the section,
# since validate reads a section up to the next `## ` line.
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' \
        '### Round 1 of 3' '#### Consolidation' 'None' '#### Tickets' 'None - no ticket breakdown' '' \
        '### Round 2 of 3' '#### Consolidation' 'None' '#### Tickets' 'None - no ticket breakdown' '' \
        '### Round 3 of 3' '#### Consolidation' 'None' '#### Tickets' 'None - no ticket breakdown' '' \
        '## Ticket breakdown' '#1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a Spec review changelog of several ### Round subheadings validates" "$st" 0
restore_suite_env

# --- handoff templates -------------------------------------------------------
# The templates in the orch-handoff skill are what every phase copies, so one
# missing a section handoff validate requires, or with a placeholder left
# empty, would fail every flow at its boundary. Each template block is written
# under its own file name and validated once, against a state that requires
# Host fallbacks: the largest required set. No run without Host fallbacks is
# needed. That set is the same headings minus `## Host fallbacks`, and validate
# fails only on a required heading that is missing or empty, so a template that
# passes the larger set passes the smaller one too. A no-state run would repeat
# this one, since Host fallbacks is required when there is no state file. Its
# own repo keeps this flow's state untouched.
echo
echo "handoff templates"
HANDOFF_SKILL="$PLUGIN_ROOT/skills/orch-handoff/SKILL.md"
tpl_repo="$(new_repo)"
mkdir -p "$tpl_repo/.orchestrator"
printf '{"host_fallbacks": true}\n' >"$tpl_repo/.orchestrator/state.json"
for tpl in 01-plan.md 02-spec.md 03-implement.md; do
  # The markdown fence under the template's `### \`<file>\`` heading.
  awk -v f="$tpl" '
    index($0, "### `" f "`") == 1 { under = 1; next }
    under && /^```markdown$/      { inside = 1; next }
    inside && /^```$/             { exit }
    inside                        { print }' "$HANDOFF_SKILL" >"$tpl_repo/$tpl"
  out="$(cd "$tpl_repo" && bash "$ORCH" handoff validate "$tpl" 2>&1)"; st=$?
  if [ "$st" -eq 0 ]; then ok "the $tpl template validates when Host fallbacks is required"
  else bad "the $tpl template validates when Host fallbacks is required" "$(flat_text <<<"$out")"; fi
done
rm -rf "$tpl_repo"

# --- handoff verification ---------------------------------------------------
# The review loop runs the command the implement phase recorded rather than
# sniffing the repo for one, so a handoff without it sends review in blind.
echo
echo "handoff verification"
fresh_flow handoffverify
h3="$("$ORCH" handoff path review)"
writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff with no verification command is incomplete" "$st" 1
assert_contains "names the section review would have read" "$out" "Verification"

writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' '' '## Verification' '   ' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a bare Verification heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_implement_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "passes once the command is recorded" "$st" 0

# A failing verification is recorded where it belongs - under Verification,
# with the ticket that reported it - and Deviations keeps only deviations.
writeln '## PR' '#3.' '' '## Spec issue' '#1.' '' '## Base SHA' 'abc1234.' '' \
        '## Deviations' 'None.' '' \
        '## Verification' 'bash scripts/test/orch_test.sh' 'fail - ticket #12' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a Verification section recording a failure and its ticket validates" "$st" 0
assert_eq "its first line is still the bare command the review loop runs" \
  "$("$ORCH" handoff section "$h3" Verification | head -n 1)" "bash scripts/test/orch_test.sh"

# Merge resolutions records what a base-sync resolver dropped (#791). The
# template carries it, but a handoff written before it existed still
# validates: the section is optional, never required.
complete_implement_handoff "$h3"
writeln '' '## Merge resolutions' 'scripts/orch.sh: dropped the base'"'"'s rename - the branch removed the caller.' >>"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff carrying Merge resolutions validates" "$st" 0
assert_eq "its Merge resolutions read back through handoff section" \
  "$("$ORCH" handoff section "$h3" "Merge resolutions")" \
  "scripts/orch.sh: dropped the base's rename - the branch removed the caller."
complete_implement_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an old implement handoff without Merge resolutions still validates" "$st" 0
assert_not_contains "and is not told the section is missing" "$out" "Merge resolutions"
restore_suite_env
