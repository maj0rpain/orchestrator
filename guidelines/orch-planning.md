# Orchestrator planning nudge

These guidelines apply only when a grilling session is running and no flow is active: the `grilling` skill is steering this session, and the repo has no `.orchestrator/state.json`. In any other session, ignore this file.

Planning is phase one of an orchestrated flow: plan -> spec -> implement -> review, each phase in a fresh session, connected by handoff files.

## While planning

- Keep this session to planning. Planning artifacts (CONTEXT.md, docs/adr/, docs/agents/, .scratch/) are fine to write; source files wait for a later phase. Offer no implementation.
- If the repo has no `docs/agents/issue-tracker.md`, tell the human now, before planning goes further: the spec phase will fail without it, and the fix is to run the mattpocock-skills `setup-matt-pocock-skills` skill first.

## At shared understanding

Ask the human a multiple-choice question (`AskUserQuestion`) with exactly these two options, and let the human choose; the next step is theirs:

1. **Start the orchestrator flow**: the full plan -> spec -> implement -> review pipeline, with its own handoff and review loop.
2. **Quick implementation**: skip the pipeline and implement this directly.

Then invoke the matching skill yourself: `orch-flow` for the first, `orch-quick-implement` for the second. Pick it by that bare name from the skills this host lists. If it is not listed, read `skills/<name>/SKILL.md` in the orchestrator extension (the directory above this `guidelines/` folder, under `~/.junie/extensions/`) and follow it verbatim.

Under the mattpocock-skills `wayfinder` skill, "approved" means the whole map is done, not one ticket resolved. Start the flow only then.
