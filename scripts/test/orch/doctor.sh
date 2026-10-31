# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# Git Bash / MSYS2 (and Cygwin) both set OSTYPE this way; used to skip fixtures
# that are known not to work in that environment rather than report a false
# FAIL.
on_windows_bash() {
  case "$OSTYPE" in msys*|cygwin*) return 0 ;; *) return 1 ;; esac
}
skip_no_jq() { skip "$1" "path_without_jq doesn't work on Windows/Git Bash - see its definition"; }

# A PATH with everything orch.sh reaches for except jq. Reporting "jq is
# missing" is the one thing doctor has to do without jq, so the only honest way
# to test it is to actually take jq away.
#
# Known gap: this doesn't work on Windows/Git Bash (MSYS) or Cygwin. `printf`
# has no external binary to `ln -sf` there (it's builtin-only), and MSYS's
# path translation between the trimmed Unix-style PATH and the Windows-side
# resolution needed to launch orch.sh breaks down under it - the invocation
# exits 127 with empty output before orch.sh's own logic ever runs. Callers
# guard with on_windows_bash and skip rather than report a false FAIL - see
# issue #68.
path_without_jq() {
  local d t p
  d="$(mktemp -d)"
  for t in env bash git gh awk sed grep tr cat sort tail head date mktemp mv rm mkdir chmod basename dirname printf; do
    if p="$(command -v "$t" 2>/dev/null)"; then ln -sf "$p" "$d/$t"; fi
  done
  printf '%s\n' "$d"
}

