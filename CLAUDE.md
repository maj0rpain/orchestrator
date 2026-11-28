# orchestrator

A Claude Code plugin. See [CONTRIBUTING.md](CONTRIBUTING.md) for layout and
authoring reference.

Standards: `CONTRIBUTING.md#Develop`, `docs/agents/cli-conventions.md`,
`docs/agents/coding-standards.md`.

## Layout

`scripts/orch.sh` is a thin entry point: every noun is Python (ADR-0067), and
`orch.sh` keeps only its bash version guard and `python3` check before it hands
every argument to the standard-library package in `scripts/orch_py/orch/`, as
`python3 -m orch <noun> ...` would run it, through a `-c` bootstrap. The
package owns the noun list, each noun's code in the module of the concept it
serves, its pytest tests beside it in `scripts/orch_py/tests/`. The bash module
directory `scripts/orch/` holds only `common.sh`, the bash primitives no
concept owns, which the autopilot scripts source; there is no module loader.
See CONTRIBUTING.md's Layout for the full map.
There is no top-level `tests/`, and `hooks/` holds only `hooks.json`.

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
e.g. `ORCH_TEST_ONLY='^list_has$'`.
A session that adds or edits tests runs `scripts/dev/section-durations.sh
--stale` before verifying and commits the durations file with its change.
Run `scripts/test/affected.sh` before each commit. CI runs the whole suite on
every PR, through `scripts/test/all.sh`.
Ticket verification: scripts/test/affected.sh
Branch verification: scripts/test/affected.sh
Full verification: scripts/test/all.sh
orch_test.sh is only the runner: its `# ---` sections live in
`scripts/test/orch/<name>.sh`, one file per bash file they test, named as it is
(`common.sh`, `flow-state.sh`, `host.sh`, `triage-labels.sh`), beside the
harness's `harness.sh` and the shared setup's `setup.sh`. A noun's tests are
pytest in `scripts/orch_py/tests/`, every noun being Python. Sections
run in parallel, so every section must pass on its own. The runners share one
job pool, its slots sized to 75% of the usable CPUs unless
`ORCH_TEST_POOL_PERCENT` sets another share (see CONTRIBUTING.md).
Test-helper placement is checked by `scripts/test/orch/harness.sh`'s
test-helper placement section; its failure message states the rule. A test that
writes out the whole body of a shared or preamble test helper it could call is
failed by harness.sh's helper body copies section: call the helper, or mark a
deliberate repeat with `# copy-of <helper>: <reason>`. Before writing or reusing
a helper, run `scripts/dev/helpers.sh` (`scripts/orch/common.sh`),
`scripts/dev/helpers.sh --tests` (the shared test setup, the gh fake's store
layout, the tally, the FIFO wait, the counting and failing-command fixtures),
or `scripts/dev/helpers.sh <file>` (any
one bash file, e.g. `scripts/test/docs_lint.sh`) instead of grepping, and read
CONTRIBUTING's Test helpers subsection: the fixtures to reach for first, running
one section under `bash -x`, and the bash-version rule.
The Python package's tests are pytest, run from `scripts/orch_py/`: `python3 -m
pytest` (`-k <name>` for one test, `-n auto` for xdist), with the dev
dependencies of `scripts/orch_py/requirements-dev.txt` installed (the image's
`/opt/orch-dev` venv has them). They use `tmp_path`, `monkeypatch` and the
in-process fakes (`orch.gh_fake`'s `FakeGh` and `FakeStore`, on the fake store
`scripts/test/gh_adapter_fake.sh` documents; `orch.git`'s `FakeGit`), never the
bash fixtures. `all.sh` and `affected.sh` run the whole pytest suite through
`scripts/test/orch_py_test.sh`, outside the durations file.
See CONTRIBUTING.md's Develop section.

## Versioning

Every PR to `main` adds one changelog fragment, `changelog.d/<issue>.md`, and
never bumps `version` in `.claude-plugin/plugin.json` or
`.antigravity-plugin/plugin.json` or adds a `## ` heading to `CHANGELOG.md` by
hand. The fragment's first line is exactly `bump: patch`,
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
