# A 0/1-ticket breakdown collapses onto the parent issue

`to-tickets`' quiz can approve a breakdown that resolves to zero or one
ticket - the work turns out too small to split, or splits into exactly one
item. `skills/flow/SKILL.md` (the spec phase's `to-tickets` step, and the
implement phase's ticket-frontier loop) and
`skills/quick-implement/SKILL.md` (its ticket-publish step, and its
implement loop) special-case this, added in #101 against parent issue #99:
`to-tickets`' own publish step is skipped entirely - no child sub-issue is
created - the drafted ticket's "What to build"/"Acceptance criteria" (when
there is one) is folded into the parent issue's own body instead, via the
stateless spec fetch/update primitives (flow) or issue fetch/update
primitives (quick implementation), and exactly one subagent is dispatched
against the parent directly, rather than a `ticket next`/`ticket close`
loop against it.

A reader watching a flow or quick implementation run this for the first
time would be surprised: `to-tickets` runs to completion, the human
approves the breakdown, and yet no sub-issue ever appears under the parent
on GitHub. Without this ADR that looks like a bug - a publish step that
silently failed - rather than the deliberate fast path it is. The
collapsed case is recorded, for the flow, as a plain-text sentinel in the
handoff's **Ticket breakdown** section - `None: work directly against
#<n>`, naming the spec issue itself - read by the implement phase the same
loose way this project already reads other plain-text conventions (e.g.
`Blocked by: None (can start immediately)`); quick implementation needs no
such record, since its own session stays alive from publish step through
implement loop.

This is also `to-tickets`' own instruction bent on purpose, not something
`to-tickets` does on its own: `to-tickets` itself says never to close or
modify the parent issue. Both `SKILL.md` files call this out explicitly at
the point they take the exception, so a reader who only knows
`to-tickets`' contract isn't misled about who owns the write.

The alternative was to keep sub-issue mechanics fully uniform: publish a
sub-issue even for a single ticket, so every breakdown - however small -
looks the same to `ticket next`, to a human skimming the parent's sub-issue
list, and to every other place this project assumes a ticket is a
sub-issue. That uniformity was traded away here to avoid duplicate-issue
noise: a one-line fix doesn't need a child issue that exists for exactly as
long as the one subagent run that closes it, restating the parent's own
title and most of its body for no reader's benefit.

## Consequences

A flow or quick implementation that collapses dispatches its one subagent
straight at the parent issue, so `ticket next`/`ticket close` never run for
that breakdown - the implement loop must branch on the sentinel (flow) or
on step 2's own collapse decision (quick implementation) before entering
its frontier loop, rather than relying on an empty frontier to mean "done":
an empty frontier here means "never split out," not "already finished." A
human or agent inspecting a parent issue after a collapse finds its own
"What to build"/"Acceptance criteria" folded directly into the body rather
than a linked sub-issue, so any tooling that assumes ticket content always
lives one hop away in a sub-issue has to check for the collapsed case
first. The cost lands on `to-tickets`, which still carries its own "never
modify the parent" instruction verbatim in the upstream skill text - this
project's use of it is now inconsistent with that skill's contract by
design, recorded here so the inconsistency is never mistaken for a bug.
