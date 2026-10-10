# --- init -------------------------------------------------------------------
echo
echo "init"
new_repo >/dev/null
fake_github
out="$("$ORCH" init "My Feature!!")"
assert_eq "normalises slug to kebab-case" "$out" "my-feature"
assert_eq "state starts at the spec phase" "$("$ORCH" state get phase)" "spec"
assert_eq "iteration starts at zero" "$("$ORCH" state get iteration)" "0"
assert_eq "issue starts unset" "$("$ORCH" state get issue)" ""
assert_contains "excludes .orchestrator/ without touching .gitignore" \
  "$(cat .git/info/exclude)" ".orchestrator/"
assert_eq "leaves the working tree clean" "$(git status --porcelain)" ""
assert_eq "excludes .orchestrator/ exactly once" "$(exclude_count .orchestrator/)" "1"
assert_eq "excludes .scratch/ exactly once" "$(exclude_count .scratch/)" "1"

# #720: a flow mid-pipeline is refused with its own exit code, 3, so a skill
# can tell "a flow is active" apart from every other init failure.
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "refuses a second concurrent flow with exit 3" "$st" 3
assert_contains "explains how to clear the active flow" "$out" "abort"
assert_contains "with the message unchanged" "$out" "a flow is already active (slug: my-feature, phase: spec)."

out="$("$ORCH" init other --bogus 2>&1)"; st=$?
assert_status "rejects an unknown flag" "$st" 1
assert_contains "names the flag it rejected" "$out" "--bogus"

out="$("$ORCH" init 2>&1)"; st=$?
assert_status "a missing slug keeps its usage exit code" "$st" 1
assert_contains "printing the usage" "$out" "usage: orch.sh init"

out="$("$ORCH" init other --issue x 2>&1)"; st=$?
assert_status "a malformed --issue keeps its exit code" "$st" 1
restore_suite_env

# --- init git-excludes the plugin's directories once ---------------------------
echo
echo "init git-excludes the plugin's directories once"
new_repo >/dev/null
fake_github
"$ORCH" init first >/dev/null
rm -rf .orchestrator
"$ORCH" init second >/dev/null
assert_eq "a second init leaves .orchestrator/ excluded once" "$(exclude_count .orchestrator/)" "1"
assert_eq "a second init leaves .scratch/ excluded once" "$(exclude_count .scratch/)" "1"
git checkout -q -b quick/7-bar
"$ORCH" review-pass begin 7 >/dev/null
assert_eq "init then review-pass begin leaves .orchestrator/ excluded once" "$(exclude_count .orchestrator/)" "1"
assert_eq "init then review-pass begin leaves .scratch/ excluded once" "$(exclude_count .scratch/)" "1"

new_repo >/dev/null
printf '%s\n' ".scratch/" >>.git/info/exclude
"$ORCH" init third >/dev/null
assert_eq "a .scratch/ line already present is not written again" "$(exclude_count .scratch/)" "1"
assert_eq "and .orchestrator/ is still added beside it" "$(exclude_count .orchestrator/)" "1"
mkdir -p .scratch && echo plan >.scratch/plan.md
assert_eq "an untracked .scratch/ stays out of git status" "$(git status --porcelain)" ""
restore_suite_env

# --- init refuses a dirty working tree ----------------------------------------
# The git-based backstop from ADR-0013: a host with no mechanical trigger for
# the edit guard can still edit source during planning, so flow start is where
# those edits get caught. Only the planning allowlist may be dirty.
echo
echo "init refuses a dirty working tree"
new_repo >/dev/null
fake_github
echo "code" >stray.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses an untracked file outside the allowlist" "$st" 1
assert_contains "names the untracked path" "$out" "stray.sh"
assert_eq "writes no state when it refuses" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
assert_contains "says how to resolve it" "$out" "Commit, stash, or discard"
assert_contains "says to retry" "$out" "run init again"
assert_contains "names what planning may change" "$out" "docs/agents/"
assert_not_contains "source-only refusal has no records block" "$out" "Planning records changed"

