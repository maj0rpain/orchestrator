# orchestrator

A Claude Code plugin that separates **planning**, **spec writing**,
**implementation**, and **review** into four phases, each running in a fresh
session, connected by handoff files.

The problem it solves: one long session that plans, specs, builds, and reviews
carries every earlier phase's context into the next. The reviewer already
believes the implementer's reasoning. Splitting the phases and passing only a
written handoff between them means each phase judges the work, not the story
behind it.

[`mattpocock-skills`](https://github.com/mattpocock/skills) is a separate plugin
of skills for planning, spec-writing, implementing, and reviewing code. This
plugin conducts it rather than replacing it: `to-spec` writes the spec,
`implement` builds it, `code-review` reviews each ticket's work. This plugin
owns the state, the handoffs, the branch, the PR, and the review loop's own
reviewer agents.

## Install

```
/plugin marketplace add maj0rpain/orchestrator
/plugin install orchestrator@orchestrator
```

The repo doubles as its own single-plugin marketplace, so there is no separate
marketplace repo. Installs at user scope, so it is available in every project on
that machine.

Requires the `mattpocock-skills` plugin, plus `gh`, `jq`, and `git`. Run
`/mattpocock-skills:setup-matt-pocock-skills` once per repo first - it writes
`docs/agents/issue-tracker.md`, which `/orchestrator:start` checks for before
starting a flow. `/orchestrator:doctor` reports all of this at any time.

`mattpocock-skills` is found wherever your host installed it, checked in this
order: `$ORCHESTRATOR_MATTPOCOCK_ROOT` if set, Claude Code's plugin cache,
Junie's extension cache (`~/.junie/extensions/`), then the `skills` CLI store
(`~/.agents/skills/`, only entries its lockfile records as `mattpocock-skills`).
The first location present is used for every skill; a project's own
`.agents/skills/` is never consulted.

"Junie" in this README and across the plugin means the Junie CLI, not the
Junie plugin for JetBrains IDEs. Junie CLI support rests on its bundled
documentation, and some of it is unverified, such as whether it loads the
plugin's `agents/` (see [docs/host-capabilities.md](docs/host-capabilities.md)).

Doctor reports the host it detects and the capabilities that host lacks (from
[docs/host-capabilities.md](docs/host-capabilities.md)). It reads Claude Code
from `CLAUDECODE` or `CLAUDE_PLUGIN_ROOT` and Junie from `JUNIE_EXTENSION_ROOT`;
set `ORCHESTRATOR_HOST=claude` or `junie` where neither reaches the shell.
Install the whole plugin, not just its skills: every skill runs `scripts/orch.sh`.

Upgrading from 0.x: 1.0.0 renamed every skill to carry an `orch-` prefix (the
flow skill is now `orchestrator:orch-flow`, and so on). See
[CHANGELOG.md](CHANGELOG.md) for the full old-to-new list.

## The flow

```
  planning session          shared understanding reached
  (grill-me / wayfinder  ->  AskUserQuestion: flow, or quick?
   / improve-codebase-…)                               |
                                        +----------------+----------------+
                                        |                                 |
                              /orchestrator:start                orchestrator:orch-quick-implement
                              ->  01-plan.md                     issue, to-tickets publishes tickets,
                                        |                          branch quick/<issue>-<slug>,
                                       | /clear                    one subagent per ticket, tdd,
                                                                    single-pass code-review, PR
  spec session         to-spec publishes the issue,  <--+
                       or already adopted at init
                       spec review
                       to-tickets publishes tickets  ->  02-spec.md
                                                       |
                                                       | /clear
  implement session    branch orch/<issue>-<slug>   <--+
                       one subagent per ticket,
                       ticket next/close, draft PR   ->  03-implement.md
                                                       |
                                                       | /clear
  review session       bounded review loop          <--+
                       triage, fix, verify, CI      ->  ready, or a bounded stop
                                                       |
                                                       | /clear (after a bounded stop)
                                                       +--> review session
```

For work that does not need the pipeline, a human can pick a quick
implementation instead of starting a flow - see CONTEXT.md's **Quick
implementation** entry. It skips all four phases: no handoff, no
`.orchestrator/state.json`, just a linked issue, `to-tickets` publishing that
issue's ticket breakdown, the same one-subagent-per-ticket loop the implement
phase uses (`tdd` instead of `implement`, ending in `pr publish` instead of a
draft `pr open`), a single-pass `code-review`, and a PR.

Handoffs live in `.orchestrator/handoff/`, ignored via `.git/info/exclude` so
running the flow never dirties a repo's working tree.

## Commands

| Command | What it does |
| --- | --- |
| `/orchestrator:start [slug]` | Start a flow from an approved plan. Runs in the planning session. |
| `/orchestrator:next` | Run the next phase. Run it in a fresh session. |
| `/orchestrator:status` | Phase, issue, branch, PR, and the flow's health. |
| `/orchestrator:doctor` | Diagnose the machine, the repo, and the active flow. |
| `/orchestrator:redo` | Step back one phase and re-run it. |
| `/orchestrator:abort` | Archive the flow to `.orchestrator/archive/`. |
| `/orchestrator:release` | Open the release PR that carries the base branch into the default branch (see below). |

### Base branch

Flows and quick implementations fork from the repo's default branch unless
you set another **base branch** (see CONTEXT.md) for the checkout - for
instance a `uat` branch that gathers a multi-ticket project:

| Command | What it does |
| --- | --- |
| `orch.sh base set <branch>` | Set the base branch. Refuses a branch `origin` does not have. Stored in the clone's local git config (`orchestrator.base`): shared by every worktree, never committed, kept through `abort` and archiving. Setting the default branch's name clears it. |
| `orch.sh base show` | Print the base branch in effect and its source: `set`, or `default`. |
| `orch.sh base clear` | Go back to the default branch. Succeeds when nothing was set. |
| `orch.sh pr release [--force] <title> <body-file>` | Open the **release PR** (see CONTEXT.md): a non-draft PR from the base branch into the default branch. Its body starts with one `Closes #N` line per still-open issue that any PR merged into the base branch refers to (`Refs`, `Closes`, `Fixes` or `Resolves #N`, anywhere in the body). Refuses on the default branch, while a release PR is already open, and with nothing to close unless `--force`. Pushes nothing. |

`/orchestrator:doctor` reports the base branch in effect, and FAILs when the
one you set is gone from `origin`.

A PR into a base branch other than the default says `Refs #N` rather than
`Closes #N`, because GitHub only closes issues on merges into the default
branch. `/orchestrator:release` closes them: the model writes the release PR's
title and summary, and `orch.sh pr release` writes the `Closes` lines.

## Why separate sessions

`handoff`, `implement`, `to-spec`, `to-tickets`, `wayfinder`, and
`improve-codebase-architecture` are all marked `disable-model-invocation: true`
upstream, so the Skill tool cannot invoke them. The flow works around this by
reading their `SKILL.md` files directly and following them, which is what the
Skill tool would have injected anyway.

That makes invocability a solved problem, **but the separate sessions remain the
point**: fresh context per phase, and room for the human-in-the-loop exchanges
that `to-spec` (test seams) and the spec review depend on. If those upstream flags
ever change, the architecture does not need to.

## Activation

A `PostToolUse` hook on `Skill(grilling)` catches all three planning entry points
- `grill-me`, `wayfinder`, and `improve-codebase-architecture` all route through
it. It fires once per session, stays quiet when a flow is already running, warns
early if the repo is unconfigured, and tells the model that once a shared
understanding is reached, the next step is a human's call, not the model's:
call `AskUserQuestion` with exactly two options, start the flow
(`orchestrator:orch-flow`) or a quick implementation (`orchestrator:orch-quick-implement`),
and do whichever the human picks.

A `PreToolUse` hook on `Edit`/`Write` enforces that: during a planning session
with no flow started, source edits are denied. Planning artifacts stay writable -
the paths listed in `scripts/planning-allowlist.sh` - because `improve-codebase-architecture` and `domain-modeling`
legitimately write them mid-planning. A third `PostToolUse` hook on the same
`Skill` matcher lifts the guard for a quick implementation: it deletes the
session's marker file when `orchestrator:orch-quick-implement` fires, without
`hook-guard.sh` itself changing.

## Layout

```
commands/                     start, next, status, doctor, redo, abort, release
agents/                       the review loop's fresh agents: two reviewers, the fixer, the closer
skills/orch-flow/             the state machine (judgment)
skills/orch-review-spec/      the spec review: four lenses, one batch question
skills/orch-review/           the review loop: rubric, authority rules, terminal states
skills/orch-handoff/          handoff templates, model-invocable unlike the upstream one
skills/orch-quick-implement/  the other route: issue, to-tickets, tdd, single-pass review, PR - no flow
skills/orch-release/          the release PR: model writes title and summary, pr release writes Closes lines
scripts/orch.sh               every deterministic operation (mechanism)
scripts/doctor.sh             diagnostics plus triage-label/issue-adoption parsing, sourced by orch.sh
scripts/hook-*.sh             the three hooks
scripts/hook-common.sh        payload reading and dual-host (Claude Code + Junie) output shared by the hooks
scripts/planning-allowlist.sh the planning allowlist, shared by the edit guard and orch.sh
scripts/test/                 shell tests
guidelines/orch-planning.md   the planning nudge for Junie, which has no hook to deliver it
docs/host-capabilities.md     how each host provides each capability a skill names, and the fallbacks
hooks/hooks.json              hook wiring
```

Prose for judgment, bash for facts. Reading state, naming branches, resolving the
default branch, and validating handoffs all have one right answer, so they live in
`orch.sh` where they cannot drift between sessions.

### Resolving orch.sh

Only Claude Code expands `CLAUDE_PLUGIN_ROOT` in skills. Other hosts expand it
only inside `hooks/hooks.json` (which keeps `${CLAUDE_PLUGIN_ROOT}` as is). So every
skill that runs `orch.sh` states the path one way, as the `ORCH=`
line followed by the relative fallback:

````
```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).
````

Keep the fallback sentence's first line intact, then call `bash "$ORCH" <subcommand>`
everywhere else. Do not copy the scripts into a skill. Commands never run
`orch.sh`: each is a thin route into an `orch-flow` section (see
[Naming host capabilities](#naming-host-capabilities)). `orch_test.sh` fails when
a skill, command, or `guidelines/` file mentions `CLAUDE_PLUGIN_ROOT` anywhere
else, or runs `orch.sh` without this pair or without `bash`.

### Naming host capabilities

Skills describe capabilities ("invoke a skill", "start a fresh subagent", "ask
a multiple-choice question"), may name the Claude Code tool inline as an
example, and point at [docs/host-capabilities.md](docs/host-capabilities.md),
which maps each capability to each host and documents the fallback where a
host lacks one. A phase records every fallback it took in its handoff's
**Host fallbacks** section, which `handoff validate` requires for flows started
on 1.0.0 or later (a flow already in progress at upgrade is exempt). Commands are
Claude Code shortcuts only: each one routes to an `orch-flow` section and
holds no behaviour of its own, so invoking the skill on another host is
complete. `orch_test.sh` fails when a skill never points at the reference,
names the Skill or Agent tool as the step itself, or when a command runs
`orch.sh` or routes to a section that does not exist.

## Develop

```
claude --plugin-dir /path/to/orchestrator     # load the working tree directly
claude plugin validate .
scripts/test/orch_test.sh && scripts/test/hooks_test.sh
```

`--plugin-dir` is the development loop: it loads the working tree, so edits take
effect on the next session with no push. The installed copy is a clone of the
default branch pinned to `version` in `plugin.json`, so changes reach it only
after a push plus `/plugin marketplace update orchestrator`. Bump `version` when
publishing a change worth pulling.

Found a bug or want to propose a change? Open a GitHub issue on this repo -
label it `needs-triage` if it isn't already.

## Status

All four phases run. The spec phase works against the flow's issue, however it
arrived - published by `to-spec` in this phase, or already adopted at init,
carrying the required `ready-for-agent` triage label, in which case `to-spec`
is skipped entirely. Either way, it reviews the issue through four independent
lenses - Fidelity to the plan, Consistency with itself and the glossary,
Testability at the agreed seams, Implementability from the spec alone - and
puts every finding to the human as one batch of proposed edits; the edits
they accept rewrite the issue body, and the disposition is recorded on the
issue and in the handoff.

The implement phase works the spec issue's published ticket breakdown one
ticket at a time: `ticket next` names the ready frontier, and each ready
ticket goes to a fresh subagent carrying only its number and body. The
subagent follows the standard `implement` skill itself against that one
ticket, builds on the flow's single branch, commits its own work, and never
opens a PR or blocks on a human - a call it cannot make alone comes back as a
deviation in its report instead. The driving session closes the ticket only
once that report is in hand, then re-queries the frontier, until none remain
and it opens the one draft PR for the whole flow.

The review phase is a bounded loop: a budget of iterations the human chooses
at the start (five by default), a fresh review from the base SHA every one of
them by the plugin's own two reviewer agents (standards and spec), a
blocking/major/nit rubric applied on top of their reports, and every blocking
finding fixed along with the majors and mechanical nits that need no decision -
one fix commit per iteration that fixed anything. The driving session only
triages and decides: a fresh fixer agent makes each fix commit, and a fresh
closer agent files what is left and comments on the PR. The loop never
polishes its own fixes, and its final iteration fixes only what is blocking. The loop runs
its whole budget; when it ends, every major and nit it left becomes a GitHub
issue labelled `review:major` or `review:nit` (a severity the loop assigned)
plus the repo's `needs-triage` (a label meaning a human hasn't looked at it
yet), with the reviewer's finding and the loop's reasoning in the body. CI is
waited on once per loop with a single flake rerun per flow. It ends one of two
ways: by marking the draft PR ready, or by a **bounded stop** - the loop
giving up before the PR is ready and recording why, rather than looping
forever - and it comments on the PR either way. After a bounded stop, a human
may run the phase again as a fresh loop with its own budget.
`/orchestrator:doctor` covers the machine, the repo, and the active flow,
including the review loop's iteration count against its budget, the PR's CI
status, and its draft state against the flow's phase.

## License

MIT - see [LICENSE](LICENSE).
