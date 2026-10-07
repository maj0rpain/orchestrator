# Fixes remove the root cause

Supersedes in part ADR-0024 and ADR-0026: the implementer's minimal implementation of a defect fix, and the fixer's "then the smallest fix", become the smallest fix that removes the cause. ADR-0016's rules for majors and nits stand unchanged.

Filed bugs kept tracing back to fixes that made the reported case pass while the cause stayed live elsewhere: a sibling copy (#494, #485), another caller, another input. Each became the next filed issue. So every fix of a defect - by a ticket subagent on a ticket that fixes a defect, or by the fixer on a blocking finding - names its cause, searches for every site the cause acts at, and fixes them all. The cause is settled as early as possible: the interview treats it as a design decision, and a bug spec records it, with its sites, in a **Root cause** subsection the Spec axis holds the change to. The Standards axis flags a possible symptom fix in any hunk that fixes a defect.

When removing the cause needs a change beyond the ticket's or finding's reach, the agent makes the symptom fix and records the cause - the implementer as a deviation, the fixer as a major waiting to be filed - instead of choosing a design unattended.

## Considered Options

- **Leave fixes minimal and rely on filed findings.** Rejected: that is the regression loop this ADR exists to end.
- **Widen major and nit fixes too.** Rejected: ADR-0016's guard against #8's fix-draws-finding churn still holds, and a major whose fix changes behaviour was never a major fix.
- **Put the rule in this repo's coding standards only.** Rejected: the agents ship to every repo the plugin runs in.

## Consequences

Blocking fixes may touch more lines than their finding names. Those lines are loop-authored, so ADR-0016's exclusion still files any major or nit found on them.
