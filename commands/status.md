---
description: Show the active orchestrator flow's phase, issue, branch, and PR.
---

Run both, and report their output:

```
${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh status
${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh state validate
```

Read-only. Do not start, advance, or repair a flow from this command - if
`state validate` reports a problem, say what it found and stop.
