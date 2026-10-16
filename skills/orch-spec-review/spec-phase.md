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

## Inputs

Steps 1 to 4 run at the start of every round, each round in a fresh
directory: each round reads the body the previous round published.

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
   - the glossary: when `GLOSSARY.md` exists at the repo root, write the
     entries the spec mentions with `bash "$ORCH" glossary match
     <dir>/spec.md <dir>/comments.md > <dir>/glossary.md`, and record
     `<dir>/glossary.md`. With no root `GLOSSARY.md`, record no glossary
     path. A failed `glossary match` stops the phase exactly as a failed
     body fetch does;
   - the decisions: `docs/adr/` at the repo root, where it exists;
   - the repo root, for the codebase.
4. On rounds 2 and later, copy the previous round's
   `map-implementability.md` into `<dir>` if that file exists - the previous
   round's directory is still on disk. This is how the code map carries
   over in a flow. When it does not exist, copy nothing and say nothing.
   Round 1 copies nothing.

Nothing from this session's conversation reaches a lens: not the plan as you
remember it, not `orch-to-spec`'s reasoning, not the seams as agreed in chat. A lens
that needs something gets a file path.

## The Fidelity lens

A flow runs four lenses: the three in the main file's table, and Fidelity,
started with them. Its row:

| Lens | Agent | Paths |
|---|---|---|
| Fidelity | `orch-lens-fidelity` | spec body, comments file, plan handoff, `<dir>/lens-fidelity.md` |

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

After the last round, return every round's changelog to the flow skill, in
round order, as the path of each round's `<dir>/changelog.md`, so the
implement phase carries the disposition without a network call. Its layout
in `02-spec.md` is the **Spec review changelog** section of `orch-handoff`'s
`02-spec.md` template. When a round retired the breakdown, breaking the
issue down again is left to `orch-flow`'s spec phase step 5, which then sees
`ticket exists` exit 1.
