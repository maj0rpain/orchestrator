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

Steps 1 to 3 run at the start of every round, each round in its own
directory: each round reads the body the previous round published.

`<dir>` is what `bash "$ORCH" spec round-dir <k>/<n>` prints, run first for
round k of n: `.orchestrator/spec-rounds/<k>/`. It makes the directory
ready - emptied, every other round's directory deleted on round 1, and
round k-1's `map-implementability.md` and `settled.md` copied in on later
rounds, each when it exists - and writes the round marker, so a session that
fails after the round resumes from it. This is how the code map and the
settled file carry over in a flow, across sessions too. A failure stops the
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
3. Resolve the other files the lenses read, and record the paths:
   - the plan handoff: `bash "$ORCH" handoff path spec` (always `01-plan.md`);
   - the glossary, the decisions and the repo root, as the main file's
     **Standalone spec review** step 4 resolves them. A failed `glossary
     match` stops the phase exactly as a failed body fetch does.

The main file's rule that nothing from this session's conversation reaches a
lens holds here too: not the plan as you remember it, not `orch-to-spec`'s
reasoning, not the seams as agreed in chat.

## The Fidelity lens

A flow runs four lenses: the three in the main file's table, and Fidelity,
started with them, all on the `lens` setting. Each round's session reads it
itself, with `bash "$ORCH" agent get lens` before its lenses start, as the
main file's **The lenses** says: a round in a session of its own never reuses
an earlier session's read. The Fidelity row:

| Lens | Agent | Paths |
|---|---|---|
| Fidelity | `orch-lens-fidelity` | spec body, comments file, plan handoff, `<dir>/settled.md`, `<dir>/lens-fidelity.md` |

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
