---
name: orch-quick-implement
description: Implement a small, already-understood change directly, skipping the plan/spec/implement/review pipeline. Reached when a human picks "quick implementation" at hook-grilling.sh's closing question, or is invoked directly for work that plainly does not need the full flow. Still requires a linked issue, a published ticket breakdown, test-driven implementation, and a single-pass review before the PR opens.
---

# Orchestrator quick implementation

The other route from an approved plan to a pull request, alongside a flow -
see `CONTEXT.md`'s **Quick implementation** entry and
`docs/adr/0006-quick-implementation-unblocks-the-edit-guard-by-deleting-the-planning-marker.md`.
A thin router, not a second pipeline: no phases, no handoff, no
`.orchestrator/state.json`. What it does not skip is this project's standard
for how a change gets made - test-driven, reviewed, then opened as a PR.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Steps here name capabilities (invoke a skill, start a fresh subagent).
`docs/host-capabilities.md` under the plugin root maps each one to your host.
Where your host's cell says **Fallback**, or **Unverified** and the capability
turns out missing, take the fallback it documents and list it under a **Host fallbacks** heading in the PR body (step 7).

## 1. Require a linked issue

Never proceed without one, and never decide silently whether to make one.

- A linked issue already exists (named earlier in this conversation, or on an
  already-checked-out branch): use it.
