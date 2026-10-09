# A spec review runs a human-chosen number of rounds

Supersedes in part ADR-0004: the spec review is no longer one pass.

ADR-0004 made the spec review one pass, because prose findings never converge and a second pass draws findings against its own edits. In practice one look misses gaps that fresh lenses catch on the edited body, and the human, who disposes of every finding, is the guard against churn: they can decline every edit in any round.

So a spec review now runs a round count of rounds. Each round runs the whole review over the body the previous round published, with its own batch question and its own changelog comment. It runs its whole count, as a review loop runs its budget, because each round is an independent look. A flow's spec phase and a blueprint ask the human for the count, recommending 3. A review run on demand runs 1 unless given `--rounds`. A quick implementation's unattended review stays at 1, because it is meant to be hands-off, and each extra round would stack more unreviewed edits on edits no human saw. A breakdown that a round retires is drawn again only after the last round, so later rounds cannot make it stale.

## Considered Options

- **Keep one pass; another look is another review.** Rejected: the human has to remember to run it again and pass the count themselves, in every flow.
- **Stop early on a round with no findings.** Rejected: the lenses are independent looks, and one empty round does not show that the next will be empty.
- **Store the count in `state.json` like the budget.** Rejected: a spec review starts and ends in one session, and each changelog's `Round <k> of <n>` header already records the count.
