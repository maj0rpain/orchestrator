# Orchestrator skills carry an `orch-` prefix

Claude Code namespaces plugin skills (`orchestrator:flow`), but Junie lists
them by bare name (`/flow`). Junie also loads skills from `~/.agents/skills/`,
where the `skills` CLI installs mattpocock's skills with no namespace either.
Orchestrator's `handoff` and mattpocock's `handoff` therefore collide, and
our other names (`flow`, `review`, `review-spec`, `quick-implement`) are
generic enough to collide with something later. We decided every
orchestrator skill carries an `orch-` prefix, whatever the host. On Claude
Code that makes the names redundant (`orchestrator:orch-flow`), but they
are unambiguous everywhere.

## Considered Options

- Rename only `handoff`, the one collision known today. Rejected: flat-name
  collisions happen silently (one skill folder simply replaces the other), so
  waiting for the next one means finding it in a broken flow.
- Leave the names and document the collision. Rejected for the same reason.

## Consequences

This is a breaking rename, released as a major version: every reference to
the skills changes, including skill prose, `hook-quick-implement.sh`'s skill
match, commands, README, and tests. Earlier ADRs are the exception: they
record decisions at a point in time, so they keep the names they were written
with. The redundant `orch-` on Claude Code is deliberate; don't "clean it up".
