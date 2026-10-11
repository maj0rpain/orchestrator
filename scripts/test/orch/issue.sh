# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# fake_issue_title <n> <title>: seeds issue #n's title.
fake_issue_title() { printf '%s\n' "$2" >"$ORCH_GH_FAKE_STORE/issues/$1/title"; }

# close_refused <what> <want> <args...>: runs `issue close <args...>` and
# asserts it exits 1 with an orch: message containing <want>, leaving the
# fake's issue #83 open.
close_refused() {
  local what="$1" want="$2" out st
  shift 2
  out="$("$ORCH" issue close "$@" 2>&1)"; st=$?
  assert_status "refuses $what" "$st" 1
  assert_contains "with an orch: message ($what)" "$out" "orch: "
  assert_contains "saying why ($what)" "$out" "$want"
  assert_eq "closing nothing ($what)" "$(fake_state_of 83)" "OPEN"
}

# triage_check <n>: run issue triage --check on issue <n>.
triage_check() { "$ORCH" issue triage "$1" --check; }

# check_says <name> <n> <expected>: --check on issue <n> prints <expected>,
# exits 0, and writes nothing to the fake.
check_says() {
  local before out st
  before="$(fake_snapshot)"
  out="$(triage_check "$2" 2>&1)"; st=$?
  assert_status "$1, exit 0" "$st" 0
  assert_eq "printing '$3'" "$out" "$3"
  assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"
}
# check_dies <name> <n> <reason>: --check on issue <n> exits 1 with <reason>
# on stderr, nothing on stdout, and writes nothing to the fake.
check_dies() {
  local before out err st errf
  errf="$(mktemp)"
  before="$(fake_snapshot)"
  out="$(triage_check "$2" 2>"$errf")"; st=$?
  err="$(cat "$errf")"; rm -f "$errf"
  assert_status "$1, exit 1" "$st" 1
  assert_contains "giving its reason on stderr" "$err" "$3"
  assert_eq "printing nothing on stdout" "$out" ""
  assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"
}

# --- issue publish ------------------------------------------------------------
# The publishing boundary a quick implementation calls instead of hardcoding
# `gh issue create` in skill prose - stateless like branch off, since a quick
# implementation has no flow to record into.
#
# Creation goes through the store-backed fake (fake_github), and what it filed
# is read back from the store - the fixture gh's log stays empty, proving it never
# spawns a real gh subprocess. The real operation is pinned in "gh adapter
# contract".
echo
echo "issue publish"
healthy_repo
fake_github
body="$(mktemp)"
writeln 'The shared understanding, written up.' >"$body"
: >"$GH_FIXTURE/env.log"
fake_next_issue 7
out="$("$ORCH" issue publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "7"
assert_eq "filing an open issue" "$(fake_state_of 7)" "OPEN"
assert_eq "under the title given" "$(fake_title_of 7)" "Widgets need a handle"
assert_eq "with the body file's contents" "$(fake_body_of 7)" "The shared understanding, written up."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the create call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_github
out="$("$ORCH" issue publish "" "$body" 2>&1)"; st=$?
assert_status "refuses an empty title" "$st" 1

out="$("$ORCH" issue publish "Title" /nonexistent/body.md 2>&1)"; st=$?
assert_status "refuses a body file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

out="$("$ORCH" issue publish "Title" 2>&1)"; st=$?
assert_status "refuses with no body file" "$st" 1
assert_eq "filing nothing for any of them" "$(fake_issues)" ""

fake_fail adapter_issue_create "$GH_502"
out="$("$ORCH" issue publish "Title" "$body" 2>&1)"; st=$?
assert_status "a gh that will not create the issue fails the command" "$st" 1
assert_contains "passing gh's first line through, in the death (#846)" "$out" \
  "orch: gh could not create the issue: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"
fake_unfail
fake_fail adapter_issue_create ''
out="$("$ORCH" issue publish "Title" "$body" 2>&1)"; st=$?
assert_status "a create that fails silently fails it too" "$st" 1
assert_contains "saying gh gave no reason" "$out" "orch: gh could not create the issue: gh gave no reason"
fake_unfail
restore_suite_env

# --- issue publish verify-then-die -------------------------------------------
# The spec a flow or a quick implementation works from gets the guarantee
# ticket publish gives its tickets: created under the ready-for-agent role's
# label, then read back - title and labels - with one retry on a mismatch and
# a death naming the issue on the second. fake_lag makes the readback stale
# for N calls, answering nothing, or the stale title and labels it is given.
echo
echo "issue publish verify-then-die"
healthy_repo
fake_github
body="$(mktemp)"
writeln 'The shared understanding, written up.' >"$body"
publish() { "$ORCH" issue publish "$@"; }

fake_next_issue 8
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes with the canonical labels" "$st" 0
assert_eq "printing the issue number and nothing else" "$out" "8"
assert_eq "applies ready-for-agent" "$(fake_labels_of 8)" "ready-for-agent "

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes under a renamed ready-for-agent label" "$st" 0
assert_eq "applying the repo's name for it, rather than the canonical one" "$(fake_labels_of "$out")" "agent go "

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `-agent`             | AFK-ready   |' >docs/agents/triage-labels.md
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "verifies a ready-for-agent label beginning with '-'" "$st" 0
assert_eq "applying it" "$(fake_labels_of "$out")" "-agent "

rm docs/agents/triage-labels.md
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "publishes with no labels doc at all" "$st" 0
assert_eq "applying the canonical ready-for-agent name" "$(fake_labels_of "$out")" "ready-for-agent "
labels_doc docs/agents/triage-labels.md

fake_next_issue 9
fake_lag adapter_issue_title_labels 1
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback that is stale once, then right, succeeds" "$st" 0
assert_eq "printing the issue number" "$out" "9"

fake_next_issue 10
fake_lag adapter_issue_title_labels 2
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback stale twice dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #10"
assert_contains "saying it did not verify" "$out" "did not verify"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"

