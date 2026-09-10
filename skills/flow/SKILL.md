---
name: flow
description: Drive the plan/spec/implement/review pipeline recorded in .orchestrator/state.json. Use when a planning session's plan has just been approved, or when the user runs /orchestrator:start, /orchestrator:next, /orchestrator:status, /orchestrator:redo, or /orchestrator:abort.
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

If `CLAUDE_PLUGIN_ROOT` is unset, it is `scripts/orch.sh` two directories above
this file. Run `"$ORCH" help` for the full command list. Never reimplement what
it already does.

## The upstream skills are not callable

`to-spec`, `implement`, `handoff`, `wayfinder`, and `improve-codebase-architecture`
carry `disable-model-invocation: true`. The Skill tool cannot reach them.

Their `SKILL.md` files are plain markdown. Resolve one with
`"$ORCH" mp-skill <name>`, read it, and follow its instructions verbatim - that
is exactly what the Skill tool would have injected. Never tell the user to type
the slash command themselves, and never claim to have invoked a skill you read.

`code-review`, `tdd`, `research`, and `domain-modeling` have no such flag; call
those through the Skill tool normally.

## Starting a flow

Reached when a planning session's plan is approved. Runs in the planning session,
which holds the only copy of the plan.

1. Pick a slug from the plan's subject, kebab-case. If the user passed one as an
   argument, use theirs. Confirm it in one line.
2. `"$ORCH" init <slug>`.
3. Call the Skill tool with `orchestrator:handoff` to write `01-plan.md`. **Do
   this before anything that can fail** - a failed precondition must never cost
   the user their plan.
4. `"$ORCH" handoff validate "$("$ORCH" handoff path spec)"`. Fix and re-validate
   until it passes.
5. `"$ORCH" doctor --env`. Report its output; stop only on a non-zero exit. A
   `warn` is an observation the user should see, not a reason to cost them a
   restart - the plan is already safe on disk either way.
6. Print the boundary (see below).

## /orchestrator:next

1. `"$ORCH" doctor --flow`. On a non-zero exit, report and stop - offer
   `/orchestrator:abort` or a concrete repair. Do not proceed on stale state.
2. `"$ORCH" state get phase`, then run that phase below.

### Phase: spec

1. Read `"$ORCH" handoff path spec`. The **Rejected alternatives** section is
   load-bearing: do not re-propose anything it rules out.
2. Read and follow `"$ORCH" mp-skill to-spec`. It will check test seams with the
   user - that exchange is the point, so do not skip it.
3. Record the published issue: `"$ORCH" state set issue <number>`.
4. **Spec review is not built yet** (see Not yet built). Say so, and let the user
   decide whether to review the spec by hand before continuing.
5. Call `orchestrator:handoff` for `02-spec.md`, validate it, then
   `"$ORCH" state set phase implement`.
6. Print the boundary.

### Phase: implement

1. Read `"$ORCH" handoff path implement` and fetch the spec issue it names.
2. `"$ORCH" branch-create` - creates `orch/<issue>-<slug>` off the default branch
   and records the base SHA the review will diff against.
3. Read and follow `"$ORCH" mp-skill implement`. Keep its closing `code-review`
   step: it is the cheapest review in the pipeline, with full context and before
   anything is pushed. Capture what it found and fixed.
4. `"$ORCH" pr-open "<title>" <body-file>`. The PR opens as a draft; marking it
   ready is the review loop's success condition.
5. Call `orchestrator:handoff` for `03-implement.md`. Its **Deviations** section
   is what lets review tell an agreed change from scope creep - if there were no
   deviations, write "None", never leave it blank. Its **Verification** section is
   the command the review loop runs every iteration: record how you just ran the
   tests, because review takes it from here rather than guessing from the repo.
6. `"$ORCH" state set phase review`, then print the boundary.

### Phase: review

Call the Skill tool with `orchestrator:review` and follow it. It owns the loop;
this file owns phase dispatch, and has nothing to add to a review beyond getting
you there.

A flow may pass through this phase more than once: a loop that hands off to a
fresh loop leaves `phase` at `review`, so `/orchestrator:next` lands here again
and the review skill reads the handoff the previous loop wrote.

## Printing the boundary

Every phase ends the same way, because the next phase needs a session this one
cannot start:

```
Phase <name> complete. Handoff written to <path>.

  Next: /clear, then /orchestrator:next
```

Say nothing after it. Do not start the next phase, and do not offer to.

## Redo

`state.phase` names the phase that runs **next**, so re-running the phase that
just finished means stepping back one first. Order: `spec -> implement -> review -> done`.
What `redo` should do to a flow already part-way through a review loop is not
settled yet (issue #6); say so rather than inventing an answer.

1. Work out which phase actually produced the bad output, and say which one you
   are about to re-run.
2. List what that run created and still exists - a spec issue, a branch, a draft
   PR - and ask the user what to do with each. Never close or delete on your own.
3. `"$ORCH" state set phase <the earlier phase>`, then run it as under
   `/orchestrator:next`.

## Abort

1. Confirm with the user.
2. `"$ORCH" archive`.
3. Report what survives: the branch, the spec issue, and the PR are untouched, so
   list whichever exist and let the user clean up.

## Rules

- **One phase per session.** The context you accumulated is exactly what the next
  phase must not inherit.
- **One flow at a time.** `init` enforces it. For a second feature, use a second
  checkout.
- **Never merge.** The flow opens a draft PR and stops. Merging is the user's.
- **Never edit `.orchestrator/state.json` by hand.** Use `"$ORCH" state set`.
- If a phase cannot finish, leave the state where it is, say what blocked it, and
  offer `/orchestrator:abort` (which archives rather than deletes).

## Not yet built

Still to come: the `orchestrator:review-spec` reviewer (fidelity, testability,
consistency, implementability), which is why the spec phase asks the user to
review by hand.