rm stray.sh
echo "changed" >>docs/agents/triage-labels.md
echo "base" >src.sh; git add src.sh; git commit -qm src
echo "edit" >>src.sh
mkdir -p lib && echo "new" >lib/deep.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a tracked modification outside the allowlist" "$st" 1
assert_contains "names the modified path" "$out" "src.sh"
assert_contains "names an untracked file inside a new directory" "$out" "lib/deep.sh"
case "$out" in *triage-labels.md*) bad "does not name allowlisted paths" "$out" ;;
  *) ok "does not name allowlisted paths" ;; esac

git checkout -q src.sh; rm -r lib
git mv src.sh moved.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a staged rename" "$st" 1
assert_contains "names the rename's new path" "$out" "moved.sh"
assert_contains "names the rename's old path" "$out" "src.sh"
git mv moved.sh src.sh

# A git status that cannot run is not a clean tree - reading it as one would
# wave through exactly the edits this check exists to catch.
cp .git/index .git/index.bak; echo garbage >.git/index
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses when git status fails" "$st" 1
assert_eq "writes no state when git status fails" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
mv .git/index.bak .git/index

# The glossary and ADRs are planning records: a dirty one refuses init with
# the guard's redirect, under its own heading (#186).
echo "# glossary" >GLOSSARY.md
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a dirty GLOSSARY.md" "$st" 1
assert_contains "heads the records block" "$out" "Planning records changed (planning does not edit these in place):
       GLOSSARY.md"
# The redirect is wrapped for the terminal, so its phrases are checked with
# the line breaks and indentation flattened out.
flat="$(printf '%s' "$out" | flat_text)"
assert_contains "gives the records redirect" "$flat" "into the plan, so the spec carries it verbatim"
assert_contains "gives the quick-implementation redirect" "$flat" "For a quick implementation, put it in the linked issue's body."
assert_eq "wraps the redirect for the terminal" \
  "$(printf '%s\n' "$out" | awk 'length > 80' | wc -l | tr -d ' ')" "0"
assert_not_contains "records-only refusal has no source block" "$out" "Changes outside the planning allowlist:"
# Committing a record from planning is the option ADR-0022 rejects, so a
# records-only refusal never offers it.
assert_not_contains "records-only refusal never says to commit" "$out" "Commit"
assert_contains "says to discard or stash the records" "$out" "Discard or stash these changes, then run init again."
assert_eq "writes no state for a dirty record" "$([ -f .orchestrator/state.json ] && echo yes || echo no)" "no"
rm GLOSSARY.md

# The legacy glossary names stay records, for repos not yet renamed (#461).
for f in CONTEXT.md CONTEXT-MAP.md; do
  echo "# glossary" >"$f"
  out="$("$ORCH" init dirty 2>&1)"; st=$?
  assert_status "refuses a dirty legacy $f" "$st" 1
  assert_contains "lists legacy $f under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       $f"
  rm "$f"
done

mkdir -p docs/adr && echo "# ADR" >docs/adr/0001-x.md
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses a dirty ADR" "$st" 1
assert_contains "lists the ADR under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       docs/adr/0001-x.md"

echo "code" >stray.sh
out="$("$ORCH" init dirty 2>&1)"; st=$?
assert_status "refuses both dirty lists" "$st" 1
assert_contains "lists the record under the records heading" "$out" "Planning records changed (planning does not edit these in place):
       docs/adr/0001-x.md"
assert_contains "lists the source path under its own heading" "$out" "Changes outside the planning allowlist:
       stray.sh"
assert_contains "tells the records apart in the resolution line" "$out" "Discard or stash the planning records; commit, stash, or discard the other
     changes, then run init again."
case "$out" in *"allowlist:"*docs/adr/0001-x.md*) bad "does not list the record under the source heading" "$out" ;;
  *) ok "does not list the record under the source heading" ;; esac
rm -r stray.sh docs/adr

