# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- agent --------------------------------------------------------------------
# The agent setting: a model and an effort per role, each its own git config
# key, looked up local, then global, else inherit. Driven against a fresh
# repo's real local config and a throwaway HOME's real global config, so a
# --global write never reaches another section's or the developer's config.
echo
echo "agent"
new_repo >/dev/null
HOME="$(mktemp -d)"
export HOME
# key <scope> <key>: the key's value at that scope, or <unset>.
key() { git config "--$1" --get "$2" 2>/dev/null || echo "<unset>"; }

out="$("$ORCH" agent get implementer 2>&1)"; st=$?
assert_status "get succeeds with nothing set" "$st" 0
assert_eq "get prints inherit for both keys when nothing is set" "$out" \
  "model inherit
effort inherit"

out="$("$ORCH" agent set implementer --model opus --effort high 2>&1)"; st=$?
assert_status "set accepts a model and an effort" "$st" 0
assert_eq "set writes the model to local config" "$(key local orchestrator.model.implementer)" "opus"
assert_eq "set writes the effort to local config" "$(key local orchestrator.effort.implementer)" "high"
assert_eq "set leaves global config alone" "$(key global orchestrator.model.implementer)" "<unset>"
assert_eq "get round-trips both keys" "$("$ORCH" agent get implementer 2>&1)" \
  "model opus
effort high"

"$ORCH" agent set reviewer --model haiku >/dev/null
assert_eq "set with only --model leaves the effort inheriting" "$("$ORCH" agent get reviewer 2>&1)" \
  "model haiku
effort inherit"
"$ORCH" agent set reviewer --effort low >/dev/null
assert_eq "set with only --effort keeps the model already set" "$("$ORCH" agent get reviewer 2>&1)" \
  "model haiku
effort low"

# Lookup: local over global over inherit, each key on its own.
out="$("$ORCH" agent set fixer --model sonnet --effort max --global 2>&1)"; st=$?
assert_status "set --global succeeds" "$st" 0
assert_eq "set --global writes the model to global config" "$(key global orchestrator.model.fixer)" "sonnet"
assert_eq "set --global leaves local config alone" "$(key local orchestrator.model.fixer)" "<unset>"
assert_eq "get falls back to global config" "$("$ORCH" agent get fixer 2>&1)" \
  "model sonnet
effort max"
"$ORCH" agent set fixer --model opus >/dev/null
assert_eq "a local model overrides the global one, and the global effort still applies" \
  "$("$ORCH" agent get fixer 2>&1)" \
  "model opus
effort max"
"$ORCH" agent set closer --model fable --global >/dev/null
"$ORCH" agent set closer --effort xhigh >/dev/null
assert_eq "a global model and a local effort combine" "$("$ORCH" agent get closer 2>&1)" \
  "model fable
effort xhigh"

# Refusals: each exit 1, naming the allowed values, config untouched.
before="$(git config --local --get-regexp '^orchestrator\.' ; git config --global --get-regexp '^orchestrator\.')"
untouched() {
  assert_eq "$1 leaves config untouched" \
    "$(git config --local --get-regexp '^orchestrator\.' ; git config --global --get-regexp '^orchestrator\.')" "$before"
}
out="$("$ORCH" agent set implementor --model opus 2>&1)"; st=$?
assert_status "set refuses an unknown role" "$st" 1
assert_contains "with an orch: message naming the roles" "$out" \
  "orch: unknown role implementor (want implementer|lens|reviewer|fixer|closer|resolver)"