- Otherwise, publish one now, per `docs/agents/issue-tracker.md`'s "publish to
  the issue tracker" convention, with `bash "$ORCH" issue publish "<title>"
  <body-file>` - the same boundary `review file` draws for a filed finding,
  kept out of skill prose - from the shared understanding just reached.
- Either way, a glossary or ADR change (`CONTEXT.md`, `CONTEXT-MAP.md`,
  `docs/adr/`) the planning session decided goes into the linked issue's body
  word for word - the new or replaced text, naming the file and entry - never
  into those files during planning. It lands with the change it describes
  (ADR-0022). The standalone spec review in step 2 runs no Fidelity lens, so
  nothing else checks the wording survived.
- If neither holds - no linked issue, and the tracker convention doc does not
  exist or `issue publish` fails - stop and say why. A quick implementation
  with no issue behind it is exactly the unaccountable path this skill exists
  to avoid.

## 2. Offer a spec review

Ask on every run, whether the linked issue was just published in step 1 or
already existed - never skip the question because the issue looks reviewed
already. Ask one `AskUserQuestion` (`ask_user` on Junie) with exactly two
options:

- **Run a spec review (Recommended)** - review the linked issue before its
  ticket breakdown.
- **Skip** - go straight to the ticket breakdown.

**Run**: invoke the `orch-spec-review` skill and follow its **Standalone spec
review** entry on the linked issue through to its end, unchanged - the same
review a human gets on demand: `spec-review begin <issue>`,
three lenses with Fidelity recorded as not run, one batch question, the
accepted edits written back to the issue body, and the changelog posted as an
issue comment. There is no quick-specific variant: Fidelity does not run, and
no plan file is written. If the review stops - the guard refuses, or a fetch
or write fails - quick implementation stops too: relay the review's message
and do not go on to step 3. Note every host fallback the review takes, and
list it under the PR body's **Host fallbacks** in step 7 as well as in the
review's changelog comment. Failed lenses stay in the changelog only.

**Skip**: record nothing anywhere, and continue at step 3.

## 3. Publish the ticket breakdown

Unconditional, whether the linked issue was just published in step 1 or
already existed, and whichever answer step 2 got - never gated by a human
choice of its own, the same treatment the flow's spec phase gives this same
call. No `to-spec` step exists on this path, so `to-tickets` synthesizes
tickets directly off the linked issue as it stands after any spec review in
step 2 - it is the only spec this path has.

`to-tickets` carries `disable-model-invocation: true` in the installed
mattpocock-skills version, so Claude Code's Skill tool refuses it, and Junie
gives the model no Skill tool at all. Resolve it with
`bash "$ORCH" mp-skill to-tickets`, read it, and follow it directly - the same
pattern `skills/orch-flow/SKILL.md` uses for the same upstream skill. Follow it
through its own quiz (steps 1-4) until the user approves a breakdown.

**A breakdown of 2 or more tickets** publishes exactly as today: publish
every ticket it proposes through `bash "$ORCH" ticket publish <parent> <title>
<body-file> [--blocked-by N,N,...]` against the linked issue as `<parent>`,
in dependency order (blockers first) - never an ad hoc `gh api` call - so the
verify-then-die guarantee `ticket publish` already provides applies to every
ticket, the same primitive and the same guarantee the flow's spec phase uses.

**A breakdown of 0 or 1 tickets collapses**: skip `to-tickets`' own publish
step entirely - no child sub-issue is created, and the linked issue is
worked directly, as if it were the sole ticket. This is the orchestrator's
own deliberate, narrowly-scoped exception to `to-tickets`' "do NOT close or
modify any parent issue" instruction - not something `to-tickets` itself
does, taken here where this step already calls its publish step, and
reached only in this collapsed case. Fetch the linked issue's current body
(`bash "$ORCH" issue fetch <issue> <file>`), append a new section wrapping the
single drafted ticket's "What to build"/"Acceptance criteria" (when there is
one) beneath the existing content - never replacing it - and write the
merged body back (`bash "$ORCH" issue update <issue> <file>`). No sub-issue
exists to record anywhere; step 5 below works the linked issue directly.

## 4. Branch

Get the slug from `bash "$ORCH" slug "<short description>"` - the same
normalisation `orch.sh init` applies to a flow's slug, exposed as a primitive
rather than re-derived here - then `bash "$ORCH" branch off "quick/<issue>-<slug>"`.
`branch off` forks it off the base branch (`bash "$ORCH" base show`) the same way
a flow's own `branch create` does, but records no flow state - a quick
implementation keeps none. It records that base branch on the branch itself,
so the PR in step 7 targets it even if the setting changes meanwhile.

## 5. Implement

If step 3 collapsed (0 or 1 tickets, no sub-issue published): no `ticket
next`/`ticket close` loop runs against the linked issue - dispatch exactly
one subagent (below), for the linked issue itself as the ticket, then
continue at step 6.

Otherwise, work the linked issue's ticket frontier, one ticket at a time,
never in parallel - every ticket commits to the same branch. Loop:

- `bash "$ORCH" ticket next <linked issue>`. Nothing ready means the frontier is
  exhausted - stop looping and continue at step 6.
- Dispatch a subagent (below) for the ticket.
- Record the subagent's report, then `bash "$ORCH" ticket close <n>` - only now
  that the report is back, never before - and go around again.

**Dispatching a subagent**: start the plugin's `orch-implementer` agent
exactly as the **Starting this agent** section of
`agents/orch-implementer.md` (under the plugin root) says, for the ticket
named above. On Claude Code it is the agent named
`orch-implementer` under the `orchestrator:` plugin scope. A host that
cannot start it natively takes `docs/host-capabilities.md`'s **Start a fresh
subagent** fallback; list it under the PR body's **Host fallbacks**, along
with any fallback that section says the agent takes.

## 6. Review

One pass, never the `orch-review` skill's multi-iteration loop - that loop's
budget, severity triage and filed-findings machinery is exactly what a quick
implementation is choosing to skip. The pass starts the same two plugin agents
the loop does, under the plugin root's `agents/`:

- **`orch-reviewer-standards`** - the Standards axis: the repo's documented
  coding standards, plus the plugin's own smell baseline.
- **`orch-reviewer-spec`** - the Spec axis: whether the change implements what
  the linked issue asked for.

Get the base SHA with `bash "$ORCH" branch base-sha` - the base branch's tip
that `branch off` recorded in step 4 - and the report directory with
`bash "$ORCH" quick path`. Start both reviewers at once, as fresh agents,
never forks, both in one message. On Claude Code each is the agent of that
name under the `orchestrator:` plugin scope. Each prompt carries these four
variables and nothing else - no issue body, no diff, no brief:

```
Base SHA: <recorded base SHA>
Spec issue: #<linked issue>
Iteration: 01
Report path: <quick report dir>/iteration-01-<standards|spec>.md
```

Each reviewer fetches the diff and the issue itself, writes its findings there
unranked, each with its file, line, and claim, and returns one line naming its
report and its finding count. A missing report, or one that says the base SHA
did not resolve or the diff was empty, is a failed review, not a clean one.
Start that reviewer again once. If it fails a second time, stop before opening
the PR and tell the human which axis failed: this skill promises a review
before the PR, so it never opens one with an axis unreviewed.

Read both reports and fix, yourself, every finding you agree with - no fixer
agent, no severity, nothing filed. Commit the fixes. Each finding you decline
goes under a **Review** heading in the PR body (step 7), one line each: the
finding's `file:line` - or `-` when the report gave `-` for its location - and
your reason for declining it. If you declined none, the heading says
`None declined.`

A host that cannot start the reviewers natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback, with the
prompt above, the same as the loop; list it under the PR body's **Host
fallbacks**.

## 7. Open the PR

Commit, then open the PR with `bash "$ORCH" pr publish <issue> "<title>"
<body-file>` - the same boundary `pr open` draws for a flow, kept out of
skill prose. The body carries a **Review** heading listing every finding
step 6 declined, with its location and reason, or `None declined.` It ends
with a **Host fallbacks** heading listing every fallback this run took -
including any the spec review in step 2 took - or `None (<host>).` It
pushes the branch and opens the PR against the base branch `branch off`
recorded, not as a draft. The body starts with `Closes #<issue>` when that
base branch is the default branch, and `Refs #<issue>` otherwise - the
issue closes when the release PR carries the work into the default branch
(the `orch-release` skill). Either way `pr publish` writes that line, so the
body file carries no closing keyword of its own. Not a draft because the
single-pass review in step 6 already happened, so there is no loop left to
promote it - draft would leave it stuck with nothing watching it.
