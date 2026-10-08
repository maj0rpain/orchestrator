---
description: Turn the current conversation into a spec and publish it as a new GitHub issue, or with an issue number rewrite that issue as the spec, outside any flow.
argument-hint: "[<issue>]"
---

Call the Skill tool with `orchestrator:orch-to-spec` and follow it. With no
leading issue number it publishes a new issue; with one, it rewrites that
issue's body as the spec (rewrite mode). The user's arguments, passed through
unchanged, are: `$ARGUMENTS`