# fake_label_names <name>...: the repo's labels are exactly the names given,
# each with no colour or description - none given, the repo has no labels.
fake_label_names() {
  : >"$ORCH_GH_FAKE_STORE/labels"
  [ $# -eq 0 ] || printf '%s\t\t\n' "$@" >"$ORCH_GH_FAKE_STORE/labels"
}

# fake_local_default <owner/name>: gh's own local default repo for the
# checkout; given an empty one, none is set.
fake_local_default() {
  if [ -n "$1" ]; then printf '%s\n' "$1" >"$ORCH_GH_FAKE_STORE/local_default"
  else rm -f "$ORCH_GH_FAKE_STORE/local_default"; fi
}

# fake_no_sub_issues: the sub-issues endpoint refuses every issue, as on a
# GitHub that does not support them.
fake_no_sub_issues() { : >"$ORCH_GH_FAKE_STORE/no_sub_issues"; }

# fake_noauth: gh is not authenticated - the auth status fails saying so,
# every other operation as unauthorised. setup.sh's fake_online undoes it.
fake_noauth()  { : >"$ORCH_GH_FAKE_STORE/noauth"; }

# doctor_github: fake_github, seeded as the GitHub a healthy repo has for
# doctor - the default labels doc's two labels, default branch main, and one
# open issue for the sub-issues probe to ask about.
doctor_github() {
  fake_github
  fake_label_names needs-triage ready-for-agent
  fake_default_branch main
  fake_issue 1 open
}

# path_without_jq() builds its restricted PATH from whatever's really on PATH,
# not from repo state, so the one built here serves every no-jq assertion
# (in doctor and in doctor --flow) instead of symlinking the same ~20 tools
# afresh at each call site. Its gh is a fixture gh, made in the subshell so
# the suite's own PATH is left alone. Empty on Windows/Git Bash, where callers
# skip.
nojq_path=""
on_windows_bash || nojq_path="$(gh_fixture && path_without_jq)"

# --- host detection (host.sh, #281) -------------------------------------------
echo
echo "host detection (host.sh, #281)"
# host.sh is sourced alone, in a fresh shell with every host signal unset, so
# it is shown to need nothing from orch.sh. host_on runs host_detect there,
# after the given VAR=value assignments, with the remaining arguments.
HOST_SH="$(dirname "$ORCH")/host.sh"
host_on() {
  local assigns=()
  while [ $# -gt 0 ] && [[ "$1" == *=* ]]; do assigns+=("$1"); shift; done
  [ "${1:-}" = -- ] && shift
  env -u ORCHESTRATOR_HOST -u CLAUDECODE -u JUNIE_EXTENSION_ROOT -u JUNIE_SHIM_PATH \
    -u CLAUDE_PLUGIN_ROOT "${assigns[@]}" \
    bash -c 'source "$1" && shift && host_detect "$@"' host_on "$HOST_SH" "$@"
}
assert_eq "payload mode: a non-empty project_path is junie" \
  "$(host_on -- '{"project_path":"/r"}')" "junie"
assert_eq "payload mode: no project_path is claude" "$(host_on -- '{}')" "claude"
assert_eq "payload mode: an empty project_path is claude" \
  "$(host_on -- '{"project_path":""}')" "claude"
assert_eq "payload mode: a null project_path is claude" \
  "$(host_on -- '{"project_path":null}')" "claude"
assert_eq "payload mode: an empty payload is claude" "$(host_on -- '')" "claude"
assert_eq "payload mode: a payload that is not JSON is claude" \
  "$(host_on -- 'not json' 2>/dev/null)" "claude"
assert_eq "payload mode ignores ORCHESTRATOR_HOST=claude" \
  "$(host_on ORCHESTRATOR_HOST=claude -- '{"project_path":"/r"}')" "junie"
assert_eq "payload mode ignores ORCHESTRATOR_HOST=junie" \
  "$(host_on ORCHESTRATOR_HOST=junie -- '{}')" "claude"
assert_eq "environment mode: no signal prints nothing" "$(host_on)" ""
assert_eq "environment mode: ORCHESTRATOR_HOST names the host" \
  "$(host_on ORCHESTRATOR_HOST=junie)" "junie"
assert_eq "environment mode: JUNIE_SHIM_PATH is junie" \
  "$(host_on JUNIE_SHIM_PATH=/x)" "junie"
assert_eq "environment mode: CLAUDECODE=1 is claude" "$(host_on CLAUDECODE=1)" "claude"
assert_eq "environment mode: JUNIE_SHIM_PATH outranks CLAUDECODE=1" \
  "$(host_on JUNIE_SHIM_PATH=/x CLAUDECODE=1)" "junie"
assert_eq "doctor.sh no longer defines host_detect" \
  "$(grep -c '^host_detect()' "$(dirname "$ORCH")/orch/doctor.sh")" "0"

# --- doctor.sh is a one-way dependency (#281) ---------------------------------
echo
echo "doctor.sh is a one-way dependency (#281)"
# doctor.sh calls into orch.sh, never the other way round: the code view
# (shell_code) of orch.sh and of every module beside doctor.sh in its orch/
# directory names, as a whole word, no function doctor.sh defines - a name in a
# comment is no call; one in a quoted literal is - except cmd_doctor, which
# main() dispatches, and the reporters d_ok, d_warn, d_fail and d_remedy, which
# a check living in the module of the concept it serves (agent.sh's
# check_agent_settings, #1358) reports through when doctor runs it.
# doctor_callbacks <scripts-dir> prints each such name found, for the
# functions defined in <scripts-dir>/orch/doctor.sh. host.sh,
# triage-labels.sh and planning-allowlist.sh are outside it: the hooks share
# them, and they call nothing in doctor.sh.
doctor_callbacks() {
  local doctor_file="$1/orch/doctor.sh" code_files=() f
  for f in "$1/orch.sh" "$1"/orch/*.sh; do
    [ "$f" = "$doctor_file" ] || code_files+=("$f")
  done
  layer_calls "$doctor_file" -- "${code_files[@]}" \
    | grep -vxE 'cmd_doctor|d_ok|d_warn|d_fail|d_remedy' || true
}
dep_dir="$(mktemp -d)"
mkdir "$dep_dir/orch"
printf '%s\n' 'check_x() {' '  :' '}' 'd_ok() { :; }' 'cmd_doctor() { check_x; }' >"$dep_dir/orch/doctor.sh"
printf '%s\n' 'main() { cmd_doctor; }' >"$dep_dir/orch.sh"
printf '%s\n' '# check_x is named in a comment only' '  # check_x again' \
  'run() { cmd_doctor; check_xy; }' 'check_y() { d_ok y; }' >"$dep_dir/orch/clean.sh"
assert_eq "a comment, cmd_doctor, a reporter or a longer word is no call back into doctor.sh" \
  "$(doctor_callbacks "$dep_dir")" ""
printf '%s\n' 'x=1 # check_x' >"$dep_dir/orch/trailing.sh"
assert_eq "a name in a trailing comment is no call back into doctor.sh" \
  "$(doctor_callbacks "$dep_dir")" ""
rm "$dep_dir/orch/trailing.sh"
printf '%s\n' 'run() { check_x; }' >"$dep_dir/orch/calls.sh"
assert_eq "a doctor.sh function called from a module is caught" \
  "$(doctor_callbacks "$dep_dir")" "check_x"
rm -rf "$dep_dir"
assert_eq "orch.sh and its modules call no doctor.sh function but cmd_doctor" \
  "$(doctor_callbacks "$(dirname "$ORCH")" | tr '\n' ' ')" ""

# --- doctor -----------------------------------------------------------------
# The two commands doctor replaces both returned success on the failures that
# actually end flows, so what these assert is the *severity* of each condition,
# not just that it got a mention.
echo
echo "doctor"
healthy_repo
doctor_github

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
if on_windows_bash; then
  skip_no_jq "fails when jq is missing"
  skip_no_jq "names jq rather than dying mid-report"
  skip_no_jq "still reaches the summary line without jq"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --env 2>&1)"; st=$?
  assert_status "fails when jq is missing" "$st" 1
  assert_contains "names jq rather than dying mid-report" "$out" "jq"
  assert_contains "still reaches the summary line without jq" "$out" " FAIL"
fi

# Severity is the behaviour under test, not the wording: "GitHub said no" must
# FAIL and "GitHub could not tell us" must only warn. Written backwards, doctor
# either blocks every flow run away from a good network or waves through the two
# failures it exists to catch, and both look plausible in a passing test suite.
# No healthy_repo() here: nothing above this point wrote to the repo (doctor
# itself never mutates, and the jq-missing checks only scoped PATH to a
# subshell), so the fixture from the top of the section is still clean.
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when a documented label is missing from the repo" "$st" 1
assert_contains "names the missing label with its backticks stripped" "$out" "ready-for-agent"
assert_contains "gives the command that creates it" "$out" 'gh label create "ready-for-agent"'
assert_contains "indents the remedy under its FAIL by six spaces" \
  "$out" "$(printf '\n      gh label create')"
assert_eq "strips the backticks the doc writes labels in" \
  "$(printf '%s\n' "$out" | grep -c '`')" "0"
assert_contains "counts one FAIL and no warns" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 1 FAIL"

# Still the fixture from the top of the section - nothing since has written
# anything besides the labels doc this call is about to overwrite anyway.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning |' \
        '| -------------------------- | -------------------- | ------- |' \
        '| `needs-triage`             | `needs triage`       | Look    |' >docs/agents/triage-labels.md
fake_label_names 'needs triage'
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label with a space in it is one label, not two" "$st" 0
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "quotes a multi-word label in the remedy" "$out" 'gh label create "needs triage"'

# A label beginning with '-' is a label, never a grep option.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning |' \
        '| -------------------------- | -------------------- | ------- |' \
        '| `needs-triage`             | `-triage`            | Look    |' \
        '| `ready-for-agent`          | `-agent`             | Go      |' >docs/agents/triage-labels.md
fake_label_names -triage -agent
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes when the repo has labels beginning with '-'" "$st" 0
assert_contains "finding every one of them" "$out" "every triage label exists on the repo"

# A label list whose names past the limit are more than a pipe holds (#1019):
# 5,000 names of 45 bytes past doctor's limit of 1,000. A listing that pipes
# them into head takes SIGPIPE once head has its lines and, under pipefail,
# fails - on every run - and doctor warns the labels could not be listed.
healthy_repo
doctor_github
filler_labels=()
for i in $(seq -w 1 6000); do filler_labels+=("filler-label-with-a-long-enough-name-pad-$i"); done
fake_label_names needs-triage ready-for-agent "${filler_labels[@]}"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label list of over 200 KiB past the limit does not block the flow" "$st" 0
assert_not_contains "and is listed" "$out" "the repo's labels could not be listed"
assert_contains "finding every triage label among the first 1000" "$out" \
  "every triage label exists on the repo"
# The same list with a triage label past the limit: the cut is kept.
fake_label_names needs-triage "${filler_labels[@]}" ready-for-agent
out="$("$ORCH" doctor --env 2>&1)"
assert_not_contains "a triage label past the limit is still listed" "$out" \
  "the repo's labels could not be listed"
assert_contains "and cannot be confirmed, by name" "$out" \
  "warn  the repo has more than 1000 labels - cannot confirm: ready-for-agent"

# GitHub answered the auth probe and then would not answer this one: an absent
# answer, not a "no", so it warns.
healthy_repo
doctor_github
fake_fail adapter_labels $'HTTP 403: Forbidden\nsecond line'
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unlistable label set does not block the flow" "$st" 0
assert_contains "says the labels could not be listed, with gh's first line" "$out" \
  "warn  the repo's labels could not be listed: HTTP 403: Forbidden"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
fake_unfail
fake_fail_times adapter_labels 5
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "a silently failing label listing says gh gave no reason" "$out" \
  "warn  the repo's labels could not be listed: gh gave no reason"
fake_unfail

# The default-branch read is the one that tells doctor GitHub can see the repo:
# when it fails, the FAIL carries gh's own first line.
fake_fail adapter_repo_default_branch $'HTTP 404: Not Found\nsecond line'
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a repo GitHub will not show fails doctor" "$st" 1
assert_contains "saying GitHub cannot see it, with gh's first line" "$out" \
  "FAIL  GitHub cannot see acme/widgets - origin may point somewhere you cannot see: HTTP 404: Not Found"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
fake_fail_times adapter_repo_default_branch 5
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "a repo read failing silently says gh gave no reason" "$out" \
  "FAIL  GitHub cannot see acme/widgets - origin may point somewhere you cannot see: gh gave no reason"

# The repo the healthy_repo() call before the labels check built is still
# clean here; only its failing label listing is undone.
fake_unfail
fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "does not fail merely because GitHub is unreachable" "$st" 0
assert_contains "collapses the checks that needed GitHub into one line" \
  "$out" "checks skipped: GitHub is not reachable"
assert_eq "emits one skip line, not one per skipped check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"
# The skip lines are a group like any other, so they carry a header and a blank
# line rather than trailing loose off the end of the last one.
assert_contains "puts the skipped group under a bare header" \
  "$out" "$(printf '\n\nskipped\nwarn  ')"

fake_online
fake_noauth
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when gh is not authenticated" "$st" 1
assert_contains "gives the login command" "$out" "gh auth login"
assert_contains "skips the checks that depended on the answer" "$out" "skipped: not authenticated"
fake_online

fake_default_branch ''
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unresolved default branch does not block the flow" "$st" 0
assert_contains "warns that the default branch came from a fallback" "$out" "default branch"

# GitHub's answer is validated as default_branch validates it (#485): a tool
# manager's banner around the name is no branch name, so doctor falls back as
# default_branch does rather than reporting the banner as the branch.
fake_default_branch "$(printf 'mise ~/.config/mise/config.toml tools: gh@2.102.0\nmain\n')"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a polluted default branch does not block the flow" "$st" 0
assert_contains "warns the default branch was not resolved from GitHub" \
  "$out" "warn  default branch not resolved from GitHub"
assert_not_contains "and never reports the banner as the branch" "$out" "mise"
fake_default_branch main

# doctor reports the repo the orchestrator works on (#520): resolved locally,
# with its source, and never gh's own default, which in a fork is the upstream.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "the repo line names the resolved repo and its source" \
  "$out" "ok    repo: acme/widgets (origin)"
out="$(GH_REPO=fork/widgets "$ORCH" doctor --env 2>&1)"
assert_contains "the repo line names GH_REPO when the caller set it" \
  "$out" "ok    repo: fork/widgets (GH_REPO)"
# Which repo doctor's operations are pinned to, and the repo view's
# positional repo, are the operations' own, pinned in "gh adapter contract".
fake_local_default upstream/widgets
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a differing gh default repo does not block the flow" "$st" 0
assert_contains "warns naming gh's default repo and the one in use" "$out" \
  "warn  gh's default repo is upstream/widgets; the orchestrator uses acme/widgets"
fake_local_default acme/widgets
out="$("$ORCH" doctor --env 2>&1)"
assert_not_contains "a matching gh default repo raises no warn" "$out" "gh's default repo"
# gh repo set-default --view prints a bare owner/name even for a default on a
# host other than github.com (gh 2.102.0), so the same repo there is no warn.
out="$(GH_REPO=ghe.example.com/acme/widgets "$ORCH" doctor --env 2>&1)"
assert_not_contains "a matching gh default repo on another host raises no warn" "$out" "gh's default repo"
fake_local_default ""
# No repo at all: a FAIL with the remedy, and doctor carries on past it - the
# later GitHub checks counted on the skip line, no gh call made at all. The
# real adapter runs here, over a fixture gh that logs every call it gets.
savepath="$PATH"; gh_fixture; PATH="$savepath"
out="$(orch_no_repo doctor --env 2>&1)"; st=$?
assert_status "no resolvable repo fails doctor" "$st" 1
assert_contains "names the missing repo as a FAIL, with no remedy in it" "$out" \
  "FAIL  $repo_cause"
assert_contains "gives the GH_REPO remedy" "$out" "export GH_REPO=<owner>/<repo>"
assert_eq "gives the GH_REPO instruction exactly once" \
  "$(printf '%s\n' "$out" | grep -c 'GH_REPO=<owner>/<repo>')" "1"
assert_eq "counts the later GitHub checks on the skip line, naming the bare cause" \
  "$(printf '%s\n' "$out" | grep -cx "warn  [0-9]* GitHub checks\\{0,1\\} skipped: $repo_missing")" "1"
assert_contains "still reaches the summary line" "$(printf '%s\n' "$out" | tail -1)" " FAIL"
assert_eq "makes no gh call without a repo to pin it to" "$(cat "$GH_FIXTURE/env.log" 2>/dev/null | wc -l | tr -d ' ')" "0"
unset GH_FIXTURE

# The plugin depends on no other plugin (ADR-0028): doctor says nothing of
# mattpocock-skills, and the old override pointing nowhere changes nothing.
# No healthy_repo() needed: the checks above put back each GitHub condition
# they seeded, so the repo is still clean.
out="$("$ORCH" doctor --env 2>&1)"; st=$?
out_mp="$(ORCHESTRATOR_MATTPOCOCK_ROOT=/nonexistent "$ORCH" doctor --env 2>&1)"; st_mp=$?
assert_eq "the old mattpocock override changes no exit status" "$st_mp" "$st"
assert_eq "nor any line of the output" "$out_mp" "$out"
assert_not_contains "says nothing of mattpocock-skills" "$out" "mattpocock"

# Setup is optional: a repo with no docs/agents/ at all is a working repo, its
# labels the five canonical names.
canonical_labels="$(printf '%s\n' needs-triage needs-info ready-for-agent ready-for-human wontfix)"
healthy_repo
doctor_github
rm -rf docs/agents
# shellcheck disable=SC2086 # one label per word
fake_label_names $canonical_labels
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a repo with no docs/agents/ passes" "$st" 0
assert_not_contains "and names no mattpocock" "$out" "mattpocock"
assert_not_contains "nor its setup skill" "$out" "setup-matt-pocock-skills"
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "with no labels doc, the canonical names are checked on the repo" "$st" 1
for l in needs-triage needs-info ready-for-agent ready-for-human wontfix; do
  assert_contains "and a missing $l is named" "$out" "gh label create \"$l\""
done
fake_label_names needs-triage
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a repo missing only some canonical labels fails" "$st" 1
assert_not_contains "and does not name the ones it has" "$out" 'gh label create "needs-triage"'

# A present doc still wins: a renamed label is checked under its local name.
healthy_repo
doctor_github
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `agent go`           | AFK-ready   |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a renamed-label doc is still checked" "$st" 1
assert_contains "under the repo's own label name" "$out" 'gh label create "agent go"'
assert_not_contains "not the canonical one" "$out" 'gh label create "ready-for-agent"'

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
# This healthy_repo() does earn its keep: the renamed-label check above left a
# one-row doc behind, and every labels-doc variant below needs a clean repo so
# the only FAIL it can produce is the one the table shape under test causes.
healthy_repo
doctor_github
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
# No healthy_repo() here or in the labels-doc variants below: each one only
# ever dirtied the labels doc, and the writeln right after overwrites it
# again before anything reads it, so re-running the whole fixture just to
# replace one file it's about to replace anyway would be pure waste.
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
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning' \
        '| -------------------------- | -------------------- | -------' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table without its trailing pipes still parses" "$st" 0
assert_contains "reads both labels out of it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label          | Meaning     |' \
        '| -------------- | ----------- |' \
        '| `needs-triage` | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails on a table that is not the documented shape" "$st" 1
assert_eq "does not read a label out of some other column" \
  "$(printf '%s\n' "$out" | grep -c 'Evaluate it')" "0"
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

# The width rule now hinges entirely on recognising the separator row, and these
# are the two ways that recognition goes wrong: a separator dressed with
# alignment colons, and a doc that never has one.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| :------------------------- | :------------------: | ----------: |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' \
        '| `ready-for-agent`          | `ready-for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an alignment-colon separator is still a separator" "$st" 0
assert_contains "reads the labels under it" "$out" "2 triage labels"

writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| `needs-triage`             | `needs-triage`       | Evaluate it |' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a table with no separator row parses to nothing" "$st" 1
assert_eq "reads no label out of a table it never confirmed the width of" \
  "$(printf '%s\n' "$out" | grep -c 'needs-triage')" "0"
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

writeln '# Triage Labels' '' 'This repo does not use a table.' >docs/agents/triage-labels.md
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "fails when the labels doc parses to no labels" "$st" 1
assert_contains "says to fix the table or delete it" "$out" "delete it to use the canonical names"

rm docs/agents/triage-labels.md
# shellcheck disable=SC2086 # one label per word
fake_label_names $canonical_labels
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "passes when the labels doc is absent entirely" "$st" 0
assert_not_contains "and does not call the doc missing" "$out" "triage-labels.md is missing"

# A label list long enough to fill the page is a list that may be cut off, so
# naming labels as missing from it would be a FAIL derived from not knowing.
# This healthy_repo() is load-bearing: the doc was just deleted above, and
# every check from here through the exclude-line one below needs the default
# labels doc back, with nothing else in between rewriting it.
healthy_repo
doctor_github
# shellcheck disable=SC2046 # one label per word
fake_label_names $(seq 1 1000)
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a label list that filled the page does not FAIL" "$st" 0
assert_contains "names the labels it cannot vouch for" "$out" "cannot confirm:"
assert_contains "names them individually" "$out" "needs-triage, ready-for-agent"

# ...but a page that filled up and still held every documented label answered
# the question. The caveat qualifies a negative; there is no negative here.
# The repo is still the one healthy_repo() built two checks up.
# shellcheck disable=SC2046 # one label per word
fake_label_names needs-triage ready-for-agent $(seq 1 1000)
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a full page that held every label is still a pass" "$st" 0
assert_contains "does not hedge an answer it actually has" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

out="$("$ORCH" doctor --env 2>&1)"
assert_contains "counts only the documented labels, not the header row" \
  "$out" "2 triage labels"

# Escaped pipes (issue #5): markdown's `\|` inside a cell is a literal `|`,
# never a column separator. Without that, an escaped cell shifts every column
# after it for that row - the label column reads a fragment of the escaped
# cell instead of the real label, and the real label is lost entirely.
# A repo with no labels makes every documented label print a "gh label
# create" remedy, which is the easiest window onto exactly what triage_labels
# parsed each row down to.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs\|triage`       | Evaluate it |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe inside the label column becomes a literal pipe" \
  "$out" 'gh label create "needs|triage"'
assert_eq "does not truncate the label at the escaped pipe" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "needs"')" "0"

# The ticket's own repro: the escape sits in the *other* column (the
# mattpocock-skills name), yet it is column 3 - the label doctor actually
# reads - that comes out corrupted, because the escaped cell shifted it.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `a\|b`                     | `needs-triage`        | do it       |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the mattpocock-name column does not shift the label column" \
  "$out" 'gh label create "needs-triage"'
assert_eq "does not invent a label out of the shifted fragment" \
  "$(printf '%s\n' "$out" | grep -c 'gh label create "b"')" "0"

# The Meaning column sits after the one doctor reads, so an escape there is
# the least likely to leak - which is exactly why it earns a test locking
# that in, rather than trusting it stays that way by accident.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `needs-triage`             | `needs-triage`        | Look \|out  |' >docs/agents/triage-labels.md
fake_label_names
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "an escaped pipe in the meaning column does not corrupt the label column" \
  "$out" 'gh label create "needs-triage"'

# triage_label_for shares the same row-splitting bug: an escape in the
# repo's local label corrupts the very value validate_adopted_issue compares
# against a real issue's labels.
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `ready\|for-agent`    | AFK-ready   |' >docs/agents/triage-labels.md
fake_issue 7 open needs-triage
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses adoption when the escape-restored label is missing" "$st" 1
assert_contains "names the label with its escaped pipe restored, not truncated" \
  "$out" "ready|for-agent"
fake_issue 7 open 'ready|for-agent'
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the escape-restored label" "$st" 0

# Restores the canonical labels doc and a clean, flow-free repo: the escaped-
# pipe block above both rewrote the doc away from its default shape and left
# an adopted flow active, and the sub-issues section right after this expects
# the plain "fully healthy repo" the earlier healthy_repo() call above had
# left before this block started borrowing it.
healthy_repo
doctor_github

# Issue #39: triage_label_for lacks triage_labels' table-boundary/column-count
# guard, so a second, differently-shaped table elsewhere in the doc can shadow
# the real answer. Placed *before* the real table, with a row that resolves to
# the same role, so a reader with no boundary awareness matches it first and
# never reaches the real table at all.
writeln '# Other Reference' '' \
        '| Role | Other |' \
        '| ready-for-agent | wrong-label |' \
        '' \
        '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| --------------------------- | --------------------- | ----------- |' \
        '| `needs-triage`              | `needs-triage`         | Evaluate it |' \
        '| `ready-for-agent`           | `ready-for-agent`      | AFK-ready   |' >docs/agents/triage-labels.md

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "list-labels: an unrelated table before the real one still passes" "$st" 0
assert_contains "still reads exactly the two documented labels" "$out" "2 triage labels"
assert_eq "does not read the unrelated table's value in as a label" \
  "$(printf '%s\n' "$out" | grep -c 'wrong-label')" "0"

fake_issue 7 open wrong-label
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "label-for ignores the unrelated table's row rather than matching it" "$st" 1
assert_contains "resolves the role against the real table's label, not the one before it" \
  "$out" "ready-for-agent"

fake_issue 7 open ready-for-agent
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "adopts once the issue carries the real table's label" "$st" 0

# Reset again: the successful adopt above just left a flow active, and the
# sub-issues checks right after this expect the plain flow-free healthy repo.
healthy_repo
doctor_github

# Sub-issues carry no enable/disable setting of their own, so the only
# reliable signal is asking the endpoint against an issue that exists and
# reading whether it answers or 404s. doctor_github's issue answers, and
# the "fully healthy repo" assertion at the end of this section already
# depends on that, so this is really confirming the ok line it produces.
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "sub-issues supported: still a healthy pass" "$st" 0
assert_contains "reports sub-issues as supported" "$out" "ok    sub-issues supported"

# The endpoint 404ing (or otherwise refusing) reads as "not supported" -
# advisory, so a warn, never a FAIL: the real gate is ticket_publish's own
# verify-then-die, not this probe.
fake_no_sub_issues
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "unsupported sub-issues does not block the flow" "$st" 0
assert_contains "warns rather than fails when sub-issues are unsupported" \
  "$out" "warn  sub-issues do not appear to be supported"
assert_contains "explains the consequence rather than leaving it silent" \
  "$out" "ticket publish will fail"

# A repo with no issues at all has nothing to probe against - still a warn,
# not a FAIL, and a distinct message from the unsupported case above.
fake_github
fake_label_names needs-triage ready-for-agent
fake_default_branch main
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no issue to probe against does not block the flow" "$st" 0
assert_contains "says the probe could not run rather than guessing" \
  "$out" "warn  sub-issues support could not be probed - the repo has no issue to test it against."

# A probe that fails (a 502, a 403, no connection) is neither "unsupported" nor
# "no issue": the warn carries gh's own first line instead (#554).
doctor_github
fake_fail adapter_sub_issues_supported "$GH_502"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a failing sub-issues probe does not block the flow" "$st" 0
assert_contains "warns with gh's first line" \
  "$out" "warn  sub-issues support could not be probed: HTTP 502: Bad Gateway"
assert_not_contains "and never as a repo with no issue" "$out" "no issue to test it against"
assert_not_contains "nor as unsupported" "$out" "do not appear to be supported"
assert_not_contains "nor past gh's first line" "$out" "second line"
fake_unfail

# A probe that fails with nothing on stderr says so, rather than ending in a
# bare colon (#766).
fake_fail_times adapter_sub_issues_supported 5
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a silently failing sub-issues probe does not block the flow" "$st" 0
assert_contains "warns that gh gave no reason" \
  "$out" "warn  sub-issues support could not be probed: gh gave no reason"
assert_not_contains "never with a bare colon" "$out" "could not be probed: "$'\n'
fake_unfail

# Gated like every other GitHub-backed check: unreachable collapses into the
# shared skip line rather than adding a check-specific one of its own.
doctor_github
fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "GitHub unreachable does not block the flow either" "$st" 0
assert_eq "still emits exactly one skip line, not a second for this check" \
  "$(printf '%s\n' "$out" | grep -c 'skipped:')" "1"

fake_online

# Still the fixture healthy_repo() built for the label-list checks above -
# nothing since has touched anything but $out - so truncating the exclude
# file here is the only new mutation, and it's this test's own setup, not
# leftover state to clean up first.
: >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing git exclude line warns without blocking" "$st" 0
assert_contains "counts one warn and no FAILs" \
  "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "gives a command that adds the exclude line" "$out" "info/exclude"
assert_contains "one warning names both missing lines" "$out" "warn  .orchestrator/, .scratch/ not git-excluded"
remedy="$(printf '%s\n' "$out" | grep -A1 'not git-excluded' | sed -n '2s/^ *//p')"
eval "$remedy"
assert_eq "the remedy for both writes .orchestrator/ once" "$(exclude_count .orchestrator/)" "1"
assert_eq "the remedy for both writes .scratch/ once" "$(exclude_count .scratch/)" "1"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "running the remedy clears the warning" \
  "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"

printf '%s\n' ".orchestrator/" >.git/info/exclude
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a missing .scratch/ line alone warns without blocking" "$st" 0
assert_contains "and counts as one warn" "$(printf '%s\n' "$out" | tail -1)" "1 warn, 0 FAIL"
assert_contains "the warning names .scratch/ alone" "$out" "warn  .scratch/ not git-excluded"
remedy="$(printf '%s\n' "$out" | grep -A1 'not git-excluded' | sed -n '2s/^ *//p')"
assert_contains "the remedy names .scratch/" "$remedy" ".scratch/"
assert_not_contains "the remedy leaves .orchestrator/ alone" "$remedy" ".orchestrator/"
eval "$remedy"
assert_eq "the remedy appends .scratch/" "$(exclude_count .scratch/)" "1"
assert_eq "without repeating .orchestrator/" "$(exclude_count .orchestrator/)" "1"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "and clears the warning" "$(printf '%s\n' "$out" | tail -1)" "0 warn, 0 FAIL"
: >.git/info/exclude

# The exclude line is still truncated from the check above, so this one does
# need a real reset before layering CLAUDE_PLUGIN_ROOT's own warning on top.
healthy_repo
doctor_github
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "running orch.sh by hand is not a broken install" "$st" 0
assert_contains "warns about the unset plugin root" "$out" "CLAUDE_PLUGIN_ROOT"
restore_suite_env

# --- doctor: host (#128) ---
# Reduced enforcement has to be visible: doctor says which host it believes it
# is under and what that host cannot do, in the words of the capabilities
# reference - so the two cannot tell a user different stories.
healthy_repo
doctor_github
out="$(env -u CLAUDE_PLUGIN_ROOT CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "detects Claude Code from CLAUDECODE" "$out" "host: Claude Code"
assert_eq "Claude Code lacks no capability" "$(printf '%s\n' "$out" | grep -c 'lacks')" "0"
assert_contains "the plugin root check still warns when Claude Code left it unset" \
  "$out" "warn  CLAUDE_PLUGIN_ROOT"

out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "Junie's missing capabilities warn, never fail" "$st" 0
assert_contains "detects Junie CLI from JUNIE_EXTENSION_ROOT" "$out" "host: Junie CLI"
# The edit guard does not arm on Junie (ADR-0025): planning there is a nudge,
# backstopped at flow start, so the row is a Fallback - a gap, not Unverified.
assert_contains "names the edit guard as lacking on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Arm the edit guard"
assert_eq "does not call the edit guard unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*' | grep -c 'Arm the edit guard')" "0"
# Junie's UserPromptSubmit hook now delivers the planning message (#202).
assert_eq "does not claim Junie lacks planning-time context" \
  "$(printf '%s\n' "$out" | grep -c 'Inject context at planning time')" "0"
# Junie CLI loads the plugin's agents/ (#200), but its capability filter hides
# them, so a native start usually fails: the cell is a Fallback, not
# Unverified (#203).
assert_contains "names the fresh subagent Junie cannot use" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Start a fresh subagent"
assert_eq "does not call the fresh subagent unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*' | grep -c 'Start a fresh subagent')" "0"
assert_contains "names the forked subagent Junie cannot start" "$out" "Start a forked subagent"
# Junie cannot start a background subagent, so it builds the frontier one
# ticket at a time (ADR-0036): a gap, not Unverified.
assert_contains "names the background subagent Junie cannot start" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Start a background subagent"
# Junie's grep_search has no files-only mode and no caller-set cap (#1342): a
# known gap with a fallback, not Unverified.
assert_contains "names the code search Junie cannot do as asked" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*')" "Search and read code"
assert_eq "does not call the code search unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*' | grep -c 'Search and read code')" "0"
# A human on Junie still starts a skill with /<name>; only the model lacks it.
assert_contains "names only mid-step skill invocation as missing" "$out" "Invoke a skill from a step"
assert_contains "points at the reference for the fallbacks" "$out" "docs/host-capabilities.md"
assert_eq "does not list what Junie can do" \
  "$(printf '%s\n' "$out" | grep -c 'Ask a multiple-choice question')" "0"
# An unconfirmed cell is not a known gap: doctor must not state it as one.
assert_contains "names what is unverified on Junie" \
  "$(printf '%s\n' "$out" | grep -o 'unverified: .*')" "Run a plugin command"
assert_eq "does not claim Junie lacks what is only unverified" \
  "$(printf '%s\n' "$out" | grep -o 'lacks: [^;]*' | grep -c 'Run a plugin command')" "0"
assert_contains "an unset plugin root is expected on Junie, not a warning" \
  "$out" "ok    CLAUDE_PLUGIN_ROOT"

# Junie CLI's agent shell has no JUNIE_EXTENSION_ROOT; JUNIE_SHIM_PATH is what
# it exports there (orch-bench run j1).
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_SHIM_PATH="$PWD" "$ORCH" doctor --env 2>&1)"
assert_contains "detects Junie CLI from JUNIE_SHIM_PATH" "$out" "host: Junie CLI"
# A Junie started from inside a Claude Code terminal inherits CLAUDECODE.
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_SHIM_PATH="$PWD" CLAUDECODE=1 "$ORCH" doctor --env 2>&1)"
assert_contains "JUNIE_SHIM_PATH outranks CLAUDECODE" "$out" "host: Junie CLI"

out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --env 2>&1)"
assert_contains "ORCHESTRATOR_HOST outranks the Claude signals" "$out" "host: Junie"
out="$(ORCHESTRATOR_HOST=vim "$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "names an ORCHESTRATOR_HOST it does not know" "$out" "ORCHESTRATOR_HOST=vim"

