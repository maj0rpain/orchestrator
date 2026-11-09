---
description: Audit the repo's documentation (prose docs, comments and docstrings, agent and skill instruction files) against the code, rank the disagreements in an HTML report; picked findings go to the planning interview, are filed as issues, or both. Changes no file.
argument-hint: "[<direction>]"
---

Call the Skill tool with `orchestrator:orch-audit-docs` and follow it. The
user's arguments, a path or direction to scope by when given, are: `$ARGUMENTS`
