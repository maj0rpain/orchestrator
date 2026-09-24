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
