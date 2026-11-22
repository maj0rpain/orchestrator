---
name: orch-spec-review
description: Review a spec issue in a chosen number of rounds - each proposes folding into the body what the issue's comments say that the body does not, reads body and comments through independent lenses (Consistency, Testability, Implementability, and in a flow Fidelity), puts every finding to the human as one batch of proposed edits, and rewrites the body with the accepted ones. Use from orch-flow's spec phase, after the issue exists and before 02-spec.md is written. Also use standalone, outside any flow, when a human asks for a spec review of a given issue or runs /orchestrator:spec-review <issue> [--rounds <n>]: three lenses, no plan handoff, nothing written to flow state. A quick implementation runs the standalone review unattended, applying its own recommendations without asking.
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

If `CLAUDE_PLUGIN_ROOT` is unset and the host gave this skill's directory,
`ORCH` is `scripts/orch.sh` two directories above this skill's own directory
(the plugin root). Otherwise run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths.

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code,
`agy plugin install <clone-dir>` on Antigravity, or `maj0rpain/orchestrator` as
a Junie extension, which is unverified).

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

Read `standalone.md` in this skill's directory and follow it. In an
**Unattended spec review** (quick implementation), also read
`unattended-spec-review.md`.

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

Run it in the foreground and wait for it (host capability *Run a long
command*). It is a **re-callable command**: it blocks at most a bounded time and
exits 75, with nothing on stdout, while a lens is still missing, and the same
command run again carries on against the same total, so run it again each time
it exits 75, and a call the host stops at its timeout is run again as one that
exited 75 is; never background it and sleep, poll or kill it. Across its
calls it waits until every named lens's findings file exists, so no lens's
hand-back takes a turn of its own, and then prints one line, `lenses back:
<name> <count>, ...`. On exit 0, read the findings files. On a host whose
lenses ran in this session, the files already exist and it returns at once.

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
file has failed. A lens is judged missing only from the wait's own exit, its
`orch:` "lenses not back" timeout, never because the call moved to the
background or a turn passed without a hand-back; no lens is restarted while
its wait is still running. When the wait times out, the hand-backs that queued
during it are now visible, and each lens it names as missing has failed. A
failed lens's findings file, if it left an unreadable one, is removed; then
the lens is spawned once more with the same prompt, and in the same response a
second
`spec-review wait` names only the respawned lenses, run the same way: a
**re-callable command**, run again while it exits 75 (host capability *Run a
long command*). A second failure makes it
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
the batch once, to `<dir>/batch.md` - see `batch-file.md` in this skill's
directory. Then check it, before it is shown, in every mode - flow, standalone,
and unattended:

```
bash "$ORCH" spec-review check <dir>
```

`check` validates the batch as `apply` would take it, writing nothing but
`<dir>/view.md`: its grammar, the lens files and the batch's citations of them,
and every anchor - each item's and each option's - matching once in the body,
then still matching once in a dry run of the **Apply all** answer. On exit 0 it
prints the compact batch view on stdout and writes it to `<dir>/view.md`. On
any other exit, each `orch:` line on stderr names what is wrong, most with its
`batch.md` line: fix `batch.md` and run `check` again, until it exits 0. A
batch that has not passed `check` is never shown and never asked about.

Then end your turn on a **turn-final reply**, per `docs/turn-final-reply.md`
under the plugin root: `check`'s stdout word for word, so the human reads
each material edit's summary and reason, each decision option's summary, and
each minor edit's summary, then the batch question with its answer words
spelled out. Compose no view of your own - no summary, no shortening, no
expansion, in any round: the view the human reads is `check`'s, every round
alike. The turn ends on the list and the question, in one reply. No edit is
applied and no changelog is posted before the answer arrives. On Claude Code
an ask-tool call is refused while the view is unpasted: after each `check`
that wrote a `view.md`, and until the next `apply` or human message, a hook
refuses every ask until one text block after that `check` holds the whole view,
handing back that view each time - end the turn on it and the batch question
in plain text.

Read `applying.md` in this skill's directory for the compact view format,
the batch question's answers and interactive answers (`show`, near-miss
replies, questions), **Applying the answer**, and **The changelog**.
