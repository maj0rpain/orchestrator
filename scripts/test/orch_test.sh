#!/usr/bin/env bash
#
# Tests for scripts/orch.sh.
#
# orch.sh is where silent wrongness hides: `doctor` returning success on a
# deleted branch, a missing triage label, or a handoff with an empty required
# section, are bugs you would experience as generic confusion three phases
# later - or, worse, as a phase that dies once the session that could have
# fixed it has been cleared. Each runs
# against a throwaway git repo in $TMPDIR - nothing here touches a real flow.

ORCH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/orch.sh"
PASS=0
FAIL=0

ok()   { printf '  ok   %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  FAIL %s\n     %s\n' "$1" "$2"; FAIL=$((FAIL + 1)); }

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not contain '$3': $2" ;; esac
}
assert_status() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}

# A fresh repo with the tracker precondition satisfied, cwd inside it.
new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  mkdir -p "$d/docs/agents"
  echo "# tracker" >"$d/docs/agents/issue-tracker.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  cd "$d" || exit 1
  printf '%s\n' "$d"
}

writeln() { printf '%s\n' "$@"; }

complete_plan_handoff() {
  writeln '## Decisions' 'Use X.' '' \
          '## Rejected alternatives' 'Y, because Z.' '' \
          '## Constraints' 'Must run offline.' '' \
          '## Open assumptions' 'Assumes W.' >"$1"
}

complete_spec_handoff() {
  writeln '## Spec issue' '#1.' '' \
          '## Seams' 'The CLI.' '' \
          '## Spec review changelog' 'Not reviewed.' >"$1"
}

complete_implement_handoff() {
  writeln '## PR' '#3.' '' \
          '## Spec issue' '#1.' '' \
          '## Base SHA' 'abc1234.' '' \
          '## Deviations' 'None.' '' \
          '## Verification' 'scripts/test/orch_test.sh' >"$1"
}

complete_review_handoff() {
  writeln '## PR' '#3.' '' \
          '## Spec issue' '#1.' '' \
          '## Base SHA' 'abc1234.' '' \
          '## Verification' 'scripts/test/orch_test.sh' '' \
          '## Chosen work' 'Split the CI classifier out.' '' \
          '## Already settled' 'Declined the naming nit.' >"$1"
}

# --- doctor harness ---------------------------------------------------------

# A fake `gh` on PATH. doctor's severity rules turn on the difference between
# "GitHub said no" and "GitHub could not tell us", and that difference cannot be
# arranged against a real gh. GH_STUB_MODE picks which answer comes back:
#   ok        authenticated, repo resolves, every documented label exists
#   noauth    `gh auth status` fails the way an unauthenticated gh does
#   offline   every call fails with a connection error
#   nolabels  authenticated, but the repo carries none of the documented labels
# GH_STUB_LOG, when set, names a file the stub appends each subcommand to, which
# is how a test asserts that a scope made no network call at all.
#
# `pr checks` answers separately, because the CI classifier is the one caller
# that has to see the answer *change* between calls. GH_STUB_CHECKS and
# GH_STUB_REQUIRED are each a `|`-separated script of answers (green, failing,
# pending, none, boom), consumed one per call with the last repeating and counted
# in the file GH_STUB_CHECKS_N / GH_STUB_REQUIRED_N names. They advance
# independently, because the classifier asks the two probes different questions:
# what branch protection requires, and what ran on the commit.
stub_gh() {
  local d
  d="$(mktemp -d)"
  cat >"$d/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_STUB_LOG:-}" ]; then printf '%s\n' "$1" >>"$GH_STUB_LOG"; fi
if [ "${GH_STUB_MODE:-ok}" = offline ]; then
  echo "dial tcp: lookup api.github.com: no such host" >&2
  exit 1
fi
case "$1" in
  auth)
    if [ "${GH_STUB_MODE:-ok}" = noauth ]; then
      echo "You are not logged into any GitHub hosts." >&2
      exit 1
    fi
    echo "Logged in to github.com" ;;
  repo) printf '%s\n' ${GH_STUB_REPO-acme/widgets main} ;;
  label)
    if [ "${GH_STUB_MODE:-ok}" = labelfail ]; then exit 1; fi
    if [ "${GH_STUB_MODE:-ok}" != nolabels ]; then
      printf '%s\n' "${GH_STUB_LABELS-needs-triage