fake_next_issue 11
fake_lag adapter_issue_title_labels 2 "$(writeln "Something else" ready-for-agent)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a title that reads back wrong fails verification" "$st" 1
assert_contains "naming the issue" "$out" "issue #11"

fake_next_issue 12
fake_lag adapter_issue_title_labels 2 "$(writeln "Widgets need a handle" needs-triage)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a label set missing ready-for-agent fails verification" "$st" 1
assert_contains "naming the issue" "$out" "issue #12"

fake_next_issue 13
fake_lag adapter_issue_title_labels 2 "$(writeln "Widgets need a handle" bug ready-for-agent)"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "extra labels beside ready-for-agent still verify" "$st" 0

fake_next_issue 14
fake_fail adapter_issue_title_labels "$(writeln "HTTP 502: Bad Gateway" "retry later")"
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback that fails twice dies" "$st" 1
assert_contains "saying gh could not read the issue, with gh's first line" "$out" \
  "orch: gh could not read issue #14: HTTP 502: Bad Gateway"
assert_not_contains "and only its first line" "$out" "retry later"
assert_not_contains "never calling a failed read a mismatch" "$out" "did not verify"
assert_eq "with no number printed for a record to cite" \
  "$(printf '%s\n' "$out" | grep -cx '[0-9][0-9]*')" "0"
fake_unfail

fake_next_issue 15
fake_fail_times adapter_issue_title_labels 1
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback that fails once, then answers, succeeds" "$st" 0
assert_eq "printing the issue number" "$out" "15"
fake_unfail

fake_next_issue 16
fake_fail adapter_issue_title_labels ''
out="$(publish "Widgets need a handle" "$body" 2>&1)"; st=$?
assert_status "a readback that fails silently twice dies" "$st" 1
assert_contains "saying gh gave no reason" "$out" \
  "orch: gh could not read issue #16: gh gave no reason"
fake_unfail
restore_suite_env

# --- issue triage -------------------------------------------------------------
# The planning close's one write to GitHub (#571): an open issue moved to the
# repo's ready-for-agent label, so init --issue can adopt it. Run against the
# store-backed fake; what it did is read back from the store.
echo
echo "issue triage"
healthy_repo
fake_github
triage() { "$ORCH" issue triage "$@"; }
comment_count() { ls "$ORCH_GH_FAKE_STORE/issues/$1/comments" 2>/dev/null | wc -l | tr -d ' '; }

fake_issue 40 open needs-triage bug
out="$(triage 40 2>&1)"; st=$?
assert_status "triages a needs-triage issue" "$st" 0
assert_eq "leaving ready-for-agent and no other triage label" "$(fake_labels_of 40)" "bug ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 40)" "1"
assert_contains "naming ready-for-agent in it" "$(fake_comments_of 40)" "ready-for-agent"

fake_issue 41 open needs-info
out="$(triage 41 2>&1)"; st=$?
assert_status "triages a needs-info issue" "$st" 0
assert_eq "leaving ready-for-agent alone" "$(fake_labels_of 41)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 41)" "1"

fake_issue 42 open
out="$(triage 42 2>&1)"; st=$?
assert_status "triages an unlabelled issue" "$st" 0
assert_eq "leaving ready-for-agent alone" "$(fake_labels_of 42)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 42)" "1"

fake_issue 43 open ready-for-agent bug
before="$(fake_snapshot)"
out="$(triage 43 2>&1)"; st=$?
assert_status "an issue already ready-for-agent is a no-op" "$st" 0
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"

for held in wontfix ready-for-human; do
  fake_issue 44 open "$held"
  before="$(fake_snapshot)"
  out="$(triage 44 2>&1)"; st=$?
  assert_status "$held without --override asks for a decision, exit 2" "$st" 2
  assert_contains "printing the label it found" "$out" "$held"
  assert_eq "changing nothing" "$(fake_snapshot)" "$before"
  out="$(triage 44 --override 2>&1)"; st=$?
  assert_status "$held with --override is triaged" "$st" 0
  assert_eq "replaced by ready-for-agent" "$(fake_labels_of 44)" "ready-for-agent "
  assert_eq "with exactly one comment" "$(comment_count 44)" "1"
done

# Both held: wontfix wins over ready-for-human, whatever order they come in.
fake_issue 57 open ready-for-human wontfix
before="$(fake_snapshot)"
out="$(triage 57 2>&1)"; st=$?
assert_status "an issue holding both wontfix and ready-for-human asks for a decision, exit 2" "$st" 2
assert_eq "printing wontfix" "$out" "wontfix"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

fake_issue 45 open needs-triage review:major
before="$(fake_snapshot)"
out="$(triage 45 2>&1)"; st=$?
assert_status "a filed finding is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #45"
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
out="$(ORCHESTRATOR_HOST=junie "$ORCH" issue triage 45 2>&1)"
assert_contains "naming the finding-triage skill off Claude Code" "$out" "orch-finding-triage skill"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

fake_issue 52 open needs-triage review:minor
before="$(fake_snapshot)"
out="$(triage 52 2>&1)"; st=$?
assert_status "a finding under any review:<severity> label is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #52"
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

# A finding carrying one of finding triage's own labels has been checked
# against the default branch (ADR-0031), so it takes the ordinary path (#586).
fake_issue 60 open review:major bug ready-for-human
before="$(fake_snapshot)"
out="$(triage 60 2>&1)"; st=$?
assert_status "a ready-for-human finding without --override asks for a decision, exit 2" "$st" 2
assert_eq "printing the label it found" "$out" "ready-for-human"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
out="$(triage 60 --override 2>&1)"; st=$?
assert_status "a ready-for-human finding with --override is triaged" "$st" 0
assert_eq "keeping its severity and category beside ready-for-agent" \
  "$(fake_labels_of 60)" "bug ready-for-agent review:major "
assert_eq "with exactly one comment" "$(comment_count 60)" "1"

fake_issue 61 open review:major wontfix
before="$(fake_snapshot)"
out="$(triage 61 2>&1)"; st=$?
assert_status "a wontfix finding without --override asks for a decision, exit 2" "$st" 2
assert_eq "printing the label it found" "$out" "wontfix"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"