untouched "an unknown role"
out="$("$ORCH" agent set lens --model gpt 2>&1)"; st=$?
assert_status "set refuses a disallowed model" "$st" 1
assert_contains "naming the allowed models" "$out" "orch: model gpt is not allowed (want sonnet|opus|haiku|fable|inherit)"
untouched "a disallowed model"
out="$("$ORCH" agent set lens --effort huge 2>&1)"; st=$?
assert_status "set refuses a disallowed effort" "$st" 1
assert_contains "naming the allowed efforts" "$out" "orch: effort huge is not allowed (want low|medium|high|xhigh|max|inherit)"
untouched "a disallowed effort"
out="$("$ORCH" agent set lens --model "opus haiku" 2>&1)"; st=$?
assert_status "set refuses a model made of several allowed words" "$st" 1
assert_contains "naming the allowed models" "$out" "orch: model opus haiku is not allowed"
untouched "a model made of several allowed words"
out="$("$ORCH" agent set lens --effort $'low\nmedium' 2>&1)"; st=$?
assert_status "set refuses an effort made of several allowed lines" "$st" 1
untouched "an effort made of several allowed lines"
out="$("$ORCH" agent set "lens reviewer" --model opus 2>&1)"; st=$?
assert_status "set refuses a role made of several roles" "$st" 1
assert_eq "with only an orch: message naming the roles" "$out" \
  "orch: unknown role lens reviewer (want implementer|lens|reviewer|fixer|closer|resolver)"
untouched "a role made of several roles"
out="$("$ORCH" agent set lens 2>&1)"; st=$?
assert_status "set refuses a call with neither --model nor --effort" "$st" 1
assert_contains "naming both flags and the allowed values" "$out" \
  "orch: agent set needs --model or --effort (models: sonnet|opus|haiku|fable|inherit; efforts: low|medium|high|xhigh|max|inherit)"
untouched "a call with neither flag"
out="$("$ORCH" agent set lens --model sonnet --effort bogus 2>&1)"; st=$?
assert_status "set refuses a mixed valid and disallowed call" "$st" 1
assert_contains "naming the disallowed value's allowed values" "$out" "orch: effort bogus is not allowed"
untouched "a mixed valid and disallowed call"
out="$("$ORCH" agent set lens --model 2>&1)"; st=$?
assert_status "set refuses --model with no value" "$st" 1
untouched "--model with no value"
out="$("$ORCH" agent set lens --model opus --model haiku 2>&1)"; st=$?
assert_status "set refuses a flag given twice" "$st" 1
untouched "a flag given twice"

# set validates each value as it is parsed, so the first problem met is named.
out="$("$ORCH" agent set implementer --model bogus --global --global 2>&1)"
assert_eq "set names a disallowed model before a repeated --global" "$out" \
  "orch: model bogus is not allowed (want sonnet|opus|haiku|fable|inherit)"
out="$("$ORCH" agent set implementer --effort bad --model 2>&1)"
assert_eq "set names a disallowed effort before a missing model value" "$out" \
  "orch: effort bad is not allowed (want low|medium|high|xhigh|max|inherit)"
out="$("$ORCH" agent set implementer --effort bad --model bad 2>&1)"
assert_eq "set names the first disallowed value met" "$out" \
  "orch: effort bad is not allowed (want low|medium|high|xhigh|max|inherit)"

# set ... inherit clears the key at that scope, never storing the literal.
"$ORCH" agent set fixer --model inherit >/dev/null
assert_eq "set --model inherit clears the local model" "$(key local orchestrator.model.fixer)" "<unset>"
assert_eq "so the global model shows through again" "$("$ORCH" agent get fixer 2>&1)" \
  "model sonnet
effort max"
"$ORCH" agent set fixer --effort inherit --global >/dev/null
assert_eq "set --effort inherit --global clears the global effort" "$(key global orchestrator.effort.fixer)" "<unset>"
assert_eq "and leaves the global model" "$(key global orchestrator.model.fixer)" "sonnet"

# show: one line per role, in role order, with each key's source.
git config --local orchestrator.effort.resolver gpt
out="$("$ORCH" agent show 2>&1)"; st=$?
assert_status "show succeeds, even with a disallowed hand-set value" "$st" 0
assert_eq "show lists every role in order with its sources, marking the invalid value" "$(head -n 6 <<<"$out")" \
  "implementer model opus (local) effort high (local)
lens model inherit (inherit) effort inherit (inherit)
reviewer model haiku (local) effort low (local)
fixer model sonnet (global) effort inherit (inherit)
closer model fable (global) effort xhigh (local)
resolver model inherit (inherit) effort gpt (local, invalid)"

