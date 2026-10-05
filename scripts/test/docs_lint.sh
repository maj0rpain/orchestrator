#!/usr/bin/env bash
#
# Docs linter: named structural rules over the plugin's skills, agents,
# commands and docs.
#
# Each rule is a scan_* function that takes a plugin root and prints one line
# per problem, "<file>: <problem>", and nothing when the root obeys it. Each
# rule runs first against fixture plugin roots that break it, so a rule that
# stops flagging anything fails here too, then once against the real plugin root.
# The linter checks structure only: it never runs orch.sh and holds no flow
# state.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

# flat_text [file]: the file, or stdin when given none, on one line with
# every whitespace run collapsed to one space.
flat_text() { tr -s ' \t\n' '   ' <"${1:-/dev/stdin}"; }

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

FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT
# new_fixture: an empty fixture plugin root, removed on exit.
new_fixture() { mktemp -d "$FIXTURES/root.XXXXXX"; }

echo "docs lint"

# --- markdown section reader -------------------------------------------------
echo
echo "markdown section reader"
f="$(new_fixture)"
printf '%s\n' '# Doc' '' '## Brief  ' '' 'Body.' '' '### Detail' '' 'Deeper.' '' '## Next' '' 'Other.' \
  '' '## Empty' '# Top' >"$f/doc.md"
assert_eq "md_section prints the body up to the next same-level heading, deeper subheadings kept" \
  "$(md_section "$f/doc.md" "## Brief")" "$(printf '\nBody.\n\n### Detail\n\nDeeper.\n')"
assert_eq "md_section stops at a higher-level heading" \
  "$(md_section "$f/doc.md" "## Empty"; echo "exit $?")" "exit 0"
assert_eq "md_section exits 1 on a missing heading" \
  "$(md_section "$f/doc.md" "## Missing"; echo "exit $?")" "exit 1"
assert_eq "md_section matches the heading line exactly" \
  "$(md_section "$f/doc.md" "## Brie"; echo "exit $?")" "exit 1"

# --- skill names (ADR-0014) --------------------------------------------------
# Every orchestrator skill carries the orch- prefix. An old unprefixed name
# left in a skill, command, hook, or doc points a model at a skill that no
# longer exists. CHANGELOG, ADRs, and .out-of-scope/ record history and may
# name the old ones; scripts/test/ feeds old names in deliberately as negative
# cases. The spec review's command and skill were renamed spec-review in 2.0.0
# (#235), so the review-spec names, command included, are old names too.
# /orchestrator:review is a live command again (#341), so only the review
# skill's directory and name line remain old names. The planning entry point
# was renamed interview in 3.0.0 (#373), so orch-plan, under any prefix, and
# the command orchestrator:plan are old names too, each matched as a whole
# token: .scratch/orch-plan-<slug>.md names a saved plan, not the skill.
echo
echo "skill names (ADR-0014)"
old_names='orchestrator:(flow|handoff|review-spec|quick-implement|orch-review-spec)([^a-z-]|$)|skills/(flow|handoff|review|review-spec|quick-implement|orch-review-spec)/|^name: (flow|handoff|review|review-spec|quick-implement|orch-review-spec)$|(^|[^a-z-])(orch-plan|orchestrator:plan)([^a-z-]|$)'
# scan_old_names <plugin root>: each old skill or command name in a tracked
# file outside history, and each old command file or skill directory.
scan_old_names() {
  local r="$1"
  git -C "$r" ls-files -z \
    | grep -zvE '^(CHANGELOG\.md|docs/adr/|scripts/test/|\.out-of-scope/)' \
    | (cd "$r" && xargs -0 grep -nE "$old_names" 2>/dev/null) \
    | sed -E 's/^([^:]*:[0-9]+):/\1: old skill or command name: /'
  local p
  for p in commands/review-spec.md commands/plan.md; do
    [ -e "$r/$p" ] && echo "$p: old command file"
  done
  for p in skills/orch-review-spec skills/orch-plan; do
    [ -e "$r/$p" ] && echo "$p/: old skill directory"
  done
  return 0
}
f="$(new_fixture)"
git -C "$f" init -q
mkdir -p "$f/skills/orch-spec-review" "$f/commands" "$f/docs/adr"
printf 'Call `orchestrator:review-spec`.\n' >"$f/commands/a.md"
printf 'Run `/orchestrator:review-spec 12`.\n' >"$f/commands/b.md"
printf 'Call `orchestrator:orch-review-spec`.\n' >"$f/commands/c.md"
printf 'See skills/orch-review-spec/SKILL.md.\n' >"$f/commands/d.md"
printf 'name: orch-review-spec\n' >"$f/commands/e.md"
printf 'Run `/orchestrator:spec-review 12`.\nCall `orchestrator:orch-spec-review`.\nskills/orch-spec-review/\n' >"$f/commands/new.md"
printf -- '---\nname: orch-spec-review\n---\n' >"$f/skills/orch-spec-review/SKILL.md"
printf 'Renamed `orchestrator:review-spec`.\n' >"$f/docs/adr/0001-x.md"
# /orchestrator:review is a live command again (#341), routed to orch-review's
# Standalone review pass; the old review skill's directory and name stay old.
printf 'Run `/orchestrator:review 12`.\nCall `orchestrator:review`.\n' >"$f/commands/review.md"
printf 'See skills/review/SKILL.md.\n' >"$f/commands/f.md"
printf 'name: review\n' >"$f/commands/g.md"
# The planning entry point was renamed interview (#373).
printf 'Call `orchestrator:orch-plan`.\n' >"$f/commands/p1.md"
printf 'Run `$orch-plan`.\n' >"$f/commands/p2.md"
printf 'Run `/orch-plan`.\n' >"$f/commands/p3.md"
printf 'A hook on `Skill(orch-plan)`.\n' >"$f/commands/p4.md"
printf 'While planning (orch-plan, grilling)\n' >"$f/commands/p5.md"
printf 'Run `/orchestrator:plan`.\n' >"$f/commands/p6.md"
printf 'See skills/orch-plan/SKILL.md.\n' >"$f/commands/p7.md"
printf 'name: orch-plan\n' >"$f/commands/p8.md"
printf 'Run `/orchestrator:interview`.\nCall `orchestrator:orch-interview`.\nskills/orch-interview/\n$orch-interview\n' >"$f/commands/interview.md"
printf 'Save it to `.scratch/orch-plan-<slug>.md`.\n' >"$f/commands/scratch.md"
git -C "$f" add -A
out="$(scan_old_names "$f")"
flags "the old review-spec skill name is flagged" "$out" "commands/a.md:1: old skill or command name"
flags "the old /orchestrator:review-spec command is flagged" "$out" "commands/b.md:1: old skill or command name"
flags "the old orch-review-spec skill name is flagged" "$out" "commands/c.md:1: old skill or command name"
flags "the old orch-review-spec skill directory is flagged" "$out" "commands/d.md:1: old skill or command name"
flags "the old orch-review-spec skill name line is flagged" "$out" "commands/e.md:1: old skill or command name"
assert_eq "the new spec-review names are not flagged" \
  "$(printf '%s\n' "$out" | grep -cE '^(commands/new\.md|skills/)')" "0"
