# Every ticket builds in its own worktree

Amends ADR-0036, ADR-0010 and ADR-0012: a collapsed breakdown's one ticket, a
cap of 1 and a host with no background subagent no longer build on the flow's
one branch with no worktrees.

Every ticket subagent builds in its own ticket worktree and is merged by
`orch.sh ticket merge`, the collapsed and one-at-a-time paths included: one
path, and a merged branch as the one proof a ticket landed. The driver loop's
sequential path still runs one ticket at a time, but each ticket gets
`ticket-worktree add <n>`, a `Worktree:` line in the dispatch, `ticket merge`,
then `ticket-worktree remove`; a host that cannot start a background subagent
runs the subagent in the foreground. A collapsed breakdown builds in
`t<spec issue>`, which is merged and removed and never closed.

## Considered Options

- **Keeping the sequential path on the flow's branch.** Rejected: it is the
  only path whose death dirties the flow's branch, and the only one where "did
  this ticket land" has no durable answer.