ready-for-agent}"
    fi ;;
  pr)
    case "$2" in
      ready) exit "${GH_STUB_READY_EXIT:-0}" ;;
      checks)
        req=0
        for a in "$@"; do if [ "$a" = --required ]; then req=1; fi; done
        if [ "$req" = 1 ]; then
          script="${GH_STUB_REQUIRED:-none}"; counter="${GH_STUB_REQUIRED_N:-}"
        else
          script="${GH_STUB_CHECKS:-green}"; counter="${GH_STUB_CHECKS_N:-}"
        fi
        i=1
        if [ -n "$counter" ]; then
          i=$(( $(cat "$counter" 2>/dev/null || echo 0) + 1 ))
          printf '%s\n' "$i" >"$counter"
        fi
        answer="$(printf '%s' "$script" | awk -F'|' -v i="$i" '{ print (i <= NF) ? $i : $NF }')"
        case "$answer" in
          green)   echo '[{"bucket":"pass","name":"build","state":"SUCCESS"}]' ;;
          failing) echo '[{"bucket":"fail","name":"build","state":"FAILURE"},{"bucket":"pass","name":"lint","state":"SUCCESS"}]' ;;
          pending) echo '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]'; exit 8 ;;
          none)    echo "no checks reported on the 'topic' branch" >&2; exit 1 ;;
          boom)    echo "dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
        esac ;;
      *) echo "${GH_STUB_PR_STATE:-OPEN}" ;;
    esac ;;
esac
GH
  chmod +x "$d/gh"
  PATH="$d:$PATH"
}

# A fake mattpocock-skills install under a throwaway HOME holding exactly the
# skills named. The *partial* install is the regression doctor exists to catch,
# and it is unreachable through the extremes: with only all-present and
# all-absent, the per-skill check is exercised by whatever happens to be
# installed on the machine running the tests, which is to say not at all.
stub_mattpocock() {
  local home base s
  home="$(mktemp -d)"
  base="$home/.claude/plugins/cache/claude-plugins-official/mattpocock-skills/1.2.3/skills/engineering"
  for s in "$@"; do
    mkdir -p "$base/$s"
    echo "# $s" >"$base/$s/SKILL.md"
  done
  printf '%s\n' "$home"
}

# The documented triage-label table, in the shape the setup skill writes it:
# a header row, a separator row, and backticked labels in the second column.
labels_doc() {
  writeln '# Triage Labels' '' \
          '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
          '| -------------------------- | -------------------- | ----------- |' \
          '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
          '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' \
          '' 'Edit the right-hand column to match whatever vocabulary you use.' >"$1"
}

# A repo where every --env check passes, so a test can break exactly one thing
# and attribute the result to it.
healthy_repo() {
  new_repo >/dev/null
  git remote add origin https://github.com/acme/widgets.git
  labels_doc docs/agents/triage-labels.md
  printf '%s\n' ".orchestrator/" >>.git/info/exclude
  stub_gh
  export CLAUDE_PLUGIN_ROOT="$PWD"
  HOME="$(stub_mattpocock to-spec implement code-review handoff)"
  export HOME
  unset GH_STUB_MODE
}

# A PATH with everything orch.sh reaches for except jq. Reporting "jq is
# missing" is the one thing doctor has to do without jq, so the only honest way
# to test it is to actually take jq away.
path_without_jq() {
  local d t p
  d="$(mktemp -d)"
  for t in env bash git gh awk sed grep tr cat sort tail head date mktemp mv rm mkdir chmod basename dirname printf; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "$d/$t"; fi
  done
  printf '%s\n' "$d"
}

echo "orch.sh tests"

# --- init -------------------------------------------------------------------
echo
echo "init"
new_repo >/dev/null
out="$("$ORCH" init "My Feature!!")"
assert_eq "normalises slug to kebab-case" "$out" "my-feature"
assert_eq "state starts at the spec phase" "$("$ORCH" state get phase)" "spec"
assert_eq "iteration starts at zero" "$("$ORCH" state get iteration)" "0"
assert_eq "issue starts unset" "$("$ORCH" state get issue)" ""
assert_contains "excludes .orchestrator/ without touching .gitignore" \
  "$(cat .git/info/exclude)" ".orchestrator/"
assert_eq "leaves the working tree clean" "$(git status --porcelain)" ""

out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "refuses a second concurrent flow" "$st" 1
assert_contains "explains how to clear the active flow" "$out" "abort"

# --- state ------------------------------------------------------------------
echo
echo "state"
assert_eq "round-trips a string value" \
  "$("$ORCH" state set branch orch/1-x; "$ORCH" state get branch)" "orch/1-x"
"$ORCH" state set issue 42
assert_eq "coerces a numeric value to a number" "$("$ORCH" state get issue)" "42"
assert_eq "stores issue as JSON number, not string" \
  "$("$ORCH" state get | jq -r '.issue | type')" "number"
"$ORCH" state set issue null
assert_eq "accepts an explicit null" "$("$ORCH" state get | jq -r '.issue | type')" "null"

# --- handoff path -----------------------------------------------------------
echo
echo "handoff path"
assert_contains "spec phase reads the plan handoff"      "$("$ORCH" handoff path spec)"      "01-plan.md"
assert_contains "implement phase reads the spec handoff" "$("$ORCH" handoff path implement)" "02-spec.md"
assert_contains "review phase reads the implement handoff" "$("$ORCH" handoff path review)"  "03-implement.md"

