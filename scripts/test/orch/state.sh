# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# The documented triage-label table, in the shape the setup skill writes it:
# a header row, a separator row, and backticked labels in the second column.
labels_doc() {
  writeln '# Triage Labels' '' \
          '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
          '| -------------------------- | -------------------- | ----------- |' \
          '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
          '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' \
          '' 'Edit the right-hand column to match whatever vocabulary you use.' >"$1"
}

# healthy_repo: a new_repo set up as the setup skill leaves one - a GitHub
# origin, a triage-labels doc, a full verification line, the orchestrator's
# folders git-excluded - with the fixture gh, CLAUDE_PLUGIN_ROOT set and a
# throwaway HOME, cwd inside it: fresh_flow's repo.
healthy_repo() {
  new_repo >/dev/null
  git remote set-url origin https://github.com/acme/widgets.git
  labels_doc docs/agents/triage-labels.md
  # The full verification line a set-up repo names.
  writeln 'Full verification: true test' >CLAUDE.md
  git add CLAUDE.md && git commit -qm 'instructions'
  printf '%s\n' ".orchestrator/" ".scratch/" >>.git/info/exclude
  gh_fixture
  export CLAUDE_PLUGIN_ROOT="$PWD"
  # A throwaway HOME, so nothing under the real one - a skill store, a cache -
  # reaches the commands a section runs.
  seeded_home
}

# fresh_flow <slug>: a section's own starting point - a healthy_repo with a
# flow named <slug> just started in it, at the spec phase, cwd inside it. A
# section that needs a later phase arranges it with state_fixture.
fresh_flow() { healthy_repo; "$ORCH" init "$1" >/dev/null; }

# state_truncate [bytes]: cuts the checkout's state file to its first <bytes>
# bytes (40 by default), leaving a file that does not parse as JSON. The cut
# goes through a temp file beside it, moved back over it.
state_truncate() {
  local file
  file="$(flow_state_file "$(git rev-parse --show-toplevel)")"
  head -c "${1:-40}" "$file" >"$file.cut" && mv "$file.cut" "$file"
}

# assert_state_unreadable <label> <want-status> <out> <st>: asserts a command
# run on a truncated state.json (see state_truncate) exited <st> as
# <want-status>, printed the shared unreadable line in <out>, and leaked no jq
# parse error. The one place tests spell that line.
assert_state_unreadable() {
  assert_status "$1 exits $2" "$4" "$2"
  assert_contains "$1 prints the unreadable line" "$3" \
    "orch: state.json cannot be read - run orch.sh doctor --flow"
  assert_not_contains "$1 leaks no jq text" "$3" "parse error"
}

# fake_pr_draft <n>: seeds PR #n as a draft.
fake_pr_draft() { : >"$ORCH_GH_FAKE_STORE/prs/$1/draft"; }

# fake_pr_draft_of <n>: whether the store's PR #n is a draft, yes or no.
fake_pr_draft_of() { [ -f "$ORCH_GH_FAKE_STORE/prs/$1/draft" ] && echo yes || echo no; }

# fake_checks <n> <required|all> <answer>...: scripts PR #n's checks for the
# scope, answered one per call, the last repeating: green, failing (build
# fails, Actions run 4242; lint passes), cancel (build cancelled, run 5150),
# external (a failing outside-CI check, ext-ci, ahead of build failing in run
# 4242), tworuns (build run 4242, test run 4343), onerun (build and test both
# in run 4242), mixed (build run 4242, then failing ext-ci), comma (one
# failing check named `build (linux, x64)`), pending, none (no checks
# reported) or boom (a connection error). An unscripted scope has no checks.
fake_checks() {
  local d="$ORCH_GH_FAKE_STORE/checks/$1" scope="$2"
  shift 2
  mkdir -p "$d"
  printf '%s\n' "$@" >"$d/$scope"
  rm -f "$d/$scope.n"
}

