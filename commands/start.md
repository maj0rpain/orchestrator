---
description: Start an orchestrated flow from an approved plan.
argument-hint: "[slug] [--issue N]"
---

The user has approved a plan in this session. Call the Skill tool with
`orchestrator:orch-flow` and follow its **Starting a flow** section.

`$ARGUMENTS` may carry a slug, `--issue N`, both, or neither. Pull `--issue N`
out first if present - it adopts an already-open, already-triaged issue as the
flow's spec instead of letting the spec phase publish a new one. Whatever
remains (with the `--issue N` tokens removed) is the slug to use instead of
deriving one from the plan; empty means derive one as usual.

This runs in the planning session on purpose: it holds the only copy of the plan.
Write the handoff before running anything that can fail.
