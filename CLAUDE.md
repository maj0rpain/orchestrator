# orchestrator

A Claude Code plugin. See [CONTRIBUTING.md](CONTRIBUTING.md) for layout and
authoring reference.

## Layout

Shell scripts live in `scripts/` (`orch.sh`, `hook-*.sh`, …). `orch.sh` is a
thin entry point: each noun's code lives in `scripts/orch/<noun>.sh`
(`doctor.sh` among them), the concept modules with no noun, `checkout.sh`,
`filed-finding.sh`, `issue-timeline.sh`, `known-items.sh`, `liveness.sh`,
`marked-comment.sh` and `standing.sh`, among them too, each helper in the module
of the concept it serves, and only the primitives no concept owns in
`scripts/orch/common.sh`.
Tests live in `scripts/test/` (`tally.sh`, the assertion tally, and
`git_env.sh`, sourced by every runner, which clears git's repo-local
variables, among them),
with the orch.sh suite's sections in `scripts/test/orch/` (one `<noun>.sh` per
orch.sh noun, named as its module is, and `checkout.sh`, `filed-finding.sh`,
`issue-timeline.sh`, `known-items.sh`, `liveness.sh`, `marked-comment.sh` and
`standing.sh` for the concept modules of those names, plus `common.sh`,
`setup.sh` and
`harness.sh`). The autopilot
container's files live in `docker/`
(`Dockerfile`, `compose.yaml`, `.env.example`), its entrypoint is
`scripts/autopilot-container.sh`, and `scripts/test/autopilot_container_test.sh`
tests it. `scripts/autopilot-up.sh` brings its compose projects up, and
`scripts/test/autopilot_up_test.sh` tests it. Repo-development tools that do
not ship to users live in
`scripts/dev/` (`helpers.sh`, the helper index). There is no top-level `tests/`,
and `hooks/` holds only `hooks.json`.

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

Judgement calls on reuse, `orch: ` messages, local names and variable meaning.
See `docs/agents/coding-standards.md`.

## Testing

While iterating, run only the section you are working on:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`,
e.g. `ORCH_TEST_ONLY='^branch create$'`.
Run `scripts/test/all.sh` once before committing.
orch_test.sh is only the runner: its `# ---` sections live in
`scripts/test/orch/<noun>.sh`, one file per orch.sh noun, and a ticket's tests
go in the file for the noun it touches (a new noun gets a new file; a concept
module with no noun, `checkout.sh`, `filed-finding.sh`, `issue-timeline.sh`,
`known-items.sh`, `liveness.sh`, `marked-comment.sh` or `standing.sh`, gets a
section file named as it is).
orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
half the usable CPUs, rounded down, at least 1, and all of them under `CI`;
usable CPUs are the online cores, lowered to a cgroup v2 `cpu.max` quota;
`ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every section must
pass on its own. all.sh runs at most that many shellcheck processes at once, and
both runners lower their own niceness to 10 outside `CI`.
Helper placement is checked by harness.sh's placement section; its failure
message states the rule. Before writing or reusing a helper, run
`scripts/dev/helpers.sh` (orch.sh's modules) or `scripts/dev/helpers.sh --tests`
(the shared test setup and the gh fake) instead of grepping, and read
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
