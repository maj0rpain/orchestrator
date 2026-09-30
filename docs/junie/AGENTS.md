<!-- orchestrator:begin -->
<!-- Temporary workaround for https://youtrack.jetbrains.com/issue/JUNIE-5493
     (Junie's capability filter hides plugin custom agents). Remove once fixed. -->
## orchestrator plugin: custom agents

The orch-* custom agents below are the orchestrator plugin's agents (`orchestrator:orch-*`).

The orch-flow skill depends on the orch-implementer, orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, orch-lens-implementability, orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-flow skill is used, those nine custom agents are required too.

The orch-quick-implement skill depends on the orch-implementer, orch-reviewer-spec, orch-reviewer-standards, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-quick-implement skill is used, those six custom agents are required too.

The orch-review skill depends on the orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-review skill is used, those four custom agents are required too.

The orch-spec-review skill depends on the orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-spec-review skill is used, those four custom agents are required too.
<!-- orchestrator:end -->