# complete_handoff <file>: a complete handoff at <file>, holding every section
# the phase table requires for its name - read from the missing sections
# `orch.sh handoff validate` reports for an empty file of that name, outside
# autopilot, so the fixture cannot drift from the validator - each with a
# placeholder body, plus Host fallbacks whatever the state says. On a name the
# table does not hold, validate reports no section, and it fails and writes no
# file.
complete_handoff() {
  local dir empty headings heading
  dir="$(mktemp -d)" || return 1
  empty="$dir/${1##*/}"
  : >"$empty"
  headings="$(env -u ORCH_AUTOPILOT "$ORCH" handoff validate "$empty" 2>/dev/null \
    | sed -n 's/^FAIL  missing section: //p')"
  rm -rf "$dir"
  [ -n "$headings" ] || return 1
  grep -qxF '## Host fallbacks' <<<"$headings" || headings="$headings"$'\n''## Host fallbacks'
  while IFS= read -r heading; do
    writeln "$heading" "Placeholder for ${heading#\#\# }." ''
  done <<<"$headings" >"$1"
}

# --- a flow from before the budget shipped ----------------------------------
# An in-flight flow carries whatever state the version that started it wrote:
# no `budget`, no `loop`, no `flake_rerun_used`. Failing on any absence would
# strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the budget shipped"
fresh_flow legacy
state_fixture_drop budget loop flake_rerun_used
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for _ in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and it runs the default budget" "$st" 1
assert_contains "of five" "$out" "budget of 5 iterations"

state_fixture phase review
complete_handoff "$("$ORCH" handoff path spec)"
complete_handoff "$("$ORCH" handoff path implement)"
complete_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0

# ci and ready need a PR, which a flow this old still records the same way.
state_fixture pr 3
fake_github
fake_pr 3 open orch/legacy main
fake_pr_draft 3
fake_checks 3 all green
out="$(ORCH_CI_GRACE=0.2 ORCH_CI_INTERVAL=0.05 "$ORCH" review ci 2>&1)"; st=$?
assert_status "review ci reads its PR from a state with no budget key" "$st" 0
assert_first_line "and classifies it" "$out" "green"
assert_eq "review ready marks the PR and finishes the flow" \
  "$("$ORCH" review ready)" "3"
assert_eq "recording done as it goes" "$("$ORCH" state get phase)" "done"
assert_eq "with the PR no longer a draft" "$(fake_pr_draft_of 3)" "no"
restore_suite_env

# --- doctor --flow on a state.json lacking keys -----------------------------
# A state file written by an older flow lacks keys a fresh one seeds; doctor
# --flow still passes it.
echo
echo "doctor --flow on a sparse state.json"
fresh_flow sparse
state_fixture_drop iteration redo_count host_fallbacks flake_rerun_used budget
complete_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow passes a state file lacking those keys" "$st" 0
restore_suite_env

# --- state.json schema ------------------------------------------------------
# What a fresh init writes, pinned: the raw file holds exactly these keys, in
# this order, with these seeds. A change to the state-key schema that alters
# state.json fails here.
echo
echo "state.json schema"
fresh_flow schema
assert_eq "slug, base, created and updated are non-empty strings" \
  "$(jq -c '[.slug, .base, .created, .updated] | map(type == "string" and . != "")' .orchestrator/state.json)" \
  "[true,true,true,true]"
assert_eq "state.json holds the pinned keys, order and seeds" \
  "$(jq -c '.slug = "S" | .base = "B" | .created = "C" | .updated = "U"' .orchestrator/state.json)" \
  '{"slug":"S","phase":"spec","issue":null,"base":"B","branch":null,"pr":null,"base_sha":null,"budget":null,"iteration":0,"flake_rerun_used":false,"redo_count":0,"host_fallbacks":true,"created":"C","updated":"U"}'
restore_suite_env

