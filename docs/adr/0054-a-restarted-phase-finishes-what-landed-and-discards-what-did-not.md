# A restarted phase finishes what landed and discards what did not

Amends ADR-0036: its rule that ticket worktrees are never removed with force,
and its rule that an interrupted run's leftovers stop the next implement phase
until a human clears them.

A restarted phase resumes from its save points and the durable records -
`applied.log`, a merged ticket branch, a saved report, `state.branch`,
`state.pr` - and discards uncommitted or unreported work. The one exception is
uncommitted changes on the flow's own branch in an interactive flow's main
checkout, which are refused with the discard command named.

## Considered Options

- **Resuming a dead subagent's partial work.** Rejected: nothing checked it
  against the acceptance criteria.
- **Refusing and asking the human.** Rejected: #1463 retries unattended, and
  the interactive flow gains nothing from a manual untangle.
