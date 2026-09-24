---
description: Show the active orchestrator flow's phase, issue, branch, and PR.
---

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
one directory above this command's own directory (the plugin root).

Run both, and report their output:

```
"$ORCH" status
"$ORCH" doctor --flow
```

Read-only. Do not start, advance, or repair a flow from this command - if
`doctor` reports a problem, say what it found and stop.
