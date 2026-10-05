<!-- orchestrator:begin -->
## orchestrator plugin: planning

While planning (orch-interview, grilling, wayfinder, or any plan agent session),
do not edit source files. Planning ends on a closing question with three
options - an orchestrator flow, a quick implementation, or a blueprint only
(publish the spec, offer a spec review, publish the ticket breakdown, then
stop) - and source edits wait until the human has picked the flow or a quick
implementation and it has started. Glossary and ADR changes (CONTEXT.md, CONTEXT-MAP.md, docs/adr/) are
recorded, not edited: write the exact new or replaced wording, and where it
goes, into the plan, so the spec carries it verbatim for the implementer, or
into the linked issue's body for a quick implementation. Planning artifacts
(docs/agents/, .scratch/, .orchestrator/) are fine to edit.

## orchestrator plugin: finding the plugin

To find the orchestrator plugin's `orch.sh` (`ORCH`), as its skills do:
If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install).
If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, find `orch.sh` as the running skill's own lookup says.
The plugin root is two directories above that `orch.sh`. Resolve `ORCH` and
the plugin root once per session and reuse them; do not probe for them again.

An orch-* skill or custom agent you cannot see is not a missing dependency: do
not stop. Take the plugin's fallback, from the plugin root's
`docs/host-capabilities.md`, and record it under **Host fallbacks** wherever
the running skill says:

- A hidden **skill**: read `skills/<name>/SKILL.md` under the plugin root and
  follow it in this session (**Invoke a skill from a step**).
- A hidden **agent**: start a fresh general-purpose agent, never a fork, with
  the prompt the skill gives, plus the path of `agents/<name>.md` under the
  plugin root to read and follow as its brief (**Start a fresh subagent**).

<!-- Temporary workaround for https://youtrack.jetbrains.com/issue/JUNIE-5493
     (Junie's capability filter hides plugin custom agents). Remove this section once fixed. -->
## orchestrator plugin: custom agents

The orch-* custom agents below are the orchestrator plugin's agents (`orchestrator:orch-*`).

The orch-flow skill depends on the orch-implementer, orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, orch-lens-implementability, orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-flow skill is used, those nine custom agents are required too.

The orch-quick-implement skill depends on the orch-implementer, orch-reviewer-spec, orch-reviewer-standards, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-quick-implement skill is used, those six custom agents are required too.

The orch-review skill depends on the orch-reviewer-spec, orch-reviewer-standards, orch-fixer, and orch-closer custom agents. Whenever the orch-review skill is used, those four custom agents are required too.

The orch-spec-review skill depends on the orch-lens-fidelity, orch-lens-consistency, orch-lens-testability, and orch-lens-implementability custom agents. Whenever the orch-spec-review skill is used, those four custom agents are required too.
<!-- orchestrator:end -->
