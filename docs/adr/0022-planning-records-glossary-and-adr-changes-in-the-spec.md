# Planning records glossary and ADR changes in the spec, not the files

The planning allowlist let a planning session edit `CONTEXT.md`,
`CONTEXT-MAP.md`, and `docs/adr/` in place, because `domain-modeling` and
`improve-codebase-architecture` update them inline. Those edits landed in the
wrong place. A ticket subagent reads only the issue body, so an uncommitted
glossary edit on the planning checkout never reached it. Committed from
planning, the glossary or an ADR would describe behaviour that has not been
built, on the default branch, and might never be built if the plan changes.
And wording committed from planning gets no review, while wording that lands
with the change is checked by the review loop's Spec axis.

Planning never edits the glossary or ADRs. They are planning records, and they
leave the planning allowlist, which keeps only `docs/agents/`, `.scratch/`,
and `.orchestrator/`. A change planning decides for a record is written into
the plan word for word - the new or replaced text, naming the file and entry -
so the spec carries it verbatim as an Implementation Decision, and it lands in
the same PR as the behaviour it describes. For a quick implementation, the
linked issue's body carries the wording instead. Where the edit guard arms, an
edit to a record while planning is denied with a reason saying where the
wording goes; where it does not arm (ADR-0013), the flow-start working-tree
check refuses a dirty record with the same redirect.

A second decision: the edit guard and the grilling hook treat a flow at phase
`done` as no flow. ADR-0009 retired a `done` flow for `init` only, and the
hooks never took that rule up, so any `.orchestrator/state.json` stood them
down - a checkout whose last flow was finished had no guard at all. Only a
phase of exactly `done` keeps them armed; any other `state.json`, including an
unreadable one or one with no `phase`, still stands them down.

## Considered Options

- **Keep the records in the allowlist.** Rejected: the edits stay invisible to
  the implementer, unreviewed, and ahead of the behaviour they describe.
- **Allow the edits, but commit them from planning.** Rejected: the default
  branch then describes unbuilt behaviour.

## Consequences

`domain-modeling`'s "update CONTEXT.md inline" is denied under the
orchestrator, and redirected into the plan, by design. The Fidelity lens
already reports a plan decision the spec dropped or altered, so a dropped
glossary or ADR wording is caught between plan and spec with no new required
section. Quick implementation's spec review is standalone and runs no Fidelity
lens, so there the rule rests on the wording reaching the linked issue's body:
written when quick implementation publishes the issue, or by its unattended
rewrite of an interviewed issue.

## Note: the grilling hook no longer stands down beside a flow

Since #640 the grilling hook sends the planning message beside a flow at any phase other than `done`, as a variant naming that flow, instead of standing down. The edit guard still stands down as the second decision above says.
