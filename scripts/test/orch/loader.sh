# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# orch_modules_list: every module of scripts/orch, one name per line, in
# C-locale order: what orch_load_all and a sourced orch.sh load.
orch_modules_list() {
  local f n
  for f in "$PLUGIN_ROOT/scripts/orch"/*.sh; do
    n="${f##*/}"; n="${n%.sh}"
    case "$n" in common|loader) ;; *) echo "$n" ;; esac
  done | LC_ALL=C sort
}

# --- orch_load ----------------------------------------------------------------
echo
echo "orch_load"
loader_dir="$PLUGIN_ROOT/scripts/orch"
# loader_run <script>: runs it in a fresh bash that has sourced common.sh and
# loader.sh, setting out and status.
loader_run() {
  out="$(bash -c 'source "$1/common.sh"; source "$1/loader.sh"; '"$1" _ "$loader_dir" 2>&1)" && status=0 || status=$?
}
trace="$(mktemp)"

loader_run 'orch_load issue; declare -F cmd_issue >/dev/null && echo defined'
assert_eq "orch_load sources a module" "$out" "defined"

loader_run 'orch_load issue; unset -f cmd_issue; orch_load issue; declare -F cmd_issue >/dev/null || echo not-resourced'
assert_eq "a second orch_load of a module does nothing" "$out" "not-resourced"

loader_run 'orch_load nonesuch; echo reached'
assert_status "an unknown module stops with exit 1" "$status" 1
assert_eq "and says which" "$out" "orch: orch_load: no module nonesuch"

loader_run 'orch_load common'
assert_eq "common.sh is no module" "$out" "orch: orch_load: no module common"

ORCH_LOAD_TRACE="$trace" loader_run 'orch_load issue; (orch_load issue-timeline)'
assert_eq "each load appends the module and its subshell depth" \
  "$(cat "$trace")" "$(printf 'issue 0\nissue-timeline 1')"

: >"$trace"
loader_run 'orch_load issue'
assert_eq "unset, the trace writes nothing" "$(cat "$trace")" ""

ORCH_LOAD_TRACE=/nonexistent/dir/trace loader_run 'orch_load issue; echo done'
assert_eq "an unwritable trace path changes neither output" "$out" "done"
assert_status "nor the exit status" "$status" 0

: >"$trace"
ORCH_LOAD_TRACE="$trace" loader_run 'orch_load_all'
assert_eq "orch_load_all loads every module in C-locale name order" \
  "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
assert_eq "issue loads before issue-timeline" \
  "$(awk '$1 ~ /^issue/ {print $1}' "$trace" | sed -n 1,2p | tr '\n' ' ')" "issue issue-timeline "

assert_eq "orch.sh sources no module but common.sh and loader.sh" \
  "$(grep -E '^[[:space:]]*(source|\.) ' "$PLUGIN_ROOT/scripts/orch.sh" | grep -cE 'orch/' | tr -d ' ')" "2"

