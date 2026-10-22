# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# --- known-items module -----------------------------------------------------
# The Known items module's helpers, called through a sourced orch.sh: sourcing
# defines its functions without running main. `review known-items` and
# `review-pass known-items` test the files the commands build; these pin the
# helpers they build them from.

echo
echo "known-items module"
new_repo >/dev/null
# sourced_orch_script <script> [<arg>...]: runs <script> in a child bash that has
# sourced orch.sh, with <arg>... as its positional parameters. Command
# substitution drops the trailing newline every appended line ends in.
sourced_orch_script() {
  bash -c 'source "$1"; script="$2"; shift 2; eval "$script"' _ "$ORCH" "$@"
}

entries="$(mktemp)"
printf '%s\n' '- first bullet' '  continued here' '    and here' 'a margin line' \
  '- None' 'None.' '- None declined.' '' '- second bullet' >"$entries"
assert_eq "text_entries joins continuations, keeps margin lines and drops None" \
  "$(sourced_orch text_entries <"$entries")" \
  "first bullet continued here and here
a margin line
second bullet"

record="$(mktemp)"
printf '%s\n' '## Deviations' '- picked a seam' '  for a reason' '## Review' '- declined one' \
  'None.' >"$record"
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "section_entries_append appends the heading's entries, each tagged" \
  "$(sourced_orch_script 'v=$'"'"'- kept\n'"'"'; section_entries_append v "$1" "## Review" declined
    printf "%s" "$v"' "$record")" \
  "- kept
- declined one - declined"
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "section_entries_append with no tag appends bare bullets" \
  "$(sourced_orch_script 'section_entries_append v "$1" "## Deviations"; printf "%s" "$v"' "$record")" \
  "- picked a seam for a reason"
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "text_entries_append appends every entry of the file, each tagged" \
  "$(sourced_orch_script 'text_entries_append v "$1" "spec ruling"; printf "%s" "$v"' "$entries")" \
  "- first bullet continued here and here - spec ruling
- a margin line - spec ruling
- second bullet - spec ruling"
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "text_entries_append with no tag appends bare bullets" \
  "$(sourced_orch_script 'v=$'"'"'- kept\n'"'"'; text_entries_append v "$1"; printf "%s" "$v"' "$entries")" \
  "- kept
- first bullet continued here and here
- a margin line
- second bullet"

out_dir="$(mktemp -d)"
sourced_orch known_items_write "$out_dir/known.md" "" $'- one\n'
assert_eq "known_items_write fills an empty deviations side with None." \
  "$(cat "$out_dir/known.md")" "## Deviations
None.
## Known items
- one"
sourced_orch known_items_write "$out_dir/known.md" $'- dev\n' ""
assert_eq "known_items_write fills an empty known side with None." \
  "$(cat "$out_dir/known.md")" "## Deviations
- dev
## Known items
None."
if [ "$(id -u)" -ne 0 ]; then
  before="$(cat "$out_dir/known.md")"
  chmod a-w "$out_dir"
  sourced_orch known_items_write "$out_dir/known.md" $'- new\n' $'- new\n' 2>/dev/null
  status=$?
  chmod u+w "$out_dir"
  assert_status "known_items_write fails when it cannot write" "$status" 1
  assert_eq "a failed known_items_write leaves the path as it was" \
    "$(cat "$out_dir/known.md")" "$before"
fi

# Where each helper is defined: extdebug makes `declare -F` print the file.
# shellcheck disable=SC2016 # expanded by the inner bash
defined_in="$(sourced_orch_script 'shopt -s extdebug
  for f in text_entries section_entries section_entries_append text_entries_append \
      known_items_write entries_append; do
    printf "%s %s\n" "$f" "$(declare -F "$f" | sed "s/^[^ ]* [0-9]* //; s#.*/##")"
  done')"
assert_eq "the five known-items helpers live in known-items.sh, entries_append nowhere" \
  "$defined_in" "text_entries known-items.sh
section_entries known-items.sh
section_entries_append known-items.sh
text_entries_append known-items.sh
known_items_write known-items.sh
entries_append "
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "handoff.sh keeps section_body" \
  "$(sourced_orch_script 'shopt -s extdebug; declare -F section_body | sed "s#.*/##"')" "handoff.sh"
