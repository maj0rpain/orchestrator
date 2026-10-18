---
name: orch-spec-review
description: Review a spec issue in one or more rounds - each round proposes folding into its body what its comments say that the body does not, then read body and comments through its lenses, each independent - Consistency with itself and the glossary, Testability at the agreed seams, Implementability from the issue alone, and in a flow Fidelity to the plan - put every finding to the human as one batch of proposed edits, and rewrite the issue body with the edits they accept; when those edits touch an open ticket of an existing ticket breakdown, ask the ticket question - edit the tickets the change touches, or retire the breakdown so the issue is broken down again; each round reads the body the previous round published, and the review runs its whole round count. Use from orch-flow's spec phase, after the issue exists - published by the spec phase or already adopted at init - and before 02-spec.md is written. Also use standalone, outside any flow, when a human asks for a spec review of a given issue or runs /orchestrator:spec-review <issue> [--rounds <n>]: three lenses, no plan handoff, and nothing written to flow state. A quick implementation runs the standalone review unattended, applying its own recommendations without asking.
---

# Orchestrator spec review

One review of the spec, in one or more rounds. First, the session running
the review proposes folding into the body whatever the issue's comments say
that the body does not - see **Consolidation**. The **lenses** then read the
issue, body and comments, independently, as parallel sub-agents that see only
files. Every consolidation item and every **finding**
they report reaches the human as a proposed edit in one batch; only the edits
the human accepts change the issue - in an **Unattended spec review**, the
recommended ones. When the issue already has a ticket
breakdown and the accepted edits touch an open ticket, the ticket question asks
how the breakdown should follow - see **Tickets follow the spec**, in
`tickets-follow-the-spec.md`; the review writes the issue's tickets only to
follow edits already accepted. The issue body stays the single truth the
implement phase reads; after a review, the comments are history.

A review runs a **round count** of **rounds** (ADR-0041) - see **Rounds**. A
quick implementation asks no question at all: it takes
the standalone entry's **Unattended spec review** mode, which applies its own
recommendations - see `unattended-spec-review.md`.
The independence comes from the sub-agents, the same way it does for the review
loop - see `docs/adr/0001-review-loop-runs-in-a-single-session.md`.

There are two entries, and everything from **Consolidation** through **The
changelog** is shared between them, run once per round:

- **Spec phase** - the spec-phase entry, from `orch-flow`'s spec phase, on
  the active flow's issue. A flow's spec phase reads `spec-phase.md` in this
  skill's directory, and only then: it holds the entry's **Inputs** and
  everything only a flow adds to the shared steps.
- **Standalone spec review** - a human asks for a review of a given issue,
  with `/orchestrator:spec-review <issue> [--rounds <n>]` or in plain words,
  outside any flow. It belongs to no flow, leaves no handoff, and runs three
  lenses: Fidelity needs a plan and has none. A review started after it ends
  is a new standalone review, with its own round count.

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

## Rounds

One **round** is everything from **Consolidation** through **The changelog**:
Consolidation, the lenses, one batch question, and one `spec-review apply`
run that applies the accepted edits and posts one `## Spec review` changelog
comment - two runs when **Tickets follow the spec** pauses it for the ticket
question. The review runs rounds 1 to `<n>`, `<n>`
the round count, in order:

- **Each round reads the body the previous round published.** Each round
  takes a fresh working directory and fetches the body and comments again:
  the standalone entry re-runs its steps from `spec-review begin <issue>`,
  which empties the directory but for the code map and the settled file it
  keeps on rounds 2 and later. Nothing is lost: the previous round has already published.
- **The code map and the settled file carry over.** The Implementability
  lens's code map, `map-implementability.md`, and the settled file,
  `settled.md`, are the files a round hands the next: the standalone entry
  keeps both with `--carry` (step 1). Findings still never carry over: each
  round stays an independent look, and only the human's rulings reach the
  next. Round 1 never inherits a map or a settled file.
- **The whole count runs.** A round that finds nothing, or whose edits are
  all declined, does not end the review early: the next round still runs, up
  to round `<n>`.
- **A failure in any round stops the whole review**, exactly as it stops a
  one-round review: no later round runs, and the rounds already run stay
  published, each with its own changelog comment. When any round of this
  review had already run `ticket retire` - the failing round included - the
  stop message also says the issue has no ticket breakdown and needs
  `/orchestrator:to-tickets <issue>`.
