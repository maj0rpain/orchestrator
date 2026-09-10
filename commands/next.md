---
description: Run the next phase of the active orchestrator flow.
---

Call the Skill tool with `orchestrator:flow` and follow its **/orchestrator:next**
section: validate state, read the current phase, run that phase, write its handoff,
print the boundary, stop.

Run this in a fresh session. If the context still holds the previous phase, tell
the user to `/clear` first rather than continuing.