# loader.sh, like common.sh, names no function a module defines.
loader_upcalls() {
  local defs=() f
  for f in "$1"/orch/*.sh; do
    case "$(basename "$f")" in common.sh|loader.sh|gh.sh) continue ;; esac
    defs+=("$f")
  done
  layer_calls "${defs[@]}" -- "$1/orch/loader.sh" "$1/orch/common.sh"
}
assert_eq "common.sh and loader.sh name no function a module defines" \
  "$(loader_upcalls "$PLUGIN_ROOT/scripts")" ""
rm -f "$trace"

# --- on-demand loading --------------------------------------------------------
echo
echo "on-demand loading"
new_repo >/dev/null
loader_dir="$PLUGIN_ROOT/scripts/orch"
trace="$(mktemp)"
# run_traced <args>: orch.sh as a command with the load trace on.
run_traced() { : >"$trace"; ORCH_LOAD_TRACE="$trace" bash "$ORCH" "$@" >/dev/null 2>&1 || true; }

run_traced state get phase
assert_eq "state get loads the state module and never the autopilot's" \
  "$(awk '$1 == "autopilot"' "$trace" | wc -l | tr -d ' ')" "0"
assert_contains "state get loads the state module" "$(cat "$trace")" "state 0"
assert_eq "no module loads twice at depth 0" \
  "$(awk '$2 == 0 {print $1}' "$trace" | sort | uniq -d)" ""
run_traced nonesuch-command
assert_eq "an unknown command loads no module" "$(cat "$trace")" ""
run_traced status
assert_eq "a load from a subshell records a depth above 0" \
  "$(awk '$2 > 0 {print $1}' "$trace" | sed -n 1p)" "checkout"
out="$(bash "$ORCH" status 2>&1)"; status=$?
out2="$(ORCH_LOAD_TRACE=/nonexistent/dir/trace bash "$ORCH" status 2>&1)"; status2=$?
assert_eq "an unwritable ORCH_LOAD_TRACE leaves the command's output as it is" "$out2" "$out"
assert_status "and its exit status" "$status2" "$status"

# lazy_run <script>: orch.sh sourced on demand, then <script>, traced.
lazy_run() { : >"$trace"; ORCH_LOAD_TRACE="$trace" bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; shift; '"$1" _ "$ORCH" 2>&1; }

lazy_run '(spec_review_lens_known consistency consistency); true'
assert_eq "a stub called in a subshell loads its module there only" "$(cat "$trace")" "spec-review 1"

# A stub passes its arguments and returns the real function's status.
out="$(lazy_run 'st=0; spec_review_lens_known consistency || st=$?; echo "st=$st"')"
out2="$(bash -c 'source "$1"; shift; st=0; spec_review_lens_known consistency || st=$?; echo "st=$st"' _ "$ORCH" 2>&1)"
assert_eq "a stub passes its arguments and returns the real function's status" "$out" "$out2"
assert_contains "for a known lens" "$out" "st=0"
out="$(lazy_run 'st=0; spec_review_lens_known nonesuch || st=$?; echo "st=$st"')"
assert_contains "and returns a failing status" "$out" "st=1"

# A stub whose module no longer defines the function: one the function moved
# to loads and the call goes on; with none, the command stops.
lazy_dir="$(mktemp -d)/scripts"; mkdir -p "${lazy_dir%/scripts}"; cp -R "$PLUGIN_ROOT/scripts" "${lazy_dir%/scripts}/"
printf '%s\n' 'zz_fn() { echo from-old; }' >"$lazy_dir/orch/zz-old.sh"
printf '%s\n' 'zz_other() { :; }' >"$lazy_dir/orch/zz-new.sh"
out="$(bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; printf "%s\n" "zz_other() { :; }" >"$2"; printf "%s\n" "zz_fn() { echo from-new; }" >"$3"; zz_fn' _ "$lazy_dir/orch.sh" "$lazy_dir/orch/zz-old.sh" "$lazy_dir/orch/zz-new.sh" 2>&1)"
assert_eq "a function moved to another module loads that module and the call goes on" "$out" "from-new"
printf "%s\n" 'zz_fn() { echo from-old; }' >"$lazy_dir/orch/zz-old.sh"
printf "%s\n" 'zz_other() { :; }' >"$lazy_dir/orch/zz-new.sh"
out="$(bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; printf "%s\n" "zz_other() { :; }" >"$2"; zz_fn' _ "$lazy_dir/orch.sh" "$lazy_dir/orch/zz-old.sh" 2>&1)"; status=$?
assert_status "a stub whose function no module defines stops with exit 1" "$status" 1
assert_eq "and says so" "$out" "orch: zz_fn is in the stub table but no module defines it"
rm -rf "${lazy_dir%/scripts}"

# Sourced, every module loads, no stub table or cache is written, and a
# function replaced after the source stays replaced.
src_run() { : >"$trace"; ORCH_LOAD_TRACE="$trace" bash -c "$1" _ "$ORCH" 2>&1; }
src_run 'source "$1"'
assert_eq "sourced plainly, every module loads" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
out="$(src_run 'source "$1"; cmd_state() { echo replaced; }; cmd_state')"
assert_eq "a function replaced after source stays replaced" "$out" "replaced"
out="$(src_run 'source "$1"; declare -f cmd_state | grep -c orch_stub')"
assert_eq "sourced plainly, no function is a stub" "$out" "0"

src_run 'ORCH_SOURCE_LAZY=1; source "$1"' >/dev/null
assert_eq "a plain ORCH_SOURCE_LAZY=1 loads on demand" "$(awk '$1 == "autopilot"' "$trace" | wc -l | tr -d ' ')" "0"
out="$(src_run 'ORCH_SOURCE_LAZY=1; source "$1"; echo "${ORCH_SOURCE_LAZY-unset}"')"
assert_eq "and is unset after the source" "$out" "unset"
out="$(src_run 'export ORCH_SOURCE_LAZY=1; source "$1"; echo "${ORCH_SOURCE_LAZY-unset}"')"
assert_eq "an exported ORCH_SOURCE_LAZY=1 is unset after the source" "$out" "unset"
assert_eq "and loads every module" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
out="$(src_run 'ORCH_SOURCE_LAZY=2; source "$1"; echo "${ORCH_SOURCE_LAZY-unset}"')"
assert_eq "a value of 2 is unset after the source" "$out" "unset"
assert_eq "and loads every module" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"

: >"$trace"
ORCH_LOAD_TRACE="$trace" sourced_orch branch_records_base orch/40-flowing || true
assert_eq "sourced_orch loads on demand" "$(awk '$1 == "autopilot"' "$trace" | wc -l | tr -d ' ')" "0"
: >"$trace"
ORCH_LOAD_TRACE="$trace" sourced_orch eval 'true'
assert_eq "sourced_orch eval loads every module" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
: >"$trace"
ORCH_LOAD_TRACE="$trace" sourced_orch_script 'true'
assert_eq "sourced_orch_script loads every module" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
rm -f "$trace"

# --- stub table cache ---------------------------------------------------------
echo
echo "stub table cache"
new_repo >/dev/null
cache_root="$(mktemp -d)"
cache_scripts="$cache_root/copy/scripts"
mkdir -p "$cache_root/copy"
cp -R "$PLUGIN_ROOT/scripts" "$cache_root/copy/"
cache_home="$cache_root/home"
cache_dir="$cache_home/.cache/orchestrator"
mkdir -p "$cache_home"
# cache_cmd <script-dir>: orch.sh over a planted copy with the temporary home,
# setting out and status.
cache_cmd() { out="$(HOME="$cache_home" bash "$1/orch.sh" help 2>&1)" && status=0 || status=$?; }
cache_count() { ls "$cache_dir" 2>/dev/null | wc -l | tr -d ' '; }
cache_file() { printf '%s\n' "$cache_dir"/*.stubs; }
# The output of a run with a home of its own, the one every run must match.
baseline="$(HOME="$(mktemp -d)" bash "$cache_scripts/orch.sh" help 2>&1)"

cache_cmd "$cache_scripts"
assert_status "the first run succeeds" "$status" 0
assert_eq "and builds the cache" "$(cache_count)" "1"
cf="$(cache_file)"
echo "# planted marker" >>"$cf"
touch -d '+1 minute' "$cf"
cache_cmd "$cache_scripts"
assert_status "the second run succeeds" "$status" 0
assert_contains "and reuses the cache" "$(cat "$cf")" "# planted marker"

touch -d '+2 minutes' "$cache_scripts/orch/state.sh"
cache_cmd "$cache_scripts"
assert_eq "a module file newer than the cache rebuilds it" "$(grep -c 'planted marker' "$cf")" "0"
assert_eq "the cache file is mode 600" "$(stat -c %a "$cf" 2>/dev/null || stat -f %Lp "$cf")" "600"

touch -d '+3 minutes' "$cf"
echo 'zz_added() { :; }' >"$cache_scripts/orch/zz-added.sh"
touch -d '+2 minutes' "$cache_scripts/orch/zz-added.sh"
touch -d '+4 minutes' "$cache_scripts/orch"
cache_cmd "$cache_scripts"
assert_contains "an added module rebuilds it" "$(cat "$cf")" "zz_added"
touch -d '+5 minutes' "$cf"
rm "$cache_scripts/orch/zz-added.sh"
touch -d '+6 minutes' "$cache_scripts/orch"
cache_cmd "$cache_scripts"
assert_eq "a removed module rebuilds it" "$(grep -c 'zz_added' "$cf")" "0"

out="$(bash -c 'unset HOME; exec bash "$1/orch.sh" help' _ "$cache_scripts" 2>&1)" && status=0 || status=$?
assert_status "HOME unset still runs the command" "$status" 0
assert_eq "and prints nothing extra" "$out" "$baseline"

if [ "$(id -u)" != 0 ]; then
  rm -f "$cache_dir"/*
  chmod 500 "$cache_dir"
  cache_cmd "$cache_scripts"
  assert_status "an unwritable cache directory still runs the command" "$status" 0
  assert_eq "and prints nothing extra" "$out" "$baseline"
  assert_eq "and leaves no file" "$(cache_count)" "0"
  chmod 700 "$cache_dir"
  cache_cmd "$cache_scripts"
  cf="$(cache_file)"
  chmod 000 "$cf"
  cache_cmd "$cache_scripts"
  assert_status "an unreadable cache file still runs the command" "$status" 0
  assert_eq "and prints nothing extra" "$out" "$baseline"
  chmod 600 "$cf"
fi

# A planted wrong table: a function under the wrong module is rebuilt once and
# the call goes on; a function no module defines stops, naming the cache file.
rm -f "$cache_dir"/*
cache_cmd "$cache_scripts"
cf="$(cache_file)"
sed -i.bak 's/^spec_review_lens_known() { orch_stub spec-review /spec_review_lens_known() { orch_stub issue /' "$cf"; rm -f "$cf.bak"
assert_contains "the planted table names the wrong module" "$(cat "$cf")" "spec_review_lens_known() { orch_stub issue "
touch -d '+10 minutes' "$cf"
out="$(HOME="$cache_home" bash -c 'unset ORCH_SOURCE_LAZY; ORCH_SOURCE_LAZY=1; source "$1/orch.sh"; spec_review_lens_known consistency; echo "st=$?"' _ "$cache_scripts" 2>&1)"
assert_eq "a planted wrong table is rebuilt and the call succeeds" "$out" "st=0"
assert_contains "and the cache holds the rebuilt table" "$(cat "$cf")" "spec_review_lens_known() { orch_stub spec-review "

printf '%s\n' 'zz_ghost() { orch_stub issue zz_ghost "$@"; }' >>"$cf"
touch -d '+11 minutes' "$cf"
out="$(HOME="$cache_home" bash -c 'ORCH_SOURCE_LAZY=1; source "$1/orch.sh"; zz_ghost' _ "$cache_scripts" 2>&1)" && status=0 || status=$?
assert_status "a table naming a function no module defines stops with exit 1" "$status" 1
assert_eq "naming the cache file" "$out" "orch: zz_ghost is in the stub table but no module defines it - remove $cf and run again"
assert_eq "with the cache already rebuilt" "$(grep -c zz_ghost "$cf")" "0"

# Two plugin copies use two files.
cache_root2="$(mktemp -d)"
cp -R "$PLUGIN_ROOT/scripts" "$cache_root2/"
cache_cmd "$cache_root2/scripts"
assert_eq "two plugin copies use two cache files" "$(cache_count)" "2"

# A failed move leaves no temporary file and the command runs.
fake_mv="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"$fake_mv/mv"; chmod +x "$fake_mv/mv"
rm -f "$cache_dir"/*
out="$(HOME="$cache_home" PATH="$fake_mv:$PATH" bash "$cache_scripts/orch.sh" help 2>&1)" && status=0 || status=$?
assert_status "a failed move still runs the command" "$status" 0
assert_eq "and leaves no file in the cache directory" "$(cache_count)" "0"
rm -rf "$cache_root" "$cache_root2" "$fake_mv"
