# A spec question met in a review pass reaches a human before the PR is ready

Supersedes in part ADR-0029: a review pass gains a third outcome beside fix and decline, and a standalone review pass may turn a PR into a draft or mark one ready. Supersedes in part ADR-0042: outside the review loop, the definition of a spec question has no "only a major" clause.

ADR-0042 made a spec question the review loop files hold the PR in draft, and left the review pass out. A pass files nothing, and the session running it fixes or declines each finding itself. In a quick implementation that session runs unattended, so it could decline a behaviour decision the spec left open, or settle it silently by picking a behaviour, and then open a PR that is not a draft: the human never ruled on it. A standalone review pass had the same gap with a human present, and its rulings, when there were any, never reached the spec, so a later review could raise the same question again.

So a spec question met in a review pass now reaches a human before the PR is ready. The session that ran the pass uses the review loop's content test - a finding whose fix needs a decision about what the change does that the spec, plan and deviations leave unsettled - without the "only a major" clause, since a pass has no severity. A finding that the change contradicts what the spec clearly asks for is fixed, and a decision about structure only is fixed or declined as before. A spec question is a third outcome beside fix and decline: never fixed by picking a behaviour, never declined, and recorded as `` `file:line` - <the open behaviour, phrased as a question> ``.

A quick implementation whose pass meets one opens its PR as a draft, with `pr publish --draft`, and its body's always-present **Spec questions** heading names each. A standalone review pass puts its questions - its own, and the PR's earlier ones no **Spec rulings** heading or spec-issue ruling already answers - to the human in the session, as one batch with a recommended answer each. It posts each ruling on the spec issue as `Spec ruling: <question> - <answer>`, and fixes per the rulings in its one fix commit. Its PR comment gains **Spec rulings** and **Spec questions** headings. A question left unruled turns an open PR into a draft with `pr draft`; once every spec question the PR's body and comments carry is ruled, and none of the pass's own is left unruled, `pr ready` marks it ready. With no open PR the questions are still asked and the rulings recorded on the spec issue. Both ops refuse a branch an active flow holds, whose PR goes ready only through the review loop.

## Considered Options

- **Stop before the PR.** Rejected: loses visible work, and the human has nothing to rule on in context.
- **List the question under Review and open ready.** Rejected: this is the silent path the change closes.
- **Ask mid-run in a quick implementation.** Rejected: breaks hands-off (ADR-0034).
- **Keep rulings only on the PR.** Rejected: the spec stays silent and a later review raises the question again.
- **Edit ADR-0042 in place.** Rejected: ADRs here are amended by supersession.

## Consequences

A quick implementation's PR may open as a draft, and a standalone review pass may convert a PR to draft or mark one ready. A spec ruling made in a standalone review pass lives on the spec issue, where every later Spec axis reads it and the next spec review folds it into the body.
