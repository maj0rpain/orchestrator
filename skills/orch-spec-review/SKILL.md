---
name: orch-spec-review
description: Review a spec issue once - propose folding into its body what its comments say that the body does not, then read body and comments through four independent lenses - Fidelity to the plan, Consistency with itself and the glossary, Testability at the agreed seams, Implementability from the issue alone - put every finding to the human as one batch of proposed edits, and rewrite the issue body with the edits they accept; when those edits touch an open ticket of an existing ticket breakdown, ask a second question - edit the tickets the change touches, or retire the breakdown so the issue is broken down again. Use from orch-flow's spec phase, after the issue exists - published by the spec phase or already adopted at init - and before 02-spec.md is written. Also use standalone, outside any flow, when a human asks for a spec review of a given issue or runs /orchestrator:spec-review <issue>: three lenses, no plan handoff, and nothing written to flow state. A quick implementation runs the standalone review unattended, applying its own recommendations without asking.
---

# Orchestrator spec review

One look at the spec, taken once. In a flow it comes after the issue exists -
published by the spec phase or already adopted at init - and before the handoff is
written; a standalone review takes it on a given issue, outside any flow, and
writes no handoff. First, the session running the review proposes folding
into the body whatever the issue's comments say that the body does not - see
**Consolidation**. The **lenses** - four in a flow, three in a standalone
review - then read the issue, body and comments, independently, as parallel
sub-agents that see only files. Every consolidation item and every **finding**
they report reaches the human as a proposed edit in one batch; only the edits
the human accepts change the issue - in an **Unattended spec review**, the
recommended ones. When the issue already has a ticket
breakdown and the accepted edits touch an open ticket, a second question asks
how the breakdown should follow - see **Tickets follow the spec**; the review
writes the issue's tickets only to follow edits already accepted. The issue body stays the single truth the
implement phase reads; after a review, the comments are history.

There is no budget and no second pass. In a flow's spec phase there is also
no "review the spec?" question: the human's control is at the batch decision,
where they may decline every edit. A quick implementation asks no question
at all: it takes the standalone entry's **Unattended spec review** mode, which
applies its own recommendations - see that section.
The independence comes from the sub-agents, the same way it does for the review
loop - see `docs/adr/0001-review-loop-runs-in-a-single-session.md`.

There are two entries, and everything from **Consolidation** through **The
changelog** is shared between them:

- **Inputs** - the spec-phase entry, from `orch-flow`'s spec phase. It works
  on the active flow's issue.
- **Standalone spec review** - a human asks for a review of a given issue,
  with `/orchestrator:spec-review <issue>` or in plain words, outside any
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
2. Fetch the comments: `bash "$ORCH" spec comments <dir>/comments.md`, in the
   same directory. It reads the issue number from state, and writes an empty
   file when the issue has no comments. A failure stops the phase exactly as
   a failed body fetch does: the lenses would otherwise review half the spec.
3. Resolve the other files the lenses read, and record the paths:
   - the plan handoff: `bash "$ORCH" handoff path spec` (always `01-plan.md`);
   - the glossary and decisions: `GLOSSARY.md` and `docs/adr/` at the repo
     root, where they exist;
   - the repo root, for the codebase.

Nothing from this session's conversation reaches a lens: not the plan as you
remember it, not `orch-to-spec`'s reasoning, not the seams as agreed in chat. A lens
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
3. **Fetch the comments**: `bash "$ORCH" issue comments <issue>
   <dir>/comments.md`. A failure stops the review, as a failed body fetch
   does.
4. Resolve the glossary and decisions (`GLOSSARY.md` and `docs/adr/` at the
   repo root, where they exist) and the repo root, as the spec-phase entry
   does. There is no plan handoff.

The standalone entry never calls `spec fetch`, `spec comments`, `spec update`,
`spec comment`, or `handoff path`, never reads under `.orchestrator/handoff/`,
and never calls `gh issue` directly.

