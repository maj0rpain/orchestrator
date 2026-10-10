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
`<section>` is an extended regex matched against the `# ---` section titles,
e.g. `ORCH_TEST_ONLY='^branch create$'` or `ORCH_TEST_ONLY='^ticket'`. Run
`scripts/test/all.sh` once before committing: it starts all four suites and
shellcheck over every shell file at once, so they overlap, carries on past a
failing one, and once all have finished prints each suite's FAIL lines and a
summary line, then shellcheck's findings and a `shellcheck: N findings` summary
line, or `shellcheck: not installed - skipped`, which fails the run only in CI.

orch_test.sh is the suite's runner and holds no test. Its `# ---` sections live
under `scripts/test/orch/`: `<noun>.sh` holds the sections for one orch.sh noun
(`branch.sh`, `ticket.sh`, `review-pass.sh`, ...), `harness.sh` the harness's
own (the section filter, quiet mode, all.sh), and `setup.sh` the shared setup
and the summary. A ticket's tests go in the file for the noun it touches; a new
noun gets a new file, which the runner picks up with no edit. A noun file holds
only `# ---` sections, optionally preceded by a preamble: the text before its
first `# ---` line, run before that file's sections whenever one of them runs.

orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
the core count; `ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every
section must pass on its own. A helper is placed by the files that use it: one
used by more than one file lives in `setup.sh`'s shared setup; one used by only
one file lives in that file's preamble, whether one section or several use it;
one already defined inside a section stays there; a helper never moves into a
section.

orch.sh's own code is laid out the same way: `scripts/orch/<noun>.sh` holds one
noun's code, named as that noun's test file is, and `scripts/orch/common.sh`
the helpers more than one module (or orch.sh itself) uses; a helper only one
module uses lives in that module. The gh adapter layer stays whole in `gh.sh`,
whoever calls it. orch.sh sources every module eagerly from an explicit list,
so a new noun gets its own module, a case in `main` and a line in that list.

shellcheck is needed for `all.sh`'s lint step. `.shellcheckrc` holds its source
settings; severity is a command-line option only, so a manual run needs
`-S warning` to match `all.sh`. Each section file under `scripts/test/orch/`
opens with a shellcheck shell directive and a never-run `source setup.sh` line
behind a `source=setup.sh` directive, so shellcheck reads setup.sh's
definitions; a new section file copies those lines.

`--plugin-dir` is the development loop: it loads the working tree, so edits take
effect on the next session with no push. The installed copy is a clone of the
default branch pinned to `version` in `plugin.json`, so changes reach it only
after a push plus `/plugin marketplace update orchestrator`.

Every PR to `main` adds one **changelog fragment** and never bumps the version
by hand. The fragment is `changelog.d/<issue>.md`, `<issue>` all digits (a PR
closing several issues names it for one of them). Its first line is exactly
`bump: patch`, `bump: minor` or `bump: major` - semver judgement: patch for
fixes and docs, minor for new features, major for breaking changes - and the
rest, after any blank lines, is the CHANGELOG prose for the change, non-empty:

```
bump: minor

