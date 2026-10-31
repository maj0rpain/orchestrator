# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# literal_handoff <phase>: the pinned literal body of the handoff <phase> reads
# (spec, implement or review), complete but for Host fallbacks.
literal_handoff() {
  case "$1" in
    spec) writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' 'Y, because Z.' '' \
                  '## Constraints' 'Must run offline.' '' '## Open assumptions' 'Assumes W.' ;;
    implement) writeln '## Spec issue' '#1.' ;;
    review) writeln '## PR' '#3.' '' '## Spec issue' '#1.' '' '## Base SHA' 'abc1234.' '' \
                    '## Deviations' 'None.' '' '## Verification' 'scripts/test/orch_test.sh' ;;
  esac
}

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

# --- phase table ------------------------------------------------------------
# The Handoff module's one ordered table of phases, the handoff each consumes,
# that handoff's writer and its required sections, read through the helpers a
# subshell that sourced orch.sh reaches. Each answer is pinned as a literal,
# today's values, so a table edit that changes one shows here.
echo
echo "phase table"
fake_flow phase-table

assert_eq "PHASES is the table's phases in order" \
  "$(sourced_orch eval 'printf "%s\n" "$PHASES"')" "spec implement review done"

for pair in "spec|01-plan.md" \
            "implement|$(writeln 01-plan.md 02-spec.md)" \
            "review|$(writeln 01-plan.md 02-spec.md 03-implement.md)" \
            "done|$(writeln 01-plan.md 02-spec.md 03-implement.md)"; do
  p="${pair%%|*}"
  out="$(sourced_orch handoffs_due "$p")"; st=$?
  assert_eq "handoffs_due $p prints the handoffs due by it" "$out" "${pair#*|}"
  assert_status "handoffs_due $p succeeds" "$st" 0
done
out="$(sourced_orch handoffs_due bogus)"; st=$?
assert_eq "handoffs_due prints nothing for a phase outside the table" "$out" ""
assert_status "and succeeds" "$st" 0

out="$(sourced_orch handoffs_written_from plan)"
assert_eq "handoffs_written_from plan prints all three handoffs" "$out" \
  "$(writeln 01-plan.md 02-spec.md 03-implement.md)"
out="$(sourced_orch handoffs_written_from spec)"
assert_eq "handoffs_written_from spec prints the spec and implement handoffs" "$out" \
  "$(writeln 02-spec.md 03-implement.md)"
out="$(sourced_orch handoffs_written_from implement)"
assert_eq "handoffs_written_from implement prints the implement handoff alone" "$out" "03-implement.md"
for p in review "done" bogus; do
  out="$(sourced_orch handoffs_written_from "$p")"; st=$?
  assert_eq "handoffs_written_from $p prints nothing" "$out" ""
  assert_status "handoffs_written_from $p succeeds" "$st" 0
done

for pair in "spec|$(writeln spec implement review "done")" \
            "implement|$(writeln implement review "done")" \
            "review|$(writeln review "done")" \
            "done|done"; do
  p="${pair%%|*}"
  out="$(sourced_orch phases_from "$p")"; st=$?
  assert_eq "phases_from $p prints $p and every later phase" "$out" "${pair#*|}"
  assert_status "phases_from $p succeeds" "$st" 0
done
out="$(sourced_orch phases_from bogus)"; st=$?
assert_eq "phases_from prints nothing for a phase outside the table" "$out" ""
assert_ne "and fails" "$st" 0

for pair in spec:implement implement:review review:done; do
  out="$(sourced_orch phase_next "${pair%%:*}")"; st=$?
  assert_eq "phase_next ${pair%%:*} prints ${pair#*:}" "$out" "${pair#*:}"
  assert_status "phase_next ${pair%%:*} succeeds" "$st" 0
done
for p in "done" bogus; do
  out="$(sourced_orch phase_next "$p")"; st=$?
  assert_eq "phase_next $p prints nothing" "$out" ""
  assert_ne "phase_next $p fails" "$st" 0
done

for cell in "handoff|spec|01-plan.md" "handoff|implement|02-spec.md" \
            "handoff|review|03-implement.md" \
            "writer|spec|plan" "writer|implement|spec" "writer|review|implement" \
            "sections|spec|Decisions;Rejected alternatives;Constraints;Open assumptions" \
            "sections|implement|Spec issue" \
            "sections|review|PR;Spec issue;Base SHA;Deviations;Verification"; do
  col="${cell%%|*}"; rest="${cell#*|}"; p="${rest%%|*}"
  out="$(sourced_orch phase_cell "$col" "$p")"; st=$?
  assert_eq "phase_cell $col $p prints its cell" "$out" "${rest#*|}"
  assert_status "phase_cell $col $p succeeds" "$st" 0
