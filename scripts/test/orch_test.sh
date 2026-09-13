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
# The CI classifier's verdict is its first line and the detail lines below it are
# not the assertion, so most of these read one line out of a captured $out.
assert_first_line() {
  assert_eq "$1" "$(printf '%s\n' "$2" | sed -n 1p)" "$3"
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
#
# `label create` and `issue create` are the filing boundary. GH_STUB_FILED names
# a file the stub appends what it was asked for to - label names and flags, the
# issue's title, labels, and body - and `issue create` answers with a fake issue
# URL numbered GH_STUB_ISSUE_NUMBER, or fails when GH_STUB_ISSUE_EXIT says so.
#
# `issue view`, `issue edit`, and `issue comment` are the spec review's hand on
# the issue. `view` answers GH_STUB_BODY verbatim; `edit` and `comment` record
# the number, flags, and body file contents they were handed to GH_STUB_FILED.
# Each fails on demand: GH_STUB_VIEW_EXIT, GH_STUB_EDIT_EXIT, GH_STUB_COMMENT_EXIT.
#
# `view` also answers `--json state` and `--json labels` independently of the
# body - mirroring the GH_STUB_PR_NUMBER/GH_STUB_PR_STATE split on `pr view`:
# GH_STUB_ISSUE_STATE (default OPEN) and GH_STUB_ISSUE_LABELS (default
# ready-for-agent, one label per line) - so `init --issue` and
# `check_flow_issue` can be tested without disturbing GH_STUB_BODY.
#
# `pr create` and `pr view` are pr-open's boundary. `create` records its flags
# and body-file contents to GH_STUB_FILED like `issue create`, answering with a
# fake PR URL numbered GH_STUB_PR_NUMBER, or failing when GH_STUB_PR_CREATE_EXIT
# says so. `view` answers GH_STUB_PR_NUMBER when asked `--json number` - the
# call pr-open makes to learn the PR it just opened - and falls back to the
# existing `--json state` behaviour (GH_STUB_PR_STATE) for every other query.
stub_gh() {
  local d
  d="$(mktemp -d)"
  cat >"$d/gh" <<'GH'
#!/usr/bin/env bash
if [ -n "${GH_STUB_LOG:-}" ]; then printf '%s\n' "$1" >>"$GH_STUB_LOG"; fi
# Records the flags of an issue write to GH_STUB_FILED, the body file's
# contents inlined, so a test asserts what reached gh rather than the exit.
record_flags() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --title)     printf 'title=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --label)     printf 'label=%s\n' "$2" >>"$GH_STUB_FILED"; shift ;;
      --body-file) { printf 'body:\n'; cat "$2"; } >>"$GH_STUB_FILED"; shift ;;
      *)           printf 'flag=%s\n' "$1" >>"$GH_STUB_FILED" ;;
    esac
    shift
  done
}
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
    if [ "$2" = create ]; then
      shift 2
      if [ -n "${GH_STUB_FILED:-}" ]; then printf 'label create %s\n' "$*" >>"$GH_STUB_FILED"; fi
      exit 0
    fi
    if [ "${GH_STUB_MODE:-ok}" != nolabels ]; then
      printf '%s\n' "${GH_STUB_LABELS-needs-triage