# get refuses a disallowed effective value, naming key, value and allowed
# values.
out="$("$ORCH" agent get resolver 2>&1)"; st=$?
assert_status "get refuses a hand-set disallowed value" "$st" 1
assert_contains "naming the key, its value and the allowed values" "$out" \
  "orch: orchestrator.effort.resolver is gpt - not an allowed effort (want low|medium|high|xhigh|max|inherit)"
assert_not_contains "and printing no values" "$out" "model inherit"
git config --global orchestrator.model.lens gpt-5
out="$("$ORCH" agent get lens 2>&1)"; st=$?
assert_status "get refuses a hand-set disallowed global value" "$st" 1
assert_contains "naming the global remedy" "$out" "orch.sh agent clear lens --model --global"
git config --local orchestrator.model.reviewer "opus haiku"
out="$("$ORCH" agent get reviewer 2>&1)"; st=$?
assert_status "get refuses a hand-set value made of several allowed words" "$st" 1
assert_contains "naming the key and its value" "$out" \
  "orch: orchestrator.model.reviewer is opus haiku - not an allowed model"
git config --local orchestrator.model.reviewer haiku
out="$("$ORCH" agent get "lens reviewer" 2>&1)"; st=$?
assert_status "get refuses a role made of several roles" "$st" 1
assert_contains "naming the roles" "$out" "orch: unknown role lens reviewer (want"
out="$("$ORCH" agent get implementor 2>&1)"; st=$?
assert_status "get refuses an unknown role" "$st" 1
assert_contains "naming the roles" "$out" "(want implementer|lens|reviewer|fixer|closer|resolver)"

# clear: both keys, or only the one named, at the scope named.
out="$("$ORCH" agent clear resolver 2>&1)"; st=$?
assert_status "clear succeeds" "$st" 0
assert_eq "clear removes the invalid local effort" "$(key local orchestrator.effort.resolver)" "<unset>"
out="$("$ORCH" agent clear lens --model --global 2>&1)"; st=$?
assert_status "clear --model --global succeeds" "$st" 0
assert_eq "and removes the global model" "$(key global orchestrator.model.lens)" "<unset>"
out="$("$ORCH" agent clear implementer --effort 2>&1)"; st=$?
assert_eq "clear --effort removes only the effort" "$("$ORCH" agent get implementer 2>&1)" \
  "model opus
effort inherit"
"$ORCH" agent clear closer >/dev/null
assert_eq "clear with no flag removes both local keys, leaving the global model" \
  "$("$ORCH" agent get closer 2>&1)" \
  "model fable
effort inherit"
"$ORCH" agent clear closer --global >/dev/null
assert_eq "clear --global removes the global keys" "$(key global orchestrator.model.closer)" "<unset>"
out="$("$ORCH" agent clear closer 2>&1)"; st=$?
assert_status "clear on an unset key exits 0" "$st" 0
assert_eq "with no output" "$out" ""
# A clear git cannot carry out - the global config locked, here by a stale
# lock file - fails naming the key, rather than passing as a key not set.
"$ORCH" agent set closer --model haiku --global >/dev/null
: >"$HOME/.gitconfig.lock"
out="$("$ORCH" agent clear closer --model --global 2>&1)"; st=$?
rm -f "$HOME/.gitconfig.lock"
"$ORCH" agent clear closer --global >/dev/null
assert_status "a failed clear exits 1" "$st" 1
assert_contains "naming the key it could not clear" "$out" "orch: cannot clear orchestrator.model.closer"
out="$("$ORCH" agent clear implementor 2>&1)"; st=$?
assert_status "clear refuses an unknown role" "$st" 1
assert_contains "naming the roles" "$out" "(want implementer|lens|reviewer|fixer|closer|resolver)"

out="$("$ORCH" agent 2>&1)"; st=$?
assert_status "refuses a missing verb" "$st" 1
assert_contains "naming the verbs" "$out" "want set|show|clear|get|sync"
out="$("$ORCH" agent roles 2>&1)"; st=$?
assert_status "roles succeeds" "$st" 0
assert_eq "roles prints the six roles one per line, in order" "$out" "implementer
lens
reviewer
fixer
closer
resolver"
out="$("$ORCH" agent roles extra 2>&1)"; st=$?
assert_status "roles refuses an argument" "$st" 1
out="$("$ORCH" agent show extra 2>&1)"; st=$?
assert_status "show refuses an argument" "$st" 1