mkdir -p .scratch && echo "ticket" >.scratch/t.md
mkdir -p sub
out="$(cd sub && "$ORCH" init clean-enough 2>&1)"; st=$?
assert_status "starts with only allowlisted changes, even from a subdirectory" "$st" 0
assert_eq "records the flow" "$("$ORCH" state get slug)" "clean-enough"
restore_suite_env

# --- init --issue -------------------------------------------------------
# Adoption is validated once, immediately, before state.json is written - a bad
# issue number must cost nothing, the same promise branch create and pr open
# already make about their own preconditions.
echo
echo "init --issue"
healthy_repo
fake_github
fake_issue 42 open ready-for-agent
out="$("$ORCH" init adopted --issue 42)"
assert_eq "adopts an open, labelled issue" "$out" "adopted"
assert_eq "issue is recorded as a number" "$("$ORCH" state get | jq -r '.issue | type')" "number"
assert_eq "issue value matches the adopted number" "$("$ORCH" state get issue)" "42"

healthy_repo
out="$("$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "refuses to adopt an issue gh cannot read" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "no flow is left active after a failed adoption" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
fake_issue 7 closed ready-for-agent
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt a closed issue" "$st" 1
assert_contains "says the issue is not open" "$out" "not open"

healthy_repo
fake_issue 7 open needs-triage
out="$("$ORCH" init nope --issue 7 2>&1)"; st=$?
assert_status "refuses to adopt an issue missing the triage label" "$st" 1
assert_contains "names the missing label" "$out" "ready-for-agent"

# validate_adopted_issue's state and labels come off the same issue, so one
# read answers both: adapter_issue_state_labels, whose single gh call is
# pinned in "gh adapter contract".

healthy_repo
writeln '# Triage Labels' '' \
        '| Label in mattpocock/skills | Label in our tracker | Meaning     |' \
        '| -------------------------- | -------------------- | ----------- |' \
        '| `ready-for-agent`          | `-agent`             | AFK-ready   |' >docs/agents/triage-labels.md
fake_issue 43 open -agent
out="$("$ORCH" init dashed --issue 43 2>&1)"; st=$?
assert_status "adopts an issue whose ready-for-agent label begins with '-'" "$st" 0
assert_eq "recording it" "$("$ORCH" state get issue)" "43"

healthy_repo
fake_issue 44 open ready-for-agent
fake_fail adapter_issue_state_labels $'HTTP 502: Bad Gateway\nsecond line'
before_store="$(fake_snapshot)"
out="$("$ORCH" init nope --issue 44 2>&1)"; st=$?
assert_status "refuses to adopt an issue whose read fails" "$st" 1
assert_contains "saying it could not be read, with gh's first line" "$out" \
  "issue #44 could not be read from GitHub - check it exists and gh is authenticated: HTTP 502: Bad Gateway"
assert_not_contains "and nothing past gh's first line" "$out" "second line"
assert_eq "leaving no flow active" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"
assert_eq "and GitHub unchanged" "$(fake_snapshot)" "$before_store"
fake_unfail

healthy_repo
out="$("$ORCH" init nope --issue 2>&1)"; st=$?
assert_status "requires a value after --issue" "$st" 1

healthy_repo
out="$("$ORCH" init nope --issue https://github.com/acme/widgets/issues/42 2>&1)"; st=$?
assert_status "refuses a non-numeric --issue value" "$st" 1
assert_contains "says --issue wants a plain number" "$out" "--issue"
assert_eq "no flow is left active after a malformed --issue" \
  "$([ -f .orchestrator/state.json ] && echo present || echo gone)" "gone"

healthy_repo
out="$("$ORCH" init 2>&1)"; st=$?
assert_status "adoption does not change that a slug is still required" "$st" 1
restore_suite_env

# --- init archives a done flow -----------------------------------------------
# issue #13: a "done" flow already succeeded - nothing downstream reads its
# handoffs - so starting over it is normal pipeline cleanup, not something
# init should still refuse as "active".
echo
echo "init archives a done flow"
fresh_flow first
complete_plan_handoff "$("$ORCH" handoff path spec)"
state_fixture phase "done"
out="$("$ORCH" init second)"; st=$?
assert_status "starting over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "first"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "first"
assert_eq "the new flow's state reflects the new slug" "$("$ORCH" state get slug)" "second"
assert_eq "the new flow starts at the spec phase, not done" "$("$ORCH" state get phase)" "spec"

