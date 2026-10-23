#!/usr/bin/env bash
#
# Docs linter: named structural rules over the plugin's skills, agents,
# commands and docs.
#
# Each rule is a scan_* function that takes a plugin root (and, for the
# fragment rule, main's commit) and prints one line per problem, "<file>: <problem>",
# and nothing when the root obeys it. Each rule runs first against fixture
# plugin roots that break it, so a rule that stops flagging anything fails here
# too, then once against the real plugin root.
# The linter checks structure only: it never runs orch.sh and holds no flow
# state.
#
# The rule index: every scan_* function, in the order this file defines them,
# with the rule it checks. Only rules carry the scan_ prefix, and
# scan_rule_index fails when this index and the definitions drift apart.
# >>> rules
#   scan_rule_index  this index lists every scan_* function, in file order
#   scan_old_names  no old skill or command name outside history, and no old command file or skill directory
#   scan_builtin_command_names  no command is named after a Claude Code built-in
#   scan_old_glossary_names  no skill or agent names CONTEXT.md or CONTEXT-MAP.md
#   scan_skill_names  each skill directory has the orch- prefix and its SKILL.md declares its name
#   scan_orch_resolution  each SKILL.md and command resolves orch.sh and the plugin root the one documented way
#   scan_orch_bash  each skill file, command and listed doc runs orch.sh through bash
#   scan_plugin_root_placeholder  no skill file or command carries a <plugin root>/ placeholder
#   scan_stop_text  each SKILL.md carries orch-flow's skills-only stop text word for word
#   scan_junie_snippet_drift  docs/junie/AGENTS.md names every agent
#   scan_junie_snippet_lookup  the Junie snippet's finding-the-plugin section carries the orch.sh lookup and the pointer
#   scan_capability_pointer  each SKILL.md, and each agent invoking a mattpocock-skills skill, points at docs/host-capabilities.md
#   scan_claude_scoped_names  no skill file or agent names a skill by its Claude-scoped name
#   scan_ask_tool_names  each skill-file or agent sentence naming AskUserQuestion also names ask_user
#   scan_offered_commands  each plugin command a skill file or agent offers has a commands/<cmd>.md
#   scan_command_runs_orch  no command runs orch.sh itself
#   scan_command_routes  each command is a thin route to an orch- skill, or a section of one, that exists
#   scan_dispatch_copies  no skill file restates the implementer's report lines or the general-purpose-agent tier
#   scan_agent_settings  each file that starts a plugin agent points at Agent settings and names agent get <role> for each role it starts
#   scan_agent_settings_section  docs/host-capabilities.md has Agent settings before Fallbacks, linked from its Start a fresh subagent row
#   scan_lens_briefs  each lens agent owns a non-empty brief, Write and a findings-file section, and orch-spec-review carries no brief
#   scan_required_headings  each load-bearing heading is present in its file, in the listed order
#   scan_orch_names  each backticked orch- name resolves to a skill or an agent
#   scan_agent_frontmatter  each agent declares its name and a flow-list allowlist with no Agent, Skill or AskUserQuestion
#   scan_subissue_endpoints  no skill or agent calls GitHub's sub-issue endpoints itself
#   scan_unpinned_gh  each skill or agent gh call is pinned to the repo with -R
#   scan_flow_cmd  orch.sh and its modules name plugin commands only through flow_cmd
#   scan_early_exit_pipe  no script pipes into a quiet grep or into head
#   scan_junie_planning  the Junie snippet has one begin and end marker and restates the planning allowlist and records
#   scan_capability_table  each docs/host-capabilities.md row has both hosts' cells filled
#   scan_names_phrase  each listed file, or section of one, names its phrase: the verifying agents suite-cost run, the review loop's triage and the review pass suite-cost check, and the PR-writing sites docs/pr-writing.md, host-capabilities' Agent settings naming agent sync, and the Junie README's Agent settings on Junie section naming --host junie and orch.sh doctor
#   scan_review_pass  the review pass is defined once in orch-review-pass and quick implementation's step 6 runs it
#   scan_unattended_modes  quick implementation's steps 1, 2 and 3 run the unattended modes
#   scan_skill_refs  each skill's SKILL.md names every reference file beside it
#   scan_spec_review_refs  orch-flow's spec phase step 4 names spec-phase.md and changelog.md, orch-spec-review's Applying the answer names spec-review apply, and orch-handoff's 02-spec.md Spec review changelog names changelog.md
#   scan_previously_declined  a standalone review pass lists earlier declines and the reviewers hear of them only through the known-items file
#   scan_review_loop_prompt  the review loop's reviewer prompt is the seven variables, Standards: last
#   scan_standalone_smells  the standalone review pass section and its command offer --smells
#   scan_cheapest_test  the implementer's and fixer's Test-driven development sections carry one identical Cheapest sufficient test paragraph
#   scan_test_cost_smells  the Standards reviewer carries the four test-cost smells outside the smell baseline
#   scan_improve_tests  orch-improve-tests has its command file and its six step headings in order
#   scan_report_capability  docs/host-capabilities.md has a row for opening the report and a Markdown-summary fallback
#   scan_review_pass_self_contained  orch-review-pass refers into no orch-review section and starts its own reviewers
#   scan_review_pass_callers  each caller of the review pass names orch-review-pass and the section it follows
#   scan_review_loop_sheds_pass  orch-review keeps no copy of the review pass and points at orch-review-pass
#   scan_junie_review_pass  Junie's custom-agent block names orch-review-pass's dependency on both reviewers
#   scan_closer_filing  the closer's Filing section names each labelled body line
#   scan_cli_nouns  each routed orch.sh noun and its verbs are in the CLI conventions
#   scan_side_checkout_issue  a quick implementation's side checkout records its issue and its new session picks it up
#   scan_docs_paths  each docs/ path a skill or agent names exists
#   scan_driver_loop  the loop step labels live in docs/driver-loop.md only
#   scan_layout_map  CONTRIBUTING's Layout map lists every docs/ file and directory
#   scan_changelog  the CHANGELOG's top heading is the plugin version, with one non-empty section
#   scan_changelog_fragments  a PR to main adds one well-formed changelog fragment, named for no sub-issue, and bumps nothing by hand
# <<< rules

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

# ORCH_TEST_QUIET=1 hides the ok lines; the count, the FAIL lines,
# section headers and the summary still print.
ok()  { PASS=$((PASS + 1)); [ -n "${ORCH_TEST_QUIET:-}" ] || printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

# flat_text [file]: the file, or stdin when given none, on one line with
# every whitespace run collapsed to one space.
flat_text() { tr -s ' \t\n' '   ' <"${1:-/dev/stdin}"; }

# skill_md_files <plugin root>: every .md file directly in a skills/<name>/
# directory, SKILL.md and reference files alike, one path per line. It never
# descends into subdirectories or lists other files, so a file added beside a
# SKILL.md needs no registration here.
skill_md_files() {
  local f
  for f in "$1"/skills/*/*.md; do
    [ -f "$f" ] && printf '%s\n' "$f"
  done
  return 0
}

# md_section <file> <heading>: the lines after the first line that is exactly
# <heading> (trailing whitespace allowed), up to the next heading of the same
# or higher level. Exits 1 when the heading is absent, so a missing section is
# told apart from an empty one. The linter never runs orch.sh, so this is its
# own reader rather than orch.sh handoff section.
md_section() {
  H="$2" awk '
    BEGIN { h = ENVIRON["H"]; match(h, /^#+/); lvl = RLENGTH }
    inb { if (match($0, /^#+[[:space:]]/) && RLENGTH - 1 <= lvl) exit; print; next }
    { line = $0; sub(/[[:space:]]+$/, "", line) }
    line == h { inb = 1; seen = 1 }
    END { exit !seen }' "$1"
}

# md_section_first_block <file> <heading>: the lines of the first fenced code
# block in md_section's <heading> section, each with its leading whitespace
# stripped, so an indented block reads the same as a flush one.
md_section_first_block() {
  md_section "$1" "$2" \
    | awk '/^[[:space:]]*```/ { if (inb) exit; inb = 1; next } inb' | sed 's/^[[:space:]]*//'
}

# check <rule> <findings>: ok when the scan found nothing, else one FAIL line
# per finding, each naming the file and the problem.
check() {
  local line
  if [ -z "$2" ]; then ok "$1"; return; fi
  while IFS= read -r line; do bad "$1" "$line"; done <<<"$2"
}
# flags <test> <findings> <expected>: a fixture self-test. Run through check,
# the findings must give a FAIL line carrying <expected> ("<file>: <problem>").
# check runs in a subshell here, so the fixture's FAIL never reaches the count.
flags() {
  local out
  out="$(check "rule" "$2")"
  case "$out" in
    *"FAIL rule"*"$3"*) ok "$1" ;;
    *) bad "$1" "expected a FAIL line naming '$3', got: ${out:-nothing}" ;;
  esac
}
# spares <test> <findings> <pattern>: the negative fixture self-test. ok when
# no finding line matches the extended regex <pattern>, else a FAIL that
# prints the matching finding lines.
spares() {
  local hits
  hits="$(printf '%s\n' "$2" | grep -E -- "$3")"
  if [ -z "$hits" ]; then ok "$1"; else bad "$1" "expected no finding matching '$3', got: $hits"; fi
}

# >>> checks
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT
# new_fixture: an empty fixture plugin root, removed on exit.
new_fixture() { mktemp -d "$FIXTURES/root.XXXXXX"; }

echo "docs lint"

# --- markdown section reader -------------------------------------------------
echo
echo "markdown section reader"
fixture="$(new_fixture)"
printf '%s\n' '# Doc' '' '## Brief  ' '' 'Body.' '' '### Detail' '' 'Deeper.' '' '## Next' '' 'Other.' \
  '' '## Empty' '# Top' >"$fixture/doc.md"
assert_eq "md_section prints the body up to the next same-level heading, deeper subheadings kept" \
  "$(md_section "$fixture/doc.md" "## Brief")" "$(printf '\nBody.\n\n### Detail\n\nDeeper.\n')"
assert_eq "md_section stops at a higher-level heading" \
  "$(md_section "$fixture/doc.md" "## Empty"; echo "exit $?")" "exit 0"
assert_eq "md_section exits 1 on a missing heading" \
  "$(md_section "$fixture/doc.md" "## Missing"; echo "exit $?")" "exit 1"
assert_eq "md_section matches the heading line exactly" \
  "$(md_section "$fixture/doc.md" "## Brie"; echo "exit $?")" "exit 1"

# --- spares self-test --------------------------------------------------------
# spares runs in a subshell here, so the deliberate FAIL never reaches the count.
echo
echo "spares self-test"
findings="$(printf '%s\n' 'skills/a.md:1: a problem' 'skills/b.md:2: another problem')"
out="$(spares "probe" "$findings" '^skills/b\.md:')"
case "$out" in
  *"FAIL probe"*"skills/b.md:2: another problem"*) ok "spares fails on a matching finding, printing its line" ;;
  *) bad "spares fails on a matching finding, printing its line" "got: ${out:-nothing}" ;;
esac
assert_eq "spares passes when no finding matches" \
  "$(ORCH_TEST_QUIET='' spares "probe" "$findings" '^skills/c\.md:')" "  ok   probe"

# --- rule index (#1145) -------------------------------------------------------
# The header's rule index, between the `# >>> rules` and `# <<< rules` lines,
# lists every scan_* function in the order the file defines them, so a reader
# finds a rule without paging through the file. Only rules carry the scan_
# prefix, so every scan_<name>() definition at column 0 is one index line.
echo
echo "rule index (#1145)"
# scan_rule_index <lint file>: one line per name defined but not indexed, per
# name indexed but not defined, one when both list the same names in a
# different order, and one when the file has no index block.
scan_rule_index() {
  local f="$1" n="${1#"$PLUGIN_ROOT"/}" indexed defined name
  if ! grep -qx '# >>> rules' "$f" || ! grep -qx '# <<< rules' "$f"; then
    echo "$n: no rule index between '# >>> rules' and '# <<< rules'"
    return 0
  fi
  indexed="$(awk '$0 == "# <<< rules" { exit }
    inb && /^#   scan_[a-z0-9_]+( |$)/ { print $2 }
    $0 == "# >>> rules" { inb = 1 }' "$f")"
  defined="$(sed -nE 's/^(scan_[a-z0-9_]+)\(\).*/\1/p' "$f")"
  for name in $defined; do
    grep -qxF -- "$name" <<<"$indexed" || echo "$n: $name is defined but not in the rule index"
  done
  for name in $indexed; do
    grep -qxF -- "$name" <<<"$defined" || echo "$n: $name is in the rule index but not defined"
  done
  if [ "$indexed" != "$defined" ] \
     && [ "$(sort <<<"$indexed")" = "$(sort <<<"$defined")" ]; then
    echo "$n: the rule index is not in the order the scan_* functions are defined"
  fi
  return 0
}
fixture="$(new_fixture)"
printf '%s\n' '#!/usr/bin/env bash' '# >>> rules' '#   scan_a  rule a' '#   scan_gone  a removed rule' \
  '# <<< rules' '# scan_a <root>: a rule.' 'scan_a() { :; }' 'scan_new() { :; }' >"$fixture/lint.sh"
out="$(scan_rule_index "$fixture/lint.sh")"
flags "a scan_* function missing from the index is flagged" \
  "$out" "$fixture/lint.sh: scan_new is defined but not in the rule index"
flags "an indexed name with no scan_* function is flagged" \
  "$out" "$fixture/lint.sh: scan_gone is in the rule index but not defined"
spares "an indexed, defined name is not flagged" "$out" ' scan_a '
printf '%s\n' '# >>> rules' '#   scan_b  rule b' '#   scan_a  rule a' '# <<< rules' \
  'scan_a() { :; }' 'scan_b() { :; }' >"$fixture/lint.sh"
flags "an index out of the functions' order is flagged" \
  "$(scan_rule_index "$fixture/lint.sh")" "$fixture/lint.sh: the rule index is not in the order"
printf '%s\n' '# Rules:' '#   scan_a  rule a' 'scan_a() { :; }' >"$fixture/lint.sh"
flags "a file with no index block is flagged" \
  "$(scan_rule_index "$fixture/lint.sh")" "$fixture/lint.sh: no rule index between"
printf '%s\n' '# >>> rules' '#   scan_a  rule a' '#   scan_b  rule b' '# <<< rules' \
  '# scan_b <root>: a comment outside the index.' 'scan_a() { :; }' 'helper() { :; }' 'scan_b() { :; }' \
  >"$fixture/lint.sh"
assert_empty "an index matching the functions in order is not flagged" \
  "$(scan_rule_index "$fixture/lint.sh")"
check "the rule index lists every scan_* function in file order" \
  "$(scan_rule_index "$PLUGIN_ROOT/scripts/test/docs_lint.sh")"

# --- skill names (ADR-0014) --------------------------------------------------
# Every orchestrator skill carries the orch- prefix. An old unprefixed name
# left in a skill, command, hook, or doc points a model at a skill that no
# longer exists. CHANGELOG, ADRs, and .out-of-scope/ record history and may
# name the old ones; scripts/test/ feeds old names in deliberately as negative
# cases. The spec review's command and skill were renamed spec-review in 2.0.0
# (#235), so the review-spec names, command included, are old names too.
# The old review skill's directory and name line remain old names. The planning entry point
# was renamed interview in 3.0.0 (#373), so orch-plan, under any prefix, and
# the command orchestrator:plan are old names too, each matched as a whole
# token: .scratch/orch-plan-<slug>.md names a saved plan, not the skill.
# /orchestrator:quick-implement is a live command too (#723), so only the
# quick-implement skill's directory and name line remain old names. The
# commands review, status and doctor were renamed review-pass, flow-status and
# health in 4.0.0 (#374), so orchestrator:review, orchestrator:status and
# orchestrator:doctor are old names too, each matched as a whole token.
echo
echo "skill names (ADR-0014)"
old_names='orchestrator:(flow|handoff|review-spec|orch-review-spec|review|status|doctor)([^a-z-]|$)|skills/(flow|handoff|review|review-spec|quick-implement|orch-review-spec)/|^name: (flow|handoff|review|review-spec|quick-implement|orch-review-spec)$|(^|[^a-z-])(orch-plan|orchestrator:plan)([^a-z-]|$)'
# tracked_pattern_lines <root> <label> <pattern> [pathspec...]: each line of a
# tracked file matching the extended regex <pattern>, as
# "<file>:<line>: <label>: <text>", where <label> is plain words with no "/",
# "\" or "&". The pathspecs, if any, narrow the files scanned; a
# ':(exclude)<path>' pathspec drops one.
tracked_pattern_lines() {
  local r="$1" label="$2" pattern="$3"
  shift 3
  git -C "$r" ls-files -z -- "$@" \
    | (cd "$r" && xargs -0 grep -nE "$pattern" 2>/dev/null) \
    | sed -E "s/^([^:]*:[0-9]+):/\\1: $label: /"
  return 0
}
# scan_old_names <plugin root>: each old skill or command name in a tracked
# file outside history, and each old command file or skill directory.
scan_old_names() {
  local r="$1"
  tracked_pattern_lines "$r" "old skill or command name" "$old_names" \
    ':(exclude)CHANGELOG.md' ':(exclude)docs/adr' \
    ':(exclude)scripts/test' ':(exclude).out-of-scope'
  local p
  for p in commands/review-spec.md commands/plan.md commands/review.md \
    commands/status.md commands/doctor.md; do
    [ -e "$r/$p" ] && echo "$p: old command file"
  done
  for p in skills/orch-review-spec skills/orch-plan; do
    [ -e "$r/$p" ] && echo "$p/: old skill directory"
  done
  return 0
}
fixture="$(new_fixture)"
git -C "$fixture" init -q
mkdir -p "$fixture/skills/orch-spec-review" "$fixture/commands" "$fixture/docs/adr"
printf 'Call `orchestrator:review-spec`.\n' >"$fixture/commands/a.md"
printf 'Run `/orchestrator:review-spec 12`.\n' >"$fixture/commands/b.md"
printf 'Call `orchestrator:orch-review-spec`.\n' >"$fixture/commands/c.md"
printf 'See skills/orch-review-spec/SKILL.md.\n' >"$fixture/commands/d.md"
printf 'name: orch-review-spec\n' >"$fixture/commands/e.md"
printf 'Run `/orchestrator:spec-review 12`.\nCall `orchestrator:orch-spec-review`.\nskills/orch-spec-review/\n' >"$fixture/commands/new.md"
printf -- '---\nname: orch-spec-review\n---\n' >"$fixture/skills/orch-spec-review/SKILL.md"
printf 'Renamed `orchestrator:review-spec`.\n' >"$fixture/docs/adr/0001-x.md"
mkdir -p "$fixture/scripts/test" "$fixture/.out-of-scope"
printf 'Renamed `orchestrator:review-spec`.\n' >"$fixture/CHANGELOG.md"
printf '# Call `orchestrator:review-spec`.\n' >"$fixture/scripts/test/x_test.sh"
printf 'Renamed `orchestrator:review-spec`.\n' >"$fixture/.out-of-scope/x.md"
# The old review skill's directory and name stay old.
printf 'See skills/review/SKILL.md.\n' >"$fixture/commands/f.md"
printf 'name: review\n' >"$fixture/commands/g.md"
# The planning entry point was renamed interview (#373).
printf 'Call `orchestrator:orch-plan`.\n' >"$fixture/commands/p1.md"
printf 'Run `$orch-plan`.\n' >"$fixture/commands/p2.md"
printf 'Run `/orch-plan`.\n' >"$fixture/commands/p3.md"
printf 'A hook on `Skill(orch-plan)`.\n' >"$fixture/commands/p4.md"
printf 'While planning (orch-plan, grilling)\n' >"$fixture/commands/p5.md"
printf 'Run `/orchestrator:plan`.\n' >"$fixture/commands/p6.md"
printf 'See skills/orch-plan/SKILL.md.\n' >"$fixture/commands/p7.md"
printf 'name: orch-plan\n' >"$fixture/commands/p8.md"
printf 'Run `/orchestrator:interview`.\nCall `orchestrator:orch-interview`.\nskills/orch-interview/\n$orch-interview\n' >"$fixture/commands/interview.md"
printf 'Save it to `.scratch/orch-plan-<slug>.md`.\n' >"$fixture/commands/scratch.md"
printf 'Run `/orchestrator:quick-implement 12`.\nCall `orchestrator:orch-quick-implement`.\n' >"$fixture/commands/quick.md"
printf 'See skills/quick-implement/SKILL.md.\n' >"$fixture/commands/q1.md"
# review, status and doctor were renamed review-pass, flow-status, health (#374).
printf 'Run `/orchestrator:review 12`.\n' >"$fixture/commands/r1.md"
printf 'Run `/orchestrator:status`.\n' >"$fixture/commands/r2.md"
printf 'Run `/orchestrator:doctor`.\n' >"$fixture/commands/r3.md"
printf 'Run `/orchestrator:review-pass 12`.\nRun `/orchestrator:flow-status`.\nRun `/orchestrator:health`.\nCall `orchestrator:orch-review`.\nCall `orchestrator:orch-review-pass`.\nSee skills/orch-review-pass/SKILL.md.\nname: orch-review-pass\n' >"$fixture/commands/renamed.md"
git -C "$fixture" add -A
out="$(scan_old_names "$fixture")"
flags "the old review-spec skill name is flagged" "$out" "commands/a.md:1: old skill or command name"
flags "the old /orchestrator:review-spec command is flagged" "$out" "commands/b.md:1: old skill or command name"
flags "the old orch-review-spec skill name is flagged" "$out" "commands/c.md:1: old skill or command name"
flags "the old orch-review-spec skill directory is flagged" "$out" "commands/d.md:1: old skill or command name"
flags "the old orch-review-spec skill name line is flagged" "$out" "commands/e.md:1: old skill or command name"
spares "the new spec-review names are not flagged" \
  "$out" '^(commands/new\.md|skills/)'
spares "the live /orchestrator:quick-implement command is not flagged" \
  "$out" '^commands/quick\.md'
flags "the old quick-implement skill directory is flagged" "$out" "commands/q1.md:1: old skill or command name"
flags "the old review skill directory is flagged" "$out" "commands/f.md:1: old skill or command name"
flags "the old review skill name line is flagged" "$out" "commands/g.md:1: old skill or command name"
flags "the old orchestrator:orch-plan skill name is flagged" "$out" "commands/p1.md:1: old skill or command name"
flags "the old \$orch-plan reference is flagged" "$out" "commands/p2.md:1: old skill or command name"
flags "the old /orch-plan reference is flagged" "$out" "commands/p3.md:1: old skill or command name"
flags "the old Skill(orch-plan) reference is flagged" "$out" "commands/p4.md:1: old skill or command name"
flags "a bare orch-plan mention is flagged" "$out" "commands/p5.md:1: old skill or command name"
flags "the old /orchestrator:plan command is flagged" "$out" "commands/p6.md:1: old skill or command name"
flags "the old orch-plan skill directory is flagged" "$out" "commands/p7.md:1: old skill or command name"
flags "the old orch-plan skill name line is flagged" "$out" "commands/p8.md:1: old skill or command name"
flags "the old /orchestrator:review command is flagged" "$out" "commands/r1.md:1: old skill or command name"
flags "the old /orchestrator:status command is flagged" "$out" "commands/r2.md:1: old skill or command name"
flags "the old /orchestrator:doctor command is flagged" "$out" "commands/r3.md:1: old skill or command name"
spares "the new review-pass, flow-status and health names, orch-review and orch-review-pass are not flagged" \
  "$out" '^commands/renamed\.md'
spares "the new interview names are not flagged" \
  "$out" '^commands/interview\.md'
spares "the saved-plan scratch file is not flagged" \
  "$out" '^commands/scratch\.md'
spares "history may name the old ones" \
  "$out" '^docs/adr/'
spares "the changelog may name the old ones" \
  "$out" '^CHANGELOG\.md'
spares "tests may name the old ones" \
  "$out" '^scripts/test/'
spares "out-of-scope notes may name the old ones" \
  "$out" '^\.out-of-scope/'
mkdir -p "$fixture/skills/orch-review-spec"
: >"$fixture/commands/review-spec.md"
mkdir -p "$fixture/skills/orch-plan"
: >"$fixture/commands/plan.md"
: >"$fixture/commands/review.md"
: >"$fixture/commands/status.md"
: >"$fixture/commands/doctor.md"
out="$(scan_old_names "$fixture")"
flags "an old review-spec command file is flagged" "$out" "commands/review-spec.md: old command file"
flags "an old orch-review-spec skill directory is flagged" "$out" "skills/orch-review-spec/: old skill directory"
flags "an old plan command file is flagged" "$out" "commands/plan.md: old command file"
flags "an old orch-plan skill directory is flagged" "$out" "skills/orch-plan/: old skill directory"
flags "an old review command file is flagged" "$out" "commands/review.md: old command file"
flags "an old status command file is flagged" "$out" "commands/status.md: old command file"
flags "an old doctor command file is flagged" "$out" "commands/doctor.md: old command file"
check "no old orchestrator skill or command name outside history" "$(scan_old_names "$PLUGIN_ROOT")"