`orch.sh widget frob` frobs the widget (#123): ...
```

Two PRs never touch the same fragment, so PRs open at the same time never
conflict on `plugin.json` or `CHANGELOG.md`. On every push to `main`, the
version-bump Action (`.github/workflows/version-bump.yml`) runs
`scripts/version-bump.sh`, which gathers every fragment on `main` into one
version bump: `version` raised by the highest level among them, one `## <new
version>` entry on top of `CHANGELOG.md` carrying their prose in issue-number
order, the fragments deleted. The Action commits that as `Release <version>`
and pushes it; a push that loses a race with another merge leaves the
fragments to that merge's run. Run `scripts/version-bump.sh` from a scratch
copy of the checkout to see how a fragment renders: it edits the files in
place and does not commit. `scripts/test/version_bump_test.sh` tests it.

CI (`docs_lint.sh`) enforces the rule: a PR to `main` adds exactly one
well-formed fragment, and never changes `version`, adds a `## ` heading to
`CHANGELOG.md`, or modifies or deletes an existing fragment. A pure CI or
repo-hygiene PR carries the `no-version-bump` label, which waives the fragment
and ships no version bump; the other rules still hold.

## Layout

```
commands/                     start, next, flow-status, health, redo, abort, finish, release, spec-review, review-pass, sync, interview, quick-implement, to-spec, to-tickets, finding-triage
agents/                       the fresh agents: two reviewers (the review loop's and the review pass's), the review loop's fixer and closer, the spec review's four lenses, the implementer, and the resolver of a merge conflict
skills/orch-flow/             the state machine (judgment)
skills/orch-spec-review/      the spec review: consolidation of the issue's comments, then four lenses in a flow (three standalone), one batch question, plus a ticket question when an existing breakdown is touched
skills/orch-review/           the review loop: rubric, authority rules, terminal states; and the review pass, quick or standalone
skills/orch-sync/             a base sync on demand: branch sync, a resolver on a conflict, one PR comment, an offered review pass
skills/orch-handoff/          handoff templates, model-invocable unlike the upstream one
skills/orch-quick-implement/  the other route: issue (possibly rewritten from the plan by orch-to-spec's Unattended rewrite), unattended spec review, orch-to-tickets, tdd, review pass, PR - no flow
skills/orch-interview/        the planning interview; hook-grilling.sh's message asks the closing question
skills/orch-to-spec/          turns the conversation into a spec: publishes it as a new issue, or rewrites a given issue's body - attended, or in the Unattended rewrite form a quick implementation takes
skills/orch-to-tickets/       breaks an issue into tickets published as sub-issues, or collapses 0-1 into the issue
skills/orch-release/          the release PR: model writes title and summary, pr release writes Closes lines
skills/orch-finding-triage/   finding triage: scan the filed findings against the default branch, one batch per source PR, apply; --bundle groups them into bundles
scripts/orch.sh               the entry point for every deterministic operation (mechanism): path resolution, shared constants, the module list, main
scripts/orch/<noun>.sh        one module per orch.sh noun (branch.sh, ticket.sh, ...), sourced by orch.sh, named as its test file
scripts/orch/global.sh        the bare global commands with no module of their own (slug, status, archive, help)
scripts/orch/common.sh        the helpers more than one module uses (die, capture, the state readers, ...)
scripts/orch/gh.sh            the gh adapter layer (ADR-0033): gh(), every adapter_* operation, the ORCH_GH_ADAPTER hook
scripts/orch/doctor.sh        diagnostics: the d_* reporting and check_* functions, the doctor noun's module
scripts/triage-labels.sh      the triage-label parser and LABELS_DOC, sourced by orch.sh and hook-grilling.sh
scripts/host.sh               the one host detector, host_detect, sourced by orch.sh and hook-common.sh
scripts/hook-*.sh             the four hooks; hook-grilling.sh also runs on UserPromptSubmit for Junie
scripts/hook-common.sh        payload reading and dual-host (Claude Code + Junie) output shared by the hooks
scripts/planning-allowlist.sh the planning allowlist and planning records, shared by the edit guard and orch.sh
scripts/version-bump.sh       the version-bump Action's script: changelog fragments into one version bump (Develop)
scripts/test/                 shell tests: orch_test.sh (the orch.sh suite's runner), hooks_test.sh, docs_lint.sh, version_bump_test.sh, all.sh
scripts/test/orch/setup.sh    the orch.sh suite's shared setup (helpers used by more than one file) and summary
scripts/test/orch/harness.sh  the harness's own sections: isolation, the section filter, quiet mode, all.sh
scripts/test/orch/<noun>.sh   one file per orch.sh noun (branch.sh, ticket.sh, ...): its sections, after an optional preamble
docs/how-it-works.md          the phases, every command in full, the base branch, hosts, and activation
docs/host-capabilities.md     how each host provides each capability a skill names, and the fallbacks
docs/driver-loop.md           the driver loop (loop steps a-f, its slots, dispatching a subagent) the implement phase and a quick implementation both run
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
the Claude Code tool inline as an example, alongside the Junie tool for the
same capability; `docs_lint.sh` fails when a skill or agent names
`AskUserQuestion` in a sentence that does not also name `ask_user`. They point at
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