# --- handoff validate -------------------------------------------------------
echo
echo "handoff validate"
h="$("$ORCH" handoff path spec)"
complete_plan_handoff "$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "passes a complete handoff" "$st" 0

writeln '## Decisions' 'Use X.' '' '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is missing" "$st" 1
assert_contains "names the missing section" "$out" "Rejected alternatives"

# The high-value case: the section the spec writer is most likely to leave as a
# bare heading, which would let already-killed alternatives get re-proposed.
complete_plan_handoff "$h"
writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "fails when a required section is present but empty" "$st" 1
assert_contains "reports it as empty, not missing" "$out" "empty section"

writeln '## Decisions' 'Use X.' '' '## Rejected alternatives' '   ' '' \
        '## Constraints' 'None.' '' '## Open assumptions' 'None.' >"$h"
out="$("$ORCH" handoff validate "$h" 2>&1)"; st=$?
assert_status "treats a whitespace-only section as empty" "$st" 1

# --- archive ----------------------------------------------------------------
echo
echo "archive"
complete_plan_handoff "$h"
dest="$("$ORCH" archive)"
assert_contains "archive path carries the slug" "$dest" "my-feature"
assert_eq "live state is cleared" "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"
assert_eq "handoff is preserved under archive/" \
  "$([ -f "$dest/handoff/01-plan.md" ] && echo present || echo gone)" "present"
out="$("$ORCH" status 2>&1)"
assert_contains "status reports no active flow afterwards" "$out" "No active flow"
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "a new flow can start after archiving" "$st" 0

# --- default-branch ---------------------------------------------------------
# The base every feature branch forks from. Getting this wrong is silent: work
# lands on top of the wrong branch and nothing complains until review.
echo
echo "default-branch"
new_repo >/dev/null
STUB="$(mktemp -d)"
cat >"$STUB/gh" <<'GH'
#!/usr/bin/env bash
[ "${GH_STUB_FAIL:-0}" = "1" ] && exit 1
echo "trunk"
GH
chmod +x "$STUB/gh"

# origin/HEAD is a local pointer frozen at clone time; GitHub's answer must win.
git remote add origin https://example.invalid/x/y.git
git checkout -q -b some-feature
git update-ref refs/remotes/origin/some-feature HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/some-feature
assert_eq "prefers GitHub's answer over a stale origin/HEAD" \
  "$(PATH="$STUB:$PATH" "$ORCH" default-branch)" "trunk"
assert_eq "falls back to origin/HEAD when gh cannot answer" \
  "$(PATH="$STUB:$PATH" GH_STUB_FAIL=1 "$ORCH" default-branch)" "some-feature"
git symbolic-ref -d refs/remotes/origin/HEAD
assert_eq "falls back to main when nothing else answers" \
  "$(PATH="$STUB:$PATH" GH_STUB_FAIL=1 "$ORCH" default-branch)" "main"

# --- mp-skill ---------------------------------------------------------------
# Resolved by glob at runtime, never by pinned version: the version in the cache
# path changes underneath us.
echo
echo "mp-skill"
if "$ORCH" mp-skill >/dev/null 2>&1; then
  assert_contains "resolves to-spec across category dirs" "$("$ORCH" mp-skill to-spec)" "/to-spec/SKILL.md"
  assert_contains "resolves handoff from another category" "$("$ORCH" mp-skill handoff)" "/handoff/SKILL.md"
  out="$("$ORCH" mp-skill definitely-not-a-skill 2>&1)"; st=$?
  assert_status "rejects an unknown skill name" "$st" 1
  assert_contains "names what it could not find" "$out" "definitely-not-a-skill"
else
  echo "  skip (mattpocock-skills not installed)"
fi

# --- doctor -----------------------------------------------------------------
# The two commands doctor replaces both returned success on the failures that
# actually end flows, so what these assert is the *severity* of each condition,
# not just that it got a mention.
echo
echo "doctor"
healthy_repo

out="$("$ORCH" doctor --nonsense 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--nonsense"

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes a healthy repo" "$st" 0
assert_contains "keeps the ok-line format of the commands it replaces" "$out" "ok    git present"
assert_contains "opens with a bare group header" "$out" "tools"
assert_contains "summarises severities on the last line" \
  "$(printf '%s\n' "$out" | tail -1)" "0 FAIL"

# jq gone is the awkward case: every other part of orch.sh needs it, so the one
# message the user needs most is the one that cannot be printed the usual way.
out="$(PATH="$(path_without_jq)" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when jq is missing" "$st" 1
assert_contains "names jq rather than dying mid-report" "$out" "jq"
assert_contains "still reaches the summary line without jq" "$out" " FAIL"

# Severity is the behaviour under test, not the wording: "GitHub said no" must
# FAIL and "GitHub could not tell us" must only warn. Written backwards, doctor
# either blocks every flow run away from a good network or waves through the two
# failures it exists to catch, and both look plausible in a passing test suite.
healthy_repo
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when a documented label is missing from the repo" "$st" 1
assert_contains "names the missing label with its backticks stripped" "$out" "ready-for-agent"
assert_contains "gives the command that creates it" "$out" 'gh label create "ready-for-agent"'
assert_contains "indents the remedy under its FAIL by six spaces" \
  "$out" "$(printf '\n      gh label create')"
