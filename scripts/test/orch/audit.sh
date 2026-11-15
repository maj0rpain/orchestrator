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
  parts=(--category documentation --finding-file "$finding" --location docs/a.md:12 --location README.md:3-9)
  tab="$(printf '\t')"
  errf="$(mktemp)"
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
fake_github
fake_label documentation ffffff "The repo's own"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "files with documentation already present" "$st" 0
assert_contains "leaving the repo's documentation label as the repo has it" "$(fake_labels)" \
  "documentation${tab}ffffff${tab}The repo's own"
assert_contains "and creating the repo's missing needs-triage" "$(fake_labels)" \
  "needs-triage${tab}e4e669${tab}Not yet triaged"

fake_github
fake_fail adapter_label_create "$GH_502"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>/dev/null)"; st=$?
assert_status "a failed create of the documentation label is ignored" "$st" 0
assert_eq "the issue is still opened and its number printed" "$out" "1"
fake_unfail

# --category is passed through: the issue carries that category label beside
# needs-triage.
for cat in bug enhancement; do
  fake_github
  out="$("$ORCH" audit file "Title" --category "$cat" --finding-file "$finding" --location a.md:1 2>&1)"; st=$?
  assert_status "files under --category $cat" "$st" 0
  assert_eq "labelling the issue $cat and needs-triage" "$(fake_labels_of "$out")" "$cat needs-triage "
done

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from.
fake_github
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
usage="orch: usage: orch.sh audit file <title> --category <bug|enhancement|documentation> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
refuse "an empty title" "orch: the title is empty" "" "${parts[@]}"
refuse "no title" "$usage"
refuse "a missing --finding-file" "$usage" "T" --category bug --location a.md:1
refuse "no --location" "$usage" "T" --category bug --finding-file "$finding"
refuse "an unknown flag" "$usage" "T" "${parts[@]}" --bogus x
refuse "a flag with no value" "$usage" "T" --category bug --finding-file "$finding" --location
refuse "a finding file given twice" "$usage" "T" "${parts[@]}" --finding-file "$finding"
refuse "no --category" "$usage" "T" --finding-file "$finding" --location a.md:1
refuse "a repeated --category" "$usage" "T" "${parts[@]}" --category bug
refuse "an unknown --category" "$usage" "T" --category question --finding-file "$finding" --location a.md:1
refuse "a finding file that does not exist" \
  "orch: finding file not found: /nonexistent/finding.md" \
  "T" --category bug --finding-file /nonexistent/finding.md --location a.md:1
blank="$(mktemp)"
printf '  \n\n' >"$blank"
refuse "a whitespace-only finding file" \
  "orch: finding file is empty: $blank" \
  "T" --category bug --finding-file "$blank" --location a.md:1
refuse "the location 'a.md:x'" \
  "orch: not a location: a.md:x (want <file>:<line> or <file>:<start>-<end>)" \
  "T" --category bug --finding-file "$finding" --location a.md:x
refuse "a location with a backtick in its file" \
  "orch: the rendered body does not parse back: locations (given 'a\`b.md:1', parsed '')" \
  "T" --category bug --finding-file "$finding" --location 'a`b.md:1'

# A finding file already holding a labelled line shadows the rendered one.
quoting="$(mktemp)"
printf 'It reads the line\n**Location:** `x.md:1`\nas a site.\n' >"$quoting"
out="$("$ORCH" audit file "T" --category bug --finding-file "$quoting" --location a.md:1 2>&1)"; st=$?
assert_status "a finding file holding a Location line is refused" "$st" 1
assert_contains "as a body that does not parse back" "$out" "the rendered body does not parse back: locations"
assert_eq "writing nothing" "$(fake_snapshot)" "$before"
printf 'It reads the line\n**Audited at:** abc123\nas a SHA.\n' >"$quoting"
out="$("$ORCH" audit file "T" --category bug --finding-file "$quoting" --location a.md:1 2>&1)"; st=$?
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

# --- audit begin ------------------------------------------------------------

echo
echo "audit begin"
new_repo >/dev/null
top="$(git rev-parse --show-toplevel)"
head_sha="$(git rev-parse HEAD)"
errf="$(mktemp)"
out="$("$ORCH" audit begin docs 2>"$errf")"; st=$?
assert_status "begins a docs audit" "$st" 0
case "$out" in
  "$top"/.orchestrator/audit/docs-[0-9]*-[0-9]*) found=absolute ;;
  *) found="$out" ;;
