#!/usr/bin/env bash
#
# Docs linter: named structural rules over the plugin's skills, agents,
# commands and docs.
#
# Each rule is a scan_* function that takes a plugin root and prints one line
# per problem, "<file>: <problem>", and nothing when the root obeys it. The
# rules run once against the real plugin root, then against fixture plugin
# roots that break them, so a rule that stops flagging anything fails here too.
# The linter checks structure only: it never runs orch.sh and holds no flow
# state.

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PASS=0
FAIL=0

ok()  { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }
assert_eq()       { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }
assert_contains() { case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "missing '$3' in: $2" ;; esac; }
assert_empty()    { if [ -z "$2" ]; then ok "$1"; else bad "$1" "expected no output, got: $2"; fi; }

# flat_text [file]: the file, or stdin when given none, on one line with
# every whitespace run collapsed to one space.
flat_text() { tr -s ' \t\n' '   ' <"${1:-/dev/stdin}"; }

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

# --- skill names (ADR-0014) --------------------------------------------------
# Every orchestrator skill carries the orch- prefix. An old unprefixed name
# left in a skill, command, hook, or doc points a model at a skill that no
# longer exists. CHANGELOG, ADRs, and .out-of-scope/ record history and may
# name the old ones; scripts/test/ feeds old names in deliberately as negative
# cases. The spec review's command and skill were renamed spec-review in 2.0.0
# (#235), so the review-spec names, command included, are old names too.
echo
echo "skill names (ADR-0014)"
old_names='orchestrator:(flow|handoff|review|review-spec|quick-implement|orch-review-spec)([^a-z-]|$)|skills/(flow|handoff|review|review-spec|quick-implement|orch-review-spec)/|^name: (flow|handoff|review|review-spec|quick-implement|orch-review-spec)$'
# scan_old_names <plugin root>: each old skill or command name in a tracked
# file outside history, and each old command file or skill directory.
scan_old_names() {
  local r="$1"
  git -C "$r" ls-files -z \
    | grep -zvE '^(CHANGELOG\.md|docs/adr/|scripts/test/|\.out-of-scope/)' \
    | (cd "$r" && xargs -0 grep -nE "$old_names" 2>/dev/null) \
    | sed -E 's/^([^:]*:[0-9]+):/\1: old skill or command name: /'
  [ -e "$r/commands/review-spec.md" ] && echo "commands/review-spec.md: old command file"
  [ -e "$r/skills/orch-review-spec" ] && echo "skills/orch-review-spec/: old skill directory"
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
git -C "$f" add -A
out="$(scan_old_names "$f")"
flags "the old review-spec skill name is flagged" "$out" "commands/a.md:1: old skill or command name"
flags "the old /orchestrator:review-spec command is flagged" "$out" "commands/b.md:1: old skill or command name"
flags "the old orch-review-spec skill name is flagged" "$out" "commands/c.md:1: old skill or command name"
flags "the old orch-review-spec skill directory is flagged" "$out" "commands/d.md:1: old skill or command name"
flags "the old orch-review-spec skill name line is flagged" "$out" "commands/e.md:1: old skill or command name"
assert_eq "the new spec-review names are not flagged" \
  "$(printf '%s\n' "$out" | grep -cE '^(commands/new\.md|skills/)')" "0"
assert_eq "history may name the old ones" \
  "$(printf '%s\n' "$out" | grep -c '^docs/adr/')" "0"
mkdir -p "$f/skills/orch-review-spec"
: >"$f/commands/review-spec.md"
out="$(scan_old_names "$f")"
flags "an old review-spec command file is flagged" "$out" "commands/review-spec.md: old command file"
flags "an old orch-review-spec skill directory is flagged" "$out" "skills/orch-review-spec/: old skill directory"
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
check "every skill and command resolves orch.sh the one documented way" \
  "$(scan_orch_resolution "$PLUGIN_ROOT")"
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
# is the one that has to explain the failure (#128). The Junie install in that
# stop text is unverified, so it has to say so (#121). One stop text, copied
# into each skill: once the Junie install is verified, every copy must change
# together, so they may not drift apart.
echo
echo "skills-only stop text (#128, #121)"
stop_text() { awk '/^If `orch.sh` is at none of these paths/,/which is unverified\)\.$/' "$1"; }
# scan_stop_text <plugin root>: each skill off orch-flow's stop text.
scan_stop_text() {
  local r="$1" f ref n
  ref="$(stop_text "$r/skills/orch-flow/SKILL.md")"
  [[ "$ref" == *"skills-only install"* ]] ||
    echo "skills/orch-flow/SKILL.md: carries no skills-only stop text"
  for f in "$r"/skills/*/SKILL.md; do
    n="${f#"$r"/}"
    grep -qF 'skills-only install' "$f" ||
      echo "$n: names no full-plugin install when orch.sh is missing"
    grep -qF 'as a Junie extension, which is unverified' "$f" ||
      echo "$n: does not mark its Junie install unverified"
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
flags "the scan flags a skill with no full-plugin install named" "$out" "skills/orch-none/SKILL.md: names no full-plugin install when orch.sh is missing"
flags "the scan flags a skill that does not mark its Junie install unverified" "$out" "skills/orch-none/SKILL.md: does not mark its Junie install unverified"
assert_eq "the scan accepts a word-for-word copy" "$(printf '%s\n' "$out" | grep -c 'orch-same')" "0"
printf 'No stop text here.\n' >"$f/skills/orch-flow/SKILL.md"
flags "the scan flags orch-flow with no stop text to match" \
  "$(scan_stop_text "$f")" "skills/orch-flow/SKILL.md: carries no skills-only stop text"
check "every skill carries orch-flow's skills-only stop text, Junie unverified" "$(scan_stop_text "$PLUGIN_ROOT")"

# --- doctor's mattpocock skill list -------------------------------------------
# Doctor's required list is only worth something while it matches what the
# plugin reads: a skill invoked but not listed passes doctor and then fails its
# phase, and a skill listed but never invoked fails doctor for nothing. So the
# list is compared with every mattpocock skill that a skill or agent invokes,
# through `mp-skill <name>` or `mattpocock-skills:<name>`.
echo
echo "doctor's mattpocock skill list"
# Mentions that name an upstream skill without invoking it, one file:name per
# line (file relative to the plugin root).
#   orch-handoff says it replaces mattpocock-skills:handoff, not that it runs it.
mp_not_invoked='skills/orch-handoff/SKILL.md:handoff'
# scan_mp_skills <plugin root>: each skill invoked but not listed, or listed
# but not invoked.
scan_mp_skills() {
  local r="$1" listed invoked name
  listed="$(sed -n 's/^MP_SKILLS="\(.*\)"$/\1/p' "$r/scripts/doctor.sh" 2>/dev/null | tr ' ' '\n' | grep . | sort -u)"
  if [ -z "$listed" ]; then
    echo "scripts/doctor.sh: no MP_SKILLS to check against"
    return
  fi
  # file:name, one per invocation.
  invoked="$(cd "$r" && grep -oE 'mp-skill [a-z][a-z-]*|mattpocock-skills:[a-z][a-z-]*' \
      skills/*/SKILL.md agents/*.md 2>/dev/null \
    | sed -E 's/:(mp-skill |mattpocock-skills:)/:/' \
    | grep -vxF "$mp_not_invoked" | sort -u)"
  printf '%s\n' "$invoked" | grep . | while IFS=: read -r file name; do
    printf '%s\n' "$listed" | grep -qxF "$name" ||
      echo "$file: invokes $name, which MP_SKILLS omits"
  done
  for name in $listed; do
    printf '%s\n' "$invoked" | grep -q ":$name\$" ||
      echo "scripts/doctor.sh: MP_SKILLS lists $name, which no skill or agent invokes"
  done
}
f="$(new_fixture)"
mkdir -p "$f/scripts" "$f/skills/orch-a" "$f/skills/orch-handoff" "$f/agents"
printf 'MP_SKILLS="to-spec grilling"\n' >"$f/scripts/doctor.sh"
printf 'Run `bash "$ORCH" mp-skill to-spec`, then `mattpocock-skills:to-tickets`.\n' >"$f/skills/orch-a/SKILL.md"
printf 'This replaces `mattpocock-skills:handoff`.\n' >"$f/skills/orch-handoff/SKILL.md"
printf 'Invoke `mattpocock-skills:to-spec`.\n' >"$f/agents/orch-b.md"
out="$(scan_mp_skills "$f")"
flags "the scan flags an invoked skill missing from MP_SKILLS" "$out" "skills/orch-a/SKILL.md: invokes to-tickets, which MP_SKILLS omits"
flags "the scan flags a listed skill nothing invokes" "$out" "scripts/doctor.sh: MP_SKILLS lists grilling, which no skill or agent invokes"
assert_eq "orch-handoff naming the skill it replaces is not an invocation" \
  "$(printf '%s\n' "$out" | grep -c 'handoff')" "0"
printf 'nothing\n' >"$f/scripts/doctor.sh"
flags "the scan flags a doctor.sh with no MP_SKILLS" \
  "$(scan_mp_skills "$f")" "scripts/doctor.sh: no MP_SKILLS to check against"
check "doctor's MP_SKILLS is exactly the mattpocock skills invoked" "$(scan_mp_skills "$PLUGIN_ROOT")"

# --- summary -----------------------------------------------------------------
echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
