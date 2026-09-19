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

`to-spec`, `implement`, `handoff`, `to-tickets`, `wayfinder`, and
`improve-codebase-architecture` carry `disable-model-invocation: true`. The
Skill tool cannot reach them.

Their `SKILL.md` files are plain markdown. Resolve one with
`"$ORCH" mp-skill <name>`, read it, and follow its instructions verbatim - that
is exactly what the Skill tool would have injected. Never tell the user to type
the slash command themselves, and never claim to have invoked a skill you read.

`mattpocock-skills:code-review`, `tdd`, `research`, and `domain-modeling` have
no such flag; call those through the Skill tool normally. Always spell the
code review skill with its `mattpocock-skills:` scope - the bare name is
ambiguous with another `code-review` skill that may be installed alongside
this plugin.

## Starting a flow

Reached when a planning session's plan is approved. Runs in the planning session,
which holds the only copy of the plan.

1. Pick a slug from the plan's subject, kebab-case. If the user passed one as an
   argument (after pulling out any `--issue N`, per `commands/start.md`), use
   theirs. Confirm it in one line.
2. `"$ORCH" init <slug>`, or `"$ORCH" init <slug> --issue N` when the user (or
   `/orchestrator:start`'s own `--issue N`) named an already-open,
   already-triaged issue to adopt as the flow's spec instead of publishing a
   new one. `init` validates adoption immediately and dies if it cannot -
   report the failure and stop rather than continuing without an issue.
   Starting over a `done` flow archives it automatically and reports where -
   only a flow still mid-pipeline (`spec`/`implement`/`review`) refuses.
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

0. Check `"$ORCH" state get issue`. Non-empty means the flow adopted an issue
   at init - skip straight to step 4 below; steps 1-3 do not run, because the
   issue already exists and is already recorded. Empty means no `--issue` was
   given - run the phase from step 1, exactly as it does for every flow that
   has no adopted issue.
1. Read `"$ORCH" handoff path spec`. The **Rejected alternatives** section is
   load-bearing: do not re-propose anything it rules out.
2. Read and follow `"$ORCH" mp-skill to-spec`. It will check test seams with the
   user - that exchange is the point, so do not skip it.
3. Record the published issue: `"$ORCH" state set issue <number>`.
4. Call the Skill tool with `orchestrator:review-spec` and follow it. It owns
   the review - four lenses, one batch question, the body rewritten with what
   the human accepts - and returns the changelog. This step is part of the
   phase, not an option in it: no spec reaches the implement phase unreviewed,
   and the human's control is at the batch, where they may decline every edit.
5. Read and follow `"$ORCH" mp-skill to-tickets`, with the just-reviewed spec
   issue (`"$ORCH" state get issue`) as its source. Publish every ticket it
   proposes through `"$ORCH" ticket publish <parent> <title> <body-file>
   [--blocked-by N,N,...]`, in dependency order (blockers first) - never an
   ad hoc `gh api` call - so the verify-then-die behaviour `ticket publish`
   already provides applies to every ticket. This step is part of the phase,
   not an option in it, the same way the review above is not: no spec reaches
   the implement phase without its tickets published.
6. Call `orchestrator:handoff` for `02-spec.md`, with the changelog the review
   returned as its **Spec review changelog** and the spec issue number as its
   **Ticket breakdown**; validate it, then `"$ORCH" state set phase implement`.
7. Print the boundary.

### Phase: implement

1. Read `"$ORCH" handoff path implement` and fetch the spec issue it names.
2. `"$ORCH" branch-create` - creates `orch/<issue>-<slug>` off the default branch
   and records the base SHA the review will diff against.
3. Read and follow `"$ORCH" mp-skill implement`. `02-spec.md`'s **Seams**
   section *is* the confirmation `tdd` asks for: read it, state the seams in
   one line, and test at them. Ask about seams only when the code makes an
   agreed one impossible, and record that as a deviation in `03-implement.md`.
   Keep the closing `mattpocock-skills:code-review` step: it is the cheapest
   review in the pipeline, with full context and before anything is pushed.
   Capture what it found and fixed.
4. `"$ORCH" pr-open "<title>" <body-file>`. The PR opens as a draft; marking it
   ready is the review loop's success condition. `pr-open` itself writes the
   `Closes #<issue>` line ahead of the body - do not add a closing keyword of
   your own to the body file.
5. Call `orchestrator:handoff` for `03-implement.md`. Its **Deviations** section
   is what lets review tell an agreed change from scope creep - if there were no
   deviations, write "None", never leave it blank. Its **Verification** section is
   the command the review loop runs every iteration: record how you just ran the
   tests, because review takes it from here rather than guessing from the repo.
   Then validate it: `"$ORCH" handoff validate "$("$ORCH" handoff path review)"`.
6. `"$ORCH" state set phase review`, then print the boundary.

### Phase: review

1. `"$ORCH" doctor --flow`.
2. Call the Skill tool with `orchestrator:review` and follow it. It owns the
   loop; this file owns phase dispatch, and has nothing to add to a review
   beyond getting you there.

A flow may pass through this phase more than once. A loop that ends in a
bounded stop leaves `phase` at `review`, and a human who wants more looks runs
`/orchestrator:next` again: that is a fresh loop with its own budget, continuing
the flow's iteration numbering, and it reads `03-implement.md` like the first
one did.

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
just finished means stepping back one first. Only two directions are
supported - `review -> implement` and `implement -> spec` - each a mechanical
transition driven by `orch.sh`, not a per-artifact interview. Redo targeting
`phase: done` remains unsupported, exactly as today - it is not discussed by
the originating issue and is not expanded here.

**From `review`**: `"$ORCH" redo review`. It refuses unless the review loop
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
`state.branch`/`state.pr`/`state.base_sha` are cleared, `state.iteration`
resets to 0, `state.redo_count` increments, `flake_rerun_used` is left
untouched (`docs/adr/0007-redo-resets-the-review-loops-iteration-and-budget.md`),
and `state.phase` becomes `implement`.

**From `implement`**: ask the human once whether to keep the existing spec
issue and re-review it as-is (default), or publish a fresh one. Then call
`"$ORCH" redo spec` or `"$ORCH" redo spec --new-issue` accordingly. The
default path only changes `state.phase` to `spec` - the existing "adopted
issue" path through the spec phase's step 0 does the rest. `--new-issue`
additionally closes the old issue first (never deletes it) with a comment
explaining why, and clears `state.issue`, so `to-spec` runs again from
scratch.

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