- **A retire holds for every later round.** After a round runs
  `ticket retire`, every later round sees `ticket exists` exit 1 and records
  **None - no ticket breakdown**.
- **Tickets follow the spec** is not another round: within a round, no lens
  runs again.

The round count lives in the session only: nothing writes it to
`state.json`, and `orch.sh` has no key for it. A standalone review takes it
from `--rounds`, 1 without it.

## Standalone spec review

The issue number comes from the human: the command's argument, or the issue
they named. With no number, ask for one and wait. Never take it from
`state.json` or the active flow.

The round count comes from `--rounds <n>` in the arguments - the command's
arguments, or the Skill tool's args when a session calls this skill directly,
e.g. `<issue> --rounds 3`; both are read the same way. Without `--rounds`, the
review runs 1 round. `<n>` must be an integer >= 1: on any other value, or a
`--rounds` with no value, stop before `spec-review begin` with a message
naming the value and that `--rounds` takes an integer >= 1. Nothing is
fetched or published. This session checks the value, never `orch.sh`.

Steps 1 to 4 below run at the start of every round, as **Rounds** says.

1. **Begin**, before fetching: `bash "$ORCH" spec-review begin <issue>` on
   round 1, and `bash "$ORCH" spec-review begin <issue> --carry` on
   rounds 2 and later. It prints the working directory, `<dir>` from here on,
   emptied for this run - except, with `--carry`, for the previous round's
   `map-implementability.md` and `settled.md`, each kept when it exists.
   If it dies, stop and relay its message - when an active flow holds this
   issue, the message names the command to run instead. This is the review's
   only read of `state.json`, and it goes through `orch.sh`.
2. **Fetch**: `bash "$ORCH" issue fetch <issue> <dir>/spec.md`, opened
   with the Read tool wherever this session reads it, never `cat`. A failure
   stops the review: say what blocked it. There is no flow to abort,
   so do not offer `/orchestrator:abort`. The directory is left for
   inspection and wiped by the next run.
3. **Fetch the comments**: `bash "$ORCH" issue comments <issue>
   <dir>/comments.md`. A failure stops the review, as a failed body fetch
   does.
4. Resolve the other files the lenses read, and record the paths:
   - the glossary: when the root `GLOSSARY.md` exists, write `bash "$ORCH"
     glossary match <dir>/spec.md <dir>/comments.md > <dir>/glossary.md` and
     record that path, else record no glossary path; a failed `glossary
     match` stops the review, as a failed body fetch does;
   - the decisions: `docs/adr/` at the repo root, where it exists;
   - the repo root, for the codebase.

   There is no plan handoff. Nothing from this session's conversation
   reaches a lens: a lens that needs something gets a file path.

The standalone entry never calls `spec fetch`, `spec comments`, `spec update`,
`spec comment`, or `handoff path`, never reads under `.orchestrator/handoff/`,
and never calls `gh issue` directly.

Then run **Consolidation**, **The lenses**, **Disposition**, and **Applying
the answer** below, with these differences:

- **Lenses**: start the three in the table: Consistency, Testability, and
  Implementability. Fidelity, which needs a plan, is never started.
  `batch.md` records it as `@@ lens fidelity standalone`, and the batch and
  the changelog show Fidelity's not-run line. That is not a failure, so the
  retry rule does not apply to it.
- **Applying**: `apply` takes `--issue <issue>` - see **Applying the
  answer**.
- **Host fallbacks and lens failures**: among the review's own records, they
  are recorded in the changelog comment only, under a **Host fallbacks**
  line that `apply --host-fallbacks <file>` writes. A standalone review has one changelog, not two. A quick
  implementation that runs the review in the same session also lists the
  host fallbacks it saw in its own PR body.


A quick implementation runs this entry in its **Unattended spec review**
mode, which asks the human nothing. In that run, and only then, read
`unattended-spec-review.md` in this skill's directory: it is the mode's one
definition.

## Consolidation

Spec content often arrives as a comment - a triage agent brief, a human's
follow-up - and every later phase reads the body alone. So before the lenses'
findings, the session running the review (never a lens) reads
`<dir>/comments.md` against `<dir>/spec.md` and drafts the **consolidation
items**:

- For every comment, draft one item - concrete replacement or insertion
  text for the body - if and only if the comment says something the body does
  not already say. Judge the content, not the author. A comment the body
  already reflects produces no item, so a re-run on the same issue proposes
  nothing new.
- A comment that contradicts the body gets one item proposing the comment's
  version: a later comment is presumed to amend the body.
- Two comments that contradict each other become one **decision** item, as in
  **Disposition**.

Each item names its comment by the author and date on the comment's
`<!-- comment @<login> <createdAt> -->` marker line, and carries the
comment's spec-bearing part, so a decline can be recorded word for word. No
comment, or none that adds anything: no items.

## The lenses

Each lens is one of the plugin's agents, which owns its brief and the
reporting rules and may write only its findings file - and the
Implementability lens its code map too. Start them all at once as fresh
subagents - never forks, which inherit this context. On Claude Code that is
the Agent tool with `subagent_type` set to the lens's agent name under the
`orchestrator:` plugin scope. Each prompt carries only the paths its row
names, the last of them its findings file, `<dir>/lens-<name>.md`. Each lens
writes its numbered findings there, its findings file last, and replies with
only that path and a count.

In the same response that starts the lenses, right after starting them, run
the wait with the working directory and the names of the lenses just started -
three in a standalone review, four in a flow's, Fidelity included:

```bash
bash "$ORCH" spec-review wait <dir> <lens>...
```

It blocks until every named lens's findings file exists, so no lens's
hand-back takes a turn of its own, and prints one line, `lenses back: <name>
<count>, ...`. On exit 0, read the findings files. On a host whose lenses ran
in this session, the files already exist and it returns at once.

| Lens | Agent | Paths |
|---|---|---|
| Consistency | `orch-lens-consistency` | spec body, comments file, glossary, ADR directory, `<dir>/settled.md`, `<dir>/lens-consistency.md` |
| Testability | `orch-lens-testability` | spec body, comments file, repo root, `<dir>/settled.md`, `<dir>/lens-testability.md` |
| Implementability | `orch-lens-implementability` | spec body, comments file, repo root, `<dir>/map-implementability.md`, `<dir>/settled.md`, `<dir>/lens-implementability.md` |

On a host that cannot start the plugin's agents natively, take the
"Start a fresh subagent" fallback in `docs/host-capabilities.md` under the
plugin root, with each lens's agent file, `agents/<agent>.md` under the
plugin root, as its brief, and record it under **Host fallbacks** - see
**Standalone spec review**.

A lens that errors, returns nothing usable, or writes no readable findings
file has failed. When the wait times out, the hand-backs that queued during it
are now visible, and each lens it names as missing has failed. A failed lens's
findings file, if it left an unreadable one, is removed; then the lens is
spawned once more with the same prompt, and in the same response a second
`spec-review wait` names only the respawned lenses. A second failure makes it
**not run - <reason>**: it appears that way in the batch and in the
changelog, and the review continues on the lenses that answered. Three
lenses and a recorded gap is a spec review; a silent gap is not.

Read each lens's findings from its file. They are never merged, ranked, or
deduplicated across lenses: the separation is what the lenses exist for.

## Disposition

Draft one proposed edit per finding - concrete replacement text for the body,
never a description of the problem. Then, with the whole batch in view,
consolidation items included:

- One edit that satisfies several findings is proposed once, naming every
  finding it resolves.
- Two findings that cannot both hold - a Consistency "the glossary defines X
  as Y" against an Implementability "the codebase does X as Z" - become a **decision** item:
  both findings side by side, the consequence of each option, and your
  recommendation. The human makes the planning call.
- A finding you believe is wrong is still presented, marked **recommend
  decline** with the reason. You have no recorded human decision to demote on,
  so nothing is dropped silently.
- A finding that reopens a ruling in `<dir>/settled.md` without naming
  evidence that ruling did not have is still presented, marked **recommend
  decline** with the reason `settled in round <k>, item <n>`.
- Consolidation items go **first**, under a **Consolidation** heading: the
  human sees the body as it will
  read before seeing what the lenses make of it. They are their own group,
  never merged into a lens.
- A lens finding about a contradiction an earlier item already resolves
  stays under its lens and names that item's number instead of proposing a
  second edit.

Each item carries a recommendation: a proposed edit is recommended for
applying unless it is marked **recommend decline** with its reason, and a
decision item carries its recommended option.