fake_issue 62 open review:nit ready-for-agent
before="$(fake_snapshot)"
out="$(triage 62 2>&1)"; st=$?
assert_status "a finding already ready-for-agent is a no-op" "$st" 0
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"

# Refused: labels that do not show finding triage ran on it, --override or not.
for case in "63|review:major" "64|review:major needs-info" \
            "65|review:major needs-triage|--override" "66|review:major|--override"; do
  n="${case%%|*}"; rest="${case#*|}"; flag="${rest#*|}"; [ "$flag" != "$rest" ] || flag=""
  # shellcheck disable=SC2086 # the labels split into separate arguments
  fake_issue "$n" open ${rest%%|*}
  before="$(fake_snapshot)"
  # shellcheck disable=SC2086 # an empty flag is no argument at all
  out="$(triage "$n" $flag 2>&1)"; st=$?
  assert_status "a finding labelled '${rest%%|*}' ${flag:-without --override} is refused" "$st" 1
  assert_contains "naming the issue" "$out" "issue #$n"
  assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
  assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
  assert_eq "changing nothing" "$(fake_snapshot)" "$before"
done

fake_issue 46 closed needs-triage
before="$(fake_snapshot)"
out="$(triage 46 2>&1)"; st=$?
assert_status "a closed issue is refused" "$st" 1
assert_contains "naming the issue" "$out" "issue #46"
assert_eq "changing nothing and posting no comment" "$(fake_snapshot)" "$before"

fake_issue 47 open needs-triage
fake_fail adapter_issue_state_labels "$GH_502"
before="$(fake_snapshot)"
out="$(triage 47 2>&1)"; st=$?
assert_status "a failed read dies" "$st" 1
assert_contains "naming the issue, with gh's line" "$out" \
  "orch: gh could not read issue #47: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_unfail

fake_issue 48 open needs-triage
fake_fail adapter_issue_relabel "$GH_502"
out="$(triage 48 2>&1)"; st=$?
assert_status "a failed relabel dies" "$st" 1
assert_contains "naming the issue, with gh's first line (#846)" "$out" \
  "orch: gh could not relabel issue #48: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "posting no comment" "$(comment_count 48)" "0"
fake_unfail

# The readback lags after the first read, which answered current. A second
# relabel would fail (fake_fail_after), so a re-read that relabelled again
# could not pass.
fake_issue 49 open needs-triage
fake_lag_after adapter_issue_state_labels 1 1 "$(writeln OPEN needs-triage)"
fake_fail_after adapter_issue_relabel 1
out="$(triage 49 2>&1)"; st=$?
assert_status "a readback stale once, then right, succeeds" "$st" 0
assert_eq "re-reading without relabelling again" "$(fake_labels_of 49)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 49)" "1"
fake_unfail

fake_issue 50 open needs-triage
fake_lag_after adapter_issue_state_labels 1 2 "$(writeln OPEN needs-triage ready-for-agent)"
out="$(triage 50 2>&1)"; st=$?
assert_status "a readback stale twice dies" "$st" 1
assert_contains "naming the issue" "$out" "issue #50"
assert_eq "posting no comment" "$(comment_count 50)" "0"

# The first read answers; both verify re-reads fail. The relabel has
# already happened, so it stands, and no comment claims it verified.
fake_issue 56 open needs-triage
fake_fail_after adapter_issue_state_labels 1 "$GH_502"
out="$(triage 56 2>&1)"; st=$?
assert_status "a verify re-read that fails twice dies" "$st" 1
assert_contains "saying gh could not read the issue, with gh's line" "$out" \
  "orch: gh could not read issue #56: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_not_contains "never calling a failed read a mismatch" "$out" "did not verify"
assert_eq "the relabel standing" "$(fake_labels_of 56)" "ready-for-agent "
assert_eq "posting no comment" "$(comment_count 56)" "0"
fake_unfail

# A verify re-read that fails once, then reads back right, succeeds. The first
# read answers; the next one fails silently, once.
fake_issue 57 open needs-triage
fake_fail_after adapter_issue_state_labels 1
fake_fail_times adapter_issue_state_labels 1
out="$(triage 57 2>&1)"; st=$?
assert_status "a verify re-read that fails once, then answers, succeeds" "$st" 0
assert_eq "the issue carrying ready-for-agent" "$(fake_labels_of 57)" "ready-for-agent "
assert_eq "with exactly one comment" "$(comment_count 57)" "1"
fake_unfail

# Both verify re-reads fail silently: the death says gh gave no reason.
fake_issue 58 open needs-triage
fake_fail_after adapter_issue_state_labels 1
fake_fail adapter_issue_state_labels ''
out="$(triage 58 2>&1)"; st=$?
assert_status "two silent verify re-read failures die" "$st" 1
assert_contains "saying gh gave no reason" "$out" \
  "orch: gh could not read issue #58: gh gave no reason"
assert_eq "the issue keeping ready-for-agent" "$(fake_labels_of 58)" "ready-for-agent "
assert_eq "posting no comment" "$(comment_count 58)" "0"
fake_unfail

fake_issue 51 open needs-triage
assert_gh_dies "a failed comment after a verified relabel still exits 0" adapter_issue_comment "$GH_502" 0 \
  "orch: warning: issue #51 is labelled ready-for-agent, but gh could not post the triage comment on it: HTTP 502: Bad Gateway" \
  triage 51
assert_eq "the relabel standing" "$(fake_labels_of 51)" "ready-for-agent "
assert_eq "posting no comment" "$(comment_count 51)" "0"

fake_issue 59 open needs-triage
assert_gh_dies "a comment that fails silently still exits 0" adapter_issue_comment '' 0 \
  "orch: warning: issue #59 is labelled ready-for-agent, but gh could not post the triage comment on it: gh gave no reason" \
  triage 59
assert_eq "the label applied" "$(fake_labels_of 59)" "ready-for-agent "
assert_eq "and no comment posted" "$(comment_count 59)" "0"

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `needs-info`               | `more info`          | Waiting     |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' \
        '| `ready-for-human`          | `human go`           | Needs human |' \
        '| `wontfix`                  | `nope`               | Not doing   |' >docs/agents/triage-labels.md
