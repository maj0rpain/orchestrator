---
description: Diagnose the machine, the repo, and the active flow.
---

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
one directory above this command's own directory (the plugin root).

Run it, and report its output:

```
"$ORCH" doctor
```

Read-only. `doctor` reports what is wrong and prints the command that fixes it;
running those commands is the user's call.

A `FAIL` exits non-zero and would block the flow. A `warn` is an observation and
does not.
