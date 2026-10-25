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
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "FILED_SEVERITIES lists the table's severities in its order" \
  "$(bash -c 'source "$1" && printf "%s" "$FILED_SEVERITIES"' _ "$ORCH")" "major nit"
bash -c 'source "$1" && filed_severity_label blocking colour desc' _ "$ORCH"
assert_status "a severity with no entry returns 1" "$?" 1

# --- axis table -------------------------------------------------------------
# Every review axis has a category a finding filed on it starts in.

echo
echo "axis table"
new_repo >/dev/null
# shellcheck disable=SC2016 # expanded by the inner bash
assert_eq "FILED_AXES lists the table's axes in its order" \
  "$(bash -c 'source "$1" && printf "%s" "$FILED_AXES"' _ "$ORCH")" "spec standards suite-cost"
# shellcheck disable=SC2016 # expanded by the inner bash
missing="$(bash -c 'source "$1"
  for axis in $FILED_AXES; do
    [ -n "$(category_for_axis "$axis")" ] || printf "%s\n" "$axis"
  done' _ "$ORCH" 2>&1)"
assert_eq "every member of FILED_AXES has a category_for_axis result" "$missing" ""
# shellcheck disable=SC2016 # expanded by the inner bash
cat_for() { bash -c 'source "$1" && category_for_axis "$2"' _ "$ORCH" "$1"; }
assert_eq "spec starts as a bug" "$(cat_for spec)" "bug"
assert_eq "standards starts as an enhancement" "$(cat_for standards)" "enhancement"
assert_eq "suite-cost starts as an enhancement" "$(cat_for suite-cost)" "enhancement"
assert_eq "the axis is case-insensitive" "$(cat_for Suite-Cost)" "enhancement"
out="$(cat_for style)"; st=0; bash -c 'source "$1" && category_for_axis style' _ "$ORCH" >/dev/null || st=$?
assert_status "an unknown axis fails" "$st" 1
assert_eq "printing nothing" "$out" ""

# --- finding body -----------------------------------------------------------
# A filed finding's issue body: finding_body_render writes it from its parts,
# finding_body_parse reads every labelled line back out, each the inverse of
# the other. A body written by hand in the closer's format before rendering
# existed parses the same way.

echo
echo "finding body"
new_repo >/dev/null
# parsed <body>...: every field finding_body_parse writes into its array, one
# "<field>=<value>" per line, in a fixed order - after parsing each body in
# turn into the same array.
# shellcheck disable=SC2016 # expanded by the inner bash
parsed() {
  bash -c 'source "$1"; shift
    declare -A f
    for b in "$@"; do finding_body_parse "$b" f; done
    for k in axis severity reason file line sha pr pr_number why question; do
      printf "%s=%s\n" "$k" "${f[$k]}"
    done' _ "$ORCH" "$@"
}
# rendered <finding text> <part>...: the body finding_body_render prints for
# the finding text, written to a file, and the parts after it.
# shellcheck disable=SC2016 # expanded by the inner bash
rendered() {
  local text="$1" f
  shift
  f="$(mktemp)"
  printf '%s' "$text" >"$f"
  bash -c 'source "$1"; shift; finding_body_render "$@"' _ "$ORCH" "$f" "$@"
  rm -f "$f"
}
# fields <axis> <sev> <reason> <file> <line> <sha> <pr> <pr_number> <why>
# [<question>]: the "<field>=<value>" lines parsed should give.
fields() {
  printf '%s\n' "axis=$1" "severity=$2" "reason=$3" "file=$4" "line=$5" "sha=$6" \
    "pr=$7" "pr_number=$8" "why=$9" "question=${10:-}"
}
sha=0123456789abcdef0123456789abcdef01234567
url=https://github.com/acme/widgets/pull/42

