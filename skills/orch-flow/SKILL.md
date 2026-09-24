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

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root). Run
`"$ORCH" help` for the full command list. Never reimplement what it already
does.

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension).

## Host capabilities

Steps here name capabilities: invoke a skill, ask a multiple-choice question,
start a fresh subagent, start a fresh session. `docs/host-capabilities.md`
under the plugin root maps each one to your host. Where your host's cell says
**Fallback**, or **Unverified** and the capability turns out missing, take the
fallback it documents and record it in this phase's
handoff under **Host fallbacks**. Where this file offers the human an
`/orchestrator:<command>` and your host has no plugin commands, offer the
matching section of this skill instead.

## The upstream skills are not callable

`to-spec`, `implement`, `handoff`, `to-tickets`, `wayfinder`, and
`improve-codebase-architecture` carry `disable-model-invocation: true`, so
no host can invoke them as skills.

Their `SKILL.md` files are plain markdown. Resolve one with
`"$ORCH" mp-skill <name>`, read it, and follow its instructions verbatim - that
is exactly what invoking the skill would have injected. Never tell the user to type
the slash command themselves, and never claim to have invoked a skill you read.

`mattpocock-skills:code-review`, `tdd`, `research`, and `domain-modeling` have
no such flag; invoke those as skills (on Claude Code, the Skill tool). Always
spell the code review skill with its `mattpocock-skills:` scope - the bare
name is ambiguous with another `code-review` skill that may be installed
alongside this plugin. On a host with no scoped names, invoke it through
`"$ORCH" mp-skill code-review` for the same reason.

## Starting a flow

Reached when a planning session's plan is approved. Runs in the planning session,
which holds the only copy of the plan.

1. Read the user's arguments, if any (on Claude Code, `/orchestrator:start`'s):
   a slug, `--issue N`, both, or neither. Pull `--issue N` out first. Whatever
   remains is the slug; use it as given. With none left, pick a slug from the
   plan's subject, kebab-case. Confirm it in one line.
