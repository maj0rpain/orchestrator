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

# report_run: a fresh repo and an audit run holding two area files and a
# ranked file; the run directory is in $run, the commit in $head_sha.
report_run() {
  new_repo >/dev/null
  head_sha="$(git rev-parse HEAD)"
  run="$("$ORCH" audit begin code)"
  cat >"$run/area-1.md" <<'AREA'
@@ finding 1
Kind: latent bug
Location: a.sh:1, b.sh:2-3
Evidence: it <breaks> when `x & y` runs
```mermaid
graph TD; A-->B
```
Confidence: certain
@@ finding 2
Kind: inefficiency
Location: b.sh:2-3, c.sh:9
Evidence: slow
AREA
  cat >"$run/area-2.md" <<'AREA'
@@ finding 1
Kind: architecture deepening
Location: d.sh:5
Evidence: friction
```
Note: kept in a fence
```
AREA
  cat >"$run/ranked.md" <<'RANKED'
@@ scope the audit's scope
@@ areas 2
@@ note Timing mode
Mode: fast.

Trend: flat.
@@ top 1
Start here, because `a.sh` is hot.
@@ finding 1
From: area-1:1, area-1:2
Title: Latent bug in a.sh
Category: bug
Overlaps: 3
Evidence: restated <b>evidence</b>
@@ finding 2
From: area-2:1
Title: Deepen d.sh
Category: enhancement
@@ finding 3
Title: Whole finding with no source
Category: enhancement
Location: z.sh:4
Kind: inefficiency
Evidence: a `tick` and a fence:
```
Evidence: not a field
```
RANKED
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
   or: orch.sh audit report <dir> <out.html>
   or: orch.sh audit file --run <dir> <numbers>
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

# --- audit report -----------------------------------------------------------

echo
echo "audit report"
report_run
report="$run/report.html"
cp "$run/ranked.md" "$run/ranked.saved"; cp "$run/area-1.md" "$run/area-1.saved"; cp "$run/record" "$run/record.saved"
# report_reset: the run as report_run left it, for the next case.
report_reset() {
  cp "$run/ranked.saved" "$run/ranked.md"; cp "$run/area-1.saved" "$run/area-1.md"; cp "$run/record.saved" "$run/record"
}
res="$("$ORCH" audit report "$run" "$report")"; st=$?
assert_status "renders a report" "$st" 0
assert_eq "printing the report's path" "$res" "$report"
page="$(cat "$report")"
assert_contains "the head names the kind" "$page" "Audit report: code"
assert_contains "and the scope" "$page" "the audit&#39;s scope"
assert_contains "and the area count" "$page" '<dt class="font-semibold">Areas</dt><dd class="col-span-3">2</dd>'
assert_contains "and the recorded commit" "$page" "<code>$head_sha</code>"
assert_contains "and each note under its heading" "$page" '<h2 class="text-lg font-semibold">Timing mode</h2>'
assert_contains "the note's paragraphs break at a blank line" "$page" '<p class="my-2">Trend: flat.</p>'
assert_contains "the top recommendation links its finding" "$page" 'href="#finding-1">Finding 1: Latent bug in a.sh</a>'
assert_contains "with its reason, a span as code" "$page" '<code>a.sh</code> is hot.'
assert_contains "a From: reference carries the source's fields" "$page" '<p class="my-2">latent bug</p>'
assert_contains "a restated field replaces the source's, escaped" "$page" 'restated &lt;b&gt;evidence&lt;/b&gt;'
assert_contains "a merge lists every source's locations" "$page" "<li><code>a.sh:1</code></li>
<li><code>b.sh:2-3</code></li>
<li><code>c.sh:9</code></li>"
assert_contains "a finding with no source carries its own" "$page" '<h2 class="text-xl font-semibold">3. Whole finding with no source</h2>'
assert_contains "its inline span is code" "$page" '<code>tick</code>'
assert_contains "a fence is preformatted code, its field-looking line kept" "$page" '<pre class="overflow-x-auto bg-gray-100 p-3 rounded text-sm"><code>Evidence: not a field</code></pre>'
assert_contains "an overlap stated on one finding links the other" "$page" 'href="#finding-3">Finding 3: Whole finding with no source</a>'
assert_contains "and shows on the other" "$(grep -A25 'id="finding-3"' "$report")" 'href="#finding-1">Finding 1: Latent bug in a.sh</a>'
assert_eq "no src or href but the two CDNs and the page's own findings" \
  "$(grep -o '\(src\|href\)="[^"]*"' "$report" | grep -v '="#finding-[0-9]*"$' | sort | tr '\n' ' ')" \
  'src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js" src="https://cdn.tailwindcss.com" '
"$ORCH" audit report "$run" "$run/again.html" >/dev/null
assert_eq "the same run renders the same bytes" "$(cksum <"$run/again.html")" "$(cksum <"$report")"

echo
echo "audit report mermaid from a hunter's block"
report_reset
sed -i '/^Evidence: restated/d' "$run/ranked.md"
"$ORCH" audit report "$run" "$report" >/dev/null
assert_contains "an unrestated field keeps the hunter's fenced diagram" "$(cat "$report")" '<pre class="mermaid">graph TD; A--&gt;B</pre>'

echo
echo "audit report refusals"
report_reset
cp "$run/ranked.md" "$run/ranked.orig"
# report_refuse <what> <expected text> <sed script over ranked.md>: the one run
# above, its ranked file restored, then edited by the sed script.
report_refuse() {
  cp "$run/ranked.orig" "$run/ranked.md"
  printf 'earlier report\n' >"$report"
  sed -i "$3" "$run/ranked.md"
  res="$("$ORCH" audit report "$run" "$report" 2>&1)"; st=$?
  assert_status "$1 is refused" "$st" 1
  assert_contains "saying so" "$res" "orch: "
  assert_contains "naming the problem" "$res" "$2"
  assert_eq "leaving the earlier report" "$(cat "$report")" "earlier report"
  assert_eq "and no temporary file" "$(find "$run" -name "*.tmp.*" | wc -l | tr -d " ")" 0
}
report_refuse "a ranked file with no scope" "no @@ scope" '/^@@ scope/d'
report_refuse "a second scope" "a second @@ scope" '/^@@ areas/a @@ scope again'
report_refuse "a ranked file with no areas" "no @@ areas" '/^@@ areas/d'
report_refuse "a ranked file with neither top nor none" "exactly one of @@ top and @@ none" '/^@@ top/,/^Start here/d'
report_refuse "a finding gap" "expected @@ finding 2" 's/^@@ finding 2/@@ finding 3/'
report_refuse "a From naming a missing area file" "area-9.md" 's/^From: area-2:1/From: area-9:1/'
report_refuse "a From naming a missing block" "finding 7" 's/^From: area-2:1/From: area-2:7/'
report_refuse "a missing title" "has no Title" '/^Title: Deepen/d'
report_refuse "a multi-line title" "not one line" 's/^Title: Deepen d.sh/Title:/'
report_refuse "an unknown category" "'cheese'" 's/^Category: bug/Category: cheese/'
report_refuse "a missing category" "has no Category" '/^Category: bug/d'
report_refuse "a bad location" "not <file>:<line>" 's/^Location: z.sh:4/Location: z.sh/'
report_refuse "a finding with no location" "has no Location" '/^Location: z.sh:4/d'
report_refuse "an overlap outside the file" "'9'" 's/^Overlaps: 3/Overlaps: 9/'
report_refuse "an overlap with itself" "'1'" 's/^Overlaps: 3/Overlaps: 1/'
report_refuse "a top outside the file" "finding 9" 's/^@@ top 1/@@ top 9/'
report_refuse "an unknown @@ line" "unknown line" 's/^@@ areas 2/@@ areas 2\n@@ bogus/'
report_reset
rm "$run/record" "$report"
res="$("$ORCH" audit report "$run" "$report" 2>&1)"; st=$?
assert_status "a run directory with no record is refused" "$st" 1
assert_contains "naming the record" "$res" "no audit run record"
assert_eq "writing nothing" "$(on_disk "$report")" absent

echo
echo "audit report output path"
report_reset
res="$("$ORCH" audit report "$run" "$run/nodir/r.html" 2>&1)"; st=$?
assert_status "an out.html whose directory is missing is refused" "$st" 1
assert_contains "with an orch line" "$res" "orch: the directory for the report does not exist"
assert_eq "writing nothing" "$(on_disk "$run/nodir")" absent
if [ "$(id -u)" -ne 0 ]; then
  mkdir "$run/ro"
  printf 'earlier\n' >"$run/ro/r.html"
  chmod a-w "$run/ro"
  res="$("$ORCH" audit report "$run" "$run/ro/r.html" 2>&1)"; st=$?
  chmod u+w "$run/ro"
  assert_status "an out.html in a read-only directory is refused" "$st" 1
  assert_contains "with an orch line" "$res" "orch: cannot write the report"
  assert_eq "leaving the earlier report byte for byte" "$(cat "$run/ro/r.html")" earlier
fi

echo
echo "audit report-reference check in audit report"
report_reset
cp "$run/ranked.md" "$run/ranked.orig"
for phrase in "finding 2" "Findings #3" "CANDIDATE 4" "candidates 1" "this report" "This Report"; do
  cp "$run/ranked.orig" "$run/ranked.md"
  printf 'earlier report\n' >"$report"
  sed -i "s/^Title: Deepen d.sh/Title: Deepen d.sh like $phrase/" "$run/ranked.md"
  res="$("$ORCH" audit report "$run" "$report" 2>&1)"; st=$?
  assert_status "a title saying '$phrase' is refused" "$st" 1
  assert_contains "naming the phrase" "$res" "says '$phrase'"
  assert_eq "writing nothing" "$(cat "$report")" "earlier report"
done
report_reset
sed -i 's/^Evidence: restated <b>evidence<\/b>/Evidence: as in finding 2/' "$run/ranked.md"
res="$("$ORCH" audit report "$run" "$report" 2>&1)"; st=$?
assert_status "a restated field saying finding 2 is refused" "$st" 1
assert_contains "naming the field" "$res" "Evidence: says 'finding 2'"
report_reset
sed -i 's/^Evidence: restated <b>evidence<\/b>/Evidence: `finding 2` and "the report" read fine/' "$run/ranked.md"
sed -i 's/^Title: Whole finding with no source/Title: See the report/' "$run/ranked.md"
"$ORCH" audit report "$run" "$report" >/dev/null; st=$?
assert_status "the report and a backticked finding 2 are accepted" "$st" 0
report_reset
sed -i "s/^Confidence: certain/Confidence: as in finding 3/" "$run/area-1.md"
res="$("$ORCH" audit report "$run" "$report" 2>&1)"; st=$?
assert_status "a hunter's block saying finding 3 is refused" "$st" 1
sed -i "s/^Evidence: restated <b>evidence<\/b>/Confidence: sure/" "$run/ranked.md"
"$ORCH" audit report "$run" "$report" >/dev/null; st=$?
assert_status "until the ranked block restates the field" "$st" 0
report_reset
sed -i "s/^Evidence: not a field/finding 9 and this report/" "$run/ranked.md"
"$ORCH" audit report "$run" "$report" >/dev/null; st=$?
assert_status "a fenced block is not checked" "$st" 0
report_reset
printf '@@ finding 4\nFrom: area-2:1\nTitle: T4\nCategory: bug\nOverlaps: 1\n' >>"$run/ranked.md"
"$ORCH" audit report "$run" "$report" >/dev/null; st=$?
assert_status "From: and Overlaps: values are not checked" "$st" 0
echo
echo "audit report nothing found"
new_repo >/dev/null
run="$("$ORCH" audit begin tests)"
printf '@@ scope s\n@@ areas 1\n@@ none\n' >"$run/ranked.md"
"$ORCH" audit report "$run" "$run/r.html" >/dev/null; st=$?
assert_status "renders a nothing-found report" "$st" 0
assert_contains "saying nothing was found" "$(cat "$run/r.html")" "found nothing"
assert_contains "naming its kind" "$(cat "$run/r.html")" "Audit report: tests"
assert_eq "with no top recommendation" "$(grep -c 'Top recommendation' "$run/r.html")" 0

echo
echo "audit report usage"
new_repo >/dev/null
for args in "report" "report only-one" "report a b c"; do
  # shellcheck disable=SC2086 # the words are the point
  res="$("$ORCH" audit $args 2>&1)"; st=$?
  assert_status "audit '$args' is refused" "$st" 1
  assert_contains "with the usage naming report" "$res" "orch: usage: orch.sh audit begin <code|docs|tests>
   or: orch.sh audit report <dir> <out.html>
   or: orch.sh audit file"
done


echo
echo "audit report-reference check in audit file"
audit_repo
before="$(fake_snapshot)"
for phrase in "finding 2" "candidate #3" "this report"; do
  out="$("$ORCH" audit file "Fix it as in $phrase" "${parts[@]}" 2>&1)"; st=$?
  assert_status "a title saying '$phrase' is refused" "$st" 1
  assert_contains "naming the phrase" "$out" "says '$phrase'"
  assert_eq "writing nothing" "$(fake_snapshot)" "$before"
done
printf 'Line one.\nSame as Finding 4 here.\n' >"$finding"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "a finding file saying Finding 4 is refused" "$st" 1
assert_contains "naming its line" "$out" "line 2 says 'Finding 4'"
assert_eq "writing nothing" "$(fake_snapshot)" "$before"
printf 'The report says `finding 4`.\n```\nthis report\n```\n' >"$finding"
out="$("$ORCH" audit file "Title" "${parts[@]}" 2>&1)"; st=$?
assert_status "the report, a span and a fence are accepted" "$st" 0

# --- audit file batch -------------------------------------------------------

# batch_run: report_run, on the store-backed fake with the repo's own
# needs-triage label; the next issue is #40.
batch_run() {
  report_run
  fake_github
  fake_label needs-triage 000000 "The repo's own"
  fake_next_issue 40
  tab="$(printf '\t')"
  errf="$(mktemp)"
}

echo
echo "audit file batch"
batch_run
git commit -q --allow-empty -m "the checkout moves on"
out="$("$ORCH" audit file --run "$run" 3,1 2>"$errf")"; st=$?
assert_status "files a pick" "$st" 0
assert_eq "printing one line per finding, in number order, whatever order was given" "$out" \
  "1${tab}40${tab}filed
3${tab}41${tab}filed"
assert_eq "and nothing on stderr" "$(cat "$errf")" ""
want="$(printf '%s\n' '**Kind:** latent bug' '' '**Evidence:** restated <b>evidence</b>' '' \
  '**Confidence:** certain' '' '**Location:** `a.sh:1`' '' '**Location:** `b.sh:2-3`' '' \
  '**Location:** `c.sh:9`' '' "**Audited at:** $head_sha" '' '**Related:** #41' ''; printf x)"
assert_eq "the body is the resolved fields, a Location line each, the recorded commit and Related, byte for byte" \
  "$(fake_body_of 40; printf x)" "$want"
assert_ne "the recorded commit is not the moved HEAD" "$head_sha" "$(git rev-parse HEAD)"
assert_contains "the other side of the overlap, stated on one side only, takes the line too" \
  "$(fake_body_of 41)" '**Related:** #40'
assert_eq "labels: needs-triage and the category" "$(fake_labels_of 40)" "bug needs-triage "
assert_eq "title passed through" "$(fake_title_of 40)" "Latent bug in a.sh"
before="$(fake_snapshot)"
out="$("$ORCH" audit file --run "$run" 1,3 2>&1)"; st=$?
assert_status "a second run succeeds" "$st" 0
assert_eq "reporting both open" "$out" "1${tab}40${tab}open
3${tab}41${tab}open"
assert_eq "and writing nothing" "$(fake_snapshot)" "$before"

echo
echo "audit file batch refusals"
batch_run
before="$(fake_snapshot)"
usage_run="orch: usage: orch.sh audit begin <code|docs|tests>
   or: orch.sh audit report <dir> <out.html>
   or: orch.sh audit file --run <dir> <numbers>"
for args in "1,1" "9" "0" "x" "1,,x"; do
  out="$("$ORCH" audit file --run "$run" "$args" 2>&1)"; st=$?
  assert_status "numbers '$args' are refused" "$st" 1
  assert_contains "with an orch: line" "$out" "orch: "
done
out="$("$ORCH" audit file --run "$run" 2>&1)"; st=$?
assert_status "no numbers is refused" "$st" 1
assert_contains "with the usage naming every form" "$out" "$usage_run"
assert_contains "the one-finding form among them" "$out" "or: orch.sh audit file <title>"
out="$("$ORCH" audit file --run "$run" "" 2>&1)"; st=$?
assert_status "empty numbers are refused" "$st" 1
sed -i 's/^Evidence: a `tick`/Evidence: see finding 2 and a `tick`/' "$run/ranked.md"
out="$("$ORCH" audit file --run "$run" 3 2>&1)"; st=$?
assert_status "a report reference is refused through --run" "$st" 1
assert_contains "naming the phrase" "$out" "finding 2"
assert_eq "reaching no GitHub call" "$(gh_calls)" "0"
assert_eq "and writing nothing" "$(fake_snapshot)" "$before"
rm -f "$run/ranked.md"
out="$("$ORCH" audit file --run "$run" 1 2>&1)"; st=$?
assert_status "a missing ranked file is refused" "$st" 1
assert_eq "reaching no GitHub call" "$(gh_calls)" "0"

echo
echo "audit file batch category"
batch_run
printf 'Category: bug\n' >>"$run/area-2.md"
sed -i '/^From: area-2:1/{n;n;d}' "$run/ranked.md"
out="$("$ORCH" audit file --run "$run" 2 2>&1)"; st=$?
assert_status "files a finding whose category is in the hunter's block" "$st" 0
assert_eq "labelled with it" "$(fake_labels_of 40)" "bug needs-triage "
assert_eq "no Related for a finding that overlaps nothing" \
  "$(fake_body_of 40 | grep -c Related || true)" "0"

echo
echo "audit file batch related"
batch_run
# Finding 2 overlaps 3, too: 1 and 3 are linked, 2 and 3 are, 1 and 2 are not.
sed -i 's/^Category: enhancement$/&/; /^From: area-2:1/a Overlaps: 3' "$run/ranked.md"
out="$("$ORCH" audit file --run "$run" 3 2>&1)"
assert_eq "an overlap outside the batch writes nothing" "$(fake_body_of 40 | grep -c Related || true)" "0"
# The open issue's body takes CRLF line ends and trailing newlines.
fake_issue_body 40 "$(fake_body_of 40 | sed 's/$/\r/')"$'\r\n\r\n\n'
out="$("$ORCH" audit file --run "$run" 1,3 2>"$errf")"; st=$?
assert_status "a batch over an open issue" "$st" 0
assert_eq "the open one is reported" "$out" "1${tab}41${tab}filed
3${tab}40${tab}open"
assert_contains "CRLF and trailing newlines differences still take the Related line" "$(fake_body_of 40)" '**Related:** #41'
assert_eq "without a warning" "$(cat "$errf")" ""
out="$("$ORCH" audit file --run "$run" 2,3 2>&1)"; st=$?
assert_status "a second batch" "$st" 0
assert_contains "keeps the first batch's number and adds its own" "$(fake_body_of 40)" '**Related:** #41 #42'
assert_contains "no chaining: 1 and 2 are not linked" "$(fake_body_of 41)" '**Related:** #40'
assert_not_contains "and 1 does not name 2" "$(fake_body_of 41)" '#42'
assert_contains "2 names only 3" "$(fake_body_of 42)" '**Related:** #40'

echo
echo "audit file batch rewritten issue"
batch_run
"$ORCH" audit file --run "$run" 3 >/dev/null 2>&1
fake_issue_body 40 "my own text"
out="$("$ORCH" audit file --run "$run" 1,3 2>"$errf")"; st=$?
assert_status "a rewritten open issue does not fail the batch" "$st" 0
assert_eq "left alone" "$(fake_body_of 40)" "my own text"
assert_contains "with a warning naming it" "$(cat "$errf")" "#40"
assert_contains "the other issue still takes its line" "$(fake_body_of 41)" '**Related:** #40'

echo
echo "audit file batch open title"
batch_run
fake_issue 50 open
fake_issue_title 50 "Deepen d.sh"
fake_issue_body 50 "mine"
out="$("$ORCH" audit file --run "$run" 2 2>&1)"; st=$?
assert_status "an already-open title" "$st" 0
assert_eq "files nothing and reports it open" "$out" "2${tab}50${tab}open"
assert_eq "no new issue" "$(fake_issues)" "50 "

echo
echo "audit file batch failures"
batch_run
fake_fail_after adapter_issue_create 1
out="$("$ORCH" audit file --run "$run" 1,3 2>&1)"; st=$?
assert_status "a failed create stops the command" "$st" 1
assert_contains "with its orch: message" "$out" "orch: gh could not create the issue"
assert_eq "the issue created stays" "$(fake_issues)" "40 "
fake_unfail
out="$("$ORCH" audit file --run "$run" 1,3 2>&1)"; st=$?
assert_status "the rerun finishes" "$st" 0
assert_eq "finding it by title" "$out" "1${tab}40${tab}open
3${tab}41${tab}filed"
assert_contains "with its Related line written" "$(fake_body_of 40)" '**Related:** #41'
batch_run
fake_fail adapter_issue_body_edit
out="$("$ORCH" audit file --run "$run" 1,3 2>&1)"; st=$?
assert_status "a failed Related write stops the command" "$st" 1
assert_contains "with its orch: message" "$out" "orch: gh could not write issue #40"
assert_eq "both issues exist" "$(fake_issues)" "40 41 "
fake_unfail
out="$("$ORCH" audit file --run "$run" 1,3 2>&1)"; st=$?
assert_status "the rerun finishes" "$st" 0
assert_contains "writing the line" "$(fake_body_of 41)" '**Related:** #40'
before="$(fake_snapshot)"
"$ORCH" audit file --run "$run" 1,3 >/dev/null 2>&1
assert_eq "and a second run writes nothing" "$(fake_snapshot)" "$before"
