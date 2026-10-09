# An adopted issue is validated once, at init; nothing records its origin

A flow's issue arrives one of two ways: `to-spec` publishes it during the spec
phase, or the flow adopts one already open, via `init --issue N`. Adoption is
checked at init only: the issue must exist, be open, and carry the repo's
`ready-for-agent` triage label, or `init` dies immediately - mirroring how
`branch create` and `pr open` already die on their own preconditions rather
than deferring the check to a later phase.

Beyond that one-time gate, nothing distinguishes an adopted issue from a
published one. `doctor --flow`'s issue check - still exists, still open - runs
for every flow with a non-null `state.issue`, whichever path put it there, and
`state.json` carries no field recording which. The label is never re-checked:
doctor mirrors `check_flow_pr`'s own shape (open, like a PR is open or merged
or closed), and a label is a triage state, not a flow state - once a flow is
running against an issue, the spec review is that issue's judgement now, not
triage's.

Tracking provenance would let some later check treat adopted issues
differently, but nothing downstream needs that distinction recorded: the
spec phase forks on whether `state.issue` is already set at the phase's
start - unset runs `to-spec`; set asks the human whether to rewrite the
issue from the plan, unless a `pre-redo-spec-*` handoff folder shows a
`redo spec` already ran - and both readings come from what is already on
disk. A field recorded for a distinction nothing needs is state carried for
nothing.

## Consequences

A maintainer removing `ready-for-agent` from an issue mid-flow doesn't stop
the flow - doctor never looks at the label again after init. If a future
phase needs to know how its issue arrived, that isn't recoverable from
`state.json` today and would need a new field added then, not now.