fake_issue 53 open "triage me" needs-triage
out="$(triage 53 2>&1)"; st=$?
assert_status "triages under renamed labels" "$st" 0
assert_eq "removing the repo's name for needs-triage, adding its ready-for-agent" \
  "$(fake_labels_of 53)" "agent go needs-triage "
assert_contains "naming the local label in the comment" "$(fake_comments_of 53)" "agent go"
fake_issue 54 open nope
out="$(triage 54 2>&1)"; st=$?
assert_status "a renamed wontfix asks for a decision" "$st" 2
assert_eq "printing the repo's name for it" "$out" "nope"
fake_issue 55 open "agent go"
before="$(fake_snapshot)"
out="$(triage 55 2>&1)"; st=$?
assert_status "a renamed ready-for-agent is a no-op" "$st" 0
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_issue 67 open "triage me" review:major
before="$(fake_snapshot)"
out="$(triage 67 --override 2>&1)"; st=$?
assert_status "a finding under the renamed needs-triage is refused" "$st" 1
assert_contains "saying it is not yet triaged" "$out" "not yet triaged"
assert_contains "naming the issue" "$out" "issue #67"
assert_contains "pointing at finding triage" "$out" "/orchestrator:finding-triage"
assert_eq "changing nothing" "$(fake_snapshot)" "$before"
fake_issue 68 open "human go" review:major
out="$(triage 68 2>&1)"; st=$?
assert_status "a finding under the renamed ready-for-human asks for a decision" "$st" 2
assert_eq "printing the repo's name for it" "$out" "human go"
labels_doc docs/agents/triage-labels.md

out="$(triage abc 2>&1)"; st=$?
assert_status "a non-numeric issue is a usage error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue triage"
out="$(triage 40 --force 2>&1)"; st=$?
assert_status "an unknown flag is a usage error" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue triage"
out="$(triage 2>&1)"; st=$?
assert_status "no issue at all is a usage error" "$st" 1
out="$("$ORCH" issue bogus 2>&1)"
assert_contains "the unknown-op message lists triage" "$out" "|triage"
assert_contains "help documents issue triage" "$("$ORCH" help)" "issue triage <n> [--override]"
assert_contains "help documents issue triage --check" "$("$ORCH" help)" "issue triage <n> --check"
restore_suite_env

# --- issue triage --check -----------------------------------------------------
# The read-only mode the planning hook's interviewed-issue step runs before it
# asks anything (#989): the write path's read and role walk, and no write.
echo
echo "issue triage --check"
healthy_repo
fake_github
fake_issue 70 open ready-for-agent bug
check_says "an issue carrying ready-for-agent is ready" 70 ready
fake_issue 71 open needs-triage bug
check_says "a needs-triage issue is movable" 71 movable
fake_issue 72 open
check_says "an unlabelled issue is movable" 72 movable
fake_issue 73 open wontfix
check_says "a wontfix issue prints wontfix" 73 wontfix
fake_issue 74 open ready-for-human
check_says "a ready-for-human issue prints ready-for-human" 74 ready-for-human
fake_issue 75 open ready-for-human wontfix
check_says "an issue holding both wontfix and ready-for-human prints wontfix" 75 wontfix
fake_issue 76 open ready-for-agent wontfix
check_says "ready-for-agent beside a held label is ready" 76 ready
fake_issue 77 open review:major bug ready-for-human
check_says "a finding finding triage has labelled takes the ordinary walk" 77 ready-for-human

fake_issue 78 closed needs-triage
check_dies "a closed issue dies" 78 "orch: issue #78 is not open"
fake_issue 79 open needs-triage review:major
check_dies "a filed finding not yet triaged dies" 79 \
  "orch: issue #79 is a filed finding (review:major) not yet triaged"
fake_issue 80 open needs-triage
fake_fail adapter_issue_state_labels "$GH_502"
check_dies "a failed read dies" 80 "orch: gh could not read issue #80: HTTP 502: Bad Gateway"
fake_unfail

fake_issue 81 open needs-triage
before="$(fake_snapshot)"
out="$("$ORCH" issue triage 81 --check --override 2>&1)"; st=$?
assert_status "--check with --override is a usage error, exit 1" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue triage"
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"
out="$("$ORCH" issue triage 81 --override --check 2>&1)"; st=$?
assert_status "in either order" "$st" 1
assert_eq "relabelling nothing and posting no comment" "$(fake_snapshot)" "$before"

# One shared walk (story 9): on each label set, --check and the plain write agree.
for labelled in "82|ready-for-agent" "83|wontfix" "84|ready-for-human" \
            "85|ready-for-human wontfix" "86|ready-for-agent ready-for-human" \
            "87|needs-triage" "88|needs-info bug"; do
  n="${labelled%%|*}"
  # shellcheck disable=SC2086 # the labels split into separate arguments
  fake_issue "$n" open ${labelled#*|}
  said="$(triage_check "$n" 2>/dev/null)"
  before="$(fake_snapshot)"
  out="$("$ORCH" issue triage "$n" 2>/dev/null)"; st=$?
  case "$said" in
    ready)
      assert_status "parity '${labelled#*|}': ready, and the write exits 0" "$st" 0
      assert_eq "relabelling nothing" "$(fake_snapshot)" "$before" ;;
    movable)
      assert_status "parity '${labelled#*|}': movable, and the write exits 0" "$st" 0
      assert_contains "relabelling it to ready-for-agent" "$(fake_labels_of "$n")" "ready-for-agent" ;;
    *)
      assert_status "parity '${labelled#*|}': '$said', and the write exits 2" "$st" 2
      assert_eq "printing the same label" "$out" "$said"
      assert_eq "relabelling nothing" "$(fake_snapshot)" "$before" ;;
  esac
done

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `triage me`          | Evaluate it |' \
        '| `needs-info`               | `more info`          | Waiting     |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' \
        '| `ready-for-human`          | `human go`           | Needs human |' \
        '| `wontfix`                  | `nope`               | Not doing   |' >docs/agents/triage-labels.md
