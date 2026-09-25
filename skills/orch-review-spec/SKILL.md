---
name: orch-review-spec
description: Review a spec issue once through four independent lenses - Fidelity to the plan, Consistency with itself and the glossary, Testability at the agreed seams, Implementability from the issue alone - put every finding to the human as one batch of proposed edits, and rewrite the issue body with the edits they accept. Use from orch-flow's spec phase, after the issue exists - published by to-spec or already adopted at init - and before 02-spec.md is written.
---

# Orchestrator spec review

One look at the spec, taken once, after the issue exists - published by
`to-spec` or already adopted at init - and before the handoff is written. Four
**lenses** read the issue independently, as parallel sub-agents that see only
files. Every **finding** they report reaches the human as a proposed edit in
one batch; only the edits the human accepts change the issue. The issue body
stays the single truth the implement phase reads.

There is no budget, no second pass, and no "review the spec?" question: the
human's control is at the batch decision, where they may decline every edit.
The independence comes from the sub-agents, the same way it does for the review
loop - see `docs/adr/0001-review-loop-runs-in-a-single-session.md`.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

## Inputs

1. Fetch the body: `bash "$ORCH" spec fetch <dir>/spec.md`, with `<dir>` a fresh
   directory under `.orchestrator/` - `spec fetch` creates it. It reads the
   issue number from state. A failure stops the phase: state stays where it
   is, say what blocked, offer `/orchestrator:abort` (on a host with
   no plugin commands, `orch-flow`'s **Abort** section). A review with no
   body to review is never claimed as done.
2. Resolve the other files the lenses read, and record the paths:
   - the plan handoff: `bash "$ORCH" handoff path spec` (always `01-plan.md`);
   - the glossary and decisions: `CONTEXT.md` and `docs/adr/` at the repo
     root, where they exist;
   - the repo root, for the codebase.

Nothing from this session's conversation reaches a lens: not the plan as you
remember it, not `to-spec`'s reasoning, not the seams as agreed in chat. A lens
that needs something gets a file path.

## The lenses

Start all four at once as fresh subagents (on Claude Code, the Agent tool
as fresh general-purpose agents) - never forks, which inherit this context.
On a host without fresh subagents, take the fallback in
`docs/host-capabilities.md` under the plugin root, running the lenses one at
a time from their briefs alone, and record it in `02-spec.md` under **Host
fallbacks**. Each prompt carries only the paths its
row names, the brief below, and the reporting rules:

> Report findings only, never draft edits. Quote the spec line for every
> finding. Under 400 words. Report "no findings" if there are none.

| Lens | Reads |
|---|---|
| Fidelity | spec body, plan handoff |
| Consistency | spec body, glossary, ADR directory |
| Testability | spec body, repo root |
| Implementability | spec body, repo root |

**Fidelity brief.** "The plan handoff records what a human decided; the spec
is what got written. Report: (a) every decision or constraint in the plan
that the spec dropped or altered; (b) anything the plan's
**Rejected alternatives** ruled out that the spec re-proposes, by whatever
route it got there - label each of these `contradicts the plan`."

**Consistency brief.** "Report where the spec disagrees with itself - user
stories against Implementation Decisions against Out of Scope - and where it
uses a term differently from the glossary or contradicts a recorded decision in
the ADRs. Quote both sides of every disagreement."

**Testability brief.** "The seams are the public boundaries the spec's
**Testing Decisions** section names; the repo's existing tests are prior art
for what those seams can observe. Report: (a) every user story or
Implementation Decision that cannot be proven at those seams; (b) if the
section names no seams, or names them too loosely to say what a test would
observe, report that as a finding in its own right."

**Implementability brief.** "You are a fresh session with only this issue and
the repo. Report: (a) every decision that needs context the issue does not
carry - a name, a shape, a reason that must have lived in a conversation; (b)
every decision the codebase makes impossible as written, quoting the code that
makes it so."

A lens that errors or returns nothing usable is spawned once more with the
same prompt. A second failure makes it **not run - <reason>**: it appears that
way in the batch and in both changelogs, and the review continues on the
lenses that answered. Three lenses and a recorded gap is a spec review; a
silent gap is not.

Keep the findings under a heading per lens. They are never merged, ranked, or
deduplicated across lenses: the separation is what the lenses exist for.

## Disposition

Draft one proposed edit per finding - concrete replacement text for the body,
never a description of the problem. Then, with the whole batch in view:

- One edit that satisfies several findings is proposed once, naming every
  finding it resolves.
- Two findings that cannot both hold - a Fidelity "the plan decided X" against
  an Implementability "the codebase cannot do X" - become a **decision** item:
  both findings side by side, the consequence of each option, and your
  recommendation. The human makes the planning call.
- A finding you believe is wrong is still presented, marked **recommend
  decline** with the reason. You have no recorded human decision to demote on,
  so nothing is dropped silently.
- A Fidelity finding labelled `contradicts the plan` goes **first**, under
  that label: the human sees a reversal of their own earlier decision before
  anything else.

Number the items. Present the list - each item's finding, lens, and proposed
edit or decision - then ask **one blocking question** with the
`AskUserQuestion` tool: options **Apply all**, **Apply none**, or a list of
item numbers through Other (the tool exists on both Claude Code and Junie).
Asked once; a long spec is one longer question, not twenty prompts.

## Applying the answer

1. Apply the accepted edits to `<dir>/spec.md`, then
   `bash "$ORCH" spec update <dir>/spec.md`. The body is rewritten in place; the
   implement phase reads one body and reconciles nothing. Apply none: skip
   this step - an update that writes the body it just read is a no-op edit on
   the issue's history, and the comment in step 2 still records the decision.
2. Write the changelog - see below - to `<dir>/changelog.md` under a
   `## Spec review` heading and `bash "$ORCH" spec comment <dir>/changelog.md`. The
   comment is history, visible on the issue; the body is the truth.
3. A declined `contradicts the plan` item: the changelog records **spec
   departs from the plan: <the human's reason>**, and the matching entry in the
   plan handoff's **Rejected alternatives** is amended to say it was reversed
   in the spec review and why. The review loop demotes findings that propose a
   rejected alternative, and without the amendment it would later demote a
   code reviewer for proposing the spec's own choice.
4. Return the changelog to the flow skill: it goes verbatim into
   `02-spec.md`'s **Spec review changelog**, so the implement phase carries the
   disposition without a network call.

Nothing calls `gh issue edit` or `gh issue comment` directly: the three
`spec` commands are the one place body writes happen, and the one place they
are tested.

## The changelog

Organised per lens, in the table's order, one heading each:

- an applied edit: one line naming what changed, not restating the body;
- a declined finding: the reviewer's finding **verbatim**, then the human's
  reason - a decision visible nowhere else is fully recorded, the same
  asymmetry the review loop applies to demoted findings;
- a lens that found nothing: **None**;
- a lens that failed twice: **not run - <reason>**.

Silence is never ambiguous: every lens has a line.
