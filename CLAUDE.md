# orchestrator

A Claude Code plugin. See [README.md](README.md) for layout and authoring reference.

## Layout

Shell scripts live in `scripts/` (`orch.sh`, `doctor.sh`, `hook-*.sh`, …); tests in `scripts/test/`. There is no top-level `tests/`, and `hooks/` holds only `hooks.json`.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues on `maj0rpain/orchestrator`, driven by the `gh` CLI.
See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name.
See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root.
See `docs/agents/domain.md`.

### CLI conventions

`orch.sh` subcommand grammar: noun before verb, e.g. `orch.sh branch retire <old> <new>`.
See `docs/agents/cli-conventions.md`.

### Coding standards

Judgement calls on reuse, `orch: ` messages, local names and variable meaning.
See `docs/agents/coding-standards.md`.

## Testing

While iterating, run only the section you are working on:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`.
Run `scripts/test/all.sh` once before committing.
orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
the core count; `ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every
section must pass on its own: a helper used by more than one section lives in its
shared setup.

## Versioning

CI (`scripts/test/docs_lint.sh`) enforces that every PR to `main` bumps `version`
in `.claude-plugin/plugin.json` and adds it as the top `CHANGELOG.md` entry, with
the `no-version-bump` label for pure CI or repo-hygiene PRs.
Use semver judgment: patch for fixes/docs, minor for new features, major for
breaking changes.