ready-for-agent}"
    fi ;;
  issue)
    case "$2" in
      view)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'issue view %s\n' "$*" >>"$GH_STUB_FILED"; fi
        [ "${GH_STUB_VIEW_EXIT:-0}" = 0 ] || { echo "gh stub: issue view refused" >&2; exit "$GH_STUB_VIEW_EXIT"; }
        for a in "$@"; do
          case "$a" in
            state)  printf '%s\n' "${GH_STUB_ISSUE_STATE:-OPEN}"; exit 0 ;;
            labels) printf '%s\n' "${GH_STUB_ISSUE_LABELS-ready-for-agent}"; exit 0 ;;
          esac
        done
        printf '%s\n' "${GH_STUB_BODY-Body of the issue.}"
        exit 0 ;;
      edit|comment)
        op="$2"; shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then
          printf 'issue %s %s\n' "$op" "$1" >>"$GH_STUB_FILED"
          shift
          record_flags "$@"
        fi
        if [ "$op" = edit ]; then st="${GH_STUB_EDIT_EXIT:-0}"; else st="${GH_STUB_COMMENT_EXIT:-0}"; fi
        [ "$st" = 0 ] || echo "gh stub: issue $op refused" >&2
        exit "$st" ;;
      create) ;;
      *) echo "gh stub: unscripted issue op '$2'" >&2; exit 99 ;;
    esac
    shift 2
    if [ -n "${GH_STUB_FILED:-}" ]; then record_flags "$@"; fi
    [ "${GH_STUB_ISSUE_EXIT:-0}" = 0 ] || { echo "gh stub: issue create refused" >&2; exit "$GH_STUB_ISSUE_EXIT"; }
    echo "https://github.com/acme/widgets/issues/${GH_STUB_ISSUE_NUMBER:-42}" ;;
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
          cancel)  echo '[{"bucket":"cancel","name":"build","state":"CANCELLED"}]' ;;
          pending) echo '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]'; exit 8 ;;
          # gh documents exit 8 for pending checks, but with --json it answers 0
          # and reports the state in the bucket instead. Both reach the same
          # verdict, and only this arm exercises the one real gh takes.
          pending0) echo '[{"bucket":"pending","name":"build","state":"IN_PROGRESS"}]' ;;
          # Exit 0 with something that is not JSON. jq fails, and the answer
          # must not be read as the empty array that means "no checks".
          garbage) echo 'not json at all' ;;
          none)    echo "no checks reported on the 'topic' branch" >&2; exit 1 ;;
          boom)    echo "dial tcp: lookup api.github.com: no such host" >&2; exit 1 ;;
          # Without this arm a typo in GH_STUB_CHECKS prints nothing and exits 0,
          # which ci_probe reads as a repo with no checks - a test that passes
          # while asserting nothing.
          *)       echo "gh stub: no script named '$answer'" >&2; exit 99 ;;
        esac ;;
      create)
        shift 2
        if [ -n "${GH_STUB_FILED:-}" ]; then printf 'pr create\n' >>"$GH_STUB_FILED"; record_flags "$@"; fi
        [ "${GH_STUB_PR_CREATE_EXIT:-0}" = 0 ] || { echo "gh stub: pr create refused" >&2; exit "$GH_STUB_PR_CREATE_EXIT"; }
        echo "https://github.com/acme/widgets/pull/${GH_STUB_PR_NUMBER:-99}" ;;
      view)
        shift 2
        for a in "$@"; do
          if [ "$a" = number ]; then echo "${GH_STUB_PR_NUMBER:-99}"; exit 0; fi
        done
        echo "${GH_STUB_PR_STATE:-OPEN}" ;;
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

# The review skill consumes this inside command substitutions - `dirname "$(...
# handoff path review)"` - so a phase it cannot resolve has to stop the caller
# rather than hand it the bare handoff directory with a zero status.
out="$("$ORCH" handoff path bogus 2>/dev/null)"; st=$?
assert_status "an unknown phase is an error, not a directory" "$st" 1
assert_eq "and prints no path for a caller to use" "$out" ""

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

# --- init --issue -------------------------------------------------------
# Adoption is validated once, immediately, before state.json is written - a bad
# issue number must cost nothing, the same promise branch-create and pr-open
# already make about their own preconditions.
echo
echo "init --issue"
healthy_repo
out="$("$ORCH" init adopted --issue 42)"
assert_eq "adopts an open, labelled issue" "$out" "adopted"
assert_eq "issue is recorded as a number" "$("$ORCH" state get | jq -r '.issue | type')" "number"
assert_eq "issue value matches the adopted number" "$("$ORCH" state get issue)" "42"

healthy_repo
out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "refuses to adopt an issue gh cannot read" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "no flow is left active after a failed adoption" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
out="$(GH_STUB_ISSUE_STATE=CLOSED "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt a closed issue" "$st" 1
assert_contains "says the issue is not open" "$out" "not open"