# #622: init's archive of a done flow refuses the same way archive does.
fresh_flow first
complete_plan_handoff "$("$ORCH" handoff path spec)"
state_fixture phase "done"
git checkout -q -b orch/1-first
top="$(git rev-parse --show-toplevel)"
"$ORCH" ticket-worktree add 6 >/dev/null
out="$("$ORCH" init second 2>&1)"; st=$?
assert_status "init over a done flow refuses while a ticket worktree exists" "$st" 1
assert_contains "naming it" "$out" "$top/.orchestrator/worktrees/t6"
assert_contains "with ticket-worktree remove as the remedy" "$out" "ticket-worktree remove"
assert_eq "the done flow is left in place" "$("$ORCH" state get slug)" "first"
assert_eq "nothing is archived" \
  "$([ -e .orchestrator/archive ] && echo present || echo absent)" "absent"
"$ORCH" ticket-worktree remove 6

healthy_repo
out="$("$ORCH" init nothing-to-archive)"
assert_eq "with no prior flow, stdout is still just the slug" "$out" "nothing-to-archive"

fresh_flow stale
state_fixture phase implement
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "an implement-phase flow still refuses with exit 3, same as spec" "$st" 3
assert_contains "names the phase" "$out" "phase: implement"
assert_contains "same message, unchanged" "$out" "One flow at a time"

state_fixture phase review
out="$("$ORCH" init other 2>&1)"; st=$?
assert_status "a review-phase flow refuses with exit 3 too" "$st" 3
assert_contains "naming the review phase" "$out" "phase: review"
assert_eq "the active flow is left in place" "$("$ORCH" state get slug)" "stale"

fresh_flow willfail
fake_github
state_fixture phase "done"
out="$("$ORCH" init nope --issue 99 2>&1)"; st=$?
assert_status "a bad --issue adoption over a done flow refuses" "$st" 1
assert_contains "names the issue number" "$out" "99"
assert_eq "the done flow is left untouched, not archived" \
  "$("$ORCH" state get slug)" "willfail"
assert_eq "and still reports done, re-runnable" "$("$ORCH" state get phase)" "done"

# A good --issue adoption over a done flow is the counterpart to the bad one
# just above: validation still runs first, but this time it passes, so the
# done flow must be archived exactly as the no-`--issue` case archives it,
# and the new flow's state must carry the newly adopted issue rather than
# null or the old flow's own issue.
healthy_repo
fake_issue 7 open ready-for-agent
fake_issue 42 open ready-for-agent
"$ORCH" init willsucceed --issue 7 >/dev/null
state_fixture phase "done"
out="$("$ORCH" init second --issue 42)"; st=$?
assert_status "a valid --issue adoption over a done flow succeeds" "$st" 0
archived="$(printf '%s\n' "$out" | sed -n '1p')"
assert_contains "prints the archive path first, carrying the old slug" "$archived" "willsucceed"
assert_eq "the new slug is the final line" "$(printf '%s\n' "$out" | tail -1)" "second"
assert_eq "exactly two lines - the archive path, then the slug" \
  "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "2"
assert_eq "the old flow's state is archived under .orchestrator/archive/" \
  "$([ -f "$archived/state.json" ] && echo present || echo gone)" "present"
assert_eq "the archived state still carries the old slug" \
  "$(jq -r .slug "$archived/state.json")" "willsucceed"
assert_eq "the new flow's state records the newly adopted issue, not the old one" \
  "$("$ORCH" state get issue)" "42"
restore_suite_env

# --- init seeds the review loop ---------------------------------------------
echo
echo "init seeds the review loop"
fresh_flow seeded
assert_eq "a flow starts with no loop counter" \
  "$("$ORCH" state get | jq -r 'has("loop")')" "false"