body="$(rendered $'> The reviewer said this.\n\n\n' standards nit 'a reason.' src/app.sh 7 "$sha" "$url" 'found in the final iteration.')"
assert_eq "renders the finding text, a blank line, then each labelled line and a blank line" \
  "$body" "$(writeln '> The reviewer said this.' '' '**Axis:** Standards' '' \
    '**Severity:** nit - a reason.' '' "**Location:** \`src/app.sh:7\` at $sha" '' \
    "**PR:** $url" '' '**Why not fixed in the loop:** found in the final iteration.')"
assert_eq "a single line parses back to every part" "$(parsed "$body")" \
  "$(fields standards nit 'a reason.' src/app.sh 7 "$sha" "$url" 42 'found in the final iteration.')"

body="$(rendered 'Spans lines.' SPEC major 'misses the spec' lib/x.sh 10-20 "$sha" "$url" 'it is a spec question' 'Should it?')"
assert_contains "a Spec question gets its own labelled line" "$body" $'\n\n**Spec question:** Should it?'
assert_contains "the axis capitalised, whatever case was given" "$body" $'\n**Axis:** Spec\n'
assert_eq "a range with a Spec question parses back to every part" "$(parsed "$body")" \
  "$(fields spec major 'misses the spec' lib/x.sh 10-20 "$sha" "$url" 42 'it is a spec question' 'Should it?')"
body="$(rendered 'Spans lines.' spec major 'misses the spec' lib/x.sh 10-20 "$sha" "$url" 'found in the final iteration.')"
assert_not_contains "no Spec question line when none is given" "$body" "Spec question"
assert_eq "a range without a Spec question parses back to every part" "$(parsed "$body")" \
  "$(fields spec major 'misses the spec' lib/x.sh 10-20 "$sha" "$url" 42 'found in the final iteration.')"

body="$(rendered 'Grew.' suite-cost major 'grew past the threshold' suite '' "$sha" "$url" 'found in the final iteration.')"
assert_contains "a suite-cost finding names the suite, with no line" "$body" "**Location:** \`suite\` at $sha"
assert_eq "and parses back to every part, its line empty" "$(parsed "$body")" \
  "$(fields suite-cost major 'grew past the threshold' suite '' "$sha" "$url" 42 'found in the final iteration.')"
no_line="$(printf '%s\n' "$body" | sed "s/\`suite\`/\`src\/app.sh\`/")"
assert_eq "while any other file with no line is no location" "$(parsed "$no_line" | grep '^file=')" "file="

body="$(rendered 'Text.' standards nit 'cheap - but noisy - fix' a.sh 1 "$sha" "$url" 'not mechanical')"
assert_eq "a severity reason containing ' - ' splits at the first one" "$(parsed "$body")" \
  "$(fields standards nit 'cheap - but noisy - fix' a.sh 1 "$sha" "$url" 42 'not mechanical')"

# The closer's format before rendering, written by hand: no trailing blank
# line, a PR URL with a trailing slash and spaces.
legacy="$(writeln '## Finding' '' '> The reviewer said this.' '' '**Axis:** Standards' '' \
  '**Severity:** nit - a reason.' '' "**Location:** \`src/app.sh:3\` at $sha" '' \
  "**PR:** $url/  " '' '**Why not fixed in the loop:** found in the final iteration.')"
assert_eq "a legacy body parses to the same fields" "$(parsed "$legacy")" \
  "$(fields standards nit 'a reason.' src/app.sh 3 "$sha" "$url/" 42 'found in the final iteration.')"

no_loc="$(printf '%s\n' "$legacy" | grep -v '^\*\*Location:\*\*')"
assert_eq "a body missing Location leaves file, line and SHA empty and fills the rest" "$(parsed "$no_loc")" \
  "$(fields standards nit 'a reason.' '' '' '' "$url/" 42 'found in the final iteration.')"
no_pr="$(printf '%s\n' "$legacy" | grep -v '^\*\*PR:\*\*')"
assert_eq "a body missing PR leaves pr and pr_number empty and fills the rest" "$(parsed "$no_pr")" \
  "$(fields standards nit 'a reason.' src/app.sh 3 "$sha" '' '' 'found in the final iteration.')"
no_axis_why="$(printf '%s\n' "$legacy" | grep -v '^\*\*Axis:\*\*\|^\*\*Why not fixed')"
assert_eq "a legacy body missing Axis and Why leaves those two empty" "$(parsed "$no_axis_why")" \
  "$(fields '' nit 'a reason.' src/app.sh 3 "$sha" "$url/" 42 '')"

quoting="$(writeln 'The reviewer quoted:' "**Location:** \`old/file.sh:9\` at abc123" \
  '**PR:** https://github.com/acme/widgets/pull/5' '' "$legacy")"
assert_eq "a body whose text quotes Location and PR lines parses from the first of each" "$(parsed "$quoting")" \
  "$(fields standards nit 'a reason.' old/file.sh 9 abc123 https://github.com/acme/widgets/pull/5 5 'found in the final iteration.')"
first_bad="$(writeln '**Location:** somewhere' '' "$legacy")"
assert_eq "a first Location line that does not parse leaves Location empty, with no fallback" \
  "$(parsed "$first_bad" | grep '^file=\|^line=\|^sha=')" "$(writeln file= line= sha=)"
pr_skip="$(writeln '**PR:** not a link' '' "$legacy")"
assert_eq "PR comes from the first line matching the whole PR rule" \
  "$(parsed "$pr_skip" | grep '^pr')" "$(writeln "pr=$url/" pr_number=42)"
last_at="$(writeln "**Location:** \`a.sh:2\` at deadbeef, rebased at $sha")"
assert_eq "the SHA is the hex run of the line's last ' at <hex>'" \
  "$(parsed "$last_at" | grep '^sha=')" "sha=$sha"
out="$(parsed 'nothing labelled here' 2>&1)"; st=$?
assert_status "a body with no labelled lines does not fail" "$st" 0
assert_eq "and leaves every field empty, printing nothing else" "$out" "$(fields '' '' '' '' '' '' '' '' '')"

# One array reused across bodies: every key is written on every call, so a
# sparse body never shows the previous body's values.
out="$(parsed "$legacy" "$no_axis_why" 2>&1)"
assert_eq "a sparse body parsed after a full one into the same array leaves its missing fields empty" \
  "$out" "$(fields '' nit 'a reason.' src/app.sh 3 "$sha" "$url/" 42 '')"
out="$(bash -c 'source "$1"; finding_body_parse "$2" nosuch' _ "$ORCH" "$legacy" 2>&1)"; st=$?
assert_status "an undeclared array name fails" "$st" 1
assert_eq "naming it" "$out" "orch: finding_body_parse: nosuch is not a declared associative array"
# shellcheck disable=SC2016 # expanded by the inner bash
out="$(bash -c 'source "$1"; g() { local f; finding_body_parse "$1" f; }; g "$2"' _ "$ORCH" "$legacy" 2>&1)"; st=$?
assert_status "a scalar fails" "$st" 1
assert_eq "naming it" "$out" "orch: finding_body_parse: f is not a declared associative array"
# shellcheck disable=SC2016 # expanded by the inner bash
out="$(bash -c 'source "$1"; g() { local -a f; finding_body_parse "$1" f; }; g "$2"' _ "$ORCH" "$legacy" 2>&1)"; st=$?
assert_status "an indexed array fails" "$st" 1
assert_eq "naming it" "$out" "orch: finding_body_parse: f is not a declared associative array"
