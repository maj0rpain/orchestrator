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

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Steps here name capabilities (invoke a skill, start a fresh subagent).
`docs/host-capabilities.md` under the plugin root maps each one to your host.
Where your host's cell says **Fallback**, or **Unverified** and the capability
turns out missing, take the fallback it documents and list it under a **Host fallbacks** heading in the PR body (step 6).

## 1. Require a linked issue

Never proceed without one, and never decide silently whether to make one.

- A linked issue already exists (named earlier in this conversation, or on an
  already-checked-out branch): use it.
- Otherwise, publish one now, per `docs/agents/issue-tracker.md`'s "publish to
  the issue tracker" convention, with `bash "$ORCH" issue publish "<title>"
  <body-file>` - the same boundary `review file` draws for a filed finding,
  kept out of skill prose - from the shared understanding just reached.
- If neither holds - no linked issue, and the tracker convention doc does not
  exist or `issue publish` fails - stop and say why. A quick implementation
  with no issue behind it is exactly the unaccountable path this skill exists
  to avoid.

## 2. Publish the ticket breakdown

Unconditional, whether the linked issue was just published in step 1 or
already existed - never gated by a human choice, the same treatment the
flow's spec phase gives this same call. No `to-spec` step exists on this
path, so `to-tickets` synthesizes tickets directly off the raw linked issue -
it is the only spec this path has.

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
exists to record anywhere; step 4 below works the linked issue directly.

## 3. Branch

Get the slug from `bash "$ORCH" slug "<short description>"` - the same
normalisation `orch.sh init` applies to a flow's slug, exposed as a primitive
rather than re-derived here - then `bash "$ORCH" branch off "quick/<issue>-<slug>"`.
`branch off` forks it off the base branch (`bash "$ORCH" base show`) the same way
a flow's own `branch create` does, but records no flow state - a quick
implementation keeps none. It records that base branch on the branch itself,
so the PR in step 6 targets it even if the setting changes meanwhile.

## 4. Implement

If step 2 collapsed (0 or 1 tickets, no sub-issue published): no `ticket
next`/`ticket close` loop runs against the linked issue - dispatch exactly
one subagent (below), briefed with the linked issue's own number, then
continue at step 5.

Otherwise, work the linked issue's ticket frontier, one ticket at a time,
never in parallel - every ticket commits to the same branch. Loop:

- `bash "$ORCH" ticket next <linked issue>`. Nothing ready means the frontier is
  exhausted - stop looping and continue at step 5.
- Dispatch a subagent (below), briefed with the ticket's number.
- Record the subagent's report, then `bash "$ORCH" ticket close <n>` - only now
  that the report is back, never before - and go around again.

**Dispatching a subagent**: start the plugin's `orch-implementer` agent
(under the plugin root's `agents/`) as a fresh subagent, never a fork - on
Claude Code, the Agent tool with `subagent_type` set to
`orch-implementer` under the `orchestrator:` plugin scope.
Its prompt is the issue number named above and nothing else; the agent owns
its brief. It returns five lines: `Ticket`, `Commits`, `Verification`,
`Criteria`, `Deviation`. On a host that does not load the plugin's
`agents/`, take `docs/host-capabilities.md`'s **Start a fresh subagent**
fallback: do the ticket's work yourself, in this session, following
`agents/orch-implementer.md` as your brief, and list the fallback under the
PR body's **Host fallbacks**.

## 5. Review

Invoke `mattpocock-skills:code-review` yourself - one plain,
single pass, never the `orch-review` skill's multi-iteration loop. That loop's
budget and filed-findings machinery is exactly what a quick implementation is
choosing to skip. Fix what it finds before opening the PR.

Always spell the code review skill with its `mattpocock-skills:` scope - the
bare name is ambiguous with another `code-review` skill that may be installed
alongside this plugin, which reviews the current diff for correctness and
cleanup, not Standards + Spec fidelity to the issue that this step needs. On
a host with no scoped names, invoke it through `bash "$ORCH" mp-skill code-review`
for the same reason.

## 6. Open the PR

Commit, then open the PR with `bash "$ORCH" pr publish <issue> "<title>"
<body-file>` - the same boundary `pr open` draws for a flow, kept out of
skill prose. The body ends with a **Host fallbacks** heading listing every
fallback this run took, or `None (<host>).` It pushes the branch and opens the PR against
the base branch `branch off` recorded, not as a draft. The body starts with
`Closes #<issue>` when that base branch is the default branch, and `Refs
#<issue>` otherwise - the issue closes when the release PR carries the work
into the default branch (the `orch-release` skill). Either way `pr publish`
writes that line, so the body file carries no closing keyword of its own.
Not a draft because the single-pass review in step 5 already
happened, so there is no loop left to promote it - draft would leave it stuck
with nothing watching it.
