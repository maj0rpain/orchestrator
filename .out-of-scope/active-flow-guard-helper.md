# Shared helper for the "does an active flow hold this?" guard

This project does not extract a shared helper, such as
`active_flow_holding <issue> [branch]`, for the guard that `cmd_spec_review`
and `cmd_review_pass` in `scripts/orch.sh` each run before they begin. The two
guards look alike, but they ask different questions and give different
answers.

## Why this is out of scope

Both guards read `phase` and `issue` from state when `$STATE` exists, skip a
`done` flow, and switch on the phase. Past that, they differ in every branch:

- **What counts as held.** A spec review is refused only when the flow holds
  the same *issue*. A review pass is also refused when the flow holds the
  current *branch*, because the change under review is what matters.
- **What each phase means.** At `spec`, a spec review is told the flow's own
  spec phase will review the issue, while a review pass is told the change
  has not been built yet. At `implement` or `review`, a spec review is told
  the spec cannot change behind the ticket subagents and to run redo, while a
  review pass is told the change belongs to the review loop and to run next.

```sh
# cmd_spec_review: held means the same issue
if [ "$phase" != done ] && [ "$held" = "$issue" ]; then ...
# cmd_review_pass: held means the same issue or the same branch
if [ "$phase" != done ] && { [ "$held" = "$issue" ] || [ "$held_branch" = "$branch" ]; }; then ...
```

Only the `*)` fallback for a phase that is not a flow phase is word for word
the same. A helper that covered both callers would need a mode for the
issue-or-branch match and would still leave each caller its own `case` for
its messages, so it would save that one fallback line. That is the same
balance as `review-terminal-state-shared-accessor.md`: callers that react
differently keep their own few lines. It also fits the file's
transaction-script style (`command-function-decomposition.md`), where a
command shows its whole precondition check in place. Merging per-phase
`case` ladders is turned down separately in `phase-order-single-table.md`.

Reconsider if a third command grows the same guard *with the same reactions*,
or if the fallback grows beyond one line.

## Prior requests

- #346: "cmd_review_pass's active-flow guard duplicates cmd_spec_review's" (review-loop Standards nit against PR #345)