done
for col in handoff writer sections; do
  for p in "done" bogus; do
    out="$(sourced_orch phase_cell "$col" "$p")"; st=$?
    assert_eq "phase_cell $col $p prints nothing" "$out" ""
    assert_ne "phase_cell $col $p fails" "$st" 0
  done
done
out="$(sourced_orch phase_cell bogus spec 2>&1)"; st=$?
assert_status "phase_cell with an unknown column dies" "$st" 1
assert_eq "naming the column" "$out" "orch: unknown phase table column: bogus"

# handoff_required, Host fallbacks left off by a pre-1.0.0 state, so only the
# table's own headings show, in today's order.
st_saved="$(cat .orchestrator/state.json)"
state_fixture_drop host_fallbacks
assert_eq "handoff_required 01-plan.md prints its headings in order" \
  "$(sourced_orch handoff_required 01-plan.md)" \
  "$(writeln '## Decisions' '## Rejected alternatives' '## Constraints' '## Open assumptions')"
assert_eq "handoff_required 02-spec.md prints its headings in order" \
  "$(sourced_orch handoff_required 02-spec.md)" \
  "$(writeln '## Spec issue')"
assert_eq "handoff_required 03-implement.md prints its headings in order" \
  "$(sourced_orch handoff_required 03-implement.md)" \
  "$(writeln '## PR' '## Spec issue' '## Base SHA' '## Deviations' '## Verification')"
printf '%s\n' "$st_saved" >.orchestrator/state.json
assert_eq "and appends Host fallbacks when the state requires it" \
  "$(sourced_orch handoff_required 02-spec.md | tail -n 1)" "## Host fallbacks"
for name in - bogus.md ''; do
  out="$(sourced_orch handoff_required "$name" 2>&1)"; st=$?
  assert_status "handoff_required '$name' fails" "$st" 1
  assert_eq "naming the unknown file" "$out" "orch: unknown handoff file: $name"
done
writeln '## Decisions' 'Use X.' >./-
out="$("$ORCH" handoff validate - 2>&1)"; st=$?
rm -f ./-
assert_status "handoff validate - fails" "$st" 1
assert_contains "as an unknown handoff file, the done row matching no name" "$out" "unknown handoff file: -"
out="$("$ORCH" handoff path "done" 2>&1)"; st=$?
assert_status "handoff path done fails" "$st" 1
assert_eq "with no handoff defined for done" "$out" "orch: no handoff defined for phase: done"

# complete_handoff, the suite's one handoff fixture, writes what the table
# requires: each file it writes validates, with Host fallbacks required or not.
for p in spec implement review; do
  hf="$("$ORCH" handoff path "$p")"
  complete_handoff "$hf"
  out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
  assert_status "complete_handoff writes a valid $(basename "$hf")" "$st" 0
  assert_contains "with Host fallbacks" "$(cat "$hf")" "## Host fallbacks"
done
printf '%s\n' "$st_saved" >.orchestrator/state.json
state_fixture_drop host_fallbacks
complete_handoff "$hf"
assert_contains "and with Host fallbacks when the state does not require it" \
  "$(cat "$hf")" "## Host fallbacks"
printf '%s\n' "$st_saved" >.orchestrator/state.json
complete_handoff "$(dirname "$hf")/bogus.md" 2>/dev/null; st=$?
assert_ne "complete_handoff fails on a file the table does not hold" "$st" 0
assert_eq "and writes no file" "$(on_disk "$(dirname "$hf")/bogus.md")" "absent"
restore_suite_env

# --- handoff validate -------------------------------------------------------
echo
echo "handoff validate"
fake_flow handoff-validate
h="$("$ORCH" handoff path spec)"
complete_handoff "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "passes a complete handoff" "$st" 0

writeln '## Decisions' 'Use X.' '' '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is missing" "$st" 1
assert_contains "names the missing section" "$out" "Rejected alternatives"

# The high-value case: the section the spec writer is most likely to leave as a
# bare heading, which would let already-killed alternatives get re-proposed.
complete_handoff "$h"
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
  # Each complete but for Host fallbacks, written literally.
  literal_handoff "$p" >"$hf"
  out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
  assert_status "$(basename "$hf") without Host fallbacks is incomplete" "$st" 1
  assert_contains "$(basename "$hf") names the missing Host fallbacks" "$out" "Host fallbacks"