out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "no detectable host is not a broken install" "$st" 0
assert_contains "says the host was not detected" "$out" "host not detected"
assert_contains "and how to name it" "$out" "export ORCHESTRATOR_HOST="

# A skills-only install copies the skills without scripts/, so the relative
# path every skill resolves orch.sh by leads nowhere. doctor runs from an
# orch.sh, so what it can see is such a copy sitting in a user skill store.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "reports the orch.sh it runs from" "$out" \
  "ok    orch.sh: ${PLUGIN_ROOT/#$HOME/\~}/scripts/orch.sh"
h="$HOME"
mkdir -p "$h/.agents/skills/orch-flow"
touch "$h/.agents/skills/orch-flow/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "reports a skills-only copy with no orch.sh" "$out" "orch.sh missing"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names the skills CLI copy" "$out" "~/.agents/skills: orch-flow"
# The fix names only the detected host's install.
assert_contains "names the full-plugin install for Claude Code" "$out" "/plugin install orchestrator@orchestrator"
assert_eq "and not Junie's, under Claude Code" \
  "$(printf '%s\n' "$out" | grep -c 'as a Junie extension')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT JUNIE_EXTENSION_ROOT="$PWD" "$ORCH" doctor --env 2>&1)"
assert_contains "names the full-plugin install for Junie" "$out" "maj0rpain/orchestrator as a Junie extension"
assert_contains "and marks it unverified" "$out" "as a Junie extension (unverified)"
assert_eq "and not Claude Code's, under Junie" \
  "$(printf '%s\n' "$out" | grep -c '/plugin install orchestrator@orchestrator')" "0"
