---
description: Diagnose the machine, the repo, and the active flow.
---

Run it, and report its output:

```
${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh doctor
```

Read-only. `doctor` reports what is wrong and prints the command that fixes it;
running those commands is the user's call.

A `FAIL` exits non-zero and would block the flow. A `warn` is an observation and
does not.
