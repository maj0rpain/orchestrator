# A merge conflict is resolved, not rebuilt

Supersedes in part ADR-0036: its rejection of a merger subagent no longer holds; its parallel worktrees and linear history still do.

ADR-0036 redid a conflicted ticket from scratch, judging an agent resolving code it did not write riskier than a rebuild. That rebuild repeats a whole ticket's work to settle a few hunks, and nothing at all handled the base branch moving under an open PR. Now a conflicted ticket's own implementer is resumed to rebase and resolve in its worktree: it wrote the code, so it already holds the intent. Where it cannot be resumed, a fresh resolver takes over, and a failed resolution still falls back to the rebuild. A flow's or quick implementation's branch is brought up to date with its base branch by merging, never rebasing: its PR is already pushed, and a merge resolves each conflict once. A resolver reads each side's primary sources (commits, issues, PRs) before choosing, and every intent it drops is listed where a reviewer or human reads it.

## Considered Options

- **Keep the rebuild.** Rejected: it costs a full ticket and does nothing about base drift.
- **Always a fresh resolver for tickets.** Rejected: it has to reconstruct the intent the ticket's implementer already holds.
- **Rebase the branch onto the base.** Rejected: it force-pushes a live PR and resolves once per commit.
- **Sync only before `review ready`.** Rejected: a resolution made there would reach a ready PR unreviewed.
