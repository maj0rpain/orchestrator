# Contributing

How the plugin is laid out, the authoring rules its docs lint enforces, and
how to develop and test it. What the plugin does is in
[README.md](README.md) and [docs/how-it-works.md](docs/how-it-works.md).

## Reporting a bug

Found a bug or want to propose a change? Open a GitHub issue on this repo -
label it `needs-triage` if it isn't already.

## Develop

```
claude --plugin-dir /path/to/orchestrator     # load the working tree directly
claude plugin validate .
scripts/test/all.sh                           # every suite; run once before committing
```

While iterating, run only the section you are working on, in quiet mode:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`, where
`<section>` is an extended regex matched against the `# ---` section titles. Run
`scripts/test/all.sh` once before committing: it starts all three suites and
shellcheck over every shell file at once, so they overlap, carries on past a
failing one, and once all have finished prints each suite's FAIL lines and a
summary line, then shellcheck's findings and a `shellcheck: N findings` summary
line, or `shellcheck: not installed - skipped`, which fails the run only in CI.

orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
the core count; `ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every
section must pass on its own: a helper used by more than one section lives in its
shared setup.

shellcheck is needed for `all.sh`'s lint step. `.shellcheckrc` holds its source
settings; severity is a command-line option only, so a manual run needs
`-S warning` to match `all.sh`.

`--plugin-dir` is the development loop: it loads the working tree, so edits take
effect on the next session with no push. The installed copy is a clone of the
default branch pinned to `version` in `plugin.json`, so changes reach it only
after a push plus `/plugin marketplace update orchestrator`. Every PR to `main`
bumps `version` and adds it as the top `CHANGELOG.md` entry, and CI enforces
both; a pure CI or repo-hygiene PR skips the bump with the `no-version-bump`
label.

## Layout

```
commands/                     start, next, status, doctor, redo, abort, finish, release, spec-review, review, sync, interview, quick-implement, to-spec, to-tickets, finding-triage
agents/                       the fresh agents: two reviewers (the review loop's and the review pass's), the review loop's fixer and closer, the spec review's four lenses, the implementer, and the resolver of a merge conflict
skills/orch-flow/             the state machine (judgment)
skills/orch-spec-review/      the spec review: consolidation of the issue's comments, then four lenses in a flow (three standalone), one batch question, plus a ticket question when an existing breakdown is touched
skills/orch-review/           the review loop: rubric, authority rules, terminal states; and the review pass, quick or standalone
skills/orch-sync/             a base sync on demand: branch sync, a resolver on a conflict, one PR comment, an offered review pass
skills/orch-handoff/          handoff templates, model-invocable unlike the upstream one
skills/orch-quick-implement/  the other route: issue, unattended spec review, orch-to-tickets, tdd, review pass, PR - no flow
skills/orch-interview/        the planning interview; hook-grilling.sh's message asks the closing question
skills/orch-to-spec/          turns the conversation into a spec: publishes it as a new issue, or rewrites a given issue's body
skills/orch-to-tickets/       breaks an issue into tickets published as sub-issues, or collapses 0-1 into the issue
skills/orch-release/          the release PR: model writes title and summary, pr release writes Closes lines
skills/orch-finding-triage/   finding triage: scan the filed findings against the default branch, one batch per source PR, apply; --bundle groups them into bundles
scripts/orch.sh               every deterministic operation (mechanism)
scripts/doctor.sh             diagnostics: the d_* reporting and check_* functions, sourced by orch.sh
scripts/triage-labels.sh      the triage-label parser and LABELS_DOC, sourced by orch.sh and hook-grilling.sh
scripts/host.sh               the one host detector, host_detect, sourced by orch.sh and hook-common.sh
scripts/hook-*.sh             the four hooks; hook-grilling.sh also runs on UserPromptSubmit for Junie
scripts/hook-common.sh        payload reading and dual-host (Claude Code + Junie) output shared by the hooks
scripts/planning-allowlist.sh the planning allowlist and planning records, shared by the edit guard and orch.sh
scripts/test/                 shell tests
docs/how-it-works.md          the phases, every command in full, the base branch, hosts, and activation
docs/host-capabilities.md     how each host provides each capability a skill names, and the fallbacks
docs/junie/README.md          Junie CLI setup: the AGENTS.md snippet and the per-prompt fallback
docs/junie/AGENTS.md          Junie snippet: standing planning and finding-the-plugin sections (where orch.sh is, what to do when an orch-* skill or agent is hidden), and each skill's custom agents (JUNIE-5493 workaround)
hooks/hooks.json              hook wiring
```

### Prose for judgment, bash for facts

Reading state, naming branches, resolving the default branch, and validating
handoffs all have one right answer, so they live in `orch.sh` where they
cannot drift between sessions.

## Resolving orch.sh

Only Claude Code expands `CLAUDE_PLUGIN_ROOT` in skills. Other hosts expand it
only inside `hooks/hooks.json` (which keeps `${CLAUDE_PLUGIN_ROOT}` as is). Junie
CLI's agent shell has no `JUNIE_EXTENSION_ROOT` either, and Junie does not tell
the model a skill's own directory. So every skill that runs `orch.sh` states the
path one way, in this order: the `ORCH=` line, then the Junie CLI install, then
the relative fallback:

````
```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).
````