out="$("$ORCH" help 2>&1)"
assert_contains "agent set is in the usage text" "$out" "agent set <role>"
assert_contains "the CLI conventions' noun table has an agent row" \
  "$(grep '^| `agent`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`set`, `show`, `clear`, `get`, `sync`'
# --host junie: the same verbs on the Junie keys, beside the Claude Code ones.
jkey() { key "$1" "orchestrator.junie.$2.$3"; }
out="$("$ORCH" agent get lens --host junie 2>&1)"; st=$?
assert_status "get --host junie succeeds with nothing set" "$st" 0
assert_eq "and prints inherit for both Junie keys" "$out" \
  "model inherit
effort inherit"
out="$("$ORCH" agent set lens --host junie --model gpt-5 --effort medium 2>&1)"; st=$?
assert_status "set --host junie accepts a model and an effort" "$st" 0
assert_eq "set --host junie writes the Junie model" "$(jkey local model lens)" "gpt-5"
assert_eq "set --host junie writes the Junie effort" "$(jkey local effort lens)" "medium"
assert_eq "a Junie write leaves the Claude Code model alone" "$(key local orchestrator.model.lens)" "<unset>"
assert_eq "get --host junie round-trips" "$("$ORCH" agent get lens --host junie 2>&1)" \
  "model gpt-5
effort medium"
assert_eq "get without --host ignores the Junie keys" "$("$ORCH" agent get lens 2>&1)" \
  "model inherit
effort inherit"
"$ORCH" agent set implementer --host junie --model custom:my/profile.1 >/dev/null
assert_eq "set --host junie accepts a custom profile id" "$(jkey local model implementer)" "custom:my/profile.1"
assert_eq "a Claude Code write leaves the Junie keys alone" \
  "$("$ORCH" agent set implementer --model sonnet >/dev/null; jkey local model implementer)" "custom:my/profile.1"
"$ORCH" agent set reviewer --host junie --model gpt-5 --global >/dev/null
"$ORCH" agent set reviewer --host junie --effort low >/dev/null
assert_eq "Junie lookup combines a global model and a local effort" \
  "$("$ORCH" agent get reviewer --host junie 2>&1)" "model gpt-5
effort low"
"$ORCH" agent set reviewer --host junie --model o3 >/dev/null
assert_eq "a local Junie model wins over the global one" \
  "$("$ORCH" agent get reviewer --host junie 2>&1 | head -n 1)" "model o3"
"$ORCH" agent set reviewer --host junie --model inherit >/dev/null
assert_eq "set --host junie --model inherit clears the local key" "$(jkey local model reviewer)" "<unset>"
assert_eq "so the global Junie model shows through" \
  "$("$ORCH" agent get reviewer --host junie 2>&1 | head -n 1)" "model gpt-5"

