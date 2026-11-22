# Shared helper for the "does an active flow hold this?" guard

This project does not extract a shared helper, such as
`active_flow_holding <issue> [branch]`, for the guard that `spec-review begin`
and `review-pass begin` each run before they begin. The two guards look alike,
but they ask different questions and give different answers. Both nouns are
converted to Python - `review-pass` in #4002, `spec-review` in #4013 - so both
guards are Python again: `begin` in `scripts/orch_py/orch/spec_review.py`,
reading the state through `orch.flow_state.flow_state_get_many`, and `begin`
in `scripts/orch_py/orch/review_pass.py`, through
`orch.flow_state.flow_holding_phase`. Sharing a language does not change the
case below, which rests on how the two react.

## Why this is out of scope

Both guards read `phase` and `issue` from `state.json` when it exists, skip a
`done` flow, and switch on the phase. Past that, they differ in every branch:

- **What counts as held.** A spec review is refused only when the flow holds
  the same *issue*. A review pass is also refused when the flow holds the
  current *branch*, because the change under review is what matters.
- **What each phase means.** At `spec`, a spec review is told the flow's own
  spec phase will review the issue, while a review pass is told the change
  has not been built yet. At `implement` or `review`, a spec review is told
  the spec cannot change behind the ticket subagents and to run redo, while a
  review pass is told the change belongs to the review loop and to run next.

```python
# spec-review begin: held means the same issue
if phase != "done" and state["issue"] == issue:
    ...
```

```python
# review-pass begin, through flow_state.flow_holding_phase: held means the
# same branch or the same issue
if state["branch"] != branch and (not issue or state["issue"] != issue):
    return None
```

Only the fallback for a phase that is not a flow phase is word for word the
same. A helper that covered both callers would need a mode for the
issue-or-branch match and would still leave each caller its own phase switch
for its messages, so it would save that one fallback line. That is the same
balance as `review-terminal-state-shared-accessor.md`: callers that react
differently keep their own few lines. It also fits the file's
transaction-script style (`command-function-decomposition.md`), where a
command shows its whole precondition check in place. Merging per-phase
`case` ladders is turned down separately in `phase-order-single-table.md`.

Reconsider if a third command grows the same guard *with the same reactions*,
or if the fallback grows beyond one line.

## Prior requests

- #346: "cmd_review_pass's active-flow guard duplicates cmd_spec_review's" (review-loop Standards nit against PR #345)
