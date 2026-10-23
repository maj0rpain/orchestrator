# Spec phase

A reference file of the `orch-spec-review` skill, read only from
`orch-flow`'s spec phase: the spec-phase entry, and everything only a flow
adds to the skill's shared steps.

In a flow the review comes after the issue exists - published by the spec
phase or already adopted at init - and before the handoff is written. It
works on the active flow's issue. There is no "review the spec?" question,
only the round count: the human's control is at each round's batch
decision, where they may decline every edit. `orch-flow`'s spec phase asks
the round count before round 1.

Everything in the skill's main file holds - **Rounds**, **Consolidation**,
**The lenses**, **Disposition**, **The batch file**, **Applying the answer**
and **The changelog** - with the additions below. **Standalone spec review**
does not apply: run **Inputs** below in its place.

## In an autopilot flow

When `bash "$ORCH" autopilot active` exits 0 the review runs unattended
(ADR-0049), each round as in an **Unattended spec review** -
`unattended-spec-review.md`
- except that all four lenses run, Fidelity included, in flow mode (**Inputs**
and **The Fidelity lens** below, not the standalone form with `--round 1/1
--issue`); the round count comes from the plan, not from a question; and the
answer is `recommended` without `--unattended`, which is for a quick
implementation. The batch is printed as for an attended review and the
session goes straight on; no question is asked of the human except for
fundamental items. The ticket question, when `apply` pauses with exit 3, is
taken as recommended: `--tickets recommended`.

While writing `batch.md`, mark each material item that is also a **fundamental
item** - one that would reverse or change a planning decision, revive a rejected
alternative, or add or drop scope beyond the plan - with the mark `fundamental`
in place of `material` on its `@@ item` line. Every `contradicts-the-plan`
item is a candidate: judge it against `01-plan.md`'s decisions, rejected
alternatives and scope. A hand-labelled issue's plan records no decisions, so
its review marks none. `spec-review check` and `apply` accept the mark only
under `ORCH_AUTOPILOT=1`.

When a round has a fundamental item:

1. Run `spec-review apply <dir> recommended --round <k>/<n>` as usual: it holds
   the fundamental items back into `<dir>/fundamental.md`, applies every other
   item as recommended, publishes the body and posts no changelog yet.
2. Write the question to a scratch file: only the fundamental items, each with
   its options and recommendation, and post it with `bash "$ORCH" autopilot
   ask spec <file>`. It @mentions the human, adds `needs-human` and releases the
   claim; the session ends.
3. The fresh session meets `spec round` printing `<k> <n> waiting` and resumes
   from the reply, as `orch-flow`'s autopilot spec phase says; with no reply it
   re-posts the question with `autopilot ask spec` and stops, never assuming
   the recommendations.

## Inputs

Steps 1 to 3 run at the start of every round, each round in its own
directory: each round reads the body the previous round published.

`<dir>` is what `bash "$ORCH" spec round-dir <k>/<n>` prints, run first for
round k of n: `.orchestrator/spec-rounds/<k>/`. It makes the directory
ready - emptied, every other round's directory deleted on round 1, and
round k-1's `agent-lens`, `map-implementability.md` and `settled.md` copied
in on later rounds, each when it exists - and writes the round marker, so a
session that fails after the round resumes from it. This is how the lens
setting, the code map and the settled file carry over in a flow, across
sessions too. A failure stops the
phase exactly as a failed body fetch does.

