# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- review label and untriaged finding --------------------------------------
# What the Filed finding module holds for autopilot's untriaged-finding gate:
# whether the labels mark a review finding, and whether finding triage has yet
# to triage it. Sourced rather than run, in one child shell: sourcing orch.sh
# defines its functions without running main.

echo
echo "review label and untriaged finding"
new_repo >/dev/null
# shellcheck disable=SC2016 # expanded by the inner bash
out="$(sourced_orch_script '
  for labels in "$@"; do
    st=0; has_review_label "$labels" || st=$?
    ut=0; finding_untriaged "$labels" || ut=$?
    printf "%s %s\n" "$st" "$ut"
  done' "$(writeln bug Review:Nit)" "review:" "nit" "review:major" \
  "$(writeln review:major Ready-For-Human)" "$(writeln review:major wontfix)" 2>&1)"
assert_eq "a review label in any casing marks a finding, a bare review: or another label does not, and a triage role label ends untriaged" \
  "$out" "$(writeln '0 0' '1 1' '1 1' '0 0' '0 1' '0 1')"
