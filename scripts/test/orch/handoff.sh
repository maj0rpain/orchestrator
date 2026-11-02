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
assert_eq "saying so" "$out" "$(handoff_missing_msg comment 7 01-plan)"
fake_lag adapter_issue_comments_json 1 'not json'
out="$("$ORCH" handoff fetch 01-plan "$fetched" 2>&1)"; st=$?
assert_status "unparseable comments make handoff fetch fail" "$st" 1
assert_eq "with the parse-failure wording" "$out" "orch: could not read issue #7's comments"
fake_lag adapter_issue_comments_json 1 ''
out="$("$ORCH" handoff fetch 01-plan "$fetched" 2>&1)"; st=$?
assert_status "an empty comments answer makes handoff fetch fail" "$st" 1
assert_eq "with the parse-failure wording and no bash error" "$out" "orch: could not read issue #7's comments"
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
# behave alike whichever adapter keeps the handoff, and so does retire.

handoff_store_contract() {
  local adapter="$1" out st p
  echo
  echo "handoff store contract ($adapter adapter)"
  fake_flow "handoff-store-$adapter"
  export ORCHESTRATOR_HOST=claude
  "$ORCH" state set issue 7 >/dev/null
  fake_issue 7 open

  # missing
  handoff_orch "$adapter" handoff path spec >/dev/null 2>&1; st=$?
  assert_status "$adapter: a missing handoff is a non-zero status at handoff path" "$st" 1

  # found
  put_handoff "$adapter" 7 2030-01-01T00:00:00Z 01-plan "$(literal_handoff spec)"
  p="$(handoff_orch "$adapter" handoff path spec 2>&1)"; st=$?
  assert_status "$adapter: a handoff that exists resolves" "$st" 0
  assert_eq "$adapter: holding its body" "$(cat "$p")" "$(literal_handoff spec)"

  # siblings: the other handoff due at the phase sits beside the one resolved
  put_handoff "$adapter" 7 2030-01-01T00:00:00Z 02-spec "$(literal_handoff implement)"
  p="$(handoff_orch "$adapter" handoff path implement 2>&1)"
  assert_eq "$adapter: a sibling handoff is beside the resolved one" \
    "$(on_disk "$(dirname "$p")/01-plan.md")" present
  assert_eq "$adapter: and holds its body" "$(cat "$(dirname "$p")/01-plan.md")" "$(literal_handoff spec)"

  if [ "$adapter" = comment ]; then
    reads_before="$(fake_comment_reads)"
    handoff_orch comment handoff path implement >/dev/null 2>&1
    assert_eq "comment: handoff path with two due handoffs makes one comment read" "$(( $(fake_comment_reads) - reads_before ))" 1
  fi

  # a retired sibling leaves no stale copy beside the handoff
  retire_handoff "$adapter" 7 2030-01-02T00:00:00Z 01-plan .orchestrator/handoff/pre-redo-1
  handoff_orch "$adapter" handoff path implement >/dev/null 2>&1
  assert_eq "$adapter: a retired sibling leaves no stale copy" \
    "$(on_disk "$(dirname "$p")/01-plan.md")" absent

  # retired reads as missing
  handoff_orch "$adapter" handoff path spec >/dev/null 2>&1; st=$?
  assert_status "$adapter: a retired handoff is missing at handoff path" "$st" 1

  # doctor: the missing-handoff finding is the adapter's (01-plan was retired)
  out="$(handoff_orch "$adapter" doctor --flow 2>&1)"; st=$?
  assert_status "$adapter: doctor --flow fails on a missing handoff" "$st" 1
  assert_contains "$adapter: with the adapter's finding" "$out" "$(handoff_doctor_missing_msg "$adapter" 7 01-plan)"

  # retire, through redo spec: both handoffs are set aside before a failing
  # ticket retire, and the re-run retires nothing twice
  put_handoff "$adapter" 7 2030-01-01T00:00:00Z 02-spec "$(literal_handoff implement)"
  put_handoff "$adapter" 7 2030-01-01T00:00:00Z 03-implement "implement text"
  state_fixture phase implement
  fake_issue_body 7 "$(printf 'Spec.\n\n## Ticket\nBuild.\n')"
  fake_fail adapter_issue_body_edit
  out="$(handoff_orch "$adapter" redo spec 2>&1)"; st=$?
  fake_unfail
  assert_status "$adapter: a gh failure in the ticket retire fails redo spec" "$st" 1
  assert_eq "$adapter: leaving the phase at implement" "$("$ORCH" state get phase)" implement
  p="$(handoff_orch "$adapter" handoff path implement 2>/dev/null)"; st=$?
  assert_status "$adapter: the retired spec handoff reads as missing" "$st" 1
  out="$(handoff_orch "$adapter" redo spec 2>&1)"; st=$?
  assert_status "$adapter: the re-run finishes" "$st" 0
  assert_eq "$adapter: the phase is spec" "$("$ORCH" state get phase)" spec
  assert_eq "$adapter: the spec handoff is retired exactly once" \
    "$(handoff_retired_count "$adapter" 7 02-spec '.orchestrator/handoff/pre-redo-spec-*')" 1
  assert_eq "$adapter: and the implement handoff" \
    "$(handoff_retired_count "$adapter" 7 03-implement '.orchestrator/handoff/pre-redo-spec-*')" 1
  restore_suite_env
}

