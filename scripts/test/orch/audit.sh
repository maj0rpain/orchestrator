# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# Filing is mechanism: which labels, what title, which body, and the number
# printed back. What reached GitHub is the assertion, read back from the
# store-backed fake (fake_github); no section spawns a gh subprocess.

# audit_repo: a fresh repo with one commit on the store-backed fake, a finding
# file in $finding and the locations a filing takes in $parts.
audit_repo() {
  new_repo >/dev/null
  fake_github
  finding="$(mktemp)"
  printf 'A doc says --force is required.\n\nThe code takes no such flag.\n\n\n' >"$finding"
  parts=(--finding-file "$finding" --location docs/a.md:12 --location README.md:3-9)
  tab="$(printf '\t')"
  errf="$(mktemp)"; blank="$(mktemp)"
}

# --- audit file -------------------------------------------------------------

echo
echo "audit file"
audit_repo
head_sha="$(git rev-parse HEAD)"
fake_label needs-triage 000000 "The repo's own"
fake_next_issue 31
out="$("$ORCH" audit file "Docs name a flag that is gone" "${parts[@]}" 2>"$errf")"; st=$?
assert_status "files a finding" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "31"
assert_eq "and nothing on stderr" "$(cat "$errf")" ""
assert_eq "labels the issue needs-triage and documentation, no category or severity" \
  "$(fake_labels_of 31)" "documentation needs-triage "
assert_contains "creating documentation with GitHub's default colour and description" "$(fake_labels)" \
  "documentation${tab}0075ca${tab}Improvements or additions to documentation"
assert_contains "and leaving the repo's own triage label as the repo has it" "$(fake_labels)" \
  "needs-triage${tab}000000${tab}The repo's own"
assert_eq "passes the title through" "$(fake_title_of 31)" "Docs name a flag that is gone"
want="$(printf '%s\n' 'A doc says --force is required.' '' 'The code takes no such flag.' '' \
  '**Location:** `docs/a.md:12`' '' \
  '**Location:** `README.md:3-9`' '' \
  "**Audited at:** $head_sha" ''; printf x)"
assert_eq "renders the finding, each location in order, and HEAD's SHA, byte for byte" \
  "$(fake_body_of 31; printf x)" "$want"
assert_eq "no real gh subprocess was spawned" "$(gh_calls)" "0"

# A documentation label the repo has already is left as it is, and a failed
# create of it is ignored.
audit_repo
fake_label documentation ffffff "The repo's own"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "files with documentation already present" "$st" 0
assert_contains "leaving the repo's documentation label as the repo has it" "$(fake_labels)" \
  "documentation${tab}ffffff${tab}The repo's own"
assert_contains "and creating the repo's missing needs-triage" "$(fake_labels)" \
  "needs-triage${tab}e4e669${tab}Not yet triaged"

audit_repo
fake_fail adapter_label_create "$GH_502"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>/dev/null)"; st=$?
assert_status "a failed create of the documentation label is ignored" "$st" 0
assert_eq "the issue is still opened and its number printed" "$out" "1"
fake_unfail

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from.
audit_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "files under a renamed triage label" "$st" 0
assert_eq "applying the repo's name for it" "$(fake_labels_of "$out")" "documentation triage me "
assert_not_contains "and not creating the canonical one" "$(fake_labels)" "needs-triage"

# --- audit file duplicates --------------------------------------------------

echo
echo "audit file duplicates"
audit_repo
fake_issue 5 open
fake_issue_title 5 "Docs name a flag that is gone"
fake_issue 6 closed
fake_issue_title 6 "Closed twin"
before="$(fake_snapshot)"
out="$("$ORCH" audit file "Docs name a flag that is gone" "${parts[@]}" 2>"$errf")"; st=$?
assert_status "an open issue with the same title exits 0" "$st" 0
assert_eq "printing its number on stdout" "$out" "5"
assert_eq "and the already-open line on stderr" "$(cat "$errf")" \
  "orch: #5 is already open with this title; nothing filed"
assert_eq "filing and labelling nothing" "$(fake_snapshot)" "$before"
out="$("$ORCH" audit file "docs name a flag that is gone" "${parts[@]}" 2>&1)"; st=$?
assert_eq "a title differing in case is a different title" "$out" "7"
out="$("$ORCH" audit file "Closed twin" "${parts[@]}" 2>&1)"; st=$?
assert_eq "a closed issue with the title does not count" "$out" "8"

