# Ticket subagents of one frontier run in parallel, each in its own worktree

Supersedes in part ADR-0010: its "one at a time" no longer holds; its "one issue, one branch, one PR, one review" still does.

ADR-0010 rejected building the frontier's ready tickets at once because every ticket committed to the same working tree, and two subagents writing to one tree is a race. A git worktree per ticket removes that race. So the implement phase and quick implementation now build up to a per-clone cap of ready tickets at once (`orchestrator.parallel`, default 3), each ticket subagent on its own ticket branch in its own ticket worktree, started in the background. When one reports, `orch.sh ticket merge` rebases its branch onto the flow's branch and fast-forwards it, and only then is the ticket closed, so a dependent never forks before its blocker's work has landed. The review still sees one linear diff from one base SHA.

## Considered Options

- **The Agent tool's native `isolation: "worktree"`.** Rejected: it is Claude Code only, the plugin cannot pin which ref it forks from, and its worktrees fall outside `orch.sh`'s tests and cleanup.
- **A merger subagent**, as `implement-spec` uses. Rejected: a clean rebase needs no agent, and an agent resolving conflicts in code it did not write is riskier than redoing the ticket on the updated branch. A conflicted ticket is instead redone alone once nothing else is in flight, which cannot conflict again.
- **An exploration subagent** writing shared notes before implementation. Deferred: tickets and their spec's Testing Decisions already serve as context pointers; revisit if parallel implementers measurably re-explore the same code.
- **Ticket worktrees as sibling directories**, as ADR-0008 planned for second flows. Rejected: they sit outside the session's project directory, so every implementer edit would draw a permission prompt. They live under `.orchestrator/worktrees/`, excluded from git.

## Consequences

Throughput is bounded by the frontier's longest chain and the cap, not by ticket count. Two tickets that pass alone can fail together, so the combined branch is verified once after the frontier is exhausted, and that run, not the last ticket's, is the recorded verification. A cap of 1, a collapsed breakdown, or a host without background subagents keeps ADR-0010's one-at-a-time loop on the one branch, with no worktrees; the entry check and the combined verification run on every path. Ticket worktrees are never removed with force: "never force" protects dirty worktrees, which hold uncommitted work. The one sanctioned discard is a conflicted attempt's clean, unmerged ticket branch, because its ticket is rebuilt from scratch and the attempt is not the only copy of anything the ticket asks for. An interrupted run's leftovers are reported by `doctor --flow` and stop the next implement phase or quick implementation until a human clears them, and `archive` refuses while any exist, since moving a worktree breaks git's record of it. This narrows ADR-0009: `init` still archives a done flow itself, but, like `archive`, refuses while a ticket worktree is left over.
