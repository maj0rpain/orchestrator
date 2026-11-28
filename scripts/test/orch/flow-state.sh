# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- the Flow state module, sourced alone -----------------------------------
# flow-state.sh is sourced by the hooks, which have no die, no ROOT and no
# STATE: each case runs it alone in a clean bash -c under set -u, outside any
# git repo, so a reference to any of them on a path exercised here fails.
echo
echo "the Flow state module, sourced alone"
fs_module="${ORCH%/*}/flow-state.sh"
fs_dir="$(mktemp -d)"
# fs_run <code>: runs <code> with the module sourced, in fs_dir, in a clean
# environment; prints its stdout and stderr together and then its status as
# the last line.
fs_run() {
  ( cd "$fs_dir" && env -i PATH="$SUITE_PATH" HOME="$SUITE_HOME" FS_MODULE="$fs_module" \
      bash --noprofile --norc -c 'set -u; source "$FS_MODULE"; '"$1"' ; echo "status $?"' 2>&1 )
}
assert_eq "it runs outside any git repo" \
  "$(fs_run 'git rev-parse --show-toplevel >/dev/null 2>&1')" "status 128"
assert_eq "with no die, ROOT or STATE" \
  "$(fs_run 'type die >/dev/null 2>&1 || [ -n "${ROOT+x}${STATE+x}" ]')" "status 1"
assert_eq "flow_state_file prints the state file under a root" \
  "$(fs_run 'flow_state_file /r')" "/r/.orchestrator/state.json
status 0"
assert_eq "flow_state_file for a root of / is /.orchestrator/state.json" \
  "$(fs_run 'flow_state_file /')" "/.orchestrator/state.json
status 0"
assert_eq "flow_state_file strips one trailing / from a root" \
  "$(fs_run 'flow_state_file /r/')" "/r/.orchestrator/state.json
status 0"
printf 'not json' >"$fs_dir/invalid.json"
printf '[1]' >"$fs_dir/array.json"
printf '{"slug":"s","iteration":null,"budget":null,"host_fallbacks":false}' >"$fs_dir/read.json"
for pair in slug:s iteration:0 redo_count:0 budget: flake_rerun_used:false host_fallbacks:false; do
  assert_eq "flow_state_get reads ${pair%%:*} as '${pair#*:}'" \
    "$(fs_run "flow_state_get read.json ${pair%%:*}")" "${pair#*:}
status 0"
done
assert_eq "flow_state_get returns 1 for a key outside the table, printing nothing" \
  "$(fs_run 'flow_state_get read.json bogus')" "status 1"
# flow_state_get_many: one jq reads every named key.
printf '{"slug":"s","iteration":null,"budget":null,"host_fallbacks":false,"issue":7}' >"$fs_dir/many.json"
assert_eq "flow_state_get_many reads several keys at once" \
  "$(fs_run 'flow_state_get_many many.json a=slug b=issue; echo "$a $b"')" "s 7
status 0"
assert_eq "null and missing keys read as defaults and a stored false stays false" \
  "$(fs_run 'flow_state_get_many many.json a=iteration b=redo_count c=host_fallbacks d=budget; echo "$a|$b|$c|$d"')" "0|0|false|
status 0"
assert_eq "out-variables named key, file, rc and val each get their own value" \
  "$(fs_run 'flow_state_get_many many.json key=slug file=issue rc=iteration val=host_fallbacks; echo "$key $file $rc $val"')" "s 7 0 false
status 0"
assert_eq "out-variables named like the check's own locals each get their own value" \
  "$(fs_run 'flow_state_get_many many.json __fsrma_var=slug __fsrma_key=issue __fsrma_def=iteration __fsrma_k=host_fallbacks __fsrma_d=redo_count; echo "$__fsrma_var $__fsrma_key $__fsrma_def $__fsrma_k $__fsrma_d"')" "s 7 0 false 0