before="$(git config --local --get-regexp '^orchestrator\.' ; git config --global --get-regexp '^orchestrator\.')"
out="$("$ORCH" agent set lens --host junie --model "GPT 5" 2>&1)"; st=$?
assert_status "set --host junie refuses a model with a space" "$st" 1
assert_contains "naming the pattern" "$out" "[A-Za-z0-9._:/-]+"
assert_contains "pointing at the /model picker and --model flag" "$out" "/model"
assert_contains "and warning about aliases" "$out" "aliases resolve unpredictably"
untouched "a Junie model with a space"
out="$("$ORCH" agent set lens --host junie --model 'a;b' 2>&1)"; st=$?
assert_status "set --host junie refuses a disallowed character" "$st" 1
untouched "a Junie model with a disallowed character"
out="$("$ORCH" agent set lens --host junie --model $'gpt\nx' 2>&1)"; st=$?
assert_status "set --host junie matches the model pattern as a whole" "$st" 1
untouched "a multi-line Junie model"
out="$("$ORCH" agent set lens --host junie --effort xhigh 2>&1)"; st=$?
assert_status "set --host junie refuses an effort Claude Code allows" "$st" 1
assert_contains "naming the Junie efforts" "$out" "low|medium|high|inherit"
untouched "a disallowed Junie effort"
out="$("$ORCH" agent set lens --host codex --model opus 2>&1)"; st=$?
assert_status "set refuses another host" "$st" 1
assert_contains "set names the unknown host" "$out" "host codex is not allowed (want junie)"
untouched "another host"
out="$("$ORCH" agent get lens --host codex 2>&1)"; st=$?
assert_status "get refuses another host" "$st" 1
assert_contains "get names the unknown host" "$out" "host codex is not allowed (want junie)"
"$ORCH" agent set lens --model haiku >/dev/null
out="$("$ORCH" agent clear lens --host codex 2>&1)"; st=$?
assert_status "clear refuses another host" "$st" 1
assert_contains "clear names the unknown host" "$out" "host codex is not allowed (want junie)"
assert_eq "a refused clear --host codex leaves a set key set" "$(git config --local --get orchestrator.model.lens)" "haiku"
"$ORCH" agent clear lens >/dev/null
for verb in clear get; do
  out="$("$ORCH" agent "$verb" lens --host 2>&1)"; st=$?
  assert_status "$verb refuses --host with no value" "$st" 1
  assert_contains "$verb names the missing value as agent set does" "$out" "--host needs a value (want junie)"
done
out="$("$ORCH" agent set lens --host junie --host junie --model gpt-5 2>&1)"; st=$?
assert_status "set refuses --host given twice" "$st" 1
assert_contains "set prints its usage for a repeated --host" "$out" "usage: orch.sh agent set <role> [--model <m>] [--effort <e>] [--global] [--host junie]"
out="$("$ORCH" agent clear lens --host junie --host junie 2>&1)"; st=$?
assert_status "clear refuses --host given twice" "$st" 1
assert_contains "clear prints its usage for a repeated --host" "$out" "usage: orch.sh agent clear <role> [--model] [--effort] [--global] [--host junie]"
out="$("$ORCH" agent get lens --host junie --host junie 2>&1)"; st=$?
assert_status "get refuses --host given twice" "$st" 1
assert_contains "get prints its usage for a repeated --host" "$out" "usage: orch.sh agent get <role> [--host junie]"
help_set="$(help_entry "agent set" | flat_text)"
assert_contains "the agent set help entry points at agent show" "$help_set" "agent show"
assert_not_contains "the agent set help entry names no model alias" "$help_set" "sonnet"
assert_not_contains "the agent set help entry names no effort level" "$help_set" "xhigh"

git config --local orchestrator.junie.effort.fixer extreme
git config --global orchestrator.junie.model.closer "bad model"
out="$("$ORCH" agent show 2>&1)"; st=$?
assert_status "show succeeds with invalid Junie values" "$st" 0
assert_eq "show prints twelve lines" "$(wc -l <<<"$out" | tr -d ' ')" "12"
assert_eq "show's Junie lines follow the six Claude Code lines, invalid values marked" "$(tail -n 6 <<<"$out")" \
  "junie implementer model custom:my/profile.1 (local) effort inherit (inherit)
junie lens model gpt-5 (local) effort medium (local)
junie reviewer model gpt-5 (global) effort low (local)
junie fixer model inherit (inherit) effort extreme (local, invalid)
junie closer model bad model (global, invalid) effort inherit (inherit)
junie resolver model inherit (inherit) effort inherit (inherit)"
out="$("$ORCH" agent get fixer --host junie 2>&1)"; st=$?
assert_status "get --host junie refuses an invalid stored value" "$st" 1
assert_contains "naming the clear that removes it" "$out" "orch.sh agent clear fixer --host junie --effort"
out="$("$ORCH" agent get closer --host junie 2>&1)"; st=$?
assert_contains "naming the global clear" "$out" "orch.sh agent clear closer --host junie --model --global"

"$ORCH" agent clear lens --host junie --model >/dev/null
assert_eq "clear --host junie --model removes only the Junie model" \
  "$(jkey local model lens) $(jkey local effort lens)" "<unset> medium"
