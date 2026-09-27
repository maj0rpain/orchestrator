---
name: orch-review-spec
description: Review a spec issue once through four independent lenses - Fidelity to the plan, Consistency with itself and the glossary, Testability at the agreed seams, Implementability from the issue alone - put every finding to the human as one batch of proposed edits, and rewrite the issue body with the edits they accept. Use from orch-flow's spec phase, after the issue exists - published by to-spec or already adopted at init - and before 02-spec.md is written. Also use standalone, outside any flow, when a human asks for a spec review of a given issue or runs /orchestrator:review-spec <issue>: three lenses, no plan handoff, and nothing written to flow state.
---

# Orchestrator spec review

One look at the spec, taken once. In a flow it comes after the issue exists -
published by `to-spec` or already adopted at init - and before the handoff is
written; a standalone review takes it on a given issue, outside any flow, and
writes no handoff. The **lenses** - four in a flow, three in a standalone
review - read the issue independently, as parallel sub-agents that see only
files. Every **finding** they report reaches the human as a proposed edit in
one batch; only the edits the human accepts change the issue. The issue body
stays the single truth the implement phase reads.

There is no budget, no second pass, and no "review the spec?" question: the
human's control is at the batch decision, where they may decline every edit.
The independence comes from the sub-agents, the same way it does for the review
loop - see `docs/adr/0001-review-loop-runs-in-a-single-session.md`.

There are two entries, and everything from **The lenses** through **The
changelog** is shared between them:

- **Inputs** - the spec-phase entry, from `orch-flow`'s spec phase. It works
  on the active flow's issue.
- **Standalone spec review** - a human asks for a review of a given issue,
  with `/orchestrator:review-spec <issue>` or in plain words, outside any
  flow. It belongs to no flow, leaves no handoff, and runs three lenses:
  Fidelity needs a plan and has none. Another look is another standalone
  review.

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

## Standalone spec review

The issue number comes from the human: the command's argument, or the issue
they named. With no number, ask for one and wait. Never take it from
`state.json` or the active flow.

1. **Begin**, before fetching: `bash "$ORCH" spec-review begin <issue>`. It
   prints the working directory, `<dir>` from here on, emptied for this run.
   If it dies, stop and relay its message - when an active flow holds this
   issue, the message names the command to run instead. This is the review's
   only read of `state.json`, and it goes through `orch.sh`.
2. **Fetch**: `bash "$ORCH" issue fetch <issue> <dir>/spec.md`. A failure
   stops the review: say what blocked it. There is no flow to abort,
   so do not offer `/orchestrator:abort`. The directory is left for
   inspection and wiped by the next run.
3. Resolve the glossary and decisions (`CONTEXT.md` and `docs/adr/` at the
   repo root, where they exist) and the repo root, as the spec-phase entry
   does. There is no plan handoff.

The standalone entry never calls `spec fetch`, `spec update`, `spec comment`,
or `handoff path`, never reads under `.orchestrator/handoff/`, and never
calls `gh issue` directly.

Then run **The lenses**, **Disposition**, and **Applying the answer** below,
with these differences:

- **Lenses**: start Consistency, Testability, and Implementability only.
  Fidelity is never started. It appears in the batch and the changelog as
  **not run - standalone review, no plan to check against**. That is not a
  failure, so the retry rule does not apply to it.
- **Disposition**: unchanged. There are no `contradicts the plan` items,
  because Fidelity does not run.
- **Applying**: see the standalone steps in **Applying the answer**.
- **Host fallbacks and lens failures** are recorded in the changelog
  comment only, under a **Host fallbacks** line. A standalone review has one
  changelog, not two.

## The lenses

Each lens is one of the plugin's agents, which owns its brief and the
reporting rules and may only read. Start all four at once (three in a
standalone review, without Fidelity) as fresh
subagents - never forks, which inherit this context. On Claude Code that is
the Agent tool with `subagent_type` set to the lens's agent name under the
`orchestrator:` plugin scope. Each prompt carries only the paths its row
names, and each lens returns its findings as its reply.