out="$(env -u CLAUDE_PLUGIN_ROOT "$ORCH" doctor --env 2>&1)"
assert_contains "names every host's install when none is detected" "$out" "/plugin install orchestrator@orchestrator"
assert_contains "including Junie's" "$out" "maj0rpain/orchestrator as a Junie extension"
# ~/.junie/skills is not a verified Junie location (#121: verified facts only).
rm -rf "$h/.agents/skills/orch-flow"
mkdir -p "$h/.junie/skills/orch-review"
touch "$h/.junie/skills/orch-review/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "does not scan the unverified ~/.junie/skills" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "0"
rm -rf "$h/.junie/skills/orch-review"

# ~/.claude/skills is Claude Code's user-level store: a stray copy there shows
# up beside the plugin's own orchestrator:orch-flow as a plain orch-flow.
mkdir -p "$h/.claude/skills/orch-flow"
touch "$h/.claude/skills/orch-flow/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names a stray copy in Claude Code's user skill store" "$out" "~/.claude/skills: orch-flow"
# Stray copies in both stores: one warning per store, one remedy.
mkdir -p "$h/.agents/skills/orch-review"
touch "$h/.agents/skills/orch-review/SKILL.md"
out="$("$ORCH" doctor --env 2>&1)"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "names the skills CLI store's copy too" "$out" "~/.agents/skills: orch-review"
assert_eq "warns once per store that holds a copy" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "2"
assert_eq "and gives the remedy once" \
  "$(printf '%s\n' "$out" | grep -c '/plugin install orchestrator@orchestrator')" "1"
rm -rf "$h/.claude/skills/orch-flow"
# The skills CLI installs into ~/.agents/skills and links Claude Code's store
# to it: ~/.claude/skills/<skill> -> ../../.agents/skills/<skill>. One copy,
# one report.
ln -s ../../.agents/skills/orch-review "$h/.claude/skills/orch-review"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "reports a copy reached by a link only once" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "1"
# shellcheck disable=SC2088 # the literal ~ path doctor prints, not a path to expand
assert_contains "under the store that holds it" "$out" "~/.agents/skills: orch-review"
rm -f "$h/.claude/skills/orch-review"
rm -rf "$h/.agents/skills/orch-review"
# A link into a full checkout has orch.sh beside the real folder.
full="$(mktemp -d)"
mkdir -p "$full/skills/orch-flow" "$full/scripts"
touch "$full/skills/orch-flow/SKILL.md" "$full/scripts/orch.sh"
ln -s "$full/skills/orch-flow" "$h/.claude/skills/orch-flow"
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "does not report a link into a full checkout" \
  "$(printf '%s\n' "$out" | grep -c 'orch.sh missing')" "0"
assert_contains "and says orch.sh is fine" "$out" "ok    orch.sh:"
rm -f "$h/.claude/skills/orch-flow"; rm -rf "$full"
# ~/.claude/skills exists but holds no orch-* skill: ok, as before.
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "an existing store with no copies is ok" "$out" "ok    orch.sh:"

# env -u above was scoped to that one command too, so this is still the same
# fully-healthy repo - exactly the state this last check needs to prove out.
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
restore_suite_env

# --- doctor --flow ----------------------------------------------------------
# An empty answer must never read as a healthy one: --flow is asked explicitly
# about a flow, so no flow is a failure there and a plain statement everywhere
# else.
healthy_repo
doctor_github

# assert_leftover_reported <label> <top> <status> <output>: a doctor run that
# exited <status> printing <output> failed on ticket worktree 12, the leftover
# each caller adds under checkout <top>, naming it and its remedy.
assert_leftover_reported() {
  assert_status "$1 fails on a leftover" "$3" 1
  assert_contains "$1 names the leftover" "$4" \
    "FAIL  ticket worktree $2/.orchestrator/worktrees/t12 is left over"
  assert_contains "$1 gives its remedy" "$4" "orch.sh ticket-worktree remove 12"
}
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow refuses to answer when there is no flow" "$st" 1
assert_contains "says why it cannot answer" "$out" "no active flow"

out="$("$ORCH" doctor 2>&1)"; st=$?
assert_status "bare doctor is safe to run with no flow" "$st" 0
assert_contains "states there is no flow instead of failing" "$out" "ok    no active flow"
assert_contains "bare doctor covers the environment too" "$out" "tools"
assert_not_contains "with no ticket worktree, bare doctor with no flow says nothing of them" \
  "$out" "ticket worktree"

# #673: a quick implementation has no flow, so its leftover ticket worktree is
# reported by bare doctor or nowhere - and only this checkout's own.
nf_top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 12 >/dev/null
nf_linked="$(mktemp -d)/linked"
git worktree add -q -b nf-other "$nf_linked"
(cd "$nf_linked" && "$ORCH" ticket-worktree add 13 >/dev/null)
out="$("$ORCH" doctor 2>&1)"; st=$?
assert_leftover_reported "bare doctor with no flow" "$nf_top" "$st" "$out"
assert_contains "still states there is no flow" "$out" "ok    no active flow"
assert_not_contains "another checkout's ticket worktree is not reported with no flow" "$out" \
  "$nf_linked/.orchestrator/worktrees/t13"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "--flow still refuses with no flow and a leftover" "$st" 1
assert_contains "still says why it cannot answer" "$out" "no active flow"
assert_not_contains "and runs no ticket-worktree check" "$out" "ticket worktree"
(cd "$nf_linked" && "$ORCH" ticket-worktree remove 13)
git worktree remove "$nf_linked"
git branch -q -D nf-other
"$ORCH" ticket-worktree remove 12

"$ORCH" init flowtest >/dev/null
complete_handoff "$("$ORCH" handoff path spec)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a fresh flow is healthy" "$st" 0
assert_contains "reports the phase" "$out" "phase: spec"
# The spec-paused marker (#1181) and the round marker (#1346) are no
# handoffs: doctor's verdict ignores them.
healthy_out="$out"
writeln 7 >"$(dirname "$("$ORCH" handoff path spec)")/spec-paused"
writeln '7 1 2' >"$(dirname "$("$ORCH" handoff path spec)")/spec-round"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a handoff folder holding spec-paused and spec-round leaves the flow healthy" "$st" 0
assert_eq "with the same report" "$out" "$healthy_out"
rm -f "$(dirname "$("$ORCH" handoff path spec)")/spec-paused" "$(dirname "$("$ORCH" handoff path spec)")/spec-round"
# "published" names only one of the two paths an issue can arrive by
# (orch-to-spec publishing vs. adoption at init, docs/adr/0005) - neutral
# wording here must not imply the other path doesn't exist.
assert_contains "reports no issue recorded yet without implying publication is the only path" \
  "$out" "issue: not recorded yet"
assert_eq "--flow leaves the environment alone" \
  "$(printf '%s\n' "$out" | grep -c '^tools$')" "0"
assert_eq "stays quiet about an upstream before the implement phase" \
  "$(printf '%s\n' "$out" | grep -c 'upstream')" "0"

# /orchestrator:next and /orchestrator:flow-status both run this scope every
# time, and a flow with no PR recorded has nothing to ask GitHub about.
# GitHub unreachable shows it: one question would put a skip line in the report.
fake_offline
out="$("$ORCH" doctor --flow 2>&1)"
assert_not_contains "a flow with no PR asks GitHub nothing" "$out" "skipped"
fake_online

# One unparseable file is one problem. Four checks each reading it again would
# print jq's parse error mid-report and then four ok lines that are not true.
# The invalid JSON is written raw: no writer can produce it.
statebak="$(mktemp)"
cp .orchestrator/state.json "$statebak"
printf '%s' '{not json' >.orchestrator/state.json
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when state.json does not parse" "$st" 1
assert_contains "names the file that will not parse" "$out" \
  "FAIL  .orchestrator/state.json is not a JSON object."
assert_contains "with the abort remedy under it" \
  "$(printf '%s\n' "$out" | grep -A1 '^FAIL  .orchestrator/state.json' | tail -n 1)" "abort"
assert_eq "reports it once rather than once per check" \
  "$(printf '%s\n' "$out" | grep -c '^FAIL')" "1"
assert_eq "claims nothing it could not read" \
  "$(printf '%s\n' "$out" | grep -c '^ok    ')" "0"
assert_eq "does not leak jq's parse error into the report" \
  "$(printf '%s\n' "$out" | grep -c 'parse error')" "0"
assert_not_contains "with no ticket worktree, an invalid state.json says nothing of them" \
  "$out" "ticket worktree"
# #673: a broken state file must not hide a leftover ticket worktree - that
# check reads git alone.
iv_top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 12 >/dev/null
for iv_args in "" "--flow"; do
  out="$("$ORCH" doctor $iv_args 2>&1)"; st=$?
  assert_leftover_reported "doctor $iv_args with an invalid state.json" "$iv_top" "$st" "$out"
done
"$ORCH" ticket-worktree remove 12
# Valid JSON that is not an object is as unreadable to the hooks as a file
# that does not parse, so doctor answers it the same way: one FAIL, and no
# flow check erroring partway through on it.
printf '%s' '[1]' >.orchestrator/state.json
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when state.json is valid JSON but not an object" "$st" 1
assert_eq "with the one FAIL and its abort remedy, and nothing else from the flow checks" \
  "$(printf '%s\n' "$out" | sed -n '/^flow state/,$p' | grep -v -e '^$' -e ' warn, ' | sed 's/^      .*abort.*/REMEDY/')" \
  "$(printf '%s\n' 'flow state' 'FAIL  .orchestrator/state.json is not a JSON object.' REMEDY)"
cp "$statebak" .orchestrator/state.json

state_fixture phase nonsense
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "rejects an unknown phase" "$st" 1
assert_contains "names the phase it does not know" "$out" "nonsense"
state_fixture phase "spec implement"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "rejects a phase made of two adjacent phases" "$st" 1
assert_contains "and reports it as an unknown phase" "$out" "unknown phase: spec implement"
state_fixture phase spec

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded branch is gone" "$st" 1
assert_contains "names the missing branch" "$out" "orch/9-gone"

git checkout -q -b orch/9-gone
state_fixture phase implement
complete_handoff "$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unpushed branch warns rather than blocking the implement phase" "$st" 0
assert_contains "gives the command that pushes it" "$out" "git push -u origin orch/9-gone"

