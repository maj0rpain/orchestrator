---
name: quick-implement
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

If `CLAUDE_PLUGIN_ROOT` is unset, it is `scripts/orch.sh` two directories above
this file.

## 1. Require a linked issue

Never proceed without one, and never decide silently whether to make one.

- A linked issue already exists (named earlier in this conversation, or on an
  already-checked-out branch): use it.
- Otherwise, publish one now, per `docs/agents/issue-tracker.md`'s "publish to
  the issue tracker" convention, with `"$ORCH" issue-publish "<title>"
  <body-file>` - the same boundary `review file` draws for a filed finding,
  kept out of skill prose - from the shared understanding just reached.
- If neither holds - no linked issue, and the tracker convention doc does not
  exist or `issue-publish` fails - stop and say why. A quick implementation
  with no issue behind it is exactly the unaccountable path this skill exists
  to avoid.

## 2. Publish the ticket breakdown

Unconditional, whether the linked issue was just published in step 1 or
already existed - never gated by a human choice, the same treatment the
flow's spec phase gives this same call. No `to-spec` step exists on this
path, so `to-tickets` synthesizes tickets directly off the raw linked issue -
it is the only spec this path has.

`to-tickets` carries `disable-model-invocation: true` in the installed
mattpocock-skills version, so the Skill tool cannot reach it. Resolve it with
`"$ORCH" mp-skill to-tickets`, read it, and follow it directly - the same
pattern `skills/flow/SKILL.md` uses for the same upstream skill.

Publish every ticket it proposes through `"$ORCH" ticket publish <parent>
<title> <body-file> [--blocked-by N,N,...]` against the linked issue as
`<parent>`, in dependency order (blockers first) - never an ad hoc `gh api`
call - so the verify-then-die guarantee `ticket publish` already provides
applies to every ticket, the same primitive and the same guarantee the
flow's spec phase uses.

## 3. Branch

Get the slug from `"$ORCH" slug "<short description>"` - the same
normalisation `orch.sh init` applies to a flow's slug, exposed as a primitive
rather than re-derived here - then `"$ORCH" branch-off "quick/<issue>-<slug>"`.
`branch-off` forks it off the default branch the same way a flow's own
`branch-create` does, but records no state - a quick implementation keeps
none.

## 4. Implement

Call the Skill tool with `mattpocock-skills:tdd` yourself - it carries no
`disable-model-invocation` flag, unlike `implement`. Build the issue as
written; it is the only spec this path has.

## 5. Review

Call the Skill tool with `mattpocock-skills:code-review` yourself - one plain,
single pass, never `orchestrator:review`'s multi-iteration loop. That loop's
budget and filed-findings machinery is exactly what a quick implementation is
choosing to skip. Fix what it finds before opening the PR.

Always spell the code review skill with its `mattpocock-skills:` scope - the
bare name is ambiguous with another `code-review` skill that may be installed
alongside this plugin, which reviews the current diff for correctness and
cleanup, not Standards + Spec fidelity to the issue that this step needs.

## 6. Open the PR

Commit, then open the PR with `"$ORCH" pr-publish <issue> "<title>"
<body-file>` - the same boundary `pr-open` draws for a flow, kept out of
skill prose. It pushes the branch, closes `<issue>`, and opens the PR against
the default branch, not as a draft: the single-pass review in step 5 already
happened, so there is no loop left to promote it - draft would leave it stuck
with nothing watching it.