healthy_repo
out="$(GH_STUB_ISSUE_LABELS=needs-triage "$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt an issue missing the triage label" "$st" 1
assert_contains "names the missing label" "$out" "ready-for-agent"

healthy_repo
out="$("$ORCH" init nope --issue 2>&1)"; st=$?
assert_status "requires a value after --issue" "$st" 1

healthy_repo
out="$("$ORCH" init 2>&1)"; st=$?
assert_status "adoption does not change that a slug is still required" "$st" 1

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

# check_flow_issue runs unconditionally on state.issue, whichever path put it
# there - adopted at init or published by to-spec - and mirrors check_flow_pr's
# open/closed/unreadable shape.
"$ORCH" state set issue 11
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an open issue is healthy" "$st" 0
assert_contains "reports the open issue" "$out" "issue #11 open"

out="$(GH_STUB_ISSUE_STATE=CLOSED "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded issue has been closed" "$st" 1
assert_contains "names the closed issue" "$out" "issue #11 is closed"
assert_contains "gives the command that reopens it" "$out" "gh issue reopen 11"

out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the issue cannot be read from GitHub" "$st" 1
assert_contains "names the unreadable issue" "$out" "issue #11 could not be read from GitHub"
assert_contains "gives the command that re-checks it" "$out" "gh issue view 11"

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
  "$out" "6 flow checks skipped: jq is not installed"

# --- pr-open -----------------------------------------------------------------
# PR #15 merged without closing #14 because the agent's body opened with a verb
# GitHub does not read as a closer. pr-open owns the keyword instead, so no
# agent-chosen wording can leave a spec issue open again.
echo
echo "pr-open"
healthy_repo
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git remote set-url origin "$bare"
git push -q origin HEAD:refs/heads/main
"$ORCH" init propen >/dev/null
git checkout -q -b orch/16-propen
"$ORCH" state set branch orch/16-propen
body="$(mktemp)"
writeln 'Implements the thing.' '' 'Some detail.' >"$body"

out="$("$ORCH" pr-open "Title" "$body" 2>&1)"; st=$?
assert_status "refuses when state has no issue" "$st" 1
assert_contains "with the guard branch-create uses" "$out" \
  "no issue recorded in state - the spec phase must publish one first"

"$ORCH" state set issue 16
filed="$(mktemp)"
out="$(GH_STUB_FILED="$filed" GH_STUB_REPO=main GH_STUB_PR_NUMBER=23 \
  "$ORCH" pr-open "Title" "$body" 2>&1)"; st=$?
assert_status "opens the PR" "$st" 0
assert_eq "prints the PR number gh answered" "$out" "23"
assert_eq "and records it in state" "$("$ORCH" state get pr)" "23"
body_recorded="$(sed -n '/^body:$/,$p' "$filed" | tail -n +2)"
assert_first_line "the recorded body opens with the closing keyword" \
  "$body_recorded" "Closes #16"
assert_contains "and keeps the agent's original body intact after a blank line" \
  "$body_recorded" "Some detail."

out="$(GH_STUB_PR_CREATE_EXIT=1 "$ORCH" pr-open "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not open the PR fails it" "$st" 1
assert_contains "with a clear reason" "$out" "gh could not open the PR"

# --- review begin -----------------------------------------------------------
# The bound lives in bash precisely so a long session cannot re-remember five as
# six, so what matters here is the refusal, not the counting. The budget is the
# human's number, read from state; a flow that never wrote one runs the default.
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
assert_status "refuses a sixth iteration on the default budget" "$st" 1
assert_contains "names the budget that stopped it" "$out" "budget of 5 iterations"
assert_eq "and does not spend the refused iteration" "$("$ORCH" state get iteration)" "5"

"$ORCH" state set iteration 0
"$ORCH" state set budget 2
assert_eq "a budget of 2 admits the first iteration" "$("$ORCH" review begin)" "1"
assert_eq "and the second" "$("$ORCH" review begin)" "2"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the third" "$st" 1
assert_contains "naming the budget it honoured" "$out" "budget of 2 iterations"