fake_issue 89 open "agent go"
check_says "a renamed ready-for-agent is ready" 89 ready
fake_issue 90 open "human go" nope
check_says "renamed held labels print the repo's wontfix" 90 nope
fake_issue 91 open "human go"
check_says "a renamed ready-for-human prints its name" 91 "human go"
fake_issue 92 open "triage me" ready-for-agent
check_says "the upstream name is no label of the repo's: movable" 92 movable
fake_issue 93 open "triage me" review:major
check_dies "a finding under the renamed needs-triage dies" 93 "not yet triaged"
labels_doc docs/agents/triage-labels.md
restore_suite_env

# --- issue ready --------------------------------------------------------------
# The spec skill's rewrite-mode check (#705): does an issue carry the repo's
# ready-for-agent label? Exit 0 yes, 1 no, 2 when GitHub could not be read.
echo
echo "issue ready"
healthy_repo
fake_github
ready() { "$ORCH" issue ready "$@"; }

fake_issue 70 open ready-for-agent bug
ready 70 >/dev/null 2>&1; st=$?
assert_status "an issue carrying ready-for-agent is ready" "$st" 0

fake_issue 71 open needs-triage bug
out="$(ready 71 2>&1)"; st=$?
assert_status "an issue carrying neither label is not ready" "$st" 1
assert_eq "and says nothing" "$out" ""

fake_issue 72 open
ready 72 >/dev/null 2>&1; st=$?
assert_status "an unlabelled issue is not ready" "$st" 1

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
fake_issue 73 open "agent go"
ready 73 >/dev/null 2>&1; st=$?
assert_status "an issue carrying the repo's mapped name is ready" "$st" 0
fake_issue 74 open needs-triage
ready 74 >/dev/null 2>&1; st=$?
assert_status "under a mapping, an issue carrying neither is not ready" "$st" 1
labels_doc docs/agents/triage-labels.md

fake_fail adapter_issue_state_labels "$GH_502"
out="$(ready 70 2>&1)"; st=$?
assert_status "a gh failure exits 2" "$st" 2
assert_contains "with an orch: message naming the issue, with gh's line" "$out" \
  "orch: gh could not read issue #70: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
fake_unfail

out="$(ready abc 2>&1)"; st=$?
assert_status "a non-numeric issue is a usage error" "$st" 2
assert_contains "with a usage line" "$out" "usage: orch.sh issue ready <n>"
out="$(ready 2>&1)"; st=$?
assert_status "no issue at all is a usage error" "$st" 2
assert_contains "with a usage line" "$out" "usage: orch.sh issue ready <n>"
out="$(ready 70 71 2>&1)"; st=$?
assert_status "a second argument is a usage error" "$st" 2
out="$("$ORCH" issue bogus 2>&1)"
assert_contains "the unknown-op message lists ready" "$out" "|ready"
assert_contains "help documents issue ready" "$("$ORCH" help)" "issue ready <n>"
assert_contains "the CLI conventions' noun table lists issue ready" \
  "$(grep '^| `issue`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`ready`'
restore_suite_env

# --- issue close --------------------------------------------------------------
# The planning close's done-close (#985): one gh call closes an issue as
# completed or as a duplicate, the file's contents as its closing comment -
# bad input refused before any gh call, nothing read back, labels untouched.
echo
echo "issue close"
healthy_repo
fake_github
close_comment="$(mktemp)"
printf 'Done by #854: all three findings fixed.' >"$close_comment"

fake_issue 80 open ready-for-agent bug
out="$("$ORCH" issue close 80 --completed --comment-file "$close_comment" 2>&1)"; st=$?
assert_status "--completed closes the issue" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "as completed" "$(fake_state_of 80) $(fake_reason_of 80)" "CLOSED completed"
assert_eq "with the file's contents as its only comment, as given" \
  "$(fake_comments_of 80)" "Done by #854: all three findings fixed."
assert_eq "leaving its labels unchanged" "$(fake_labels_of 80)" "bug ready-for-agent "

fake_issue 81 open
fake_issue 82 open
out="$("$ORCH" issue close 81 --duplicate-of 82 --comment-file "$close_comment" 2>&1)"; st=$?
assert_status "--duplicate-of closes the issue" "$st" 0
assert_eq "as a duplicate of the other" \
  "$(fake_state_of 81) $(fake_reason_of 81) $(fake_duplicate_of 81)" "CLOSED duplicate 82"
assert_eq "with the comment" "$(fake_comments_of 81)" "Done by #854: all three findings fixed."
assert_eq "and the other issue untouched" "$(fake_state_of 82)" "OPEN"

empty_comment="$(mktemp)"
fake_issue 83 open
close_refused "a non-numeric issue" "plain issue number" 8x3 --completed --comment-file "$close_comment"
close_refused "no issue at all" "usage: orch.sh issue close" --completed --comment-file "$close_comment"
close_refused "a non-numeric duplicate target" "plain issue number" 83 --duplicate-of '#82' --comment-file "$close_comment"
close_refused "a duplicate of itself" "duplicate of itself" 83 --duplicate-of 83 --comment-file "$close_comment"
close_refused "neither --completed nor --duplicate-of" "--completed or --duplicate-of" 83 --comment-file "$close_comment"
close_refused "both --completed and --duplicate-of" "--completed or --duplicate-of" 83 --completed --duplicate-of 82 --comment-file "$close_comment"
close_refused "a missing --comment-file" "--comment-file" 83 --completed
close_refused "a comment file that does not exist" "comment file not found" 83 --completed --comment-file /nonexistent/comment.md
close_refused "an empty comment file" "comment file is empty" 83 --completed --comment-file "$empty_comment"
close_refused "an unknown option" "usage: orch.sh issue close" 83 --completed --reason x --comment-file "$close_comment"
close_refused "a missing --duplicate-of value" "usage: orch.sh issue close" 83 --comment-file "$close_comment" --duplicate-of
close_refused "a missing --comment-file value" "usage: orch.sh issue close" 83 --completed --comment-file
close_refused "a second issue" "usage: orch.sh issue close" 83 84 --completed --comment-file "$close_comment"

