# A flow's spec review runs each round in its own session

Supersedes ADR-0041 in part: its rejected option of storing the count in
`state.json` is now answered by storing it in the round marker, a file in the
handoff folder that is not a handoff, instead of `state.json`; and its
"recommending 3" becomes a recommendation sized to the spec, defaulting to 2.

Every round of a flow's spec review ran in one session. Each round's four lens
outputs, its batch and its apply output stayed in the context window, so by the
last round the session was crowded with material the next round never needed:
the only things a round hands the next are the Implementability lens's code map
and the settled file, both on disk. A third round also rarely found anything the
first two had not, yet 3 was recommended whether the spec touched one line or
five modules.

So in a flow, each spec review round but the last runs in its own session. After
round k of n (k < n) has applied its answer and written its changelog, `orch.sh
spec pause --round <k>/<n>` writes the round marker and prints the standard stop
block. The fresh session's spec phase reads `orch.sh spec round` and goes
straight to the next round, asking neither the rewrite question nor the round
count; the whole count still runs. The last round runs in the same session as
the ticket breakdown, the `02-spec.md` handoff and `phase advance`. Each round
works in a fixed directory, `.orchestrator/spec-rounds/<k>/`, which `orch.sh
spec round-dir <k>/<n>` makes ready, so no path is recorded anywhere. The
recommended round count is sized to the spec: 1 for a one-site spec, 2 by
default, 3 for a large or cross-cutting one. Blueprint and on-demand reviews
stay single-session.

## Considered Options

- **One session for all rounds.** Rejected: the context fills with lens output
  and batches, and nothing in it is needed by the next round, since the code map
  and settled file carry the rulings.
- **The count in `state.json`.** Rejected: a marker leaves nothing behind once
  the phase advances, and is already how the spec phase resumes.
- **Splitting blueprint and on-demand reviews too.** Deferred: no flow owns
  their resume.