"$ORCH" state set iteration 0
"$ORCH" state set budget 8
for i in 1 2 3 4 5 6 7 8; do "$ORCH" review begin >/dev/null; done
assert_eq "a budget of 8 runs past the old bound of five" "$("$ORCH" state get iteration)" "8"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and stops at eight" "$st" 1

# A budget nothing can read is the default, not a refusal: the only flows that
# carry one are the ones started before it existed.
"$ORCH" state set iteration 4
"$ORCH" state set budget null
assert_eq "a null budget reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth" "$st" 1
"$ORCH" state set iteration 4
"$ORCH" state set budget lots
assert_eq "a budget that is not a number reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth too" "$st" 1
"$ORCH" state set budget null

# --- review path ------------------------------------------------------------
# One flow, one trail: the records sit flat under review/, numbered on across
# every loop the flow runs, so nothing is ever moved aside.
echo
echo "review path"
assert_contains "files the record flat under review/" \
  "$("$ORCH" review path)" "/review/iteration-05.md"
assert_contains "zero-pads an explicit iteration" \
  "$("$ORCH" review path 2)" "/review/iteration-02.md"
assert_eq "creates the directory it names" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
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

# --- the multi-loop machinery is gone ---------------------------------------
# Every loop reads the implement handoff, whatever the flow has been through.
# The old entry points are removed rather than deprecated, so each one has to
# fail loudly: a session that found a path back into them would be driving a
# loop nothing else understands.
echo
echo "the multi-loop machinery is gone"
"$ORCH" state set phase review
"$ORCH" state set iteration 7
assert_contains "review reads the implement handoff however far in the flow is" \
  "$("$ORCH" handoff path review)" "03-implement.md"
"$ORCH" state set iteration 5

out="$("$ORCH" handoff path review-next 2>&1)"; st=$?
assert_status "there is no handoff for a next loop to read" "$st" 1
assert_eq "and no path printed for a caller to use" \
  "$(printf '%s\n' "$out" | grep -c '/handoff/')" "0"

writeln '## PR' '#3' >.orchestrator/handoff/04-review.md
out="$("$ORCH" handoff validate .orchestrator/handoff/04-review.md 2>&1)"; st=$?
assert_status "a review handoff is not a handoff validate knows" "$st" 1
assert_contains "and it says so rather than passing it empty" "$out" "unknown handoff file"
rm .orchestrator/handoff/04-review.md

out="$("$ORCH" review loop-next 2>&1)"; st=$?
assert_status "review loop-next is an unknown op" "$st" 1
assert_contains "listed alongside the ops that exist" "$out" "unknown review op"

# --- review file ------------------------------------------------------------
# Filing is mechanism: which labels, what title, which body, and the number
# printed back. The stub records what reached gh, which is the assertion - a
# finding filed with no severity label is a finding triage never finds.
echo
echo "review file"
filed="$(mktemp)"
body="$(mktemp)"
writeln 'The reviewer said this.' '' 'Axis: Standards' >"$body"
out="$(GH_STUB_FILED="$filed" GH_STUB_ISSUE_NUMBER=17 \
  "$ORCH" review file major "Comment drifted from the code" --body-file "$body" 2>&1)"; st=$?
assert_status "files a major" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "17"
assert_contains "creates the severity label" "$(cat "$filed")" "label create review:major"
assert_contains "and the triage label" "$(cat "$filed")" "label create needs-triage"
assert_contains "creating ours over one that exists already" \
  "$(cat "$filed")" "label create review:major --force"
assert_eq "and leaving the repo's own triage label as the repo has it" \
  "$(grep -c 'label create needs-triage --force' "$filed")" "0"
assert_contains "passes the title through unprefixed" \
  "$(cat "$filed")" "title=Comment drifted from the code"
