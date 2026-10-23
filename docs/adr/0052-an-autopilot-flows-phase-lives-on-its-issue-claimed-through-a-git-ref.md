# An autopilot flow's phase lives on its issue, claimed through a git ref

Amends ADR-0034, ADR-0041 and ADR-0050.

Every flow boundary needed a human `/clear` and `/orchestrator:next`. Headless
sessions can start phases, but they need a phase record every session can reach
and a mutual-exclusion primitive across watchers.

Decision: the phase label on the issue is the record; handoffs and questions are
issue comments; a claim is a create-only ref push (`refs/orch/claims/<n>`,
`--force-with-lease` with an empty expect), the one atomic compare-and-swap
GitHub offers; the cap counts claim refs and is soft.

It amends ADR-0034 (an autopilot flow's spec review is unattended too, not only
a quick implementation's), ADR-0041 (that review runs the plan's `Rounds`, not
1: the edits it stacks are those the human would accept anyway, and a
fundamental item still reaches the human) and ADR-0050 (an autopilot flow's spec
phase skips the rewrite decision, and its batch is unattended: the human kept
control of the spec at the planning close instead). Each of those ADRs gains a
line pointing at this one.

## Considered Options

- **The `orch:running` label as the claim.** Rejected: adding a label is
  idempotent, so both racers succeed, and actors of one user are
  indistinguishable.
- **Claim comments with a lowest-comment-ID tiebreak.** Rejected: needs a settle
  delay and a comment per phase. Kept as the fallback if GitHub does not honour
  an empty lease.
- **Slot refs for an exact cap.** Rejected: a second claim and crash cleanup for
  an overshoot of one.
- **`state.json` as the phase record.** Rejected: not reachable from every
  session or runner, and relabel-to-redo would not work.