# --- state_fixture on a corrupt state.json ---------------------------------
# A fixture arranging state on a file jq cannot parse fails, so a failed
# arrangement fails its test rather than leaving a state the test did not ask
# for, and leaves the file as it found it, with no temp file left beside it.
# The invalid JSON is written raw: no writer can produce it.
echo
echo "state_fixture on a corrupt state.json"
fresh_flow corrupt
printf 'not json\n' >.orchestrator/state.json
before_ls="$(ls -A .orchestrator)"
state_fixture budget 3 2>/dev/null; st=$?
assert_ne "state_fixture on an unparseable state.json returns non-zero" "$st" 0
assert_eq "and leaves it untouched" "$(cat .orchestrator/state.json)" "not json"
assert_eq "with nothing new beside it, after the fixture" "$(ls -A .orchestrator)" "$before_ls"
restore_suite_env

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
printf '{"slug":"s"}' >"$fs_dir/write.json"
for pair in null:null true:boolean false:boolean 42:number abc:string 4a:string ':string'; do
  assert_eq "flow_state_write stores '${pair%%:*}' as a JSON ${pair#*:}" \
    "$(fs_run "flow_state_write write.json budget '${pair%%:*}' && jq -r '.budget | type' write.json")" \
    "${pair#*:}
status 0"
done
for v in null true 42 abc; do
  assert_eq "flow_state_write_string stores '$v' as a JSON string" \
    "$(fs_run "flow_state_write_string write.json budget '$v' && jq -c '.budget' write.json")" \
    "\"$v\"
status 0"
done
assert_eq "a write leaves the other keys as they were" "$(jq -r .slug "$fs_dir/write.json")" "s"
assert_contains "a write stamps updated with a UTC timestamp" \
  "$(fs_run 'flow_state_write write.json budget 1 && jq -r .updated write.json' | sed -n 1p)" "Z"
assert_eq "a write of updated itself sticks" \
  "$(fs_run 'flow_state_write write.json updated SENTINEL && flow_state_get write.json updated')" \
  "SENTINEL
status 0"
before_ls="$(ls -A "$fs_dir")"
assert_ne "a write to an unparseable file returns non-zero" \
  "$(fs_run 'flow_state_write invalid.json budget 1 2>/dev/null' | tail -n 1)" "status 0"
assert_eq "and leaves the file untouched" "$(cat "$fs_dir/invalid.json")" "not json"
assert_eq "with nothing new in its directory" "$(ls -A "$fs_dir")" "$before_ls"
assert_ne "a write to an absent file returns non-zero" \
  "$(fs_run 'flow_state_write absent.json budget 1 2>/dev/null' | tail -n 1)" "status 0"
assert_eq "and creates nothing" "$(ls -A "$fs_dir")" "$before_ls"
printf '{"phase":"done"}' >"$fs_dir/done.json"
printf '{"phase":"review"}' >"$fs_dir/review.json"
for pair in absent:1 done:1 review:0 invalid:0; do
  assert_eq "flow_state_active answers ${pair#*:} for a ${pair%%:*} file, printing nothing" \
    "$(fs_run "flow_state_active ${pair%%:*}.json")" "status ${pair#*:}"
done
printf '{"slug":"m","budget":1}' >"$fs_dir/many.json"
assert_eq "flow_state_write_many sets several keys, coerced, and stamps updated" \
  "$(fs_run 'flow_state_write_many many.json budget 5 pr null phase review flake_rerun_used true && jq -c ".updated |= type" many.json')" \
  '{"slug":"m","budget":5,"updated":"string","pr":null,"phase":"review","flake_rerun_used":true}
status 0'
cp "$fs_dir/many.json" "$fs_dir/many.before"
before_ls="$(ls -A "$fs_dir")"
assert_eq "flow_state_write_many refuses a key with no value" \
  "$(fs_run 'flow_state_write_many many.json budget 1 pr')" "status 2"
assert_eq "and leaves the file untouched" "$(cat "$fs_dir/many.json")" "$(cat "$fs_dir/many.before")"
assert_eq "with nothing new in its directory" "$(ls -A "$fs_dir")" "$before_ls"
assert_ne "flow_state_write_many returns non-zero on a failed replace after the temp file" \
  "$(fs_run 'flow_state_write_many invalid.json budget 1 2>/dev/null' | tail -n 1)" "status 0"