The Junie step is prose carrying a literal `ls`, not a bash line that sets
`ORCH`, because hosts may not keep shell variables between calls. The glob uses
`$HOME/.junie`, the one install path confirmed so far, and its one-level
`extensions/*/orchestrator` matches the installed extension but not the
marketplace clone under `extensions/marketplaces/`. Keep the first line of the
Junie sentence and the three "If it prints" sentences intact, in that order,
then call `bash "$ORCH" <subcommand>` everywhere else. Do not copy the scripts
into a skill. Commands never run `orch.sh`: each is a thin route into a skill, usually
an `orch-flow` section (see [Naming host capabilities](#naming-host-capabilities)).

A skill that reads another file under the plugin root names it as
`"${CLAUDE_PLUGIN_ROOT}/<path>"`, and the same file carries a sentence starting
``If `CLAUDE_PLUGIN_ROOT` is unset, the plugin root is``, naming the same
steps the `ORCH` fallback does: two directories above the `orch.sh` that `ls`
printed, else two directories above the skill's own directory. `docs_lint.sh`
fails when a skill or command mentions `CLAUDE_PLUGIN_ROOT`
any other way, runs `orch.sh` without these steps in order or without `bash`,
names the plugin root without the Junie step in that same sentence, or names a
path through a `<plugin root>/` placeholder.

## Naming host capabilities

Skills and the agent briefs under `agents/` describe capabilities ("invoke a
skill", "start a fresh subagent", "ask a multiple-choice question"), may name
the Claude Code tool inline as an example, and point at
[docs/host-capabilities.md](docs/host-capabilities.md), which maps each
capability to each host and documents the fallback where a host lacks one. A
phase records every fallback it took in its handoff's **Host fallbacks**
section, which `handoff validate` requires for flows started on 1.0.0 or later
(a flow already in progress at upgrade is exempt); an agent records its own
where its brief says. Commands are Claude Code shortcuts only: each one routes to a
skill, or to one section of it (usually an `orch-flow` section), and holds no
behaviour of its own, so invoking the skill on another host is complete. `docs_lint.sh` fails when a skill, or an agent that
invokes a skill, never points at the reference, when a skill or agent offers
a `/orchestrator:<cmd>` that has no `commands/<cmd>.md`, or when a command runs
`orch.sh` or routes to a section that does not exist.

## Command names

A command must not share its bare name with a host built-in command (for
example Claude Code's `/plan`, `/review`, `/status` or `/doctor`), because the
typeahead lists both. `scripts/test/docs_lint.sh` enforces this against its
list of Claude Code built-ins.