2. `"$ORCH" init <slug>`, or `"$ORCH" init <slug> --issue N` when the user (or
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
   `01-plan.md` template from `orchestrator:orch-handoff`, to
   `.scratch/orch-plan-<slug>.md`. `.scratch/` is on the planning allowlist, so
   the file never causes a refusal of its own. Tell the human where it is. Once
   they have fixed what `init` reported, rerun from step 2, in this session or a
   fresh one given that file.
3. Invoke `orchestrator:orch-handoff` to write `01-plan.md`, from this session's
   plan or from the `.scratch/orch-plan-<slug>.md` step 2 saved. **Do
   this before anything else that can fail.** `init` is the one check that runs
   first, because it creates the directory the handoff goes in.
4. `"$ORCH" handoff validate "$("$ORCH" handoff path spec)"`. Fix and re-validate
   until it passes.
5. `"$ORCH" doctor --env`. Report its output; stop only on a non-zero exit. A
   `warn` is an observation the user should see, not a reason to cost them a
   restart - the plan is already safe on disk either way.
6. Print the boundary (see below).

## Next phase

Reached by `/orchestrator:next`, or when the user asks to run the flow's next
phase. Run it in a fresh session: if the context still holds the previous
phase, tell the user to start a fresh session (Claude Code `/clear`, Junie
`/new`) and stop rather than continuing.

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
4. Invoke `orchestrator:orch-review-spec` and follow it. It owns
   the review - four lenses, one batch question, the body rewritten with what
   the human accepts - and returns the changelog. This step is part of the
   phase, not an option in it: no spec reaches the implement phase unreviewed,
   and the human's control is at the batch, where they may decline every edit.
5. Read and follow `"$ORCH" mp-skill to-tickets`, with the just-reviewed spec
   issue (`"$ORCH" state get issue`) as its source, through its own quiz
   (steps 1-4) until the user approves a breakdown.

   **A breakdown of 2 or more tickets** publishes exactly as today: publish
   every ticket it proposes through `"$ORCH" ticket publish <parent> <title>
   <body-file> [--blocked-by N,N,...]`, in dependency order (blockers first)
   - never an ad hoc `gh api` call - so the verify-then-die behaviour
   `ticket publish` already provides applies to every ticket. This step is
   part of the phase, not an option in it, the same way the review above is
   not: no spec reaches the implement phase without its tickets published.

   **A breakdown of 0 or 1 tickets collapses**: skip `to-tickets`' own
   publish step entirely - no child sub-issue is created, and the spec issue
   is worked directly, as if it were the sole ticket. This is the
   orchestrator's own deliberate, narrowly-scoped exception to `to-tickets`'
   "do NOT close or modify any parent issue" instruction - not something
   `to-tickets` itself does, taken here where this phase already calls its
   publish step, and reached only in this collapsed case. Fetch the spec
   issue's current body (`"$ORCH" spec fetch <file>`), append a new section
   wrapping the single drafted ticket's "What to build"/"Acceptance
   criteria" (when there is one) beneath the existing content - never
   replacing it - and write the merged body back (`"$ORCH" spec update
   <file>`).
6. Invoke `orchestrator:orch-handoff` for `02-spec.md`, with the changelog the review
   returned as its **Spec review changelog**, and its **Ticket breakdown** as
   either the spec issue number (a published breakdown) or `None: work
   directly against #<n>` naming the spec issue (a collapsed one, per step
   5); validate it, then `"$ORCH" state set phase implement`.
7. Print the boundary.

### Phase: implement

1. Read `"$ORCH" handoff path implement` and fetch the spec issue it names.
2. `"$ORCH" branch create` - creates `orch/<issue>-<slug>` off the default branch
   and records the base SHA the review will diff against.
3. Read the handoff's **Ticket breakdown** section, written by the spec
   phase's step 5.

   **`None: work directly against #<n>`** means that breakdown collapsed to
   0 or 1 tickets and published no sub-issue - `<n>` names the spec issue
   itself. No `ticket next`/`ticket close` loop runs against it: an empty
   frontier there means nothing was ever split out, not "already done."
   Dispatch exactly one subagent (below), briefed with `<n>`, then continue
   at step 4.

   **Any other content** names the spec issue as a parent whose GitHub
   sub-issues carry the real tickets. Work its frontier, one ticket at a
   time, never in parallel - every ticket commits to the same branch. Loop:
   - `"$ORCH" ticket next <spec issue>`. Nothing ready means the frontier is
     exhausted - stop looping and continue at step 4.
   - Dispatch a subagent (below), briefed with the ticket's number.
   - Record the subagent's report, then `"$ORCH" ticket close <n>` - only now
     that the report is back, never before - and go around again.

   **Dispatching a subagent**: start a fresh subagent (on Claude Code, the
   Agent tool as a fresh agent, explicitly not a fork), so it starts with
   nothing but what this brief hands it, carrying only the issue number
   named above. Without one, take the documented fallback. The brief's directions
   open with an explicit first instruction: fetch the ticket itself (`gh
   issue view <n> --comments`, per `docs/agents/issue-tracker.md`'s "fetch
   the relevant ticket" convention) before doing anything else. The brief
   then directs the subagent to resolve and follow `"$ORCH" mp-skill
   implement` itself, the same way this file resolves any upstream skill,
   against the ticket - and, when `implement`'s closing step calls for a
   review, to use `mattpocock-skills:code-review` by its fully scoped name,
   never the bare name, the same disambiguation this file observes above; to
   build on the current branch, already checked out, and commit its own
   work to it; to never open a branch or PR of its own; and to never block
   on a human mid-ticket - a call it cannot make alone is a deviation,
   recorded and returned instead of asked. The brief adds file-read
   discipline: never re-read a file already read in full this session -
   grep for the next location and jump there instead of re-reading it
   wholesale; and on a wide-blast-radius ticket (a rename, a grammar
   change, anything touching many call sites), run one `grep -rn` pass up
   front to build a complete reference list, then work that list with
   targeted reads and edits, never re-scanning the same files afterward.
   Its report is structured: what it built, and the deviation it made,
   if any.
4. `"$ORCH" pr open "<title>" <body-file>`. The PR opens as a draft; marking it
   ready is the review loop's success condition. `pr open` itself writes the
   `Closes #<issue>` line ahead of the body - do not add a closing keyword of
   your own to the body file.
5. Invoke `orchestrator:orch-handoff` for `03-implement.md`. Its **Deviations** section
   is assembled from every ticket's report, one bullet per ticket that returned
   one, naming the ticket - "None" only if not one ticket reported a deviation,
   never left blank. Its **Verification** section is the command the review loop
   runs every iteration: record how you just ran the tests, because review takes
   it from here rather than guessing from the repo.
   Then validate it: `"$ORCH" handoff validate "$("$ORCH" handoff path review)"`.
6. `"$ORCH" state set phase review`, then print the boundary.

### Phase: review

1. `"$ORCH" doctor --flow`.
2. Invoke `orchestrator:orch-review` and follow it. It owns the
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

  Next: <fresh session>, then <next phase>
```

On Claude Code that line reads `Next: /clear, then /orchestrator:next`. On
Junie it reads `Next: /new, then ask for the next phase with /orch-flow`.

Say nothing after it. Do not start the next phase, and do not offer to.

## Status

Reached by `/orchestrator:status`, or when the user asks where the flow
stands. Run `"$ORCH" status` and `"$ORCH" doctor --flow`, and report both
outputs. Read-only: do not start, advance, or repair a flow from here. If
`doctor` reports a problem, say what it found and stop.

## Doctor

Reached by `/orchestrator:doctor`, or when the user asks to diagnose the
machine, the repo, or the flow. Run `"$ORCH" doctor` and report its output.
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