assert_eq "strips the backticks the doc writes labels in" \
  "$(printf '%s\n' "$out" | grep -c '`')" "0"
assert_contains "counts one FAIL and no warns" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 1 FAIL"

healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning |' \
        '| -------------------------- | -------------------- | ------- |' \
        '| `needs-triage`             | `needs triage`       | Look    |' >docs/agents/triage-labels.md
out="$(GH_STUB_LABELS='needs triage' "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label with a space in it is one label, not two" "$st" 0
out="$(GH_STUB_MODE=nolabels "$ORCH" doctor --env 2>&1)"
assert_contains "quotes a multi-word label in the remedy" "$out" 'gh label create "needs triage"'

# GitHub answered the auth probe and then would not answer this one: an absent
# answer, not a "no", so it warns.
healthy_repo
out="$(GH_STUB_MODE=labelfail "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unlistable label set does not block the flow" "$st" 0
assert_contains "says the labels could not be listed" "$out" "could not be listed"

healthy_repo
out="$(GH_STUB_MODE=offline "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "does not fail merely because GitHub is unreachable" "$st" 0
assert_contains "collapses the checks that needed GitHub into one line" \
  "$out" "checks skipped: GitHub is not reachable"
assert_eq "emits one skip line, not one per skipped check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"
# The skip lines are a group like any other, so they carry a header and a blank
# line rather than trailing loose off the end of the last one.
assert_contains "puts the skipped group under a bare header" \
  "$out" "$(printf '\n\nskipped\nwarn  ')"

out="$(GH_STUB_MODE=noauth "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when gh is not authenticated" "$st" 1
assert_contains "gives the login command" "$out" "gh auth login"
assert_contains "skips the checks that depended on the answer" "$out" "skipped: not authenticated"

out="$(GH_STUB_REPO='acme/widgets ' "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unresolved default branch does not block the flow" "$st" 0
assert_contains "warns that the default branch came from a fallback" "$out" "default branch"

# A partial install is the regression this feature exists to catch: find_mattpocock
# probes one skill file, so it passes, and the spec phase then dies with the
# context that could have fixed it already cleared.
healthy_repo
HOME="$(stub_mattpocock implement code-review)"; export HOME
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a partial mattpocock-skills install" "$st" 1
assert_contains "names one missing skill" "$out" "to-spec"
assert_contains "names the other missing skill" "$out" "handoff"
assert_eq "says nothing about the skills that are present" \
  "$(printf '%s\n' "$out" | grep -c 'code-review')" "0"

out="$(HOME=/nonexistent "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails cleanly when mattpocock-skills is absent" "$st" 1
assert_contains "gives the install command" "$out" "/plugin install mattpocock-skills"
assert_contains "skips the per-skill check rather than deriving a second FAIL" \
  "$out" "1 skill check skipped"

# Labels are parsed from the doc rather than hardcoded, so the parser is what
# decides whether doctor is right in a repo that customised its vocabulary.
# A narrower table would hand $3 whatever column sits last, so doctor would go
# demanding that the repo create labels named after the Meaning text. Parsing to
# nothing is the honest answer; inventing one is the worst thing a diagnostic
# can do.
# The width belongs to one table, and a doc may hold more than one. A second,
# narrower table's *header* row arrives a line before the separator that would
# correct the width, so without a reset at the end of the block that heading
# gets read out as a label and demanded of the repo.
healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '' '## Glossary' '' \
        '| Term | Definition |' \
        '| ---- | ---------- |' \
        '| flow | a run       |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reads only the labels table, not every table in the doc" \
  "$out" "1 triage labels"
assert_eq "does not read a heading out of a second, narrower table" \
  "$(printf '%s\n' "$out" | grep -c 'Definition')" "0"
assert_status "and does not demand the repo create it" "$st" 0

# The width comes from the separator row, because only there is an empty last
# field unambiguous. On a data row it is equally an empty last *cell*, and a row
# that drops its trailing pipe *and* leaves Meaning blank looks exactly like a
# two-column row - so reading the width off that row costs a real label.
healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an empty last cell does not cost the row its label" "$st" 0
assert_contains "reads both labels, not just the one with a Meaning" "$out" "2 triage labels"

# Markdown lets a row drop its trailing pipe, and the width is read off the
# separator row precisely so that such a doc still parses.
healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table without its trailing pipes still parses" "$st" 0
assert_contains "reads both labels out of it" "$out" "2 triage labels"

healthy_repo
writeln '# Triage Labels' '' \
        '| Label          | Meaning     |' \
        '| -------------- | ----------- |' \
        '| `needs-triage` | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a table that is not the documented shape" "$st" 1