Then run **Consolidation**, **The lenses**, **Disposition**, and **Applying
the answer** below, with these differences:

- **Lenses**: start Consistency, Testability, and Implementability only.
  Fidelity is never started. It appears in the batch and the changelog with
  Fidelity's not-run line, as in **The changelog**. That is not a failure,
  so the retry rule does not apply to it.
- **Disposition**: unchanged. There are no `contradicts the plan` items,
  because Fidelity does not run.
- **Applying**: see the standalone steps in **Applying the answer**.
- **Host fallbacks and lens failures**: among the review's own records, they
  are recorded in the changelog comment only, under a **Host fallbacks**
  line. A standalone review has one changelog, not two. A quick
  implementation that runs the review in the same session also lists the
  host fallbacks it saw in its own PR body.

### Unattended spec review

The mode a quick implementation takes, and only a quick implementation: a
standalone spec review that asks the human nothing (ADR-0034). It is the one
definition of the mode - quick implementation's own steps never restate its
rules. Everything in **Standalone spec review** above holds, with these
differences only:

- **Consolidation and the lenses** run unchanged: Consistency, Testability
  and Implementability, with Fidelity not run.
- **Disposition**: the batch is drafted, numbered and printed in the session
  as usual, so a human watching can see what is applied and interrupt. Then
  no question is asked and nothing waits: the batch is applied at once as
  **Apply as recommended** - every proposed edit applied, every **recommend
  decline** item skipped, and every decision item takes its recommended
  option.
- **Tickets follow the spec** runs as usual, its items printed, but takes its
  recommended option without asking: **Apply as recommended**, or **Retire
  and break down again** when that is the recommendation.
- **Applying**: the standalone steps in **Applying the answer**, unchanged
  except step 4: a retire is followed by `orch-to-tickets`' **Unattended
  breakdown**, never its quiz.
- **The changelog** opens, ahead of its Consolidation section, with exactly
  this line:

  ```
  Unattended spec review, run from a quick implementation: applied as recommended.
  ```

  Each decision item taken records, under its lens or under Consolidation,
  one line `decision (<n>): took <letter> - <option>, as recommended`, with
  `<n>` the item's number in the batch. A quick implementation lists those
  lines in its PR body. Declined items record **declined as recommended:
  <reason>**, as in **The changelog**. An attended review's changelog has
  no opening line and is unchanged.
- **Failures** are unchanged: a guard refusal, a failed fetch or a failed
  write stops the review, and the quick implementation that ran it with it.

## Consolidation

Spec content often arrives as a comment - a triage agent brief, a human's
follow-up - and every later phase reads the body alone. So before the lenses'
findings, the session running the review (never a lens) reads
`<dir>/comments.md` against `<dir>/spec.md` and drafts the **consolidation
items**:

- Skip any comment whose body opens with a `## Spec review` heading: that is
  this review's own history, never folded back into the spec.
- For every other comment, draft one item - concrete replacement or insertion
  text for the body - if and only if the comment says something the body does
  not already say. Judge the content, not the author. A comment the body
  already reflects produces no item, so a re-run on the same issue proposes
  nothing new.
- A comment that contradicts the body gets one item proposing the comment's
  version: a later comment is presumed to amend the body.
- Two comments that contradict each other become one **decision** item, as in
  **Disposition**.

Each item names its comment by the author and date on the comment's
`<!-- comment @<login> <createdAt> -->` marker line. No comment, or none that
adds anything: no items, and the changelog's Consolidation line says **None**.

## The lenses

Each lens is one of the plugin's agents, which owns its brief and the
reporting rules and may only read. Start them all at once (a
standalone review starts fewer - see **Standalone spec review**) as fresh
subagents - never forks, which inherit this context. On Claude Code that is
the Agent tool with `subagent_type` set to the lens's agent name under the
`orchestrator:` plugin scope. Each prompt carries only the paths its row
names, and each lens returns its findings as its reply.