status 0"
printf '{"slug":"a\\tb\\nc\\\\d"}' >"$fs_dir/bytes.json"
assert_eq "tab, newline and backslash round-trip byte for byte" \
  "$(fs_run 'flow_state_get_many bytes.json v=slug; printf "%s" "$v" | od -An -c | tr -s " "')" " a \t b \n c \\ d
status 0"
printf '{"slug":"x\\u0000y","issue":"z"}' >"$fs_dir/nul.json"
assert_eq "a NUL is dropped and later keys keep their values" \
  "$(fs_run 'flow_state_get_many nul.json a=slug b=issue; echo "$a $b"')" "xy z
status 0"
assert_eq "an unknown key returns 1, printing nothing and leaving a pre-set variable" \
  "$(fs_run 'a=keep; flow_state_get_many many.json a=bogus; echo "rc=$? $a"')" "rc=1 keep
status 0"
assert_eq "an argument with no = returns 2, assigning nothing" \
  "$(fs_run 'a=keep; flow_state_get_many many.json a=slug slug; echo "rc=$? $a"')" "rc=2 keep
status 0"
assert_eq "an empty variable name returns 2, assigning nothing" \
  "$(fs_run 'a=keep; flow_state_get_many many.json a=slug =slug; echo "rc=$? $a"')" "rc=2 keep
status 0"
printf 'null' >"$fs_dir/null.json"
printf '{"slug":"s"} trailing' >"$fs_dir/trailing.json"
: >"$fs_dir/empty.json"
for f in absent invalid array null trailing empty; do
  assert_eq "flow_state_get_many on a $f file returns 1, assigning nothing" \
    "$(fs_run "a=keep; flow_state_get_many $f.json a=slug 2>/dev/null; echo \"rc=\$? \$a\"")" "rc=1 keep
status 0"
done
fs_jq_usage_error_bin="$(fails_bin jq '*' 2 'jq: usage error')"
assert_eq "flow_state_get_many returns 1 when jq exits 2, passing its text through" \
  "$(fs_run "PATH='$fs_jq_usage_error_bin':\$PATH; a=keep; flow_state_get_many many.json a=slug; echo \"rc=\$? \$a\"")" "jq: usage error
rc=1 keep
status 0"
# A fake jq writing records by hand: every value but no sentinel, a wrong
# sentinel, and a record after the sentinel are each a failed read.
fs_fakebin="$(mktemp -d)"
for fs_fake in 'nosentinel|s\0' 'wrongsentinel|s\0bogus\0' 'trailing|s\0flow-state-end\0extra\0'; do
  printf '#!/bin/sh\nprintf "%s"\n' "${fs_fake#*|}" >"$fs_fakebin/jq"
  chmod +x "$fs_fakebin/jq"
  assert_eq "flow_state_get_many returns 1, assigning nothing, on a jq giving ${fs_fake%%|*}" \
    "$(fs_run "PATH='$fs_fakebin':\$PATH; a=keep; flow_state_get_many many.json a=slug; echo \"rc=\$? \$a\"")" "rc=1 keep
status 0"
done
rm -rf "$fs_fakebin"
fs_mktempbin="$(counting_bin mktemp)"
fs_rmbin="$(counting_bin rm)"
fs_jqbin="$(counting_bin jq)"
fs_run "PATH=$fs_jqbin:$fs_mktempbin:$fs_rmbin:\$PATH; flow_state_get_many many.json a=slug b=issue c=phase d=pr e=budget" >/dev/null
assert_eq "flow_state_get_many starts no mktemp" "$(counting_starts "$fs_mktempbin" mktemp)" "0"
assert_eq "and no rm" "$(counting_starts "$fs_rmbin" rm)" "0"
assert_eq "a five-key read starts exactly one jq" "$(counting_starts "$fs_jqbin" jq)" "1"
assert_eq "flow_state_key_field returns 2 for an unknown column, printing nothing" \
  "$(fs_run 'flow_state_key_field slug bogus')" "status 2"