esac
assert_eq "printing the run directory's absolute path and nothing else" "$found" absolute
assert_eq "and nothing on stderr" "$(cat "$errf")" ""
assert_eq "the directory exists" "$(on_disk "$out")" present
assert_eq "recording the kind and the HEAD commit" "$(cat "$out/record")" "$(printf 'kind docs\ncommit %s' "$head_sha")"
assert_eq "git excludes the directory, so status shows nothing" "$(git status --porcelain)" ""
assert_eq "and the exclude names .orchestrator/ once" "$(grep -cxF .orchestrator/ "$(git rev-parse --git-common-dir)/info/exclude")" 1
for kind in code tests; do
  out="$("$ORCH" audit begin "$kind" 2>&1)"; st=$?
  assert_status "begins a $kind audit" "$st" 0
  assert_contains "its directory named for the kind" "$out" ".orchestrator/audit/$kind-"
done

# Refusals make nothing.
usage_all="orch: usage: orch.sh audit begin <code|docs|tests>
   or: orch.sh audit file <title> --category <bug|enhancement|documentation> --finding-file <f> --location <<file>:<line>|<file>:<start>-<end>> [--location ...]"
new_repo >/dev/null
for args in "begin" "begin bogus" "begin code extra" "bogus" ""; do
  # shellcheck disable=SC2086 # the words are the point
  out="$("$ORCH" audit $args 2>&1)"; st=$?
  assert_status "audit '$args' is refused" "$st" 1
  assert_eq "with the usage naming every form" "$out" "$usage_all"
  assert_eq "making no audit directory" "$(on_disk .orchestrator/audit)" absent
done

nohead="$(mktemp -d)"
git -C "$nohead" init -q
cd "$nohead" || exit 1
out="$("$ORCH" audit begin code 2>&1)"; st=$?
assert_status "a repo with no commit is refused" "$st" 1
assert_eq "saying HEAD cannot be read" "$out" "orch: cannot read the HEAD commit"
assert_eq "making nothing" "$(on_disk .orchestrator)" absent

# An existing directory is never reused: the date stub pins the stamp.
new_repo >/dev/null
shim="$(mktemp -d)"
printf '%s\n' '#!/bin/sh' 'case "$*" in "-u +%Y%m%d-%H%M%S") echo 20300101-000000 ;; *) exec /usr/bin/env date "$@" ;; esac' >"$shim/date"
chmod +x "$shim/date"
out="$(PATH="$shim:$PATH" "$ORCH" audit begin code 2>&1)"; st=$?
assert_status "the first run at a pinned stamp succeeds" "$st" 0
echo kept >"$out/area-1.md"
out2="$(PATH="$shim:$PATH" "$ORCH" audit begin code 2>&1)"; st=$?
assert_status "a second run at the same stamp is refused" "$st" 1
assert_contains "saying the directory exists" "$out2" "already exists"
assert_eq "leaving the first run as it was" "$(cat "$out/area-1.md")" kept

# A write failing after the directory is made removes it.
new_repo >/dev/null
exclude="$(git rev-parse --git-common-dir)/info/exclude"
rm -f "$exclude"
mkdir -p "$exclude"
out="$("$ORCH" audit begin tests 2>&1)"; st=$?
assert_status "an unwritable git exclude file fails the run" "$st" 1
assert_contains "dying with its orch line" "$out" "orch: cannot add"
assert_eq "leaving no run directory" "$(find .orchestrator/audit -mindepth 1 2>/dev/null | wc -l | tr -d ' ')" 0

# With and without an active flow, state.json is untouched.
new_repo >/dev/null
out="$("$ORCH" audit begin code 2>&1)"; st=$?
assert_status "runs with no flow" "$st" 0
assert_eq "and writes no state.json" "$(on_disk .orchestrator/state.json)" absent
fake_github
"$ORCH" init audit-flow >/dev/null 2>&1
state_fixture phase implement
before="$(cksum <.orchestrator/state.json)"
out="$("$ORCH" audit begin docs 2>&1)"; st=$?
assert_status "runs with an active flow" "$st" 0
assert_eq "leaving state.json unchanged" "$(cksum <.orchestrator/state.json)" "$before"
