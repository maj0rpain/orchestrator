# On Junie, planning is a nudge, not a guard

Supersedes ADR-0023. On Junie the edit guard no longer arms, even though Junie
now offers a mechanical trigger for it, and the flow-start working-tree check
(ADR-0013) is the backstop there. This departs from ADR-0013's rule that a
host with a trigger keeps the guard armed, and on Junie accepts the prose
steering ADR-0013 rejected as a replacement: enforcement stays mechanical, but
moves to flow start.

ADR-0023 kept the live guard on Junie once build 3419.7's `PreToolUse` carried
`session_id`, and lifted it for a quick implementation on a `Read` of the
installed `orch-quick-implement/SKILL.md`. In use the guard was finicky on
Junie: the lift depended on the model reading that exact file with the Read
tool, under a path field still unverified, and a session whose lift did not
fire stayed locked out of every source edit. Its value there did not pay for
that friction.

`hook-grilling.sh` still writes a per-session marker on Junie's
`UserPromptSubmit`, because the marker also keeps the planning message to
once per session and gates the closing question asked when Junie's plan
screen is confirmed. On Junie it is named `orchestrator-planning-<session>`,
a name `hook-guard.sh` never reads, so the guard stays unarmed. The guard
cannot skip Junie itself: Junie's `PreToolUse` may lack `project_path`, which
is how the hooks tell the hosts apart. Planning on Junie is steered by the
planning message and by a standing planning section in the
`docs/junie/AGENTS.md` snippet: no source edits, and glossary and ADR changes
written word for word into the plan (ADR-0022). The `PreToolUse` `Read` lift
is removed; on Claude Code the `Skill` lift (ADR-0006) is unchanged.

## Considered Options

- **Keep the guard on Junie and fix the lock-ups.** Rejected: the lift rests
  on host behaviour the plugin cannot verify or control, and each fix would
  be another guess at it.
- **Write no marker on Junie.** Rejected: the closing question after Junie's
  plan screen would either never be asked, or be asked after every Junie
  plan, including ones that never grilled (#202).

## Consequences

On Junie, source edits made while planning are caught at flow start by
`orch.sh init`, not prevented as they happen. Doctor reports the edit guard
as a capability Junie lacks. A model that ignores the nudge and edits
CONTEXT.md or an ADR mid-planning is caught the same way.
