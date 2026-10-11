# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- is_filed_severity ------------------------------------------------------

echo
echo "is_filed_severity"
new_repo >/dev/null
# Sourced rather than run: the helper is the one answer to "is this severity
# filed", and sourcing orch.sh defines its functions without running main.
filed_sev() { bash -c 'source "$1" && is_filed_severity "$2"' _ "$ORCH" "$1"; }
filed_sev major; assert_status "accepts major" "$?" 0
filed_sev nit; assert_status "accepts nit" "$?" 0
filed_sev blocking; assert_status "refuses blocking - it is always fixed, never filed" "$?" 1
filed_sev ""; assert_status "refuses an empty severity" "$?" 1

# --- severity table ---------------------------------------------------------
# Every filed severity has a label colour and description, so `review file`
# needs no fallback for a severity the table leaves out.

echo
echo "severity table"
new_repo >/dev/null
# shellcheck disable=SC2016 # expanded by the inner bash
missing="$(bash -c 'source "$1"
  for sev in $FILED_SEVERITIES; do
    colour= desc=
    filed_severity_label "$sev" colour desc && [ -n "$colour" ] && [ -n "$desc" ] \
      || printf "%s\n" "$sev"
  done' _ "$ORCH" 2>&1)"
assert_eq "every member of FILED_SEVERITIES has a severity-table entry" "$missing" ""
bash -c 'source "$1" && filed_severity_label blocking colour desc' _ "$ORCH"
assert_status "a severity with no entry returns 1" "$?" 1