# branch create forks off origin/<default>, so an unpushed branch already has an
# upstream - just not its own. Accepting any upstream would call a branch nobody
# else can see pushed.
git update-ref refs/remotes/origin/main HEAD
git branch -q --set-upstream-to=origin/main orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_contains "an upstream pointing at the base branch is still unpushed" \
  "$out" "not on origin yet"

# A handoff with a bare required heading is the failure the next phase would
# experience as running blind, so it has to surface as a FAIL here.
writeln '## Spec issue' '' \
  >"$("$ORCH" handoff path implement)"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when a completed phase's handoff has an empty section" "$st" 1
assert_contains "names the handoff" "$out" "02-spec.md"
assert_contains "reports it as empty, not missing" "$out" "empty section"
complete_handoff "$("$ORCH" handoff path implement)"

# check_flow_issue runs unconditionally on state.issue, whichever path put it
# there - adopted at init or published by orch-to-spec - and mirrors
# check_flow_pr's open/closed/unreadable shape.
"$ORCH" state set issue 11
fake_issue 11 open ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an open issue is healthy" "$st" 0
assert_contains "reports the open issue" "$out" "issue #11 open"

fake_issue 11 closed ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded issue has been closed" "$st" 1
assert_contains "names the closed issue" "$out" "issue #11 is closed"
assert_contains "gives the command that reopens it" "$out" "gh issue reopen 11"

fake_fail adapter_issue_state_labels "$GH_502"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the issue cannot be read from GitHub" "$st" 1
assert_contains "names the unreadable issue, with gh's first line" "$out" \
  "FAIL  issue #11 could not be read from GitHub: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
assert_contains "gives the command that re-checks it" "$out" "gh issue view 11"
fake_unfail
fake_fail_times adapter_issue_state_labels 5
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an issue read failing silently says gh gave no reason" "$out" \
  "FAIL  issue #11 could not be read from GitHub: gh gave no reason"

# The ready-for-agent label is a one-time gate at adoption, not an ongoing flow
# invariant (docs/adr/0005) - a maintainer's later triage housekeeping must not
# stop a flow already running against the issue.
fake_unfail
fake_issue 11 open needs-triage
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an issue whose label was removed after adoption is still healthy" "$st" 0
assert_contains "still reports it open" "$out" "issue #11 open"

# issue #13: pr open always writes `Closes #<issue>`, so a merged flow's issue
# is closed as a matter of course - a done flow reporting that as broken was
# doctor misreporting every successfully-finished flow.
complete_handoff "$("$ORCH" handoff path review)"
state_fixture phase "done"
fake_issue 11 closed
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a closed issue is healthy once the flow is done" "$st" 0
assert_contains "reports it closed instead of failing" "$out" "issue #11 closed"

# issue #415: a merged flow stays in done until the next init archives it
# (ADR-0009), and deleting its branch after the merge is routine. Neither the
# local nor the origin branch being gone is a problem then, and a push remedy
# would recreate a branch somebody just deleted on purpose.
assert_done_branch_gone_ok() {
  local label="$1" out="$2"
  assert_contains "$label: branch reports ok" "$out" "ok    branch: "
  assert_contains "$label: upstream reports ok" "$out" "ok    upstream: "
  assert_not_contains "$label: no missing-branch FAIL" "$out" "no longer exists"
  assert_not_contains "$label: no unpushed warning" "$out" "not on origin yet"
  assert_not_contains "$label: no push remedy" "$out" "git push -u origin"
}
state_fixture branch orch/9-merged
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, branch gone locally and on origin" "$out"
assert_contains "names the branch as gone after merge" "$out" \
  "branch: orch/9-merged gone - expected after merge"
assert_contains "names no upstream as expected after merge" "$out" \
  "upstream: none - expected after merge"

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, local branch kept but origin branch gone" "$out"

git update-ref refs/remotes/origin/orch/9-merged HEAD
state_fixture branch orch/9-merged
out="$("$ORCH" doctor --flow 2>&1)"
assert_done_branch_gone_ok "done, local branch gone but origin branch kept" "$out"

# Outside done, the same states are still what they were: a review flow with
# its branch gone has nothing to build on, and an unpushed one still needs it.
fake_issue 11 open
state_fixture phase review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review flow with its branch gone still fails" "$st" 1
assert_contains "still says it no longer exists" "$out" "orch/9-merged no longer exists"
assert_contains "still gives the abort remedy" "$out" "/orchestrator:abort"
git update-ref -d refs/remotes/origin/orch/9-merged

state_fixture branch orch/9-gone
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an unpushed review flow still warns" "$out" "not on origin yet"
assert_contains "and still gives the push remedy" "$out" "git push -u origin orch/9-gone"
state_fixture phase implement

state_fixture pr 7
fake_pr 7 closed orch/9-gone main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the recorded PR has been closed" "$st" 1
assert_contains "names the closed PR" "$out" "#7"
fake_pr 7 merged orch/9-gone main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR is not a failure" "$st" 0
fake_fail adapter_pr_state_draft "$GH_502"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "fails when the PR cannot be read from GitHub" "$st" 1
assert_contains "names the unreadable PR, with gh's first line" "$out" \
  "FAIL  PR #7 could not be read from GitHub: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
fake_unfail
fake_fail_times adapter_pr_state_draft 5
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "a PR read failing silently says gh gave no reason" "$out" \
  "FAIL  PR #7 could not be read from GitHub: gh gave no reason"
fake_unfail

fake_offline
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable GitHub does not fail the flow scope" "$st" 0
assert_contains "skips the PR check with its cause" "$out" "skipped: GitHub is not reachable"
fake_online

# #622: a ticket worktree left over by an interrupted run is a FAIL naming it,
# with ticket-worktree remove as the remedy - but only this checkout's own.
tw_top="$(git rev-parse --show-toplevel)"
out="$("$ORCH" doctor --flow 2>&1)"
assert_not_contains "with no ticket worktree, doctor --flow says nothing of them" "$out" "ticket worktree"
"$ORCH" ticket-worktree add 12 >/dev/null
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a leftover ticket worktree fails doctor --flow" "$st" 1
assert_contains "reports it as a FAIL naming it" "$out" \
  "FAIL  ticket worktree $tw_top/.orchestrator/worktrees/t12 is left over"
assert_contains "with ticket-worktree remove <n> as the remedy" "$out" "orch.sh ticket-worktree remove 12"
"$ORCH" ticket-worktree remove 12
tw_linked="$(mktemp -d)/linked"
git worktree add -q -b orch/9-other "$tw_linked"
(cd "$tw_linked" && "$ORCH" ticket-worktree add 13 >/dev/null)
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "another checkout's ticket worktree does not fail doctor --flow" "$st" 0
assert_not_contains "nor is it reported" "$out" "$tw_linked/.orchestrator/worktrees/t13"
(cd "$tw_linked" && "$ORCH" ticket-worktree remove 13)
git worktree remove "$tw_linked"
git branch -q -D orch/9-other

# #721: every phase commits its own work before ending, so a change outside the
# planning allowlist at a phase boundary is a bug in the phase that left it -
# caught by doctor --flow, at the top of every /orchestrator:next.
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a clean tree passes doctor --flow" "$st" 0
assert_not_contains "a clean tree reports nothing about the working tree" "$out" "planning allowlist"
mkdir -p lib
printf 'x\n' >lib/left-behind.sh
printf 'x\n' >stray.txt
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "changes outside the planning allowlist fail doctor --flow" "$st" 1
assert_contains "the FAIL lists the paths outside the allowlist" "$out" \
  "FAIL  the working tree has changes outside the planning allowlist: lib/left-behind.sh, stray.txt"
rm -rf lib stray.txt
mkdir -p docs/agents .scratch
printf 'x\n' >docs/agents/notes.md
printf 'x\n' >.scratch/plan.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "changes inside the planning allowlist pass doctor --flow" "$st" 0
assert_not_contains "and are not reported" "$out" "planning allowlist"
rm -rf docs/agents/notes.md .scratch
# A git status that cannot run is a FAIL naming git's error, never the end of
# the report: doctor is what you run when the world is already broken.
break_index
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
restore_index
assert_status "a failing git status fails doctor --flow" "$st" 1
assert_contains "the FAIL names git's error" "$out" \
  "FAIL  git status failed - cannot check the working tree: "
assert_contains "and quotes it" "$out" "index file"
assert_contains "the rest of doctor still runs" "$out" "phase: implement"
assert_contains "and reaches its summary" "$(printf '%s\n' "$out" | tail -1)" " FAIL"

# --flow never runs the tools group, so if it skipped every check it has and
# still exited 0, /orchestrator:next would advance a flow nothing had checked.
if on_windows_bash; then
  skip_no_jq "--flow without jq fails rather than reporting a clean bill"
  skip_no_jq "names jq as the reason it cannot answer"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor --flow 2>&1)"; st=$?
  assert_status "--flow without jq fails rather than reporting a clean bill" "$st" 1
  assert_contains "names jq as the reason it cannot answer" "$out" "jq not found"
fi

if on_windows_bash; then
  skip_no_jq "bare doctor without jq fails on the tools check"
  skip_no_jq "collapses every flow check into one line when jq is gone"
else
  out="$(PATH="$nojq_path" "$ORCH" doctor 2>&1)"; st=$?
  assert_status "bare doctor without jq fails on the tools check" "$st" 1
  # The count comes from the registry, so a check appended to it is covered by
  # the gate without anyone remembering to add a preamble - and this number
  # moving is how you find out that happened.
  assert_contains "collapses every flow check into one line when jq is gone" \
    "$out" "11 flow checks skipped: jq is not installed"
  assert_not_contains "with no ticket worktree, doctor without jq says nothing of them" \
    "$out" "ticket worktree"
fi

# #673: the ticket-worktree check reads git alone, so a missing jq must not hide
# a leftover - under --flow or bare doctor.
if on_windows_bash; then
  skip_no_jq "doctor without jq still fails on a leftover ticket worktree"
else
  nj_top="$(git rev-parse --show-toplevel)"
  "$ORCH" ticket-worktree add 12 >/dev/null
  for nj_args in "" "--flow"; do
    out="$(PATH="$nojq_path" "$ORCH" doctor $nj_args 2>&1)"; st=$?
    assert_leftover_reported "doctor $nj_args without jq" "$nj_top" "$st" "$out"
  done
  "$ORCH" ticket-worktree remove 12
fi
restore_suite_env

# --- doctor --env: finished side checkouts (#727) -----------------------------
# A finished side checkout left standing is a leftover, so doctor --env warns
# on each one - never a FAIL - with the exact remove command, and says nothing
# for one still in use. The finished test is the sweep's own; GitHub
# unreachable skips the check into the GitHub skipped warn.
echo
echo "doctor --env finished side checkouts"
sc_clone
doctor_github
mkdir -p docs/agents
labels_doc docs/agents/triage-labels.md
gh_fixture
export CLAUDE_PLUGIN_ROOT="$PWD"
HOME="$(mktemp -d)"; export HOME
fake_offline
dfin="$(sc_add dfin)"
git -C "$dfin" checkout -q -b quick/20-dfin
git -C "$dfin" commit -q --allow-empty -m "work on dfin"
fake_pr 60 merged quick/20-dfin main
dopen="$(sc_add dopen)"
git -C "$dopen" checkout -q -b quick/21-dopen
git -C "$dopen" commit -q --allow-empty -m "work on dopen"
fake_pr 61 open quick/21-dopen main
dflow="$(sc_add dflow)"
(cd "$dflow" && orch_gh_failing init dflow-flow >/dev/null \
  && git checkout -q -b orch/dflow-flow \
  && state_fixture phase "done" && state_fixture branch orch/dflow-flow && state_fixture pr 62)
fake_pr 62 merged orch/dflow-flow main
dnd="$(sc_add dnd)"
(cd "$dnd" && orch_gh_failing init dnd-flow >/dev/null && state_fixture phase implement)
fake_online
git remote set-url origin https://github.com/acme/widgets.git

out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env passes with finished side checkouts standing" "$st" 0
assert_contains "warns on a finished quick side checkout" "$out" "warn  side checkout dfin is finished"
assert_contains "naming the exact remove command" "$out" \
  "$(printf '\n      orch.sh side-checkout remove dfin')"