You, never a lens, then mark each item that carries an edit **material** or
**minor**:

- **Material**: the item's edit changes what gets built or how it is
  proven - behaviour, scope, an interface, an acceptance criterion or a test
  seam.
- **Minor**: anything else - wording, clarification, naming, internal
  consistency, a cross-reference.
- Every decision item and every `contradicts-the-plan` item is material;
  `check` and `apply` refuse either marked minor.
- A recommend-decline item whose edit would be material if applied is
  material. No check catches this one: the call is yours.
- A resolved item carries no mark: it has no edit.

Number the items, consolidation items included, in one sequence, and write
the batch once, to `<dir>/batch.md` - see **The batch file**. Then check it,
before it is shown, in every mode - flow, standalone, and unattended:

```
bash "$ORCH" spec-review check <dir>
```

`check` validates the batch as `apply` would take it, without writing
anything: its grammar, the lens files and the batch's citations of them, and
every anchor - each item's and each option's - matching once in the body,
then still matching once in a dry run of the **Apply all** answer. On exit 0
it prints the batch view on stdout - the lens lines, ran or not run with the
reason, then every material item in full, in batch order, consolidation
items first: its group, its recommendation, its cited findings (or, for a
consolidation item, its comment), and its Current and Proposed text in full,
each option's for a decision item. Then, under a `### Minor edits` heading,
every minor and resolved item one line each, in batch order: `<n>. <Group>:
<summary>`, a recommend-decline minor item's line ending `- recommend
decline: <reason>`, and a resolved item's reading `<n>. <Group>: resolved by
item <m>`. The heading is left out when no item is minor or resolved, and
the item numbers stay the one sequence of `batch.md`. Its one-line pass
summary goes to stderr. On any other exit, each `orch:` line on
stderr names what is wrong, most with its `batch.md` line: fix `batch.md` and
run `check` again, until it exits 0. A batch that has not passed `check` is
never shown and never asked about.

Then paste `check`'s stdout into chat word for word, so the human reads each
material edit's wording, and each minor edit's summary, before answering. Compose no view of your own - no summary,
no shortening, in any round: the view the human reads is `check`'s, every
round alike. Then ask **one blocking question** with the host's ask tool
(`AskUserQuestion` on Claude Code, `ask_user` on Junie), the paste and the
call in the same response. The review never ends its turn on the list:
presenting it is not the end of the step, the answer is. No edit is applied
and no changelog is posted before the answer arrives. The options:

- **Apply as recommended (Recommended)** - every proposed edit applied, every
  decision item takes its recommended option, every **recommend decline** item
  skipped. Always offered, first.
- **Apply all** - offered only when at least one item is marked **recommend
  decline**: as recommended, plus those items too. With no such item it would
  equal the first option, so it is not shown.
- **Apply none** - always offered.
- **Other** - only the departures from the recommendation, comma-separated,
  e.g. `3B, -4, +2`: `<n><letter>` gives decision item `<n>` option
  `<letter>`; `-<n>` declines item `<n>`, or leaves a decision item undecided,
  and the changelog says so; `+<n>` applies recommend-decline item `<n>`.
  Every item not named stays as recommended. A bare item number is no
  departure and is refused. The question text states this format.

The spec batch is asked once; a long spec is one longer question, not twenty
prompts.

### The batch file

Marker lines; a line starting `@@ ` is reserved, and no body line starts that
way. The `@@ lens` lines come first, one per lens, Fidelity included, then one block
per item, in the batch's order:

```
@@ lens <name> ran                        a lens that answered
@@ lens <name> not-run <reason>           a lens that failed twice
@@ lens fidelity standalone               Fidelity in a standalone review
@@ item <n> <group> apply <mark>                   a proposed edit, recommended
@@ item <n> <group> decline <mark> <reason>        a proposed edit marked recommend decline;
                                                     it still carries the edit it declines
@@ item <n> <group> decision <letter> <mark>        a decision item, <letter> recommended
@@ item <n> <group> resolved                       a finding an earlier item resolves; no mark
@@ summary <one line>                     the changelog's line when the item is applied
@@ why <one line>                         a material item's reason for its edit, at item
                                            level: one per material item, never under an
                                            option, and on no minor or resolved item
