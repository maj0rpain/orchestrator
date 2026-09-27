---
description: Review any spec issue on demand, outside a flow - a standalone spec review.
argument-hint: "<issue>"
---

Call the Skill tool with `orchestrator:orch-review-spec` and follow its
**Standalone spec review** section, for the issue number the user gave. The
user's arguments are: `$ARGUMENTS`

If the arguments hold no issue number, ask the human for one and wait. Never
take the number from `.orchestrator/state.json` or the active flow.