assert_eq "does not read a label out of some other column" \
  "$(printf '%s\n' "$out" | grep -c 'Evaluate it')" "0"
assert_contains "points at the setup skill instead" "$out" "setup-matt-pocock-skills"

# The width rule now hinges entirely on recognising the separator row, and these
# are the two ways that recognition goes wrong: a separator dressed with
# alignment colons, and a doc that never has one.
healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| :------------------------- | :------------------: | ----------: |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an alignment-colon separator is still a separator" "$st" 0
assert_contains "reads the labels under it" "$out" "2 triage labels"

healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table with no separator row parses to nothing" "$st" 1
assert_eq "reads no label out of a table it never confirmed the width of" \
  "$(printf '%s\n' "$out" | grep -c 'needs-triage')" "0"
assert_contains "points at the setup skill" "$out" "setup-matt-pocock-skills"

healthy_repo
writeln '# Triage Labels' '' 'This repo does not use a table.' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc parses to no labels" "$st" 1
assert_contains "points at the setup skill" "$out" "setup-matt-pocock-skills"

healthy_repo
rm docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc is absent entirely" "$st" 1
assert_contains "says the doc is missing rather than that it lists nothing" \
  "$out" "triage-labels.md is missing"

# A label list long enough to fill the page is a list that may be cut off, so
# naming labels as missing from it would be a FAIL derived from not knowing.
healthy_repo
out="$(GH_STUB_LABELS="$(seq 1 1000)" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label list that filled the page does not FAIL" "$st" 0
assert_contains "names the labels it cannot vouch for" "$out" "cannot confirm:"
assert_contains "names them individually" "$out" "needs-triage, ready-for-agent"

# ...but a page that filled up and still held every documented label answered
# the question. The caveat qualifies a negative; there is no negative here.
healthy_repo
out="$(GH_STUB_LABELS="$(printf '%s\n' needs-triage ready-for-agent; seq 1 1000)" \
  "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a full page that held every label is still a pass" "$st" 0
assert_contains "does not hedge an answer it actually has" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

healthy_repo
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "counts only the documented labels, not the header row" \
  "$out" "2 triage labels"

healthy_repo
: >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing git exclude line warns without blocking" "$st" 0
assert_contains "counts one warn and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "gives a command that adds the exclude line" "$out" "info/exclude"

healthy_repo
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "running orch.sh by hand is not a broken install" "$st" 0
assert_contains "warns about the unset plugin root" "$out" "CLAUDE_PLUGIN_ROOT"

healthy_repo
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "separates groups with a blank line and a bare header" \
  "$out" "$(printf '\n\nauth & remotes\n')"
assert_contains "a fully healthy repo reports no warns and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"
# Asserted against the lines actually printed rather than a literal, so adding a
# check to the registry cannot quietly make the count wrong.
assert_eq "the summary's ok count matches the ok lines it printed" \
  "$(printf '%s\n' "$out" | tail -1 | sed 's/ ok,.*//')" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')"

# --- doctor --flow ----------------------------------------------------------
# An empty answer must never read as a healthy one: --flow is asked explicitly
# about a flow, so no flow is a failure there and a plain statement everywhere
# else.
healthy_repo
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow refuses to answer when there is no flow" "$st" 1
assert_contains "says why it cannot answer" "$out" "no active flow"

out="$("$ORCH" doctor 2>&1)"; st=$?
assert_status "bare doctor is safe to run with no flow" "$st" 0
assert_contains "states there is no flow instead of failing" "$out" "ok    no active flow"
assert_contains "bare doctor covers the environment too" "$out" "tools"

"$ORCH" init flowtest >/dev/null
complete_plan_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a fresh flow is healthy" "$st" 0
assert_contains "reports the phase" "$out" "phase: spec"
assert_eq "--flow leaves the environment alone" \
  "$(printf '%s\n' "$out" | grep -c '^tools$')" "0"
assert_eq "stays quiet about an upstream before the implement phase" \
  "$(printf '%s\n' "$out" | grep -c 'upstream')" "0"

# /orchestrator:next and /orchestrator:status both run this scope every time, and
# a flow with no PR recorded has nothing to ask GitHub about.
ghlog="$(mktemp)"
GH_STUB_LOG="$ghlog" "$ORCH" doctor --flow >/dev/null 2>&1
assert_eq "a flow with no PR asks GitHub nothing" "$(grep -c . "$ghlog")" "0"

# One unparseable file is one problem. Four checks each reading it again would
# print jq's parse error mid-report and then four ok lines that are not true.
statebak="$(mktemp)"
cp .orchestrator/state.json "$statebak"
printf '%s' '{not json' >.orchestrator/state.json
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when state.json does not parse" "$st" 1
assert_contains "names the file that will not parse" "$out" "not valid JSON"
assert_eq "reports it once rather than once per check" \
  "$(printf '%s\n' "$out" | grep -c '^FAIL')" "1"