| Lens | Agent | Paths |
|---|---|---|
| Fidelity | `orch-lens-fidelity` | spec body, comments file, plan handoff |
| Consistency | `orch-lens-consistency` | spec body, comments file, glossary, ADR directory |
| Testability | `orch-lens-testability` | spec body, comments file, repo root |
| Implementability | `orch-lens-implementability` | spec body, comments file, repo root |

On a host that cannot start the plugin's agents natively, take the
"Start a fresh subagent" fallback in `docs/host-capabilities.md` under the
plugin root, with each lens's agent file, `agents/<agent>.md` under the
plugin root, as its brief, and record it in `02-spec.md` under **Host
fallbacks** (a standalone review records it elsewhere - see **Standalone
spec review**).

A lens that errors or returns nothing usable is spawned once more with the
same prompt. A second failure makes it **not run - <reason>**: it appears that
way in the batch and in both changelogs (a standalone review differs here -
see **Standalone spec review**), and the review continues on the
lenses that answered. Three lenses and a recorded gap is a spec review; a
silent gap is not.

Keep the findings under a heading per lens. They are never merged, ranked, or
deduplicated across lenses: the separation is what the lenses exist for.

## Disposition

Draft one proposed edit per finding - concrete replacement text for the body,
never a description of the problem. Then, with the whole batch in view,
consolidation items included:

- One edit that satisfies several findings is proposed once, naming every
  finding it resolves.
- Two findings that cannot both hold - a Fidelity "the plan decided X" against
  an Implementability "the codebase cannot do X" - become a **decision** item:
  both findings side by side, the consequence of each option, and your
  recommendation. The human makes the planning call.
- A finding you believe is wrong is still presented, marked **recommend
  decline** with the reason. You have no recorded human decision to demote on,
  so nothing is dropped silently.
- Consolidation items go **first**, under a **Consolidation** heading, ahead
  even of `contradicts the plan` items: the human sees the body as it will
  read before seeing what the lenses make of it. They are their own group,
  never merged into a lens.
- A lens finding about a contradiction a consolidation item already resolves
  stays under its lens and names that item's number instead of proposing a
  second edit.
- A Fidelity finding labelled `contradicts the plan` goes next, under that
  label: the human sees a reversal of their own earlier decision before any
  other finding.

Each item carries a recommendation: a proposed edit is recommended for
applying unless it is marked **recommend decline** with its reason, and a
decision item carries its recommended option.

Number the items, consolidation items included, in one sequence. Present the
list - each item's finding (or, for a consolidation item, its comment), lens
or **Consolidation**, and proposed edit or decision - and ask **one blocking
question** with the `AskUserQuestion` tool (it exists on both Claude Code and
Junie), the list and the call in the same response. The review never ends its
turn on the list: presenting it is not the end of the step, the answer is. No
edit is applied and no changelog is posted before the answer arrives. The
options:

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

The spec batch is asked once; a long spec is one longer question, not twenty
prompts.

## Applying the answer

1. Apply the accepted edits to `<dir>/spec.md`, the working copy. Keep a copy
   of the body as fetched: **Tickets follow the spec** reads both.
2. Run **Tickets follow the spec** below: draft, ask, and apply the accepted
   ticket edits. Sub-issue edits go through `issue update`; an edit to a
   collapsed `## Ticket` section goes into `<dir>/spec.md`.
3. Publish the body once: `bash "$ORCH" spec update <dir>/spec.md`. The body
   is rewritten in place; the implement phase reads one body and reconciles
   nothing. Skip this step when nothing in `<dir>/spec.md` changed - on Apply
   none, say: an update that writes the body it just read is a no-op edit on
   the issue's history, and the comment in step 5 still records the decision.
4. If the human chose **Retire and break down again**, run
   `bash "$ORCH" ticket retire <issue>` now, after the publish, so it cuts any
   `## Ticket` section from the body just published. Breaking the issue down
   again is left to `orch-flow`'s spec phase step 5, which then sees
   `ticket exists` exit 1.
