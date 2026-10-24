# The spec handoff copies nothing its issue already holds

Supersedes ADR-0004 in part: the spec handoff no longer copies the review's
changelog or the seams.

ADR-0004 had `02-spec.md` carry the spec review's changelog and the seams, so
that nothing downstream had to remember a reversal. Every round already posts
its changelog as a comment on the spec issue, and the issue's **Testing
Decisions** records the seams. No later phase reads either copy: the review
loop learns of a reversal from the plan handoff's amended entry. In an autopilot
flow, where the handoff is itself an issue comment, the copy showed every round
twice on the same issue.

Decision: `02-spec.md` carries neither a **Spec review changelog** nor
**Seams**. The changelog lives in its round comments and the seams in the
issue's **Testing Decisions**, which the implement phase reads.

## Considered Options

- **A one-line pointer to the round comments.** Rejected: the handoff already
  names the spec issue, and the comments are on it.
- **Keep the copies in interactive flows only.** Rejected: an interactive flow
  posts the same round comments, and no reader there differs.