assert_eq "claims nothing it could not read" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')" "0"
assert_eq "does not leak jq's parse error into the report" \
  "$(printf '%s\n' "$out" | grep -c 'parse error')" "0"
cp "$statebak" .orchestrator/state.json

"$ORCH" state set phase nonsense
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "rejects an unknown phase" "$st" 1
assert_contains "names the phase it does not know" "$out" "nonsense"
"$ORCH" state set phase spec

"$ORCH" state set branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded branch is gone" "$st" 1
assert_contains "names the missing branch" "$out" "orch/9-gone"

git checkout -q -b orch/9-gone
"$ORCH" state set phase implement
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unpushed branch warns rather than blocking the implement phase" "$st" 0
assert_contains "gives the command that pushes it" "$out" "git push -u origin orch/9-gone"

# branch-create forks off origin/<default>, so an unpushed branch already has an
# upstream - just not its own. Accepting any upstream would call a branch nobody
# else can see pushed.
git update-ref refs/remotes/origin/main HEAD
git branch -q --set-upstream-to=origin/main orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_contains "an upstream pointing at the base branch is still unpushed" \
  "$out" "not on origin yet"

# A handoff with a bare required heading is the failure the next phase would
# experience as running blind, so it has to surface as a FAIL here.
writeln '## Spec issue' '#1' '' '## Seams' '' '## Spec review changelog' 'None.' \
  >"$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when a completed phase's handoff has an empty section" "$st" 1
assert_contains "names the handoff" "$out" "02-spec.md"
assert_contains "reports it as empty, not missing" "$out" "empty section"
complete_spec_handoff "$("$ORCH" handoff path implement)"

"$ORCH" state set pr 7
out="$(GH_STUB_PR_STATE=CLOSED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded PR has been closed" "$st" 1
assert_contains "names the closed PR" "$out" "#7"
out="$(GH_STUB_PR_STATE=MERGED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR is not a failure" "$st" 0

out="$(GH_STUB_MODE=offline "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable GitHub does not fail the flow scope" "$st" 0
assert_contains "skips the PR check with its cause" "$out" "skipped: GitHub is not reachable"

# --flow never runs the tools group, so if it skipped every check it has and
# still exited 0, /orchestrator:next would advance a flow nothing had checked.
out="$(PATH="$(path_without_jq)" "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow without jq fails rather than reporting a clean bill" "$st" 1
assert_contains "names jq as the reason it cannot answer" "$out" "jq not found"

out="$(PATH="$(path_without_jq)" "$ORCH" doctor 2>&1)"; st=$?
assert_status "bare doctor without jq fails on the tools check" "$st" 1
# The count comes from the registry, so a check appended to it is covered by the
# gate without anyone remembering to add a preamble - and this number moving is
# how you find out that happened.
assert_contains "collapses every flow check into one line when jq is gone" \
  "$out" "5 flow checks skipped: jq is not installed"

# --- review begin -----------------------------------------------------------
# The bound lives in bash precisely so a long session cannot re-remember five as
# six, so what matters here is the refusal, not the counting.
echo
echo "review begin"
healthy_repo
"$ORCH" init reviewtest >/dev/null
assert_eq "the first iteration is 1" "$("$ORCH" review begin)" "1"
assert_eq "records the iteration in state" "$("$ORCH" state get iteration)" "1"
for i in 2 3 4 5; do
  assert_eq "iteration $i is claimed in order" "$("$ORCH" review begin)" "$i"
done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "refuses a sixth iteration" "$st" 1
assert_contains "says the bound is what stopped it" "$out" "5 iterations"
assert_eq "and does not spend the refused iteration" "$("$ORCH" state get iteration)" "5"

# --- review path ------------------------------------------------------------
# Per-loop directories are what stop loop 2's iteration 1 overwriting loop 1's.
echo
echo "review path"
assert_contains "files the record under the current loop" \
  "$("$ORCH" review path)" "/review/loop-01/iteration-05.md"
assert_contains "zero-pads an explicit iteration" \
  "$("$ORCH" review path 2)" "/review/loop-01/iteration-02.md"
assert_eq "creates the directory it names" \
  "$([ -d .orchestrator/review/loop-01 ] && echo present || echo gone)" "present"
out="$("$ORCH" review path nope 2>&1)"; st=$?
assert_status "rejects an iteration that is not a number" "$st" 1

# --- handoff verification ---------------------------------------------------
# The review loop runs the command the implement phase recorded rather than
# sniffing the repo for one, so a handoff without it sends review in blind.
echo
echo "handoff verification"
h3="$("$ORCH" handoff path review)"
writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "an implement handoff with no verification command is incomplete" "$st" 1
assert_contains "names the section review would have read" "$out" "Verification"

writeln '## PR' '#3' '' '## Spec issue' '#1' '' '## Base SHA' 'abc1234' '' \
        '## Deviations' 'None.' '' '## Verification' '   ' >"$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "a bare Verification heading is no better than none" "$st" 1