assert_eq "and leaves that file untouched" "$(cat "$fs_dir/invalid.json")" "not json"
assert_eq "with no temp file beside it" "$(ls -A "$fs_dir")" "$before_ls"
printf '{"slug":"s","budget":1}' >"$fs_dir/str.json"
assert_eq "flow_state_write_many --string stores digits and true as strings beside coerced values" \
  "$(fs_run 'flow_state_write_many str.json --string base_sha 12345 --string pr true budget 7 flake_rerun_used true && jq -c "del(.updated)" str.json')" \
  '{"slug":"s","budget":7,"base_sha":"12345","pr":"true","flake_rerun_used":true}
status 0'
cp "$fs_dir/str.json" "$fs_dir/str.before"
assert_eq "flow_state_write_many refuses a dangling --string" \
  "$(fs_run 'flow_state_write_many str.json budget 2 --string')" "status 2"
assert_eq "and leaves the file untouched for it" "$(cat "$fs_dir/str.json")" "$(cat "$fs_dir/str.before")"
before_ls="$(ls -A "$fs_dir")"
tonumber_fails_bin="$(fails_bin jq '*tonumber*')"
tonumber_usage_error_bin="$(fails_bin jq '*tonumber*' 2 'jq: usage error')"
for jq_status in 1 2; do
  case "$jq_status" in 1) jq_bin="$tonumber_fails_bin" ;; *) jq_bin="$tonumber_usage_error_bin" ;; esac
  out="$(fs_run "PATH='$jq_bin':\$PATH; flow_state_write_many str.json budget 5")"
  assert_eq "flow_state_write_many fails with a status other than 0 and 2 on a value that will not convert, jq exiting $jq_status" \
    "$(case "${out##*status }" in 0|2) echo "$out" ;; *) echo ok ;; esac)" "ok"
  assert_eq "printing nothing else, jq's own error included, jq exiting $jq_status" "${out%status *}" ""
  assert_eq "and leaves the file untouched for that, jq exiting $jq_status" "$(cat "$fs_dir/str.json")" "$(cat "$fs_dir/str.before")"
  assert_eq "with no temp file beside it for that, jq exiting $jq_status" "$(ls -A "$fs_dir")" "$before_ls"
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
# A state.json Python init wrote - the seed, created, then its spec phase
# written, by orch/flow_state.py - is one bash changes from then on:
# flow_state_write_many rewrites it in one replace, keeping its key order and
# leaving no temp file, and the readers the hooks use read it through jq.
fs_py="$fs_dir/python-seeded"
mkdir -p "$fs_py"
python3 -c '
import sys
sys.path.insert(0, sys.argv.pop(1))
from orch.flow_state import flow_state_create, flow_state_seed, phase_write
assert flow_state_create(sys.argv[1], flow_state_seed("py-seed", "7", "rélease/2.0"))
phase_write(sys.argv[1], "spec")
' "${ORCH%/*}/orch_py" "$fs_py/state.json" </dev/null
assert_eq "flow_state_write_many rewrites a Python-written state.json" \
  "$(fs_run 'flow_state_write_many python-seeded/state.json branch feat/x iteration 2')" "status 0"
assert_eq "keeping its keys in table order, with no temp file beside it" \
  "$(fs_run 'jq -r "keys_unsorted | join(\" \")" python-seeded/state.json; ls -A python-seeded')" \
  "slug phase issue base branch pr base_sha budget iteration flake_rerun_used redo_count host_fallbacks created updated
state.json
status 0"
assert_eq "flow_state_get_many reads every key of the rewritten file" \
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

# --- the shared and own-checkout readers on a truncated state.json -----------
# state_get_many_in guards: an unreadable file returns 2 and prints nothing, a
# readable one reads as ever. state_get stays unguarded: jq's text comes
# through.
echo
echo "state readers on an unreadable state.json"
fresh_flow readers
rd_file="$PWD/.orchestrator/state.json"
out="$(sourced_orch state_get_many_in "$rd_file" a=nonsense 2>&1)"; st=$?
assert_status "state_get_many_in of an unknown key dies" "$st" 1
assert_eq "as an unknown state key" "$out" "orch: unknown state key: nonsense"
out="$(sourced_orch state_get_many_in "$rd_file" nokey 2>&1)"; st=$?
assert_status "state_get_many_in of a malformed argument dies" "$st" 1
assert_eq "as a malformed state read" "$out" "orch: malformed state read: nokey"
out="$(sourced_orch state_get_many a=nonsense 2>&1)"
assert_eq "state_get_many dies as an unknown state key" "$out" "orch: unknown state key: nonsense"
out="$(sourced_orch state_get_many =phase 2>&1)"
assert_eq "state_get_many dies as a malformed state read" "$out" "orch: malformed state read: =phase"
out="$(sourced_orch_script 'state_get_many_in "$1" key=slug file=phase; echo "$key $file"' "$rd_file" 2>&1)"
assert_eq "state_get_many_in reads a readable file's keys" "$out" "readers spec"
out="$(sourced_orch_script 'state_get_many key=slug file=phase rc=issue val=pr; echo "$key $file $rc $val"' 2>&1)"
assert_eq "state_get_many assigns out-variables named like common locals" "$out" "readers spec  "
rd_jq="$(counting_bin jq)"
PATH="$rd_jq:$PATH" sourced_orch state_get_many_in "$rd_file" a=slug b=phase c=issue d=pr e=budget >/dev/null
assert_eq "state_get_many_in reading five keys starts exactly one jq" "$(counting_starts "$rd_jq" jq)" "1"
state_truncate
out="$(sourced_orch state_get_many_in "$rd_file" a=phase 2>&1)"; st=$?
assert_status "state_get_many_in on a truncated file returns 2" "$st" 2
assert_eq "and prints nothing" "$out" ""
restore_suite_env

# --- the entry read ----------------------------------------------------------
# require_state_read, the one-jq entry read.
echo
echo "require_state_read"
fresh_flow entry
rs_file="$PWD/.orchestrator/state.json"
rs_jq="$(counting_bin jq)"
out="$(sourced_orch_script 'require_state_read key=slug file=phase rc=issue; echo "$key $file [$rc]"' 2>&1)"
assert_eq "require_state_read assigns several keys with defaults" "$out" "entry spec []"
PATH="$rs_jq:$PATH" sourced_orch require_state_read a=slug b=phase c=issue d=pr e=budget >/dev/null
assert_eq "require_state_read of five keys starts exactly one jq" "$(counting_starts "$rs_jq" jq)" "1"
out="$(sourced_orch require_state_read a=nonsense 2>&1)"; st=$?
assert_status "require_state_read dies on a key outside the table" "$st" 1
assert_eq "as an unknown state key" "$out" "orch: unknown state key: nonsense"
out="$(sourced_orch require_state_read nokey 2>&1)"
assert_eq "and on a malformed argument" "$out" "orch: malformed state read: nokey"
rm -f "$rs_file"
out="$(sourced_orch require_state_read a=phase 2>&1)"; st=$?
assert_status "require_state_read with no state file dies" "$st" 1
assert_contains "saying there is no active flow" "$out" "orch: no active flow"
out="$(sourced_orch require_state_read die2 a=phase 2>&1)"; st=$?
assert_status "and exits 2 through die2" "$st" 2
fresh_flow entry2
state_truncate
out="$(sourced_orch require_state_read a=phase 2>&1)"; st=$?
assert_state_unreadable "require_state_read" 1 "$out" "$st"
out="$(sourced_orch require_state_read die2 a=phase 2>&1)"; st=$?
assert_state_unreadable "require_state_read through die2" 2 "$out" "$st"
restore_suite_env