# --- audit file refusals ----------------------------------------------------

echo
echo "audit file refusals"
audit_repo
before="$(fake_snapshot)"
refuse() { # label message args...
  local label="$1" msg="$2"
  shift 2
  out="$("$ORCH" audit file "$@" 2>&1)"; st=$?
  assert_status "$label is refused" "$st" 1
  assert_eq "saying why" "$out" "$msg"
  assert_eq "and writing nothing" "$(fake_snapshot)" "$before"
}
usage="orch: usage: orch.sh audit file <title> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
refuse "an empty title" "orch: the title is empty" "" "${parts[@]}"
refuse "no title" "$usage"
refuse "a missing --finding-file" "$usage" "T" --location a.md:1
refuse "no --location" "$usage" "T" --finding-file "$finding"
refuse "an unknown flag" "$usage" "T" "${parts[@]}" --bogus x
refuse "a flag with no value" "$usage" "T" --finding-file "$finding" --location
refuse "a finding file given twice" "$usage" "T" "${parts[@]}" --finding-file "$finding"
refuse "a missing finding file" "orch: finding file not found: /nonexistent/f" \
  "T" --finding-file /nonexistent/f --location a.md:1
printf '  \n\n' >"$blank"
refuse "an empty finding file" "orch: finding file is empty: $blank" \
  "T" --finding-file "$blank" --location a.md:1
for bad in a.md a.md: a.md:x a.md:1- :4 a.md:1-2-3; do
  refuse "the location '$bad'" \
    "orch: not a location: $bad (want <file>:<line> or <file>:<start>-<end>)" \
    "T" --finding-file "$finding" --location "$bad"
done
refuse "a location with a backtick in its file" \
  "orch: the rendered body does not parse back: locations (given 'a\`b.md:1', parsed '')" \
  "T" --finding-file "$finding" --location 'a`b.md:1'

# A finding file already holding a labelled line shadows the rendered one.
quoting="$(mktemp)"
printf 'It reads the line\n**Location:** `x.md:1`\nas a site.\n' >"$quoting"
out="$("$ORCH" audit file "T" --finding-file "$quoting" --location a.md:1 2>&1)"; st=$?
assert_status "a finding file holding a Location line is refused" "$st" 1
assert_contains "as a body that does not parse back" "$out" "the rendered body does not parse back: locations"
assert_eq "writing nothing" "$(fake_snapshot)" "$before"
printf 'It reads the line\n**Audited at:** abc123\nas a SHA.\n' >"$quoting"
out="$("$ORCH" audit file "T" --finding-file "$quoting" --location a.md:1 2>&1)"; st=$?
assert_status "a finding file holding an Audited at line is refused" "$st" 1
assert_contains "as a body that does not parse back" "$out" "the rendered body does not parse back: audited at"
assert_eq "writing nothing" "$(fake_snapshot)" "$before"

# A HEAD whose SHA cannot be read.
nohead="$(mktemp -d)"
git -C "$nohead" init -q
cd "$nohead" || exit 1
out="$("$ORCH" audit file "T" "${parts[@]}" 2>&1)"; st=$?
assert_status "a repo with no commit is refused" "$st" 1
assert_eq "saying HEAD cannot be read" "$out" "orch: cannot read the HEAD commit"
assert_eq "and writing nothing" "$(fake_snapshot)" "$before"

# --- audit file failures ----------------------------------------------------

echo
echo "audit file failures"
audit_repo
before="$(fake_snapshot)"
assert_gh_dies "a failed open-issue lookup dies naming the step" adapter_issues_open_titles "$GH_502" 1 \
  "orch: gh could not list the open issues: HTTP 502: Bad Gateway" \
  "$ORCH" audit file "Title" "${parts[@]}"
assert_eq "writing no label and no issue" "$(fake_snapshot)" "$before"

assert_gh_dies "a failed issue create dies naming the step" adapter_issue_create "$GH_502" 1 \
  "orch: gh could not create the issue: HTTP 502: Bad Gateway" \
  "$ORCH" audit file "Title" "${parts[@]}"
assert_eq "filing no issue" "$(fake_issues)" ""