done
# A flow started before 1.0.0 has no host_fallbacks in state.json and wrote
# its handoffs without the section; upgrading mid-flow must not fail them.
st_saved="$(cat .orchestrator/state.json)"
state_fixture_drop host_fallbacks
out="$("$ORCH" handoff validate "$hf" 2>&1)"; st=$?
assert_status "a pre-1.0.0 flow's handoff validates without Host fallbacks" "$st" 0
printf '%s\n' "$st_saved" >.orchestrator/state.json
complete_handoff "$h"
# The spec-paused marker (#1181) and the round marker (#1346) share the
# handoff folder but are no handoffs: beside a complete handoff or an
# incomplete one, the verdict is unchanged.
before_out="$("$ORCH" handoff validate "$h" 2>&1)"
writeln 7 >"$(dirname "$h")/spec-paused"
writeln '7 1 2' >"$(dirname "$h")/spec-round"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "a folder holding spec-paused and spec-round still passes a complete handoff" "$st" 0
assert_eq "with the same report" "$out" "$before_out"
writeln '## Decisions' 'Use X.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "and still fails an incomplete one" "$st" 1
rm -f "$(dirname "$h")/spec-paused" "$(dirname "$h")/spec-round"
complete_handoff "$h"
restore_suite_env

# --- handoff section --------------------------------------------------------
# The review loop's driver reads Rejected alternatives and Deviations through
# this rather than reading whole handoffs, so it has to print exactly one
# section's body and nothing of its neighbours.
echo
echo "handoff section"
fake_flow handoff-section
h="$("$ORCH" handoff path spec)"
{ literal_handoff spec; writeln '' '## Host fallbacks' 'None (Claude Code).'; } >"$h"
out="$("$ORCH" handoff section "$h" "Rejected alternatives" 2>&1)"; st=$?
assert_status "prints a named section" "$st" 0
assert_eq "prints only that section's body" "$out" "Y, because Z."

hi="$("$ORCH" handoff path review)"
{ literal_handoff review; writeln '' '## Host fallbacks' 'None (Claude Code).'; } >"$hi"
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
complete_handoff "$h"

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
assert_contains "an unknown handoff op lists section" "$out" "want path|post|fetch|validate|section"
rm -f "$hs" "$hi"
restore_suite_env

# --- spec handoff -----------------------------------------------------------
# The spec phase's last step publishes tickets as sub-issues of the spec
# issue, so the handoff that follows it must at least name the parent -
# anything less sends implement's `ticket next` query against nothing.
echo
echo "spec handoff"
fake_flow spec-handoff
h2="$("$ORCH" handoff path implement)"
writeln '## Decisions' 'Use X.' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a spec handoff with no Spec issue is incomplete" "$st" 1
assert_contains "names the missing Spec issue" "$out" "Spec issue"

writeln '## Spec issue' '   ' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a bare Spec issue heading is no better than none" "$st" 1
assert_contains "reported as an empty Spec issue" "$out" "empty section: ## Spec issue"

complete_handoff "$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "passes once the parent issue is recorded" "$st" 0

# A spec handoff written before the Ticket breakdown section was dropped still
# carries it; only the phase table's sections are checked, so it validates.
writeln '## Spec issue' '#1.' '' \
        '## Ticket breakdown' 'None: work directly against #1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "an older spec handoff still carrying Ticket breakdown validates" "$st" 0

# A handoff that still carries the old Seams and Spec review changelog
# sections validates, filled or empty: neither is required any more.
writeln '## Spec issue' '#1.' '' '## Seams' 'The CLI.' '' \
        '## Spec review changelog' 'Not reviewed.' '' '## Ticket breakdown' '#1.' '' \
        '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a handoff still carrying filled Seams and Spec review changelog validates" "$st" 0
writeln '## Spec issue' '#1.' '' '## Seams' '' '## Spec review changelog' '' '' \
        '## Ticket breakdown' '#1.' '' '## Host fallbacks' 'None (Claude Code).' >"$h2"
out="$("$ORCH" handoff validate "$h2" 2>&1)"; st=$?
assert_status "a handoff carrying empty Seams and Spec review changelog validates" "$st" 0

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
# Seeded empty, then written through the Flow state module's writer, so the
# fixture holds only what orch.sh would write.
printf '{}\n' >"$tpl_repo/.orchestrator/state.json"
flow_state_write "$(flow_state_file "$tpl_repo")" host_fallbacks true \
  || bad "the handoff templates' state fixture is written" "flow_state_write failed"
