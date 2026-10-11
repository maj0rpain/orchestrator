# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- common.sh is the bottom layer --------------------------------------------
echo
echo "common.sh is the bottom layer"
# common.sh holds the primitives no concept owns and calls nothing a noun
# module defines: no non-comment line of it names, as a whole word, a function
# defined in a module of its orch/ directory other than common.sh and gh.sh,
# the adapter layer below it. common_upcalls <scripts-dir> prints each such
# name found in <scripts-dir>/orch/common.sh. A definition is a column-0
# `name()` line. host.sh, triage-labels.sh and planning-allowlist.sh sit
# outside orch/, so common.sh's calls into them are outside the check.
common_upcalls() {
  local common_file="$1/orch/common.sh" code name f
  code="$(grep -v '^[[:space:]]*#' "$common_file")"
  for f in "$1"/orch/*.sh; do
    case "$(basename "$f")" in common.sh|gh.sh) continue ;; esac
    grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "$f" | sed 's/()$//'
  done | sort -u | while IFS= read -r name; do
    if printf '%s\n' "$code" | grep -qw -- "$name"; then printf '%s\n' "$name"; fi
  done
}
layer_dir="$(mktemp -d)"
mkdir "$layer_dir/orch"
printf '%s\n' 'noun_fn() {' '  :' '}' >"$layer_dir/orch/noun.sh"
printf '%s\n' '# noun_fn is named in a comment only' '  # noun_fn again' \
  'prim() { noun_fnx; }' >"$layer_dir/orch/common.sh"
assert_eq "a comment or a longer word is no call into a noun module" \
  "$(common_upcalls "$layer_dir")" ""
printf '%s\n' 'prim() { noun_fn; }' >"$layer_dir/orch/common.sh"
assert_eq "a noun-module function called from common.sh is caught" \
  "$(common_upcalls "$layer_dir")" "noun_fn"
printf '%s\n' 'gh() {' '  :' '}' >"$layer_dir/orch/gh.sh"
printf '%s\n' 'own() {' '  :' '}' 'prim() { gh; own; }' >"$layer_dir/orch/common.sh"
assert_eq "a gh.sh-only function or common.sh's own is no call into a noun module" \
  "$(common_upcalls "$layer_dir")" ""
rm -rf "$layer_dir"
assert_eq "common.sh calls no function a noun module defines" \
  "$(common_upcalls "$(dirname "$ORCH")" | tr '\n' ' ')" ""