"$ORCH" agent clear lens --host junie >/dev/null
assert_eq "clear --host junie removes both Junie keys" "$(jkey local effort lens)" "<unset>"
"$ORCH" agent clear reviewer --host junie --global >/dev/null
assert_eq "clear --host junie --global removes the global Junie key" "$(jkey global model reviewer)" "<unset>"
assert_eq "and leaves the Claude Code keys" "$(key local orchestrator.model.implementer)" "sonnet"
out="$("$ORCH" agent get 2>&1)"; st=$?
assert_contains "get's usage names --host junie" "$out" "[--host junie]"

# The agent settings are read once per process from git config's -z records.
git config --local --add orchestrator.model.resolver opus
git config --local --add orchestrator.model.resolver sonnet
assert_eq "agent show reads the last of a key written twice" \
  "$("$ORCH" agent show | grep '^resolver')" "resolver model sonnet (local) effort inherit (inherit)"
assert_eq "agent get reads the last of a key written twice" \
  "$("$ORCH" agent get resolver 2>&1 | head -n 1)" "model sonnet"
git config --local --unset-all orchestrator.model.resolver
printf '[orchestrator "effort"]\n\tresolver\n' >>.git/config
out="$("$ORCH" agent show | grep '^resolver')"
assert_eq "a key with no value reads as the empty value, marked invalid" \
  "$out" "resolver model inherit (inherit) effort  (local, invalid)"
out="$("$ORCH" agent get resolver 2>&1)"; st=$?
assert_status "get refuses a key with no value" "$st" 1
assert_contains "naming its key" "$out" "orchestrator.effort.resolver"
git config --local --unset-all orchestrator.effort.resolver
git config --local orchestrator.model.resolver $'opus\nsonnet'
out="$("$ORCH" agent show)"
assert_contains "a stored multi-line value is one invalid value" "$out" "resolver model opus
sonnet (local, invalid)"
assert_contains "and leaves other keys' lines" "$out" "closer model inherit (inherit) effort inherit (inherit)"
out="$("$ORCH" agent get resolver 2>&1)"; st=$?
assert_status "get refuses a stored multi-line value" "$st" 1
assert_contains "naming its key" "$out" "orchestrator.model.resolver"
git config --local --unset-all orchestrator.model.resolver

# A write is synced in the same command: the copy carries the value just set.
"$ORCH" agent set resolver --host junie --model gpt-5 >/dev/null
assert_contains "set --host junie writes a copy carrying the model" \
  "$(cat .junie/agents/orch-resolver.md)" "gpt-5"
"$ORCH" agent set resolver --host junie --model o3 >/dev/null
assert_contains "a second set leaves the copy carrying the new model" \
  "$(cat .junie/agents/orch-resolver.md)" "o3"
assert_eq "and not the old one" "$(grep -c gpt-5 .junie/agents/orch-resolver.md)" "0"
"$ORCH" agent clear resolver --host junie >/dev/null
assert_eq "clear --host junie removes the copy" "$([ -e .junie/agents/orch-resolver.md ] && echo present || echo gone)" "gone"
unset -f jkey
unset -f key untouched
restore_suite_env

# --- agent sync ---------------------------------------------------------------
# Agent copies: sync writes a marked copy of each plugin agent whose role has a
# Junie setting into the checkout's .junie/agents/, and keeps it out of git.
# Driven through the CLI against a fresh repo and a throwaway HOME.
echo
echo "agent sync"
new_repo >/dev/null
HOME="$(mktemp -d)"
export HOME
as_dir=".junie/agents"
as_marker="# written by orch.sh agent sync"
as_plugin="$PLUGIN_ROOT/agents"
as_exclude() { cat "$(git rev-parse --git-common-dir)/info/exclude" 2>/dev/null; }
# as_copies: the file names under .junie/agents, one per line.
as_copies() { ls "$as_dir" 2>/dev/null; }

