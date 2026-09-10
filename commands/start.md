---
description: Start an orchestrated flow from an approved plan.
argument-hint: "[slug]"
---

The user has approved a plan in this session. Call the Skill tool with
`orchestrator:flow` and follow its **Starting a flow** section.

`$ARGUMENTS`, if non-empty, is the slug to use instead of deriving one from the
plan.

This runs in the planning session on purpose: it holds the only copy of the plan.
Write the handoff before running anything that can fail.