| Lens | Agent | Paths |
|---|---|---|
| Fidelity | `orch-lens-fidelity` | spec body, plan handoff |
| Consistency | `orch-lens-consistency` | spec body, glossary, ADR directory |
| Testability | `orch-lens-testability` | spec body, repo root |
| Implementability | `orch-lens-implementability` | spec body, repo root |

On a host that cannot start the plugin's agents natively, take the
"Start a fresh subagent" fallback in `docs/host-capabilities.md` under the
plugin root, with each lens's agent file, `agents/<agent>.md` under the
plugin root, as its brief, and record it in `02-spec.md` under **Host
fallbacks** (a standalone review records it in its changelog comment
instead).

A lens that errors or returns nothing usable is spawned once more with the
same prompt. A second failure makes it **not run - <reason>**: it appears that
way in the batch and in both changelogs (the one changelog, in a standalone
review), and the review continues on the
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

Each item carries a recommendation: a proposed edit is recommended for
applying unless it is marked **recommend decline** with its reason, and a
decision item carries its recommended option.

Number the items. Present the list - each item's finding, lens, and proposed
edit or decision - and ask **one blocking question** with the
`AskUserQuestion` tool (it exists on both Claude Code and Junie), the list and
the call in the same response. The review never ends its turn on the list:
presenting it is not the end of the step, the answer is. No edit is applied and
no changelog is posted before the answer arrives. The options:

- **Apply as recommended (Recommended)** - every proposed edit applied, every
  decision item takes its recommended option, every **recommend decline** item
  skipped. Always offered, first.
- **Apply all** - offered only when at least one item is marked **recommend
  decline**: as recommended, plus those items too. With no such item it would
  equal the first option, so it is not shown.
- **Apply none** - always offered.
- **Other** - item numbers, with the option letter on decision items, e.g.
  `1B, 2, 3, 5`. Any item left out is declined; a decision item left out stays
  undecided, and the changelog says so. The question text states this format.

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
   in the spec review and why. Declining it through **Apply as recommended** is
   allowed: the changelog records **spec departs from the plan: declined as
   recommended: <reason>**, and the amendment cites the same reason. The review loop demotes findings that
   propose a rejected alternative, and without the amendment it would later
   demote a code reviewer for proposing the spec's own choice.
4. Return the changelog to the flow skill: it goes verbatim into
   `02-spec.md`'s **Spec review changelog**, so the implement phase carries the
   disposition without a network call.

A standalone review applies through the stateless `issue` commands instead:

1. Apply the accepted edits to `<dir>/spec.md`, then
   `bash "$ORCH" issue update <issue> <dir>/spec.md`. Apply none: skip this
   step, as above.
2. Write the changelog to `<dir>/changelog.md` under a `## Spec review`
   heading, with Fidelity's **not run - standalone review, no plan to check
   against** line and any **Host fallbacks** line, and
   `bash "$ORCH" issue comment <issue> <dir>/changelog.md`. The comment is
   posted on Apply none too.

It never writes `state.json`, `.orchestrator/handoff/`, `02-spec.md`, or a
plan's **Rejected alternatives**, and returns nothing to a flow skill.

Nothing calls `gh issue edit` or `gh issue comment` directly: `orch.sh`'s
`spec` and `issue` commands are the one place body writes and comments
happen, and the one place they are tested.

## The changelog

Organised per lens, in the table's order, one heading each:

- an applied edit: one line naming what changed, not restating the body;
- a declined finding: the reviewer's finding **verbatim**, then the human's
  reason - a decision visible nowhere else is fully recorded, the same
  asymmetry the review loop applies to demoted findings. A finding declined
  because the human chose **Apply as recommended** records **declined as
  recommended: <the recommendation's reason>** instead of a human's reason;
- a decision item left out of an Other answer: each of its findings
  **verbatim**, then **left undecided**;
- a lens that found nothing: **None**;
- a lens that failed twice: **not run - <reason>**;
- in a standalone review, Fidelity: **not run - standalone review, no plan
  to check against**.

Silence is never ambiguous: every lens has a line.