assert_contains "labels the issue with the severity" "$(cat "$filed")" "label=review:major"
assert_contains "and with needs-triage" "$(cat "$filed")" "label=needs-triage"
assert_contains "and sends the body file's contents" "$(cat "$filed")" "The reviewer said this."

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" review file nit "Rename it" --body-file "$body" 2>&1)"; st=$?
assert_status "files a nit" "$st" 0
assert_contains "under the nit label" "$(cat "$filed")" "label=review:nit"

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" review file blocking "Wrong" --body-file "$body" 2>&1)"; st=$?
assert_status "refuses a blocking severity - the loop fixes those" "$st" 1
assert_contains "naming what it accepts" "$out" "major"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "" --body-file "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1
assert_eq "before anything reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "Title" --body-file /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and files nothing" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_FILED="$filed" "$ORCH" review file major "Title" "$body" 2>&1)"; st=$?
assert_status "insists on --body-file rather than guessing a positional" "$st" 1

out="$(GH_STUB_FILED="$filed" GH_STUB_ISSUE_EXIT=1 \
  "$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

out="$(GH_STUB_FILED="$filed" GH_STUB_MODE=labelfail \
  "$ORCH" review file major "Title" --body-file "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the label fails it too" "$st" 1

# The triage label is the repo's vocabulary, read from the doc the spec phase
# labels from: a repo that renamed it must not get a second label the name
# this plugin happens to know.
: >"$filed"
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$(GH_STUB_FILED="$filed" "$ORCH" review file nit "Rename it" --body-file "$body" 2>&1)"; st=$?
assert_status "files under a renamed triage label" "$st" 0
assert_contains "creating the repo's name for it" "$(cat "$filed")" "label create triage me"
assert_contains "and applying it" "$(cat "$filed")" "label=triage me"
assert_eq "rather than the canonical one" "$(grep -c 'needs-triage' "$filed")" "0"
labels_doc docs/agents/triage-labels.md

# --- spec ---------------------------------------------------------------------
# The spec review's one hand on GitHub: fetch the body, replace it, comment on
# it. The number comes from state so a review can never touch the wrong issue,
# and the stub records what reached gh so the test asserts the body sent, not
# only that the command exited zero.
echo
echo "spec"
spec_body="$(mktemp)"
out="$("$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch refuses when state records no issue" "$st" 1
assert_contains "naming the phase that records one" "$out" "spec phase"
out="$("$ORCH" spec update "$spec_body" 2>&1)"; st=$?
assert_status "update refuses too" "$st" 1
assert_contains "for the same reason" "$out" "spec phase"
out="$("$ORCH" spec comment "$spec_body" 2>&1)"; st=$?
assert_status "and comment" "$st" 1
assert_contains "likewise" "$out" "spec phase"

"$ORCH" state set issue 14
filed="$(mktemp)"
# A body with everything a heredoc or a shell quote would mangle: a table, a
# fence, a `#nn` reference. What the lenses read must be what GitHub holds.
tricky="$(mktemp)"
writeln '## Solution' '' \
        '| Lens | Reads |' '|---|---|' '| Fidelity | plan handoff |' '' \
        '```sh' 'orch.sh spec fetch "$file"' '```' '' \
        'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
rm -f "$spec_body"
out="$(GH_STUB_FILED="$filed" GH_STUB_BODY="$(cat "$tricky")" \
  "$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "fetch writes the body to the file" "$st" 0
assert_eq "exactly as gh answered it - table, fence, and #nn survive" \
  "$(cat "$spec_body")" "$(cat "$tricky")"
assert_contains "asking gh for the issue state records" "$(cat "$filed")" "issue view 14"
assert_contains "and for its body alone" "$(cat "$filed")" "--json body"

# The skill fetches into a fresh directory under .orchestrator/, so the first
# fetch of a review is the one that has to create it.
out="$("$ORCH" spec fetch .orchestrator/spec-review/spec.md 2>&1)"; st=$?
assert_status "fetch creates the directory it is told to write into" "$st" 0
assert_eq "and the body lands there" "$(cat .orchestrator/spec-review/spec.md)" "Body of the issue."
rm -rf .orchestrator/spec-review

rm -f "$spec_body"
out="$(GH_STUB_VIEW_EXIT=1 "$ORCH" spec fetch "$spec_body" 2>&1)"; st=$?
assert_status "a gh that will not answer fails the fetch" "$st" 1
assert_contains "with the reason" "$out" "issue view refused"
assert_eq "and leaves no file a lens could mistake for a body" \
  "$([ -e "$spec_body" ] && echo present || echo gone)" "gone"

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "update replaces the body" "$st" 0
assert_contains "of the issue state records" "$(cat "$filed")" "issue edit 14"
assert_contains "with the file's contents as the body" \
  "$(cat "$filed")" 'orch.sh spec fetch "$file"'