@@ finding <lens> <k>                     repeatable: the lens findings the item resolves
@@ comment @<login> <createdAt>           a consolidation item's comment, repeatable,
@@ quote                                    each followed by the comment's spec-bearing part
@@ resolved-by <m>                        the earlier item; a resolved item has no anchor
@@ option <letter> <label>                a decision item's option, with its own summary,
                                            anchor and replacement
@@ anchor                                 exact text already in the body, matching once
@@ replace                                its replacement
@@ end
```

`<group>` is `consolidation`, a lens name, or `contradicts-the-plan`.
`<mark>` is `material` or `minor`, the last fixed token of the `@@ item`
line, before any reason; a decision item and a `contradicts-the-plan` item
are always `material`, and a resolved item takes no mark. An
insertion is an anchor plus a replacement that repeats it. Every item with
an anchor, and every option, has its one `@@ summary`. Every material item
carries one `@@ why`, a decision item's before its first `@@ option`; on a
recommend-decline item it is still the reason for the edit, and the reason
for declining stays on the `@@ item` line. `check` and `apply` refuse a
material item without one, naming its `@@ item` line, and a `@@ why` that is
empty, on a minor or resolved item, under an option, or a second on one
item. The changelog never carries it. A `@@ finding` cites
the `<k>`-th finding in `<dir>/lens-<lens>.md`, which `apply` copies into the
changelog, so the batch file never quotes a lens.

`check` and `apply` verify every anchor: each must match the body exactly
once, and `check` names the `batch.md` line of each one that does not. No
hand check is needed - no `grep` loop, no python count - before running
`check`.

#### A worked example

A standalone review, so Fidelity is recorded as `standalone`, of this body:

```
# Widget export

## Problem Statement

Exports time out on large widgets.

## Solution

The export streams each widget in pages of 100.
The export writes one file.

## Testing Decisions

- One seam: the `widget export` CLI.
```

Its batch holds one item of each kind, and passes `check`:

```
@@ lens fidelity standalone
@@ lens consistency ran
@@ lens testability ran
@@ lens implementability ran

@@ item 1 consolidation apply material
@@ summary Failed pages are retried once
@@ why A page that fails once should not fail the whole export
@@ comment @alice 2026-10-01T09:00:00Z
@@ quote
A failed page should be retried once before the export gives up.
@@ anchor
The export streams each widget in pages of 100.
@@ replace
The export streams each widget in pages of 100.
A failed page is retried once before the export fails.
@@ end

@@ item 2 testability apply material
@@ finding testability 1
@@ summary The seam's test runs against a fake store
@@ why The seam names no store to test against
@@ anchor
- One seam: the `widget export` CLI.
@@ replace
- One seam: the `widget export` CLI, end to end, against a fake store.
@@ end

@@ item 3 consistency decline minor the glossary's term is widget, as the body says
@@ finding consistency 1
@@ summary Widgets renamed items
@@ anchor
Exports time out on large widgets.
@@ replace
Exports time out on large items.
@@ end

@@ item 4 implementability decision B material
@@ finding implementability 1
@@ why One file cannot hold the largest exports
@@ option A One file
@@ summary The export writes one compressed file
@@ anchor
The export writes one file.
@@ replace
The export writes one compressed file.
@@ end
@@ option B One file per widget
@@ summary The export writes one file per widget
@@ anchor
The export writes one file.
@@ replace
The export writes one file per widget.
@@ end

