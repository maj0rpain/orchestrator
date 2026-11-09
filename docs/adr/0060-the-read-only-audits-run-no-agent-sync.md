# The read-only audits run no agent sync

ADR-0052 (on Junie the agent setting travels in generated agent copies) has
every skill run `agent sync` on Junie once per run, before its first plugin
agent. The audit skills, `orch-audit-docs` and `orch-audit-code`, are the
exception: they change no file in the checkout, and `agent sync` writes
`.junie/agents/`. On Junie their hunters carry the `auditor` setting only from
copies the user wrote by running `orch.sh agent sync` themselves, and otherwise
start with no setting. We chose this over syncing anyway, which would break the
audits' read-only promise.
