# The edit guard arms only where a host offers a mechanical trigger

The planning edit guard (`hook-guard.sh`) is armed by a marker that a
`PostToolUse` hook on the `Skill` tool creates when grilling starts. Junie,
the first host after Claude Code, has neither a `PostToolUse` event nor a
`Skill` tool, so on Junie nothing mechanical can arm the guard. We decided
the guard stays armed only where a host gives it a mechanical trigger. On
every other host there is no real-time guard. Instead, `orch.sh` checks at
flow start that the working tree has nothing changed outside the planning
allowlist, and refuses to start if it does. That check is git state, so it
works the same on every host.

## Considered Options

- The model arms the guard itself, by writing a repo-scoped marker such as
  `.orchestrator/planning` when it notices planning has begun. Rejected: this
  undoes ADR-0006's rule that the guard's enforcement never depends on the
  model correctly reporting its own state. The guard exists because the model
  does not reliably follow instructions, so it cannot be armed by one.
- Move the guard's rule into skill prose ("do not edit source files while
  planning"). Rejected for the same reason: that turns a mechanism back into
  the instruction it was built to back up.
- Refuse to run on hosts without a compatible trigger. Rejected: the flow's
  durability already lives in `.orchestrator/state.json`, and the guard was
  always the early-warning half, not the whole defence.

## Consequences

On a host without a trigger, source edits made during planning are caught
at flow start, not prevented while they happen. Doctor reports the missing
guard as a missing host capability. A future Junie trigger (for example, a
`PreToolUse` on `Read` of a grilling `SKILL.md`, if Junie turns out to load
skills that way) can arm the same marker without changing the guard.
