# Standalone spec review

A reference file of the `orch-spec-review` skill, read only for a
standalone spec review (outside a flow).

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
