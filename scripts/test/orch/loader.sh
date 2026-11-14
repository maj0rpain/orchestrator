# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# orch_modules_list: every module of scripts/orch, one name per line, in
# C-locale order: what a sourced orch.sh loads.
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

loader_run 'orch_load issue; declare -F cmd_issue >/dev/null && echo defined'
assert_eq "orch_load sources a module" "$out" "defined"

loader_run 'orch_load issue; unset -f cmd_issue; orch_load issue; declare -F cmd_issue >/dev/null || echo not-resourced'
assert_eq "a second orch_load of a module does nothing" "$out" "not-resourced"

loader_run 'orch_load nonesuch; echo reached'
assert_status "an unknown module stops with exit 1" "$status" 1
assert_eq "and says which" "$out" "orch: orch_load: no module nonesuch"

loader_run 'orch_load common'
assert_eq "common.sh is no module" "$out" "orch: orch_load: no module common"

assert_eq "orch.sh sources no module but common.sh and loader.sh" \
  "$(grep -E '^[[:space:]]*(source|\.) ' "$PLUGIN_ROOT/scripts/orch.sh" | grep -cE 'orch/' | tr -d ' ')" "2"

# loader.sh, like common.sh, names no function a module defines (gh.sh too).
assert_eq "loader.sh names no function a module defines" \
  "$(layer_upcalls "$PLUGIN_ROOT/scripts" loader.sh common.sh loader.sh)" ""

# --- on-demand loading --------------------------------------------------------
echo
echo "on-demand loading"
new_repo >/dev/null
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
run_traced side-checkout issue
assert_eq "a load from a subshell records a depth above 0" \
  "$(awk '$2 > 0 {print $1}' "$trace" | sed -n 1p)" "checkout"
out="$(bash "$ORCH" status 2>&1)"; status=$?
out2="$(ORCH_LOAD_TRACE=/nonexistent/dir/trace bash "$ORCH" status 2>&1)"; status2=$?
assert_eq "an unwritable ORCH_LOAD_TRACE leaves the command's output as it is" "$out2" "$out"
assert_status "and its exit status" "$status2" "$status"

# src_run <script>: <script> run with $1 = orch.sh, the trace emptied first.
src_run() { : >"$trace"; ORCH_LOAD_TRACE="$trace" bash -c "$1" _ "$ORCH" 2>&1; }
lazy_pre='ORCH_SOURCE_LAZY=1; source "$1"; shift; '

src_run "$lazy_pre"'(spec_review_lens_known consistency consistency); true'
assert_eq "a stub called in a subshell loads its module there only" "$(cat "$trace")" "spec-review 1"

# A stub passes its arguments and returns the real function's status.
out="$(src_run "$lazy_pre"'st=0; spec_review_lens_known consistency || st=$?; echo "st=$st"')"
assert_eq "a stub passes its arguments and returns the real function's status for a known lens" "$out" "st=0"
out="$(src_run "$lazy_pre"'st=0; spec_review_lens_known nonesuch || st=$?; echo "st=$st"')"
assert_contains "and returns a failing status" "$out" "st=1"

# A stub whose module no longer defines the function: one the function moved
# to loads and the call goes on; with none, the command stops.
lazy_dir="$(tree_copy scripts)"
printf '%s\n' 'zz_fn() { echo from-old; }' >"$lazy_dir/orch/zz-old.sh"
printf '%s\n' 'zz_other() { :; }' >"$lazy_dir/orch/zz-new.sh"
out="$(bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; printf "%s\n" "zz_other() { :; }" >"$2"; printf "%s\n" "zz_fn() { echo from-new; }" >"$3"; zz_fn' _ "$lazy_dir/orch.sh" "$lazy_dir/orch/zz-old.sh" "$lazy_dir/orch/zz-new.sh" 2>&1)"
assert_eq "a function moved to another module loads that module and the call goes on" "$out" "from-new"
printf "%s\n" 'zz_fn() { echo from-old; }' >"$lazy_dir/orch/zz-old.sh"
printf "%s\n" 'zz_other() { :; }' >"$lazy_dir/orch/zz-new.sh"
out="$(bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; printf "%s\n" "zz_other() { :; }" >"$2"; zz_fn' _ "$lazy_dir/orch.sh" "$lazy_dir/orch/zz-old.sh" 2>&1)"; status=$?
assert_status "a stub whose function no module defines stops with exit 1" "$status" 1
assert_eq "and says so" "$out" "orch: zz_fn is in the stub table but no module defines it"
rm -f "$lazy_dir/orch/zz-old.sh" "$lazy_dir/orch/zz-new.sh"

# A function defined with a run of spaces before its brace gets a stub too.
printf '%s\n' 'zz_wide()   { echo from-wide; }' >"$lazy_dir/orch/zz-wide.sh"
: >"$trace"
out="$(HOME="$lazy_dir" ORCH_LOAD_TRACE="$trace" bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; zz_wide' _ "$lazy_dir/orch.sh" 2>&1)"
assert_eq "a function defined as name()   { runs through its stub" "$out" "from-wide"
assert_contains "and loads its module on demand" "$(cat "$trace")" "zz-wide 0"

# A relative path to orch.sh and a cd before the first on-demand load: the
# module directory is absolute from the start. It has its own HOME, so it
# scans the modules instead of reading the cache the case above wrote.
git init -q "${lazy_dir%/scripts}"
rel_home="$(mktemp -d "${lazy_dir%/scripts}/home.XXXXXX")"
out="$(cd "${lazy_dir%/scripts}" && HOME="$rel_home" bash -c 'ORCH_SOURCE_LAZY=1; source scripts/orch.sh; cd /; zz_wide' 2>&1)"
assert_eq "an on-demand load after a cd works with orch.sh sourced by a relative path" "$out" "from-wide"
rm -rf "${lazy_dir%/scripts}"