# A plugin command must not share its bare name with a host built-in command
# (CONTRIBUTING.md's Command names, #374): both appear in the typeahead when
# the user types the bare name. Claude Code's built-in commands, bundled skills
# and their aliases, from https://code.claude.com/docs/en/commands (fetched
# 2026-10-09); refresh this list from there. No Junie list until Junie is shown
# to load plugin commands (docs/host-capabilities.md, Run a plugin command).
echo
echo "command names against host built-ins (#374)"
claude_code_builtins='add-dir advisor agents allowed-tools android app artifact-capabilities
artifact-diagramming artifacts auto-mode-setup autocompact autofix-pr
background batch bg branch btw bug cd checkpoint checkup chrome claude-api
claude-in-chrome clear code-review color compact config context continue copy
cost dataviz debug deep-research design design-login design-sync desktop diff
doctor effort exit export fast feedback fewer-permission-prompts focus fork
goal heapdump help hooks ide import init insights install-github-app
install-slack-app ios keybindings list-agents login logout loop mcp memory
mobile model new output-style passes permissions plan plugin plugin-authoring
powerup pr-comments privacy-settings proactive quit radio rate-limit-options
rc recap release-notes reload-plugins reload-skills remote-control remote-env
rename reset resume review rewind routines run run-skill-generator sandbox
schedule scroll-speed security-review settings setup-bedrock setup-vertex
share simplify skill-doctor skills slides stats status statusline stickers
stop subtask tasks team-onboarding teleport terminal-setup theme tui
ultraplan ultrareview undo update-config upgrade usage usage-credits verify
vim voice web-setup workflow-authoring workflows'
# scan_builtin_command_names <plugin root>: each commands/<name>.md whose
# <name> is a Claude Code built-in command.
scan_builtin_command_names() {
  local r="$1" f name names
  names="$(tr -s ' \n' '\n\n' <<<"$claude_code_builtins")"
  for f in "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .md)"
    grep -qxF -- "$name" <<<"$names" \
      && echo "commands/$name.md: command named after a host built-in"
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/commands"
: >"$fixture/commands/clear.md"
: >"$fixture/commands/interview.md"
out="$(scan_builtin_command_names "$fixture")"
flags "a command named after a Claude Code built-in is flagged" \
  "$out" "commands/clear.md: command named after a host built-in"
spares "a command with a name of its own is not flagged" "$out" '^commands/interview\.md'
check "no command is named after a host built-in" "$(scan_builtin_command_names "$PLUGIN_ROOT")"

# The glossary was renamed upstream: CONTEXT.md became GLOSSARY.md, and
# CONTEXT-MAP.md became GLOSSARY-MAP.md (#461). Like the old skill names, an
# old glossary name in a skill or agent points a model at a file that no
# longer exists. Only skills/ and agents/ are scanned: the Junie snippet
# docs/junie/AGENTS.md and planning-allowlist.sh still list the legacy names,
# which the planning guard keeps protecting.
echo
echo "glossary names (#461)"
# scan_old_glossary_names <plugin root>: each CONTEXT.md or CONTEXT-MAP.md in
# a tracked file under skills/ or agents/.
scan_old_glossary_names() {
  tracked_pattern_lines "$1" "old glossary name" 'CONTEXT(-MAP)?\.md' \
    skills agents
}
fixture="$(new_fixture)"
git -C "$fixture" init -q
mkdir -p "$fixture/skills/orch-x" "$fixture/agents"
printf 'Read `CONTEXT.md` first.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'With a `CONTEXT-MAP.md` at the root.\n' >"$fixture/agents/orch-a.md"
printf 'Read `GLOSSARY.md`, or with a `GLOSSARY-MAP.md`, the one it points to.\n' >"$fixture/agents/orch-new.md"
printf 'Records (GLOSSARY.md, GLOSSARY-MAP.md, CONTEXT.md, CONTEXT-MAP.md, docs/adr/).\n' >"$fixture/README.md"
git -C "$fixture" add -A
out="$(scan_old_glossary_names "$fixture")"
flags "an old CONTEXT.md in a skill is flagged" "$out" "skills/orch-x/SKILL.md:1: old glossary name"
flags "an old CONTEXT-MAP.md in an agent is flagged" "$out" "agents/orch-a.md:1: old glossary name"
spares "the new glossary names are not flagged" "$out" '^agents/orch-new\.md'
spares "the legacy names outside skills and agents are not flagged" "$out" '^README\.md'
check "no skill or agent names the old glossary files" "$(scan_old_glossary_names "$PLUGIN_ROOT")"

# Each skill directory carries the orch- prefix, and its SKILL.md declares the
# directory's name.
# scan_skill_names <plugin root>: each skill directory off the rule.
scan_skill_names() {
  local d n name
  for d in "$1"/skills/*/; do
    [ -d "$d" ] || continue
    n="$(basename "$d")"
    case "$n" in orch-*) ;; *) echo "skills/$n/: no orch- prefix" ;; esac
    name="$(sed -n 's/^name: //p' "$d/SKILL.md" 2>/dev/null | head -1)"
    [ "$name" = "$n" ] || echo "skills/$n/SKILL.md: name: is '$name', not its directory"
  done
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/flow" "$fixture/skills/orch-x" "$fixture/skills/orch-ok"
printf -- '---\nname: flow\n---\n' >"$fixture/skills/flow/SKILL.md"
printf -- '---\nname: orch-y\n---\n' >"$fixture/skills/orch-x/SKILL.md"
printf -- '---\nname: orch-ok\n---\n' >"$fixture/skills/orch-ok/SKILL.md"
printf 'A reference file with no name: line.\n' >"$fixture/skills/orch-ok/ref.md"
out="$(scan_skill_names "$fixture")"
spares "a reference file is not asked for its own name: line" "$out" 'ref\.md'
flags "an unprefixed skill directory is flagged" "$out" "skills/flow/: no orch- prefix"
flags "a skill whose name: is not its directory is flagged" "$out" "skills/orch-x/SKILL.md: name: is 'orch-y', not its directory"
spares "a prefixed skill named for its directory is not flagged" \
  "$out" 'orch-ok'
check "every skill directory carries the orch- prefix and declares its name" "$(scan_skill_names "$PLUGIN_ROOT")"

# --- orch.sh resolution (#123) ------------------------------------------------
# Only Claude Code expands CLAUDE_PLUGIN_ROOT, and only in hooks/hooks.json on
# other hosts, so skill and command text must pair it with the
# relative fallback. The one documented form (CONTRIBUTING.md, "Resolving
# orch.sh") is the ORCH= line, the Junie step, and the fallback sentence; any other mention
# of the variable, or a file that runs orch.sh without them, is a regression.
# hooks/hooks.json is deliberately out of scope: both hosts expand it there.
echo
echo "orch.sh resolution (#123)"
orch_line='ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"'
# On Junie CLI the agent's shell has no plugin-root variable at all, so the
# Junie install is found by a literal ls before the relative fallback (#201).
# This prose sentence opens with the same fixed prefix in every file.
orch_junie='If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`'
orch_junie_one='If it prints one path, `ORCH` is that path.'
orch_junie_many='If it prints more than one, stop and show the human the paths.'
orch_fallback='If it prints nothing, `ORCH` is `scripts/orch.sh`'
# A path under the plugin root other than orch.sh (#155) is the one other
# documented form: "${CLAUDE_PLUGIN_ROOT}/<path>", in a file that also carries
# this sentence naming the same unset fallback the ORCH line has.
root_fallback='If `CLAUDE_PLUGIN_ROOT` is unset, the plugin root is'
# ...and that sentence takes the same Junie step first (#201).
root_junie='two directories above the `orch.sh` that `ls` printed'
# The steps wrap differently from file to file, so order is checked on the
# file's text with every run of whitespace collapsed to one space.
# The Junie lookup up to the several-installs stop; the Junie snippet carries
# this much of it too (#416).
orch_lookup="$orch_junie (the Junie CLI install). $orch_junie_one $orch_junie_many"
orch_steps="$orch_lookup $orch_fallback"
# scan_orch_resolution <plugin root>: print one line per offending file.
scan_orch_resolution() {
  local r="$1" f flat root_sentence
  local -a allowed
  for f in "$r"/skills/*/SKILL.md "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    flat="$(flat_text "$f")"
    allowed=(-e "$orch_line" -e "$orch_junie")
    grep -qF "$root_fallback" "$f" && allowed+=(-e "$root_fallback" -e '"${CLAUDE_PLUGIN_ROOT}/')
    if grep -n 'CLAUDE_PLUGIN_ROOT' "$f" | grep -vF "${allowed[@]}" | grep -q .; then
      echo "${f#"$r"/}: CLAUDE_PLUGIN_ROOT outside the ORCH= line and its fallback"
    fi
    if grep -qF "$root_fallback" "$f"; then
      # The sentence runs to the first full stop followed by a space;
      # orch.sh's own dot is followed by a backtick, so it does not end it.
      root_sentence="${flat#*"$root_fallback"}"
      root_sentence="${root_sentence%%. *}"
      [[ "$root_sentence" == *"$root_junie"* ]] ||
        echo "${f#"$r"/}: names the plugin root without the Junie step"
    fi
    if grep -qE 'orch\.sh|\$ORCH' "$f"; then
      grep -qxF "$orch_line" "$f" || echo "${f#"$r"/}: uses orch.sh without the ORCH= line"
      grep -qF "$orch_junie" "$f" || echo "${f#"$r"/}: uses orch.sh without the Junie step"
      grep -qF "$orch_junie_one" "$f" || echo "${f#"$r"/}: uses orch.sh without the one-install step"
      grep -qF "$orch_junie_many" "$f" || echo "${f#"$r"/}: uses orch.sh without the stop on several Junie installs"
      grep -qF "$orch_fallback" "$f" || echo "${f#"$r"/}: uses orch.sh without the relative fallback"
      [[ "$flat" == *"$orch_steps"* ]] || echo "${f#"$r"/}: resolves orch.sh out of the documented order"
    fi
  done
}
fixture="$(new_fixture)"
mkdir -p "$fixture/commands"
printf 'Run `${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh status`.\n' >"$fixture/commands/orch.md"
flags "the scan covers commands/ and flags a bare CLAUDE_PLUGIN_ROOT" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: CLAUDE_PLUGIN_ROOT outside"
printf '%s\n' '```' "$orch_line" '```' \
  'If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh` two directories above this skill.' \
  >"$fixture/commands/orch.md"
flags "the scan flags orch.sh resolved without the Junie step" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: uses orch.sh without the Junie step"
# documented_orch_form [step]...: the documented form, minus each step named.
documented_orch_form() {
  local -a steps=("$orch_junie (the Junie CLI install)." "$orch_junie_one" "$orch_junie_many"
    "$orch_fallback two directories above this skill's own directory.")
  local step skip
  printf '%s\n' '```' "$orch_line" '```'
  for step in "${steps[@]}"; do
    for skip in "$@"; do [ "$step" = "$skip" ] && continue 2; done
    printf '%s\n' "$step"
  done
}
documented_orch_form "$orch_junie_one" >"$fixture/commands/orch.md"
flags "the scan flags a Junie step with no one-install step" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: uses orch.sh without the one-install step"
documented_orch_form "$orch_junie_many" >"$fixture/commands/orch.md"
flags "the scan flags a Junie step with no stop on several installs" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: uses orch.sh without the stop on several Junie installs"
{ documented_orch_form "$orch_junie_one"; printf '%s\n' "$orch_junie_one"; } >"$fixture/commands/orch.md"
flags "the scan flags the Junie steps out of order" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: resolves orch.sh out of the documented order"
documented_orch_form >"$fixture/commands/orch.md"
assert_empty "the scan accepts the documented form" "$(scan_orch_resolution "$fixture")"
fixture2="$(new_fixture)"
mkdir -p "$fixture2/skills/orch-x"
documented_orch_form >"$fixture2/skills/orch-x/SKILL.md"
printf 'Run `bash "$ORCH" status`.\n' >"$fixture2/skills/orch-x/ref.md"
spares "a reference file using its skill's \$ORCH is not asked for its own ORCH= line" \
  "$(scan_orch_resolution "$fixture2")" 'ref\.md'
# plugin_root_fence: a fenced command that reads a file under the plugin root.
plugin_root_fence() {
  printf '%s\n' '```' 'sed -n 1p "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"' '```'
}
plugin_root_fence >"$fixture/commands/orch.md"
flags "the scan flags a plugin-root path with no unset fallback" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: CLAUDE_PLUGIN_ROOT outside"
{ plugin_root_fence
  printf '%s\n' "$root_fallback two directories above this skill's own directory."
} >"$fixture/commands/orch.md"
flags "the scan flags a plugin-root fallback with no Junie step" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: names the plugin root without the Junie step"
{ plugin_root_fence
  printf '%s\n' "$root_fallback two directories above this skill's own directory." \
    "Elsewhere, $root_junie."
} >"$fixture/commands/orch.md"
flags "the scan flags a Junie step outside the plugin-root sentence" \
  "$(scan_orch_resolution "$fixture")" "commands/orch.md: names the plugin root without the Junie step"
{ documented_orch_form
  plugin_root_fence
  printf '%s\n' "$root_fallback found as for \`ORCH\`:" \
    "$root_junie, else two directories above this skill's own directory."
} >"$fixture/commands/orch.md"
assert_empty "the scan accepts a plugin-root path with its unset fallback" \
  "$(scan_orch_resolution "$fixture")"
check "every skill and command resolves orch.sh the one documented way" \
  "$(scan_orch_resolution "$PLUGIN_ROOT")"

# Some hosts drop the execute bit on install or update, so orch.sh is always
# run through bash, quoted or not (#142; docs/host-capabilities.md, "Execute bit").
# scan_orch_bash <plugin root>: print one line per call site that skips bash.
scan_orch_bash() {
  local r="$1" f
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}" "$r"/commands/*.md \
           "$r"/README.md "$r"/CONTRIBUTING.md "$r"/docs/how-it-works.md \
           "$r"/docs/junie/README.md "$r"/docs/host-capabilities.md; do
    [ -f "$f" ] || continue
    sed 's/bash "\$ORCH"//g' "$f" | grep -nE '\$\{?ORCH\b' \
      | sed -E "s|^([0-9]+):|${f#"$r"/}:\\1: runs orch.sh without bash: |"
  done
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-x" "$fixture/docs"
printf 'Run `bash "$ORCH" status`.\nRun `"$ORCH" doctor`.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Run `"$ORCH" doctor`.\n' >"$fixture/skills/orch-x/ref.md"
printf 'Run `${ORCH} status`.\n' >"$fixture/README.md"
printf 'Run `${ORCH} status`.\n' >"$fixture/CONTRIBUTING.md"
printf 'Then `${ORCH} doctor`.\n' >"$fixture/docs/how-it-works.md"
mkdir -p "$fixture/docs/junie"
printf 'Run `${ORCH} status`.\n' >"$fixture/docs/junie/README.md"
out="$(scan_orch_bash "$fixture")"
flags "the scan flags a quoted \$ORCH run without bash" "$out" "skills/orch-x/SKILL.md:2: runs orch.sh without bash"
flags "the scan flags \${ORCH} run without bash" "$out" "README.md:1: runs orch.sh without bash"
flags "the scan flags \${ORCH} without bash in CONTRIBUTING.md" "$out" "CONTRIBUTING.md:1: runs orch.sh without bash"
flags "the scan flags \${ORCH} without bash in docs/how-it-works.md" "$out" "docs/how-it-works.md:1: runs orch.sh without bash"
flags "the scan flags \${ORCH} without bash in docs/junie/README.md" "$out" "docs/junie/README.md:1: runs orch.sh without bash"
flags "the scan flags \$ORCH run without bash in a skill's reference file" "$out" "skills/orch-x/ref.md:1: runs orch.sh without bash"
spares "the scan accepts bash \"\$ORCH\"" "$out" 'SKILL.md:1:'
check "every skill and doc runs orch.sh through bash" "$(scan_orch_bash "$PLUGIN_ROOT")"

# A skill's commands name the plugin root through CLAUDE_PLUGIN_ROOT, never a
# "<plugin root>" placeholder the driver must work out for itself (#155).
# scan_plugin_root_placeholder <plugin root>: each <plugin root>/ placeholder.
scan_plugin_root_placeholder() {
  local r="$1" f
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}" "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -nF '<plugin root>/' "$f" \
      | sed -E "s|^([0-9]+):.*|${f#"$r"/}:\\1: <plugin root>/ placeholder|"
  done
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-x" "$fixture/commands"
printf 'Read `<plugin root>/agents/orch-fixer.md`.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Run `<plugin root>/scripts/orch.sh`.\n' >"$fixture/commands/x.md"
printf 'Read `<plugin root>/agents/orch-fixer.md`.\n' >"$fixture/skills/orch-x/ref.md"
out="$(scan_plugin_root_placeholder "$fixture")"
flags "the scan flags a <plugin root> placeholder in a skill" "$out" "skills/orch-x/SKILL.md:1: <plugin root>/ placeholder"
flags "the scan flags a <plugin root> placeholder in a command" "$out" "commands/x.md:1: <plugin root>/ placeholder"
flags "the scan flags a <plugin root> placeholder in a skill's reference file" "$out" "skills/orch-x/ref.md:1: <plugin root>/ placeholder"
check "no skill or command carries a <plugin root> placeholder" "$(scan_plugin_root_placeholder "$PLUGIN_ROOT")"

# --- skills-only stop text (#128, #121) ---------------------------------------
# With no full install at all, doctor has no orch.sh to run from, so the skill
# is the one that has to explain the failure (#128). One stop text, copied
# into each skill, checked only as a copy-match against orch-flow's (ADR-0027):
# once the Junie install is verified (#121), every copy must change together,
# so they may not drift apart.
echo
echo "skills-only stop text (#128, #121)"
# stop_text <file>: the stop text, located by its first and last lines - the
# copy-match's anchor, not a pinned phrase.
# Not a section read: the stop text is anchored by its own lines, not a heading.
stop_text() { awk '/^If `orch.sh` is at none of these paths/,/which is unverified\)\.$/' "$1"; }
# scan_stop_text <plugin root>: each skill off orch-flow's stop text.
scan_stop_text() {
  local r="$1" f ref n
  ref="$(stop_text "$r/skills/orch-flow/SKILL.md")"
  if [ -z "$ref" ]; then
    echo "skills/orch-flow/SKILL.md: carries no skills-only stop text"
    return 0
  fi
  for f in "$r"/skills/*/SKILL.md; do
    n="${f#"$r"/}"
    [ "$(stop_text "$f")" = "$ref" ] ||
      echo "$n: skills-only stop text differs from orch-flow's"
  done
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-flow" "$fixture/skills/orch-same" "$fixture/skills/orch-drift" "$fixture/skills/orch-none"
stop='If `orch.sh` is at none of these paths, stop: this is a skills-only install. Install the full plugin (or as a Junie extension, which is unverified).'
printf '%s\n' "$stop" >"$fixture/skills/orch-flow/SKILL.md"
printf '%s\n' "$stop" >"$fixture/skills/orch-same/SKILL.md"
printf '%s\n' "${stop/the full plugin/it all}" >"$fixture/skills/orch-drift/SKILL.md"
printf 'No stop text here.\n' >"$fixture/skills/orch-none/SKILL.md"
out="$(scan_stop_text "$fixture")"
flags "the scan flags stop text that drifts from orch-flow's" "$out" "skills/orch-drift/SKILL.md: skills-only stop text differs from orch-flow's"
flags "the scan flags a skill with no stop text" "$out" "skills/orch-none/SKILL.md: skills-only stop text differs from orch-flow's"
spares "the scan accepts a word-for-word copy" "$out" 'orch-same'
printf 'No stop text in a reference file.\n' >"$fixture/skills/orch-flow/ref.md"
spares "a reference file is not asked for the stop text" "$(scan_stop_text "$fixture")" 'ref\.md'
printf 'No stop text here.\n' >"$fixture/skills/orch-flow/SKILL.md"
flags "the scan flags orch-flow with no stop text to match" \
  "$(scan_stop_text "$fixture")" "skills/orch-flow/SKILL.md: carries no skills-only stop text"
# The rule is a copy-match only (ADR-0027): a stop text worded any other way
# between its anchor lines passes, so long as every copy matches orch-flow's.
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-flow" "$fixture/skills/orch-same"
stop='If `orch.sh` is at none of these paths, stop and install it whole (the Junie route, which is unverified).'
printf '%s\n' "$stop" >"$fixture/skills/orch-flow/SKILL.md"
printf '%s\n' "$stop" >"$fixture/skills/orch-same/SKILL.md"
assert_empty "the scan accepts any wording between the anchors, copied word for word" "$(scan_stop_text "$fixture")"
check "every skill carries orch-flow's skills-only stop text word for word" "$(scan_stop_text "$PLUGIN_ROOT")"

# --- Junie snippet names every agent (#264) -----------------------------------
# JUNIE-5493's workaround: docs/junie/AGENTS.md names every agent so Junie's
# capability filter keeps it visible. Delete this rule along with the snippet
# once JUNIE-5493 is fixed.
echo
echo "Junie snippet names every agent (#264)"
# scan_junie_snippet_drift <plugin root>: each agents/*.md the snippet does not name.
# It checks names only, not which skill lists which agent: that per-skill
# mapping is hand-kept, an accepted drift for a temporary workaround.
scan_junie_snippet_drift() {
  local r="$1" a n
  for a in "$r"/agents/*.md; do
    [ -f "$a" ] || continue
    n="$(basename "$a" .md)"
    grep -qw -- "$n" "$r/docs/junie/AGENTS.md" 2>/dev/null ||
      echo "agents/$n.md: not named in docs/junie/AGENTS.md"
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents" "$fixture/docs/junie"
printf -- '---\nname: orch-named\n---\n' >"$fixture/agents/orch-named.md"
printf -- '---\nname: orch-extra\n---\n' >"$fixture/agents/orch-extra.md"
printf 'Start `orch-named` by name.\n' >"$fixture/docs/junie/AGENTS.md"
out="$(scan_junie_snippet_drift "$fixture")"
flags "the drift check flags an agent the snippet omits" "$out" "agents/orch-extra.md: not named in docs/junie/AGENTS.md"
spares "the drift check accepts an agent the snippet names" \
  "$out" 'orch-named'
check "the Junie snippet names every agent" "$(scan_junie_snippet_drift "$PLUGIN_ROOT")"

# --- Junie snippet finds the plugin (#416) ------------------------------------
# Junie's agent shell has no plugin-root variable, and its capability filter
# can hide an orch-* skill or agent. The snippet's permanent "finding the
# plugin" section carries the orch.sh lookup the skills state, so a session
# resolves it once, and points at docs/host-capabilities.md for the fallback
# when a piece is hidden. Unlike the JUNIE-5493 section, it stays.
echo
echo "Junie snippet finds the plugin (#416)"
junie_find_heading='## orchestrator plugin: finding the plugin'
# scan_junie_snippet_lookup <plugin root>: one line per thing the snippet's
# finding-the-plugin section lacks.
scan_junie_snippet_lookup() {
  local f="$1/docs/junie/AGENTS.md" body flat
  if ! body="$(md_section "$f" "$junie_find_heading" 2>/dev/null)"; then
    echo "docs/junie/AGENTS.md: no '$junie_find_heading' section"
    return 0
  fi
  flat="$(flat_text <<<"$body")"
  [[ "$flat" == *"$orch_lookup"* ]] ||
    echo "docs/junie/AGENTS.md: finding the plugin without the orch.sh lookup, in order"
  [[ "$flat" == *"docs/host-capabilities.md"* ]] ||
    echo "docs/junie/AGENTS.md: finding the plugin never points at docs/host-capabilities.md"
  return 0
}
# junie_find_section [line]...: the section's heading, then each line given.
junie_find_section() { printf '%s\n' '<!-- orchestrator:begin -->' "$junie_find_heading" "$@" '<!-- orchestrator:end -->'; }
fixture="$(new_fixture)"
mkdir -p "$fixture/docs/junie"
printf '%s\n' '## orchestrator plugin: planning' "$orch_junie (the Junie CLI install)." "$orch_junie_one" "$orch_junie_many" \
  'See docs/host-capabilities.md.' >"$fixture/docs/junie/AGENTS.md"
flags "the lookup check flags a snippet with no finding-the-plugin section" \
  "$(scan_junie_snippet_lookup "$fixture")" "docs/junie/AGENTS.md: no '$junie_find_heading' section"
junie_find_section "$orch_junie (the Junie CLI install)." "$orch_junie_many" 'See docs/host-capabilities.md.' \
  >"$fixture/docs/junie/AGENTS.md"
flags "the lookup check flags a lookup missing its one-install step" \
  "$(scan_junie_snippet_lookup "$fixture")" "docs/junie/AGENTS.md: finding the plugin without the orch.sh lookup"
junie_find_section "$orch_junie (the Junie CLI install)." "$orch_junie_many" "$orch_junie_one" 'See docs/host-capabilities.md.' \
  >"$fixture/docs/junie/AGENTS.md"
flags "the lookup check flags the lookup's steps out of order" \
  "$(scan_junie_snippet_lookup "$fixture")" "docs/junie/AGENTS.md: finding the plugin without the orch.sh lookup"
junie_find_section "$orch_junie (the Junie CLI install)." "$orch_junie_one" "$orch_junie_many" >"$fixture/docs/junie/AGENTS.md"
out="$(scan_junie_snippet_lookup "$fixture")"
flags "the lookup check flags a section that never points at the reference" \
  "$out" "docs/junie/AGENTS.md: finding the plugin never points at docs/host-capabilities.md"
spares "the lookup check accepts the lookup in order" "$out" 'orch\.sh lookup'
junie_find_section "$orch_junie (the Junie CLI install)." "$orch_junie_one" "$orch_junie_many" '## other section' \
  'See docs/host-capabilities.md.' >"$fixture/docs/junie/AGENTS.md"
flags "the lookup check flags a reference only outside the section" \
  "$(scan_junie_snippet_lookup "$fixture")" "docs/junie/AGENTS.md: finding the plugin never points at docs/host-capabilities.md"
junie_find_section "$orch_junie (the Junie CLI install)." "$orch_junie_one" "$orch_junie_many" \
  'See docs/host-capabilities.md.' >"$fixture/docs/junie/AGENTS.md"
spares "the lookup check accepts a complete section" "$(scan_junie_snippet_lookup "$fixture")" '.'
check "the Junie snippet finds the plugin" "$(scan_junie_snippet_lookup "$PLUGIN_ROOT")"

# --- host capabilities (#127) -------------------------------------------------
echo
echo "host capabilities (#127)"
# Skills describe capabilities and point at one reference that maps each
# capability to each host, so a host without Claude Code's tools can still
# follow them. Commands are Claude-only shortcuts and hold no behaviour of
# their own: each routes to an orch- skill, or a section of one, that exists.

# scan_capability_pointer <plugin root>: each skill, and each agent that
# invokes a mattpocock-skills skill, that never points at the reference. An
# agent brief names host capabilities as a skill does (#157); only one that
# invokes a mattpocock-skills skill must point at the reference, since the
# others name no capability a host could lack.
scan_capability_pointer() {
  local r="$1" f
  for f in "$r"/skills/*/SKILL.md "$r"/agents/*.md; do
    [ -f "$f" ] || continue
    if [[ "$f" != "$r"/agents/* ]] || grep -qE 'mattpocock-skills:[a-z]' "$f"; then
      grep -qF 'docs/host-capabilities.md' "$f" \
        || echo "${f#"$r"/}: never points at docs/host-capabilities.md"
    fi
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-x" "$fixture/skills/orch-y" "$fixture/agents"
printf 'Invoke the skill `x`.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Invoke the skill `x` (see docs/host-capabilities.md).\n' >"$fixture/skills/orch-y/SKILL.md"
printf 'Invoke the skill `x`.\n' >"$fixture/skills/orch-y/ref.md"
printf 'Fix it through the `mattpocock-skills:tdd` skill.\n' >"$fixture/agents/orch-z.md"
printf 'Fix it through the `mattpocock-skills:tdd` skill (see docs/host-capabilities.md).\n' >"$fixture/agents/orch-p.md"
printf 'Read the diff and write the report.\n' >"$fixture/agents/orch-q.md"
out="$(scan_capability_pointer "$fixture")"
flags "the scan flags a skill that never points at the reference" \
  "$out" "skills/orch-x/SKILL.md: never points at docs/host-capabilities.md"
flags "the scan flags an agent that never points at the reference" \
  "$out" "agents/orch-z.md: never points at docs/host-capabilities.md"
spares "the scan accepts a skill that points at the reference" "$out" '^skills/orch-y/'
spares "a reference file is not asked for its own pointer" "$out" 'ref\.md'
spares "the scan accepts an agent that points at the reference" "$out" '^agents/orch-p\.md:'
spares "the scan accepts an agent that invokes no skill without the pointer" "$out" '^agents/orch-q\.md:'
check "every skill, and every agent invoking a mattpocock-skills skill, points at the reference" \
  "$(scan_capability_pointer "$PLUGIN_ROOT")"

# scan_claude_scoped_names <plugin root>: each line of a skill or agent that
# names a skill by its Claude-scoped name. Junie has no plugin scope, so a
# skill names its siblings bare (orch-flow); the Claude-scoped form is only
# ever the generic orchestrator:<name>.
scan_claude_scoped_names() {
  local r="$1" f
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}" "$r"/agents/*.md; do
    [ -f "$f" ] || continue
    grep -nE 'orchestrator:orch-' "$f" \
      | sed "s|^|${f#"$r"/}: names a skill by its Claude-scoped name: |"
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-flow" "$fixture/skills/orch-x"
printf 'Invoke `orchestrator:orch-handoff`.\n' >"$fixture/skills/orch-flow/SKILL.md"
printf 'Then invoke `orchestrator:orch-sync`.\n' >"$fixture/skills/orch-x/ref.md"
printf 'Invoke the `orch-handoff` skill (`orchestrator:<name>` on Claude Code).\n' >"$fixture/skills/orch-x/SKILL.md"
out="$(scan_claude_scoped_names "$fixture")"
flags "the scan flags a sibling skill named by its Claude scope" \
  "$out" "skills/orch-flow/SKILL.md: names a skill by its Claude-scoped name"
flags "the scan flags a Claude-scoped skill name in a skill's reference file" \
  "$out" "skills/orch-x/ref.md: names a skill by its Claude-scoped name"
spares "the scan accepts a bare skill name and the generic scoped form" "$out" '^skills/orch-x/SKILL\.md'
check "no skill or agent names a skill by its Claude-scoped name" \
  "$(scan_claude_scoped_names "$PLUGIN_ROOT")"

# scan_ask_tool_names <plugin root>: one line per sentence of a skill or agent
# that names Claude Code's ask tool without Junie's. A sentence that copies one
# host's tool from docs/host-capabilities.md's "Ask a multiple-choice question"
# row copies the other host's tool too (ADR-0027). Each file is read as one
# line and split into sentences at ". ", so a name wrapped across lines still
# counts; docs/ is not scanned, since parts of it are Claude-only on purpose.
scan_ask_tool_names() {
  local r="$1" f
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}" "$r"/agents/*.md; do
    [ -f "$f" ] || continue
    flat_text "$f" | awk -v file="${f#"$r"/}" '{
      n = split($0, s, /\. /)
      for (i = 1; i <= n; i++)
        if (index(s[i], "AskUserQuestion") && !index(s[i], "ask_user"))
          print file ": names AskUserQuestion without ask_user"
    }'
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-a" "$fixture/skills/orch-b" "$fixture/skills/orch-c" \
  "$fixture/skills/orch-d" "$fixture/agents"
printf 'Ask the human with the `AskUserQuestion` tool. Then carry on.\n' \
  >"$fixture/skills/orch-a/SKILL.md"
printf 'Ask one question\n(`AskUserQuestion` on both Claude Code and Junie). Ask once.\n' \
  >"$fixture/skills/orch-b/SKILL.md"
printf 'Ask with `AskUserQuestion`. Junie has `ask_user`.\n' >"$fixture/skills/orch-c/SKILL.md"
printf 'Ask with the host'"'"'s ask tool (`AskUserQuestion` on Claude Code,\n`ask_user` on Junie). Then carry on.\n' \
  >"$fixture/skills/orch-d/SKILL.md"
printf 'Ask the human with `AskUserQuestion`.\n' >"$fixture/agents/orch-z.md"
printf 'Ask the human with `AskUserQuestion`.\n' >"$fixture/skills/orch-d/ref.md"
out="$(scan_ask_tool_names "$fixture")"
flags "the scan flags a skill sentence naming AskUserQuestion alone" \
  "$out" "skills/orch-a/SKILL.md: names AskUserQuestion without ask_user"
flags "the scan flags AskUserQuestion said to exist on both hosts" \
  "$out" "skills/orch-b/SKILL.md: names AskUserQuestion without ask_user"
flags "the scan flags ask_user only in the next sentence" \
  "$out" "skills/orch-c/SKILL.md: names AskUserQuestion without ask_user"
flags "the scan flags an agent sentence naming AskUserQuestion alone" \
  "$out" "agents/orch-z.md: names AskUserQuestion without ask_user"
flags "the scan flags a reference-file sentence naming AskUserQuestion alone" \
  "$out" "skills/orch-d/ref.md: names AskUserQuestion without ask_user"
spares "the scan accepts both hosts' ask tools wrapped across lines" "$out" '^skills/orch-d/SKILL\.md'
check "every skill or agent sentence naming AskUserQuestion also names ask_user" \
  "$(scan_ask_tool_names "$PLUGIN_ROOT")"

# scan_offered_commands <plugin root>: each plugin command a skill or agent
# offers that has no commands/<cmd>.md. That file is the route
# scan_command_routes checks reaches a skill section.
scan_offered_commands() {
  local r="$1" f cmd
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}" "$r"/agents/*.md; do
    [ -f "$f" ] || continue
    for cmd in $(grep -oE '/orchestrator:[a-z][a-z-]*' "$f" | sed 's|^/orchestrator:||' | sort -u); do
      [ -f "$r/commands/$cmd.md" ] \
        || echo "${f#"$r"/}: offers /orchestrator:$cmd, which has no commands/$cmd.md"
    done
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-x" "$fixture/skills/orch-y" "$fixture/agents" "$fixture/commands"
printf 'Offer `/orchestrator:abort`.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Offer `/orchestrator:nope 12`.\n' >"$fixture/agents/orch-z.md"
printf 'Offer `/orchestrator:status`.\n' >"$fixture/skills/orch-y/SKILL.md"
printf 'Offer `/orchestrator:gone`.\n' >"$fixture/skills/orch-y/ref.md"
: >"$fixture/commands/status.md"
out="$(scan_offered_commands "$fixture")"
flags "the scan flags a skill offering a plugin command with no command file" \
  "$out" "skills/orch-x/SKILL.md: offers /orchestrator:abort, which has no commands/abort.md"
flags "the scan flags an agent offering a plugin command with no command file" \
  "$out" "agents/orch-z.md: offers /orchestrator:nope, which has no commands/nope.md"
flags "the scan flags a reference file offering a plugin command with no command file" \
  "$out" "skills/orch-y/ref.md: offers /orchestrator:gone, which has no commands/gone.md"
spares "the scan accepts a plugin command that has a command file" "$out" '^skills/orch-y/SKILL\.md'
check "every plugin command a skill or agent offers has a command file" \
  "$(scan_offered_commands "$PLUGIN_ROOT")"

# scan_command_runs_orch <plugin root>: each command that runs orch.sh itself
# rather than leaving the work to the skill it routes to.
scan_command_runs_orch() {
  local r="$1" f
  for f in "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -qE 'orch\.sh|\$ORCH' "$f" && echo "${f#"$r"/}: runs orch.sh itself"
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/commands"
printf '%s\n' "$orch_line" >"$fixture/commands/status.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Status** section.\n' >"$fixture/commands/doctor.md"
out="$(scan_command_runs_orch "$fixture")"
flags "the scan flags a command that runs orch.sh itself" "$out" "commands/status.md: runs orch.sh itself"
spares "the scan accepts a command that only routes to a skill" "$out" '^commands/doctor\.md:'
check "no command runs orch.sh itself" "$(scan_command_runs_orch "$PLUGIN_ROOT")"

# scan_command_routes <plugin root>: each command that routes to no orch-
# skill, to a missing skill, or to a missing section of its skill. A command
# follows either one of its skill's sections (the flow steps, spec-review) or
# the whole skill (release, #139). The route may wrap across lines, so the
# file is read as one line.
scan_command_routes() {
  local r="$1" f route skill section body
  for f in "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    body="$(flat_text "$f")"
    route="$(grep -oE '`orchestrator:orch-[a-z-]+` and follow it(s \*\*[^*]+\*\* section|\.)' <<<"$body" | head -n1)"
    section="$(sed -n 's/.*follow its \*\*\([^*]*\)\*\* section$/\1/p' <<<"$route")"
    skill="$(sed 's/^`orchestrator://; s/`.*//' <<<"$route")"
    if [ -z "$skill" ]; then echo "${f#"$r"/}: routes to no orch- skill"
    elif [ ! -f "$r/skills/$skill/SKILL.md" ]; then echo "${f#"$r"/}: routes to a missing skill: $skill"
    elif [ -n "$section" ]; then md_section "$r/skills/$skill/SKILL.md" "## $section" >/dev/null \
      || echo "${f#"$r"/}: routes to a missing $skill section: $section"; fi
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-flow" "$fixture/skills/orch-y" "$fixture/commands"
printf '## Status\n' >"$fixture/skills/orch-flow/SKILL.md"
printf '## Solo run\n' >"$fixture/skills/orch-y/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Doctor** section.\n' >"$fixture/commands/doctor.md"
printf 'Do the thing.\n' >"$fixture/commands/none.md"
printf 'Invoke `orchestrator:orch-w` and follow it.\n' >"$fixture/commands/w.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Status** section.\n' >"$fixture/commands/status.md"
printf 'Invoke `orchestrator:orch-y` and follow it.\n' >"$fixture/commands/whole.md"
# A command may route to a named section of a skill other than orch-flow
# (spec-review, #185) - that section must exist in that skill.
printf 'Invoke `orchestrator:orch-y` and follow its **Deep run**\nsection.\n' >"$fixture/commands/deep.md"
printf 'Invoke `orchestrator:orch-y` and follow its **Solo run**\nsection.\n' >"$fixture/commands/solo.md"
out="$(scan_command_routes "$fixture")"
flags "the scan flags a command routed to a missing section" \
  "$out" "commands/doctor.md: routes to a missing orch-flow section: Doctor"
flags "the scan flags a command that routes to no skill" "$out" "commands/none.md: routes to no orch- skill"
flags "the scan flags a command routed to a missing skill" "$out" "commands/w.md: routes to a missing skill: orch-w"
flags "the scan flags a command routed to a missing section of its own skill" \
  "$out" "commands/deep.md: routes to a missing orch-y section: Deep run"
spares "the scan accepts a command routed to an existing orch-flow section" "$out" '^commands/status\.md:'
spares "the scan accepts a thin route to a whole skill" "$out" '^commands/whole\.md:'
spares "the scan accepts a wrapped route to an existing section of its own skill" "$out" '^commands/solo\.md:'
printf '## Solo run\n\n## Padded run  \n' >"$fixture/skills/orch-y/SKILL.md"
printf 'Invoke `orchestrator:orch-y` and follow its **Padded run** section.\n' >"$fixture/commands/padded.md"
spares "the scan accepts a route to a section whose heading ends in trailing whitespace" \
  "$(scan_command_routes "$fixture")" '^commands/padded\.md:'
check "every command is a thin route to an orch- skill section that exists" \
  "$(scan_command_routes "$PLUGIN_ROOT")"

# --- one definition of starting a plugin agent (#181) -------------------------
echo
echo "one definition of starting a plugin agent (#181)"
# The host fallback for starting a plugin agent lives once, in
# docs/host-capabilities.md, and orch-implementer's dispatch contract (prompt
# shape, six report lines) lives once too, in agents/orch-implementer.md - so
# a change to either is made at one site, not copied into every skill that
# starts an agent.
# scan_dispatch_copies <plugin root>: print one line per restated copy.
scan_dispatch_copies() {
  local r="$1" f line named
  local -a skill_files
  mapfile -t skill_files < <(skill_md_files "$r")
  for f in "${skill_files[@]}"; do
    [ -f "$f" ] || continue
    # The contract's one copy is the agent file, so any skill naming five or
    # more of the six report lines is a second copy: the five original ones
    # with `Evidence` or without it, or `Evidence` in place of one of them.
    named=0
    for line in Ticket Commits Verification Criteria Deviation Evidence; do
      grep -qF "\`$line\`" "$f" && named=$((named + 1))
    done
    if [ "$named" -ge 5 ]; then
      echo "${f#"$r"/}: restates the implementer's six report lines"
    fi
    # The general-purpose-agent tier: a general-purpose agent briefed with a
    # plugin agent's file. A general-purpose agent named with no agent file
    # is not the tier and is left alone.
    awk -v f="${f#"$r"/}" 'BEGIN { RS = "" }
      /general-purpose/ && (/agents\// || /agent'"'"'s file/) { print f ": restates the general-purpose-agent tier" }' "$f"
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/a" "$fixture/skills/b"
printf 'Returns `Ticket`, `Commits`, `Verification`, `Criteria`, `Deviation`.\n' >"$fixture/skills/a/SKILL.md"
printf 'Else start a fresh general-purpose agent\nbriefed with its file under `agents/`.\n' >"$fixture/skills/b/SKILL.md"
printf 'Returns `Ticket`, `Commits`, `Verification`, `Criteria`, `Deviation`.\n' >"$fixture/skills/b/ref.md"
mkdir -p "$fixture/skills/c"
printf 'Returns `Ticket`, `Commits`, `Verification`, `Criteria`, `Evidence`, `Deviation`.\n' \
  >"$fixture/skills/c/SKILL.md"
printf 'Returns `Ticket`, `Commits`, `Verification`, `Criteria`, `Evidence`.\n' >"$fixture/skills/c/ref.md"
out="$(scan_dispatch_copies "$fixture")"
flags "the scan flags the report lines copied into a skill's reference file" \
  "$out" "skills/b/ref.md: restates the implementer's six report lines"
flags "the scan flags the report lines copied into a skill" \
  "$out" "skills/a/SKILL.md: restates the implementer's six report lines"
flags "the scan flags all six report lines copied into a skill" \
  "$out" "skills/c/SKILL.md: restates the implementer's six report lines"
flags "the scan flags a copy that keeps \`Evidence\` and drops another report line" \
  "$out" "skills/c/ref.md: restates the implementer's six report lines"
flags "the scan flags a skill restating the general-purpose-agent tier" \
  "$out" "skills/b/SKILL.md: restates the general-purpose-agent tier"
printf 'Start the implementer as its agent file says.\n' >"$fixture/skills/a/SKILL.md"
printf 'Summarise the log with a fresh general-purpose agent.\n' >"$fixture/skills/b/SKILL.md"
printf 'Start the implementer as its agent file says.\n' >"$fixture/skills/b/ref.md"
printf 'Its report ends with `Evidence` and `Deviation`.\n' >"$fixture/skills/c/SKILL.md"
printf 'Start the implementer as its agent file says.\n' >"$fixture/skills/c/ref.md"
assert_empty "the scan accepts a pointer and a general-purpose agent with no agent file" \
  "$(scan_dispatch_copies "$fixture")"
check "the host fallback and the implementer's report are each stated once" \
  "$(scan_dispatch_copies "$PLUGIN_ROOT")"

# --- start sites read the agent setting (#1359) ------------------------------
echo
echo "start sites read the agent setting (#1359)"
# Every start of one of the plugin's agents runs on its role's agent setting,
# and the rule for that lives once, in docs/host-capabilities.md's **Agent
# settings** section. So every file that starts a plugin agent points at that
# section and names `agent get <role>` for each role it starts. A file starts
# an agent when, read flattened, it starts one under the `orchestrator:`
# plugin scope (the scope named, `subagent_type`, or `orchestrator:<agent>`) -
# its roles then come from the orch- agent names it gives, never from an
# agent's file path - or when it points
# at a shared section that starts one: **Dispatching a subagent** starts the
# implementer, **A driver's base sync** and **A driver's ticket resolution**
# the resolver. A skill's scoped name, such as `orchestrator:orch-flow`, is
# not a start, and a **Start a fresh subagent** pointer is not a read.
# agent_role <agent name>: the role an orch- agent's setting is read under.
agent_role() {
  case "$1" in
    orch-lens-*) echo lens ;;
    orch-reviewer-*) echo reviewer ;;
    orch-*) echo "${1#orch-}" ;;
  esac
}
# agent_start_files <plugin root>: every skill file, agent file and docs/
# file a start site can live in, one path per line.
agent_start_files() {
  skill_md_files "$1"
  find "$1/agents" "$1/docs" -name '*.md' -type f 2>/dev/null | sort
  return 0
}
# scan_agent_settings <plugin root>: one line per role a start site starts
# without reading its setting.
scan_agent_settings() {
  local r="$1" f text name roles role
  local -a files
  mapfile -t files < <(agent_start_files "$r")
  for f in "${files[@]}"; do
    text="$(flat_text "$f")"
    roles=""
    if grep -qE '`orchestrator:` plugin scope|subagent_type|orchestrator:<agent>|orchestrator:orch-(implementer|lens-|reviewer-|fixer|closer|resolver)' <<<"$text"; then
      # An agent's file path, such as agents/orch-fixer.md, names a file to
      # read, not an agent to start.
      while IFS= read -r name; do
        case "$name" in /* | *.md | '') continue ;; esac
        roles+=" $(agent_role "$name")"
      done < <(grep -oE '/?\borch-(implementer|lens-[a-z]+|reviewer-[a-z]+|fixer|closer|resolver)\b(\.md)?' <<<"$text")
    fi
    grep -qF '**Dispatching a subagent**' <<<"$text" && roles+=" implementer"
    grep -qE "\*\*A driver's (base sync|ticket resolution)\*\*" <<<"$text" && roles+=" resolver"
    [ -n "$roles" ] || continue
    if ! grep -qE '\*\*Agent settings\*\*|#agent-settings\)' <<<"$text"; then
      echo "${f#"$r"/}: starts a plugin agent but does not point at **Agent settings**"
    fi
    for role in $(tr ' ' '\n' <<<"$roles" | sort -u); do
      grep -qF "agent get $role" <<<"$text" ||
        echo "${f#"$r"/}: starts an agent of the $role role but does not name agent get $role"
    done
  done
  return 0
}
# scan_agent_settings_section <plugin root>: docs/host-capabilities.md has
# the **Agent settings** heading before **Fallbacks**, and the Claude Code
# cell of its Start a fresh subagent row links to it. Structure only
# (ADR-0027): the rule's wording is left to review.
scan_agent_settings_section() {
  local doc="docs/host-capabilities.md"
  awk -F'|' -v f="$doc" '
    /^## Agent settings[[:space:]]*$/ && !settings { settings = NR }
    /^## Fallbacks[[:space:]]*$/ && !fallbacks { fallbacks = NR }
    /^\| Start a fresh subagent \|/ { row = 1; if ($3 ~ /\(#agent-settings\)/) linked = 1 }
    END {
      if (!settings) print f ": has no ## Agent settings section"
      else if (fallbacks && fallbacks < settings) print f ": ## Agent settings is not before ## Fallbacks"
      if (!row) print f ": has no Start a fresh subagent row"
      else if (!linked) print f ": the Start a fresh subagent Claude Code cell does not link to #agent-settings"
    }' "$1/$doc"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/a" "$fixture/skills/b" "$fixture/skills/c" "$fixture/agents" "$fixture/docs"
printf 'Start `orch-reviewer-spec` with the Agent tool, `subagent_type` set to\n`orchestrator:<agent>`, as **Start a fresh subagent** says.\n' \
  >"$fixture/skills/a/SKILL.md"
printf 'Start `orch-fixer` under the `orchestrator:`\nplugin scope. Read `agent get fixer`\nper **Agent settings** in `docs/host-capabilities.md`.\nIts record is in `agents/orch-closer.md`.\n' \
  >"$fixture/skills/b/SKILL.md"
printf 'Run the flow with `orchestrator:orch-flow`, then follow **A driver'"'"'s base sync**.\n' \
  >"$fixture/skills/c/SKILL.md"
printf '## Dispatching a subagent\n\nStart `orch-implementer` under the `orchestrator:` plugin scope, reading\n`agent get implementer` per [Agent settings](host-capabilities.md#agent-settings).\n' \
  >"$fixture/docs/loop.md"
printf 'Follow **Dispatching a subagent** in `docs/loop.md`.\n' >"$fixture/agents/orch-x.md"
out="$(scan_agent_settings "$fixture")"
flags "a start site with no read is flagged for its pointer" \
  "$out" "skills/a/SKILL.md: starts a plugin agent but does not point at **Agent settings**"
flags "a start site with no read is flagged for its role" \
  "$out" "skills/a/SKILL.md: starts an agent of the reviewer role but does not name agent get reviewer"
spares "a start site with a read is accepted, its read wrapped across lines" "$out" '^skills/b/'
spares "an agent's file path is not a start of that agent" "$out" 'starts a closer'
spares "a linked Agent settings pointer counts as a read" "$out" '^docs/loop\.md'
flags "a pointer at a driver's base sync starts the resolver" \
  "$out" "skills/c/SKILL.md: starts an agent of the resolver role but does not name agent get resolver"
spares "a skill's scoped name is not a start" "$out" 'skills/c/SKILL.md: starts an agent of the (implementer|lens|reviewer|fixer|closer) '
flags "a pointer at Dispatching a subagent starts the implementer" \
  "$out" "agents/orch-x.md: starts an agent of the implementer role but does not name agent get implementer"
check "every start site points at Agent settings and reads each role it starts" \
  "$(scan_agent_settings "$PLUGIN_ROOT")"

fixture="$(new_fixture)"
mkdir -p "$fixture/docs"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  '| Start a fresh subagent | The Agent tool. | Ignored ([settings](#agent-settings)). |' \
  '' '## Fallbacks' '' '## Agent settings' >"$fixture/docs/host-capabilities.md"
out="$(scan_agent_settings_section "$fixture")"
flags "an Agent settings section after Fallbacks is flagged" \
  "$out" "docs/host-capabilities.md: ## Agent settings is not before ## Fallbacks"
flags "a Claude Code cell with no link to Agent settings is flagged" \
  "$out" "docs/host-capabilities.md: the Start a fresh subagent Claude Code cell does not link to #agent-settings"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  '| Start a fresh subagent | The Agent tool, on its [setting](#agent-settings). | Ignored. |' \
  '' '## Agent settings' '' '## Fallbacks' >"$fixture/docs/host-capabilities.md"
assert_empty "Agent settings before Fallbacks and a linked Claude Code cell are accepted" \
  "$(scan_agent_settings_section "$fixture")"
check "docs/host-capabilities.md has Agent settings before Fallbacks, linked from the table" \
  "$(scan_agent_settings_section "$PLUGIN_ROOT")"

# --- spec-review lenses run as plugin agents (#177) ---------------------------
echo
echo "spec-review lenses run as plugin agents (#177)"
# Each lens owns its brief as a plugin agent, the way the review
# loop's reviewers own theirs (ADR-0018), so orch-spec-review carries only the
# lens-to-agent table, and the host fallback runs a lens from its agent file.
# scan_lens_briefs <plugin root>: print one line per brief out of place. The
# briefs' one copy is each lens agent's `## Brief` section, so the check is on
# structure, never on the briefs' wording: every lens agent has a non-empty
# `## Brief`, and no orch-spec-review .md file has a `**<Lens> brief.**` heading. Each
# lens agent also has Write in its tools: list and a `## The findings file`
# section, the file it writes its findings to.
lenses="fidelity consistency testability implementability"
scan_lens_briefs() {
  local r="$1" lens a heading brief f
  for lens in $lenses; do
    a="$r/agents/orch-lens-$lens.md"
    if [ -f "$a" ]; then
      if ! brief="$(md_section "$a" "## Brief")"; then
        echo "${a#"$r"/}: has no ## Brief section"
      elif ! grep -q '[^[:space:]]' <<<"$brief"; then
        echo "${a#"$r"/}: has an empty ## Brief section"
      fi
      # A lens writes its findings to one file (#1115), so it needs Write and
      # a brief section saying which file.
      grep -m1 '^tools:' "$a" | tr -d '[] ' | tr ',' '\n' | grep -qx 'tools:Write\|Write' ||
        echo "${a#"$r"/}: has no Write in its tools: list"
      md_section "$a" "## The findings file" >/dev/null ||
        echo "${a#"$r"/}: has no ## The findings file section"
    fi
    heading="**${lens^} brief.**"
    for f in "$r"/skills/orch-spec-review/*.md; do
      [ -f "$f" ] || continue
      grep -qF "$heading" "$f" && echo "${f#"$r"/}: carries the $heading heading"
    done
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents" "$fixture/skills/orch-spec-review"
printf -- '---\nname: orch-lens-fidelity\n---\n\n## Brief\n\n## Reporting rules\n\n- Under 400 words.\n' \
  >"$fixture/agents/orch-lens-fidelity.md"
printf -- '---\nname: orch-lens-consistency\n---\n\n# Consistency lens\n\nReport.\n' \
  >"$fixture/agents/orch-lens-consistency.md"
printf -- '---\nname: orch-lens-testability\ntools: [Read, Write]\n---\n\n## Brief\n\nReport seams.\n\n## Reporting rules\n\n## The findings file\n\nWrite it.\n' \
  >"$fixture/agents/orch-lens-testability.md"
printf -- '---\nname: orch-lens-implementability\ntools: [Read, Grep]\n---\n\n## Brief\n\nReport gaps.\n' \
  >"$fixture/agents/orch-lens-implementability.md"
printf 'Run the lenses.\n\n**Consistency brief.** Placeholder.\n' \
  >"$fixture/skills/orch-spec-review/SKILL.md"
printf 'A reference file.\n\n**Testability brief.** Placeholder.\n' \
  >"$fixture/skills/orch-spec-review/ref.md"
out="$(scan_lens_briefs "$fixture")"
flags "the scan flags an empty ## Brief section" \
  "$out" "agents/orch-lens-fidelity.md: has an empty ## Brief section"
flags "the scan flags a lens agent with no ## Brief heading" \
  "$out" "agents/orch-lens-consistency.md: has no ## Brief section"
spares "the scan accepts a brief with content" \
  "$out" 'orch-lens-testability'
flags "the scan flags a lens agent with no Write tool" \
  "$out" "agents/orch-lens-implementability.md: has no Write in its tools: list"
flags "the scan flags a lens agent with no findings-file section" \
  "$out" "agents/orch-lens-implementability.md: has no ## The findings file section"
flags "the scan flags a brief heading back in orch-spec-review" \
  "$out" "skills/orch-spec-review/SKILL.md: carries the **Consistency brief.** heading"
flags "the scan flags a brief heading in an orch-spec-review reference file" \
  "$out" "skills/orch-spec-review/ref.md: carries the **Testability brief.** heading"
check "each lens agent owns a non-empty brief and the skill carries none" \
  "$(scan_lens_briefs "$PLUGIN_ROOT")"

# --- required headings (#285) ------------------------------------------------
echo
echo "required headings (#285)"
# Some headings are load-bearing: a step or section that a model is sent to by
# name. Each must stay present exactly as written, in the listed order. The
# list holds skill and agent headings only, never glossary or ADR entries, and
# nothing below heading level.
# One "<file>|<heading>" pair per line, file relative to the plugin root, in
# the order the headings must appear within their file.
required_headings='agents/orch-fixer.md|## Checking the PR body
agents/orch-fixer.md|## The record
agents/orch-implementer.md|## Root-cause fixes
agents/orch-reviewer-standards.md|## Root-cause check
skills/orch-quick-implement/SKILL.md|## 1. Require a linked issue
skills/orch-quick-implement/SKILL.md|## 2. Run an unattended spec review
skills/orch-quick-implement/SKILL.md|## 3. Publish the ticket breakdown
skills/orch-quick-implement/SKILL.md|## 6. Review
skills/orch-quick-implement/SKILL.md|## 7. Open the PR
skills/orch-review-pass/SKILL.md|## Review pass
skills/orch-review-pass/SKILL.md|## Standalone review pass
skills/orch-spec-review/SKILL.md|## Standalone spec review
skills/orch-spec-review/SKILL.md|## Consolidation
skills/orch-spec-review/SKILL.md|## Disposition
skills/orch-spec-review/SKILL.md|## Applying the answer
skills/orch-spec-review/SKILL.md|## The changelog
skills/orch-spec-review/spec-phase.md|# Spec phase
skills/orch-spec-review/spec-phase.md|## Inputs
skills/orch-spec-review/tickets-follow-the-spec.md|# Tickets follow the spec
skills/orch-spec-review/unattended-spec-review.md|# Unattended spec review
skills/orch-to-spec/SKILL.md|## Rewrite the issue
skills/orch-to-spec/SKILL.md|## Unattended rewrite
skills/orch-to-tickets/SKILL.md|### 4. Quiz the user
skills/orch-to-tickets/SKILL.md|## Unattended breakdown
skills/orch-to-tickets/SKILL.md|## Ticket template'
# scan_required_headings <plugin root> [pairs]: each listed heading missing
# from its file, or found above the heading listed before it in that file.
scan_required_headings() {
  local r="$1" pairs="${2:-$required_headings}" file heading n last="" prev=0
  while IFS='|' read -r file heading; do
    [ -n "$file" ] || continue
    [ "$file" = "$last" ] || { last="$file"; prev=0; }
    n="$(grep -nxF -- "$heading" "$r/$file" 2>/dev/null | head -n1 | cut -d: -f1)"
    if [ -z "$n" ]; then echo "$file: missing required heading: $heading"
    elif [ "$n" -lt "$prev" ]; then echo "$file: required heading out of order: $heading"
    else prev="$n"; fi
  done <<<"$pairs"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/a" "$fixture/skills/b" "$fixture/skills/c"
printf '# A\n\n## One\n\ntext\n\n## Two\n' >"$fixture/skills/a/SKILL.md"
printf '# B\n\n## Two\n\n## One\n' >"$fixture/skills/b/SKILL.md"
printf '# C\n\n## One\n\n### Two\n' >"$fixture/skills/c/SKILL.md"
pairs='skills/a/SKILL.md|## One
skills/a/SKILL.md|## Two
skills/b/SKILL.md|## One
skills/b/SKILL.md|## Two
skills/c/SKILL.md|## One
skills/c/SKILL.md|## Two'
out="$(scan_required_headings "$fixture" "$pairs")"
flags "a required heading missing from its file is flagged" \
  "$out" "skills/c/SKILL.md: missing required heading: ## Two"
flags "required headings out of order are flagged" \
  "$out" "skills/b/SKILL.md: required heading out of order: ## Two"
spares "required headings present and in order are not flagged" \
  "$out" '^skills/a/'
check "every required heading is present and in order" \
  "$(scan_required_headings "$PLUGIN_ROOT")"

# --- orch- names resolve (#285) -----------------------------------------------
echo
echo "orch- names resolve (#285)"
# A backticked `orch-<name>` sends a model to a skill or an agent, so it must
# name a skills/<name>/ directory or an agents/<name>.md file. ADRs record
# history and may name what no longer exists.
# scan_orch_names <plugin root>: each backticked orch- name that resolves to
# neither a skill nor an agent, with its file and line.
scan_orch_names() {
  local r="$1" hit file line name
  (cd "$r" && grep -rnoE '`orch-[a-z0-9-]+`' skills agents commands docs README.md CONTRIBUTING.md 2>/dev/null) \
    | while IFS= read -r hit; do
        file="${hit%%:*}"; hit="${hit#*:}"
        line="${hit%%:*}"; name="${hit#*:}"; name="${name//\`/}"
        case "$file" in docs/adr/*) continue ;; esac
        [ -d "$r/skills/$name" ] || [ -f "$r/agents/$name.md" ] ||
          echo "$file:$line: names no skill or agent: $name"
      done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-real" "$fixture/agents" "$fixture/commands" "$fixture/docs/adr" "$fixture/docs/x"
printf -- '---\nname: orch-real\n---\nStart `orch-helper`, then `orch-ghost`.\n' >"$fixture/skills/orch-real/SKILL.md"
printf -- '---\nname: orch-helper\n---\nInvoke `orch-real`.\n' >"$fixture/agents/orch-helper.md"
printf 'Invoke `orch-phantom`.\n' >"$fixture/commands/c.md"
printf 'See `orch-lost`.\n' >"$fixture/docs/x/d.md"
printf 'Use `orch-missing`.\n' >"$fixture/README.md"
printf 'Use `orch-absent`.\n' >"$fixture/CONTRIBUTING.md"
printf 'Renamed `orch-retired`.\n' >"$fixture/docs/adr/0001-x.md"
out="$(scan_orch_names "$fixture")"
flags "an orch- name in a skill that resolves to nothing is flagged" \
  "$out" "skills/orch-real/SKILL.md:4: names no skill or agent: orch-ghost"
flags "an orch- name in a command that resolves to nothing is flagged" \
  "$out" "commands/c.md:1: names no skill or agent: orch-phantom"
flags "an orch- name in docs that resolves to nothing is flagged" \
  "$out" "docs/x/d.md:1: names no skill or agent: orch-lost"
flags "an orch- name in the README that resolves to nothing is flagged" \
  "$out" "README.md:1: names no skill or agent: orch-missing"
flags "an orch- name in CONTRIBUTING.md that resolves to nothing is flagged" \
  "$out" "CONTRIBUTING.md:1: names no skill or agent: orch-absent"
spares "orch- names of a skill or an agent are not flagged" \
  "$out" 'orch-(real|helper)$'
spares "ADRs may name an orch- name that no longer resolves" \
  "$out" 'orch-retired'
check "every backticked orch- name resolves to a skill or an agent" \
  "$(scan_orch_names "$PLUGIN_ROOT")"

# --- agent frontmatter (ADR-0026) --------------------------------------------
echo
echo "agent frontmatter (ADR-0026)"
# Every agent declares its name and its allowlist. Claude Code and Junie CLI
# both read a YAML flow list as the allowlist (#204, ADR-0024), and an agent
# listing Agent, Skill or AskUserQuestion could start sub-agents, invoke a
# skill, or block on a human (#262, ADR-0026). The fixer and the closer build
# as the implementer does, so their allowlists are copies of its.
# scan_agent_frontmatter <plugin root>: one line per agent off the rule.
scan_agent_frontmatter() {
  local r="$1" a n name t tool impl
  impl="$(grep -m1 '^tools:' "$r/agents/orch-implementer.md" 2>/dev/null)"
  for a in "$r"/agents/*.md; do
    [ -f "$a" ] || continue
    n="$(basename "$a" .md)"
    name="$(sed -n 's/^name: //p' "$a" | head -1)"
    [ "$name" = "$n" ] || echo "agents/$n.md: name: is '$name', not its file"
    t="$(grep -m1 '^tools:' "$a")" || { echo "agents/$n.md: declares no tools:"; continue; }
    case "$t" in
      'tools: ['*']') ;;
      *) echo "agents/$n.md: tools: is not a YAML flow list" ;;
    esac
    for tool in $(printf '%s\n' "${t#tools: }" | tr -d '[] ' | tr ',' ' '); do
      case "$tool" in
        Agent|Skill|AskUserQuestion) echo "agents/$n.md: lists $tool" ;;
      esac
    done
    case "$n" in
      orch-fixer|orch-closer)
        [ "$t" = "$impl" ] || echo "agents/$n.md: tools: is not the implementer's" ;;
    esac
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents"
printf -- '---\nname: orch-implementer\ntools: [Read, Bash]\n---\n' >"$fixture/agents/orch-implementer.md"
printf -- '---\nname: orch-fixer\ntools: [Read, Bash]\n---\n' >"$fixture/agents/orch-fixer.md"
printf -- '---\nname: orch-closer\ntools: [Read]\n---\n' >"$fixture/agents/orch-closer.md"
printf -- '---\nname: orch-other\ntools: Read, Bash\n---\n' >"$fixture/agents/orch-a.md"
printf -- '---\nname: orch-b\n---\n' >"$fixture/agents/orch-b.md"
printf -- '---\nname: orch-c\ntools: [Read, Skill]\n---\n' >"$fixture/agents/orch-c.md"
out="$(scan_agent_frontmatter "$fixture")"
flags "an agent whose name: is not its file is flagged" \
  "$out" "agents/orch-a.md: name: is 'orch-other', not its file"
flags "an agent whose tools: is not a list is flagged" \
  "$out" "agents/orch-a.md: tools: is not a YAML flow list"
flags "an agent with no tools: is flagged" "$out" "agents/orch-b.md: declares no tools:"
flags "an agent listing Skill is flagged" "$out" "agents/orch-c.md: lists Skill"
flags "a closer whose allowlist is not the implementer's is flagged" \
  "$out" "agents/orch-closer.md: tools: is not the implementer's"
spares "agents named for their files with a matching list are not flagged" \
  "$out" 'orch-(implementer|fixer)\.md'
check "every agent is named for its file and declares a safe tools: list" \
  "$(scan_agent_frontmatter "$PLUGIN_ROOT")"

# --- sub-issue endpoints (#179) -----------------------------------------------
echo
echo "sub-issue endpoints (#179)"
# orch.sh's ticket group is the one caller of GitHub's sub-issue endpoints, so
# no brief calls them itself: an agent finds its spec issue through `ticket
# parent`.
# scan_subissue_endpoints <plugin root>: each skill or agent line that calls one.
scan_subissue_endpoints() {
  (cd "$1" && grep -rnE 'gh api[^`]*(/parent|sub_issues)|issues/[^ ]*/(parent|sub_issues)' agents skills 2>/dev/null) \
    | sed -E 's/^([^:]+:[0-9]+):.*/\1: calls a sub-issue endpoint/'
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents" "$fixture/skills/orch-x"
printf 'Run `gh api repos/o/r/issues/7/parent`.\n' >"$fixture/agents/orch-a.md"
printf 'Run `gh api repos/o/r/issues/7/sub_issues`.\n' >"$fixture/skills/orch-x/SKILL.md"
printf 'Run `bash "$ORCH" ticket parent 7`.\n' >"$fixture/agents/orch-b.md"
out="$(scan_subissue_endpoints "$fixture")"
flags "an agent calling the parent endpoint is flagged" "$out" "agents/orch-a.md:1: calls a sub-issue endpoint"
flags "a skill calling the sub_issues endpoint is flagged" "$out" "skills/orch-x/SKILL.md:1: calls a sub-issue endpoint"
spares "ticket parent is not flagged" "$out" 'orch-b'
check "no agent or skill calls a sub-issue endpoint" "$(scan_subissue_endpoints "$PLUGIN_ROOT")"

# --- gh calls pinned to the repo (#520) ---------------------------------------
echo
echo "gh calls pinned to the repo (#520)"
# A gh call left to gh's own default repo reaches the upstream in a fork, so
# every gh call in a brief either goes through orch.sh or passes -R with the
# repo `orch.sh repo show --name` resolved. A call is `gh <group> <verb>`
# followed by an argument - a flag, a <placeholder>, a quote, or a $ - read up
# to the next backtick, pipe or semicolon; a bare `gh <group> <verb>` in
# running text is a mention, not a call. Each file is read with whitespace
# collapsed, so a call wrapped across lines is still seen.
# scan_unpinned_gh <plugin root>: each skill or agent gh call without -R.
scan_unpinned_gh() {
  local f call
  while IFS= read -r f; do
    while IFS= read -r call; do
      [ -n "$call" ] || continue
      grep -qE -- '(^| )(-R|--repo)( |=|$)' <<<"$call" && continue
      echo "${f#"$1"/}: gh call without -R: $call"
    done < <(flat_text "$f" | grep -oE -- "gh [a-z][a-z-]* [a-z][a-z-]* [-<\"'\$][^\`|;]*")
  done < <(find "$1/agents" "$1/skills" -name '*.md' 2>/dev/null | sort)
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents" "$fixture/skills/orch-x"
printf 'Read it: `gh issue view <n> --json body`.\n' >"$fixture/agents/orch-a.md"
printf 'Read it (`gh issue\n  view <n>`).\n' >"$fixture/skills/orch-x/SKILL.md"
printf '%s\n' 'Nothing calls `gh issue create` or `gh label create` directly.' \
  'Read it: `gh issue view <n> -R "$repo" --json body`.' >"$fixture/agents/orch-b.md"
out="$(scan_unpinned_gh "$fixture")"
flags "a gh call without -R is flagged" "$out" "agents/orch-a.md: gh call without -R: gh issue view <n>"
flags "a gh call wrapped across lines is flagged" \
  "$out" "skills/orch-x/SKILL.md: gh call without -R: gh issue view <n>"
spares "a bare gh command named in running text, or a call with -R, is not flagged" "$out" 'orch-b'
check "every gh call in an agent or skill passes -R" "$(scan_unpinned_gh "$PLUGIN_ROOT")"

# --- flow commands in script messages -----------------------------------------
echo
echo "flow commands in script messages"
# orch.sh's and doctor.sh's messages reach the model on every host, so they
# name a flow command only through flow_cmd, which adds the orch-flow section
# for a host with no plugin commands - and every section it names must exist.
# Both forms of a literal flow command are caught: /orchestrator:<cmd> written
# outside flow_cmd, and a remedy naming `orch.sh redo` or `orch.sh abort`,
# which works on no host as a flow step. A `usage:` string for redo or abort
# names the CLI itself, so it is spared, as are comments; a line with `usage:`
# elsewhere is not.
# scan_flow_cmd <plugin root>: each line of orch.sh or of a module in its
# orch/ directory naming a plugin command outside flow_cmd, each such line
# naming orch.sh redo or abort other than in its own usage: string, quoted any
# way, and each flow_cmd section orch-flow lacks.
scan_flow_cmd() {
  local r="$1" s
  (cd "$r" && grep -nE '/orchestrator:[a-z]' scripts/orch.sh scripts/orch/*.sh 2>/dev/null) \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | sed -E 's/^([^:]+:[0-9]+):.*/\1: names a plugin command outside flow_cmd/'
  (cd "$r" && grep -nE 'orch\.sh (redo|abort)' scripts/orch.sh scripts/orch/*.sh 2>/dev/null) \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | sed -E "s/usage: [\"']?orch\\.sh (redo|abort)//g" | grep -E 'orch\.sh (redo|abort)' \
    | sed -E 's/^([^:]+:[0-9]+):.*/\1: names a flow command literally, not through flow_cmd/'
  # Not a section read: this range is a shell function body in orch.sh or a module.
  (cd "$r" && awk '/^flow_cmd\(\)/,/^}/' scripts/orch.sh scripts/orch/*.sh 2>/dev/null) \
    | grep -oE 'section="[^"]+"' | sed 's/section="//; s/"$//' \
    | while IFS= read -r s; do
        md_section "$r/skills/orch-flow/SKILL.md" "## $s" >/dev/null 2>&1 ||
          echo "skills/orch-flow/SKILL.md: has no section flow_cmd names: $s"
      done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts/orch" "$fixture/skills/orch-flow"
printf '%s\n' 'flow_cmd() {' '  case "$1" in' '    start) section="Starting a flow" ;;' \
  '    next)  section="Next phase" ;;' '  esac' '  printf "/orchestrator:%s" "$1"' '}' \
  '# /orchestrator:next in a comment is fine' 'die "run /orchestrator:abort"' \
  'die "run orch.sh redo review"' 'die "run orch.sh abort"' '  die "usage: orch.sh redo review"' \
  '# orch.sh abort in a comment is fine' 'die "bad args (see usage: x); run orch.sh abort"' \
  '  die "usage: orch.sh abort"' "  die 'usage: orch.sh redo review'" "  die 'usage: orch.sh abort'" \
  '  echo usage: orch.sh redo review' '  echo usage: orch.sh abort' \
  'die "usage: orch.sh redo review; run orch.sh abort"' \
  >"$fixture/scripts/orch.sh"
printf '%s\n' 'echo ok' 'die "run orch.sh abort"' >"$fixture/scripts/orch/doctor.sh"
printf '# Flow\n\n## Starting a flow\n\n## Next steps\n' >"$fixture/skills/orch-flow/SKILL.md"
out="$(scan_flow_cmd "$fixture")"
flags "a script naming a plugin command outside flow_cmd is flagged" \
  "$out" "scripts/orch.sh:9: names a plugin command outside flow_cmd"
flags "a flow_cmd section orch-flow lacks is flagged" \
  "$out" "skills/orch-flow/SKILL.md: has no section flow_cmd names: Next phase"
flags "a die naming orch.sh redo is flagged" \
  "$out" "scripts/orch.sh:10: names a flow command literally, not through flow_cmd"
flags "a die naming orch.sh abort is flagged" \
  "$out" "scripts/orch.sh:11: names a flow command literally, not through flow_cmd"
flags "a die naming orch.sh abort in a module is flagged" \
  "$out" "scripts/orch/doctor.sh:2: names a flow command literally, not through flow_cmd"
spares "a comment and an existing section are not flagged" \
  "$out" ':8:|Starting a flow'
flags "a line with usage: elsewhere that names orch.sh abort is flagged" \
  "$out" "scripts/orch.sh:14: names a flow command literally, not through flow_cmd"
spares "a usage: line and a comment naming orch.sh redo or abort are not flagged" \
  "$out" ':12:|:13:'
spares "a double-quoted usage: string naming orch.sh abort is not flagged" \
  "$out" ':15:'
spares "a single-quoted usage: string naming orch.sh redo is not flagged" \
  "$out" ':16:'
spares "a single-quoted usage: string naming orch.sh abort is not flagged" \
  "$out" ':17:'
spares "an unquoted usage: string naming orch.sh redo is not flagged" \
  "$out" ':18:'
spares "an unquoted usage: string naming orch.sh abort is not flagged" \
  "$out" ':19:'
flags "a usage: string beside another literal flow command is flagged" \
  "$out" "scripts/orch.sh:20: names a flow command literally, not through flow_cmd"
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts/orch" "$fixture/skills/orch-flow"
printf '%s\n' 'flow_cmd() {' '  case "$1" in' '    pad) section="Padded step" ;;' '  esac' '}' \
  >"$fixture/scripts/orch.sh"
printf '# Flow\n\n## Padded step \t\n' >"$fixture/skills/orch-flow/SKILL.md"
assert_empty "a flow_cmd section whose orch-flow heading ends in trailing whitespace is not flagged" \
  "$(scan_flow_cmd "$fixture")"
check "the scripts name a plugin command only through flow_cmd, whose sections exist" \
  "$(scan_flow_cmd "$PLUGIN_ROOT")"

# --- no pipe into a quiet grep or head (#987, #1019) -------------------------
echo
echo "no pipe into a quiet grep or head (#987, #1019)"
# orch.sh runs under `set -euo pipefail`, and its modules and the gh fake it
# sources inherit it. In `printf '%s\n' "$v" | grep -q y`, grep exits as soon
# as it matches; a writer still writing later lines is killed by SIGPIPE and
# exits 141, and pipefail turns that into a false "no" although grep matched.
# It needs load to land, so it shows as a rare flake (#987). head exits the
# same way once it has its lines, and a writer with more than a pipe holds
# left to send fails on every run (#1019). The safe form passes the value as a
# herestring, `grep -q y <<<"$v"`, written in full before grep runs, and cuts
# lines with a reader of all its input, `awk -v n=1 'NR<=n'`. Every .sh under scripts/ is scanned, whether or not it sets
# pipefail, except scripts/test/, whose runners run outside orch.sh; the gh
# fake is scanned, since orch.sh sources it. A pipe is a single |, never ||.
# The quiet flags are -q or -m in any short-flag bundle or as a word, --quiet,
# --silent and --max-count, anywhere among that grep's words up to the next |,
# ;, && or ||. head is flagged whatever its flags, when it is the first word
# after the pipe, ending at whitespace, ), ;, &, | or the line's end, so
# `| header` is not. There are no exemptions. A line is judged whole: a trailing comment is not stripped,
# since # sits inside quoted patterns, and words are not parsed for quoting,
# so an option-shaped word inside a pattern counts too. Comment lines are
# spared. A pipe continued onto the next line with \ goes unseen.
# scan_early_exit_pipe <plugin root>: "<file>:<line>: <text>" for each line of
# a scanned script that pipes into a quiet grep or into head, <text> with
# leading whitespace trimmed.
scan_early_exit_pipe() {
  local f
  while IFS= read -r f; do
    case "$f" in scripts/test/gh_adapter_fake.sh) ;; scripts/test/*) continue ;; esac
    F="$f" awk '
      { t = $0; sub(/^[[:space:]]+/, "", t) }
      t ~ /^#/ { next }
      {
        s = t; gsub(/\|\|/, SUBSEP, s)
        n = split(s, seg, "|")
        for (i = 2; i <= n; i++) {
          g = seg[i]
          cut = length(g) + 1
          if ((k = index(g, ";")) && k < cut) cut = k
          if ((k = index(g, "&&")) && k < cut) cut = k
          if ((k = index(g, SUBSEP)) && k < cut) cut = k
          m = split(substr(g, 1, cut - 1), w, /[[:space:]]+/)
          j = 1; while (j <= m && w[j] == "") j++
          if (j <= m && w[j] ~ /^head([);&|]|$)/) { print ENVIRON["F"] ":" FNR ": " t; next }
          if (j > m || w[j] != "grep") continue
          for (j++; j <= m; j++) {
            o = w[j]; sub(/^["\047]+/, "", o)
            if (o ~ /^-[A-Za-z0-9]*[qm]/ || o ~ /^--(quiet|silent)$/ || o ~ /^--max-count(=|$)/) {
              print ENVIRON["F"] ":" FNR ": " t; next
            }
          }
        }
      }' "$1/$f"
  done < <(cd "$1" && find scripts -name '*.sh' 2>/dev/null | sort)
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts/orch" "$fixture/scripts/test"
printf '%s\n' '#!/usr/bin/env bash' \
  'printf "%s\n" "$x" | grep -q y' \
  '  printf "%s\n" "$x" | grep -qxF y' \
  'echo "$x" | grep -Eq "a|b"' \
  'echo "$x" | grep -E -q y' \
  'echo "$x" | grep -m1 y' \
  'echo "$x" | grep -m 1 y' \
  'echo "$x" | grep --quiet y' \
  'echo "$x" | grep --silent y' \
  'echo "$x" | grep --max-count=1 y' \
  'echo "$x" | grep --max-count 1 y' \
  >"$fixture/scripts/orch/flagged.sh"
printf '%s\n' 'fake_label_exists() { cut -f1 "$s" | grep -qxF "$1"; }' \
  '  cut -f1 "$f" | head -n "$1"' \
  >"$fixture/scripts/test/gh_adapter_fake.sh"
printf '%s\n' '#!/usr/bin/env bash' \
  'range_lines "$r" | head -n 1' \
  'echo "$x" | head -1' \
  'echo "$x" | head' \
  'x="$(cmd | head)"' \
  >"$fixture/scripts/orch/head.sh"
printf '%s\n' 'echo "$x" | header' >"$fixture/scripts/orch/header.sh"
printf '%s\n' 'grep -q y <<<"$x"' >"$fixture/scripts/orch/herestring.sh"
printf '%s\n' 'false || grep -q y f' >"$fixture/scripts/orch/oror.sh"
printf '%s\n' '  # never write printf "%s" "$x" | grep -q y' >"$fixture/scripts/orch/comment.sh"
printf '%s\n' 'echo "$x" | grep -q y' 'echo "$x" | head -n 1' >"$fixture/scripts/test/runner.sh"
out="$(scan_early_exit_pipe "$fixture")"
flags "a pipe into grep -q is flagged" "$out" 'scripts/orch/flagged.sh:2: printf "%s\n" "$x" | grep -q y'
flags "a pipe into grep -qxF is flagged, its leading whitespace trimmed" \
  "$out" 'scripts/orch/flagged.sh:3: printf "%s\n" "$x" | grep -qxF y'
flags "a pipe into grep -Eq is flagged" "$out" 'scripts/orch/flagged.sh:4: echo "$x" | grep -Eq "a|b"'
flags "a pipe into grep -E -q is flagged" "$out" 'scripts/orch/flagged.sh:5: echo "$x" | grep -E -q y'
flags "a pipe into grep -m1 is flagged" "$out" 'scripts/orch/flagged.sh:6: echo "$x" | grep -m1 y'
flags "a pipe into grep -m 1 is flagged" "$out" 'scripts/orch/flagged.sh:7: echo "$x" | grep -m 1 y'
flags "a pipe into grep --quiet is flagged" "$out" 'scripts/orch/flagged.sh:8: echo "$x" | grep --quiet y'
flags "a pipe into grep --silent is flagged" "$out" 'scripts/orch/flagged.sh:9: echo "$x" | grep --silent y'
flags "a pipe into grep --max-count=1 is flagged" \
  "$out" 'scripts/orch/flagged.sh:10: echo "$x" | grep --max-count=1 y'
flags "a pipe into grep --max-count 1 is flagged" \
  "$out" 'scripts/orch/flagged.sh:11: echo "$x" | grep --max-count 1 y'
flags "a pipe into a quiet grep in the gh fake is flagged" \
  "$out" 'scripts/test/gh_adapter_fake.sh:1: fake_label_exists() { cut -f1 "$s" | grep -qxF "$1"; }'
flags "a pipe into head -n 1 is flagged" "$out" 'scripts/orch/head.sh:2: range_lines "$r" | head -n 1'
flags "a pipe into head -1 is flagged" "$out" 'scripts/orch/head.sh:3: echo "$x" | head -1'
flags "a pipe into a bare head is flagged" "$out" 'scripts/orch/head.sh:4: echo "$x" | head'
flags "a pipe into head closing a substitution is flagged" "$out" 'scripts/orch/head.sh:5: x="$(cmd | head)"'
flags "a pipe into head in the gh fake is flagged" \
  "$out" 'scripts/test/gh_adapter_fake.sh:2: cut -f1 "$f" | head -n "$1"'
spares "a pipe into a word starting with head is not flagged" "$out" '^scripts/orch/header\.sh:'
spares "a herestring into grep -q is not flagged" "$out" '^scripts/orch/herestring\.sh:'
spares "grep -q after || is not flagged" "$out" '^scripts/orch/oror\.sh:'
spares "a comment mentioning | grep -q is not flagged" "$out" '^scripts/orch/comment\.sh:'
spares "a pipe into grep -q or head elsewhere under scripts/test/ is not flagged" "$out" '^scripts/test/runner\.sh:'
check "no plugin script pipes into a quiet grep or head" "$(scan_early_exit_pipe "$PLUGIN_ROOT")"

# --- Junie planning snippet (ADR-0025) ----------------------------------------
echo
echo "Junie planning snippet (ADR-0025)"
# docs/junie/AGENTS.md is pasted between one begin and one end marker, and its
# planning section restates the allowlist and the records, whose one
# definition is scripts/planning-allowlist.sh, the list the hooks print from.
# scan_junie_planning <plugin root>: each way the snippet is off the rule.
scan_junie_planning() {
  local r="$1" doc="docs/junie/AGENTS.md" n which text body
  for which in begin end; do
    n="$(grep -cxF "<!-- orchestrator:$which -->" "$r/$doc" 2>/dev/null)"
    [ "${n:-0}" = 1 ] || echo "$doc: has ${n:-0} $which markers, not 1"
  done
  body="$(flat_text "$r/$doc" 2>/dev/null)"
  for which in records allowlist; do
    text="($(source "$r/scripts/planning-allowlist.sh" && "planning_${which}_text"))"
    case "$body" in
      *"$text"*) ;;
      *) echo "$doc: does not list the planning $which as planning-allowlist.sh does: $text" ;;
    esac
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts" "$fixture/docs/junie"
printf '%s\n' 'PLANNING_ALLOWLIST=(docs/agents/ .scratch/)' 'PLANNING_RECORDS=(GLOSSARY.md docs/adr/)' \
  'planning_allowlist_text() { local IFS=,; printf "%s" "${PLANNING_ALLOWLIST[*]}" | sed "s/,/, /g"; }' \
  'planning_records_text() { local IFS=,; printf "%s" "${PLANNING_RECORDS[*]}" | sed "s/,/, /g"; }' \
  >"$fixture/scripts/planning-allowlist.sh"
printf '%s\n' '<!-- orchestrator:begin -->' 'Records (GLOSSARY.md) are recorded.' \
  'Artifacts (docs/agents/,' '.scratch/) are fine.' '<!-- orchestrator:begin -->' >"$fixture/docs/junie/AGENTS.md"
out="$(scan_junie_planning "$fixture")"
flags "a snippet with two begin markers is flagged" \
  "$out" "docs/junie/AGENTS.md: has 2 begin markers, not 1"
flags "a snippet with no end marker is flagged" \
  "$out" "docs/junie/AGENTS.md: has 0 end markers, not 1"
flags "a snippet whose records drift from planning-allowlist.sh is flagged" \
  "$out" "docs/junie/AGENTS.md: does not list the planning records as planning-allowlist.sh does: (GLOSSARY.md, docs/adr/)"
spares "an allowlist that matches across a line break is not flagged" \
  "$out" 'planning allowlist'
check "the Junie snippet is marked once and lists planning-allowlist.sh's lists" \
  "$(scan_junie_planning "$PLUGIN_ROOT")"

# --- host capability table ------------------------------------------------------
echo
echo "host capability table"
# docs/host-capabilities.md maps each capability to each host, so every row
# carries the capability and both hosts' cells, filled, and no stray pipe.
# scan_capability_table <plugin root>: each row off the rule, with its line.
scan_capability_table() {
  local r="$1" doc="docs/host-capabilities.md"
  awk -F'|' -v f="$doc" '
    /^\|/ && !/^\| *---/ {
      if (NF != 5) { print f ":" NR ": a row with " NF - 2 " cells, not 3"; next }
      for (i = 2; i <= 4; i++) if ($i ~ /^ *$/) { print f ":" NR ": a row with an empty cell"; next }
    }' "$r/$doc"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/docs"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  '| Ask | `AskUserQuestion`. | Plain text. |' '| Guard | A hook. |  |' \
  '| Start | The Agent tool. | One | two. |' >"$fixture/docs/host-capabilities.md"
out="$(scan_capability_table "$fixture")"
flags "a row with an empty cell is flagged" "$out" "docs/host-capabilities.md:4: a row with an empty cell"
flags "a row with a stray pipe is flagged" "$out" "docs/host-capabilities.md:5: a row with 4 cells, not 3"
spares "a filled row is not flagged" "$out" ':(1|2|3):'
check "every host capability row has both hosts' cells filled" \
  "$(scan_capability_table "$PLUGIN_ROOT")"

# names_with_bold <text> <token> <bold>: the text names <token>, as given,
# and <bold> in bold, as **<bold>**.
names_with_bold() { grep -qF -- "$2" <<<"$1" && grep -qF -- "**$3**" <<<"$1"; }

# quick_step_refers <plugin root> <step heading> <skill> <section> <noun>:
# one line when that quick-implement step does not name `<skill>` and its
# **<section>**. A name ending in one s (orch-to-tickets) takes a bare apostrophe.
quick_step_refers() {
  local quick="skills/orch-quick-implement/SKILL.md" body numbered="${2#\#\# }" owner="$3's"
  [[ $3 == *s && $3 != *ss ]] && owner="$3'"
  body="$(md_section "$1/$quick" "$2" | flat_text)"
  names_with_bold "$body" "\`$3\`" "$4" \
    || echo "$quick: step ${numbered%%.*} does not refer to $owner **$4** $5"
}

# scan_names_phrase <plugin root> <list> <phrase>: for each `file` or
# `file|section` entry in the newline list, one line when the section is
# missing, or when the file, or that section of it, never names the phrase,
# read flattened so a phrase wrapped across lines still counts.
scan_names_phrase() {
  local r="$1" list="$2" phrase="$3" f h body
  while IFS='|' read -r f h; do
    [ -n "$f" ] || continue
    if [ -z "$h" ]; then
      flat_text "$r/$f" 2>/dev/null | grep -qF -- "$phrase" \
        || echo "$f: does not name $phrase"
    elif ! body="$(md_section "$r/$f" "$h" 2>/dev/null)"; then
      echo "$f: no $h section"
    elif ! flat_text <<<"$body" | grep -qF -- "$phrase"; then
      echo "$f: $h does not name $phrase"
    fi
  done <<<"$list"
  return 0
}

check "host-capabilities Agent settings names agent sync, the Junie sync step" \
  "$(scan_names_phrase "$PLUGIN_ROOT" 'docs/host-capabilities.md|## Agent settings' 'agent sync')"
check "the Junie README has an Agent settings on Junie section naming --host junie" \
  "$(scan_names_phrase "$PLUGIN_ROOT" 'docs/junie/README.md|## Agent settings on Junie' '--host junie')"
check "the Junie README's Agent settings on Junie section names orch.sh doctor" \
  "$(scan_names_phrase "$PLUGIN_ROOT" 'docs/junie/README.md|## Agent settings on Junie' 'orch.sh doctor')"

# --- autopilot docs (#1497) ---------------------------------------------------
echo
echo "autopilot docs (#1497)"
for phrase in 'orch.sh autopilot watch' orchestrator.autopilot.permission-mode; do
  check "README's Running autopilot names $phrase" \
    "$(scan_names_phrase "$PLUGIN_ROOT" 'README.md|## Running autopilot' "$phrase")"
done
for phrase in orchestrator.autopilot.permission-mode 'orch.sh autopilot tick' needs-human 'all: recommended' 'orch.sh doctor'; do
  check "how-it-works' Autopilot section names $phrase" \
    "$(scan_names_phrase "$PLUGIN_ROOT" 'docs/how-it-works.md|## Autopilot' "$phrase")"
done

# The container and host-alternative subsections sit inside ### Setup, and the
# files the container docs name exist (#1502).
container_files=(docker/compose.yaml docker/.env.example)
for phrase in "${container_files[@]}" systemd; do
  check "how-it-works' Autopilot Setup names $phrase" \
    "$(scan_names_phrase "$PLUGIN_ROOT" 'docs/how-it-works.md|### Setup' "$phrase")"
done
for f in "${container_files[@]}"; do
  check "$f exists" "$([ -f "$PLUGIN_ROOT/$f" ] || echo "$f: missing")"
done
# The build context is the plugin root, so .dockerignore must keep the filled-in
# secrets (the .gitignore Secrets patterns, at any depth) out of the image.
for pat in '**/.env' '**/.env.*' '!**/.env.example' .claude/settings.local.json; do
  check ".dockerignore lists $pat" \
    "$(grep -qxF -- "$pat" "$PLUGIN_ROOT/.dockerignore" || echo ".dockerignore: does not list $pat")"
done

# --- review pass (#342) --------------------------------------------------------
echo
echo "review pass (#342)"
# A review pass is defined once, in orch-review-pass's ## Review pass section, which
# starts with review-pass begin. Quick implementation's step 6 runs that
# section rather than keeping its own copy.
# scan_review_pass <plugin root>: one line per break of that rule.
scan_review_pass() {
  local r="$1"
  scan_names_phrase "$r" 'skills/orch-review-pass/SKILL.md|## Review pass' 'review-pass begin'
  quick_step_refers "$r" "## 6. Review" orch-review-pass "Review pass" section
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review-pass" "$fixture/skills/orch-quick-implement"
printf '# R\n\n## Review pass\n\nStart the reviewers.\n\n## Other\n\nrun review-pass begin\n' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
printf '# Q\n\n## 6. Review\n\nStart the reviewers.\n\n## 7. Open the PR\n\nSee `orch-review-pass` **Review pass**.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
out="$(scan_review_pass "$fixture")"
flags "a Review pass section that skips review-pass begin is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: ## Review pass does not name review-pass begin"
flags "a step 6 that does not run orch-review-pass's Review pass is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 6 does not refer to orch-review-pass's **Review pass** section"
printf '# R\n\n## Other\n' >"$fixture/skills/orch-review-pass/SKILL.md"
flags "a missing Review pass section is flagged" \
  "$(scan_review_pass "$fixture")" "skills/orch-review-pass/SKILL.md: no ## Review pass section"
printf '# R\n\n## Review pass\n\nRun `orch.sh review-pass begin <issue>`.\n' >"$fixture/skills/orch-review-pass/SKILL.md"
printf '# Q\n\n## 6. Review\n\nRun the `orch-review-pass` skill'"'"'s **Review\npass** section.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
assert_empty "a review pass defined once and run by step 6 is not flagged" "$(scan_review_pass "$fixture")"
check "the review pass is defined once in orch-review-pass and quick implementation runs it" \
  "$(scan_review_pass "$PLUGIN_ROOT")"

# --- unattended modes (#616) --------------------------------------------------
echo
echo "unattended modes (#616)"
# Quick implementation runs hands-off through three unattended modes, each
# defined once in its own skill: orch-to-spec's **Unattended rewrite**,
# orch-spec-review's **Unattended spec review** and orch-to-tickets'
# **Unattended breakdown**. Its steps 1, 2 and 3 run those modes rather than
# keeping their own copies, as step 6 runs the Review pass.
# scan_unattended_modes <plugin root>: one line per step that does not refer
# to its mode.
scan_unattended_modes() {
  quick_step_refers "$1" "## 1. Require a linked issue" orch-to-spec "Unattended rewrite" mode
  quick_step_refers "$1" "## 2. Run an unattended spec review" orch-spec-review "Unattended spec review" mode
  quick_step_refers "$1" "## 3. Publish the ticket breakdown" orch-to-tickets "Unattended breakdown" mode
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-quick-implement"
printf '# Q\n\n## 1. Require a linked issue\n\nLink the issue.\n\n## 2. Run an unattended spec review\n\nRun a review.\n\n## 3. Publish the ticket breakdown\n\nRun `orch-to-tickets` in its quiz.\n\n## 4. Branch\n\nSee `orch-spec-review` **Unattended spec review** and **Unattended breakdown**, and `orch-to-spec` **Unattended rewrite**.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
out="$(scan_unattended_modes "$fixture")"
flags "a step 1 that does not run orch-to-spec's unattended mode is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 1 does not refer to orch-to-spec's **Unattended rewrite** mode"
flags "a step 2 that does not run orch-spec-review's unattended mode is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 2 does not refer to orch-spec-review's **Unattended spec review** mode"
flags "a step 3 that does not run orch-to-tickets' unattended mode is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 3 does not refer to orch-to-tickets' **Unattended breakdown** mode"
printf '# Q\n\n## 1. Require a linked issue\n\nEnd with `orch-to-spec`'"'"'s **Unattended\nrewrite**.\n\n## 2. Run an unattended spec review\n\nRun `orch-spec-review`'"'"'s **Unattended\nspec review**.\n\n## 3. Publish the ticket breakdown\n\nRun `orch-to-tickets` in its **Unattended breakdown**.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
assert_empty "steps 1, 2 and 3 that run the unattended modes are not flagged" "$(scan_unattended_modes "$fixture")"
check "quick implementation's steps 1, 2 and 3 run the unattended modes" \
  "$(scan_unattended_modes "$PLUGIN_ROOT")"

# --- skill reference files (#1147, #1145) -------------------------------------
echo
echo "skill reference files (#1147, #1145)"
# A skill's SKILL.md holds what every path needs; what only one path needs sits
# in a reference file beside it, read only on that path. A reference file is a
# .md file directly in skills/<name>/ other than SKILL.md, and its SKILL.md
# names it, so no reference file is orphaned. The files are worked out from
# each skill's directory, never listed here, so adding one needs no edit to
# this linter.
# scan_skill_refs <plugin root>: one line per reference file its skill's
# SKILL.md does not name.
scan_skill_refs() {
  local r="$1" f d
  while IFS= read -r f; do
    [ "${f##*/}" = SKILL.md ] && continue
    d="${f%/*}"
    grep -qF -- "${f##*/}" "$d/SKILL.md" 2>/dev/null \
      || echo "${d#"$r"/}/SKILL.md: does not name ${f##*/}"
  done < <(skill_md_files "$r")
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-x" "$fixture/skills/orch-y" "$fixture/skills/orch-z/sub"
printf '# X\n\nOn that path, read named.md.\n' >"$fixture/skills/orch-x/SKILL.md"
: >"$fixture/skills/orch-x/named.md"
: >"$fixture/skills/orch-x/orphan.md"
printf '# Y\n' >"$fixture/skills/orch-y/SKILL.md"
: >"$fixture/skills/orch-y/lost.md"
printf '# Z\n' >"$fixture/skills/orch-z/SKILL.md"
: >"$fixture/skills/orch-z/notes.txt"
: >"$fixture/skills/orch-z/sub/deep.md"
out="$(scan_skill_refs "$fixture")"
flags "a reference file its SKILL.md does not name is flagged" \
  "$out" "skills/orch-x/SKILL.md: does not name orphan.md"
flags "an unnamed reference file is flagged in any skill" \
  "$out" "skills/orch-y/SKILL.md: does not name lost.md"
spares "a reference file its SKILL.md names is not flagged" "$out" 'named\.md'
spares "a skill with only SKILL.md, a non-.md file or a subdirectory gives nothing" "$out" '^skills/orch-z/'
check "every skill's SKILL.md names each of its reference files" \
  "$(scan_skill_refs "$PLUGIN_ROOT")"

# orch-flow's spec phase, which alone needs orch-spec-review's spec-phase.md,
# names it in its step 4, where it invokes the review, and names changelog.md
# there, where each round's changelog is read from. orch-spec-review's
# Applying the answer names the spec-review apply command, and orch-handoff's
# 02-spec.md template's Spec review changelog names changelog.md, where each
# round's changelog is copied from. Names only, never wording (ADR-0027).
# scan_spec_review_refs <plugin root>: one line per site that lost its name.
scan_spec_review_refs() {
  local r="$1" flow="skills/orch-flow/SKILL.md" step
  step="$(md_section "$r/$flow" "### Phase: spec" 2>/dev/null \
    | awk '/^[0-9]+\. / { inb = ($0 ~ /^4\. /) } inb' | flat_text)"
  grep -qF 'spec-phase.md' <<<"$step" \
    || echo "$flow: spec phase step 4 does not name orch-spec-review's spec-phase.md"
  grep -qF 'changelog.md' <<<"$step" \
    || echo "$flow: spec phase step 4 does not name changelog.md"
  scan_names_phrase "$r" 'skills/orch-spec-review/SKILL.md|## Applying the answer' 'spec-review apply'
  scan_names_phrase "$r" 'skills/orch-handoff/SKILL.md|## Spec review changelog' 'changelog.md'
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-flow"
printf '# F\n\n### Phase: spec\n\n4. Invoke `orch-spec-review`.\n5. Then read spec-phase.md.\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
flags "a spec phase step 4 that does not name spec-phase.md is flagged" \
  "$(scan_spec_review_refs "$fixture")" "skills/orch-flow/SKILL.md: spec phase step 4 does not name orch-spec-review's spec-phase.md"
printf '# F\n\n### Phase: spec\n\n4. Invoke `orch-spec-review`, reading spec-phase.md.\n5. Read each `changelog.md`.\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
mkdir -p "$fixture/skills/orch-spec-review" "$fixture/skills/orch-handoff"
printf '# S\n\n## Applying the answer\n\nApply it.\n\n## The changelog\n\nRun `spec-review apply`.\n' \
  >"$fixture/skills/orch-spec-review/SKILL.md"
printf '# H\n\n```markdown\n## Spec review changelog\n\nOne per round.\n\n## Ticket breakdown\n\nSee `changelog.md`.\n```\n' \
  >"$fixture/skills/orch-handoff/SKILL.md"
out="$(scan_spec_review_refs "$fixture")"
flags "an Applying the answer section that does not name spec-review apply is flagged" \
  "$out" "skills/orch-spec-review/SKILL.md: ## Applying the answer does not name spec-review apply"
flags "a Spec review changelog naming changelog.md only after Ticket breakdown is flagged" \
  "$out" "skills/orch-handoff/SKILL.md: ## Spec review changelog does not name changelog.md"
flags "a spec phase naming changelog.md only in step 5 is flagged" \
  "$out" "skills/orch-flow/SKILL.md: spec phase step 4 does not name changelog.md"
printf '# S\n\n## Other\n' >"$fixture/skills/orch-spec-review/SKILL.md"
flags "a missing Applying the answer section is flagged" \
  "$(scan_spec_review_refs "$fixture")" "skills/orch-spec-review/SKILL.md: no ## Applying the answer section"
printf '# F\n\n### Phase: spec\n\n4. Ask the round count.\n\n   Then invoke `orch-spec-review`, reading its\n   spec-phase.md, and keep each round'"'"'s changelog.md path.\n5. Break it down.\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
printf '# S\n\n## Applying the answer\n\nHand the reply to `orch.sh spec-review\napply` once.\n' \
  >"$fixture/skills/orch-spec-review/SKILL.md"
printf '# H\n\n```markdown\n## Spec review changelog\n\nEach round, taken from its changelog.md.\n\n## Ticket breakdown\n```\n' \
  >"$fixture/skills/orch-handoff/SKILL.md"
assert_empty "a spec review whose sites name their files and command, however worded, is not flagged" \
  "$(scan_spec_review_refs "$fixture")"
check "the spec review's references name spec-phase.md, changelog.md and spec-review apply" \
  "$(scan_spec_review_refs "$PLUGIN_ROOT")"

# --- previously declined (#418) ------------------------------------------------
echo
echo "previously declined (#418)"
# A standalone review pass reads earlier passes' declines through pr comments
# and lists what it dropped as **Previously declined** - while the reviewers
# hear of earlier passes only through the known-items file: Review pass step
# 3's prompt is the seven variables, `Known items: <prefix>-known.md` then
# `Standards: <the line review standards printed>` last, and carries no
# earlier items inline (ADR-0045).
# scan_previously_declined <plugin root>: one line per break of that rule.
scan_previously_declined() {
  local r="$1" pass="skills/orch-review-pass/SKILL.md" body prompt
  body="$(md_section "$r/$pass" "## Standalone review pass" | flat_text)"
  grep -qF 'pr comments' <<<"$body" \
    || echo "$pass: ## Standalone review pass does not name pr comments"
  grep -qF '**Previously declined**' <<<"$body" \
    || echo "$pass: ## Standalone review pass does not name **Previously declined**"
  prompt="$(md_section_first_block "$r/$pass" "## Review pass")"
  [ "$prompt" = "$(printf '%s\n' 'Base SHA: <base SHA>' 'Spec issue: #<issue>' 'Iteration: <NN>' \
    'Report path: <prefix>-<standards|spec>.md' 'orch.sh: <the path ORCH holds>' \
    'Known items: <prefix>-known.md' 'Standards: <the line review standards printed>')" ] \
    || echo "$pass: ## Review pass step 3's reviewer prompt is not the seven variables"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review-pass"
printf '%s\n' '# R' '' '## Review pass' '' '3. Start them:' '' '   ```' '   Base SHA: <base SHA>' \
  '   Spec issue: #<issue>' '   Earlier declines: <list>' '   Iteration: <NN>' \
  '   Report path: <prefix>-<standards|spec>.md' '   orch.sh: <the path ORCH holds>' \
  '   Known items: <prefix>-known.md' '   ```' '' \
  '## Standalone review pass' '' 'Post it.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
out="$(scan_previously_declined "$fixture")"
flags "a standalone pass that never reads pr comments is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: ## Standalone review pass does not name pr comments"
flags "a standalone pass with no Previously declined is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: ## Standalone review pass does not name **Previously declined**"
flags "a reviewer prompt carrying earlier declines inline is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: ## Review pass step 3's reviewer prompt is not the seven variables"
printf '%s\n' '# R' '' '## Review pass' '' '3. Start them:' '' '   ```' '   Base SHA: <base SHA>' \
  '   Spec issue: #<issue>' '   Iteration: <NN>' '   Report path: <prefix>-<standards|spec>.md' \
  '   orch.sh: <the path ORCH holds>' '   ```' '' \
  '## Standalone review pass' '' 'Run `orch.sh pr comments <file>`; list **Previously' 'declined**.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
flags "the old five-variable prompt is flagged" \
  "$(scan_previously_declined "$fixture")" \
  "skills/orch-review-pass/SKILL.md: ## Review pass step 3's reviewer prompt is not the seven variables"
printf '%s\n' '# R' '' '## Review pass' '' '3. Start them:' '' '   ```' '   Base SHA: <base SHA>' \
  '   Spec issue: #<issue>' '   Iteration: <NN>' '   Report path: <prefix>-<standards|spec>.md' \
  '   orch.sh: <the path ORCH holds>' '   Known items: <prefix>-known.md' '   ```' '' \
  '## Standalone review pass' '' 'Run `orch.sh pr comments <file>`; list **Previously' 'declined**.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
flags "the old six-variable prompt, with no Standards line, is flagged" \
  "$(scan_previously_declined "$fixture")" \
  "skills/orch-review-pass/SKILL.md: ## Review pass step 3's reviewer prompt is not the seven variables"
printf '%s\n' '# R' '' '## Review pass' '' '3. Run `orch.sh review-pass known-items <issue> <prefix>-known.md`, then start them:' \
  '' '   ```' '   Base SHA: <base SHA>' \
  '   Spec issue: #<issue>' '   Iteration: <NN>' '   Report path: <prefix>-<standards|spec>.md' \
  '   orch.sh: <the path ORCH holds>' '   Known items: <prefix>-known.md' \
  '   Standards: <the line review standards printed>' '   ```' '' \
  '## Standalone review pass' '' 'Run `orch.sh pr comments <file>`; list **Previously' 'declined**.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
assert_empty "a pass that reads earlier declines and passes the seven variables is not flagged" \
  "$(scan_previously_declined "$fixture")"
check "a standalone review pass drops earlier declines and the reviewer prompt is the seven variables" \
  "$(scan_previously_declined "$PLUGIN_ROOT")"

# --- review loop reviewer prompt (#1532) ----------------------------------------
echo
echo "review loop reviewer prompt (#1532)"
# The review loop's reviewers get the same seven variables a review pass's do,
# with the loop's own placeholders: `Standards: <the line review standards
# printed>` last, after `Known items:`.
# scan_review_loop_prompt <plugin root>: one line when the orch-review skill's
# ## The reviewers prompt block is not those seven lines.
scan_review_loop_prompt() {
  local r="$1" skill="skills/orch-review/SKILL.md" prompt
  prompt="$(md_section_first_block "$r/$skill" "## The reviewers")"
  [ "$prompt" = "$(printf '%s\n' "Base SHA: <this iteration's base SHA>" 'Spec issue: #<spec issue>' \
    'Iteration: <NN>' 'Report path: <report path>' 'orch.sh: <the path ORCH holds>' \
    'Known items: <the iteration-NN-known.md step 3 of The iteration built>' \
    'Standards: <the line review standards printed>')" ] \
    || echo "$skill: ## The reviewers prompt is not the seven variables"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review"
printf '%s\n' '# R' '' '## The reviewers' '' '```' "Base SHA: <this iteration's base SHA>" \
  'Spec issue: #<spec issue>' 'Iteration: <NN>' 'Report path: <report path>' \
  'orch.sh: <the path ORCH holds>' 'Known items: <the iteration-NN-known.md step 3 of The iteration built>' \
  '```' >"$fixture/skills/orch-review/SKILL.md"
flags "a six-variable loop prompt, with no Standards line, is flagged" \
  "$(scan_review_loop_prompt "$fixture")" \
  "skills/orch-review/SKILL.md: ## The reviewers prompt is not the seven variables"
printf '%s\n' '# R' '' '## The reviewers' '' '```' "Base SHA: <this iteration's base SHA>" \
  'Spec issue: #<spec issue>' 'Iteration: <NN>' 'Report path: <report path>' \
  'orch.sh: <the path ORCH holds>' 'Known items: <the iteration-NN-known.md step 3 of The iteration built>' \
  'Standards: <the line review standards printed>' '```' >"$fixture/skills/orch-review/SKILL.md"
assert_empty "the seven-variable loop prompt is not flagged" "$(scan_review_loop_prompt "$fixture")"
check "the review loop's reviewer prompt is the seven variables" "$(scan_review_loop_prompt "$PLUGIN_ROOT")"

# --- standalone pass smells (#419) ---------------------------------------------
echo
echo "standalone pass smells (#419)"
# A standalone review pass leaves out the Standards reviewer's smell-baseline
# findings unless the human passes --smells. Under ADR-0027 a flag name is a
# token, as review-pass begin is: the skill's ## Standalone review pass section
# names --smells, and the command's argument-hint offers it.
# scan_standalone_smells <plugin root>: one line per place that drops the flag.
scan_standalone_smells() {
  local r="$1" pass="skills/orch-review-pass/SKILL.md" cmd="commands/review-pass.md"
  md_section "$r/$pass" "## Standalone review pass" | grep -qF -- '--smells' \
    || echo "$pass: ## Standalone review pass does not name --smells"
  grep -E '^argument-hint:' "$r/$cmd" 2>/dev/null | grep -qF -- '--smells' \
    || echo "$cmd: argument-hint does not name --smells"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review-pass" "$fixture/commands"
printf '# R\n\n## Standalone review pass\n\nRun the pass.\n\n## Other\n\n--smells\n' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
printf -- '---\nargument-hint: "<issue>"\n---\n\nPass --smells along.\n' >"$fixture/commands/review-pass.md"
out="$(scan_standalone_smells "$fixture")"
flags "a Standalone review pass section that never names --smells is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: ## Standalone review pass does not name --smells"
flags "a review-pass argument-hint without --smells is flagged" \
  "$out" "commands/review-pass.md: argument-hint does not name --smells"
printf '# R\n\n## Standalone review pass\n\nWith `--smells`, keep them.\n' >"$fixture/skills/orch-review-pass/SKILL.md"
printf -- '---\nargument-hint: "<issue> [--smells]"\n---\n' >"$fixture/commands/review-pass.md"
assert_empty "a standalone pass and argument-hint naming --smells are not flagged" \
  "$(scan_standalone_smells "$fixture")"
check "a standalone review pass takes --smells, and review-pass offers it" \
  "$(scan_standalone_smells "$PLUGIN_ROOT")"

# --- test cost (#1307) ---------------------------------------------------------
echo
echo "test cost (#1307)"
# The agents that write tests, the implementer and the fixer, carry one rule
# for test cost: a paragraph led by **Cheapest sufficient test.** in each
# Test-driven development section. Under ADR-0027 the two copies must match,
# and no wording is pinned. The Standards reviewer carries four test-cost
# smells in a section of its own, kept apart from the pinned smell baseline
# (ADR-0018), so a standalone review pass never counts them as baseline smells.
tdd_agents='agents/orch-implementer.md
agents/orch-fixer.md'
test_cost_smells='Duplicated coverage
Expensive seam
Per-test setup
Waiting'
# cheapest_paragraph <file>: the paragraph of <file>'s ## Test-driven
# development section that a line beginning **Cheapest sufficient test.**
# leads, up to the next blank line, flattened to one line. Empty when absent.
cheapest_paragraph() {
  md_section "$1" "## Test-driven development" 2>/dev/null \
    | awk '/^\*\*Cheapest sufficient test\.\*\*/ { inb = 1 } inb && /^[[:space:]]*$/ { exit } inb' \
    | flat_text
}
# scan_cheapest_test <plugin root>: one line per Test-driven development
# section with no such paragraph, and one when the copies differ.
scan_cheapest_test() {
  local r="$1" f para first="" firstf=""
  while IFS= read -r f; do
    para="$(cheapest_paragraph "$r/$f")"
    if [ -z "$para" ]; then
      echo "$f: ## Test-driven development has no paragraph led by **Cheapest sufficient test.**"
    elif [ -z "$firstf" ]; then first="$para"; firstf="$f"
    elif [ "$para" != "$first" ]; then
      echo "$f: the **Cheapest sufficient test.** paragraph differs from $firstf's"
    fi
  done <<<"$tdd_agents"
  return 0
}
# scan_test_cost_smells <plugin root>: one line per test-cost smell missing
# from the Standards reviewer's ## Test-cost smells section, or named in bold
# inside its ## Smell baseline, and one when the section is missing.
scan_test_cost_smells() {
  local r="$1" f="agents/orch-reviewer-standards.md" body base smell
  base="$(md_section "$r/$f" "## Smell baseline" 2>/dev/null)"
  if ! body="$(md_section "$r/$f" "## Test-cost smells" 2>/dev/null)"; then
    echo "$f: no ## Test-cost smells section"
    body=""
  fi
  while IFS= read -r smell; do
    if [ -n "$body" ] && ! grep -qF -- "**$smell**" <<<"$body"; then
      echo "$f: ## Test-cost smells does not name **$smell**"
    fi
    if grep -qF -- "**$smell**" <<<"$base"; then
      echo "$f: **$smell** is inside the ## Smell baseline"
    fi
  done <<<"$test_cost_smells"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents"
para='**Cheapest sufficient test.** Pick the cheapest seam.
Cost is only the tiebreak.'
printf '# I\n\n## Test-driven development\n\nRules.\n\n## Other\n\n%s\n' "$para" >"$fixture/agents/orch-implementer.md"
printf '# F\n\n## Test-driven development\n\n%s\n\nMore.\n' "${para/tiebreak/excuse}" >"$fixture/agents/orch-fixer.md"
out="$(scan_cheapest_test "$fixture")"
flags "a Test-driven development section with no Cheapest sufficient test paragraph is flagged" \
  "$out" "agents/orch-implementer.md: ## Test-driven development has no paragraph led by **Cheapest sufficient test.**"
printf '# I\n\n## Test-driven development\n\n%s\n\nNext paragraph.\n' "$para" >"$fixture/agents/orch-implementer.md"
flags "copies of the Cheapest sufficient test paragraph that differ are flagged" \
  "$(scan_cheapest_test "$fixture")" \
  "agents/orch-fixer.md: the **Cheapest sufficient test.** paragraph differs from agents/orch-implementer.md's"
printf '# F\n\nIntro.\n\n## Test-driven development\n\nA fix.\n\n%s\n' \
  "$(printf '%s\n' "$para" | tr '\n' ' ' | sed 's/ $//; s/seam\. /seam.\n/')" >"$fixture/agents/orch-fixer.md"
assert_empty "identical Cheapest sufficient test paragraphs, wrapped differently, are not flagged" \
  "$(scan_cheapest_test "$fixture")"
check "both Test-driven development sections carry the same Cheapest sufficient test paragraph" \
  "$(scan_cheapest_test "$PLUGIN_ROOT")"
printf '# S\n\n## Smell baseline\n\n- **Waiting**: a sleep.\n\n## Test-cost smells\n\n- **Duplicated coverage**: again.\n- **Expensive seam**: costly.\n' \
  >"$fixture/agents/orch-reviewer-standards.md"
out="$(scan_test_cost_smells "$fixture")"
flags "a test-cost smell missing from the Test-cost smells section is flagged" \
  "$out" "agents/orch-reviewer-standards.md: ## Test-cost smells does not name **Per-test setup**"
flags "a test-cost smell inside the smell baseline is flagged" \
  "$out" "agents/orch-reviewer-standards.md: **Waiting** is inside the ## Smell baseline"
printf '# S\n\n## Smell baseline\n\n- **Mysterious Name**: a name.\n' >"$fixture/agents/orch-reviewer-standards.md"
flags "a Standards reviewer with no Test-cost smells section is flagged" \
  "$(scan_test_cost_smells "$fixture")" "agents/orch-reviewer-standards.md: no ## Test-cost smells section"
printf '# S\n\n## Smell baseline\n\n- **Mysterious Name**: a name.\n\n## Test-cost smells\n\n- **Duplicated coverage**: a.\n- **Expensive seam**: b.\n- **Per-test setup**: c.\n- **Waiting**: d.\n' \
  >"$fixture/agents/orch-reviewer-standards.md"
assert_empty "four test-cost smells outside the smell baseline are not flagged" \
  "$(scan_test_cost_smells "$fixture")"
check "the Standards reviewer carries the four test-cost smells outside the smell baseline" \
  "$(scan_test_cost_smells "$PLUGIN_ROOT")"

# --- verify through suite cost (#1306) ----------------------------------------
echo
echo "verify through suite cost (#1306)"
# The agents that run a repo's verification - the implementer, the fixer and
# the resolver - run it as orch.sh suite-cost run -- <cmd>, so every passing
# run is recorded as a suite cost with no bookkeeping of their own.
verify_agents='agents/orch-implementer.md
agents/orch-fixer.md
agents/orch-resolver.md'
fixture="$(new_fixture)"
mkdir -p "$fixture/agents"
printf '# I\n\nRun `bash "<orch.sh>" suite-cost\nrun -- <cmd>`.\n' >"$fixture/agents/orch-implementer.md"
printf '# F\n\nRun `bash "<orch.sh>" suite-cost run -- <cmd>`.\n' >"$fixture/agents/orch-fixer.md"
printf '# R\n\nRun the checks.\n' >"$fixture/agents/orch-resolver.md"
out="$(scan_names_phrase "$fixture" "$verify_agents" 'suite-cost run --')"
flags "an agent that runs its checks bare is flagged" \
  "$out" "agents/orch-resolver.md: does not name suite-cost run --"
spares "an agent that runs suite-cost run, wrapped across lines, is not flagged" \
  "$out" "orch-(implementer|fixer)"
check "the implementer, fixer and resolver run their verification through suite-cost run" \
  "$(scan_names_phrase "$PLUGIN_ROOT" "$verify_agents" 'suite-cost run --')"

# --- suite-cost check (#1308) --------------------------------------------------
echo
echo "suite-cost check (#1308)"
# Suite-cost growth surfaces as a finding at review time: the review loop's
# triage, in orch-review's ## The iteration, and the review pass, in
# orch-review-pass's ## Review pass, each run suite-cost check -- <cmd>.
suite_cost_checks='skills/orch-review/SKILL.md|## The iteration
skills/orch-review-pass/SKILL.md|## Review pass'
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review" "$fixture/skills/orch-review-pass"
printf '# L\n\n## The iteration\n\nTriage the findings.\n\n## Severity\n\nRun `suite-cost check -- <cmd>`.\n' \
  >"$fixture/skills/orch-review/SKILL.md"
printf '# P\n\n## Other\n\nRun `suite-cost check -- <cmd>`.\n' >"$fixture/skills/orch-review-pass/SKILL.md"
out="$(scan_names_phrase "$fixture" "$suite_cost_checks" 'suite-cost check --')"
flags "a review loop triage that never runs suite-cost check is flagged" \
  "$out" "skills/orch-review/SKILL.md: ## The iteration does not name suite-cost check --"
flags "a missing Review pass section is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: no ## Review pass section"
printf '# L\n\n## The iteration\n\nTriage: run `bash "$ORCH" suite-cost\ncheck -- <cmd>`.\n' \
  >"$fixture/skills/orch-review/SKILL.md"
printf '# P\n\n## Review pass\n\nRun `suite-cost check -- <cmd>` once.\n' >"$fixture/skills/orch-review-pass/SKILL.md"
assert_empty "a triage and a review pass that run suite-cost check, wrapped across lines, are not flagged" \
  "$(scan_names_phrase "$fixture" "$suite_cost_checks" 'suite-cost check --')"
check "the review loop's triage and the review pass run suite-cost check" \
  "$(scan_names_phrase "$PLUGIN_ROOT" "$suite_cost_checks" 'suite-cost check --')"

# --- improve tests (#1309) -----------------------------------------------------
echo
echo "improve tests (#1309)"
# orch-improve-tests is defined by its six steps, so each step heading stays
# present and in order, and its command routes to it. Opening its report is a
# host capability: a row in docs/host-capabilities.md, with a fallback
# subsection that gives the Markdown summary in its place.
improve_tests_skill='skills/orch-improve-tests/SKILL.md'
improve_tests_steps='Scope
Measure
Hunt
Rank
Report
Hand off'
open_report_capability='Open a report in the browser'
# scan_improve_tests <plugin root>: one line when the command file is missing
# or routes elsewhere, and one per step heading (## <n>. <step>) missing from
# the skill or out of order.
scan_improve_tests() {
  local r="$1" cmd="commands/improve-tests.md" step n=0 pairs=""
  if [ ! -f "$r/$cmd" ]; then echo "$cmd: missing"
  elif ! flat_text "$r/$cmd" | grep -qF '`orchestrator:orch-improve-tests` and follow it'; then
    echo "$cmd: does not route to orch-improve-tests"
  fi
  while IFS= read -r step; do
    n=$((n + 1))
    pairs+="$improve_tests_skill|## $n. $step"$'\n'
  done <<<"$improve_tests_steps"
  scan_required_headings "$r" "$pairs"
}
# scan_report_capability <plugin root>: one line when docs/host-capabilities.md
# has no row for opening the report, and one when its Fallbacks have no
# subsection for it naming a Markdown summary.
scan_report_capability() {
  local r="$1" doc="docs/host-capabilities.md" body
  grep -qF -- "| $open_report_capability |" "$r/$doc" 2>/dev/null \
    || echo "$doc: no row for $open_report_capability"
  if ! body="$(md_section "$r/$doc" "### $open_report_capability" 2>/dev/null)"; then
    echo "$doc: no fallback for $open_report_capability"
  elif ! flat_text <<<"$body" | grep -qiF 'markdown summary'; then
    echo "$doc: the fallback for $open_report_capability gives no Markdown summary"
  fi
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-improve-tests" "$fixture/commands" "$fixture/docs"
printf '# I\n\n## 1. Scope\n\n## 2. Measure\n\n## 4. Rank\n\n## 3. Hunt\n\n## 5. Report\n' \
  >"$fixture/$improve_tests_skill"
out="$(scan_improve_tests "$fixture")"
flags "a missing improve-tests command file is flagged" "$out" "commands/improve-tests.md: missing"
flags "a step heading out of order is flagged" \
  "$out" "$improve_tests_skill: required heading out of order: ## 4. Rank"
flags "a missing step heading is flagged" \
  "$out" "$improve_tests_skill: missing required heading: ## 6. Hand off"
printf 'Call the Skill tool with `orchestrator:orch-interview` and follow it.\n' \
  >"$fixture/commands/improve-tests.md"
flags "a command file routing elsewhere is flagged" \
  "$(scan_improve_tests "$fixture")" "commands/improve-tests.md: does not route to orch-improve-tests"
printf 'Call the Skill tool with\n`orchestrator:orch-improve-tests` and follow it.\n' \
  >"$fixture/commands/improve-tests.md"
printf '# I\n\n## 1. Scope\n\n## 2. Measure\n\n## 3. Hunt\n\n## 4. Rank\n\n## 5. Report\n\n## 6. Hand off\n' \
  >"$fixture/$improve_tests_skill"
assert_empty "the six step headings in order and a wrapped route are not flagged" \
  "$(scan_improve_tests "$fixture")"
check "orch-improve-tests has its command and its six step headings in order" \
  "$(scan_improve_tests "$PLUGIN_ROOT")"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  '| Ask | `AskUserQuestion`. | `ask_user`. |' '' '## Fallbacks' '' \
  "### $open_report_capability" '' 'Say where the file is.' >"$fixture/docs/host-capabilities.md"
out="$(scan_report_capability "$fixture")"
flags "a host capability table with no report row is flagged" \
  "$out" "docs/host-capabilities.md: no row for $open_report_capability"
flags "a report fallback with no Markdown summary is flagged" \
  "$out" "docs/host-capabilities.md: the fallback for $open_report_capability gives no Markdown summary"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  "| $open_report_capability | \`xdg-open\`. | Unverified. |" '' '## Fallbacks' '' \
  '### Ask' '' 'Write a Markdown summary.' >"$fixture/docs/host-capabilities.md"
flags "a report row with no fallback subsection is flagged" \
  "$(scan_report_capability "$fixture")" "docs/host-capabilities.md: no fallback for $open_report_capability"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  "| $open_report_capability | \`xdg-open\`. | Unverified. |" '' '## Fallbacks' '' \
  "### $open_report_capability" '' 'Write a Markdown' 'summary in chat.' >"$fixture/docs/host-capabilities.md"
assert_empty "a report row with a Markdown summary fallback is not flagged" \
  "$(scan_report_capability "$fixture")"
check "docs/host-capabilities.md has a row for opening the report, with the Markdown fallback" \
  "$(scan_report_capability "$PLUGIN_ROOT")"

# --- review pass skill (#1138) -------------------------------------------------
echo
echo "review pass skill (#1138)"
# The review pass lives in its own skill, orch-review-pass, so a pass loads
# none of orch-review's loop text. That holds only while the pass's skill
# refers into no loop section, every caller invokes orch-review-pass, and
# orch-review keeps no copy of the pass.
# The loop-only names, the spec's closed list: orch-review's loop sections, plus
# Met again, the loop's triage outcome. A pass's skill names one when a bold
# span is the name, or begins with the name and a colon.
review_loop_only='Before the first iteration
The iteration
The reviewers
The fixer
The closer
Starting an agent
Severity
Authority
CI
Termination
Met again'
# names_orch_review: stdin names the orch-review skill as a whole token -
# orch-review or orchestrator:orch-review, never orch-review-pass or
# orch-reviewer-spec.
names_orch_review() { grep -qE '(^|[^a-z0-9-])orch-review([^a-z0-9-]|$)'; }
# skill_part <file> frontmatter|body: the lines between the `---` fence on
# line 1 and the next `---`, or the lines after that closing fence. With no
# fence on line 1 the frontmatter is empty and the body is the whole file; with
# the fence never closed, every line after line 1 is frontmatter.
skill_part() {
  P="$2" awk 'BEGIN { body = ENVIRON["P"] == "body" }
    NR == 1 && $0 == "---" { fm = 1; next }
    fm && $0 == "---" { fm = 0; next }
    fm != body { print }' "$1" 2>/dev/null
}
# skill_description <file>: the description line of the file's frontmatter.
skill_description() { skill_part "$1" frontmatter | grep '^description:'; }
# scan_review_pass_self_contained <plugin root>: one line per reference from
# orch-review-pass into orch-review, and per missing reviewer-start or
# description token.
scan_review_pass_self_contained() {
  local r="$1" pass="skills/orch-review-pass/SKILL.md" text name desc
  text="$(flat_text "$r/$pass" 2>/dev/null)"
  while IFS= read -r name; do
    grep -oE '\*\*[^*]+\*\*' <<<"$text" | sed 's/^\*\*//; s/\*\*$//' \
      | grep -qxE -e "$name" -e "$name:.*" \
      && echo "$pass: names orch-review's loop-only **$name**"
  done <<<"$review_loop_only"
  names_orch_review <"$r/$pass" 2>/dev/null && echo "$pass: names the orch-review skill"
  names_with_bold "$text" '`docs/host-capabilities.md`' "Start a fresh subagent" \
    || echo "$pass: does not name docs/host-capabilities.md's **Start a fresh subagent**"
  grep -qF 'subagent_type' <<<"$text" || echo "$pass: does not name subagent_type"
  desc="$(skill_description "$r/$pass")"
  grep -qF '/orchestrator:review-pass' <<<"$desc" \
    || echo "$pass: description does not name /orchestrator:review-pass"
  grep -qF 'orch-quick-implement' <<<"$desc" \
    || echo "$pass: description does not name orch-quick-implement"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review-pass"
printf '%s\n' '---' 'name: orch-review-pass' 'description: One look.' '---' '' \
  'See **The iteration** and **Authority: what the loop refuses to act on**,' \
  'judged as **Met' 'again** does, with **Severity**.' 'Start them as `orch-review` says.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
out="$(scan_review_pass_self_contained "$fixture")"
flags "a pass naming The iteration is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: names orch-review's loop-only **The iteration**"
flags "a pass naming a loop section by its full heading is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: names orch-review's loop-only **Authority**"
flags "a pass naming Met again across a line break is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: names orch-review's loop-only **Met again**"
flags "a pass naming Severity in bold is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: names orch-review's loop-only **Severity**"
flags "a pass naming the orch-review skill in plain prose is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: names the orch-review skill"
flags "a pass that does not say how to start a reviewer is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: does not name docs/host-capabilities.md's **Start a fresh subagent**"
flags "a pass that does not name subagent_type is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: does not name subagent_type"
flags "a pass description without /orchestrator:review-pass is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: description does not name /orchestrator:review-pass"
flags "a pass description without orch-quick-implement is flagged" \
  "$out" "skills/orch-review-pass/SKILL.md: description does not name orch-quick-implement"
printf '%s\n' '---' 'name: orch-review-pass' \
  'description: One look, from orch-quick-implement or /orchestrator:review-pass <issue>.' '---' '' \
  '## Review pass' '' 'A pass has no severity, and no closer. Start `orch-reviewer-spec` and' \
  '`orch-reviewer-standards` with `subagent_type`, or `docs/host-capabilities.md`'"'"'s' \
  '**Start a fresh' 'subagent**. Follow **Review pass** and `orchestrator:orch-review-pass`.' \
  >"$fixture/skills/orch-review-pass/SKILL.md"
assert_empty "a self-contained pass is not flagged" "$(scan_review_pass_self_contained "$fixture")"
check "orch-review-pass refers into no orch-review section and says how to start a reviewer" \
  "$(scan_review_pass_self_contained "$PLUGIN_ROOT")"

# follows_standalone_pass <text> <prefix>: one line, after <prefix> and a
# space, when the text does not name orch-review-pass's **Standalone review
# pass**, and one when it names the orch-review skill.
follows_standalone_pass() {
  names_with_bold "$1" orch-review-pass "Standalone review pass" \
    || echo "$2 does not name orch-review-pass's **Standalone review pass**"
  names_orch_review <<<"$1" && echo "$2 names the orch-review skill"
  return 0
}
# scan_review_pass_callers <plugin root>: one line per caller of the pass that
# does not name orch-review-pass and the section it follows, or names
# orch-review. Quick implementation's step 6 is named by scan_review_pass.
scan_review_pass_callers() {
  local r="$1" cmd="commands/review-pass.md" quick="skills/orch-quick-implement/SKILL.md"
  local sync="skills/orch-sync/SKILL.md" cmd_text step6_text offer_text
  cmd_text="$(flat_text "$r/$cmd" 2>/dev/null)"
  follows_standalone_pass "$cmd_text" "$cmd:"
  step6_text="$(md_section "$r/$quick" "## 6. Review" | flat_text)"
  names_orch_review <<<"$step6_text" && echo "$quick: step 6 names the orch-review skill"
  offer_text="$(md_section "$r/$sync" "## 3. Offer a review pass" | flat_text)"
  follows_standalone_pass "$offer_text" "$sync: step 3"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/commands" "$fixture/skills/orch-quick-implement" "$fixture/skills/orch-sync"
printf 'Call `orchestrator:orch-review` and follow its **Standalone review pass**.\n' \
  >"$fixture/commands/review-pass.md"
printf '# Q\n\n## 6. Review\n\nInvoke `orch-review` and `orch-review-pass`'"'"'s **Review pass**.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
printf '# S\n\n## 3. Offer a review pass\n\nInvoke `orch-review`'"'"'s **Review pass**.\n\n## 4. Other\n\n`orch-review-pass` **Standalone review pass**\n' \
  >"$fixture/skills/orch-sync/SKILL.md"
out="$(scan_review_pass_callers "$fixture")"
flags "a review-pass command that never names orch-review-pass is flagged" \
  "$out" "commands/review-pass.md: does not name orch-review-pass's **Standalone review pass**"
flags "a review-pass command that calls orch-review is flagged" \
  "$out" "commands/review-pass.md: names the orch-review skill"
flags "a quick step 6 that names orch-review is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 6 names the orch-review skill"
flags "a sync offer that does not follow orch-review-pass is flagged" \
  "$out" "skills/orch-sync/SKILL.md: step 3 does not name orch-review-pass's **Standalone review pass**"
flags "a sync offer that invokes orch-review is flagged" \
  "$out" "skills/orch-sync/SKILL.md: step 3 names the orch-review skill"
printf 'Call `orchestrator:orch-review-pass` and follow its **Standalone\nreview pass**.\n' \
  >"$fixture/commands/review-pass.md"
printf '# Q\n\n## 6. Review\n\nInvoke `orch-review-pass`'"'"'s **Review pass**.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
printf '# S\n\n## 3. Offer a review pass\n\nInvoke `orch-review-pass`'"'"'s **Standalone review pass**.\n' \
  >"$fixture/skills/orch-sync/SKILL.md"
assert_empty "callers that invoke orch-review-pass are not flagged" "$(scan_review_pass_callers "$fixture")"
check "every caller of the review pass invokes orch-review-pass, never orch-review" \
  "$(scan_review_pass_callers "$PLUGIN_ROOT")"

# scan_review_loop_sheds_pass <plugin root>: one line per copy of the pass
# left in orch-review, or per missing pointer to orch-review-pass.
scan_review_loop_sheds_pass() {
  local r="$1" review="skills/orch-review/SKILL.md" text desc heading
  text="$(flat_text "$r/$review" 2>/dev/null)"
  for heading in "Review pass" "Standalone review pass"; do
    md_section "$r/$review" "## $heading" >/dev/null 2>&1 \
      && echo "$review: holds a ## $heading section"
    grep -qF "**$heading**" <<<"$text" && echo "$review: names **$heading**"
  done
  desc="$(skill_description "$r/$review")"
  grep -qF 'orch-review-pass' <<<"$desc" || echo "$review: description does not name orch-review-pass"
  grep -qF '/orchestrator:review-pass' <<<"$desc" && echo "$review: description names /orchestrator:review-pass"
  skill_part "$r/$review" body | grep -qF 'orch-review-pass' \
    || echo "$review: body does not name orch-review-pass"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-review"
printf '%s\n' '---' 'name: orch-review' 'description: The loop, and /orchestrator:review-pass <issue>.' '---' '' \
  '## Review pass' '' 'See **Standalone' 'review pass** and **Review' 'pass**.' '' '## Standalone review pass' '' 'More.' \
  >"$fixture/skills/orch-review/SKILL.md"
out="$(scan_review_loop_sheds_pass "$fixture")"
flags "a Review pass section left in orch-review is flagged" \
  "$out" "skills/orch-review/SKILL.md: holds a ## Review pass section"
flags "a Standalone review pass section left in orch-review is flagged" \
  "$out" "skills/orch-review/SKILL.md: holds a ## Standalone review pass section"
flags "a **Standalone review pass** reference left in orch-review is flagged" \
  "$out" "skills/orch-review/SKILL.md: names **Standalone review pass**"
flags "a **Review pass** reference left in orch-review is flagged" \
  "$out" "skills/orch-review/SKILL.md: names **Review pass**"
flags "an orch-review description with no pointer to orch-review-pass is flagged" \
  "$out" "skills/orch-review/SKILL.md: description does not name orch-review-pass"
flags "an orch-review description that still claims the command is flagged" \
  "$out" "skills/orch-review/SKILL.md: description names /orchestrator:review-pass"
flags "an orch-review body with no pointer to orch-review-pass is flagged" \
  "$out" "skills/orch-review/SKILL.md: body does not name orch-review-pass"
printf '%s\n' '---' 'name: orch-review' 'description: The loop. The review pass is orch-review-pass.' '---' '' \
  '# Loop' '' 'A review pass lives in the `orch-review-pass` skill.' \
  >"$fixture/skills/orch-review/SKILL.md"
assert_empty "an orch-review that points to orch-review-pass is not flagged" \
  "$(scan_review_loop_sheds_pass "$fixture")"
printf '%s\n' '---' 'name: orch-review' 'description: The loop. The review pass is orch-review-pass.' '---' '' \
  '# Loop' '' 'No pointer here.' >"$fixture/skills/orch-review/SKILL.md"
flags "an orch-review naming orch-review-pass only in its frontmatter is flagged" \
  "$(scan_review_loop_sheds_pass "$fixture")" "skills/orch-review/SKILL.md: body does not name orch-review-pass"
printf '%s\n' '---' 'name: orch-review' 'description: The loop.' '---' '' \
  'description: see orch-review-pass.' >"$fixture/skills/orch-review/SKILL.md"
flags "a body description: line does not satisfy the orch-review description check" \
  "$(scan_review_loop_sheds_pass "$fixture")" "skills/orch-review/SKILL.md: description does not name orch-review-pass"
printf '%s\n' '# Loop' '' 'A review pass lives in the `orch-review-pass` skill.' \
  >"$fixture/skills/orch-review/SKILL.md"
spares "an orch-review with no frontmatter whose body names orch-review-pass keeps its body" \
  "$(scan_review_loop_sheds_pass "$fixture")" 'body does not name orch-review-pass'
check "orch-review holds the loop only and points to orch-review-pass" \
  "$(scan_review_loop_sheds_pass "$PLUGIN_ROOT")"

# scan_junie_review_pass <plugin root>: one line when Junie's custom-agent
# block has no orch-review-pass dependency sentence naming both reviewers.
scan_junie_review_pass() {
  local r="$1" doc="docs/junie/AGENTS.md" line
  line="$(md_section "$r/$doc" "## orchestrator plugin: custom agents" 2>/dev/null \
    | grep -E '^The orch-review-pass skill depends on')"
  { grep -qF 'orch-reviewer-spec' <<<"$line" && grep -qF 'orch-reviewer-standards' <<<"$line"; } \
    || echo "$doc: no orch-review-pass dependency sentence naming both reviewers"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/docs/junie"
printf '%s\n' '## orchestrator plugin: custom agents' '' \
  'The orch-review-pass skill depends on the orch-reviewer-spec custom agent.' \
  >"$fixture/docs/junie/AGENTS.md"
flags "an orch-review-pass sentence missing a reviewer is flagged" \
  "$(scan_junie_review_pass "$fixture")" "docs/junie/AGENTS.md: no orch-review-pass dependency sentence naming both reviewers"
printf '%s\n' '## orchestrator plugin: custom agents' '' \
  'The orch-review-pass skill depends on the orch-reviewer-spec and orch-reviewer-standards custom agents.' \
  >"$fixture/docs/junie/AGENTS.md"
assert_empty "an orch-review-pass sentence naming both reviewers is not flagged" \
  "$(scan_junie_review_pass "$fixture")"
check "Junie's custom-agent block names orch-review-pass's reviewers" \
  "$(scan_junie_review_pass "$PLUGIN_ROOT")"

# --- closer's filed body lines -----------------------------------------------
# The six labels - **Spec question:** only on a spec question - are the field
# names of a filed finding's body format, which `review file` renders from its
# flags and the finding-triage skill's prose reads. The closer's **Filing**
# section names each one as the line `review file` renders from its flag, so a
# label dropped there is a field that skill's reader cannot find described.
# Every label stays pinned, not only the ones orch.sh's scan parses. Under
# ADR-0027 this is a structural rule, not a phrase pin: the labels are the
# field names of a body format, and checking that a section names them is like
# checking for a required heading.
echo
echo "closer's filed body lines"
closer_filing_lines='**Axis:**
**Severity:**
**Location:**
**PR:**
**Why not fixed in the loop:**
**Spec question:**'
# scan_closer_filing <plugin root>: each labelled body line the closer's
# ## Filing section does not name, or the section itself when it is missing.
scan_closer_filing() {
  local r="$1" closer="agents/orch-closer.md" body line
  if ! body="$(md_section "$r/$closer" "## Filing")"; then
    echo "$closer: no ## Filing section"
    return 0
  fi
  while IFS= read -r line; do
    grep -qF -- "$line" <<<"$body" || echo "$closer: ## Filing does not name $line"
  done <<<"$closer_filing_lines"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/agents"
printf '# C\n\n## Filing\n\n**Axis:** **Severity:** **Location:** **Why not fixed in the loop:** **Spec question:**\n\n## Other\n\n**PR:**\n' \
  >"$fixture/agents/orch-closer.md"
flags "a Filing section that drops a labelled line is flagged" \
  "$(scan_closer_filing "$fixture")" "agents/orch-closer.md: ## Filing does not name **PR:**"
spares "and the lines it names are not" "$(scan_closer_filing "$fixture")" 'name \*\*(Axis|Severity|Location|Why|Spec)'
printf '# C\n\n## Filing\n\n**Axis:** **Severity:** **Location:** **PR:** **Why not fixed in the loop:**\n' \
  >"$fixture/agents/orch-closer.md"
flags "a Filing section that drops **Spec question:** is flagged" \
  "$(scan_closer_filing "$fixture")" "agents/orch-closer.md: ## Filing does not name **Spec question:**"
printf '# C\n\n## Other\n' >"$fixture/agents/orch-closer.md"
flags "a missing Filing section is flagged" \
  "$(scan_closer_filing "$fixture")" "agents/orch-closer.md: no ## Filing section"
printf '# C\n\n## Filing\n\n**Axis:** **Severity:** **Location:** **PR:** **Why not fixed in the loop:** **Spec question:**\n' \
  >"$fixture/agents/orch-closer.md"
assert_empty "a Filing section naming all six is not flagged" "$(scan_closer_filing "$fixture")"
check "the closer's Filing section names every labelled line the closer's body format carries" \
  "$(scan_closer_filing "$PLUGIN_ROOT")"

# --- routed nouns and their verbs are in the CLI conventions -------------------
# docs/agents/cli-conventions.md maps orch.sh's grammar: every noun the
# dispatcher in main() routes is either a row of its Current nouns table or is
# named in its Exceptions section, so a new noun cannot ship unmapped. A table
# noun's verbs match its row both ways, a verb Exceptions names as
# `<noun> <verb>` aside; redo's verbs are each named so in Exceptions; a bare
# global command - one Exceptions' "Bare global commands" bullet names - has no
# verbs to check.
echo
echo "routed nouns and their verbs are in the CLI conventions"
# routed_nouns <orch.sh>: one line per command main()'s case statement routes,
# its option spellings (-h, --help) and the catch-all left out.
routed_nouns() {
  awk '
    /^main\(\) \{/ { inm = 1; next }
    inm && /^\}/ { exit }
    inm && match($0, /^[[:space:]]+[a-z][a-z|-]*\)/) {
      arm = substr($0, RSTART, RLENGTH - 1); gsub(/[[:space:]]/, "", arm)
      n = split(arm, names, "|")
      for (i = 1; i <= n; i++) if (names[i] !~ /^-/) print names[i]
    }' "$1"
}
# noun_verbs <module> <noun>: one line per verb the noun dispatches - each name
# on a top-level arm of the first case in the module's cmd_<noun> (- mapped to
# _), its option spellings, the catch-all and nested cases' arms left out.
noun_verbs() {
  [ -f "$1" ] || return 0
  F="cmd_${2//-/_}" awk '
    BEGIN { fn = ENVIRON["F"] }
    index($0, fn "()") == 1 { inf = 1; next }
    !inf { next }
    /^\}/ { exit }
    /^[[:space:]]*#/ { next }
    {
      if (depth == 1 && match($0, /^[[:space:]]+[a-z-][a-z|-]*\)/)) {
        arm = substr($0, RSTART, RLENGTH - 1); gsub(/[[:space:]]/, "", arm)
        n = split(arm, names, "|")
        for (i = 1; i <= n; i++) if (names[i] !~ /^-/) print names[i]
      }
      t = $0; opens = gsub(/(^|[;[:space:]])case[[:space:]]/, "", t)
      t = $0; closes = gsub(/(^|[;[:space:]])esac([;[:space:])]|$)/, "", t)
      if (opens) started = 1
      depth += opens - closes
      if (started && depth <= 0) exit
    }' "$1"
}
# scan_cli_nouns <plugin root>: each routed noun in neither the table nor the
# Exceptions section, and each verb out of step with its noun's row or
# Exceptions.
scan_cli_nouns() {
  local r="$1" orch="scripts/orch.sh" doc="docs/agents/cli-conventions.md" table exceptions noun
  local bare row row_verbs module verbs verb
  table="$(md_section "$r/$doc" "## Current nouns" | grep -E '^[[:space:]]*\|')"
  exceptions="$(md_section "$r/$doc" "## Exceptions")"
  # The "Bare global commands" bullet, up to the next bullet.
  bare="$(awk '/^- \*\*Bare global commands\*\*/ { inb = 1; print; next } inb && /^- / { exit } inb' <<<"$exceptions")"
  while IFS= read -r noun; do
    [ -n "$noun" ] || continue
    module="scripts/orch/$noun.sh"
    verbs="$(noun_verbs "$r/$module" "$noun")"
    row="$(grep -E -- "^[[:space:]]*\|[[:space:]]*\`$noun\`" <<<"$table" | head -n 1)"
    if [ -z "$row" ]; then
      if ! grep -qE -- "\`${noun}[\` ]" <<<"$exceptions"; then
        echo "$doc: routed noun $noun is in neither the Current nouns table nor Exceptions"
        continue
      fi
      # A bare global command: no verbs to check.
      grep -qF -- "\`$noun\`" <<<"$bare" && continue
    fi
    # The row's verbs: the backticked names in its second cell.
    row_verbs="$(awk -F'|' '{ print $3 }' <<<"$row" | grep -oE '`[^`]+`' | tr -d '`')"
    while IFS= read -r verb; do
      [ -n "$verb" ] || continue
      grep -qxF -- "$verb" <<<"$row_verbs" && continue
      grep -qF -- "\`$noun $verb\`" <<<"$exceptions" && continue
      echo "$doc: $noun verb $verb is dispatched but in neither its Current nouns row nor Exceptions"
    done <<<"$verbs"
    while IFS= read -r verb; do
      [ -n "$verb" ] || continue
      grep -qxF -- "$verb" <<<"$verbs" && continue
      echo "$doc: $noun verb $verb is in its Current nouns row but $module no longer dispatches it"
    done <<<"$row_verbs"
  done < <(routed_nouns "$r/$orch")
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts" "$fixture/docs/agents"
printf '%s\n' 'main() {' '  case "$cmd" in' '    base)   cmd_base "$@" ;;' '    redo)   cmd_redo "$@" ;;' \
  '    help|-h|--help) cmd_help ;;' '    widget) cmd_widget "$@" ;;' '    *) die nope ;;' '  esac' '}' \
  '  stray) not_routed ;;' >"$fixture/scripts/orch.sh"
printf '%s\n' '# CLI' '' '## Current nouns' '' '| Noun | Verbs |' '| --- | --- |' '| `base` | `set` |' '' \
  'widget is mentioned here but not in the table.' '' '## Exceptions' '' '- `help`, and `redo review` / `redo spec`.' \
  >"$fixture/docs/agents/cli-conventions.md"
out="$(scan_cli_nouns "$fixture")"
flags "a routed noun in neither the table nor Exceptions is flagged" \
  "$out" "docs/agents/cli-conventions.md: routed noun widget is in neither"
spares "a noun in the table, or in Exceptions, is not" "$out" 'noun (base|redo|help) '
spares "nor an option spelling, the catch-all, or an arm outside main" "$out" 'noun (-h|--help|\*|stray) '
# The verbs fixture: base dispatches an unlisted verb and no longer dispatches
# a row verb, redo dispatches a verb Exceptions does not name, and the rest is
# spared.
fixture="$(new_fixture)"
mkdir -p "$fixture/scripts/orch" "$fixture/docs/agents"
printf '%s\n' 'main() {' '  case "$cmd" in' '    base) cmd_base "$@" ;;' '    redo) cmd_redo "$@" ;;' \
  '    doctor) cmd_doctor "$@" ;;' '    widget-thing) cmd_widget_thing "$@" ;;' '    *) die nope ;;' '  esac' '}' \
  >"$fixture/scripts/orch.sh"
printf '%s\n' 'cmd_base() {' '  case "$1" in' '    set)' '      case "$2" in' '        major)' '          x=1 ;;' \
  '        green)' '          x=2 ;;' '      esac' '      ;;' '    show|-x|--long) echo ;;' '    extra) echo ;;' \
  '    *) die "unknown base op" ;;' '  esac' '  case "$1" in' '    later) echo ;;' '  esac' '}' >"$fixture/scripts/orch/base.sh"
printf '%s\n' 'cmd_redo() {' '  case "$1" in' '    review) cmd_redo_review ;;' '    spec) cmd_redo_spec ;;' \
  '    zap) cmd_redo_zap ;;' '    *) die nope ;;' '  esac' '}' >"$fixture/scripts/orch/redo.sh"
printf '%s\n' 'cmd_doctor() {' '  case "$1" in' '    --flow) echo ;;' '    check) echo ;;' '  esac' '}' \
  >"$fixture/scripts/orch/doctor.sh"
printf '%s\n' 'cmd_widget_thing() {' '  case "$1" in' '    go|stop) echo ;;' '  esac' '}' \
  >"$fixture/scripts/orch/widget-thing.sh"
printf '%s\n' '# CLI' '' '## Current nouns' '' '| Noun | Verbs |' '| --- | --- |' \
  '| `base` | `set`, `show`, `clear` |' '| `widget-thing` | `go`, `stop` |' '' '## Exceptions' '' \
  '- **Bare global commands**: `doctor`.' '- **`redo review` / `redo spec`**: not ops belonging to a `redo` noun.' \
  >"$fixture/docs/agents/cli-conventions.md"
out="$(scan_cli_nouns "$fixture")"
flags "a dispatched verb in neither its row nor Exceptions is flagged" \
  "$out" "docs/agents/cli-conventions.md: base verb extra is dispatched but in neither"
flags "a redo verb not named redo <verb> in Exceptions is flagged" \
  "$out" "docs/agents/cli-conventions.md: redo verb zap is dispatched but in neither"
flags "a row verb its module no longer dispatches is flagged" \
  "$out" "docs/agents/cli-conventions.md: base verb clear is in its Current nouns row but"
spares "nested-case arms, option spellings, the catch-all and a later case are not verbs" \
  "$out" 'verb (major|green|-x|--long|\*|later) '
spares "a row verb, a redo <verb> in Exceptions, and a hyphenated noun's verbs are spared" \
  "$out" '(base verb (set|show) |redo verb (review|spec) |widget-thing verb )'
spares "a bare global command in Exceptions has no verbs to check" "$out" '(doctor|routed noun) '
check "every noun orch.sh routes, and every verb it dispatches, is in the CLI conventions table or its Exceptions" \
  "$(scan_cli_nouns "$PLUGIN_ROOT")"

# --- a side checkout's recorded issue (#874) ----------------------------------
echo
echo "a side checkout's recorded issue (#874)"
# A side checkout made for a quick implementation records its issue, and a
# session opened in it picks the issue up: quick implementation's step 1 reads
# side-checkout issue, both skills' side routes open the new session with the
# command already typed, and quick implementation's passes --issue.
side_checkout_sentence='One made for a quick implementation records that implementation'"'"'s issue, so a session opened in it picks the issue up without being told.'
# glossary_entry <file> <term>: the entry's lines, on one line, read by
# glossary.sh's own parser so the entry grammar is never re-derived here.
glossary_entry() {
  (source "$PLUGIN_ROOT/scripts/orch/glossary.sh" &&
    GLOSSARY_MISSING=/dev/null glossary_run show "$1" "$2" 2>/dev/null) | flat_text
}
# scan_side_checkout_issue <plugin root>: one line per break of that rule.
scan_side_checkout_issue() {
  local r="$1" quick="skills/orch-quick-implement/SKILL.md" flow="skills/orch-flow/SKILL.md" body
  body="$(md_section "$r/$quick" "## 1. Require a linked issue" | flat_text)"
  grep -qF 'side-checkout issue' <<<"$body" \
    || echo "$quick: step 1 does not name side-checkout issue"
  body="$(md_section "$r/$quick" "## Starting in a side checkout" | flat_text)"
  grep -qF 'claude "/orchestrator:quick-implement <issue>"' <<<"$body" \
    || echo "$quick: ## Starting in a side checkout does not prefill claude \"/orchestrator:quick-implement <issue>\""
  grep -qF -- '--issue' <<<"$body" \
    || echo "$quick: ## Starting in a side checkout does not pass --issue"
  body="$(md_section "$r/$flow" "### Starting in a side checkout" | flat_text)"
  grep -qF 'claude "/orchestrator:next"' <<<"$body" \
    || echo "$flow: ### Starting in a side checkout does not prefill claude \"/orchestrator:next\""
  glossary_entry "$r/GLOSSARY.md" "Side checkout" | grep -qF -- "$side_checkout_sentence" \
    || echo "GLOSSARY.md: the **Side checkout** entry does not carry the recorded-issue sentence"
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-quick-implement" "$fixture/skills/orch-flow"
printf '# Q\n\n## 1. Require a linked issue\n\nUse the argument.\n\n## Starting in a side checkout\n\nRun `side-checkout add <slug>`, then `cd <path> && claude`.\n\n## Other\n\nRun `side-checkout issue`, --issue, claude "/orchestrator:quick-implement <issue>".\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
printf '# F\n\n### Starting in a side checkout\n\nRun `cd <path> && claude`.\n\n## Next phase\n\nclaude "/orchestrator:next"\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
printf '**Side checkout**:\nA worktree.\n\n**Other**:\n%s\n' "$side_checkout_sentence" >"$fixture/GLOSSARY.md"
out="$(scan_side_checkout_issue "$fixture")"
flags "a step 1 that does not read side-checkout issue is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 1 does not name side-checkout issue"
flags "a quick side route that does not prefill the command is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: ## Starting in a side checkout does not prefill"
flags "a quick side route that does not pass --issue is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: ## Starting in a side checkout does not pass --issue"
flags "a flow side route that does not prefill the command is flagged" \
  "$out" "skills/orch-flow/SKILL.md: ### Starting in a side checkout does not prefill"
flags "a Side checkout entry without the sentence is flagged" \
  "$out" "GLOSSARY.md: the **Side checkout** entry does not carry the recorded-issue sentence"
printf '# Q\n\n## 1. Require a linked issue\n\nThen `bash "$ORCH" side-checkout\nissue`.\n\n## Starting in a side checkout\n\n`side-checkout add <slug> --issue <issue>`, then `cd <path> && claude\n"/orchestrator:quick-implement <issue>"`.\n' \
  >"$fixture/skills/orch-quick-implement/SKILL.md"
printf '# F\n\n### Starting in a side checkout\n\nRun `cd <path> && claude "/orchestrator:next"`.\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
printf '**Side checkout**:\nA worktree. One made for a quick implementation records that\nimplementation'"'"'s issue, so a session opened in it picks the issue up without\nbeing told.\n\n**Other**:\nOther.\n' >"$fixture/GLOSSARY.md"
assert_empty "skills and a glossary that carry the recorded issue are not flagged" \
  "$(scan_side_checkout_issue "$fixture")"
check "a side checkout's recorded issue is read by step 1, prefilled, and in the glossary" \
  "$(scan_side_checkout_issue "$PLUGIN_ROOT")"

# --- docs/ paths resolve (#901) -----------------------------------------------
echo
echo "docs/ paths resolve (#901)"
# A skill or agent that names a docs/<path>.md under the plugin root points a
# model at that file, so the file must exist. Directory references (docs/adr/)
# and placeholders (docs/adr/<file>.md) name no one file and are not checked.
# A path under the plugin root's variable or placeholder (${CLAUDE_PLUGIN_ROOT}/docs/,
# <plugin root>/docs/) is checked; one under any other directory is not ours.
# skill_agent_md_grep <plugin root> <grep args...>: grep run over every .md file
# under the root's skills/ and agents/, each hit as "<file>:<line>:<match>".
skill_agent_md_grep() {
  local r="$1"; shift
  (cd "$r" && find skills agents -name '*.md' -type f 2>/dev/null | sort | xargs -r grep -H "$@")
}
# scan_docs_paths <plugin root>: each docs/<path>.md a file under skills/ or
# agents/ names that does not exist, as "<file>:<line>: names missing <path>".
scan_docs_paths() {
  local r="$1" file line match path
  [ -d "$r/skills" ] || [ -d "$r/agents" ] || return 0
  skill_agent_md_grep "$r" -noE '(^|[^A-Za-z0-9_./-]|[}>]/)docs/[A-Za-z0-9_./<>*-]*\.md' \
    | while IFS=: read -r file line match; do
      path="docs/${match#*docs/}"
      case "$path" in *'<'* | *'*'*) continue ;; esac
      [ -e "$r/$path" ] || echo "$file:$line: names missing $path"
    done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-a" "$fixture/agents" "$fixture/docs/adr"
: >"$fixture/docs/here.md"
: >"$fixture/docs/adr/0001-x.md"
printf 'See `docs/gone.md`.\n' >"$fixture/skills/orch-a/SKILL.md"
printf '%s\n' 'Read docs/adr/0002-gone.md.' 'Read ${CLAUDE_PLUGIN_ROOT}/docs/rooted-gone.md.' \
  'Read `<plugin root>/docs/placeholder-gone.md`.' >"$fixture/agents/a.md"
printf '%s\n' 'See `docs/here.md` and docs/adr/0001-x.md.' 'ADRs live in `docs/adr/`.' \
  'Write `docs/adr/<file>.md`.' 'Not ours: some/docs/gone.md.' >"$fixture/agents/b.md"
out="$(scan_docs_paths "$fixture")"
flags "a skill naming a missing docs/ file is flagged" \
  "$out" "skills/orch-a/SKILL.md:1: names missing docs/gone.md"
flags "an agent naming a missing nested docs/ file is flagged" \
  "$out" "agents/a.md:1: names missing docs/adr/0002-gone.md"
flags "a docs/ file under the plugin root's variable is flagged" \
  "$out" "agents/a.md:2: names missing docs/rooted-gone.md"
flags "a docs/ file under a plugin root placeholder is flagged" \
  "$out" "agents/a.md:3: names missing docs/placeholder-gone.md"
spares "existing docs/ files are not flagged" "$out" 'docs/(here|adr/0001-x)\.md'
spares "a docs/ directory reference is not flagged" "$out" 'docs/adr/$'
spares "a docs/ placeholder path is not flagged" "$out" '<file>'
spares "a path that only ends in docs/ is not flagged" "$out" '^agents/b\.md'
check "every docs/ file a skill or agent names exists" "$(scan_docs_paths "$PLUGIN_ROOT")"

# --- one driver loop (#901) ----------------------------------------------------
echo
echo "one driver loop (#901)"
# The driver loop's steps a-f live once, in docs/driver-loop.md under the plugin
# root, and the skills that run it point there. A loop step label in a skill or
# agent is a copy of the loop surviving outside the doc.
loop_labels=('**a. Entry check.**' '**b. Pick the path.**' '**c. Fill the free slots.**'
  '**d. As each report returns**' '**e. On a merge conflict**' '**f. Verify the combined branch**')
# scan_driver_loop <plugin root>: each loop step label missing from
# docs/driver-loop.md, and each one in a file under skills/ or agents/.
scan_driver_loop() {
  local r="$1" doc="docs/driver-loop.md" label
  for label in "${loop_labels[@]}"; do
    grep -qF -- "$label" "$r/$doc" 2>/dev/null || echo "$doc: missing loop step label $label"
    skill_agent_md_grep "$r" -nF -- "$label" | sed -E 's/^([^:]*:[0-9]+):.*/\1: driver loop step label outside '"${doc//\//\\/}"'/'
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/skills/orch-a" "$fixture/skills/orch-b" "$fixture/docs"
printf '%s\n' '# Doc' '' '- **a. Entry check.** List.' '- **b. Pick the path.** Read.' >"$fixture/docs/driver-loop.md"
printf '%s\n' '# A' '' '- **c. Fill the free slots.** Keep.' >"$fixture/skills/orch-a/SKILL.md"
printf '%s\n' '# B' '' 'Run the driver loop in `docs/driver-loop.md`: loop step a, the entry check.' \
  >"$fixture/skills/orch-b/SKILL.md"
out="$(scan_driver_loop "$fixture")"
flags "a skill carrying a loop step label is flagged" \
  "$out" "skills/orch-a/SKILL.md:3: driver loop step label outside docs/driver-loop.md"
flags "a loop step label missing from the doc is flagged" \
  "$out" "docs/driver-loop.md: missing loop step label **f. Verify the combined branch**"
spares "a skill that only points at the doc is not flagged" "$out" '^skills/orch-b/'
check "the driver loop lives once, in docs/driver-loop.md" "$(scan_driver_loop "$PLUGIN_ROOT")"

# --- docs/ in the Layout map (#1008) -------------------------------------------
echo
echo "docs/ in the Layout map (#1008)"
# Every doc under docs/ has a line in CONTRIBUTING.md's Layout map, the code
# block of its ## Layout section, whose lines each start with the path they
# describe. A docs/*.md is listed when a line starts with its path. A
# docs/<dir>/ is listed when a line starts with docs/<dir>/ itself, or when
# every file under it is listed; no directory is exempt.
# layout_paths <plugin root>: the first word of each line of the Layout map's
# code block.
layout_paths() {
  md_section_first_block "$1/CONTRIBUTING.md" "## Layout" 2>/dev/null | awk 'NF { print $1 }'
}
# scan_layout_map <plugin root>: each docs/*.md and docs/<dir>/ the Layout map
# does not list, as "CONTRIBUTING.md: the Layout map does not list <path>",
# a partly listed directory followed by its unlisted files.
scan_layout_map() {
  local r="$1" paths path dir files missing
  [ -d "$r/docs" ] || return 0
  paths="$(layout_paths "$r")"
  for path in "$r"/docs/*.md; do
    [ -f "$path" ] || continue
    path="${path#"$r"/}"
    grep -qxF -- "$path" <<<"$paths" || echo "CONTRIBUTING.md: the Layout map does not list $path"
  done
  for dir in "$r"/docs/*/; do
    [ -d "$dir" ] || continue
    dir="${dir#"$r"/}"
    grep -qxF -- "$dir" <<<"$paths" && continue
    files="$(cd "$r" && find "$dir" -type f | sort)"
    missing="$(grep -vxF -- "$paths" <<<"$files" | tr '\n' ' ')"
    missing="${missing% }"
    if [ "$missing" = "$(tr '\n' ' ' <<<"$files" | sed 's/ $//')" ]; then
      echo "CONTRIBUTING.md: the Layout map does not list $dir"
    elif [ -n "$missing" ]; then
      echo "CONTRIBUTING.md: the Layout map does not list $dir (unlisted: $missing)"
    fi
  done
  return 0
}
fixture="$(new_fixture)"
mkdir -p "$fixture/docs/unlisted" "$fixture/docs/partly" "$fixture/docs/whole" "$fixture/docs/bydir"
: >"$fixture/docs/listed.md"
: >"$fixture/docs/gone.md"
: >"$fixture/docs/unlisted/a.md"
: >"$fixture/docs/partly/a.md"
: >"$fixture/docs/partly/b.md"
: >"$fixture/docs/whole/a.md"
: >"$fixture/docs/whole/b.md"
: >"$fixture/docs/bydir/a.md"
printf '%s\n' '# C' '' '## Layout' '' '```' \
  'docs/listed.md      a doc' 'docs/partly/a.md    one of two' \
  'docs/whole/a.md     one' 'docs/whole/b.md     two' 'docs/bydir/         a dir' '```' '' \
  'Prose naming docs/gone.md outside the block.' '' '## Next' '' '```' 'docs/unlisted/' '```' \
  >"$fixture/CONTRIBUTING.md"
out="$(scan_layout_map "$fixture")"
flags "an unlisted docs/*.md is flagged" \
  "$out" "CONTRIBUTING.md: the Layout map does not list docs/gone.md"
flags "an unlisted docs/<dir>/ is flagged" \
  "$out" "CONTRIBUTING.md: the Layout map does not list docs/unlisted/"
flags "a partly listed docs/<dir>/ is flagged, naming its unlisted file" \
  "$out" "CONTRIBUTING.md: the Layout map does not list docs/partly/ (unlisted: docs/partly/b.md)"
spares "a listed docs/*.md is not flagged" "$out" 'docs/listed\.md'
spares "a directory listed through all its files is not flagged" "$out" 'docs/whole/'
spares "a directory listed as docs/<dir>/ is not flagged" "$out" 'docs/bydir/'
check "every doc under docs/ is in CONTRIBUTING.md's Layout map" "$(scan_layout_map "$PLUGIN_ROOT")"

# --- the PR-writing standard (#1389) ------------------------------------------
echo
echo "the PR-writing standard (#1389)"
# Every PR body and PR comment the plugin writes follows docs/pr-writing.md,
# so each PR-writing site names it: the three body sites, the three comment
# sites, and the fixer's PR-body check.
pr_writing_sites='skills/orch-flow/SKILL.md|### Phase: implement
skills/orch-quick-implement/SKILL.md|## 7. Open the PR
skills/orch-release/SKILL.md
agents/orch-closer.md|## The PR comment
skills/orch-review-pass/SKILL.md
skills/orch-sync/SKILL.md
agents/orch-fixer.md|## Checking the PR body'
fixture="$(new_fixture)"
mkdir -p "$fixture/agents" "$fixture/skills/orch-flow" "$fixture/skills/orch-quick-implement" \
  "$fixture/skills/orch-release" "$fixture/skills/orch-review-pass" "$fixture/skills/orch-sync"
printf '# F\n\n### Phase: implement\n\nOpen the PR.\n\n### Phase: review\n\nSee `docs/pr-writing.md`.\n' \
  >"$fixture/skills/orch-flow/SKILL.md"
printf '# Q\n\n## 7. Open the PR\n\nWrite it per\n`docs/pr-writing.md`.\n' >"$fixture/skills/orch-quick-implement/SKILL.md"
printf '# R\n\nWrite the summary.\n' >"$fixture/skills/orch-release/SKILL.md"
printf '# C\n\n## Filing\n\nFile.\n' >"$fixture/agents/orch-closer.md"
for f in skills/orch-review-pass/SKILL.md skills/orch-sync/SKILL.md; do
  printf '# S\n\nPost per `docs/pr-writing.md`.\n' >"$fixture/$f"
done
printf '# X\n\n## Checking the PR body\n\nCheck the human layer per `docs/pr-writing.md`.\n' \
  >"$fixture/agents/orch-fixer.md"
out="$(scan_names_phrase "$fixture" "$pr_writing_sites" 'docs/pr-writing.md')"
flags "a flow implement phase that names the doc only in another phase is flagged" \
  "$out" "skills/orch-flow/SKILL.md: ### Phase: implement does not name docs/pr-writing.md"
flags "a release skill that never names the doc is flagged" \
  "$out" "skills/orch-release/SKILL.md: does not name docs/pr-writing.md"
flags "a closer with no PR comment section is flagged" \
  "$out" "agents/orch-closer.md: no ## The PR comment section"
spares "sites that name the doc, wrapped across lines or not, are not flagged" \
  "$out" "orch-(quick-implement|review-pass|sync|fixer)"
check "each PR-writing site names docs/pr-writing.md" \
  "$(scan_names_phrase "$PLUGIN_ROOT" "$pr_writing_sites" 'docs/pr-writing.md')"

# --- version and CHANGELOG (CLAUDE.md Versioning) -----------------------------
# Every PR to main adds one changelog fragment, changelog.d/<issue>.md, and
# never bumps the version by hand: the version-bump Action does, on merge. The
# CHANGELOG rule always runs; the fragment rule runs against the real root only
# when CHANGELOG_BASE holds main's commit, and waives its one-fragment part when
# NO_VERSION_BUMP is set; .github/workflows/test.yml's "Read main's commit"
# step sets both, and its Verify step carries the GH_TOKEN the fragment rule's
# parent lookup reads issues with.
echo
echo "version and CHANGELOG (CLAUDE.md Versioning)"
# version_field: the version field of the plugin.json on stdin, empty when
# there is none. The linter needs no jq: plugin.json keeps it on one line.
version_field() {
  sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1
}
# plugin_version <plugin root>: the version field of its plugin.json.
plugin_version() { version_field <"$1/.claude-plugin/plugin.json" 2>/dev/null; }
# scan_changelog <plugin root>: the CHANGELOG's first ## heading is exactly
# ## <version>, its section is non-empty, and no other ## <version> heading
# for that version exists.
scan_changelog() {
  local r="$1" v top
  v="$(plugin_version "$r")"
  if [ -z "$v" ]; then echo ".claude-plugin/plugin.json: no version"; return 0; fi
  if [ ! -f "$r/CHANGELOG.md" ]; then echo "CHANGELOG.md: missing, so it has no ## $v entry"; return 0; fi
  top="$(grep -m 1 -E '^## ' "$r/CHANGELOG.md" | sed 's/[[:space:]]*$//')"
  if [ "$top" != "## $v" ]; then
    echo "CHANGELOG.md: top entry is '${top:-none}', not '## $v'"
    return 0
  fi
  md_section "$r/CHANGELOG.md" "## $v" | grep -q '[^[:space:]]' ||
    echo "CHANGELOG.md: the ## $v entry is empty"
  [ "$(sed 's/[[:space:]]*$//' "$r/CHANGELOG.md" | grep -cxF -- "## $v")" -le 1 ] ||
    echo "CHANGELOG.md: more than one ## $v entry"
  return 0
}
# changelog_fixture <version> <CHANGELOG lines...>: a fixture root whose
# plugin.json carries <version> (none when empty) and whose CHANGELOG.md is
# the given lines.
changelog_fixture() {
  local f v="$1"; shift
  f="$(new_fixture)"
  mkdir -p "$f/.claude-plugin"
  if [ -n "$v" ]; then printf '{\n  "name": "x",\n  "version": "%s"\n}\n' "$v" >"$f/.claude-plugin/plugin.json"
  else printf '{\n  "name": "x"\n}\n' >"$f/.claude-plugin/plugin.json"; fi
  printf '%s\n' "$@" >"$f/CHANGELOG.md"
  echo "$f"
}
flags "a top CHANGELOG heading that is not the version is flagged" \
  "$(scan_changelog "$(changelog_fixture 3.2.0 '# Changelog' '' '## 3.1.0' '' 'Old.')")" \
  "CHANGELOG.md: top entry is '## 3.1.0', not '## 3.2.0'"
flags "an empty top CHANGELOG entry is flagged" \
  "$(scan_changelog "$(changelog_fixture 3.2.0 '# Changelog' '' '## 3.2.0' '' '## 3.1.0' '' 'Old.')")" \
  "CHANGELOG.md: the ## 3.2.0 entry is empty"
flags "a duplicate ## <version> heading is flagged" \
  "$(scan_changelog "$(changelog_fixture 3.2.0 '# Changelog' '' '## 3.2.0' '' 'New.' '' '## 3.2.0' '' 'Again.')")" \
  "CHANGELOG.md: more than one ## 3.2.0 entry"
fixture="$(changelog_fixture 3.2.0 '## 3.2.0' '' 'New.')"
rm "$fixture/CHANGELOG.md"
flags "a missing CHANGELOG.md is flagged" "$(scan_changelog "$fixture")" "CHANGELOG.md: missing"
flags "a plugin.json with no version is flagged" \
  "$(scan_changelog "$(changelog_fixture '' '# Changelog' '' '## 3.2.0' '' 'New.')")" \
  ".claude-plugin/plugin.json: no version"
spares "a CHANGELOG topped by a non-empty entry for the version is not flagged" \
  "$(scan_changelog "$(changelog_fixture 3.2.0 '# Changelog' '' '## 3.2.0' '' 'New.' '' '## 3.1.0' '' 'Old.')")" '.'
check "CHANGELOG.md's top entry is the plugin.json version" "$(scan_changelog "$PLUGIN_ROOT")"

# scan_changelog_fragments <plugin root> <base commit> [<no bump>]: the
# root's HEAD, against its merge-base with <base commit>. Unless <no bump> is
# non-empty, it adds exactly one file under changelog.d/, named <digits>.md
# and well-formed as scripts/version-bump.sh reads it. Always: plugin.json's
# version is unchanged, CHANGELOG.md gains no ## heading, and no fragment the
# merge-base holds is modified or deleted. changelog.d/.gitkeep is not a
# fragment: adding it counts for nothing, and changing it is flagged on its
# own. The one fragment's issue must not be a sub-issue: a fragment is named
# for the PR's issue, never a ticket (CLAUDE.md Versioning).
scan_changelog_fragments() {
  local r="$1" base="$2" no_bump="${3:-}" mb status path added=() old new heading frag issue parent
  if ! mb="$(git -C "$r" merge-base "$base" HEAD 2>/dev/null)"; then
    echo "CHANGELOG_BASE: no merge-base with HEAD for '$base'"; return 0
  fi
  while IFS=$'\t' read -r status path; do
    if [ "$path" = changelog.d/.gitkeep ]; then
      case "$status" in
        A) ;;
        M) echo "$path: modified; version-bump.sh keeps it" ;;
        D) echo "$path: deleted; version-bump.sh keeps it" ;;
        *) echo "$path: changed ($status); version-bump.sh keeps it" ;;
      esac
      continue
    fi
    case "$status" in
      A) added+=("$path") ;;
      M) echo "$path: an existing fragment is modified" ;;
      D) echo "$path: an existing fragment is deleted" ;;
      *) echo "$path: an existing fragment is changed ($status)" ;;
    esac
  done < <(git -C "$r" diff --no-renames --name-status "$mb" HEAD -- changelog.d/)
  if [ -z "$no_bump" ]; then
    if [ "${#added[@]}" -eq 0 ]; then
      echo "changelog.d/: no changelog fragment added; add one, changelog.d/<issue>.md"
    elif [ "${#added[@]}" -gt 1 ]; then
      echo "changelog.d/: ${#added[@]} changelog fragments added, not one: ${added[*]}"
    elif ! [[ "${added[0]}" =~ ^changelog\.d/[0-9]+\.md$ ]]; then
      echo "${added[0]}: not named <issue>.md, <issue> all digits"
    else
      # Well-formed as the version-bump script reads it: the script itself,
      # run on a scratch checkout holding only this fragment.
      frag="$(new_fixture)"
      mkdir -p "$frag/.claude-plugin" "$frag/changelog.d"
      printf '{\n  "version": "0.0.0"\n}\n' >"$frag/.claude-plugin/plugin.json"
      printf '%s\n' '## 0.0.0' '' 'Scratch.' >"$frag/CHANGELOG.md"
      git -C "$r" show "HEAD:${added[0]}" >"$frag/${added[0]}"
      (cd "$frag" && bash "$PLUGIN_ROOT/scripts/version-bump.sh" 2>&1 >/dev/null) |
        sed 's/^version-bump: //'
      issue="$(basename "${added[0]}" .md)"
      if ! parent="$(cd "$r" && issue_parent_url "$issue")"; then
        echo "${added[0]}: looking up #$issue's parent issue failed (gh api), so the fragment's name is unchecked"
      elif [ -n "$parent" ]; then
        echo "${added[0]}: #$issue is a sub-issue of #${parent##*/}; name the fragment for the PR's issue, never a ticket"
      fi
    fi
  fi
  old="$(git -C "$r" show "$mb:.claude-plugin/plugin.json" 2>/dev/null | version_field)"
  new="$(git -C "$r" show "HEAD:.claude-plugin/plugin.json" 2>/dev/null | version_field)"
  [ "$old" = "$new" ] ||
    echo ".claude-plugin/plugin.json: version changed from $old to $new; the version-bump Action bumps it on merge"
  while IFS= read -r heading; do
    [ -n "$heading" ] &&
      echo "CHANGELOG.md: $heading added; the version-bump Action adds the entry on merge"
  done < <(LC_ALL=C comm -13 \
    <(git -C "$r" show "$mb:CHANGELOG.md" 2>/dev/null | grep -E '^## ' | LC_ALL=C sort) \
    <(git -C "$r" show "HEAD:CHANGELOG.md" 2>/dev/null | grep -E '^## ' | LC_ALL=C sort))
  return 0
}
# issue_parent_url <n>: issue <n>'s parent_issue_url, read from GitHub for the
# repo of the current directory; empty when it has none. Fails when gh does.
# The fixture self-tests replace it with a fake.
issue_parent_url() {
  gh api "repos/{owner}/{repo}/issues/$1" --jq '.parent_issue_url // ""'
}
# fragment_fixture: a fixture git repo whose main branch holds plugin.json at
# 4.5.6, a CHANGELOG topped by ## 4.5.6, and one fragment not yet bumped,
# changelog.d/7.md; checked out on a pr branch made from main.
fragment_fixture() {
  local f
  f="$(changelog_fixture 4.5.6 '# Changelog' '' '## 4.5.6' '' 'Old.' '' '## 4.5.5' '' 'Older.')"
  mkdir "$f/changelog.d"
  printf '%s\n' 'bump: patch' '' 'Merged, not yet bumped.' >"$f/changelog.d/7.md"
  git -C "$f" init -q -b main
  fragment_commit "$f"
  git -C "$f" checkout -q -b pr
  echo "$f"
}
# fragment_commit <fixture>: commits every change in it.
fragment_commit() {
  git -C "$1" add -A
  git -C "$1" -c user.name=lint -c user.email=lint@example.com -c commit.gpgsign=false \
    commit -q -m change
}
# fixture_sed <file> <sed expression>: edits <file> in place, portably.
fixture_sed() {
  sed -i.bak "$2" "$1" && rm "$1.bak"
}
# fragment_add <fixture> <name> <lines...>: writes changelog.d/<name>, one
# line per argument, and commits it.
fragment_add() {
  local f="$1" name="$2"
  shift 2
  printf '%s\n' "$@" >"$f/changelog.d/$name"
  fragment_commit "$f"
}
# The fixtures' issues have no parent unless a test fakes one: the fake
# stands in for issue_parent_url for every fixture self-test, and the real
# lookup is put back before the real root's check.
real_issue_parent_url="$(declare -f issue_parent_url)"
issue_parent_url() { :; }
fixture="$(fragment_fixture)"
fragment_add "$fixture" 12.md 'bump: minor' '' 'A new feature.'
spares "one well-formed new fragment is not flagged" \
  "$(scan_changelog_fragments "$fixture" main)" '.'
fixture="$(fragment_fixture)"
printf 'More.\n' >>"$fixture/CHANGELOG.md"
fragment_commit "$fixture"
flags "a PR with no new fragment is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/: no changelog fragment added"
fixture="$(fragment_fixture)"
fragment_add "$fixture" 12.md 'bump: minor' '' 'A new feature.'
fragment_add "$fixture" 13.md 'bump: patch' '' 'A fix.'
flags "a PR adding two fragments is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/: 2 changelog fragments added"
fixture="$(fragment_fixture)"
fragment_add "$fixture" 12.md 'bump: big' '' 'A new feature.'
flags "a fragment with an unknown bump level is flagged, naming it" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/12.md: its first line is not"
fixture="$(fragment_fixture)"
fragment_add "$fixture" 12.md 'bump: patch'
flags "a fragment with no prose is flagged, naming it" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/12.md: it has no prose"
fixture="$(fragment_fixture)"
fragment_add "$fixture" fix-12.md 'bump: patch' '' 'A fix.'
flags "a misnamed fragment is flagged, naming it" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/fix-12.md: not named <issue>.md"
fixture="$(fragment_fixture)"
fixture_sed "$fixture/.claude-plugin/plugin.json" 's/4\.5\.6/4.5.7/'
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "a changed plugin.json version is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" ".claude-plugin/plugin.json: version changed from 4.5.6 to 4.5.7"
fixture="$(fragment_fixture)"
fixture_sed "$fixture/CHANGELOG.md" 's/^## 4\.5\.6$/## 4.5.7\n\nNew.\n\n## 4.5.6/'
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "an added ## CHANGELOG heading is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "CHANGELOG.md: ## 4.5.7 added"
fixture="$(fragment_fixture)"
printf '\n## 4.5.5\n\nAgain.\n' >>"$fixture/CHANGELOG.md"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "a second copy of an existing ## CHANGELOG heading is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "CHANGELOG.md: ## 4.5.5 added"
fixture="$(fragment_fixture)"
fixture_sed "$fixture/CHANGELOG.md" 's/^Older\.$/Older, reworded./'
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
spares "an edit to an older CHANGELOG entry is not flagged" \
  "$(scan_changelog_fragments "$fixture" main)" '.'
fixture="$(fragment_fixture)"
printf 'Reworded.\n' >>"$fixture/changelog.d/7.md"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "an existing fragment modified is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/7.md: an existing fragment is modified"
fixture="$(fragment_fixture)"
rm "$fixture/changelog.d/7.md"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "an existing fragment deleted is flagged" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/7.md: an existing fragment is deleted"
fixture="$(fragment_fixture)"
printf 'More.\n' >>"$fixture/CHANGELOG.md"
fragment_commit "$fixture"
spares "with NO_VERSION_BUMP, a PR with no fragment is not flagged" \
  "$(scan_changelog_fragments "$fixture" main 1)" '.'
fixture="$(fragment_fixture)"
fixture_sed "$fixture/.claude-plugin/plugin.json" 's/4\.5\.6/4.5.7/'
fragment_commit "$fixture"
flags "with NO_VERSION_BUMP, a changed plugin.json version is still flagged" \
  "$(scan_changelog_fragments "$fixture" main 1)" ".claude-plugin/plugin.json: version changed from 4.5.6 to 4.5.7"
flags "a base with no merge-base is flagged, naming it" \
  "$(scan_changelog_fragments "$fixture" no-such-ref)" "CHANGELOG_BASE: no merge-base with HEAD for 'no-such-ref'"
# gitkeep_fixture: fragment_fixture with changelog.d/.gitkeep already on main.
gitkeep_fixture() {
  local f
  f="$(fragment_fixture)"
  git -C "$f" checkout -q main
  : >"$f/changelog.d/.gitkeep"
  fragment_commit "$f"
  git -C "$f" checkout -q -B pr
  echo "$f"
}
fixture="$(fragment_fixture)"
: >"$fixture/changelog.d/.gitkeep"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
spares "an added .gitkeep beside one well-formed fragment is not flagged" \
  "$(scan_changelog_fragments "$fixture" main)" '.'
fixture="$(gitkeep_fixture)"
rm "$fixture/changelog.d/.gitkeep"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "a deleted .gitkeep is flagged with its own message" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/.gitkeep: deleted; version-bump.sh keeps it"
fixture="$(gitkeep_fixture)"
echo kept >"$fixture/changelog.d/.gitkeep"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "a modified .gitkeep is flagged with its own message" \
  "$(scan_changelog_fragments "$fixture" main)" "changelog.d/.gitkeep: modified; version-bump.sh keeps it"
fixture="$(fragment_fixture)"
fragment_add "$fixture" 12.md 'bump: patch' '' 'A fix.'
flags "a fragment named for a sub-issue is flagged, naming its parent" \
  "$(issue_parent_url() { echo "https://api.github.com/repos/o/r/issues/10"; }
    scan_changelog_fragments "$fixture" main)" \
  "changelog.d/12.md: #12 is a sub-issue of #10; name the fragment for the PR's issue, never a ticket"
spares "a fragment named for an issue with no parent is not flagged" \
  "$(issue_parent_url() { echo ""; }; scan_changelog_fragments "$fixture" main)" '.'
flags "a failed parent lookup is flagged" \
  "$(issue_parent_url() { return 1; }; scan_changelog_fragments "$fixture" main)" \
  "changelog.d/12.md: looking up #12's parent issue failed"
spares "with NO_VERSION_BUMP, no parent lookup runs" \
  "$(issue_parent_url() { echo "lookup ran"; return 1; }; scan_changelog_fragments "$fixture" main 1)" '.'
eval "$real_issue_parent_url"
if [ -n "${CHANGELOG_BASE+set}" ]; then
  check "the PR adds one changelog fragment and bumps nothing by hand" \
    "$(scan_changelog_fragments "$PLUGIN_ROOT" "$CHANGELOG_BASE" "${NO_VERSION_BUMP:-}")"
else
  ok "the changelog fragment rule skipped (CHANGELOG_BASE unset)"
fi

# >>> summary
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
