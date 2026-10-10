# orchestrator

A Claude Code plugin. See [CONTRIBUTING.md](CONTRIBUTING.md) for layout and authoring reference.

## Layout

Shell scripts live in `scripts/` (`orch.sh`, `hook-*.sh`, …). `orch.sh` is a thin entry point: each noun's code lives in `scripts/orch/<noun>.sh` (`doctor.sh` among them), and the helpers more than one module uses in `scripts/orch/common.sh`. Tests live in `scripts/test/`, with the orch.sh suite's sections in `scripts/test/orch/` (one `<noun>.sh` per orch.sh noun, named as its module is, plus `setup.sh` and `harness.sh`). There is no top-level `tests/`, and `hooks/` holds only `hooks.json`.

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
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`,
e.g. `ORCH_TEST_ONLY='^branch create$'`.
Run `scripts/test/all.sh` once before committing.
orch_test.sh is only the runner: its `# ---` sections live in
`scripts/test/orch/<noun>.sh`, one file per orch.sh noun, and a ticket's tests
go in the file for the noun it touches (a new noun gets a new file).
orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
the core count; `ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every
section must pass on its own. So a helper is placed by the files that use it: one
used by more than one file lives in `scripts/test/orch/setup.sh`; one used by
only one file lives in that file's preamble, before its first `# ---` line; one
already defined inside a section stays there; a helper never moves into a
section.
See CONTRIBUTING.md's Develop section.

## Versioning

Every PR to `main` adds one changelog fragment, `changelog.d/<issue>.md`, and
never bumps `version` in `.claude-plugin/plugin.json` or adds a `## ` heading to
`CHANGELOG.md` by hand. The fragment's first line is exactly `bump: patch`,
`bump: minor` or `bump: major`, and the rest, after a blank line, is its
CHANGELOG prose. Use semver judgment: patch for fixes/docs, minor for new
features, major for breaking changes. On merge, the version-bump Action runs
`scripts/version-bump.sh`, which bumps the version and writes the CHANGELOG
entry from the fragments. CI (`scripts/test/docs_lint.sh`) enforces the rule;
a pure CI or repo-hygiene PR carries the `no-version-bump` label and adds no
fragment.
See CONTRIBUTING.md's Develop section.