5. Write the changelog - see below - to `<dir>/changelog.md` under a
   `## Spec review` heading and `bash "$ORCH" spec comment <dir>/changelog.md`. The
   comment is history, visible on the issue; the body is the truth.
6. A declined `contradicts the plan` item: the changelog records **spec
   departs from the plan: <the human's reason>**, and the matching entry in the
   plan handoff's **Rejected alternatives** is amended to say it was reversed
   in the spec review and why. Declining it through **Apply as recommended** is
   allowed: the changelog records **spec departs from the plan: declined as
   recommended: <reason>**, and the amendment cites the same reason. The review loop demotes findings that
   propose a rejected alternative, and without the amendment it would later
   demote a code reviewer for proposing the spec's own choice.
7. Return the changelog to the flow skill: it goes verbatim into
   `02-spec.md`'s **Spec review changelog**, its **Tickets** section included,
   so the implement phase carries the disposition without a network call.

A standalone review applies through the stateless `issue` commands instead:

1. Apply the accepted edits to `<dir>/spec.md`, the working copy, keeping a
   copy of the body as fetched, as above.
2. Run **Tickets follow the spec**, as above.
3. Publish the body once: `bash "$ORCH" issue update <issue> <dir>/spec.md`.
   Skip this step when nothing in `<dir>/spec.md` changed, as above.
4. If the human chose **Retire and break down again**, run
   `bash "$ORCH" ticket retire <issue>` now, after the publish. Then invoke the
   `orch-to-tickets` skill on the issue: it reads the published, edited body.
   An attended review follows it through its own quiz until the human
   approves a breakdown. An **Unattended spec review** follows its
   **Unattended breakdown** instead, never the quiz; the quick implementation
   that ran it then sees `ticket exists` exit 0 at its step 3 and works the
   new breakdown.
5. Write the changelog to `<dir>/changelog.md` under a `## Spec review`
   heading, with Fidelity's not-run line, as in **The changelog**, and any
   **Host fallbacks** line, and
   `bash "$ORCH" issue comment <issue> <dir>/changelog.md`. The comment is
   posted on Apply none too.

It never writes `state.json`, `.orchestrator/handoff/`, `02-spec.md`, or a
plan's **Rejected alternatives**, and returns nothing to a flow skill.

Nothing calls `gh issue edit` or `gh issue comment` directly: `orch.sh`'s
`spec`, `issue` and `ticket` commands are the one place body writes, comments
and retirements happen, and the one place they are tested.

## Tickets follow the spec

A spec review on an issue that already has a ticket breakdown - a blueprint a
flow adopted or a quick implementation linked, or any issue reviewed
standalone - would otherwise leave tickets drawn from the old body, and the
implement phase would build them. This step brings the breakdown in line with
the edits just accepted, before the body is published. It is not a second
pass: no lens runs and the spec is not reviewed again (ADR-0004). Both
entries share it. `<issue>` is the issue under review: in a flow,
the number `bash "$ORCH" state get issue` prints.

**When it runs.** Only when both hold:

- at least one accepted edit was applied to `<dir>/spec.md`;
- `bash "$ORCH" ticket exists <issue>` exits 0, printing `sub-issues` or
  `collapsed`.

With no edit applied, `ticket exists` is not run, and the changelog's
**Tickets** line is **Not checked - no edit applied**. Exit 1 means no
breakdown: the line is **None - no ticket breakdown**. Any other exit stops
the review the way a failed fetch does: say what blocked, publish nothing,
and in a flow leave state where it is.

**Drafting.** The session running the review drafts - never a lens, never a
new agent: this is reconciliation, the same kind of work as
**Consolidation**.

- Read the body as fetched and as edited, plus each ticket's body.
- `sub-issues`: `bash "$ORCH" ticket list <issue>` prints each ticket as
  `<n> open` or `<n> closed`; fetch each with
  `bash "$ORCH" issue fetch <n> <dir>/ticket-<n>.md`. `collapsed`: the ticket
  is the body's `## Ticket` section.