# The file list is the phase table's, so a new phase's template is checked too.
# orch.sh is sourced inside the fixture repo, since it resolves one as it loads.
tpls="$(cd "$tpl_repo" && sourced_orch handoffs_due "done")"
assert_eq "the phase table names the templates to check" "$tpls" \
  "$(writeln 01-plan.md 02-spec.md 03-implement.md)"
for tpl in $tpls; do
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

complete_handoff "$h3"
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
complete_handoff "$h3"
writeln '' '## Merge resolutions' 'scripts/orch.sh: dropped the base'"'"'s rename - the branch removed the caller.' >>"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff carrying Merge resolutions validates" "$st" 0
assert_eq "its Merge resolutions read back through handoff section" \
  "$("$ORCH" handoff section "$h3" "Merge resolutions")" \
  "scripts/orch.sh: dropped the base's rename - the branch removed the caller."
complete_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an old implement handoff without Merge resolutions still validates" "$st" 0
assert_not_contains "and is not told the section is missing" "$out" "Merge resolutions"
restore_suite_env

# --- handoff comments (autopilot) ---------------------------------------------
# In an autopilot flow a handoff is one tagged issue comment, its only copy.
echo
echo "handoff post, fetch and path in autopilot"
fake_flow handoff-comments
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open
planf="$(mktemp -d)/01-plan.md"
plan_file "$planf" $'Rounds: 2\nBudget: 3'

out="$("$ORCH" handoff post 01-plan "$planf" 2>&1)"; st=$?
assert_status "handoff post refuses outside autopilot" "$st" 1
assert_contains "saying it is for an autopilot flow" "$out" "autopilot"
export ORCH_AUTOPILOT=1
out="$("$ORCH" handoff post 01-plan "$planf" 2>&1)"; st=$?
assert_status "handoff post posts a valid plan" "$st" 0
assert_eq "as one comment" "$(ls "$ORCH_GH_FAKE_STORE/issues/7/comments" | wc -l | tr -d ' ')" "1"
assert_eq "tagged with the handoff's name" "$(fake_comments_of 7 | head -1)" "<!-- orch:handoff 01-plan -->"

fetched="$(mktemp -d)/got.md"
"$ORCH" handoff fetch 01-plan "$fetched" >/dev/null 2>&1; st=$?
assert_status "handoff fetch succeeds" "$st" 0
assert_eq "writing the body with the marker stripped" "$(cat "$fetched")" "$(cat "$planf")"

# the newest tagged comment wins; untagged comments are not handoffs
sed -i 's/Placeholder for Decisions\./Newer decisions./' "$planf"
"$ORCH" handoff post 01-plan "$planf" >/dev/null 2>&1
fake_comment 7 someone 2030-01-01T00:00:00Z "unrelated chatter"
"$ORCH" handoff fetch 01-plan "$fetched" >/dev/null 2>&1
assert_contains "the newest tagged comment wins" "$(cat "$fetched")" "Newer decisions."
assert_eq "an older one is left in place" "$(ls "$ORCH_GH_FAKE_STORE/issues/7/comments" | wc -l | tr -d ' ')" "3"

# a retired newest comment reads as no handoff
fake_comment 7 someone 2030-01-02T00:00:00Z "$(marker_of handoff 01-plan retired)"
out="$("$ORCH" handoff fetch 01-plan "$fetched" 2>&1)"; st=$?
assert_status "a retired newest comment is no handoff to fetch" "$st" 1
assert_eq "saying so" "$out" "orch: issue #7 has no 01-plan handoff comment"
out="$("$ORCH" handoff fetch 02-spec "$fetched" 2>&1)"; st=$?
assert_status "a handoff never posted is none" "$st" 1
out="$("$ORCH" handoff fetch bogus "$fetched" 2>&1)"; st=$?
assert_status "an unknown name is refused" "$st" 1
assert_contains "naming the names that exist" "$out" "01-plan"

