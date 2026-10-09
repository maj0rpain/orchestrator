# A spec question the review loop files holds the PR in draft

Supersedes ADR-0003 and ADR-0016 in part: their rule that a filed major never holds the PR out of ready no longer covers spec questions; their budget, fix rules, and filing stand.

In a Junie retro, a fixer met a finding that was really a question the spec never settled: whether a high-water mark should depend on the archive step. Under ADR-0003 and ADR-0016 it was left unfixed and filed, and the PR was marked ready anyway. The human then had to rule on it after the fact: the high-water mark should not depend on the archive step at all.

So a **spec question** - a major whose fix needs a decision about what the change does that the spec, plan and deviations leave unsettled: silent, ambiguous, or self-contradictory on it - now holds the PR out of ready. A finding that the change contradicts what the spec clearly asks for is still blocking, and a decision about structure only (which of two refactorings, which name) is still an ordinary filed major. ADR-0016's separate "would change behaviour" filing rule folds into it: a major whose fix changes behaviour the spec settles is blocking, and one whose behaviour the spec leaves unsettled is a spec question. Only a major can be one, and it is classified by its content, never by when or where it was found, after the two Authority demotions.

The driver's triage classifies one with the rule `spec question`, and so does the fixer for a major it could not fix because its fix needs that decision; reviewers still report unranked. The loop stays autonomous: it runs its whole budget and files as usual. **Ready** gains a fifth condition - no record of this loop lists a spec question waiting to be filed - and otherwise the loop ends in a bounded stop whose reason names each spec question, as `stop - spec question #<n>: <file>:<line> <title>`, or with `(not filed)` in place of the number when the closer could not file it. The closer's filed body carries a `**Spec question:**` line phrasing the open behaviour as a question, and its return names the spec questions it filed. A spec question a previous loop filed, met again on re-entry, does not block: the human re-entering review after the stop is the ruling.

## Considered Options

- **Pre-triage spec questions to `ready-for-human`.** Rejected: the human already rules at the bounded stop, and bypassing finding triage loses its check of whether a later change settled the question.
- **Every "needs a decision" major blocks.** Rejected: too broad - structural choices would stop most loops and undo the loop's autonomy.
- **Block while the filed issue stays open.** Rejected: needs a GitHub read at termination, and re-entering review is already the human's ruling.
- **Ask the human mid-loop.** Rejected: the loop stays autonomous and runs its whole budget.

## Consequences

A PR can still be marked ready with filed majors open, unless one is a spec question this loop filed. ADR-0016's separate "would change behaviour" filing rule is folded into spec question. Re-entry after such a stop is a fresh loop with its own budget.