- Draft concrete replacement text only for **open** tickets the accepted
  edits touch. A closed ticket is never edited and nothing reopens it: note
  what changed for it, for the changelog.
- An edit that changes only which open tickets block which is applied with
  `ticket block`/`ticket unblock` and rewrites no other part of the body.
  Adding, removing or re-ordering slices still recommends **Retire and break
  down again**. "Open tickets" names the ticket whose edges change: its
  blocker may be open or closed. Each edge change - one edge added or
  removed - is its own numbered item in the ticket question below.
- A drafted edit you believe is wrong is still presented, marked **recommend
  decline** with the reason.

**The question.** If no open ticket is affected, ask nothing: the line is
**None - no ticket affected**, and each closed ticket the edits touch is
still listed. Otherwise number the ticket items - each naming its ticket
(`#<n>`, or the `## Ticket` section), what the accepted edits changed for it,
and its replacement text, or for an edge change the one edge added or removed -
and ask **one blocking question** with the
`AskUserQuestion` tool, the list and the call in the same response, as for
the spec batch. The options, each offered once:

- **Apply as recommended** - every ticket edit applied except those marked
  **recommend decline**.
- **Apply all** - offered only when some item is marked **recommend
  decline**: as recommended, plus those items too.
- **Apply none**.
- **Retire and break down again** - no ticket is edited; the breakdown is
  retired after the body is published, and the issue broken down again.
- **Other** - item numbers, e.g. `1, 3`, as in the spec batch; any item left
  out is declined. The question text states this format.

The option you recommend comes first and carries **(Recommended)**: **Retire
and break down again** when you recommend a retire, otherwise **Apply as
recommended**.

**Applying.** Each accepted sub-issue edit replaces that ticket's body: write
it to `<dir>/ticket-<n>.md`, then
`bash "$ORCH" issue update <n> <dir>/ticket-<n>.md`. An accepted edit to a
collapsed `## Ticket` section goes into `<dir>/spec.md`, published with the
review's one body update. Each accepted edge change runs
`bash "$ORCH" ticket block <n> --by <blocker>` to add the edge, or
`bash "$ORCH" ticket unblock <n> --by <blocker>` to remove it; the command
rewrites `<n>`'s `## Blocked by` section itself. When one ticket gets both a
text edit and an edge change, the text edit is applied first, its
`## Blocked by` section left as fetched, then `ticket block`/`unblock` runs and
rewrites that section. A retire edits no ticket here: it runs at
**Applying the answer**'s step 4, after the publish. A failed `issue update`
stops the review the way a failed fetch does. A failed `ticket block` or
`ticket unblock` stops the review the way a failed `issue update` does.
Nothing calls `gh issue` directly.

## The changelog

A **Consolidation** section comes first, ahead of the lens headings:

- an applied item: one line naming the comment folded in, by its author and
  date;
- a declined item: the comment's spec-bearing part **verbatim**, then the
  human's reason, or **declined as recommended: <reason>** as below;
- a decision item left out of an Other answer: both comments' spec-bearing
  parts **verbatim**, then **left undecided**;
- no item proposed: **None**.

Then the lenses, organised per lens, in the table's order, one heading each:

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

Then a **Tickets** section, after the lens headings, one line per outcome:

- an applied ticket edit: one line naming the ticket and what changed;
- an applied edge change: one line per changed edge, e.g. **#12 now blocked
  by #10** or **#12 no longer blocked by #11**;
- a declined ticket edit: the proposed change **verbatim**, then the human's
  reason, or **declined as recommended: <reason>**;
- a retire: **retired, to be broken down again**;
- a closed ticket the edits touch: **closed, built against the earlier spec:
  <what changed>**;
- otherwise exactly one of **None - no ticket breakdown**, **None - no ticket
  affected**, or **Not checked - no edit applied**.

The **Tickets** line is written even when **Tickets follow the spec** does
not run.

Silence is never ambiguous: Consolidation, every lens, and Tickets have a
line.