# gh's reason rides on orch's own line, first line only (#846).
assert_gh_dies "a failed completed close exits 1" adapter_issue_close "$GH_502" 1 \
  "orch: gh could not close issue #83: HTTP 502: Bad Gateway" \
  "$ORCH" issue close 83 --completed --comment-file "$close_comment"
assert_gh_dies "a failed duplicate close names the gh it needs" adapter_issue_close "$GH_502" 1 \
  "orch: gh could not close issue #83: HTTP 502: Bad Gateway - --duplicate-of needs gh 2.102 or newer" \
  "$ORCH" issue close 83 --duplicate-of 82 --comment-file "$close_comment"
assert_eq "a failed close leaves it open" "$(fake_state_of 83)" "OPEN"
assert_eq "with no comment behind" "$(fake_comments_of 83)" ""

out="$("$ORCH" issue bogus 2>&1)"
assert_contains "the unknown-op message lists close" "$out" "|close"
assert_contains "help documents issue close" "$("$ORCH" help)" \
  "issue close <n> (--completed | --duplicate-of <m>) --comment-file <file>"
assert_contains "the CLI conventions' noun table lists issue close" \
  "$(grep '^| `issue`' "$PLUGIN_ROOT/docs/agents/cli-conventions.md")" '`close`'
rm -f "$close_comment" "$empty_comment"
restore_suite_env

# --- issue fetch/update -------------------------------------------------------
# The stateless issue body read/write pair - the same contract
# issue publish/pr publish/ticket publish already offer, extended to a plain
# issue's body. cmd_spec's fetch/update ops (further below) become thin
# wrappers over these, resolving the issue from state exactly as before - so
# this section proves the primitives work given just an issue number, before
# `init reviewtest` below ever writes a state.json into this repo.
#
# Goes through the store-backed fake (fake_github), what each op wrote read
# back from the store - the fixture gh's log stays empty, proving it never spawns a real
# gh subprocess. The real operations are pinned in "gh adapter contract".
echo
echo "issue fetch/update"
healthy_repo
fake_github
fake_issue 23 open
fake_issue_body 23 "Body of #23."
assert_eq "no state.json exists yet in this repo" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
issue_body="$(mktemp)"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" issue fetch 23 "$issue_body" 2>&1)"; st=$?
assert_status "fetch writes the issue's body to the file, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "exactly what GitHub holds" "$(cat "$issue_body")" "Body of #23."
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

rm -f "$issue_body"
out="$("$ORCH" issue fetch 404 "$issue_body" 2>&1)"; st=$?
assert_status "an issue gh cannot read fails the fetch" "$st" 1
assert_contains "naming the issue" "$out" "issue #404"
assert_eq "and leaves no file a caller could mistake for a body" \
  "$([ -e "$issue_body" ] && echo present || echo gone)" "gone"

# issue fetch streams gh's stdout to the file, so what gh printed - the body
# and the one newline gh's --jq adds - round-trips byte for byte, and its
# death carries gh's first line (#846). A read that prints nothing writes
# nothing: issue comments' empty file, below.
fidir="$(mktemp -d)"
fake_issue_body 23 $'Body of #23.\n\n'
"$ORCH" issue fetch 23 "$fidir/body.md"; st=$?
assert_status "fetch of a body ending in newlines succeeds" "$st" 0
assert_eq "keeping every trailing newline" "$(od -c <"$fidir/body.md")" "$(printf 'Body of #23.\n\n\n' | od -c)"
fake_issue_body 23 "Body of #23."
"$ORCH" issue fetch 23 "$fidir/body.md"
assert_eq "and adding none of its own to a body that has none" "$(od -c <"$fidir/body.md")" "$(printf 'Body of #23.\n' | od -c)"
assert_gh_dies "a failed body read fails the fetch" adapter_issue_body "$GH_502" 1 \
  "orch: gh could not read the body of issue #23: HTTP 502: Bad Gateway" \
  "$ORCH" issue fetch 23 "$fidir/body.md"
assert_eq "leaving the target untouched" "$(od -c <"$fidir/body.md")" "$(printf 'Body of #23.\n' | od -c)"
assert_eq "and no temp file beside it" "$(ls "$fidir")" "body.md"
assert_gh_dies "a silent failed body read fails the fetch" adapter_issue_body '' 1 \
  "orch: gh could not read the body of issue #23: gh gave no reason" \
  "$ORCH" issue fetch 23 "$fidir/body.md"
assert_eq "leaving the target untouched too" "$(od -c <"$fidir/body.md")" "$(printf 'Body of #23.\n' | od -c)"
assert_eq "and no temp file" "$(ls "$fidir")" "body.md"
rm -rf "$fidir"
unset fidir

# issue fetch --json (#528): the issue's title, body, labels and comments in one
# trimmed JSON object, so a fresh agent reads an issue with one call pinned to
# the repo. Its jq is ISSUE_JSON_JQ, pinned in "gh adapter contract".
fake_issue 27 open ready-for-agent bug
fake_issue_title 27 "Widgets need a handle"
fake_issue_body 27 "$(writeln '## What to build' '' 'A `$HOME` handle for #6.')"
fake_comment 27 pat 2026-09-02T11:30:00Z "Also: \\ stays unescaped."
issue_json="$(mktemp)"
printf 'old contents\n' >"$issue_json"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" issue fetch 27 "$issue_json" --json 2>&1)"; st=$?
assert_status "fetch --json writes the issue as JSON, over an existing file" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "the trimmed shape: number, title, body, label names, and each comment's author, date and body" \
  "$(jq -cS . "$issue_json" 2>&1)" \
  "$(jq -cS . <<'JSON'
{"number": 27, "title": "Widgets need a handle",
 "body": "## What to build\n\nA `$HOME` handle for #6.",
 "labels": ["ready-for-agent", "bug"],
 "comments": [{"author": "pat", "createdAt": "2026-09-02T11:30:00Z", "body": "Also: \\ stays unescaped."}]}