assert_eq "the live /orchestrator:review command is not flagged" \
  "$(printf '%s\n' "$out" | grep -c '^commands/review\.md')" "0"
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
assert_eq "the new interview names are not flagged" \
  "$(printf '%s\n' "$out" | grep -c '^commands/interview\.md')" "0"
assert_eq "the saved-plan scratch file is not flagged" \
  "$(printf '%s\n' "$out" | grep -c '^commands/scratch\.md')" "0"
assert_eq "history may name the old ones" \
  "$(printf '%s\n' "$out" | grep -c '^docs/adr/')" "0"
mkdir -p "$f/skills/orch-review-spec"
: >"$f/commands/review-spec.md"
mkdir -p "$f/skills/orch-plan"
: >"$f/commands/plan.md"
out="$(scan_old_names "$f")"
flags "an old review-spec command file is flagged" "$out" "commands/review-spec.md: old command file"
flags "an old orch-review-spec skill directory is flagged" "$out" "skills/orch-review-spec/: old skill directory"
flags "an old plan command file is flagged" "$out" "commands/plan.md: old command file"
flags "an old orch-plan skill directory is flagged" "$out" "skills/orch-plan/: old skill directory"
check "no old orchestrator skill or command name outside history" "$(scan_old_names "$PLUGIN_ROOT")"

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
f="$(new_fixture)"
mkdir -p "$f/skills/flow" "$f/skills/orch-x" "$f/skills/orch-ok"
printf -- '---\nname: flow\n---\n' >"$f/skills/flow/SKILL.md"
printf -- '---\nname: orch-y\n---\n' >"$f/skills/orch-x/SKILL.md"
printf -- '---\nname: orch-ok\n---\n' >"$f/skills/orch-ok/SKILL.md"
out="$(scan_skill_names "$f")"
flags "an unprefixed skill directory is flagged" "$out" "skills/flow/: no orch- prefix"
flags "a skill whose name: is not its directory is flagged" "$out" "skills/orch-x/SKILL.md: name: is 'orch-y', not its directory"
assert_eq "a prefixed skill named for its directory is not flagged" \
  "$(printf '%s\n' "$out" | grep -c 'orch-ok')" "0"
check "every skill directory carries the orch- prefix and declares its name" "$(scan_skill_names "$PLUGIN_ROOT")"

# --- orch.sh resolution (#123) ------------------------------------------------
# Only Claude Code expands CLAUDE_PLUGIN_ROOT, and only in hooks/hooks.json on
# other hosts, so skill and command text must pair it with the
# relative fallback. The one documented form (README, "Resolving orch.sh") is
# the ORCH= line, the Junie step, and the fallback sentence; any other mention
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
orch_steps="$orch_junie (the Junie CLI install). $orch_junie_one $orch_junie_many $orch_fallback"
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
f="$(new_fixture)"
mkdir -p "$f/commands"
printf 'Run `${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh status`.\n' >"$f/commands/orch.md"
flags "the scan covers commands/ and flags a bare CLAUDE_PLUGIN_ROOT" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: CLAUDE_PLUGIN_ROOT outside"
printf '%s\n' '```' "$orch_line" '```' \
  'If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh` two directories above this skill.' \
  >"$f/commands/orch.md"
flags "the scan flags orch.sh resolved without the Junie step" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: uses orch.sh without the Junie step"
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
documented_orch_form "$orch_junie_one" >"$f/commands/orch.md"
flags "the scan flags a Junie step with no one-install step" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: uses orch.sh without the one-install step"
documented_orch_form "$orch_junie_many" >"$f/commands/orch.md"
flags "the scan flags a Junie step with no stop on several installs" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: uses orch.sh without the stop on several Junie installs"
{ documented_orch_form "$orch_junie_one"; printf '%s\n' "$orch_junie_one"; } >"$f/commands/orch.md"
flags "the scan flags the Junie steps out of order" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: resolves orch.sh out of the documented order"
documented_orch_form >"$f/commands/orch.md"
assert_empty "the scan accepts the documented form" "$(scan_orch_resolution "$f")"
printf '%s\n' '```' 'sed -n 1p "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"' '```' \
  >"$f/commands/orch.md"
flags "the scan flags a plugin-root path with no unset fallback" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: CLAUDE_PLUGIN_ROOT outside"
printf '%s\n' '```' 'sed -n 1p "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"' '```' \
  "$root_fallback two directories above this skill's own directory." >"$f/commands/orch.md"
