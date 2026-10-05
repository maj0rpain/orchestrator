---
name: orch-flow
description: Drive the plan/spec/implement/review pipeline recorded in .orchestrator/state.json. Use when a planning session's plan has just been approved, when the user asks to start, advance, check, diagnose, redo, or abort a flow, or runs /orchestrator:start, /orchestrator:next, /orchestrator:status, /orchestrator:doctor, /orchestrator:redo, or /orchestrator:abort.
---

# Orchestrator flow

Four phases, four sessions: **plan -> spec -> implement -> review**. Each phase
runs with fresh context, reading a handoff file the previous phase wrote. You are
driving exactly one phase. Do the phase, write the handoff, stop.

## Resolve the script first

Every deterministic operation lives in `orch.sh`, so that reading state, naming
branches, and validating handoffs cannot drift between sessions:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root). Run
`bash "$ORCH" help` for the full command list. Never reimplement what it already
does.

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

## Host capabilities

Steps here name capabilities: invoke a skill, ask a multiple-choice question,
start a fresh subagent, start a fresh session. Skills are named bare
(`orch-handoff`); on Claude Code the scoped name is `orchestrator:<name>`.
`docs/host-capabilities.md` under the plugin root maps each capability to your
host. Where your host's cell says **Fallback**, or **Unverified** and the
capability turns out missing, take the fallback it documents and record it in
this phase's handoff under **Host fallbacks**. Where this file offers the human an
`/orchestrator:<command>`, here or in a skill this flow runs, and your host
has no plugin commands, offer the matching section of this skill instead.

## Starting a flow

Reached when a planning session's plan is approved. Runs in the planning session,
which holds the only copy of the plan.

1. Read the user's arguments, if any (on Claude Code, `/orchestrator:start`'s):
   a slug, `--issue N`, both, or neither. Pull `--issue N` out first. Whatever
   remains is the slug; use it as given. With none left, pick a slug from the
   plan's subject, kebab-case. Confirm it in one line.
