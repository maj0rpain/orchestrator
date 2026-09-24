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

A flow started on 1.0.0 needs a `## Host fallbacks` section in every handoff
(`01-plan.md`, `02-spec.md`, `03-implement.md`), and `handoff validate` /
`doctor --flow` fail without one. A flow already under way when you upgrade is
exempt, so it finishes as it would have on 0.x.

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
