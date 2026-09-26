# Ticket subagents check acceptance criteria and leave review to the loop

Supersedes ADR-0018's note that the implement phase's ticket subagents still
use `code-review`, and ADR-0010's "resolves and follows `implement` or `tdd`
itself": a ticket subagent now follows `tdd` only.

A ticket subagent no longer follows upstream `implement` verbatim. It is
started as the plugin's own `orch-implementer` agent, whose brief the plugin
owns: build the ticket test-first through `mattpocock-skills:tdd`, verify,
commit, then check the diff against the ticket's acceptance criteria - no
sub-agents, no `code-review`. A criterion it cannot meet alone is reported
as unmet, never asked about, and the review loop's Spec axis judges it as an
ordinary finding - not a deviation, which ADR-0002 would demote to a note. A
call it cannot make alone is still its deviation. The same agent serves the
implement phase and quick implementation.

Upstream `implement` closes with `/code-review`, which costs every ticket the
skill body and two reviewer sub-agents. The review loop then reviews the
whole change from the base SHA on both axes, every iteration, so per-ticket
review mostly finds the same things one phase earlier. The acceptance
self-check keeps what per-ticket review was worth on a multi-ticket
breakdown - catching a ticket that missed its criteria before the next one
builds on it - at none of the sub-agent cost.

Owning the brief also lets the plugin restrict the agent mechanically: its
tools are Read, Edit, Write, Grep, Glob, Bash, and Skill. Without Agent it
cannot start sub-agents; without a question tool it cannot block on a human.
Both were rules the brief could only ask for.

The trade-off: a defect per-ticket review would have caught now surfaces in
the review loop, where fixing it spends an iteration of the budget. And
changes to upstream `implement` reach the flow only when someone copies them
across.

## Considered Options

- **Keep following `implement` verbatim.** Rejected: the per-ticket review
  duplicates the review loop at the highest per-call cost in the phase.
- **Package the brief as an agent but keep `code-review`.** Rejected: it
  saves the brief, a few hundred tokens, and leaves the real cost in place.
- **Drop per-ticket checking entirely.** Rejected: on a multi-ticket
  breakdown a later ticket would build on an earlier one that missed its
  criteria, and nothing would notice until review.
- **Pin a cheaper model now.** Deferred: measure this change on a real flow
  first, so the model change can be judged on its own numbers.
