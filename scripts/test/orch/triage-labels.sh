# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- triage_label_into: parse once, later lookups start no command ------------
echo
echo "triage_label_into"
tli_root="$(mktemp -d)"
mkdir -p "$tli_root/docs/agents"
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage-me`          | Evaluate it |' \
        '| `ready-for-agent`          | `afk`                | AFK-ready   |' >"$tli_root/docs/agents/triage-labels.md"
tli_script='ROOT="$1"; source "$2"
triage_label_into first needs-triage
PATH=""
triage_label_into second ready-for-agent
triage_label_into third wontfix
printf "%s %s %s\n" "$first" "$second" "$third"'
out="$(bash -c "$tli_script" _ "$tli_root" "$(dirname "$ORCH")/triage-labels.sh" 2>&1)"
assert_eq "a lookup after the first answers with an empty PATH" "$out" "triage-me afk wontfix"
tli_script='ROOT="$1"; source "$2"; triage_label_into got ready-for-agent; [ "$got" = "$(triage_label_for ready-for-agent)" ] && echo same'
out="$(bash -c "$tli_script" _ "$tli_root" "$(dirname "$ORCH")/triage-labels.sh" 2>&1)"
assert_eq "triage_label_into sets what triage_label_for prints" "$out" "same"
out="$(bash -c "$tli_script" _ "$tli_root/none" "$(dirname "$ORCH")/triage-labels.sh" 2>&1)"
assert_eq "a missing doc answers the role name itself" "$out" "same"
rm -rf "$tli_root"