# a failed post posts nothing
before="$(fake_snapshot)"
bad_plan="$(mktemp -d)/01-plan.md"; printf '## Decisions\nOnly.\n' >"$bad_plan"
out="$("$ORCH" handoff post 01-plan "$bad_plan" 2>&1)"; st=$?
assert_status "an invalid handoff is refused" "$st" 1
assert_contains "naming the missing section" "$out" "missing section"
assert_eq "posting nothing" "$(fake_snapshot)" "$before"
post_tmp="$(mktemp -d)"
fake_fail adapter_issue_comment "HTTP 502"
out="$(TMPDIR="$post_tmp" "$ORCH" handoff post 01-plan "$planf" 2>&1)"; st=$?
fake_unfail
assert_status "a post gh refuses dies" "$st" 1
assert_contains "showing the gh reason" "$out" "gh could not post the 01-plan handoff on issue #7: HTTP 502"
assert_eq "having posted nothing" "$(fake_snapshot)" "$before"
assert_eq "a failed post leaves no temp file" "$(ls -A "$post_tmp")" ""
unset ORCH_AUTOPILOT
restore_suite_env

# --- handoff store contract (#1820) -------------------------------------------
# One function, run once per adapter, at the orch.sh CLI over the gh fake: a
# handoff is a file in the handoff directory (file adapter, interactive) or a
# tagged comment on the issue (comment adapter, ORCH_AUTOPILOT=1). The reads
# behave alike whichever adapter keeps the handoff.

# hs_orch <adapter> <orch args>...: runs orch.sh as that adapter's session.
hs_orch() {
  local adapter="$1"
  shift
  if [ "$adapter" = comment ]; then ORCH_AUTOPILOT=1 "$ORCH" "$@"; else env -u ORCH_AUTOPILOT "$ORCH" "$@"; fi
}

# hs_put <adapter> <name> <body>: keeps the handoff <name> (no .md) as the
# adapter does - a file, or a live tagged comment.
hs_put() {
  if [ "$1" = comment ]; then
    fake_comment 7 someone 2030-01-01T00:00:00Z "$(marker_of handoff "$2"; printf '%s\n' "$3")"
  else
    mkdir -p .orchestrator/handoff
    printf '%s\n' "$3" >".orchestrator/handoff/$2.md"
  fi
}

# hs_retire <adapter> <name>: sets the handoff aside as the adapter does - a
# newer retired comment, or the file moved into a pre-redo folder.
hs_retire() {
  if [ "$1" = comment ]; then
    fake_comment 7 someone 2030-01-02T00:00:00Z "$(marker_of handoff "$2" retired)"
  else
    mkdir -p .orchestrator/handoff/pre-redo-1
    mv ".orchestrator/handoff/$2.md" .orchestrator/handoff/pre-redo-1/
  fi
}

# hs_missing_msg <adapter> <name> [<hint>]: the adapter's missing message.
hs_missing_msg() {
  if [ "$1" = comment ]; then
    printf 'orch: issue #7 has no %s handoff comment%s' "$2" "${3:+ - post it with handoff post $3}"
  else
    printf 'orch: handoff not found: %s/.orchestrator/handoff/%s.md%s' "$PWD" "$2" "${3:+ - write it $3}"
  fi
}