handoff_store_contract file
handoff_store_contract comment

# The checks that hold for one adapter only, after the contract.
echo
echo "handoff store, comment adapter only"
fake_flow handoff-store-comment-only
export ORCHESTRATOR_HOST=claude
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open
out="$(handoff_orch comment handoff path spec 2>/dev/null)"; st=$?
assert_eq "comment: a missing handoff still prints its scratch path first" "$out" "$PWD/.orchestrator/scratch/01-plan.md"
assert_eq "comment: and dies with the missing message" \
  "$(handoff_orch comment handoff path spec 2>&1 >/dev/null)" "$(handoff_missing_msg comment 7 01-plan)"
put_handoff comment 7 2030-01-01T00:00:00Z 01-plan "$(literal_handoff spec)"
put_handoff comment 7 2030-01-01T00:00:00Z 02-spec "$(literal_handoff implement)"
p="$(handoff_orch comment handoff path spec 2>&1)"
assert_contains "comment: a found handoff resolves to a scratch file under .orchestrator" "$p" "/.orchestrator/"
assert_not_contains "comment: not the handoff directory" "$p" "/handoff/"
retire_handoff comment 7 2030-01-02T00:00:00Z 01-plan .orchestrator/handoff/pre-redo-1
out="$(handoff_orch comment handoff path spec 2>&1 >/dev/null)"
assert_eq "comment: a retired handoff dies with the missing message" "$out" "$(handoff_missing_msg comment 7 01-plan)"
# a stale scratch copy is never found
scratch="$(dirname "$p")"
assert_contains "comment: the stale copy goes in the sandbox's scratch directory" "$scratch" "/.orchestrator/"
case "$scratch" in /*/.orchestrator/*) echo stale >"$scratch/01-plan.md" ;; esac
out="$(handoff_orch comment handoff path spec 2>&1)"; st=$?
assert_status "comment: a stale scratch copy is not a found handoff" "$st" 1
assert_contains "comment: with the missing message" "$out" "$(handoff_missing_msg comment 7 01-plan)"
fake_fail adapter_issue_comments_json "HTTP 503 read"
out="$(handoff_orch comment handoff path implement 2>&1)"; st=$?
fake_unfail
assert_status "comment: a failed comments read dies" "$st" 1
assert_contains "comment: showing the gh reason" "$out" "HTTP 503 read"
assert_not_contains "comment: and not the missing line" "$out" "handoff comment"
fake_lag adapter_issue_comments_json 1 'not json'
out="$(handoff_orch comment handoff path implement 2>&1)"; st=$?
fake_unfail
assert_status "comment: handoff path over unparseable comments dies" "$st" 1
assert_eq "comment: with the parse-failure wording" "$out" "orch: could not read issue #7's comments"
# the comments unreadable with no sibling due: gh's reason, not "missing"
fake_fail adapter_issue_comments_json "HTTP 503 read"
out="$(handoff_orch comment handoff path spec 2>&1)"; st=$?
fake_unfail
assert_status "comment: a failed read with no sibling due dies" "$st" 1
assert_contains "comment: showing the gh reason with no sibling due" "$out" "HTTP 503 read"
assert_not_contains "comment: and not the missing line with no sibling due" "$out" "handoff comment"
# the comments unreadable with a sibling due: one read, no sibling copy
put_handoff comment 7 2030-01-01T00:00:00Z 01-plan "$(literal_handoff spec)"
handoff_orch comment handoff path implement >/dev/null 2>&1
assert_eq "comment: the sibling is fetched while readable" "$(on_disk "$scratch/01-plan.md")" present
reads_before="$(fake_comment_reads)"
fake_fail adapter_issue_comments_json "HTTP 503 read"
out="$(handoff_orch comment handoff path implement 2>&1)"; st=$?
fake_unfail
assert_status "comment: an unreadable sibling fetch dies" "$st" 1
assert_contains "comment: showing the gh reason with a sibling due" "$out" "HTTP 503 read"
assert_eq "comment: after exactly one comment read" "$(( $(fake_comment_reads) - reads_before ))" 1
assert_eq "comment: leaving no sibling copy" "$(on_disk "$scratch/01-plan.md")" absent
fake_flow handoff-store-ready-comment
out="$(handoff_orch comment doctor --flow 2>&1)"
assert_contains "comment: no recorded issue is today's finding" "$out" \
  "autopilot session, but no issue is recorded - the handoff comments cannot be read."
restore_suite_env

echo
echo "handoff store, file adapter only"
fake_flow handoff-store-file-only
export ORCHESTRATOR_HOST=claude
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open
out="$(handoff_orch file handoff path spec 2>/dev/null)"
assert_eq "file: a missing handoff prints only the write target" "$out" "$PWD/.orchestrator/handoff/01-plan.md"
fake_flow handoff-store-ready-file
out="$(handoff_orch file doctor --flow 2>&1)"
assert_not_contains "file: readiness passes with no recorded issue" "$out" "no issue is recorded"
assert_contains "file: and the missing handoff is reported" "$out" "$(handoff_doctor_missing_msg file 7 01-plan)"
restore_suite_env

# --- handoff comment retire's timeline read -----------------------------------
# The comments are read once per retire, and not at all when no file is named.
echo
echo "handoff comment retire's timeline read"
fake_flow handoff-retire-reads
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open
fake_comment 7 someone 2030-01-03T00:00:00Z "$(marker_of handoff 02-spec)
spec again"
fake_comment 7 someone 2030-01-03T00:00:01Z "$(marker_of handoff 03-implement)
implement again"
retire_all() { ORCH_AUTOPILOT=1 sourced_orch handoff_comment_retire pre-redo 02-spec.md 03-implement.md; }
reads_before="$(fake_comment_reads)"
ORCH_AUTOPILOT=1 sourced_orch handoff_comment_retire pre-redo >/dev/null 2>&1; st=$?
assert_status "a retire with no files succeeds" "$st" 0
assert_eq "and makes no comment read" "$(( $(fake_comment_reads) - reads_before ))" "0"
reads_before="$(fake_comment_reads)"
retire_all >/dev/null 2>&1
assert_eq "a retire of several handoffs makes exactly one comment read" "$(( $(fake_comment_reads) - reads_before ))" "1"

# an unreadable read dies before any post, with each failure's wording
fake_comment 7 someone 2030-01-04T00:00:00Z "$(marker_of handoff 02-spec)
spec third"
before="$(fake_comments_of 7)"
assert_gh_dies "a failed comments read dies with gh's wording" adapter_issue_comments_json "$GH_502" 1 \
  "orch: gh could not read the comments of issue #7: HTTP 502: Bad Gateway" \
  retire_all
assert_eq "posting nothing" "$(fake_comments_of 7)" "$before"
fake_lag adapter_issue_comments_json 1 'not json'
out="$(retire_all 2>&1)"; st=$?
assert_status "unparseable comments die" "$st" 1
assert_eq "posting nothing either" "$(fake_comments_of 7)" "$before"
restore_suite_env

# a retire naming no files still needs the recorded issue
fake_flow handoff-retire-no-issue
out="$(ORCH_AUTOPILOT=1 sourced_orch handoff_comment_retire pre-redo 2>&1)"; st=$?
assert_status "a no-file retire with no recorded issue fails" "$st" 1
assert_contains "naming the missing issue" "$out" "no issue recorded in state - the spec phase must publish one first"
restore_suite_env

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