2. `bash "$ORCH" init <slug>`, or `bash "$ORCH" init <slug> --issue N` when the user (or
   step 1's `--issue N`) named an already-open,
   already-triaged issue to adopt as the flow's spec instead of publishing a
   new one. `init` validates adoption immediately and dies if it cannot -
   report the failure and stop rather than continuing without an issue.
   It also refuses while the working tree has changes outside the planning
   allowlist, listing them: show the human the list and stop. Do not commit,
   stash, or discard them yourself - they may be the planning edits the guard
   exists to catch.
   Starting over a `done` flow archives it automatically and reports where -
   only a flow still mid-pipeline (`spec`/`implement`/`review`) refuses.
   **Whenever `init` fails, save the plan before stopping** - a failed
   precondition must never cost the user their plan. Write it, in the
   `01-plan.md` template from the `orch-handoff` skill, to
   `.scratch/orch-plan-<slug>.md`. `.scratch/` is on the planning allowlist, so
   the file never causes a refusal of its own. Tell the human where it is. Once
   they have fixed what `init` reported, rerun from step 2, in this session or a
   fresh one given that file.
3. Invoke the `orch-handoff` skill to write `01-plan.md`, from this session's
   plan or from the `.scratch/orch-plan-<slug>.md` step 2 saved. **Do
   this before anything else that can fail.** `init` is the one check that runs
   first, because it creates the directory the handoff goes in.
4. `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path spec)"`. Fix and re-validate
   until it passes.
5. `bash "$ORCH" doctor --env`. Report its output; stop only on a non-zero exit. A
   `warn` is an observation the user should see, not a reason to cost them a
   restart - the plan is already safe on disk either way.
6. `bash "$ORCH" phase boundary`, and relay its output (see **Printing the
   boundary** below).

## Next phase

Reached by `/orchestrator:next`, or when the user asks to run the flow's next
phase. Run it in a fresh session: if the context still holds the previous
phase, tell the user to start a fresh session (Claude Code `/clear`, Junie
`/new`) and stop rather than continuing.

1. `bash "$ORCH" doctor --flow`. On a non-zero exit, report and stop - offer
   `/orchestrator:abort` or a concrete repair. Do not proceed on stale state.
2. `bash "$ORCH" state get phase`, then run that phase below.

### Phase: spec

0. Check `bash "$ORCH" state get issue`. Non-empty means the flow adopted an issue
   at init - skip straight to step 4 below; steps 1-3 do not run, because the
   issue already exists and is already recorded. Empty means no `--issue` was
   given - run the phase from step 1, exactly as it does for every flow that
   has no adopted issue.
1. Read `bash "$ORCH" handoff path spec`. The **Rejected alternatives** section is
   load-bearing: do not re-propose anything it rules out.
2. Invoke the `orch-to-spec` skill and follow it. It will check test seams
   with the user - that exchange is the point, so do not skip it - and
   reports the issue it published.
3. Record the published issue: `bash "$ORCH" state set issue <number>`.
4. Invoke the `orch-spec-review` skill and follow it. It owns
   the review - four lenses, one batch question, the body rewritten with what
   the human accepts, and, when the accepted edits touch an open ticket of an
   existing breakdown, a ticket question that edits those tickets or retires
   the breakdown - and returns the changelog. This step is part of the
   phase, not an option in it: no spec reaches the implement phase unreviewed,
   and the human's control is at the batch, where they may decline every edit.
5. Run `bash "$ORCH" ticket exists <spec issue>` first, with the spec issue
   from `bash "$ORCH" state get issue`.

   **Exit 0** means the issue already has a ticket breakdown - as for a
   blueprint adopted at init; a default `redo spec` retires the breakdown
   first, so it never reaches this exit. Skip the breakdown and
   ask nothing: step 4's spec review may already have reconciled the
   breakdown with the edits it applied. If that review retired the
   breakdown instead, this step sees exit 1 and runs `orch-to-tickets` as
   below. It printed one word, which settles step 6's **Ticket
   breakdown**: `sub-issues` means the spec issue number, and `collapsed`
   means `None: work directly against #<n>` naming the spec issue.

   **Exit 1** means it has none: invoke the `orch-to-tickets` skill on the
   just-reviewed spec issue and follow it, through its own quiz until the
   user approves a breakdown. It publishes 2 or more tickets as sub-issues,
   or collapses 0 or 1 into the spec issue under its fixed `## Ticket`
   heading, and reports which: the published numbers, or `collapsed`. This
   step is part of the phase, not an option in it, the same way the review
   above is not: no spec reaches the implement phase without its breakdown.

   **Any other exit** means GitHub could not be read: stop, leaving the state
   where it is, say what blocked, and offer `/orchestrator:abort`.
6. Invoke the `orch-handoff` skill for `02-spec.md`, with the changelog the review
   returned as its **Spec review changelog**, and its **Ticket breakdown** as
   either the spec issue number (published or found as sub-issues) or
   `None: work directly against #<n>` naming the spec issue (collapsed, per
   step 5); validate it with `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path implement)"`,
   fixing and re-validating until it passes.
7. `bash "$ORCH" phase advance`. It validates `02-spec.md` again and checks the
   issue is recorded before recording the implement phase; on a FAIL the phase
   stays at spec - fix what it names and run it again. Relay its output (see
   **Printing the boundary**).

### Phase: implement

1. Read `bash "$ORCH" handoff path implement` and fetch the spec issue it names.
2. `bash "$ORCH" branch create` - creates `orch/<issue>-<slug>` off the flow's base
   branch (recorded in state at `init`) and records the base SHA the review will diff against.
3. Read the handoff's **Ticket breakdown** section, written by the spec
   phase's step 5.

   **`None: work directly against #<n>`** means that breakdown collapsed to
   0 or 1 tickets and published no sub-issue - `<n>` names the spec issue
   itself. No `ticket next`/`ticket close` loop runs against it: an empty
   frontier there means nothing was ever split out, not "already done."
   Dispatch exactly one subagent (below), for ticket `<n>`, then continue
   at step 4.

   **Any other content** names the spec issue as a parent whose GitHub
   sub-issues carry the real tickets. Work its frontier, one ticket at a
   time, never in parallel - every ticket commits to the same branch. Loop:
   - `bash "$ORCH" ticket next <spec issue>`. Nothing ready means the frontier is
     exhausted - stop looping and continue at step 4.
   - Dispatch a subagent (below) for the ticket.
   - Record the subagent's report, then `bash "$ORCH" ticket close <n>` - only now
     that the report is back, never before - and go around again.

   **Dispatching a subagent**: start the plugin's `orch-implementer` agent
   exactly as the **Starting this agent** section of
   `agents/orch-implementer.md` (under the plugin root) says, for the ticket
   named above. On Claude Code it is the agent named
   `orch-implementer` under the `orchestrator:` plugin scope. A host that
   cannot start it natively takes `docs/host-capabilities.md`'s **Start a
   fresh subagent** fallback; record it under the handoff's **Host
   fallbacks**, along with any fallback that section says the agent takes.
4. `bash "$ORCH" pr open "<title>" <body-file>`. The PR opens as a draft; marking it
   ready is the review loop's success condition. The PR targets the flow's base
   branch. `pr open` itself writes the issue line ahead of the body -
   `Closes #<issue>` when the base branch is the default branch, `Refs
   #<issue>` otherwise - so the body file carries no closing keyword of its
   own.
5. Invoke the `orch-handoff` skill for `03-implement.md`, assembling three
   sections from the tickets' reports:
   - **Deviations**: one bullet per ticket whose `Deviation` line is not
     `None`, naming the ticket and holding all of its deviations. "None" only
     if not one ticket reported a deviation, never left blank.
   - **Unmet criteria**: one bullet per ticket whose `Criteria` line names an
     unmet criterion or an `untested:` file, naming the ticket, each
     criterion, and each untested file. "None" otherwise.
   - **Verification**: from the last ticket's `Verification` line - its full
     verification ran over the whole branch - in the shape the `orch-handoff`
     template gives. A `fail` stays here, never under **Deviations**: a
     failing verification is not a deviation.
   Then validate it: `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path review)"`,
   fixing and re-validating until it passes.
6. `bash "$ORCH" phase advance`. It validates `03-implement.md` again and checks
   the branch, base SHA, and PR are recorded before recording the review phase;
   on a FAIL the phase stays at implement - fix what it names and run it again.
   Relay its output (see **Printing the boundary**).

### Phase: review

1. `bash "$ORCH" doctor --flow`.
2. Invoke the `orch-review` skill and follow it. It owns the
   loop; this file owns phase dispatch, and has nothing to add to a review
   beyond getting you there.

A flow may pass through this phase more than once. A loop that ends in a
bounded stop leaves `phase` at `review`, and a human who wants more looks runs
`/orchestrator:next` again: that is a fresh loop with its own budget, continuing
the flow's iteration numbering, and it reads `03-implement.md` like the first
one did.

## Printing the boundary

Every phase ends the same way, because the next phase needs a session this one
cannot start. `orch.sh` owns the block that says so, and its host's `Next:`
line: `phase advance` prints it on success, and `phase boundary` prints it at
flow start. Relay that output verbatim - never compose the block yourself.

Say nothing after it. Do not start the next phase, and do not offer to.

## Status

Reached by `/orchestrator:status`, or when the user asks where the flow
stands. Run `bash "$ORCH" status` and `bash "$ORCH" doctor --flow`, and report both
outputs. Read-only: do not start, advance, or repair a flow from here. If
`doctor` reports a problem, say what it found and stop.

## Doctor

Reached by `/orchestrator:doctor`, or when the user asks to diagnose the
machine, the repo, or the flow. Run `bash "$ORCH" doctor` and report its output.
Read-only: `doctor` prints the command that fixes each problem, and running
those is the user's call. A `FAIL` exits non-zero and would block the flow; a
`warn` is an observation and does not.

## Redo

`state.phase` names the phase that runs **next**, so re-running the phase that
just finished means stepping back one first. Only two directions are
supported - `review -> implement` and `implement -> spec` - each a mechanical
transition driven by `orch.sh`, not a per-artifact interview. Redo targeting
`phase: done` remains unsupported, exactly as today - it is not discussed by
the originating issue and is not expanded here.

**From `review`**: `bash "$ORCH" redo review`. It refuses unless the review loop
has reached a **bounded stop**, detected from the `## Terminal state` heading
the review skill's Termination step writes into the final iteration's
record. A PR marked ready has already moved `state.phase` to `done` as part
of that same termination - out of scope per above - so `stop` is the only
terminal state redo actually acts on. On a refusal, report the message and
stop rather than doing anything destructive:

- No loop has run yet: offer `/orchestrator:next` to start one.
- Still short of its budget: offer `/orchestrator:next` instead - that is what
  resumes a loop still mid-flight, and redo is for after a loop ends.
- The last iteration has no recorded terminal state: the session looks
  interrupted, not stopped - offer `/orchestrator:next` to resume it.

Once confirmed terminal, it runs without asking anything further - retiring
and closing are not destructive: the old branch is renamed aside
(`orch/<issue>-<slug>-redo-N`, never force-pushed over), the old draft PR is
closed with a comment pointing at the redo, the old loop's
`.orchestrator/review/iteration-NN.md` records move into `pre-redo-N/`,
the stale `03-implement.md` handoff moves into `.orchestrator/handoff/pre-redo-N/`
(the same N), `state.branch`/`state.pr`/`state.base_sha` are cleared, `state.iteration`
resets to 0, `state.redo_count` increments, `flake_rerun_used` is left
untouched (`docs/adr/0007-redo-resets-the-review-loops-iteration-and-budget.md`),
and `state.phase` becomes `implement`.

Abort differs on purpose: it ends the flow with no successor phase, so a
mistaken call loses the live flow's state, whereas redo always leaves a live
flow behind and every transition it makes can be undone by another `redo` or
`next`.

**From `implement`**: ask the human once whether to keep the existing spec
issue and re-review it, retiring its ticket breakdown (default), or publish a
fresh one. Then call
`bash "$ORCH" redo spec` or `bash "$ORCH" redo spec --new-issue` accordingly. The
default keeps the issue and retires its ticket breakdown - each sub-issue
closed as not planned if still open, commented on and unlinked, or the
collapsed `## Ticket` section cut from the body - then changes `state.phase`
to `spec`, so the spec phase's step 5 breaks the redone spec down again; the
existing "adopted issue" path through the spec phase's step 0 does the rest.
If GitHub fails while retiring, it dies with the phase still `implement`, and
a re-run resumes. Either way the
stale `02-spec.md` handoff, and `03-implement.md` if one exists, move into
`.orchestrator/handoff/pre-redo-spec-<UTC timestamp>/`, so `phase advance`
cannot leave the redone spec phase on them; `state.redo_count` is not bumped.
`01-plan.md` is never touched by either redo. `--new-issue`
additionally closes the old issue first (never deletes it) with a comment
explaining why, and clears `state.issue`, so `orch-to-spec` runs again from
scratch.

## Abort

1. Confirm with the user.
2. `bash "$ORCH" archive`.
3. Report what survives: the branch, the spec issue, and the PR are untouched, so
   list whichever exist and let the user clean up.

## Rules

- **One phase per session.** The context you accumulated is exactly what the next
  phase must not inherit.
- **One flow at a time.** `init` enforces it. For a second feature, use a second
  checkout.
- **Never merge.** The flow opens a draft PR and stops. Merging is the user's.
- **Never edit `.orchestrator/state.json` by hand; the phase moves only through
  `phase advance`, `review ready`, and redo, and `issue`, `budget`, and
  `flake_rerun_used` change only through `orch.sh state set`.**
- If a phase cannot finish, leave the state where it is, say what blocked it, and
  offer `/orchestrator:abort` (which archives rather than deletes).