assert_eq "and prints nothing" "$out" ""

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" spec update /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_EDIT_EXIT=1 "$ORCH" spec update "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not edit fails the update" "$st" 1
assert_contains "with gh's reason" "$out" "issue edit refused"
assert_contains "and the issue it was for" "$out" "issue #14"

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file" "$st" 0
assert_contains "on the issue state records" "$(cat "$filed")" "issue comment 14"
assert_contains "with the file's contents as the comment" \
  "$(cat "$filed")" "| Fidelity | plan handoff |"

: >"$filed"
out="$(GH_STUB_FILED="$filed" "$ORCH" spec comment /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and nothing reaches gh" "$(grep -c . "$filed")" "0"

out="$(GH_STUB_COMMENT_EXIT=1 "$ORCH" spec comment "$tricky" 2>&1)"; st=$?
assert_status "a gh that will not comment fails it" "$st" 1
assert_contains "with gh's reason" "$out" "issue comment refused"
assert_contains "and the issue it was for" "$out" "issue #14"

out="$("$ORCH" spec publish "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the three it does" "$out" "fetch|update|comment"
out="$("$ORCH" spec fetch 2>&1)"; st=$?
assert_status "and a call with no file" "$st" 1
assert_contains "with the usage" "$out" "usage: orch.sh spec"
assert_contains "help documents the spec verb" "$("$ORCH" help)" "spec fetch"
"$ORCH" state set issue null

# --- doctor at the review phase ---------------------------------------------
# Three handoffs are due from review onwards, and only three: a flow started
# under the old loop machinery carries a `loop` key doctor neither reports nor
# touches, and is asked for no handoff a loop would have written.
echo
echo "doctor at the review phase"
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review-phase flow with its three handoffs is healthy" "$st" 0
assert_contains "counts the implement handoff among them" "$out" "handoff 03-implement.md complete"

"$ORCH" state set loop 2
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray loop key from an older flow still passes" "$st" 0
assert_eq "and earns no mention of a handoff no loop writes any more" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"
assert_eq "nor a line reporting the key" \
  "$(printf '%s\n' "$out" | grep -c 'loop: 2')" "0"
assert_eq "and the key is left as it was" "$("$ORCH" state get loop)" "2"

# The per-loop record directories an older flow left behind are the other
# artefact story 37 names: ignored, not moved, and never a reason to fail.
mkdir -p .orchestrator/review/loop-01
: > .orchestrator/review/loop-01/iteration-01.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray review/loop-NN/ directory from an older flow still passes" "$st" 0
assert_eq "and earns no line of its own" \
  "$(printf '%s\n' "$out" | grep -c 'loop-01')" "0"
assert_eq "and is left where it was" \
  "$([ -f .orchestrator/review/loop-01/iteration-01.md ] && echo present || echo gone)" "present"

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
assert_first_line "and say so in one word" "$out" "green"

out="$(GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "a failing check stops the loop" "$st" 1
assert_first_line "classified as failing" "$out" "failing"
assert_contains "names the check that failed" "$out" "build"
assert_eq "and not the ones that passed" "$(printf '%s\n' "$out" | grep -c 'lint')" "0"

# A cancelled run is not a run that passed, and it is never going to report. It
# classifies as failing, which is also the arm that offers the flake rerun - the
# right remedy for a check that was killed rather than one that judged the change.
out="$(GH_STUB_CHECKS=cancel "$ORCH" review ci 2>&1)"; st=$?
assert_status "a cancelled check stops the loop too" "$st" 1
assert_first_line "classified as failing rather than waited on" "$out" "failing"
assert_contains "naming the check that was cancelled" "$out" "build"