assert_eq "flow_state_key_field returns 1 for an unknown key, printing nothing" \
  "$(fs_run 'flow_state_key_field bogus default')" "status 1"
assert_eq "flow_state_key_field prints a key's column" \
  "$(fs_run 'flow_state_key_field iteration default')" "0
status 0"
assert_ne "flow_state_get on an unparseable file returns non-zero" \
  "$(fs_run 'flow_state_get invalid.json slug >/dev/null 2>&1' | tail -n 1)" "status 0"
printf '{"phase":"done"}' >"$fs_dir/done.json"
printf '{"phase":"review"}' >"$fs_dir/review.json"
for pair in absent:1 done:1 review:0 invalid:0; do
  assert_eq "flow_state_active answers ${pair#*:} for a ${pair%%:*} file, printing nothing" \
    "$(fs_run "flow_state_active ${pair%%:*}.json")" "status ${pair#*:}"
done
# The golden state.json files the Python Flow state reader's tests read too,
# with the same expected values: each under read/ reads every key its
# .expected file lists, <key><TAB><value> a line, as that file says, and each
# under refused/ is a failed read, assigning nothing.
fs_golden="${ORCH%/*}/orch_py/tests/flow_state"
# shellcheck disable=SC2016 # expanded by fs_run's bash, GOLDEN set before it
fs_golden_read='fs_args=() fs_keys=()
while read -r k _; do fs_keys+=("$k"); fs_args+=("v_$k=$k"); done <"${GOLDEN%.json}.expected"
if flow_state_get_many "$GOLDEN" "${fs_args[@]}"; then
  for k in "${fs_keys[@]}"; do v="v_$k"; printf "%s\t%s\n" "$k" "${!v}"; done
fi'
for fs_file in "$fs_golden"/read/*.json; do
  fs_name="${fs_file##*/}"
  assert_eq "flow_state_get_many reads the golden ${fs_name%.json} file as its expected file says" \
    "$(fs_run "GOLDEN=$(printf '%q' "$fs_file"); $fs_golden_read")" "$(cat "${fs_file%.json}.expected")
status 0"
done
for fs_file in "$fs_golden"/refused/*.json; do
  fs_name="${fs_file##*/}"
  assert_eq "flow_state_get_many on the golden ${fs_name%.json} file returns 1, assigning nothing" \
    "$(fs_run "a=keep; flow_state_get_many $(printf '%q' "$fs_file") a=slug 2>/dev/null; echo \"rc=\$? \$a\"")" "rc=1 keep
status 0"
done
# A state.json the Python Flow state module wrote - the seed, created, its
# spec phase, then a multi-key write, as the Python nouns write it - reads
# through the readers the hooks use.
fs_py="$fs_dir/python-seeded"
mkdir -p "$fs_py"
python3 -c '
import sys
sys.path.insert(0, sys.argv.pop(1))
from orch.flow_state import flow_state_create, flow_state_seed, phase_write, state_write_many
assert flow_state_create(sys.argv[1], flow_state_seed("py-seed", "7", "rélease/2.0"))
phase_write(sys.argv[1], "spec")
state_write_many(sys.argv[1], [("branch", "feat/x", True), ("iteration", "2")])
' "${ORCH%/*}/orch_py" "$fs_py/state.json" </dev/null
assert_eq "flow_state_get_many reads every key of a Python-written file" \
  "$(fs_run 'flow_state_get_many python-seeded/state.json a=slug b=phase c=issue d=base e=branch f=iteration g=host_fallbacks h=pr; echo "$a|$b|$c|$d|$e|$f|$g|$h"')" \
  "py-seed|spec|7|rélease/2.0|feat/x|2|true|
status 0"
assert_eq "flow_state_get reads one key of it" \
  "$(fs_run 'flow_state_get python-seeded/state.json base')" "rélease/2.0
status 0"
assert_eq "flow_state_active answers yes for it" \
  "$(fs_run 'flow_state_active python-seeded/state.json')" \
  "status 0"
restore_suite_env