out="$("$ORCH" agent sync 2>&1)"; st=$?
assert_status "sync with nothing set succeeds" "$st" 0
assert_eq "sync with nothing set writes no copy" "$(as_copies)" ""
out="$("$ORCH" agent sync extra 2>&1)"; st=$?
assert_status "sync takes no argument" "$st" 1
assert_contains "the usage text lists agent sync" "$("$ORCH" help 2>&1)" "agent sync"

"$ORCH" agent set implementer --host junie --model gpt-5 --effort high >/dev/null
assert_eq "set --host junie writes the copy" "$(as_copies)" "orch-implementer.md"
assert_eq "the copy is the plugin agent with the marker, model and effort after the opening ---" \
  "$(cat "$as_dir/orch-implementer.md")" \
  "$(awk -v m="$as_marker" 'NR == 1 { print; print m; print "model: gpt-5"; print "reasoningLevel: high"; next } { print }' "$as_plugin/orch-implementer.md")"
assert_eq "the exclude file gains the copy line once" \
  "$(exclude_count '.junie/agents/orch-*.md')" "1"
"$ORCH" agent sync >/dev/null
assert_eq "a second sync adds no second exclude line" \
  "$(exclude_count '.junie/agents/orch-*.md')" "1"
assert_eq "the copy stays out of git status" "$(git status --porcelain)" ""

touch -d '2001-01-01' "$as_dir/orch-implementer.md"
"$ORCH" agent sync >/dev/null
assert_eq "a second sync leaves an identical copy alone" \
  "$(stat -c %y "$as_dir/orch-implementer.md" | cut -c1-4)" "2001"

"$ORCH" agent set lens --host junie --model claude-opus-5-5 >/dev/null
assert_eq "a lens setting writes every lens copy" "$(as_copies)" \
  "orch-implementer.md
orch-lens-consistency.md
orch-lens-fidelity.md
orch-lens-implementability.md
orch-lens-testability.md"
assert_eq "a model-only copy has no reasoningLevel" \
  "$(grep -c '^reasoningLevel:' "$as_dir/orch-lens-fidelity.md")" "0"

"$ORCH" agent set reviewer --model opus --effort high >/dev/null
"$ORCH" agent sync >/dev/null
assert_eq "the Claude Code keys never produce a copy" "$(as_copies | grep -c reviewer)" "0"

"$ORCH" agent set implementer --host junie --model gpt-5-mini >/dev/null
assert_contains "a changed setting rewrites the copy" "$(cat "$as_dir/orch-implementer.md")" "model: gpt-5-mini"
printf '%s\n' 'tampered' >>"$as_dir/orch-implementer.md"
"$ORCH" agent sync >/dev/null
assert_eq "a hand-edited marked copy is rewritten" \
  "$(grep -c tampered "$as_dir/orch-implementer.md")" "0"

"$ORCH" agent set implementer --host junie --model custom:my/profile.1 --effort low >/dev/null
assert_eq "a custom: profile id is written whole, colon and all" \
  "$(grep -E '^(model|reasoningLevel):' "$as_dir/orch-implementer.md")" \
  "model: custom:my/profile.1
reasoningLevel: low"
touch -d '2001-01-01' "$as_dir/orch-implementer.md"
"$ORCH" agent sync >/dev/null
assert_eq "and a second sync finds that copy current" \
  "$(stat -c %y "$as_dir/orch-implementer.md" | cut -c1-4)" "2001"
"$ORCH" agent set implementer --host junie --model gpt-5-mini >/dev/null
"$ORCH" agent clear implementer --host junie --effort >/dev/null

"$ORCH" agent clear lens --host junie >/dev/null
assert_eq "clear --host junie deletes the role's copies" "$(as_copies)" "orch-implementer.md"
printf '%s\n' '---' "$as_marker" 'name: orch-gone' '---' >"$as_dir/orch-gone.md"
"$ORCH" agent sync >/dev/null
assert_eq "a marked copy naming no plugin agent is deleted" "$(as_copies)" "orch-implementer.md"
printf '%s\n' 'mine' >"$as_dir/notes.md"
printf '%s\n' '---' 'name: orch-gone' "$as_marker" '---' >"$as_dir/orch-gone.md"
"$ORCH" agent clear implementer --host junie >/dev/null
assert_eq "only the line after the opening --- counts as the marker; non-orch files are never touched" \
  "$(as_copies)" "notes.md