# Requiring CI in a repo that has none would make the plugin unusable in its own
# repo, which has none.
out="$(GH_STUB_CHECKS=none "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo with no checks at all is not thereby failing" "$st" 0
assert_first_line "classified as none" "$out" "none"

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
assert_first_line "a required check that has not registered yet is waited for" "$out" "green"
assert_status "and the loop finishes on the answer it waited for" "$st" 0

# Where branch protection names required checks, those are the checks that
# matter - and a failure outside them is not the flow's business.
out="$(GH_STUB_REQUIRED=green GH_STUB_CHECKS=failing "$ORCH" review ci 2>&1)"; st=$?
assert_status "required checks decide it where branch protection names them" "$st" 0
assert_first_line "so the unfiltered answer is never asked for" "$out" "green"

# ...and where it names none, the answer is every check on the commit, but only
# once the grace has run out.
out="$(ORCH_CI_GRACE=0.2 GH_STUB_REQUIRED=none GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "a repo that requires nothing falls back to every check" "$st" 0
assert_first_line "reading the commit's own checks for its answer" "$out" "green"

out="$(GH_STUB_CHECKS=boom "$ORCH" review ci 2>&1)"; st=$?
assert_status "an API that will not answer stops the loop" "$st" 1
assert_first_line "classified as unreachable" "$out" "unreachable"
assert_contains "carrying the reason it could not be asked" "$out" "dial tcp"

# doctor's "an unreachable API is a warn" rule was written for a read-only
# diagnostic. Here the outcome is an action, so an answer that never arrived
# cannot be treated as a green one.
out="$(ORCH_CI_TIMEOUT=0.2 GH_STUB_CHECKS=pending "$ORCH" review ci 2>&1)"; st=$?
assert_status "checks still pending at the cap stop the loop" "$st" 1
assert_first_line "rather than being read as green" "$out" "unreachable"
assert_contains "and it says the wait ran out" "$out" "still pending"

# The same wait, reached the way real gh reports it. `gh pr checks --json` exits
# 0 whatever the buckets hold, so the exit-8 arm above is the path the stub
# takes and this is the path the live command takes - and until both are
# asserted, the classifier's bucket-reading half ships unexercised.
out="$(ORCH_CI_TIMEOUT=0.2 GH_STUB_CHECKS=pending0 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a pending bucket is a wait even when gh exits 0" "$st" 1
assert_first_line "classified from the bucket rather than the exit status" "$out" "unreachable"
assert_contains "and says the same thing the exit-8 path says" "$out" "still pending"

# The clocks are compared with awk, which compares a number against a
# non-numeric string as strings - so a mistyped knob makes every comparison
# true, and the one command written to be bounded polls GitHub until something
# else kills it. The leash is what makes this assertable: without the fix the
# command never returns on its own.
out="$(ORCH_CI_GRACE=oops timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "a grace that is not a number stops the command, not the clock" "$st" 1
assert_contains "naming the knob it could not read" "$out" "ORCH_CI_GRACE"

# A zero interval passes for a number and still defeats the bound: `sleep 0`
# returns at once and never advances the clock, so the loop polls as fast as
# GitHub answers for the whole timeout.
out="$(ORCH_CI_INTERVAL=0 timeout 5 "$ORCH" review ci 2>&1)"; st=$?
assert_status "an interval of zero is refused rather than busy-polled" "$st" 1
assert_contains "saying the interval has to be above zero" "$out" "greater than zero"

# The one direction this classifier must never fail in: an answer nobody could
# read is not an answer that there is nothing to read.
out="$(GH_STUB_CHECKS=garbage "$ORCH" review ci 2>&1)"; st=$?
assert_status "output jq cannot parse stops the loop" "$st" 1
assert_first_line "rather than passing as a repo with no checks" "$out" "unreachable"
assert_contains "saying what it could not read" "$out" "could not read"

"$ORCH" state set pr null
out="$("$ORCH" review ci 2>&1)"; st=$?
assert_status "refuses to classify checks on a PR that does not exist yet" "$st" 1
# require_pr dies inside a command substitution, so what stops the command is
# `set -e` on the assignment rather than the exit itself. Asserting the message
# is what would catch the guard degrading into an empty PR number.
assert_contains "saying which phase was supposed to open it" "$out" "the implement phase opens it"
unset ORCH_CI_GRACE ORCH_CI_TIMEOUT ORCH_CI_INTERVAL

