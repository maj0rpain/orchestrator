# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- host detection (host.sh, #281) -------------------------------------------
echo
echo "host detection (host.sh, #281)"
# host.sh is sourced alone, in a fresh shell with every host signal unset, so
# it is shown to need nothing from orch.sh. host_on runs host_detect there,
# after the given VAR=value assignments.
HOST_SH="$(dirname "$ORCH")/host.sh"
# host_clean_env is the clean shell both helpers run host.sh in: the env options
# that unset every host signal. env unsets before it applies VAR=value
# assignments, so a case's own assignment still reaches the shell.
host_clean_env=(-u ORCHESTRATOR_HOST -u CLAUDECODE -u JUNIE_EXTENSION_ROOT
  -u JUNIE_SHIM_PATH -u CLAUDE_PLUGIN_ROOT -u ANTIGRAVITY_AGENT
  -u ANTIGRAVITY_CONVERSATION_ID)
host_on() {
  env "${host_clean_env[@]}" "$@" \
    bash -c 'source "$1" && host_detect' host_on "$HOST_SH"
}
# host_from_project_path <project_path>, in the same clean shell.
host_from() {
  env "${host_clean_env[@]}" "${@:2}" \
    bash -c 'source "$1" && host_from_project_path "$2"' host_from "$HOST_SH" "$1"
}
assert_eq "host_from_project_path ignores ORCHESTRATOR_HOST=claude" \
  "$(host_from /r ORCHESTRATOR_HOST=claude)" "junie"
assert_eq "host_from_project_path ignores ORCHESTRATOR_HOST=junie" \
  "$(host_from '' ORCHESTRATOR_HOST=junie)" "claude"
assert_eq "host_detect: no signal prints nothing" "$(host_on)" ""
assert_eq "host_detect: ORCHESTRATOR_HOST names the host" \
  "$(host_on ORCHESTRATOR_HOST=junie)" "junie"
assert_eq "host_detect: ORCHESTRATOR_HOST outranks ANTIGRAVITY_AGENT" \
  "$(host_on ORCHESTRATOR_HOST=claude ANTIGRAVITY_AGENT=1)" "claude"
assert_eq "host_detect: ANTIGRAVITY_AGENT is antigravity" \
  "$(host_on ANTIGRAVITY_AGENT=1)" "antigravity"
assert_eq "host_detect: ANTIGRAVITY_CONVERSATION_ID is antigravity" \
  "$(host_on ANTIGRAVITY_CONVERSATION_ID=abc)" "antigravity"
assert_eq "host_detect: ANTIGRAVITY_CONVERSATION_ID outranks CLAUDECODE=1" \
  "$(host_on ANTIGRAVITY_CONVERSATION_ID=abc CLAUDECODE=1)" "antigravity"
assert_eq "host_detect: ANTIGRAVITY_AGENT outranks JUNIE_SHIM_PATH and CLAUDECODE=1" \
  "$(host_on ANTIGRAVITY_AGENT=1 JUNIE_SHIM_PATH=/x CLAUDECODE=1)" "antigravity"
assert_eq "host_detect: JUNIE_SHIM_PATH is junie" \
  "$(host_on JUNIE_SHIM_PATH=/x)" "junie"
assert_eq "host_detect: CLAUDECODE=1 is claude" "$(host_on CLAUDECODE=1)" "claude"
assert_eq "host_detect: JUNIE_SHIM_PATH outranks CLAUDECODE=1" \
  "$(host_on JUNIE_SHIM_PATH=/x CLAUDECODE=1)" "junie"
