# orchestrator

A Claude Code plugin. See [README.md](README.md) for layout and authoring reference.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues on `maj0rpain/orchestrator`, driven by the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name.
See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root.
See `docs/agents/domain.md`.

### CLI conventions

`orch.sh` subcommand grammar: noun before verb, e.g. `orch.sh branch retire <old> <new>`.
See `docs/agents/cli-conventions.md`.

## Versioning

Every PR that merges to `main` must bump `version` in `.claude-plugin/plugin.json`.
Use semver judgment: patch for fixes/docs, minor for new features, major for
breaking changes. A PR with no user-visible or behavioral change (pure CI/repo
hygiene) is the only exception.