orch-gone.md"
rm -f "$as_dir/orch-gone.md"

# An unmarked orch-*.md in the way is refused by name, and nothing else changes.
"$ORCH" agent set implementer --host junie --model gpt-5 >/dev/null
printf '%s\n' 'hand made' >"$as_dir/orch-reviewer-spec.md"
"$ORCH" agent clear implementer --host junie --model >/dev/null
printf '%s\n' '---' "$as_marker" '---' >"$as_dir/orch-fixer.md"
git config --local orchestrator.junie.model.implementer gpt-5
git config --local orchestrator.junie.model.reviewer gpt-5
before="$(dir_snapshot "$as_dir"; as_exclude)"
out="$("$ORCH" agent sync 2>&1)"; st=$?
assert_status "sync refuses an unmarked orch-*.md in its way" "$st" 1
assert_contains "naming the file" "$out" "orch-reviewer-spec.md"
assert_eq "and changes nothing else" "$(dir_snapshot "$as_dir"; as_exclude)" "$before"
assert_eq "the unmarked file is byte-identical" "$(cat "$as_dir/orch-reviewer-spec.md")" "hand made"

printf '%s\n' 'hand made too' >"$as_dir/orch-reviewer-standards.md"
out="$("$ORCH" agent sync 2>&1)"; st=$?
assert_status "sync refuses two unmarked orch-*.md in its way" "$st" 1
assert_eq "naming both files in one message" "$out" \
  "orch: agent sync: orch-reviewer-spec.md orch-reviewer-standards.md in $PWD/$as_dir carries no sync marker - not written by orch.sh agent sync, so left alone; rename or remove it, then rerun orch.sh agent sync"
rm -f "$as_dir/orch-reviewer-standards.md"

out="$("$ORCH" agent set closer --host junie --model gpt-5 2>&1)"; st=$?
assert_status "set --host junie with an unmarked file in the way exits non-zero" "$st" 1
assert_contains "with sync's message" "$out" "orch-reviewer-spec.md"
assert_eq "the key is still written" "$(git config --local --get orchestrator.junie.model.closer)" "gpt-5"
out="$("$ORCH" agent clear closer --host junie 2>&1)"; st=$?
assert_status "clear --host junie with an unmarked file in the way exits non-zero" "$st" 1
assert_contains "clear carries sync's message" "$out" "orch-reviewer-spec.md"
assert_eq "the key is still removed" "$(git config --local --get orchestrator.junie.model.closer || echo none)" "none"

# A linked worktree adds the line to the common git dir's exclude file.
new_repo >/dev/null
as_main="$PWD"
git worktree add -q "$as_main-wt" -b wt
cd "$as_main-wt" || exit 1
git config --local orchestrator.junie.model.closer gpt-5
"$ORCH" agent sync >/dev/null
assert_eq "a sync in a linked worktree writes the common git dir's exclude" \
  "$(grep -cxF '.junie/agents/orch-*.md' "$as_main/.git/info/exclude")" "1"
assert_eq "and the copy lands in the worktree" "$(as_copies)" "orch-closer.md"
cd "$as_main" || exit 1

# An exclude append that fails names the exclude file's path.
new_repo >/dev/null
rm -f .git/info/exclude
mkdir -p .git/info/exclude
git config --local orchestrator.junie.model.closer gpt-5
out="$("$ORCH" agent sync 2>&1)"; st=$?
assert_status "sync with an exclude file it cannot append to exits non-zero" "$st" 1
assert_contains "naming the exclude file's path in its own message" "$out" "to the git exclude file .git/info/exclude"
assert_eq "and holding exactly one orch: line" "$(printf '%s\n' "$out" | grep -c '^orch: ')" "1"
assert_not_contains "and no agent sync wrapper message" "$out" "agent sync: cannot add"
rm -rf .git/info/exclude
cd "$as_main" || exit 1
unset -f as_exclude as_copies
unset as_dir as_marker as_plugin
restore_suite_env
