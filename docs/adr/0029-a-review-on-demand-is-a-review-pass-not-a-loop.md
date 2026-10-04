# A review on demand is a review pass, not a loop

Supersedes in part ADR-0021: a quick implementation's reviewer prompts no longer carry iteration `01` or a report path from `quick path`; both come from `review-pass begin`.

A human can now ask for a review of the branch they are on, against a given issue, outside any flow - after a quick implementation, say. That review is a **review pass**: the one pass quick implementation took before its PR opened, moved into the `orch-review` skill as its one definition, which quick implementation now calls. The session that runs it fixes what it agrees with, files nothing, and records what it declines: a quick implementation in its PR body, a standalone review pass in a PR comment, or in the session when there is no PR.

The review loop was the obvious home, with a budget of 1. It was rejected because its two defining rules are the opposite of what an on-demand review wants. The loop's driver never edits the change, and the loop files every major and nit it does not fix. A human asking for another look after a quick implementation wants the quick rules: fix what is agreed, say what was not, file nothing. A one-iteration loop would also bring flow state, a terminal state and a closer that a branch with no flow has no use for.

A branch or issue an active flow holds belongs to that flow: `review-pass begin` refuses it.

## Considered Options

- **A standalone entry in the review loop, with a budget.** Rejected: it either breaks the rule that the driver never edits, or files findings the human asked to have fixed.
- **A separate copy of the pass beside quick implementation's.** Rejected: two definitions of one review drift apart, as quick implementation's `code-review` pass once drifted from the loop (ADR-0021).
