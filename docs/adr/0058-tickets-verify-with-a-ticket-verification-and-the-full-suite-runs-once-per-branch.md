# Tickets verify with a ticket verification; the full suite runs once per branch

A full run of this repo's suite costs about 22 CPU-minutes, and a flow ran it
about 9-12 times: once per ticket subagent, once at the combined-branch check,
once per review-loop fixer, and again for each suite-cost confirmation.

Decision: ticket subagents, fixers, resolvers and review pass sessions run the
repo's **ticket verification**, a cheaper command its instructions name beside
its full verification (`Ticket verification: <command>` and `Full verification:
<command>`); a repo that names none runs its full verification as before.
Driver loop step f runs the full verification once per branch, through
`suite-cost run`, and CI's required check stays the full gate.

Trade-off accepted: a ticket can go green while breaking something outside the
sections its change maps to. That is caught at step f or in CI, later than
before. In exchange, each ticket saves about 20 CPU-minutes.

## Considered Options

- **Porting the tests to another language.** Rejected: the cost is process
  creation inside orch.sh, not the test harness.
- **Rewriting orch.sh in a compiled language.** Rejected: months of work for
  the same result that running less gives now.