assert_contains "warns on a finished flow side checkout" "$out" "warn  side checkout dflow is finished"
assert_contains "naming its remove command" "$out" "orch.sh side-checkout remove dflow"
assert_not_contains "says nothing for an open PR's side checkout" "$out" "side checkout dopen"
assert_not_contains "says nothing for a flow not at done" "$out" "side checkout dnd"
assert_contains "and prints no FAIL" "$(printf '%s\n' "$out" | tail -1)" " 0 FAIL"
out_in="$(cd "$dopen" && "$ORCH" doctor --env 2>&1)"
assert_contains "warns the same from inside a side checkout" "$out_in" "orch.sh side-checkout remove dfin"
out="$(PATH="$(nowalk_bin):$PATH" "$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env fails when the checkouts cannot be read (#1333)" "$st" 1
assert_contains "reporting it as a FAIL" "$out" "FAIL  could not read the checkouts"

fake_offline
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env passes when GitHub is unreachable" "$st" 0
assert_not_contains "printing no FAIL line" "$out" "FAIL  "
assert_contains "and a FAIL count of zero" "$(printf '%s\n' "$out" | tail -1)" " 0 FAIL"
assert_not_contains "and no finished warning it could not check" "$out" "is finished"
assert_contains "counting the check in the GitHub skipped warn" "$out" "GitHub checks skipped: GitHub is not reachable"
skip_n() { printf '%s\n' "$1" | sed -n 's/^warn  \([0-9]*\) GitHub checks\{0,1\} skipped.*/\1/p'; }
with_n="$(skip_n "$out")"
for p in "$dfin" "$dopen" "$dflow" "$dnd"; do git worktree remove --force "$p"; done
without_n="$(skip_n "$("$ORCH" doctor --env 2>&1)")"
assert_eq "as one more skipped check than with no side checkouts" "$with_n" "$((without_n + 1))"
fake_online
restore_suite_env

# --- doctor at the review phase ---------------------------------------------
# Three handoffs are due from review onwards, and only three: a flow started
# under the old loop machinery carries a `loop` key doctor neither reports nor
# touches, and is asked for no handoff a loop would have written.
echo
echo "doctor at the review phase"
review_flow reviewdoctor
doctor_github
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review-phase flow with its three handoffs is healthy" "$st" 0
assert_contains "counts the implement handoff among them" "$out" "handoff 03-implement.md complete"

state_fixture loop 2
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray loop key from an older flow still passes" "$st" 0
assert_eq "and earns no mention of a handoff no loop writes any more" \
  "$(printf '%s\n' "$out" | grep -c '04-review.md')" "0"
assert_eq "nor a line reporting the key" \
  "$(printf '%s\n' "$out" | grep -c 'loop: 2')" "0"
assert_eq "and the key is left as it was" "$("$ORCH" state get | jq -r .loop)" "2"

# The per-loop record directories an older flow left behind are the other
# artefact story 37 names: ignored, not moved, and never a reason to fail.
mkdir -p .orchestrator/review/loop-01
: > .orchestrator/review/loop-01/iteration-01.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stray review/loop-NN/ directory from an older flow still passes" "$st" 0
assert_eq "and earns no line of its own" \
  "$(printf '%s\n' "$out" | grep -c 'loop-01')" "0"
assert_eq "and is left where it was" \
  "$(on_disk .orchestrator/review/loop-01/iteration-01.md)" "present"
restore_suite_env

# --- doctor: upstream beside an ambiguous origin/<branch> (#1331) ------------
# A local branch named origin/<branch> makes the upstream's short name
# ambiguous, so git abbreviates it to remotes/origin/<branch>: a pushed,
# tracked branch must still read as on origin. The local branch is made only
# after the push, since made first it makes `git push -u` itself fail.
echo
echo "doctor: upstream beside an ambiguous origin/<branch>"
review_flow ambiguousupstream
doctor_github
amb_branch="$(git branch --show-current)"
state_fixture branch "$amb_branch"
bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
bare_origin "$bare"
git push -q -u origin "$amb_branch"
git branch -q "origin/$amb_branch"
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "a pushed branch beside a local origin/<branch> reports its upstream ok" \
  "$out" "ok    upstream: origin/$amb_branch"
assert_not_contains "with no unpushed warning" "$out" "not on origin yet"
assert_not_contains "and no push remedy" "$out" "git push -u origin"
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- doctor: review terminal check --------------------------------------
# check_flow_pr's open/closed/unreadable branching is the direct template:
# ok/warn on the classification, and phase-gated silent outside review.
echo
echo "doctor: review terminal check"
fresh_flow doctorterm
doctor_github
complete_handoff "$("$ORCH" handoff path spec)"
complete_handoff "$("$ORCH" handoff path implement)"
state_fixture phase implement
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "implement phase still passes" "$st" 0
assert_eq "and says nothing about a review loop" \
  "$(printf '%s\n' "$out" | grep -c 'review loop')" "0"

complete_handoff "$("$ORCH" handoff path review)"
state_fixture phase review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no loop yet is healthy" "$st" 0
assert_contains "reports the loop has not started" "$out" "review loop: not started yet"

state_fixture iteration 2
"$ORCH" state set budget 5
out="$(ORCHESTRATOR_HOST=junie "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget warns, never fails" "$st" 0
assert_contains "names the iteration and budget" "$out" "iteration 2 of budget 5"
assert_contains "reads as pending, not interrupted" "$out" "hasn't reached its budget yet"
assert_contains "points at next for resuming it" "$out" "/orchestrator:next (or orch-flow's Next phase section) will resume it"
assert_contains "and says redo refuses until it is terminal" "$out" "redo refuses until it reaches a terminal state"

mkdir -p .orchestrator/review
writeln '## Terminal state' 'stop - base sync failed.' >.orchestrator/review/iteration-02.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stop short of the budget is healthy" "$st" 0
assert_contains "named a terminal state, not proceeding normally" \
  "$out" "review loop at a terminal state: stop (base sync failed.)"
rm .orchestrator/review/iteration-02.md

state_fixture iteration 5
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "at budget with no terminal record warns rather than fails" "$st" 0
assert_contains "reads as interrupted, not pending" "$out" "looks interrupted, not stopped"

# A review directory that cannot be made fails, naming it (#1334).
rm -rf .orchestrator/review
: >.orchestrator/review
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a review directory that cannot be made fails" "$st" 1
assert_contains "with a FAIL line naming its path" "$out" \
  "FAIL  review loop's terminal state cannot be read: cannot create the review directory $(pwd -P)/.orchestrator/review"
rm -f .orchestrator/review

mkdir -p .orchestrator/review
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready record is healthy" "$st" 0
assert_contains "names it a terminal state" "$out" "review loop at a terminal state: ready"

writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a stop record is healthy too" "$st" 0
assert_contains "names the terminal state and its reason" \
  "$out" "review loop at a terminal state: stop (CI failed twice.)"

writeln '## Terminal state' '**stop**' 'CI failed twice.' >.orchestrator/review/iteration-05.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a malformed record fails, since next will not fix it" "$st" 1
assert_contains "with a FAIL line naming it malformed" "$out" "FAIL  review loop's last iteration (5) has a malformed terminal state"
assert_contains "printing the expected shape" "$out" "expected: first line"
assert_contains "and the rewrite remedy" "$out" "rewrite the first line of"
writeln '## Terminal state' 'stop' 'CI failed twice.' >.orchestrator/review/iteration-05.md

# Report files change nothing doctor says about the loop either.
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-standards.md
writeln '## Terminal state' 'ready' >.orchestrator/review/iteration-05-spec.md
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "report files beside a stop record stay healthy" "$st" 0
assert_contains "still reading the stop from the record" \
  "$out" "review loop at a terminal state: stop (CI failed twice.)"
mv .orchestrator/review/iteration-05.md .orchestrator/review/stop.saved
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "report files with no record warn rather than fail" "$st" 0
assert_contains "and read as interrupted" "$out" "looks interrupted, not stopped"
mv .orchestrator/review/stop.saved .orchestrator/review/iteration-05.md
rm .orchestrator/review/iteration-05-standards.md .orchestrator/review/iteration-05-spec.md
restore_suite_env

# --- doctor: review budget check -----------------------------------------
# review begin's own `die` at budget is what is meant to make an iteration
# past it unreachable - this check is for the state.json that got there some
# other way, not one review begin produced itself.
echo
echo "doctor: review budget check"
review_flow doctorbudget
doctor_github
"$ORCH" state set budget 5
state_fixture iteration 3
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "short of budget is healthy" "$st" 0
assert_contains "reports it within budget" "$out" "review loop iteration (3) within budget (5)"

state_fixture iteration 6
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "past budget fails" "$st" 1
assert_contains "names the impossible count" "$out" \
  "review loop iteration (6) is past its budget (5)"
assert_contains "and points at abort" "$out" "/orchestrator:abort"
state_fixture iteration 5
restore_suite_env

# --- doctor: review ci check ----------------------------------------------
# ci_probe is the loop's own read of the PR's checks, reused rather than a
# second query of the same endpoint - so its five answers are the five cases
# here, not a fresh classification doctor derives on its own.
echo
echo "doctor: review ci check"
review_flow doctorci
doctor_github
state_fixture pr 40
# A draft PR mid-review agrees with the phase, so the draft check stays quiet
# and only the CI check's own verdict decides the exit status below.
fake_pr 40 open orch/doctorci main
fake_pr_draft 40

fake_checks 40 required green
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "green required checks are healthy" "$st" 0
assert_contains "reports it" "$out" "CI: required checks green"

fake_checks 40 required none
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "no required checks reported is not a failure" "$st" 0
assert_contains "reports it" "$out" "CI: no required checks reported"
# review ci's none detail (issue #476) is added in review ci, not ci_probe,
# so doctor's own none line is unchanged and carries neither path's detail.
assert_eq "without review ci's none detail" \
  "$(printf '%s\n' "$out" | grep -c 'no CI signals\|grace ran out')" "0"

fake_checks 40 required pending
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "pending required checks are not a failure yet" "$st" 0
assert_contains "reports it" "$out" "CI: required checks still pending"

fake_checks 40 required failing
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a failing required check fails doctor" "$st" 1
assert_contains "names the PR" "$out" "CI: required check(s) failing on PR #40"
assert_contains "carries the failing check's name" "$out" "build"
assert_contains "gives the command that shows it" "$out" "gh pr checks 40"

fake_checks 40 required boom
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "an unreachable API warns rather than fails" "$st" 0
assert_contains "reports it, carrying the reason inline" "$out" \
  "warn  CI: could not be read from GitHub for PR #40: dial tcp: lookup api.github.com: no such host"
assert_eq "and the reason only once" "$(printf '%s\n' "$out" | grep -c 'dial tcp')" "1"

fake_fail adapter_pr_checks "$GH_502"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a failing checks read warns rather than fails" "$st" 0
assert_contains "carrying gh's first line inline" "$out" \
  "warn  CI: could not be read from GitHub for PR #40: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past it" "$out" "second line"
assert_eq "and gh's line only once" "$(printf '%s\n' "$out" | grep -c 'HTTP 502')" "1"
fake_unfail

fake_fail_times adapter_pr_checks 5
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a silently failing checks read warns rather than fails" "$st" 0
assert_contains "saying gh gave no reason" "$out" \
  "warn  CI: could not be read from GitHub for PR #40: gh gave no reason"
fake_unfail
restore_suite_env

# --- doctor: review draft check -------------------------------------------
# `review ready` marks the PR ready and records phase: done as one operation,
# so isDraft and phase disagreeing on GitHub's own PR is evidence that
# operation only half landed.
echo
echo "doctor: review draft check"
review_flow doctordraft
doctor_github
state_fixture pr 40
fake_pr 40 open orch/doctordraft main
fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR mid-review is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (review)"

fake_pr 40 open orch/doctordraft main
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a PR marked ready while still in review fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 was marked ready on GitHub but the flow phase is still review"
assert_contains "gives the command that inspects it" "$out" "gh pr view 40"

state_fixture phase "done"
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a ready PR once the flow is done is healthy" "$st" 0
assert_contains "reports it matches phase" "$out" \
  "PR #40 draft state matches phase (done)"

fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a draft PR left behind once the flow is done fails" "$st" 1
assert_contains "names the mismatch" "$out" \
  "PR #40 is still a draft but the flow phase is done"
assert_contains "gives the command that promotes it" "$out" "gh pr ready 40"

fake_pr 40 merged orch/doctordraft main
fake_pr_draft 40
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "a merged PR has nothing left to disagree with" "$st" 0
assert_eq "and says nothing about draft state" \
  "$(printf '%s\n' "$out" | grep -c 'draft state')" "0"
state_fixture phase review

fake_pr 40 open orch/doctordraft main
fake_fail adapter_pr_state_draft "$GH_502"
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an unreadable draft state warns with gh's first line" "$out" \
  "warn  PR #40 draft state could not be read from GitHub: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
fake_unfail
fake_fail_times adapter_pr_state_draft 5
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "a draft state read failing silently says gh gave no reason" "$out" \
  "warn  PR #40 draft state could not be read from GitHub: gh gave no reason"
fake_unfail
restore_suite_env

# --- doctor: phase-listed flow checks -----------------------------------------
# A FLOW_CHECKS entry may list the phases it applies to (`name:phase,phase`),
# and d_run_flow runs it only in those; an entry with no list runs in every
# phase, and an unknown phase matches no list. Each phase-listed check is set up
# here to have something to say, so its silence elsewhere is the filter's.
echo
echo "doctor: phase-listed flow checks"
review_flow doctorphases
doctor_github
state_fixture pr 40
fake_pr 40 open orch/doctorphases main
fake_pr_draft 40
fake_checks 40 required green
state_fixture branch "$(git branch --show-current)"
# phase_reports <phase>: the checks a doctor --flow run at <phase> reported,
# one name per line, among the five phase-listed checks and check_flow_pr.
phase_reports() {
  local out
  state_fixture phase "$1"
  out="$("$ORCH" doctor --flow 2>&1)"
  if printf '%s\n' "$out" | grep -qE 'upstream: |is not on origin yet'; then echo upstream; fi
  if printf '%s\n' "$out" | grep -qE "review loop: not started|review loop at a terminal|review loop hasn't|review loop's last"; then echo terminal; fi
  if printf '%s\n' "$out" | grep -qF 'review loop iteration ('; then echo budget; fi
  if printf '%s\n' "$out" | grep -qF 'CI: '; then echo ci; fi
  if printf '%s\n' "$out" | grep -qE 'draft state|still a draft'; then echo draft; fi
  if printf '%s\n' "$out" | grep -qF 'PR #40 open'; then echo pr; fi
}
assert_eq "at spec only the unlisted check reports" \
  "$(phase_reports spec | tr '\n' ' ')" "pr "
assert_eq "at implement the upstream check joins it" \
  "$(phase_reports implement | tr '\n' ' ')" "upstream pr "
assert_eq "at review every phase-listed check reports" \
  "$(phase_reports review | tr '\n' ' ')" "upstream terminal budget ci draft pr "
assert_eq "at done the upstream and draft checks report" \
  "$(phase_reports "done" | tr '\n' ' ')" "upstream draft pr "
assert_eq "at an invalid phase no phase-listed check reports" \
  "$(phase_reports bogus | tr '\n' ' ')" "pr "
restore_suite_env

# A `<phase>+` element stands for <phase> and every later phase in the table,
# on any element of an entry's list; any element, plain or `+`, naming a phase
# the table does not hold dies naming its entry, so a typo can never quietly
# disable a check.
registry='a:implement+ b:review,spec+ c'
assert_eq "at spec a + entry from a later phase is filtered out" \
  "$(sourced_orch d_entries_at "$registry" spec)" "b c "
assert_eq "at implement a + entry from implement applies" \
  "$(sourced_orch d_entries_at "$registry" implement)" "a b c "
assert_eq "at done every + entry applies" \
  "$(sourced_orch d_entries_at "$registry" "done")" "a b c "
out="$(sourced_orch d_entries_at 'a:implemnt+' implement 2>&1)"; st=$?
assert_status "a + element naming an unknown phase dies" "$st" 1
assert_contains "naming the entry" "$out" "orch: a:implemnt+"
out="$(sourced_orch d_entries_at 'a:reveiw' review 2>&1)"; st=$?
assert_status "a plain element naming an unknown phase dies too" "$st" 1
assert_contains "naming its entry" "$out" "orch: a:reveiw"

# --- doctor: base branch check -----------------------------------------------
# A set base branch that has vanished from origin is the one stale setting that
# would send the next flow's fork and PR at nothing, so it FAILs; origin being
# unreachable only means doctor could not tell, so it warns.
echo
echo "doctor: base branch check"
healthy_repo
doctor_github
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a default base branch passes" "$st" 0
assert_contains "reports the default branch as the base branch" "$out" "ok    base branch: main (default)"
assert_contains "keeps the default-branch check" "$out" "ok    default branch: main (from GitHub)"

bare="$(mktemp -d)/origin.git"
git init -q --bare "$bare"
git push -q "$bare" HEAD:refs/heads/main HEAD:refs/heads/uat
bare_origin "$bare"
git config orchestrator.base uat
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch origin has passes" "$st" 0
assert_contains "reports the set base branch" "$out" "ok    base branch: uat (set)"

git config orchestrator.base gone
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a set base branch missing from origin fails" "$st" 1
assert_contains "names the missing base branch" "$out" "FAIL  base branch gone"
assert_contains "gives the way out" "$out" "base clear"

git remote set-url origin "$(dirname "$bare")/unreachable.git"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unverifiable base branch does not block the flow" "$st" 0
assert_contains "warns that origin could not be reached" "$out" "warn  base branch gone"
git config --unset orchestrator.base
rm -rf "$(dirname "$bare")"
restore_suite_env

# --- doctor: agent settings check (#1358) -------------------------------------
# Doctor lists every role's agent setting, model and effort each with its
# source, as ok lines; a disallowed hand-set value, local or global, is a FAIL
# naming the key, its value and the allowed values, with the clear at the bad
# value's own scope as its remedy - so it is fixed before a skill stops on it.
echo
echo "doctor: agent settings check"
healthy_repo
doctor_github
git config --global orchestrator.model.reviewer haiku
git config --local orchestrator.effort.implementer high
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "doctor --env passes with valid agent settings" "$st" 0
assert_contains "doctor --env lists a role's local effort and inherited model" "$out" \
  "ok    agent implementer: model inherit (inherit), effort high (local)"
assert_contains "doctor --env lists a role's global model" "$out" \
  "ok    agent reviewer: model haiku (global), effort inherit (inherit)"
assert_contains "doctor --env lists every role, the last among them" "$out" \
  "ok    agent resolver: model inherit (inherit), effort inherit (inherit)"

git config --local orchestrator.model.fixer gpt
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a local disallowed model fails doctor" "$st" 1
assert_contains "naming the key, its value and the allowed models" "$out" \
  "FAIL  orchestrator.model.fixer is gpt (local) - not an allowed model (want sonnet|opus|haiku|fable|inherit)"
assert_contains "with the local clear as its remedy" "$out" \
  "$(printf '\n      orch.sh agent clear fixer --model\n')"
git config --local --unset orchestrator.model.fixer

git config --global orchestrator.effort.closer huge
out="$("$ORCH" doctor 2>&1)"; st=$?
assert_status "a global disallowed effort fails bare doctor" "$st" 1
assert_contains "naming the key, its value and the allowed efforts" "$out" \
  "FAIL  orchestrator.effort.closer is huge (global) - not an allowed effort (want low|medium|high|xhigh|max|inherit)"
assert_contains "with the global clear as its remedy" "$out" \
  "$(printf '\n      orch.sh agent clear closer --effort --global\n')"
assert_contains "still listing the failing role's model and effort with their sources" "$out" \
  "ok    agent closer: model inherit (inherit), effort huge (global, invalid)"
git config --local orchestrator.effort.closer low
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a global bad value hidden by a local one still fails" "$st" 1
assert_contains "naming the global key" "$out" "FAIL  orchestrator.effort.closer is huge (global)"
restore_suite_env

# --- doctor: Junie session and log (#1449) ------------------------------------
# Best effort, from Junie's own files under $HOME/.junie: the newest session for
# this checkout names its log, whose last "Executing agent" line per orch-*
# agent says what it ran on; and the newest log's Unrecognized 'model' value
# line FAILs when the value is a role's effective Junie model.
echo
echo "doctor: Junie session and log"
healthy_repo
doctor_github
JH="$HOME/.junie"
root="$(git rev-parse --show-toplevel)"
junie_reset() { rm -rf "$JH"; mkdir -p "$JH/sessions" "$JH/logs"; }
junie_index() { # <session> <updatedAt>...
  : >"$JH/sessions/index.jsonl"
  while [ $# -ge 2 ]; do
    printf '{"sessionId":"%s","projectDir":"%s","createdAt":"1","updatedAt":"%s"}\n' "$1" "$root" "$2" >>"$JH/sessions/index.jsonl"
    shift 2
  done
}
junie_exec() { # <log> <session> <agent> <model> <effort> <reasoningEffort>
  printf 'session %s\n%s INFO Executing agent custom_agent_%s_1 with parameters AgentParams(model=%s, effort=%s, reasoningEffort=%s)\n' \
    "$2" "x" "$3" "$4" "$5" "$6" >>"$JH/logs/$1"
}

junie_reset
junie_index new 20 old 10
junie_exec log-a.log old orch-reviewer-spec gpt-4 null low
junie_exec log-b.log new orch-reviewer-spec gpt-5-2025-08-07 null high
junie_exec log-b.log new orch-fixer claude-opus-5-5 medium null
junie_exec log-b.log new orch-fixer claude-opus-5-5 low null
git config orchestrator.junie.model.reviewer gpt-5
git config orchestrator.junie.effort.reviewer high
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a Junie session report exits 0" "$st" 0
assert_contains "the newer session is chosen; a dated model matches the set one, effort read from reasoningEffort=" "$out" \
  "ok    junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt-5, effort high)"
assert_contains "an inherit key gives an ok line with effort read from effort=, the last line wins" "$out" \
  "ok    junie orch-fixer ran model claude-opus-5-5, effort low (set model inherit, effort inherit)"
assert_not_contains "an agent absent from the log gets no line" "$out" "junie orch-closer"
assert_not_contains "no cannot-tell line when the session is read" "$out" "junie session: cannot tell"

git config orchestrator.junie.model.reviewer gpt-4
git config orchestrator.junie.effort.reviewer low
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a mismatch is a WARN, not a failure" "$st" 0
assert_contains "a model and effort mismatch warns" "$out" \
  "warn  junie orch-reviewer-spec ran model gpt-5-2025-08-07, effort high (set model gpt-4, effort low)"
git config --unset orchestrator.junie.model.reviewer
git config --unset orchestrator.junie.effort.reviewer

assert_junie_cannot_tell() { # <label> <reason>
  out="$("$ORCH" doctor --env 2>&1)"; st=$?
  assert_status "$1 exits 0" "$st" 0
  assert_contains "$1 gives the cannot-tell line" "$out" "ok    junie session: cannot tell ($2"
}
junie_reset
assert_junie_cannot_tell "no session" "no Junie session index"
junie_index other 5; sed -i 's#"projectDir":"[^"]*"#"projectDir":"/elsewhere"#' "$JH/sessions/index.jsonl"
assert_junie_cannot_tell "an index without this checkout" "no session for this checkout"
junie_index lost 5
assert_junie_cannot_tell "a session no log names" "no log names session lost"
echo 'not json' >"$JH/sessions/index.jsonl"
assert_junie_cannot_tell "a garbled index" "the session index does not parse"
junie_index g 5
printf 'g\ngarbage\n' >"$JH/logs/log-g.log"
assert_junie_cannot_tell "a garbled log" "the log "

junie_reset
junie_index s 5
echo "s" >"$JH/logs/log-old.log"
printf "WARN Unrecognized 'model' value 'old-model', falling back to default. Allowed LLM names: a, b\n" >>"$JH/logs/log-old.log"
touch -d '2 days ago' "$JH/logs/log-old.log"
echo "nothing" >"$JH/logs/log-new.log"
git config orchestrator.junie.model.fixer old-model
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "the line only in an older log gives no failure" "$st" 0
assert_not_contains "and no message" "$out" "did not recognise"
printf "WARN Unrecognized 'model' value 'bad-model', falling back to default. Allowed display names: X. Allowed LLM names: gpt-5, claude-opus-5-5\n" >>"$JH/logs/log-new.log"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unrecognised value that is not set gives no failure" "$st" 0
assert_not_contains "and no message" "$out" "did not recognise"
git config orchestrator.junie.model.fixer bad-model
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unrecognised local set model fails" "$st" 1
assert_contains "naming the role" "$out" "FAIL  Junie did not recognise model bad-model, set for fixer (local)"
assert_contains "printing the allowed LLM names" "$out" "Allowed LLM names: gpt-5, claude-opus-5-5"
assert_contains "with the agent set remedy" "$out" "orch.sh agent set fixer --host junie --model <id>"
git config --unset orchestrator.junie.model.fixer
git config --global orchestrator.junie.model.closer bad-model
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "an unrecognised global set model fails" "$st" 1
assert_contains "naming the global role" "$out" "set for closer (global)"
git config orchestrator.junie.model.closer good
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a global model hidden by a local one gives no failure" "$st" 0
git config --unset orchestrator.junie.model.closer
rm -rf "$JH"
restore_suite_env

# --- doctor: Junie agent settings check (#1448) -------------------------------
# Doctor lists the Junie setting of every role beside the Claude Code one, fails
# a disallowed stored Junie value at each scope with the clear that removes it,
# and warns when this checkout's .junie/agents/ copies are not what agent sync
# would leave (missing, stale or extra, or an unmarked orch-*.md in the way).
echo
echo "doctor: Junie agent settings check"
healthy_repo
doctor_github
git config --global orchestrator.junie.model.reviewer gpt-5
git config --local orchestrator.junie.effort.implementer high
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_contains "lists a role's local Junie effort and inherited model" "$out" \
  "ok    agent junie implementer: model inherit (inherit), effort high (local)"
assert_contains "lists a role's global Junie model" "$out" \
  "ok    agent junie reviewer: model gpt-5 (global), effort inherit (inherit)"
assert_contains "lists every role, the last among them" "$out" \
  "ok    agent junie resolver: model inherit (inherit), effort inherit (inherit)"
assert_contains "warns of the missing copies" "$out" "warn  Junie agent copies in"
assert_contains "naming a missing copy" "$out" "missing orch-implementer.md"
assert_contains "with agent sync as its remedy" "$out" "$(printf '\n      orch.sh agent sync\n')"
assert_status "a copies WARN alone does not fail doctor" "$st" 0

"$ORCH" agent sync
out="$("$ORCH" doctor --env 2>&1)"
assert_eq "no WARN once sync has run" "$(printf '%s\n' "$out" | grep -c 'Junie agent copies')" "0"

echo "# hand edit" >>.junie/agents/orch-implementer.md
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "warns of a stale copy" "$out" "stale orch-implementer.md"
"$ORCH" agent sync

git config --local --unset orchestrator.junie.effort.implementer
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "warns of an extra copy once its setting is gone" "$out" "extra orch-implementer.md"
"$ORCH" agent sync 2>/dev/null

printf '%s\n' 'mine' >.junie/agents/orch-reviewer-spec.md
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "warns of an unmarked file in the way, by name" "$out" \
  "orch-reviewer-spec.md carries no sync marker and is in the way"
printf '%s\n' 'mine too' >.junie/agents/orch-reviewer-standards.md
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "warns of two unmarked files in the way, both named" "$out" \
  "warn  Junie agent copies in $PWD/.junie/agents are not what agent sync would leave: orch-reviewer-spec.md orch-reviewer-standards.md carries no sync marker and is in the way"
rm -f .junie/agents/orch-reviewer-standards.md
rm -f .junie/agents/orch-reviewer-spec.md

git config --local orchestrator.junie.model.fixer "my model"
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a local disallowed Junie model fails doctor" "$st" 1
assert_contains "naming the key and value" "$out" \
  "FAIL  orchestrator.junie.model.fixer is my model (local) - not an allowed model"
assert_contains "with the local Junie clear as its remedy" "$out" \
  "$(printf '\n      orch.sh agent clear fixer --host junie --model\n')"
git config --local --unset orchestrator.junie.model.fixer

git config --global orchestrator.junie.effort.closer huge
git config --local orchestrator.junie.effort.closer low
out="$("$ORCH" doctor --env 2>&1)"; st=$?
assert_status "a global bad Junie value hidden by a local one still fails" "$st" 1
assert_contains "naming the global key" "$out" "FAIL  orchestrator.junie.effort.closer is huge (global)"
assert_contains "with the global Junie clear as its remedy" "$out" \
  "$(printf '\n      orch.sh agent clear closer --host junie --effort --global\n')"
restore_suite_env

# --- doctor: autopilot phase label and claims (#1457) -------------------------
# The phase label against the recorded phase, and old claims of other hosts.
echo
echo "doctor: autopilot phase label and claims"
fake_flow autopilot-doctor
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent orch:implement
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "doctor flags a label that disagrees with the recorded phase" "$out" "is labelled orch:implement, but this checkout last moved to phase spec"
fake_issue 7 open ready-for-agent orch:review orch:spec
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "two phase labels are named space-separated in table order" "$out" "is labelled orch:spec orch:review, but this checkout last moved to phase spec"
fake_issue 7 open ready-for-agent orch:spec
out="$("$ORCH" doctor --flow 2>&1)"
assert_contains "an agreeing label is ok" "$out" "phase label: orch:spec"
fake_fail adapter_issue_state_labels "HTTP 502"
out="$("$ORCH" doctor --flow 2>&1 >/dev/null)"
assert_not_contains "doctor stays silent about a failed label read" "$out" "HTTP 502"
fake_unfail
fake_issue 7 open ready-for-agent
out="$("$ORCH" doctor --flow 2>&1)"; st=$?
assert_not_contains "an interactive flow's missing label is not mentioned" "$out" "phase label"
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow refuses an autopilot session with no phase label" "$st" 1
assert_contains "naming it" "$out" "carries no phase label"
fake_claim_seed 7 otherhost 5 2020-01-01T00:00:00Z
fake_claim_seed 8 otherhost 5 "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fake_claim_seed 9 "$(hostname)" 5 2020-01-01T00:00:00Z
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "doctor lists another host's old claim" "$out" "issue #7 has been claimed by otherhost"
assert_contains "its remedy names the host to run a tick on" "$out" "if that session is gone, run orch.sh autopilot tick on otherhost"
assert_not_contains "and no claim ref" "$out" "refs/orch/claims"
assert_not_contains "not a fresh one" "$out" "issue #8"
assert_contains "this host's dead claim with no record warns, naming issue, phase and no record" "$out" "issue #9 is claimed by this host (phase spec), but its process is gone (no record)."
assert_contains "with the tick remedy" "$out" "orch.sh autopilot tick"
live_orch liveness_run_begin 9
out="$("$ORCH" doctor --env 2>&1)"
assert_not_contains "a live claim adds no warning" "$out" "issue #9 is claimed"
live_stop
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "a since-exited run record's pid is named" "$out" "issue #9 is claimed by this host (phase spec), but its process is gone (pid $LIVE_PID)."
sourced_orch liveness_issue_forget 9
out="$(PATH="$(nowalk_bin):$PATH" "$ORCH" doctor --env 2>&1)"
assert_not_contains "with the checkouts unreadable, this host's claim adds no warning" "$out" "issue #9 is claimed"
fake_claim_seed 6 autopilot-abc123 5 2020-01-01T00:00:00Z
out="$(ORCH_HOST_ID=autopilot-abc123 "$ORCH" doctor --env 2>&1)"
assert_contains "with ORCH_HOST_ID set, a claim of that id is this host's" "$out" "issue #6 is claimed by this host"
assert_not_contains "and the hostname's claim is another identity's, a day old or not" "$out" "issue #9 is claimed by this host"
fake_fail adapter_claim_list "HTTP 502 claims"
out="$("$ORCH" doctor --env 2>&1)"
fake_unfail
assert_not_contains "claims origin cannot list are not reported" "$out" "has been claimed by"
assert_contains "and doctor's other checks still run" "$out" "ok    "
restore_suite_env

# --- doctor: autopilot side-checkout flows ------------------------------------
# A plain doctor in the main checkout checks the autopilot flows living in the
# watcher's side checkouts.
echo
echo "doctor: autopilot side-checkout flows"
tick_fixture
fake_issue 7 open ready-for-agent orch:spec
fake_issue_title 7 "Side flow"
# The side checkout is built by the commands a pickup runs: add, then init.
side7="$("$ORCH" side-checkout add 7-side-flow --issue 7 2>/dev/null)"
(cd "$side7" && "$ORCH" init 7-side-flow --issue 7 >/dev/null 2>&1)
fake_issue 7 open ready-for-agent orch:implement
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "doctor in the main checkout flags a side flow whose label disagrees" "$out" "issue #7 is labelled orch:implement, but its side checkout"
assert_contains "naming the recorded phase" "$out" "last moved to phase spec"
fake_issue 7 open ready-for-agent orch:review orch:spec
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "a side flow with two phase labels names both, space-separated" "$out" "issue #7 is labelled orch:spec orch:review, but its side checkout"
fake_issue 7 open ready-for-agent orch:spec
out="$("$ORCH" doctor --env 2>&1)"
assert_contains "an agreeing side flow is ok" "$out" "phase label of #7: orch:spec"
restore_suite_env ORCH_AUTOPILOT_LAUNCHER ORCH_AUTOPILOT_FOREGROUND

# --- doctor --flow: autopilot handoff comments (#1457) ------------------------
# In an autopilot session a handoff is the posted comment, so doctor --flow
# validates the fetched comment, never a file under the handoff directory.
echo
echo "doctor --flow: autopilot handoff comments"
fake_flow autopilot-handoffs
export ORCHESTRATOR_HOST=claude
state_fixture phase implement
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow fails with no recorded issue" "$st" 1
assert_contains "naming the unreadable handoff comments" "$out" "autopilot session, but no issue is recorded - the handoff comments cannot be read."
assert_contains "with abort as the remedy" "$out" "abort"
"$ORCH" state set issue 7 >/dev/null
fake_issue 7 open ready-for-agent orch:implement
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_status "doctor --flow fails with the handoff comments missing" "$st" 1
assert_contains "naming the missing plan comment" "$out" "handoff 01-plan comment is missing on issue #7"
plan_h="$(mktemp -d)/01-plan.md"
plan_file "$plan_h" $'Rounds: 2\nBudget: 3'
spec_h="$(mktemp -d)/02-spec.md"
complete_handoff "$spec_h"
ORCH_AUTOPILOT=1 "$ORCH" handoff post 01-plan "$plan_h" >/dev/null 2>&1
ORCH_AUTOPILOT=1 "$ORCH" handoff post 02-spec "$spec_h" >/dev/null 2>&1
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
assert_not_contains "posted handoff comments are not reported missing" "$out" "is missing"
assert_contains "the plan comment validates" "$out" "handoff 01-plan.md complete"
assert_contains "and the spec comment" "$out" "handoff 02-spec.md complete"
fake_fail adapter_issue_json "HTTP 502 comments"
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"; st=$?
fake_unfail
assert_status "a comments read failing past the gh gate is a failed check" "$st" 1
assert_contains "reported as the missing comment" "$out" "handoff 01-plan comment is missing on issue #7"
assert_contains "and doctor carries on to the next handoff" "$out" "handoff 02-spec comment is missing on issue #7"
fake_comment 7 o 2030-01-01T00:00:00Z "$(marker_of handoff 02-spec)
## Decisions"
out="$(ORCH_AUTOPILOT=1 "$ORCH" doctor --flow 2>&1)"
assert_contains "an incomplete newest comment is flagged" "$out" "handoff 02-spec.md: "
restore_suite_env
