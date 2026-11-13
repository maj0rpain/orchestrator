# orchestrator

A Claude Code plugin. See [CONTRIBUTING.md](CONTRIBUTING.md) for layout and
authoring reference.

Standards: `CONTRIBUTING.md#Develop`, `docs/agents/cli-conventions.md`,
`docs/agents/coding-standards.md`.

## Layout

`orch.sh` is a thin entry point: each noun's code lives in
`scripts/orch/<noun>.sh`, each helper in the module of the concept it serves,
and only the primitives no concept owns in `scripts/orch/common.sh`; `common.sh`
and the module loader `loader.sh` are the two files every start loads. See
CONTRIBUTING.md's Layout for the full map. There is no top-level `tests/`, and
`hooks/` holds only `hooks.json`.

## Agent skills

### Issue tracker

Issues and specs live as GitHub issues on `maj0rpain/orchestrator`, driven by
the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

The five canonical triage roles, each label string equal to its name.
See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `GLOSSARY.md` and `docs/adr/` at the repo root.
See `docs/agents/domain.md`.

### CLI conventions

`orch.sh` subcommand grammar: noun before verb, e.g. `orch.sh branch
retire <old> <new>`. See `docs/agents/cli-conventions.md`.

### Coding standards

Judgement calls on reuse, `orch: ` messages, local names, variable meaning,
reading a process substitution to EOF and per-item helpers that start no
external command.
See `docs/agents/coding-standards.md`.

## Testing

While iterating, run only the section you are working on:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`,
e.g. `ORCH_TEST_ONLY='^branch create$'`.
Run `scripts/test/affected.sh` before each commit, and `scripts/test/all.sh`
once before opening a PR.
Ticket verification: scripts/test/affected.sh
Full verification: scripts/test/all.sh
orch_test.sh is only the runner: its `# ---` sections live in
`scripts/test/orch/<noun>.sh`, and a ticket's tests go in the file for the noun
it touches (a new noun gets a new file; a concept module with no noun gets a
section file named as it is). Sections run in parallel, so every section must
pass on its own. The runners share one job pool, holding 75% of the usable CPUs
unless `ORCH_TEST_POOL_PERCENT` sets another share (see CONTRIBUTING.md).
Test-helper placement is checked by harness.sh's test-helper placement
section; its failure message states the rule. Before writing or reusing a
helper, run
`scripts/dev/helpers.sh` (orch.sh's modules), `scripts/dev/helpers.sh --tests`
(the shared test setup and the gh fake), or `scripts/dev/helpers.sh <file>` (any
one bash file, e.g. `scripts/test/docs_lint.sh`) instead of grepping, and read
CONTRIBUTING's Test helpers subsection: the fixtures to reach for first, running
one section under `bash -x`, and the bash-version rule.
See CONTRIBUTING.md's Develop section.

## Versioning

Every PR to `main` adds one changelog fragment, `changelog.d/<issue>.md`, and
never bumps `version` in `.claude-plugin/plugin.json` or adds a `## ` heading to
`CHANGELOG.md` by hand. The fragment's first line is exactly `bump: patch`,
`bump: minor` or `bump: major`, and the rest, after any blank lines, is its
CHANGELOG prose. The fragment is named for the PR's issue - in a flow or a quick
implementation, the spec issue, never a ticket - and is written once: by the one
ticket subagent when the breakdown collapsed onto the issue, else by the session
driving the flow or quick implementation after its last ticket lands; no other
ticket subagent writes or edits it. Use semver judgment: patch for fixes/docs,
minor for new features, major for breaking changes. On merge, the version-bump
Action runs `scripts/version-bump.sh`, which bumps the version and writes the
CHANGELOG entry from the fragments. CI (`scripts/test/docs_lint.sh`) enforces
the rule; a pure CI or repo-hygiene PR carries the `no-version-bump` label and
adds no fragment.
See CONTRIBUTING.md's Develop section.
