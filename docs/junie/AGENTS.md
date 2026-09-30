<!-- orchestrator:begin -->
## orchestrator plugin: planning

While planning (grilling, wayfinder, or any plan agent session) and before an
orchestrator flow or a quick implementation has started, do not edit source
files. Glossary and ADR changes (CONTEXT.md, CONTEXT-MAP.md, docs/adr/) are
recorded, not edited: write the exact new or replaced wording, and where it
goes, into the plan, so the spec carries it verbatim for the implementer, or
into the linked issue's body for a quick implementation. Planning artifacts
(docs/agents/, .scratch/, .orchestrator/) are fine to edit.

<!-- Temporary workaround for https://youtrack.jetbrains.com/issue/JUNIE-5493
     (Junie's capability filter hides plugin custom agents). Remove this section once fixed. -->
## orchestrator plugin: custom agents

The orch-* custom agents below are the orchestrator plugin's agents (`orchestrator:orch-*`).

The orch-flow skill depends on the orch-implementer, orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, orch-lens-implementability, orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-flow skill is used, those nine custom agents are required too.

The orch-quick-implement skill depends on the orch-implementer, orch-reviewer-spec, orch-reviewer-standards, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-quick-implement skill is used, those six custom agents are required too.

The orch-review skill depends on the orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-review skill is used, those four custom agents are required too.

The orch-spec-review skill depends on the orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-spec-review skill is used, those four custom agents are required too.
<!-- orchestrator:end -->
