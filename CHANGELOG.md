# Changelog

## 1.0.0

Breaking: every orchestrator skill now carries an `orch-` prefix, whatever the
host (see `docs/adr/0014-orchestrator-skills-carry-an-orch-prefix.md`). Bare
skill names collide on hosts that list skills without a plugin namespace, such
as Junie, where orchestrator's `handoff` shadowed mattpocock's.

Migration - update any muscle memory, notes, or scripts that name a skill:

| Old name                       | New name                            |
| ------------------------------ | ----------------------------------- |
| `orchestrator:flow`            | `orchestrator:orch-flow`            |
| `orchestrator:handoff`         | `orchestrator:orch-handoff`         |
| `orchestrator:review`          | `orchestrator:orch-review`          |
| `orchestrator:review-spec`     | `orchestrator:orch-review-spec`     |
| `orchestrator:quick-implement` | `orchestrator:orch-quick-implement` |

The slash commands (`/orchestrator:start`, `/orchestrator:next`, and so on) are
unchanged. The skill directories moved from `skills/<name>/` to
`skills/orch-<name>/`.

Also breaking, for a flow already under way when you upgrade: every handoff
(`01-plan.md`, `02-spec.md`, `03-implement.md`) now needs a `## Host fallbacks`
section, and `handoff validate` / `doctor --flow` fail without one. Add the
section by hand - `None (Claude Code).` if nothing fell back - or finish the
flow on 0.x before upgrading.

Also new in 1.0.0 (see issue #121):

- Junie is supported as a second host. `docs/host-capabilities.md` maps each
  capability the skills rely on to each host, with documented fallbacks.
- Skills find `orch.sh` relative to their own directory when
  `CLAUDE_PLUGIN_ROOT` is unset.
- mattpocock-skills are found in Claude's plugin cache, Junie's extension
  cache, or the `skills` CLI store (`~/.agents`), or wherever
  `ORCHESTRATOR_MATTPOCOCK_ROOT` points.
- `orch.sh init` refuses to start a flow while the working tree has changes
  outside the planning allowlist.
- Doctor reports the detected host (override with `ORCHESTRATOR_HOST`) and the
  capabilities it lacks.
- `guidelines/orch-planning.md` carries the planning nudge on Junie.
