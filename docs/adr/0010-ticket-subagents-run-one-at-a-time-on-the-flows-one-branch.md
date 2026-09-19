# Ticket subagents run one at a time, on the flow's one branch

The implement phase and quick implementation both build a ticket breakdown by
handing each ready ticket to a fresh subagent (`skills/flow/SKILL.md`'s
Phase: implement step 3, added in #86; `skills/quick-implement/SKILL.md`'s
step 4, added in #87). That subagent resolves and follows `implement` or
`tdd` itself, builds on the branch the driving session already checked out,
and commits its own work there - never a branch or PR of its own. The
driving session dispatches
tickets strictly one at a time: it only calls `"$ORCH" ticket next` again,
and only dispatches the next subagent, once the previous one's report is
back and `"$ORCH" ticket close <n>` has run.

Two alternatives were considered and rejected. Running the frontier's
independent tickets in parallel - several subagents dispatched at once
wherever `ticket next` returns more than one ready ticket - was rejected
because every ticket commits to the same branch: two subagents writing to
one working tree at once is a race, not a speedup, and the frontier's
"ready" set says nothing about which tickets are safe to interleave, only
which have no open blocker. Giving each ticket its own branch and PR was
rejected because it would turn one flow into several: the flow's contract is
exactly one issue, one branch, one PR, and a review phase built to look at
one accumulated diff from one base SHA - not something to reconcile across
several ticket-sized PRs afterward.

So the frontier is worked sequentially even though GitHub can report more
than one ticket ready at a time, and a ticket subagent's write access is
scoped to "the current branch, already checked out" rather than to a branch
of its own.

## Consequences

Throughput is bounded by ticket count, not by how many the frontier could
theoretically run at once - the tradeoff is accepted because a flow's win is
one coherent, reviewable diff, not wall-clock time. Because a subagent
carries only its ticket's number and body (not the driving session's
reasoning, and not a fork of it) and reports back structurally rather than
blocking on a human mid-ticket, the sequencing also stays cheap: the driving
session pays for one report and one `ticket close` per ticket, not a
teardown and rebuild of shared state between them. A ticket that can't be
completed exactly as written comes back as a deviation in that report
instead of stalling the loop, and every deviation is collected into the
phase's one handoff (`skills/handoff/SKILL.md`) rather than scattered across
per-ticket artefacts - there is still only one implement-phase handoff and
one review, of the whole diff, same as before this feature existed.
