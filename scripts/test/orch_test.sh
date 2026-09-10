#!/usr/bin/env bash
#
# Tests for scripts/orch.sh.
#
# orch.sh is where silent wrongness hides: `state validate` returning success on
# a deleted branch, or a handoff passing with an empty required section, are
# bugs you would experience as generic confusion three phases later. Each runs
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

# --- state validate ---------------------------------------------------------
echo
echo "state validate"
out="$("$ORCH" state validate 2>&1)"; st=$?
assert_status "fails when the recorded branch does not exist" "$st" 1
assert_contains "names the missing branch" "$out" "orch/1-x"
git checkout -q -b orch/1-x
out="$("$ORCH" state validate 2>&1)"; st=$?
assert_status "passes once the branch exists" "$st" 0
"$ORCH" state set phase nonsense
out="$("$ORCH" state validate 2>&1)"; st=$?
assert_status "rejects an unknown phase" "$st" 1
"$ORCH" state set phase spec

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

# --- precheck ---------------------------------------------------------------
echo
echo "precheck"
rm -f docs/agents/issue-tracker.md
out="$("$ORCH" precheck 2>&1)"; st=$?
assert_status "fails without a configured issue tracker" "$st" 1
assert_contains "points at the setup skill" "$out" "setup-matt-pocock-skills"

# A non-matching plugin glob must report cleanly, not abort under set -e.
echo "# tracker" >docs/agents/issue-tracker.md
out="$(HOME=/nonexistent "$ORCH" precheck 2>&1)"; st=$?
assert_status "fails cleanly when mattpocock-skills is absent" "$st" 1
assert_contains "gives the install command" "$out" "/plugin install mattpocock-skills"

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