assert_eq "and no budget until a human names one" "$("$ORCH" state get budget)" ""
assert_eq "with somewhere to file its records" \
  "$([ -d .orchestrator/review ] && echo present || echo gone)" "present"
assert_eq "and no per-loop directory under it" \
  "$([ -e .orchestrator/review/loop-01 ] && echo present || echo gone)" "gone"
# The flake rerun belongs to the flow, so it is seeded once here and never
# refilled. `state get` reads it back as "false" - the review skill tests only
# for "true", so spent is "true" and anything else is unspent.
assert_eq "and one flake rerun unspent" \
  "$("$ORCH" state get | jq -r '.flake_rerun_used')" "false"
assert_eq "which reads as unspent through state get" \
  "$("$ORCH" state get flake_rerun_used)" "false"
"$ORCH" state set flake_rerun_used true
assert_eq "and as spent once it has been" \
  "$("$ORCH" state get flake_rerun_used)" "true"

# redo_count is what answers "how many times has this flow been redone" once
# a redo has happened - iteration alone no longer can.
assert_eq "a fresh flow has never been redone" "$("$ORCH" state get redo_count)" "0"
assert_eq "recorded as a number, not a string" \
  "$("$ORCH" state get | jq -r '.redo_count | type')" "number"

assert_contains "status names the iteration against the default budget" \
  "$("$ORCH" status)" "iteration 0 of 5"
"$ORCH" state set budget 3
state_fixture iteration 2
assert_contains "and against the budget once one is set" \
  "$("$ORCH" status)" "iteration 2 of 3"
assert_contains "status shows how many times the flow has been redone" \
  "$("$ORCH" status)" "redo:      0"
state_fixture redo_count 2
assert_contains "and updates once it has been" "$("$ORCH" status)" "redo:      2"
assert_contains "help documents the review verb" "$("$ORCH" help)" "review begin"
assert_contains "and the CI classifier's outcomes" "$("$ORCH" help)" "review ci"
assert_contains "and filing" "$("$ORCH" help)" "review file"
assert_contains "with the finding's axis" "$("$ORCH" help)" "review file <major|nit> <title> --axis <spec|standards> --body-file <file>"
assert_contains "and finding triage's scan" "$("$ORCH" help)" "finding-triage scan [--all] [<issue> | --pr <n>]"
assert_contains "with --all's re-check" "$("$ORCH" help)" "--all: every open review:<severity> finding"
assert_contains "and the triage-state column" "$("$ORCH" help)" "TAB <detail> TAB <state>"
assert_contains "and its apply, in both forms" "$("$ORCH" help)" "finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>"
assert_contains "the open one with its category" "$("$ORCH" help)" "--category <bug|enhancement> --comment-file <file>"
assert_contains "and the terminal-state classifier" "$("$ORCH" help)" "review terminal"
assert_contains "and retiring a loop's records" "$("$ORCH" help)" "review retire"
assert_contains "help documents issue publish" "$("$ORCH" help)" "issue publish"
assert_contains "and pr publish" "$("$ORCH" help)" "pr publish"
assert_contains "and pr release" "$("$ORCH" help)" "pr release [--force] <title> <body-file>"
assert_contains "and ticket publish" "$("$ORCH" help)" "ticket publish"
assert_contains "and ticket next" "$("$ORCH" help)" "ticket next"
assert_contains "and ticket close" "$("$ORCH" help)" "ticket close"
assert_contains "and ticket reset" "$("$ORCH" help)" "ticket reset"
assert_contains "and retiring a branch" "$("$ORCH" help)" "branch retire"
assert_contains "and creating one" "$("$ORCH" help)" "branch create"
assert_contains "and forking one for a quick implementation" "$("$ORCH" help)" "branch off"
assert_contains "and opening a draft PR" "$("$ORCH" help)" "pr open"
assert_contains "and redo review" "$("$ORCH" help)" "redo review"
assert_contains "and redo spec" "$("$ORCH" help)" "redo spec"
assert_eq "and no longer the loop machinery" "$("$ORCH" help | grep -c 'loop-next')" "0"
restore_suite_env