JSON
)"
assert_eq "the read never reached a real gh subprocess" "$(gh_calls)" "0"

out="$("$ORCH" issue fetch 27 "$issue_body" 2>&1)"; st=$?
assert_status "without --json, fetch still succeeds" "$st" 0
assert_eq "writing the body alone, as before" "$(cat "$issue_body")" \
  "$(writeln '## What to build' '' 'A `$HOME` handle for #6.')"

printf 'old contents\n' >"$issue_json"
fake_fail adapter_issue_json "$GH_502"
out="$("$ORCH" issue fetch 27 "$issue_json" --json 2>&1)"; st=$?
assert_status "a gh that will not answer fails fetch --json" "$st" 1
assert_eq "naming the issue, with gh's first line alone (#846)" "$out" \
  "orch: gh could not read issue #27: HTTP 502: Bad Gateway"
assert_eq "and leaves the file that was already there byte-identical" \
  "$(od -c "$issue_json")" "$(printf 'old contents\n' | od -c)"
rm -f "$issue_json"
out="$("$ORCH" issue fetch 27 "$issue_json" --json 2>&1)"; st=$?
assert_status "a failed fetch --json into no file fails too" "$st" 1
assert_eq "and leaves no file behind" \
  "$([ -e "$issue_json" ] && echo present || echo gone)" "gone"
fake_unfail

for args in "27 --json $issue_json" "--json 27 $issue_json" "27 $issue_json --jsn" "27 $issue_json --json extra"; do
  # shellcheck disable=SC2086 # each case is split into its words on purpose
  out="$("$ORCH" issue fetch $args 2>&1)"; st=$?
  assert_status "fetch refuses a misplaced or unknown flag: $args" "$st" 1
  assert_contains "with the usage line" "$out" "usage: orch.sh issue fetch <n> <file> [--json]"
done
assert_eq "and writes no file" "$([ -e "$issue_json" ] && echo present || echo gone)" "gone"
out="$("$ORCH" issue comments 27 "$issue_json" --json 2>&1)"; st=$?
assert_status "--json is fetch's alone: comments refuses it" "$st" 1
assert_contains "with its own usage line" "$out" "usage: orch.sh issue comments <n> <file>"
assert_eq "and writes no file" "$([ -e "$issue_json" ] && echo present || echo gone)" "gone"
assert_contains "help lists --json under issue fetch" "$("$ORCH" help)" "issue fetch <n> <file> [--json]"

tricky="$(mktemp)"
writeln '## Solution' '' 'Tracked in #6; see `$HOME` and '"'"'quoted'"'"' text.' >"$tricky"
out="$("$ORCH" issue update 23 "$tricky" 2>&1)"; st=$?
assert_status "update replaces the issue's body, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "the issue number given, not one from state, holds the file's contents, exactly" \
  "$(fake_body_of 23)" "$(cat "$tricky")"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the edit call never reached a real gh subprocess" "$(gh_calls)" "0"

out="$("$ORCH" issue update 23 "$tricky" --json 2>&1)"; st=$?
assert_status "--json is fetch's alone: update refuses it" "$st" 1
assert_contains "with its own usage line" "$out" "usage: orch.sh issue update <n> <file>"
assert_eq "and leaves the issue's body unchanged" "$(fake_body_of 23)" "$(cat "$tricky")"
for args in "23" "23 $tricky extra"; do
  # shellcheck disable=SC2086 # each case is split into its words on purpose
  out="$("$ORCH" issue update $args 2>&1)"; st=$?
  assert_status "update refuses the wrong argument count: $args" "$st" 1
  assert_contains "with its own usage line" "$out" "usage: orch.sh issue update <n> <file>"
done

out="$("$ORCH" issue update 23 /nonexistent/body.md 2>&1)"; st=$?
assert_status "update refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"

assert_gh_dies "a gh that will not edit fails the update" adapter_issue_body_edit "$GH_502" 1 \
  "orch: gh could not replace the body of issue #23: HTTP 502: Bad Gateway" \
  "$ORCH" issue update 23 "$tricky"

# issue comment is the stateless counterpart to spec comment, the way issue
# fetch/update are to spec fetch/update: a standalone spec review posts its
# summary on whatever issue it was pointed at, with no flow to ask.
out="$("$ORCH" issue comment 23 "$tricky" 2>&1)"; st=$?
assert_status "comment posts the file on the issue, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "on the issue number given, not one from state, the file's contents as the comment, exactly" \
  "$(fake_comments_of 23)" "$(cat "$tricky")"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the comment call never reached a real gh subprocess" "$(gh_calls)" "0"

out="$("$ORCH" issue comment 23 /nonexistent/body.md 2>&1)"; st=$?
assert_status "comment refuses a file that does not exist" "$st" 1
assert_contains "naming the file" "$out" "/nonexistent/body.md"
assert_eq "and posts nothing" "$(fake_comments_of 23)" "$(cat "$tricky")"

assert_gh_dies "a gh that will not comment fails it" adapter_issue_comment "$GH_502" 1 \
  "orch: gh could not comment on issue #23: HTTP 502: Bad Gateway" \
  "$ORCH" issue comment 23 "$tricky"

out="$("$ORCH" issue comment abc "$tricky" 2>&1)"; st=$?
assert_status "comment refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
assert_contains "with its own usage line" "$out" "usage: orch.sh issue comment <n> <file>"

for extra in --json extra; do
  out="$("$ORCH" issue comment 23 "$tricky" "$extra" 2>&1)"; st=$?
  assert_status "comment refuses a third argument (--json is fetch's alone): $extra" "$st" 1
  assert_contains "with its own usage line" "$out" "usage: orch.sh issue comment <n> <file>"
  assert_eq "and posts nothing" "$(fake_comments_of 23)" "$(cat "$tricky")"
done

out="$("$ORCH" issue comment 23 2>&1)"; st=$?
assert_status "comment refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue comment"

out="$("$ORCH" issue 2>&1)"; st=$?
assert_status "refuses no op at all" "$st" 1
assert_contains "listing comment among the ops it has" "$out" "comment"