# A plugin path containing a colon still maps every function to its module.
colon_root="$(mktemp -d)/c:olon"
mkdir "$colon_root"
cp -R "$PLUGIN_ROOT/scripts" "$colon_root/"
out="$(HOME="$colon_root" bash "$colon_root/scripts/orch.sh" help 2>&1)"; status=$?
assert_status "orch.sh run from a path containing a colon succeeds" "$status" 0
assert_eq "and prints what a colon-free copy prints" "$out" \
  "$(HOME="$colon_root" bash "$ORCH" help 2>&1)"
rm -rf "${colon_root%/c:olon}"

# Sourced, every module loads, no stub table or cache is written, and a
# function replaced after the source stays replaced.
src_run 'source "$1"'
assert_eq "sourced plainly, every module loads" "$(awk '{print $1}' "$trace")" "$(orch_modules_list)"
src_home="$(mktemp -d)"
HOME="$src_home" src_run 'source "$1"'
assert_eq "sourced plainly, no cache file is written" "$(ls -A "$src_home/.cache/orchestrator" 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$src_home"
out="$(src_run 'source "$1"; cmd_state() { echo replaced; }; cmd_state')"
assert_eq "a function replaced after source stays replaced" "$out" "replaced"

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
# The section's own HOME starts with the stub cache of the tree under test,
# seeded by the runner; other trees' files under it are not counted. Its name
# is whatever a run of orch.sh writes into an empty HOME.
name_home="$(mktemp -d)"
(cd "$PLUGIN_ROOT" && HOME="$name_home" "$ORCH" help >/dev/null 2>&1)
seed_file_name="$(basename "$(printf "%s\n" "$name_home"/.cache/orchestrator/*.stubs)")"
rm -rf "$name_home"
# seeded_cache_checks <label prefix> <file>: the file is a regular file of mode
# 600 and a run of orch.sh reuses it.
seeded_cache_checks() {
  local prefix="$1" file="$2"
  assert_eq "$prefix starts with the stub cache" "$([ -f "$file" ] && echo yes || echo no)" "yes"
  assert_eq "$prefix cache is a regular file, not a link" "$([ -L "$file" ] && echo link || echo file)" "file"
  assert_eq "$prefix cache is of mode 600" "$(stat -c %a "$file" 2>/dev/null || stat -f %Lp "$file")" "600"
  echo "# seeded marker" >>"$file"
  touch -d '+1 minute' "$file"
  "$ORCH" help >/dev/null 2>&1
  assert_contains "and a run reuses the $prefix cache" "$(cat "$file")" "# seeded marker"
  sed -i.bak '/^# seeded marker$/d' "$file"; rm -f "$file.bak"
}
seeded_cache_checks "a section's HOME" "$HOME/.cache/orchestrator/$seed_file_name"

# A HOME the shared helper makes starts the same way, with a copy of its own.
suite_home="$HOME"
seeded_home
assert_ne "a seeded_home is a HOME of its own" "$HOME" "$suite_home"
seeded_cache_checks "a seeded_home" "$HOME/.cache/orchestrator/$seed_file_name"
rm -rf "$HOME"; HOME="$suite_home"; export HOME

new_repo >/dev/null
cache_root="$(mktemp -d)"
cache_scripts="$(tree_copy scripts)"
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
sed -i.bak 's/^cmd_state() { orch_stub state /cmd_state() { orch_stub issue /' "$cf"; rm -f "$cf.bak"
assert_contains "the planted table names the wrong module" "$(cat "$cf")" "cmd_state() { orch_stub issue "
touch -d '+10 minutes' "$cf"
out="$(HOME="$cache_home" bash "$cache_scripts/orch.sh" state get phase 2>&1)" && status=0 || status=$?
assert_eq "a planted wrong table is rebuilt and the call goes on" "$out" "$(bash "$ORCH" state get phase 2>&1)"
assert_contains "and the cache holds the rebuilt table" "$(cat "$cf")" "cmd_state() { orch_stub state "

sed -i.bak 's/^cmd_state() {/cmd_state_gone() {/' "$cache_scripts/orch/state.sh"; rm -f "$cache_scripts/orch/state.sh.bak"
touch -d '+11 minutes' "$cf"
out="$(HOME="$cache_home" bash "$cache_scripts/orch.sh" state get phase 2>&1)" && status=0 || status=$?
assert_status "a table naming a function no module defines stops with exit 1" "$status" 1
assert_eq "naming the cache file" "$out" "orch: cmd_state is in the stub table but no module defines it - remove $cf and run again"
assert_eq "with the cache already rebuilt" "$(grep -c '^cmd_state()' "$cf")" "0"

# Two plugin copies use two files.
cache_scripts2="$(tree_copy scripts)"
cache_cmd "$cache_scripts2"
assert_eq "two plugin copies use two cache files" "$(cache_count)" "2"

# A failed move leaves no temporary file and the command runs.
fake_mv="$(mktemp -d)"
printf '#!/bin/sh\nexit 1\n' >"$fake_mv/mv"; chmod +x "$fake_mv/mv"
rm -f "$cache_dir"/*
out="$(HOME="$cache_home" PATH="$fake_mv:$PATH" bash "$cache_scripts/orch.sh" help 2>&1)" && status=0 || status=$?
assert_status "a failed move still runs the command" "$status" 0
assert_eq "and leaves no file in the cache directory" "$(cache_count)" "0"
rm -rf "$cache_root" "${cache_scripts%/scripts}" "${cache_scripts2%/scripts}" "$fake_mv"
