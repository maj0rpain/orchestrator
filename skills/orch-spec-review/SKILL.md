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

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths. If it prints nothing, `ORCH` is
`scripts/orch.sh` two directories above this skill's own directory (the plugin
root).

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
the round count, in order, all in one session - except in a flow, where each
round but the last runs in its own session and the last runs in the session
that breaks the issue down: see `spec-phase.md`.

- **Each round reads the body the previous round published.** Each round
  takes a fresh working directory and fetches the body and comments again:
  the standalone entry re-runs its steps from `spec-review begin <issue>`,
  which empties the directory but for the code map and the settled file it
  keeps on rounds 2 and later. Nothing is lost: the previous round has already
  published.
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
  `/orchestrator:to-tickets <issue>`. In a flow's resumed session, whether an
  earlier round ran `ticket retire` is read from the earlier rounds'
  changelogs in their fixed directories,
  `.orchestrator/spec-rounds/<k>/changelog.md` (their Tickets section), or from
  `ticket exists`; nothing extra is recorded.
- **A retire holds for every later round.** After a round runs
  `ticket retire`, every later round sees `ticket exists` exit 1 and records
  **None - no ticket breakdown**.
- **Tickets follow the spec** is not another round: within a round, no lens
  runs again.

The round count is never written to `state.json`, and `orch.sh` has no
key for it there. In a flow, it lives in the round marker from round 1 on,
written by `orch.sh` (`spec round-dir` and `spec pause --round`). A
standalone review keeps it in the session only, and takes it from
`--rounds`, 1 without it.

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
4. **The glossary**: only when the root `GLOSSARY.md` exists, write
   `bash "$ORCH" glossary match <dir>/spec.md <dir>/comments.md >
   <dir>/glossary.md`; with no root glossary, write nothing, and the
   Consistency prompt reads `Glossary: none`. A failed `glossary match`
   stops the review, as a failed body fetch does. Every other path a lens
   reads - the ADR directory, the repo root, the settled file and the
   previous code map - `spec-review prompt` resolves itself, from what
   exists when it runs.

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
  line that `apply --host-fallbacks <file>` writes. A standalone review has one
  changelog, not two. A quick implementation that runs the review in the same
  session also lists the host fallbacks it saw in its own PR body.


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
`orchestrator:` plugin scope, every lens on the `lens` setting: run
`bash "$ORCH" agent get lens` once, before the review's first round, per
**Agent settings** in `docs/host-capabilities.md`, and start every round's
lenses on those values, even if the setting changes between rounds. A flow's
later rounds, each in a session of its own, take them from round 1's read
rather than reading again, as `spec-phase.md`'s **The Fidelity lens** says.
Each lens's prompt is exactly
what `bash "$ORCH" spec-review prompt <dir> <lens>` prints, passed unchanged:
one labelled line per path its row names, every path absolute, the last of
them its findings file, `<dir>/lens-<name>.md`. An input that does not exist
reads `none`, which the lens takes as a meaning, never as a path to try;
the findings file and the Implementability map file are always given. Never
build or edit a prompt by hand; when the op dies, relay its message and stop
the review, as a failed body fetch does. Each lens
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

| Lens | Agent | Prompt |
|---|---|---|
| Consistency | `orch-lens-consistency` | pass what `spec-review prompt <dir> consistency` prints: spec body, comments, glossary, ADR directory, settled, findings file |
| Testability | `orch-lens-testability` | pass what `spec-review prompt <dir> testability` prints: spec body, comments, repo root, settled, findings file |
| Implementability | `orch-lens-implementability` | pass what `spec-review prompt <dir> implementability` prints: spec body, comments, repo root, previous map, map file, settled, findings file |

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
  as Y" against an Implementability "the codebase does X as Z" - become a
  **decision** item: both findings side by side, the consequence of each option,
  and your recommendation. The human makes the planning call.
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

`check` validates the batch as `apply` would take it, writing nothing but
`<dir>/view.md` (below): its grammar, the lens files and the batch's citations
of them, and every anchor - each item's and each option's - matching once in the
body, then still matching once in a dry run of the **Apply all** answer. On exit
0 it prints the compact batch view on stdout - the lens lines, ran or not run
with the reason, then the material items as one bulleted list in batch
order, consolidation items first, each under its `batch.md` number and with
no `### Item` heading. The number is written literally, in bold after the
bullet, never as a Markdown ordered-list number, which a renderer would
recount from the first item, so the number a human reads is the number
their answer names. Each entry is one line, its summary and its reason -
`- **<n>** - **<Group>** - <summary> (apply) - <why>`, or `- **<n>** -
**<Group>** - <summary> (recommend decline: <reason>) - <why>`, `<why>` its
`@@ why` line - or for a decision item its header, `- **<n>** - **<Group>**
(decision, option <L> recommended) - <why>`, then one sub-bullet per option,
indented a fixed 2 spaces: `Option <L> - <label>: <summary>`, ` (recommended)`
after the recommended one's label. The compact view cites no finding or
comment and shows no diff: `--full` prints an item in full. Then, under a
`### Minor edits` heading, every minor and resolved item one line each, in
batch order: `- **<n>** - <Group>: <summary>`, a recommend-decline minor
item's line ending `- recommend decline: <reason>`, and a resolved item's
reading `- **<n>** - <Group>: resolved by item <m>`. No line of the view
starts with `<digits>. `. The heading is left out when no item
is minor or resolved, and the item numbers stay the one sequence of
`batch.md`. `check <dir> --full <n>...` validates the batch the same way,
then prints only the named items, any of them, minor or resolved included,
in the order named, each in full: its group, its recommendation, its cited
findings and comments quoted, and its Current and Proposed text in full,
each option's for a decision item. Either form also writes exactly the view
it printed to `<dir>/view.md`, overwriting any earlier one, and its one-line
pass summary goes to stderr: it names that `view.md` by absolute path and
tells you to end your turn on one plain-text reply, with no tool call,
holding the view above word for word and then the question with its answer
words spelled out. A `check` that fails leaves any earlier `view.md` as it was.
On any other exit, each `orch:` line on
stderr names what is wrong, most with its `batch.md` line: fix `batch.md` and
run `check` again, until it exits 0. A batch that has not passed `check` is
never shown and never asked about.

