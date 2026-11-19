# CI is the only full run where a repo names a branch verification

ADR-0058 kept one local full run per branch, at the combined-branch check. In
the autopilot container on 2026-11-12 to 2026-11-14 a flow still started the
whole suite about 3.4 times - step f's run and its reruns, full runs by
review-phase subagents, and ticket verifications that fell back to the whole
suite - on 8 CPUs, for a suite CI runs on every PR (#3179).

Decision: a repo's instructions may name a **branch verification** (`Branch
verification: <command>`). Driver loop step f runs it in place of the full
verification, the implement handoff records it, and the fixer is handed it; such
a repo's full verification no longer runs at step f, and CI is where the whole
suite always runs. A repo that names none runs its full verification at step f,
as before. In every repo, whether or not it names a branch verification, the
review loop looks at CI without waiting at each iteration's triage, and a
failing check the change can fix is a blocking finding of that iteration; the
one wait at Termination stays. A quick implementation, likewise in every repo,
waits for CI once after its PR opens and reports the result.

Trade-off accepted: a break outside what a change selects is first seen in CI,
after the PR is open. Suite growth is still guarded per change, by the suite
budget.

## Considered Options

- **Every repo that names a ticket verification drops the local full run.**
  Rejected: a repo with a slow suite and no CI would never run its whole suite.
- **Step f decides from evidence of CI.** Rejected: a workflow file existing
  does not prove it runs the whole suite, and step f runs before a PR exists.
- **Drop the combined-branch check.** Rejected: tickets built in parallel were
  each verified alone, and nothing else checks the merged combination before the
  PR opens.
- **Read CI only at Termination.** Rejected: a break only CI can see would cost
  a bounded stop and a re-entry, where CI's median of 3:25 usually ends inside
  one iteration.
