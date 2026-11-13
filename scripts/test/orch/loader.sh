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