assert_contains "reported as empty, not missing" "$out" "empty section"

complete_implement_handoff "$h3"
out="$("$ORCH" handoff validate "$h3" 2>&1)"; st=$?
assert_status "passes once the command is recorded" "$st" 0

# --- handoff path across loops ----------------------------------------------
# Loop 2 is entered from the handoff loop 1 wrote, not from the implement
# phase's - which is the whole difference between re-entering a loop and
# restarting the phase.
echo
echo "handoff path across loops"
assert_contains "review reads the implement handoff on the first loop" \
  "$("$ORCH" handoff path review)" "03-implement.md"
"$ORCH" state set loop 2
assert_contains "and the outgoing review handoff on a later one" \
  "$("$ORCH" handoff path review)" "04-review.md"
assert_contains "the earlier phases are unaffected by the loop number" \
  "$("$ORCH" handoff path implement)" "02-spec.md"
"$ORCH" state set loop 1

# --- review loop-next -------------------------------------------------------
# The loop boundary is a real context boundary: the outgoing handoff is filed
# under the loop that wrote it, and the counter that bounds iterations resets.
echo
echo "review loop-next"
"$ORCH" state set phase review
out="$("$ORCH" review loop-next 2>&1)"; st=$?
assert_status "refuses to roll a loop that wrote no handoff" "$st" 1
assert_contains "names the handoff it is missing" "$out" "04-review.md"

complete_review_handoff "$("$ORCH" handoff path review-next)"
"$ORCH" review loop-next >/dev/null
assert_eq "the flow moves on to the next loop" "$("$ORCH" state get loop)" "2"
assert_eq "the iteration count resets with it" "$("$ORCH" state get iteration)" "0"
assert_eq "files the outgoing handoff under the loop that wrote it" \
  "$([ -f .orchestrator/review/loop-01/04-review.md ] && echo present || echo gone)" "present"
assert_eq "leaves it in place for the next loop to read" \
  "$([ -f .orchestrator/handoff/04-review.md ] && echo present || echo gone)" "present"
assert_eq "opens a directory for the loop that follows" \
  "$([ -d .orchestrator/review/loop-02 ] && echo present || echo gone)" "present"
assert_eq "the phase stays at review so re-entry lands correctly" \
  "$("$ORCH" state get phase)" "review"
assert_contains "records now land under the new loop" \
  "$("$ORCH" review path 1)" "/review/loop-02/iteration-01.md"

# --- doctor across loops ----------------------------------------------------
# Which handoffs are due stays mechanical, and on a second loop 04 is one of
# them: it is the only thing carrying forward what the first loop settled.
echo
echo "doctor across loops"
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a second loop with every handoff in place is healthy" "$st" 0
assert_contains "counts the outgoing review handoff among them" \
  "$out" "handoff 04-review.md complete"

stashed="$(mktemp)"
mv .orchestrator/handoff/04-review.md "$stashed"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the loop that re-entered has no handoff to read" "$st" 1
assert_contains "names the handoff it cannot find" "$out" "04-review.md is missing"
mv "$stashed" .orchestrator/handoff/04-review.md

"$ORCH" state set loop 1
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_eq "the first loop is not asked for a handoff no loop has written yet" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"
"$ORCH" state set loop 2

# --- review ready -----------------------------------------------------------
# Marking the PR ready and recording the flow as done are one operation, because
# either half alone is a lie: a `done` flow over a draft PR, or a PR promoted out
# of draft by a flow that still thinks it is reviewing.
echo
echo "review ready"
"$ORCH" state set pr 7
out="$(GH_STUB_READY_EXIT=1 "$ORCH" review ready 2>&1)"; st=$?
assert_status "fails when GitHub will not mark the PR ready" "$st" 1
assert_eq "and leaves the phase where it was rather than half-finishing" \
  "$("$ORCH" state get phase)" "review"
"$ORCH" review ready >/dev/null
assert_eq "records the flow as done once the PR is ready" "$("$ORCH" state get phase)" "done"
"$ORCH" state set phase review

# --- review ci --------------------------------------------------------------
# The classification is what decides whether a PR may be marked ready, so each
# of the four answers is asserted for its exit status as well as its word.
echo
echo "review ci"
export ORCH_CI_GRACE=0.3 ORCH_CI_TIMEOUT=1 ORCH_CI_INTERVAL=0.05
out="$(GH_STUB_CHECKS=green "$ORCH" review ci 2>&1)"; st=$?
assert_status "green checks let the loop finish" "$st" 0
assert_eq "and say so in one word" "$(printf '%s\n' "$out" | sed -n 1p)" "green"

out="$(GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "a failing check stops the loop" "$st" 1
assert_eq "classified as failing" "$(printf '%s\n' "$out" | sed -n 1p)" "failing"
assert_contains "names the check that failed" "$out" "build"
assert_eq "and not the ones that passed" "$(printf '%s\n' "$out" | grep -c 'lint')" "0"

