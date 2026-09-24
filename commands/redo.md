---
description: Step the active flow back one phase and re-run it.
---

A deliberate rewind, for when a phase produced something wrong. Call the Skill
tool with `orchestrator:orch-flow` and follow its **Redo** section.

Do not confuse this with `/orchestrator:next`: `state.phase` names the phase that
runs *next*, so redoing the phase that just finished means stepping back one
first.