1. Fetch the body: `bash "$ORCH" spec fetch <dir>/spec.md`. It reads the
   issue number from state. A failure stops the phase: state stays where it
   is, say what blocked, offer `/orchestrator:abort` (on a host with
   no plugin commands, `orch-flow`'s **Abort** section). A review with no
   body to review is never claimed as done.
2. Fetch the comments: `bash "$ORCH" spec comments <dir>/comments.md`, in the
   same directory. It reads the issue number from state, and writes an empty
   file when the issue has no comments. A failure stops the phase exactly as
   a failed body fetch does: the lenses would otherwise review half the spec.
3. The glossary, as the main file's **Standalone spec review** step 4
   writes it. A failed `glossary match` stops the phase exactly as a failed
   body fetch does. The plan handoff is not resolved here: the Fidelity
   prompt's `spec-review prompt` runs `handoff path spec` itself, and dies,
   naming the plan handoff, when it is missing - which stops the phase
   exactly as a failed body fetch does.

The main file's rule that nothing from this session's conversation reaches a
lens holds here too: not the plan as you remember it, not `orch-to-spec`'s
reasoning, not the seams as agreed in chat.

## The Fidelity lens

A flow runs four lenses: the three in the main file's table, and Fidelity,
started with them, all on the `lens` setting as round 1 read it. Round 1
runs the main file's read into its round directory, `bash "$ORCH" agent get
lens >"<dir>/agent-lens"`, and starts its lenses on the `model` and `effort`
lines that file holds; a refusal stops the run as **Agent settings** says.
`spec round-dir` copies the file into each later round's directory, and a
later round starts its lenses on `<dir>/agent-lens`, never running `agent get
lens` again: a round in a session of its own still runs on round 1's values,
even if the setting changed since. A later round whose directory holds no
`agent-lens` - round 1 took the **Agent settings** host fallback and skipped
the read - starts its lenses as round 1 did, with no setting. The Fidelity
row:

| Lens | Agent | Prompt |
|---|---|---|
| Fidelity | `orch-lens-fidelity` | pass what `spec-review prompt <dir> fidelity` prints: spec body, comments, plan handoff, settled, findings file |

`batch.md` records it as `@@ lens fidelity ran`, or `not-run <reason>` after
two failures, never `standalone`.

A host fallback taken for any lens is recorded in `02-spec.md` under **Host
fallbacks**, never through `apply --host-fallbacks`.

## Contradicts the plan

- A Fidelity finding labelled `contradicts the plan` becomes an item of the
  `contradicts-the-plan` group, under that label. It goes next after the
  consolidation items, ahead of every other finding: the human sees a
  reversal of their own earlier decision before any other finding.
  Consolidation items still go first, ahead even of `contradicts the plan`
  items.
- A decision item may set a Fidelity "the plan decided X" against an
  Implementability "the codebase cannot do X": the human makes the planning
  call.

## Applying in a flow

`apply` takes no `--issue`: it reads the issue from state and publishes
through the `spec` commands.

After `apply` exits 0: a declined `contradicts the plan` item, recorded in
the changelog as **spec departs from the plan: <reason>**, has its matching
entry in the plan handoff's **Rejected alternatives** amended to say it was
reversed in the spec review and why - citing the human's reason, or the
recommendation's when it was declined through **Apply as recommended**. The
review loop demotes findings that propose a rejected alternative, and
without the amendment it would later demote a code reviewer for proposing
the spec's own choice.

In an autopilot flow the plan handoff is the `01-plan` comment, and `handoff
path` only fetches it into a scratch file: make the amendment in that file,
then re-post it with `bash "$ORCH" handoff post 01-plan <file>`, or the edit is
lost on the next fetch and the review loop reads the unamended comment.

After round k of n, k < n, the amendment runs, then the pause: `orch-flow`'s
spec phase step 4 runs `spec pause --round <k>/<n>` and the session stops,
and the next round runs in a fresh one. The last round never pauses.

After the last round, return every round's changelog to the flow skill, in
round order, as the paths `.orchestrator/spec-rounds/<k>/changelog.md`, so the
implement phase carries the disposition without a network call. Its layout
in `02-spec.md` is the **Spec review changelog** section of `orch-handoff`'s
`02-spec.md` template. When a round retired the breakdown, breaking the
issue down again is left to `orch-flow`'s spec phase step 5, which then sees
`ticket exists` exit 1.