# --- a flow from before the budget shipped ----------------------------------
# An in-flight flow carries whatever state the version that started it wrote:
# no `budget`, no `loop`, no `flake_rerun_used`. Failing on any absence would
# strand exactly the flows this change was meant to finish.
echo
echo "a flow started before the budget shipped"
healthy_repo
"$ORCH" init legacy >/dev/null
legacy="$(mktemp)"
jq 'del(.budget, .loop, .flake_rerun_used)' .orchestrator/state.json >"$legacy"
mv "$legacy" .orchestrator/state.json
assert_eq "the state it left behind names no budget" "$("$ORCH" state get budget)" ""
assert_eq "review begin still claims an iteration" "$("$ORCH" review begin)" "1"
assert_contains "records land flat under review/" "$("$ORCH" review path)" "/review/iteration-01.md"
assert_contains "and review reads the implement handoff as it always did" \
  "$("$ORCH" handoff path review)" "03-implement.md"
for i in 2 3 4 5; do "$ORCH" review begin >/dev/null; done
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and it runs the default budget" "$st" 1
assert_contains "of five" "$out" "budget of 5 iterations"

"$ORCH" state set phase review
complete_plan_handoff "$("$ORCH" handoff path spec)"
complete_spec_handoff "$("$ORCH" handoff path implement)"
complete_implement_handoff "$("$ORCH" handoff path review)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor does not strand it either" "$st" 0
assert_contains "status reads its budget as the default" "$("$ORCH" status)" "iteration 5 of 5"

# ci and ready need a PR, which a flow this old still records the same way.
"$ORCH" state set pr 3 >/dev/null
out="$(ORCH_CI_GRACE=0.2 ORCH_CI_INTERVAL=0.05 GH_STUB_CHECKS=green \
  "$ORCH" review ci 2>&1)"; st=$?
assert_status "review ci reads its PR from a state with no budget key" "$st" 0
assert_first_line "and classifies it" "$out" "green"
assert_eq "review ready marks the PR and finishes the flow" \
  "$("$ORCH" review ready)" "3"
assert_eq "recording done as it goes" "$("$ORCH" state get phase)" "done"

# --- init seeds the review loop ---------------------------------------------
echo
echo "init seeds the review loop"
healthy_repo
"$ORCH" init seeded >/dev/null
assert_eq "a flow starts with no loop counter" \
  "$("$ORCH" state get | jq -r 'has("loop")')" "false"
assert_eq "and no budget until a human names one" "$("$ORCH" state get budget)" ""
assert_eq "with somewhere to file its records" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
assert_eq "and no per-loop directory under it" \
  "$([ -e .orchestrator/review/loop-01 ] && echo present || echo gone)" "gone"
# The flake rerun belongs to the flow, so it is seeded once here and never
# refilled. `state get` reads a JSON false back as empty, which is the shape the
# review skill tests against - spent is "true", and anything else is unspent.
assert_eq "and one flake rerun unspent" \
  "$("$ORCH" state get | jq -r '.flake_rerun_used')" "false"
assert_eq "which reads as unspent through state get" \
  "$("$ORCH" state get flake_rerun_used)" ""
"$ORCH" state set flake_rerun_used true
assert_eq "and as spent once it has been" \
  "$("$ORCH" state get flake_rerun_used)" "true"

assert_contains "status names the iteration against the default budget" \
  "$("$ORCH" status)" "iteration 0 of 5"
"$ORCH" state set budget 3
"$ORCH" state set iteration 2
assert_contains "and against the budget once one is set" \
  "$("$ORCH" status)" "iteration 2 of 3"
assert_contains "help documents the review verb" "$("$ORCH" help)" "review begin"
assert_contains "and the CI classifier's outcomes" "$("$ORCH" help)" "review ci"
assert_contains "and filing" "$("$ORCH" help)" "review file"
assert_eq "and no longer the loop machinery" "$("$ORCH" help | grep -c 'loop-next')" "0"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