Then end your turn on a **turn-final reply**, per `docs/turn-final-reply.md`
under the plugin root: `check`'s stdout word for word, so the human reads
each material edit's summary and reason, each decision option's summary, and
each minor edit's summary, then the batch question with its answer words
spelled out. Compose no view of your own - no summary, no shortening, no
expansion, in any round: the view the human reads is `check`'s, every round
alike. The turn ends on the list and the question, in one reply. No edit is
applied and no changelog is posted before the answer arrives. On Claude Code
an ask-tool call is refused while the view is unpasted: after each `check`
that wrote a `view.md`, and until the next `apply`, a hook refuses every ask
until one text block after that `check` holds the whole view, handing back
that view each time - end the turn on it and the batch question in plain
text. The answers:

- **Apply as recommended (Recommended)**, answer word `recommended` - every
  proposed edit applied, every decision item takes its recommended option,
  every **recommend decline** item skipped. Always offered, first.
- **Apply all**, answer word `all` - offered only when at least one item is
  marked **recommend decline**: as recommended, plus those items too. With no
  such item it would equal the first option, so it is not shown.
- **Apply none**, answer word `none` - always offered.
- **Other** - only the departures from the recommendation, comma-separated,
  e.g. `3B, -4, +2`: `<n><letter>` gives decision item `<n>` option
  `<letter>`; `-<n>` declines item `<n>`, or leaves a decision item undecided,
  and the changelog says so; `+<n>` applies recommend-decline item `<n>`.
  Every item not named stays as recommended. A bare item number is no
  departure and is refused. Other also takes `show <n>` - one or more item
  numbers, e.g. `show 3` or `show 3 5` - which prints those items in full,
  or a free-text question.

The question spells every answer out: `recommended`, `all` when offered,
`none`, a departure list in this format, `show <n>...`, or a question in
plain words. An answer word and its option's full label (`Apply as
recommended`, `Apply all`, `Apply none`) are the same answer, matched as the
doc says.

Tell an Other answer's form this way. An answer starting with `show`
followed by item numbers is a show request. An answer made only of
departure-shaped tokens - `<n><letter>`, `-<n>`, `+<n>` or a bare `<n>` -
comma-separated, is a departure list: it goes to `apply` as given, which
refuses it as it does today if it is malformed, a bare number included.
A reply that is clearly a question is a question.

A **near-miss reply** (the doc's **Near-miss reply**) matches none of these
forms: a typo, extra words around an answer word, or mixed forms such as
`recommended but not 4`. It is never re-pasted. Its one-line restatement is in
the grammar `apply` accepts (e.g. "Apply as recommended, except item 4
declined" - `-4`). *No* runs the question path below. On Claude Code the
confirmation ask passes the hook: the view is already in the turn-final reply
above it.

An Other answer of `show <n>...` is not an answer to the batch question.
Run `bash "$ORCH" spec-review check <dir> --full <n>...` with the numbers it
names, then end your turn on one plain-text reply holding its stdout word
for word and the batch question again, its answer words spelled out, with no
tool call. It writes the full items' view to `<dir>/view.md` in place of
the batch view, and its pass line names that file and gives the same
instruction as the batch `check`'s. On Claude Code an ask-tool call is
refused until the view is pasted, as for the batch question. `apply` never
receives a `show` answer. A `--full` refusal - a number not in `batch.md` -
is told to the human, and the batch question asked again, the same way.

A question, or *No* to a near-miss confirmation, is not an answer to the
batch question either: the doc's **Question path** runs. Do not run `apply`,
which never receives a question. Re-run `bash "$ORCH" spec-review check
<dir>`, and end the turn again on its new view word for word and the batch
question. The re-run's pass
line arms the guard again, so on Claude Code only a paste made after it lets
a later ask through.

The spec batch is asked once; a long spec is one longer question, not twenty
prompts.

### The batch file

Marker lines; a line starting `@@ ` is reserved, and no body line starts that
way. The `@@ lens` lines come first, one per lens, Fidelity included, then one
block per item, in the batch's order:

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
an anchor, and every option, has its one `@@ summary`: one sentence stating
what the spec will say after the edit, not the topic the edit touches. `check`
and `apply` refuse a summary, an item's or an option's, of more than 30
words - each a run of non-whitespace - naming the item, its option and its
`batch.md` line. Every material item
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
  mark, `@@ summary`, `@@ why`, `@@ anchor`, `@@ replace` or `@@ end`, and
  `check` lists it under **Minor edits** as resolved by item 4.

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
never ambiguous: Consolidation, every lens, and Tickets have a line. An
applied item, minor or material, reads `- (<n>) <summary>`, attended or
unattended alike: no line carries a minor tag. The
heading keeps every earlier round's comment out of `comments.md`: `orch.sh`
leaves out a comment whose body opens with it.

The comment is history, visible on the issue; the body is the truth.
`<dir>/changelog.md` stays in the round's working directory after it is
posted. As its last step, once every GitHub write has landed, `apply` also
appends the changelog, exactly as written, to the review-wide settled file
`<dir>/settled.md`, creating it on round 1: a pause or a failed write before
then appends nothing.