# Requiring CI in a repo that has none would make the plugin unusable in its own
# repo, which has none.
out="$(GH_STUB_CHECKS=none "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo with no checks at all is not thereby failing" "$st" 0
assert_eq "classified as none" "$(printf '%s\n' "$out" | sed -n 1p)" "none"

# The grace period is the whole reason `none` is not concluded on the first
# answer: this is the CI-having repo that would otherwise be called CI-less. It
# is spent on the *required* probe, because gh reports "no required checks"
# whether the repo requires nothing or requires something that has not landed
# yet. Widening to every check on the commit before the grace is out is how an
# unrelated green check gets mistaken for a required one that never arrived - so
# the unfiltered answer here is `failing`, and a green result proves it was never
# consulted. The grace is set well clear of a whole-second wall-clock tick, so
# what the test proves is the second answer winning rather than how fast the
# first one came.
reqn="$(mktemp)"; : >"$reqn"
out="$(ORCH_CI_GRACE=5 GH_STUB_REQUIRED_N="$reqn" GH_STUB_REQUIRED='none|green' \
  GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_eq "a required check that has not registered yet is waited for" \
  "$(printf '%s\n' "$out" | sed -n 1p)" "green"
assert_status "and the loop finishes on the answer it waited for" "$st" 0

# Where branch protection names required checks, those are the checks that
# matter - and a failure outside them is not the flow's business.
out="$(GH_STUB_REQUIRED=green GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "required checks decide it where branch protection names them" "$st" 0
assert_eq "so the unfiltered answer is never asked for" \
  "$(printf '%s\n' "$out" | sed -n 1p)" "green"

# ...and where it names none, the answer is every check on the commit, but only
# once the grace has run out.
out="$(ORCH_CI_GRACE=0.2 GH_STUB_REQUIRED=none GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo that requires nothing falls back to every check" "$st" 0
assert_eq "reading the commit's own checks for its answer" \
  "$(printf '%s\n' "$out" | sed -n 1p)" "green"

out="$(GH_STUB_CHECKS=boom "$ORCH" review ci 2>&1)"; st=$?
assert_status "an API that will not answer stops the loop" "$st" 1
assert_eq "classified as unreachable" "$(printf '%s\n' "$out" | sed -n 1p)" "unreachable"
assert_contains "carrying the reason it could not be asked" "$out" "dial tcp"

# doctor's "an unreachable API is a warn" rule was written for a read-only
# diagnostic. Here the outcome is an action, so an answer that never arrived
# cannot be treated as a green one.
out="$(ORCH_CI_TIMEOUT=0.2 GH_STUB_CHECKS=pending "$ORCH" review ci 2>&1)"; st=$?
assert_status "checks still pending at the cap stop the loop" "$st" 1
assert_eq "rather than being read as green" "$(printf '%s\n' "$out" | sed -n 1p)" "unreachable"
assert_contains "and it says the wait ran out" "$out" "still pending"

"$ORCH" state set pr null
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "refuses to classify checks on a PR that does not exist yet" "$st" 1
unset ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL

# --- a flow from before the review loop shipped -----------------------------
# An in-flight flow has no `loop` key, because nothing had written one. Failing
# on its absence would strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the review loop shipped"
healthy_repo
"$ORCH" init legacy >/dev/null
legacy="$(mktemp)"
jq 'del(.loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no loop" "$("$ORCH" state get loop)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land under the first loop" "$("$ORCH" review path)" "/review/loop-01/"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"

"$ORCH" state set phase review
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
complete_implement_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0
assert_eq "and asks it for no handoff a later loop would have written" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"

# --- init seeds the review loop ---------------------------------------------
echo
echo "init seeds the review loop"
healthy_repo
"$ORCH" init seeded >/dev/null
assert_eq "a flow starts on its first loop" "$("$ORCH" state get loop)" "1"
assert_eq "with somewhere to file that loop's records" \
  "$([ -d .orchestrator/review/loop-01 ] && echo present || echo gone)" "present"
# The budget belongs to the flow, so it is seeded once here and never refilled.
# `state get` reads a JSON false back as empty, which is the shape the review
# skill tests against - spent is "true", and anything else is unspent.
assert_eq "and one flake rerun unspent" \
  "$("$ORCH" state get | jq -r '.flake_rerun_used')" "false"
assert_eq "which reads as unspent through state get" \
  "$("$ORCH" state get flake_rerun_used)" ""
"$ORCH" state set flake_rerun_used true
assert_eq "and as spent once it has been" \
  "$("$ORCH" state get flake_rerun_used)" "true"

assert_contains "status names the loop as well as the iteration" \
  "$("$ORCH" status)" "loop 1, iteration 0"
assert_contains "help documents the review verb" "$("$ORCH" help)" "review begin"
assert_contains "and the CI classifier's outcomes" "$("$ORCH" help)" "review ci"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