flags "the scan flags a plugin-root fallback with no Junie step" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: names the plugin root without the Junie step"
printf '%s\n' '```' 'sed -n 1p "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"' '```' \
  "$root_fallback two directories above this skill's own directory." \
  "Elsewhere, $root_junie." >"$f/commands/orch.md"
flags "the scan flags a Junie step outside the plugin-root sentence" \
  "$(scan_orch_resolution "$f")" "commands/orch.md: names the plugin root without the Junie step"
{ documented_orch_form
  printf '%s\n' '```' 'sed -n 1p "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"' '```' \
    "$root_fallback found as for \`ORCH\`:" \
    "$root_junie, else two directories above this skill's own directory."
} >"$f/commands/orch.md"
assert_empty "the scan accepts a plugin-root path with its unset fallback" \
  "$(scan_orch_resolution "$f")"
check "every skill and command resolves orch.sh the one documented way" \
  "$(scan_orch_resolution "$PLUGIN_ROOT")"

# Some hosts drop the execute bit on install or update, so orch.sh is always
# run through bash, quoted or not (#142; docs/host-capabilities.md, "Execute bit").
# scan_orch_bash <plugin root>: print one line per call site that skips bash.
scan_orch_bash() {
  local r="$1" f
  for f in "$r"/skills/*/SKILL.md "$r"/commands/*.md \
           "$r"/README.md "$r"/docs/host-capabilities.md; do
    [ -f "$f" ] || continue
    sed 's/bash "\$ORCH"//g' "$f" | grep -nE '\$\{?ORCH\b' \
      | sed -E "s|^([0-9]+):|${f#"$r"/}:\\1: runs orch.sh without bash: |"
  done
}
f="$(new_fixture)"
mkdir -p "$f/skills/orch-x" "$f/docs"
printf 'Run `bash "$ORCH" status`.\nRun `"$ORCH" doctor`.\n' >"$f/skills/orch-x/SKILL.md"
printf 'Run `${ORCH} status`.\n' >"$f/README.md"
out="$(scan_orch_bash "$f")"
flags "the scan flags a quoted \$ORCH run without bash" "$out" "skills/orch-x/SKILL.md:2: runs orch.sh without bash"
flags "the scan flags \${ORCH} run without bash" "$out" "README.md:1: runs orch.sh without bash"
assert_eq "the scan accepts bash \"\$ORCH\"" "$(printf '%s\n' "$out" | grep -c 'SKILL.md:1:')" "0"
check "every skill and doc runs orch.sh through bash" "$(scan_orch_bash "$PLUGIN_ROOT")"

# A skill's commands name the plugin root through CLAUDE_PLUGIN_ROOT, never a
# "<plugin root>" placeholder the driver must work out for itself (#155).
# scan_plugin_root_placeholder <plugin root>: each <plugin root>/ placeholder.
scan_plugin_root_placeholder() {
  local r="$1" f
  for f in "$r"/skills/*/SKILL.md "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -nF '<plugin root>/' "$f" \
      | sed -E "s|^([0-9]+):.*|${f#"$r"/}:\\1: <plugin root>/ placeholder|"
  done
}
f="$(new_fixture)"
mkdir -p "$f/skills/orch-x" "$f/commands"
printf 'Read `<plugin root>/agents/orch-fixer.md`.\n' >"$f/skills/orch-x/SKILL.md"
printf 'Run `<plugin root>/scripts/orch.sh`.\n' >"$f/commands/x.md"
out="$(scan_plugin_root_placeholder "$f")"
flags "the scan flags a <plugin root> placeholder in a skill" "$out" "skills/orch-x/SKILL.md:1: <plugin root>/ placeholder"
flags "the scan flags a <plugin root> placeholder in a command" "$out" "commands/x.md:1: <plugin root>/ placeholder"
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
f="$(new_fixture)"
mkdir -p "$f/skills/orch-flow" "$f/skills/orch-same" "$f/skills/orch-drift" "$f/skills/orch-none"
stop='If `orch.sh` is at none of these paths, stop: this is a skills-only install. Install the full plugin (or as a Junie extension, which is unverified).'
printf '%s\n' "$stop" >"$f/skills/orch-flow/SKILL.md"
printf '%s\n' "$stop" >"$f/skills/orch-same/SKILL.md"
printf '%s\n' "${stop/the full plugin/it all}" >"$f/skills/orch-drift/SKILL.md"
printf 'No stop text here.\n' >"$f/skills/orch-none/SKILL.md"
out="$(scan_stop_text "$f")"
flags "the scan flags stop text that drifts from orch-flow's" "$out" "skills/orch-drift/SKILL.md: skills-only stop text differs from orch-flow's"
flags "the scan flags a skill with no stop text" "$out" "skills/orch-none/SKILL.md: skills-only stop text differs from orch-flow's"
assert_eq "the scan accepts a word-for-word copy" "$(printf '%s\n' "$out" | grep -c 'orch-same')" "0"
printf 'No stop text here.\n' >"$f/skills/orch-flow/SKILL.md"
flags "the scan flags orch-flow with no stop text to match" \
  "$(scan_stop_text "$f")" "skills/orch-flow/SKILL.md: carries no skills-only stop text"
# The rule is a copy-match only (ADR-0027): a stop text worded any other way
# between its anchor lines passes, so long as every copy matches orch-flow's.
f="$(new_fixture)"
mkdir -p "$f/skills/orch-flow" "$f/skills/orch-same"
stop='If `orch.sh` is at none of these paths, stop and install it whole (the Junie route, which is unverified).'
printf '%s\n' "$stop" >"$f/skills/orch-flow/SKILL.md"
printf '%s\n' "$stop" >"$f/skills/orch-same/SKILL.md"
assert_empty "the scan accepts any wording between the anchors, copied word for word" "$(scan_stop_text "$f")"
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
f="$(new_fixture)"
mkdir -p "$f/agents" "$f/docs/junie"
printf -- '---\nname: orch-named\n---\n' >"$f/agents/orch-named.md"
printf -- '---\nname: orch-extra\n---\n' >"$f/agents/orch-extra.md"
printf 'Start `orch-named` by name.\n' >"$f/docs/junie/AGENTS.md"
out="$(scan_junie_snippet_drift "$f")"
flags "the drift check flags an agent the snippet omits" "$out" "agents/orch-extra.md: not named in docs/junie/AGENTS.md"
assert_eq "the drift check accepts an agent the snippet names" \
  "$(printf '%s\n' "$out" | grep -c 'orch-named')" "0"
check "the Junie snippet names every agent" "$(scan_junie_snippet_drift "$PLUGIN_ROOT")"

# --- host capabilities (#127) -------------------------------------------------
echo
echo "host capabilities (#127)"
# Skills describe capabilities and point at one reference that maps each
# capability to each host, so a host without Claude Code's tools can still
# follow them. Commands are Claude-only shortcuts and hold no behaviour of
# their own: each routes to an orch- skill, or a section of one, that exists.
# scan_capabilities <plugin root>: print one line per offending skill, agent,
# or command. An agent brief names host capabilities as a skill does (#157);
# only one that invokes a mattpocock-skills skill must point at the reference,
# since the others name no capability a host could lack.
scan_capabilities() {
  local r="$1" f route skill section body cmd
  for f in "$r"/skills/*/SKILL.md "$r"/agents/*.md; do
    [ -f "$f" ] || continue
    if [[ "$f" != "$r"/agents/* ]] || grep -qE 'mattpocock-skills:[a-z]' "$f"; then
      grep -qF 'docs/host-capabilities.md' "$f" \
        || echo "${f#"$r"/}: never points at docs/host-capabilities.md"
    fi
    # Junie has no plugin scope, so a skill names its siblings bare (orch-flow);
    # the Claude-scoped form is only ever the generic orchestrator:<name>.
    grep -nE 'orchestrator:orch-' "$f" \
      | sed "s|^|${f#"$r"/}: names a skill by its Claude-scoped name: |"
    # A plugin command offered must exist: its commands/<cmd>.md is the route
    # the command scan below checks reaches a skill section.
    for cmd in $(grep -oE '/orchestrator:[a-z][a-z-]*' "$f" | sed 's|^/orchestrator:||' | sort -u); do
      [ -f "$r/commands/$cmd.md" ] \
        || echo "${f#"$r"/}: offers /orchestrator:$cmd, which has no commands/$cmd.md"
    done
  done
  for f in "$r"/commands/*.md; do
    [ -f "$f" ] || continue
    grep -qE 'orch\.sh|\$ORCH' "$f" && echo "${f#"$r"/}: runs orch.sh itself"
    # A command routes to an orch- skill and follows either one of its
    # sections (the flow steps, spec-review) or the whole skill (release,
    # #139). The skill must exist, and so must a section it names. The route
    # may wrap across lines, so the file is read as one line.
    body="$(flat_text "$f")"
    route="$(grep -oE '`orchestrator:orch-[a-z-]+` and follow it(s \*\*[^*]+\*\* section|\.)' <<<"$body" | head -n1)"
    section="$(sed -n 's/.*follow its \*\*\([^*]*\)\*\* section$/\1/p' <<<"$route")"
    skill="$(sed 's/^`orchestrator://; s/`.*//' <<<"$route")"
    if [ -z "$skill" ]; then echo "${f#"$r"/}: routes to no orch- skill"
    elif [ ! -f "$r/skills/$skill/SKILL.md" ]; then echo "${f#"$r"/}: routes to a missing skill: $skill"
    elif [ -n "$section" ]; then grep -qxF "## $section" "$r/skills/$skill/SKILL.md" \
      || echo "${f#"$r"/}: routes to a missing $skill section: $section"; fi
  done
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/skills/orch-x" "$f/skills/orch-flow" "$f/commands"
printf '## Status\nSee docs/host-capabilities.md.\n' >"$f/skills/orch-flow/SKILL.md"
printf 'Invoke the skill `x`. See docs/host-capabilities.md.\n' >"$f/skills/orch-x/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Doctor** section.\n' >"$f/commands/doctor.md"
flags "the scan flags a command routed to a missing section" \
  "$(scan_capabilities "$f")" "commands/doctor.md: routes to a missing orch-flow section: Doctor"
printf '## Status\nInvoke `orchestrator:orch-handoff`. See docs/host-capabilities.md.\n' >"$f/skills/orch-flow/SKILL.md"
flags "the scan flags a sibling skill named by its Claude scope" \
  "$(scan_capabilities "$f")" "skills/orch-flow/SKILL.md: names a skill by its Claude-scoped name"
printf '## Status\nInvoke the `orch-handoff` skill (`orchestrator:<name>` on Claude Code). See docs/host-capabilities.md.\n' >"$f/skills/orch-flow/SKILL.md"
printf 'Invoke the skill `x`.\n' >"$f/skills/orch-x/SKILL.md"
flags "the scan flags a skill that never points at the reference" \
  "$(scan_capabilities "$f")" "skills/orch-x/SKILL.md: never points at docs/host-capabilities.md"
printf 'Invoke the skill `x` (see docs/host-capabilities.md).\n' >"$f/skills/orch-x/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Status** section.\n' >"$f/commands/doctor.md"
printf '%s\n' "$orch_line" >"$f/commands/status.md"
flags "the scan flags a command that runs orch.sh itself" \
  "$(scan_capabilities "$f")" "commands/status.md: runs orch.sh itself"
printf 'Do the thing.\n' >"$f/commands/status.md"
flags "the scan flags a command that routes to no skill" \
  "$(scan_capabilities "$f")" "commands/status.md: routes to no orch- skill"
rm "$f/commands/status.md"
printf 'Invoke `orchestrator:orch-y` and follow it.\n' >"$f/commands/y.md"
flags "the scan flags a command routed to a missing skill" \
  "$(scan_capabilities "$f")" "commands/y.md: routes to a missing skill: orch-y"
mkdir -p "$f/skills/orch-y"
printf 'Invoke the skill `x` (see docs/host-capabilities.md).\n' >"$f/skills/orch-y/SKILL.md"
assert_empty "the scan accepts capability phrasing and a thin route" "$(scan_capabilities "$f")"
# A command may route to a named section of a skill other than orch-flow
# (spec-review, #185) - that section must exist in that skill.
printf 'Invoke `orchestrator:orch-y` and follow its **Solo run**\nsection.\n' >"$f/commands/y.md"
flags "the scan flags a command routed to a missing section of its own skill" \
  "$(scan_capabilities "$f")" "commands/y.md: routes to a missing orch-y section: Solo run"
printf '## Solo run\nInvoke the skill `x` (see docs/host-capabilities.md).\n' >"$f/skills/orch-y/SKILL.md"
assert_empty "the scan accepts a command routed to an existing section of its own skill" \
  "$(scan_capabilities "$f")"
# An agent brief names host capabilities the way a skill does (#157).
mkdir -p "$f/agents"
printf 'Fix it through the `mattpocock-skills:tdd` skill.\n' >"$f/agents/orch-z.md"
flags "the scan flags an agent that never points at the reference" \
  "$(scan_capabilities "$f")" "agents/orch-z.md: never points at docs/host-capabilities.md"
printf 'Fix it through the `mattpocock-skills:tdd` skill (see docs/host-capabilities.md).\n' >"$f/agents/orch-z.md"
assert_empty "the scan accepts an agent that points at the reference" "$(scan_capabilities "$f")"
printf 'Read the diff and write the report.\n' >"$f/agents/orch-z.md"
assert_empty "the scan accepts an agent that invokes no skill without the pointer" "$(scan_capabilities "$f")"
# A plugin command a skill or agent offers must route somewhere: it needs its
# own commands/<cmd>.md, whose route the command scan above checks.
f="$(new_fixture)"
mkdir -p "$f/skills/orch-x" "$f/agents" "$f/commands"
printf 'Offer `/orchestrator:abort`. See docs/host-capabilities.md.\n' >"$f/skills/orch-x/SKILL.md"
printf 'Offer `/orchestrator:nope 12`.\n' >"$f/agents/orch-z.md"
out="$(scan_capabilities "$f")"
flags "the scan flags a skill offering a plugin command with no command file" "$out" "skills/orch-x/SKILL.md: offers /orchestrator:abort, which has no commands/abort.md"
flags "the scan flags an agent offering a plugin command with no command file" "$out" "agents/orch-z.md: offers /orchestrator:nope, which has no commands/nope.md"
mkdir -p "$f/skills/orch-flow"
printf '## Abort\nSee docs/host-capabilities.md.\n' >"$f/skills/orch-flow/SKILL.md"
printf 'Invoke `orchestrator:orch-flow` and follow its **Abort** section.\n' >"$f/commands/abort.md"
cp "$f/commands/abort.md" "$f/commands/nope.md"
assert_empty "the scan accepts plugin commands that each have a command file" "$(scan_capabilities "$f")"
check "every skill points at the reference, and every command is a thin route" \
  "$(scan_capabilities "$PLUGIN_ROOT")"

# --- one definition of starting a plugin agent (#181) -------------------------
echo
echo "one definition of starting a plugin agent (#181)"
# The host fallback for starting a plugin agent lives once, in
# docs/host-capabilities.md, and orch-implementer's dispatch contract (prompt
# shape, five report lines) lives once too, in agents/orch-implementer.md - so
# a change to either is made at one site, not copied into every skill that
# starts an agent.
# scan_dispatch_copies <plugin root>: print one line per restated copy.
scan_dispatch_copies() {
  local r="$1" f
  for f in "$r"/skills/*/SKILL.md; do
    [ -f "$f" ] || continue
    # The contract's one copy is the agent file, so any skill carrying all
    # five report lines is a second copy.
    if grep -qF '`Ticket`' "$f" && grep -qF '`Commits`' "$f" && grep -qF '`Verification`' "$f" \
       && grep -qF '`Criteria`' "$f" && grep -qF '`Deviation`' "$f"; then
      echo "${f#"$r"/}: restates the implementer's five report lines"
    fi
    # The general-purpose-agent tier: a general-purpose agent briefed with a
    # plugin agent's file. A general-purpose agent named with no agent file
    # is not the tier and is left alone.
    awk -v f="${f#"$r"/}" 'BEGIN { RS = "" }
      /general-purpose/ && (/agents\// || /agent'"'"'s file/) { print f ": restates the general-purpose-agent tier" }' "$f"
  done
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/skills/a" "$f/skills/b"
printf 'Returns `Ticket`, `Commits`, `Verification`, `Criteria`, `Deviation`.\n' >"$f/skills/a/SKILL.md"
printf 'Else start a fresh general-purpose agent\nbriefed with its file under `agents/`.\n' >"$f/skills/b/SKILL.md"
out="$(scan_dispatch_copies "$f")"
flags "the scan flags the report lines copied into a skill" \
  "$out" "skills/a/SKILL.md: restates the implementer's five report lines"
flags "the scan flags a skill restating the general-purpose-agent tier" \
  "$out" "skills/b/SKILL.md: restates the general-purpose-agent tier"
printf 'Start the implementer as its agent file says.\n' >"$f/skills/a/SKILL.md"
printf 'Summarise the log with a fresh general-purpose agent.\n' >"$f/skills/b/SKILL.md"
assert_empty "the scan accepts a pointer and a general-purpose agent with no agent file" \
  "$(scan_dispatch_copies "$f")"
check "the host fallback and the implementer's report are each stated once" \
  "$(scan_dispatch_copies "$PLUGIN_ROOT")"

# --- spec-review lenses run as plugin agents (#177) ---------------------------
echo
echo "spec-review lenses run as plugin agents (#177)"
# Each lens owns its brief as a read-only plugin agent, the way the review
# loop's reviewers own theirs (ADR-0018), so orch-spec-review carries only the
# lens-to-agent table, and the host fallback runs a lens from its agent file.
# scan_lens_briefs <plugin root>: print one line per brief out of place. The
# briefs' one copy is each lens agent's `## Brief` section, so the check is on
# structure, never on the briefs' wording: every lens agent has a non-empty
# `## Brief`, and orch-spec-review has no `**<Lens> brief.**` heading.
lenses="fidelity consistency testability implementability"
scan_lens_briefs() {
  local r="$1" lens a heading brief
  for lens in $lenses; do
    a="$r/agents/orch-lens-$lens.md"
    if [ -f "$a" ]; then
      if ! brief="$(md_section "$a" "## Brief")"; then
        echo "${a#"$r"/}: has no ## Brief section"
      elif ! grep -q '[^[:space:]]' <<<"$brief"; then
        echo "${a#"$r"/}: has an empty ## Brief section"
      fi
    fi
    heading="**${lens^} brief.**"
    grep -qF "$heading" "$r/skills/orch-spec-review/SKILL.md" 2>/dev/null &&
      echo "skills/orch-spec-review/SKILL.md: carries the $heading heading"
  done
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/agents" "$f/skills/orch-spec-review"
printf -- '---\nname: orch-lens-fidelity\n---\n\n## Brief\n\n## Reporting rules\n\n- Under 400 words.\n' \
  >"$f/agents/orch-lens-fidelity.md"
printf -- '---\nname: orch-lens-consistency\n---\n\n# Consistency lens\n\nReport.\n' \
  >"$f/agents/orch-lens-consistency.md"
printf -- '---\nname: orch-lens-testability\n---\n\n## Brief\n\nReport seams.\n\n## Reporting rules\n' \
  >"$f/agents/orch-lens-testability.md"
printf 'Run the lenses.\n\n**Consistency brief.** Placeholder.\n' \
  >"$f/skills/orch-spec-review/SKILL.md"
out="$(scan_lens_briefs "$f")"
flags "the scan flags an empty ## Brief section" \
  "$out" "agents/orch-lens-fidelity.md: has an empty ## Brief section"
flags "the scan flags a lens agent with no ## Brief heading" \
  "$out" "agents/orch-lens-consistency.md: has no ## Brief section"
assert_eq "the scan accepts a brief with content" \
  "$(printf '%s\n' "$out" | grep -c 'orch-lens-testability')" "0"
flags "the scan flags a brief heading back in orch-spec-review" \
  "$out" "skills/orch-spec-review/SKILL.md: carries the **Consistency brief.** heading"
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
required_headings='skills/orch-quick-implement/SKILL.md|## 1. Require a linked issue
skills/orch-quick-implement/SKILL.md|## 2. Offer a spec review
skills/orch-quick-implement/SKILL.md|## 3. Publish the ticket breakdown
skills/orch-quick-implement/SKILL.md|## 6. Review
skills/orch-quick-implement/SKILL.md|## 7. Open the PR
skills/orch-review/SKILL.md|## Review pass
skills/orch-review/SKILL.md|## Standalone review pass
skills/orch-spec-review/SKILL.md|## Standalone spec review
skills/orch-spec-review/SKILL.md|## Disposition
skills/orch-spec-review/SKILL.md|## Applying the answer
skills/orch-spec-review/SKILL.md|## Tickets follow the spec
skills/orch-spec-review/SKILL.md|## The changelog'
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
f="$(new_fixture)"
mkdir -p "$f/skills/a" "$f/skills/b" "$f/skills/c"
printf '# A\n\n## One\n\ntext\n\n## Two\n' >"$f/skills/a/SKILL.md"
printf '# B\n\n## Two\n\n## One\n' >"$f/skills/b/SKILL.md"
printf '# C\n\n## One\n\n### Two\n' >"$f/skills/c/SKILL.md"
pairs='skills/a/SKILL.md|## One
skills/a/SKILL.md|## Two
skills/b/SKILL.md|## One
skills/b/SKILL.md|## Two
skills/c/SKILL.md|## One
skills/c/SKILL.md|## Two'
out="$(scan_required_headings "$f" "$pairs")"
flags "a required heading missing from its file is flagged" \
  "$out" "skills/c/SKILL.md: missing required heading: ## Two"
flags "required headings out of order are flagged" \
  "$out" "skills/b/SKILL.md: required heading out of order: ## Two"
assert_eq "required headings present and in order are not flagged" \
  "$(printf '%s\n' "$out" | grep -c '^skills/a/')" "0"
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
  (cd "$r" && grep -rnoE '`orch-[a-z0-9-]+`' skills agents commands docs README.md 2>/dev/null) \
    | while IFS= read -r hit; do
        file="${hit%%:*}"; hit="${hit#*:}"
        line="${hit%%:*}"; name="${hit#*:}"; name="${name//\`/}"
        case "$file" in docs/adr/*) continue ;; esac
        [ -d "$r/skills/$name" ] || [ -f "$r/agents/$name.md" ] ||
          echo "$file:$line: names no skill or agent: $name"
      done
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/skills/orch-real" "$f/agents" "$f/commands" "$f/docs/adr" "$f/docs/x"
printf -- '---\nname: orch-real\n---\nStart `orch-helper`, then `orch-ghost`.\n' >"$f/skills/orch-real/SKILL.md"
printf -- '---\nname: orch-helper\n---\nInvoke `orch-real`.\n' >"$f/agents/orch-helper.md"
printf 'Invoke `orch-phantom`.\n' >"$f/commands/c.md"
printf 'See `orch-lost`.\n' >"$f/docs/x/d.md"
printf 'Use `orch-missing`.\n' >"$f/README.md"
printf 'Renamed `orch-retired`.\n' >"$f/docs/adr/0001-x.md"
out="$(scan_orch_names "$f")"
flags "an orch- name in a skill that resolves to nothing is flagged" \
  "$out" "skills/orch-real/SKILL.md:4: names no skill or agent: orch-ghost"
flags "an orch- name in a command that resolves to nothing is flagged" \
  "$out" "commands/c.md:1: names no skill or agent: orch-phantom"
flags "an orch- name in docs that resolves to nothing is flagged" \
  "$out" "docs/x/d.md:1: names no skill or agent: orch-lost"
flags "an orch- name in the README that resolves to nothing is flagged" \
  "$out" "README.md:1: names no skill or agent: orch-missing"
assert_eq "orch- names of a skill or an agent are not flagged" \
  "$(printf '%s\n' "$out" | grep -cE 'orch-(real|helper)$')" "0"
assert_eq "ADRs may name an orch- name that no longer resolves" \
  "$(printf '%s\n' "$out" | grep -c 'orch-retired')" "0"
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
f="$(new_fixture)"
mkdir -p "$f/agents"
printf -- '---\nname: orch-implementer\ntools: [Read, Bash]\n---\n' >"$f/agents/orch-implementer.md"
printf -- '---\nname: orch-fixer\ntools: [Read, Bash]\n---\n' >"$f/agents/orch-fixer.md"
printf -- '---\nname: orch-closer\ntools: [Read]\n---\n' >"$f/agents/orch-closer.md"
printf -- '---\nname: orch-other\ntools: Read, Bash\n---\n' >"$f/agents/orch-a.md"
printf -- '---\nname: orch-b\n---\n' >"$f/agents/orch-b.md"
printf -- '---\nname: orch-c\ntools: [Read, Skill]\n---\n' >"$f/agents/orch-c.md"
out="$(scan_agent_frontmatter "$f")"
flags "an agent whose name: is not its file is flagged" \
  "$out" "agents/orch-a.md: name: is 'orch-other', not its file"
flags "an agent whose tools: is not a list is flagged" \
  "$out" "agents/orch-a.md: tools: is not a YAML flow list"
flags "an agent with no tools: is flagged" "$out" "agents/orch-b.md: declares no tools:"
flags "an agent listing Skill is flagged" "$out" "agents/orch-c.md: lists Skill"
flags "a closer whose allowlist is not the implementer's is flagged" \
  "$out" "agents/orch-closer.md: tools: is not the implementer's"
assert_eq "agents named for their files with a matching list are not flagged" \
  "$(printf '%s\n' "$out" | grep -cE 'orch-(implementer|fixer)\.md')" "0"
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
f="$(new_fixture)"
mkdir -p "$f/agents" "$f/skills/orch-x"
printf 'Run `gh api repos/o/r/issues/7/parent`.\n' >"$f/agents/orch-a.md"
printf 'Run `gh api repos/o/r/issues/7/sub_issues`.\n' >"$f/skills/orch-x/SKILL.md"
printf 'Run `bash "$ORCH" ticket parent 7`.\n' >"$f/agents/orch-b.md"
out="$(scan_subissue_endpoints "$f")"
flags "an agent calling the parent endpoint is flagged" "$out" "agents/orch-a.md:1: calls a sub-issue endpoint"
flags "a skill calling the sub_issues endpoint is flagged" "$out" "skills/orch-x/SKILL.md:1: calls a sub-issue endpoint"
assert_eq "ticket parent is not flagged" "$(printf '%s\n' "$out" | grep -c 'orch-b')" "0"
check "no agent or skill calls a sub-issue endpoint" "$(scan_subissue_endpoints "$PLUGIN_ROOT")"

# --- flow commands in script messages -----------------------------------------
echo
echo "flow commands in script messages"
# orch.sh's and doctor.sh's messages reach the model on every host, so they
# name a flow command only through flow_cmd, which adds the orch-flow section
# for a host with no plugin commands - and every section it names must exist.
# scan_flow_cmd <plugin root>: each script line naming a plugin command
# outside flow_cmd, and each flow_cmd section orch-flow lacks.
scan_flow_cmd() {
  local r="$1" s
  (cd "$r" && grep -nE '/orchestrator:[a-z]' scripts/orch.sh scripts/doctor.sh 2>/dev/null) \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' \
    | sed -E 's/^([^:]+:[0-9]+):.*/\1: names a plugin command outside flow_cmd/'
  # Not a section read: this range is a shell function body in orch.sh.
  awk '/^flow_cmd\(\)/,/^}/' "$r/scripts/orch.sh" 2>/dev/null \
    | grep -oE 'section="[^"]+"' | sed 's/section="//; s/"$//' \
    | while IFS= read -r s; do
        grep -qxF "## $s" "$r/skills/orch-flow/SKILL.md" 2>/dev/null ||
          echo "skills/orch-flow/SKILL.md: has no section flow_cmd names: $s"
      done
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/scripts" "$f/skills/orch-flow"
printf '%s\n' 'flow_cmd() {' '  case "$1" in' '    start) section="Starting a flow" ;;' \
  '    next)  section="Next phase" ;;' '  esac' '  printf "/orchestrator:%s" "$1"' '}' \
  '# /orchestrator:next in a comment is fine' 'die "run /orchestrator:abort"' >"$f/scripts/orch.sh"
printf 'echo ok\n' >"$f/scripts/doctor.sh"
printf '# Flow\n\n## Starting a flow\n\n## Next steps\n' >"$f/skills/orch-flow/SKILL.md"
out="$(scan_flow_cmd "$f")"
flags "a script naming a plugin command outside flow_cmd is flagged" \
  "$out" "scripts/orch.sh:9: names a plugin command outside flow_cmd"
flags "a flow_cmd section orch-flow lacks is flagged" \
  "$out" "skills/orch-flow/SKILL.md: has no section flow_cmd names: Next phase"
assert_eq "a comment and an existing section are not flagged" \
  "$(printf '%s\n' "$out" | grep -cE ':8:|Starting a flow')" "0"
check "the scripts name a plugin command only through flow_cmd, whose sections exist" \
  "$(scan_flow_cmd "$PLUGIN_ROOT")"

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
f="$(new_fixture)"
mkdir -p "$f/scripts" "$f/docs/junie"
printf '%s\n' 'PLANNING_ALLOWLIST=(docs/agents/ .scratch/)' 'PLANNING_RECORDS=(CONTEXT.md docs/adr/)' \
  'planning_allowlist_text() { local IFS=,; printf "%s" "${PLANNING_ALLOWLIST[*]}" | sed "s/,/, /g"; }' \
  'planning_records_text() { local IFS=,; printf "%s" "${PLANNING_RECORDS[*]}" | sed "s/,/, /g"; }' \
  >"$f/scripts/planning-allowlist.sh"
printf '%s\n' '<!-- orchestrator:begin -->' 'Records (CONTEXT.md) are recorded.' \
  'Artifacts (docs/agents/,' '.scratch/) are fine.' '<!-- orchestrator:begin -->' >"$f/docs/junie/AGENTS.md"
out="$(scan_junie_planning "$f")"
flags "a snippet with two begin markers is flagged" \
  "$out" "docs/junie/AGENTS.md: has 2 begin markers, not 1"
flags "a snippet with no end marker is flagged" \
  "$out" "docs/junie/AGENTS.md: has 0 end markers, not 1"
flags "a snippet whose records drift from planning-allowlist.sh is flagged" \
  "$out" "docs/junie/AGENTS.md: does not list the planning records as planning-allowlist.sh does: (CONTEXT.md, docs/adr/)"
assert_eq "an allowlist that matches across a line break is not flagged" \
  "$(printf '%s\n' "$out" | grep -c 'planning allowlist')" "0"
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
f="$(new_fixture)"
mkdir -p "$f/docs"
printf '%s\n' '| Capability | Claude Code | Junie CLI |' '| --- | --- | --- |' \
  '| Ask | `AskUserQuestion`. | Plain text. |' '| Guard | A hook. |  |' \
  '| Start | The Agent tool. | One | two. |' >"$f/docs/host-capabilities.md"
out="$(scan_capability_table "$f")"
flags "a row with an empty cell is flagged" "$out" "docs/host-capabilities.md:4: a row with an empty cell"
flags "a row with a stray pipe is flagged" "$out" "docs/host-capabilities.md:5: a row with 4 cells, not 3"
assert_eq "a filled row is not flagged" "$(printf '%s\n' "$out" | grep -cE ':(1|2|3):')" "0"
check "every host capability row has both hosts' cells filled" \
  "$(scan_capability_table "$PLUGIN_ROOT")"

# --- review pass (#342) --------------------------------------------------------
echo
echo "review pass (#342)"
# A review pass is defined once, in orch-review's ## Review pass section, which
# starts with review-pass begin. Quick implementation's step 6 runs that
# section rather than keeping its own copy.
# scan_review_pass <plugin root>: one line per break of that rule.
scan_review_pass() {
  local r="$1" review="skills/orch-review/SKILL.md" quick="skills/orch-quick-implement/SKILL.md" body
  if body="$(md_section "$r/$review" "## Review pass")"; then
    flat_text <<<"$body" | grep -qF 'review-pass begin' \
      || echo "$review: ## Review pass does not name review-pass begin"
  else
    echo "$review: no ## Review pass section"
  fi
  body="$(md_section "$r/$quick" "## 6. Review" | flat_text)"
  { grep -qF '`orch-review`' <<<"$body" && grep -qF '**Review pass**' <<<"$body"; } \
    || echo "$quick: step 6 does not refer to orch-review's **Review pass** section"
  return 0
}
f="$(new_fixture)"
mkdir -p "$f/skills/orch-review" "$f/skills/orch-quick-implement"
printf '# R\n\n## Review pass\n\nStart the reviewers.\n\n## Other\n\nrun review-pass begin\n' \
  >"$f/skills/orch-review/SKILL.md"
printf '# Q\n\n## 6. Review\n\nStart the reviewers.\n\n## 7. Open the PR\n\nSee `orch-review` **Review pass**.\n' \
  >"$f/skills/orch-quick-implement/SKILL.md"
out="$(scan_review_pass "$f")"
flags "a Review pass section that skips review-pass begin is flagged" \
  "$out" "skills/orch-review/SKILL.md: ## Review pass does not name review-pass begin"
flags "a step 6 that does not run orch-review's Review pass is flagged" \
  "$out" "skills/orch-quick-implement/SKILL.md: step 6 does not refer to orch-review's **Review pass** section"
printf '# R\n\n## Other\n' >"$f/skills/orch-review/SKILL.md"
flags "a missing Review pass section is flagged" \
  "$(scan_review_pass "$f")" "skills/orch-review/SKILL.md: no ## Review pass section"
printf '# R\n\n## Review pass\n\nRun `orch.sh review-pass begin <issue>`.\n' >"$f/skills/orch-review/SKILL.md"
printf '# Q\n\n## 6. Review\n\nRun the `orch-review` skill'"'"'s **Review\npass** section.\n' \
  >"$f/skills/orch-quick-implement/SKILL.md"
assert_empty "a review pass defined once and run by step 6 is not flagged" "$(scan_review_pass "$f")"
check "the review pass is defined once in orch-review and quick implementation runs it" \
  "$(scan_review_pass "$PLUGIN_ROOT")"

# --- summary -----------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
