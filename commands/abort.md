---
description: Archive the active orchestrator flow and clear its state.
---

Call the Skill tool with `orchestrator:orch-flow` and follow its **Abort** section.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
one directory above this command's own directory (the plugin root).

Confirm with the user first, then run `"$ORCH" archive`.
It moves the flow into `.orchestrator/archive/<timestamp>-<slug>/` rather than
deleting it - the moment you want a handoff back is the moment you just threw it
away.

Archiving leaves the branch, the spec issue, and the PR alone. Tell the user what
still exists so they can clean up if they want to.