handoff_store_contract() {
  local adapter="$1" out st p
  echo
  echo "handoff store contract ($adapter adapter)"
  fake_flow "handoff-store-$adapter"
  export ORCHESTRATOR_HOST=claude
  "$ORCH" state set issue 7 >/dev/null
  fake_issue 7 open

  # missing: handoff path prints the write target (file) or dies (comment)
  out="$(hs_orch "$adapter" handoff path spec 2>/dev/null)"; st=$?
  assert_status "$adapter: a missing handoff is a non-zero status at handoff path" "$st" 1
  if [ "$adapter" = comment ]; then
    assert_eq "$adapter: dying with the adapter's missing message" \
      "$(hs_orch "$adapter" handoff path spec 2>&1 >/dev/null)" "$(hs_missing_msg comment 01-plan)"
  else
    assert_eq "$adapter: printing only the write target" "$out" "$PWD/.orchestrator/handoff/01-plan.md"
  fi
  out="$(hs_orch "$adapter" phase advance 2>&1)"; st=$?
  assert_status "$adapter: phase advance with the handoff missing dies" "$st" 1
  assert_contains "$adapter: with the adapter's missing message and hint" "$out" \
    "$(hs_missing_msg "$adapter" 02-spec "before leaving the spec phase")"
  assert_eq "$adapter: leaving the phase at spec" "$("$ORCH" state get phase)" spec

  # invalid: phase advance reports the adapter's invalid message
  hs_put "$adapter" 02-spec $'## Decisions'
  out="$(hs_orch "$adapter" phase advance 2>&1)"; st=$?
  assert_status "$adapter: phase advance with an invalid handoff dies" "$st" 1
  if [ "$adapter" = comment ]; then
    assert_contains "$adapter: with the adapter's invalid message" "$out" \
      "the 02-spec comment on issue #7 is not valid - post a fixed one, then run phase advance again; the flow stays at spec"
  else
    assert_contains "$adapter: with the adapter's invalid message" "$out" \
      "02-spec.md is not valid - fix it, then run phase advance again; the flow stays at spec"
  fi
  assert_eq "$adapter: leaving the phase at spec" "$("$ORCH" state get phase)" spec

  # found
  hs_put "$adapter" 01-plan "$(literal_handoff spec)"
  p="$(hs_orch "$adapter" handoff path spec 2>&1)"; st=$?
  assert_status "$adapter: a handoff that exists resolves" "$st" 0
  assert_eq "$adapter: holding its body" "$(cat "$p")" "$(literal_handoff spec)"

  # siblings: the other handoff due at the phase sits beside the one resolved
  hs_put "$adapter" 02-spec "$(literal_handoff implement)"
  p="$(hs_orch "$adapter" handoff path implement 2>&1)"
  assert_eq "$adapter: a sibling handoff is beside the resolved one" \
    "$(on_disk "$(dirname "$p")/01-plan.md")" present
  assert_eq "$adapter: and holds its body" "$(cat "$(dirname "$p")/01-plan.md")" "$(literal_handoff spec)"

  # a retired sibling leaves no stale copy beside the handoff
  hs_retire "$adapter" 01-plan
  hs_orch "$adapter" handoff path implement >/dev/null 2>&1
  assert_eq "$adapter: a retired sibling leaves no stale copy" \
    "$(on_disk "$(dirname "$p")/01-plan.md")" absent

  # retired reads as missing
  out="$(hs_orch "$adapter" handoff path spec 2>&1 >/dev/null)"; st=$?
  assert_status "$adapter: a retired handoff is missing at handoff path" "$st" 1
  if [ "$adapter" = comment ]; then
    assert_eq "$adapter: with the missing message" "$out" "$(hs_missing_msg comment 01-plan)"
  fi

  # a stale scratch copy is never found (only the comment adapter has one)
  if [ "$adapter" = comment ]; then
    echo stale >"$(dirname "$p")/01-plan.md"
    out="$(hs_orch comment handoff path spec 2>&1)"; st=$?
    assert_status "comment: a stale scratch copy is not a found handoff" "$st" 1
    assert_contains "comment: with the missing message" "$out" "$(hs_missing_msg comment 01-plan)"
    fake_fail adapter_issue_json "HTTP 503 read"
    out="$(hs_orch comment handoff path implement 2>&1)"; st=$?
    fake_unfail
    assert_status "comment: a failed comments read dies" "$st" 1
    assert_contains "comment: showing the gh reason" "$out" "HTTP 503 read"
  fi
  restore_suite_env
}

handoff_store_contract file
handoff_store_contract comment

echo
echo "handoff validate's Autopilot block"
new_repo >/dev/null
f="$(mktemp -d)/01-plan.md"
plan_file "$f"
out="$(env -u ORCH_AUTOPILOT "$ORCH" handoff validate "$f" 2>&1)"; st=$?
assert_status "an interactive plan without the block validates as today" "$st" 0
out="$(ORCH_AUTOPILOT=1 "$ORCH" handoff validate "$f" 2>&1)"; st=$?
assert_status "an autopilot plan without the block fails" "$st" 1
assert_contains "naming the block" "$out" "missing section: ## Autopilot"
plan_file "$f" $'Rounds: 2\nBudget: 3'
out="$(ORCH_AUTOPILOT=1 "$ORCH" handoff validate "$f" 2>&1)"; st=$?
assert_status "a plan with the block passes in autopilot" "$st" 0
assert_contains "reporting it ok" "$out" "ok    ## Autopilot"
for body in $'Rounds: 0\nBudget: 3' $'Rounds: two\nBudget: 3' $'Rounds: 2' $'Budget: 3' $'Rounds: 2\nBudget: -1' $'Rounds: 2\nRounds: 3\nBudget: 3'; do
  plan_file "$f" "$body"
  out="$(ORCH_AUTOPILOT=1 "$ORCH" handoff validate "$f" 2>&1)"; st=$?
  assert_status "the block '$(flat_text <<<"$body")' fails in autopilot" "$st" 1
  out="$(env -u ORCH_AUTOPILOT "$ORCH" handoff validate "$f" 2>&1)"; st=$?
  assert_status "and is ignored interactively" "$st" 0
done
restore_suite_env