@@ item 5 implementability resolved
@@ finding implementability 2
@@ resolved-by 4
```

- **Consolidation** (item 1): an `apply` item citing its comment with
  `@@ comment` and `@@ quote` instead of a `@@ finding`. Its edit is an
  insertion: the replacement repeats the anchor and adds a line after it.
- **Apply** (item 2): a `@@ finding`, a `@@ summary`, its `@@ why`, as a
  material item, then one `@@ anchor`, `@@ replace`, `@@ end` block.
- **Decline** (item 3): the same shape as an apply item - summary, anchor,
  replacement and `@@ end` - so **Apply all** can still apply it; the reason
  is on its `@@ item` line, after its mark. Renaming a term is minor, so it
  carries no `@@ why`, and `check` lists it under **Minor edits** with its
  reason.
- **Decision** (item 4): no summary or block of its own, but its one
  `@@ why` before its options; each `@@ option` carries its own
  `@@ summary` and block, and the `@@ item` line names the recommended
  letter.
- **Resolved** (item 5): only its findings and `@@ resolved-by`; it takes no
  mark, `@@ summary`, `@@ why`, `@@ anchor`, `@@ replace` or `@@ end`, and `check`
  lists it under **Minor edits** as resolved by item 4.

## Applying the answer

One call applies the answer, run with the human's answer as given:
`recommended` for **Apply as recommended**, `all`, `none`, or the Other
override list such as `"3B, -4, +2"`. `--round <k>/<n>` names the round. A
departure that matches the recommendation - `-<n>` on a recommend-decline
item, or a decision's recommended letter - is accepted and recorded as
recommended. `apply` refuses, before any write, a token that is not
`<n><letter>`, `-<n>` or `+<n>` (a bare number among them), an unknown item
or option letter, a letter on an item that is no decision, `+` on a decision
item or on an item not recommended for decline, `-` or `+` on a resolved
item, and an item named twice. The human's reasons for declined items - a
`-<n>` decline among them - go in a file, one `<n>: <reason>` line each,
passed as `--reasons <file>`; a line naming an item the answer does not
decline is refused.

```
bash "$ORCH" spec-review apply <dir> <answer> --round <k>/<n> [--reasons <file>]
```

`apply` applies the accepted items to `<dir>/spec.md`, follows the tickets,
publishes the body only when it changed, runs any retire after that
publish, and writes the round's changelog to `<dir>/changelog.md` and posts
it, on Apply none too - see **The changelog**. Nothing calls `gh issue`
directly.

How it exits:

- **0**: the round is published.
- **3**: the ticket pause. An accepted edit changed the body and the issue
  has a ticket breakdown; `apply` printed its kind and wrote nothing to
  GitHub. Read `tickets-follow-the-spec.md` in this skill's directory now,
  and follow it: it drafts `<dir>/tickets.md`, asks the ticket question,
  and runs `apply` again with `--tickets <answer>`.
- **Any other exit, refused**: the `orch:` message names the item, line or
  answer at fault, and nothing was written to GitHub. Fix `batch.md`,
  `tickets.md` or the reasons file and run the same `apply` again; an
  answer `apply` cannot read is asked again.
- **Any other exit, a failed write**: the message names the write that
  failed and every write that already landed, and says the review stops
  here. Stop the review, as **Rounds** says; `apply` refuses to run again
  in that directory.

A standalone review adds `--issue <issue>`, and with host fallbacks to
record, `--host-fallbacks <file>` holding them. `apply` then uses the
stateless `issue` commands and never reads `state.json`. When a round
retired the breakdown, invoke the `orch-to-tickets` skill on the issue after
the **final** round - never before it, so a later round cannot make a fresh
breakdown stale: it reads the published, edited body, and an attended review
follows it through its own quiz until the human approves a breakdown. A
standalone review never writes `state.json`, `.orchestrator/handoff/`,
`02-spec.md`, or a plan's **Rejected alternatives**, and returns nothing to
a flow skill.

## The changelog

`apply` writes it, from `batch.md`, the lens files, `tickets.md`, the
answers and the reasons: the session never types it. It opens with the
`## Spec review` heading and the `Round <k> of <n>` line, then a
Consolidation section, one section per lens - Fidelity first - and a
Tickets section: applied items one line each, declined findings and
comments word for word with the human's reason or **declined as
recommended: <reason>**, an undecided decision item's sides then **left
undecided**, **None** for a group with no items, **not run - <reason>** for
a lens that failed twice, and Fidelity's standalone not-run line. Silence is
never ambiguous: Consolidation, every lens, and Tickets have a line. A
minor item applied by the human's answer - by **Apply as recommended**,
**Apply all**, `+<n>`, or left unnamed in an override answer - reads
`- (<n>, minor) <summary>`, so the history shows it was applied without being
shown in full; material, declined, decision and resolved lines carry no tag,
and neither does any line of an unattended review's changelog, which no human
answers. The
heading keeps every earlier round's comment out of `comments.md`: `orch.sh`
leaves out a comment whose body opens with it.

The comment is history, visible on the issue; the body is the truth.
`<dir>/changelog.md` stays in the round's working directory after it is
posted. As its last step, once every GitHub write has landed, `apply` also
appends the changelog, exactly as written, to the review-wide settled file
`<dir>/settled.md`, creating it on round 1: a pause or a failed write before
then appends nothing.