out="$("$ORCH" issue fetch abc "$issue_body" 2>&1)"; st=$?
assert_status "fetch refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
assert_contains "with the fetch usage line" "$out" "usage: orch.sh issue fetch <n> <file> [--json]"

out="$("$ORCH" issue update abc "$tricky" 2>&1)"; st=$?
assert_status "update refuses the same" "$st" 1
assert_contains "naming it" "$out" "abc"
assert_contains "with its own usage line" "$out" "usage: orch.sh issue update <n> <file>"

out="$("$ORCH" issue fetch 23 2>&1)"; st=$?
assert_status "fetch refuses with no file" "$st" 1
assert_contains "with the fetch usage line" "$out" "usage: orch.sh issue fetch <n> <file> [--json]"

out="$("$ORCH" issue bogus 23 "$tricky" 2>&1)"; st=$?
assert_status "refuses an op it does not have" "$st" 1
assert_contains "naming the six it does" "$out" "fetch|update|comment|comments|publish|triage"

assert_contains "help documents issue fetch" "$("$ORCH" help)" "issue fetch"
assert_contains "and issue update" "$("$ORCH" help)" "issue update"
assert_contains "and issue publish" "$("$ORCH" help)" "issue publish"
assert_contains "and issue comment" "$("$ORCH" help)" "issue comment"

# issue comments: every comment on an issue, each opened by a marker line
# naming its author and timestamp, so the spec review reads the issue's
# comments alongside its body (issue #361). The marker's own format is
# COMMENTS_JQ's, pinned in "gh adapter contract".
fake_issue 24 open
fake_comment 24 triage-bot 2026-09-01T10:00:00Z "$(writeln '## Agent brief' '' 'Do the `$HOME` thing in #6.')"
fake_comment 24 pat 2026-09-02T11:30:00Z "$(writeln 'Also: the second line' '\\ stays unescaped.')"
issue_comments="$(mktemp)"
: >"$GH_FIXTURE/env.log"
out="$("$ORCH" issue comments 24 "$issue_comments" 2>&1)"; st=$?
assert_status "comments writes the issue's comments to the file, with no state.json present" "$st" 0
assert_eq "and prints nothing" "$out" ""
assert_eq "each comment in order, opened by its author-and-date marker, one blank line between" \
  "$(cat "$issue_comments")" "$(writeln '<!-- comment @triage-bot 2026-09-01T10:00:00Z -->' \
    '## Agent brief' '' 'Do the `$HOME` thing in #6.' '' \
    '<!-- comment @pat 2026-09-02T11:30:00Z -->' 'Also: the second line' '\\ stays unescaped.')"
assert_eq "records no state" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_eq "the view call never reached a real gh subprocess" "$(gh_calls)" "0"

fake_issue 25 open
out="$("$ORCH" issue comments 25 "$issue_comments" 2>&1)"; st=$?
assert_status "an issue with no comments still succeeds" "$st" 0
assert_eq "leaving an empty file" "$(wc -c <"$issue_comments" | tr -d ' ')" "0"

printf 'known content\n' >"$issue_comments"
assert_gh_dies "a gh that will not answer fails the comments fetch" adapter_issue_comments "$GH_502" 1 \
  "orch: gh could not read the comments of issue #24: HTTP 502: Bad Gateway" \
  "$ORCH" issue comments 24 "$issue_comments"
assert_eq "and leaves the file that was already there byte-identical" \
  "$(od -c "$issue_comments")" "$(printf 'known content\n' | od -c)"

out="$("$ORCH" issue comments abc "$issue_comments" 2>&1)"; st=$?
assert_status "comments refuses an issue number that is not a plain number" "$st" 1
assert_contains "naming it" "$out" "abc"
assert_contains "with its own usage line" "$out" "usage: orch.sh issue comments <n> <file>"

out="$("$ORCH" issue comments 23 2>&1)"; st=$?
assert_status "comments refuses with no file" "$st" 1
assert_contains "with a usage line" "$out" "usage: orch.sh issue comments"

assert_contains "help documents issue comments" "$("$ORCH" help)" "issue comments"
rm -f "$issue_comments"

assert_eq "still no state.json - this section recorded none" \
  "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"

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

state_fixture iteration 0
"$ORCH" state set budget 2
assert_eq "a budget of 2 admits the first iteration" "$("$ORCH" review begin)" "1"
assert_eq "and the second" "$("$ORCH" review begin)" "2"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the third" "$st" 1
assert_contains "naming the budget it honoured" "$out" "budget of 2 iterations"

state_fixture iteration 0
"$ORCH" state set budget 8
for i in 1 2 3 4 5 6 7 8; do "$ORCH" review begin >/dev/null; done
assert_eq "a budget of 8 runs past the old bound of five" "$("$ORCH" state get iteration)" "8"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and stops at eight" "$st" 1

# A budget nothing can read is the default, not a refusal: the only flows that
# carry one are the ones started before it existed.
state_fixture iteration 4
"$ORCH" state set budget null
assert_eq "a null budget reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth" "$st" 1
state_fixture iteration 4
"$ORCH" state set budget lots
assert_eq "a budget that is not a number reads as five" "$("$ORCH" review begin)" "5"
out="$("$ORCH" review begin 2>&1)"; st=$?
assert_status "and refuses the sixth too" "$st" 1
"$ORCH" state set budget null
restore_suite_env

# --- outside a checkout (#931) ---------------------------------------------------
# Run from the suite's own non-repo cwd: the death names the cwd and the
# remedy. It comes before dispatch, so any subcommand reaches it.
echo
echo "outside a checkout (#931)"
cd "$SUITE_CWD" || exit 1
err="$(bash "$ORCH" issue fetch 931 out.md 2>&1 >/dev/null)"; st=$?
assert_status "orch.sh outside a git repository exits 1" "$st" 1
assert_eq "naming the cwd and the remedy" "$err" \
  "orch: not inside a git repository ($PWD) - run orch.sh from inside the repo's checkout"
