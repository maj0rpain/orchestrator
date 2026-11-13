# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

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
expected="$(for f in "$loader_dir"/*.sh; do n="${f##*/}"; n="${n%.sh}"; case "$n" in common|loader) ;; *) echo "$n" ;; esac; done | LC_ALL=C sort)"
assert_eq "orch_load_all loads every module in C-locale name order" \
  "$(awk '{print $1}' "$trace")" "$expected"
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

# lazy_run <script>: orch.sh sourced on demand, then <script>, traced.
lazy_run() { : >"$trace"; ORCH_LOAD_TRACE="$trace" bash -c 'ORCH_SOURCE_LAZY=1; source "$1"; shift; '"$1" _ "$ORCH" 2>&1; }
orch_modules_list() { for f in "$loader_dir"/*.sh; do n="${f##*/}"; n="${n%.sh}"; case "$n" in common|loader) ;; *) echo "$n" ;; esac; done | LC_ALL=C sort; }

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
