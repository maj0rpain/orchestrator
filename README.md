# orchestrator

A Claude Code plugin that separates **planning**, **spec writing**,
**implementation**, and **review** into four phases, each running in a fresh
session, connected by handoff files.

The problem it solves: one long session that plans, specs, builds, and reviews
carries every earlier phase's context into the next. The reviewer already
believes the implementer's reasoning. Splitting the phases and passing only a
written handoff between them means each phase judges the work, not the story
behind it.

The plugin carries everything it runs: `orch-to-spec` writes the spec,
`orch-to-tickets` breaks it into tickets, each ticket subagent builds its
ticket test-first, and the plugin owns the state, the handoffs, the branch, the
PR, and the reviewer agents that both the review loop and a review pass
start. If you have
[`mattpocock-skills`](https://github.com/mattpocock/skills) installed, its
`grilling`, `grill-me`, `grill-with-docs`, and `wayfinder` also start a
planning session.

## Install

```
/plugin marketplace add maj0rpain/orchestrator
/plugin install orchestrator@orchestrator
```

The repo doubles as its own single-plugin marketplace, so there is no separate
marketplace repo. Installs at user scope, so it is available in every project on
that machine.

Requires `gh`, `jq`, and `git`. No per-repo setup is needed: issues are
labelled with the five canonical triage label names (`needs-triage`,
`needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`), or with the
names a `docs/agents/triage-labels.md` table maps them to, when the repo has
one. `/orchestrator:doctor` reports all of this at any time, including any of
those labels the repo is missing.

"Junie" in this README and across the plugin means the Junie CLI, not the
Junie plugin for JetBrains IDEs. Junie CLI support rests on its bundled
documentation, and some of it is unverified (see
[docs/host-capabilities.md](docs/host-capabilities.md)). Junie loads the
plugin's `agents/`, but a capability filter at agent start usually hides them
from the model, so the flow starts a general-purpose agent briefed with the
agent's file instead. JetBrains tracks this as
[JUNIE-5493](https://youtrack.jetbrains.com/issue/JUNIE-5493); until it is
fixed, append the plugin's snippet
[docs/junie/AGENTS.md](docs/junie/AGENTS.md) to your user-scoped
`~/.junie/AGENTS.md`, which tells Junie each skill needs its custom agents
and also carries a standing planning section and a standing finding-the-plugin
section: where `orch.sh` is, and what to do when an orch-* skill or agent is
hidden:
`cat "$HOME"/.junie/extensions/*/orchestrator/docs/junie/AGENTS.md >> ~/.junie/AGENTS.md`.
If the glob matches more than one install, pick one path and `cat` only that.
The snippet sits between `<!-- orchestrator:begin -->` and
`<!-- orchestrator:end -->` markers, so it can be replaced cleanly; its
custom-agents section goes once JUNIE-5493 is fixed. As a fallback, naming the
agent in your own prompt keeps it visible, for example "For step 4, start the
custom agent orch-implementer by name." Naming it in a skill does not.

Doctor reports the host it detects and the capabilities that host lacks (from
[docs/host-capabilities.md](docs/host-capabilities.md)). It reads Claude Code
from `CLAUDECODE` or `CLAUDE_PLUGIN_ROOT` and Junie from `JUNIE_SHIM_PATH` (set
in Junie CLI's agent shell) or `JUNIE_EXTENSION_ROOT` (set for extension hooks);
set `ORCHESTRATOR_HOST=claude` or `junie` where neither reaches the shell.
Install the whole plugin, not just its skills: every skill runs `scripts/orch.sh`.

Upgrading from 0.x: 1.0.0 renamed every skill to carry an `orch-` prefix (the
flow skill is now `orchestrator:orch-flow`, and so on). See
[CHANGELOG.md](CHANGELOG.md) for the full old-to-new list.

## The flow

```
  planning session          shared understanding reached
  (orch-interview, or a ->  AskUserQuestion: flow, quick, or blueprint only?
   mattpocock grilling)                                |
                 +-------------------------------------+-------------------+
                 |                                     |                   |
       /orchestrator:start          orchestrator:orch-quick-implement   blueprint only
       ->  01-plan.md               issue, unattended spec review,      orch-to-spec publishes
                 |                  orch-to-tickets publishes tickets,  the issue, spec review
                 | /clear           branch quick/<issue>-<slug>, one    offered, orch-to-tickets
                 |                  subagent per ticket, tdd, review    publishes tickets, stop
                 |                  pass, PR
                 +-------------------------------------+
                                                       |
  spec session         orch-to-spec publishes the    <--+
                       issue, or already adopted at init
                       spec review
                       orch-to-tickets publishes
                       tickets                       ->  02-spec.md
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
implementation instead of starting a flow - see GLOSSARY.md's **Quick
implementation** entry. It skips all four phases: no handoff, no
`.orchestrator/state.json`, just a linked issue, `orch-to-tickets` publishing that
issue's ticket breakdown, the same one-`orch-implementer`-per-ticket driver
loop the implement phase uses, building its frontier in parallel (ending in `pr publish` instead of a draft `pr open`), a
review pass by the plugin's own reviewer agents, and a PR. A human can run
another review pass of the same branch on demand, with
`/orchestrator:review <issue>` - see GLOSSARY.md's **Review pass** entry.

Handoffs live in `.orchestrator/handoff/`. It and `.scratch/`, where planning
drafts land, are ignored via `.git/info/exclude` so running the flow never
dirties a repo's working tree.

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
| `/orchestrator:spec-review <issue>` | Review any spec issue on demand, outside a flow: a standalone spec review. |
| `/orchestrator:review <issue>` | Review the current branch against an issue on demand, outside a flow: a standalone review pass. Drops findings an earlier pass on the branch's open PR already declined, fixes what it agrees with, and posts what it declines - and what it dropped as previously declined - on that PR. |
| `/orchestrator:interview` | Start a planning session: an interview that reaches a shared understanding, then asks how to carry it forward. |
| `/orchestrator:to-spec` | Turn the current conversation into a spec and publish it as an issue, outside any flow. |
| `/orchestrator:to-tickets <issue>` | Break an existing issue into tickets published as its sub-issues, or collapse it into the issue, outside any flow. |
| `/orchestrator:finding-triage [<issue> \| --pr <n>]` | Finding triage: check the review loop's open filed findings against the default branch and move each out of `needs-triage`, one batch of proposed outcomes per source PR. |

### Base branch

Flows and quick implementations fork from the repo's default branch unless
you set another **base branch** (see GLOSSARY.md) for the checkout - for
instance a `uat` branch that gathers a multi-ticket project:

| Command | What it does |
| --- | --- |
| `orch.sh base set <branch>` | Set the base branch. Refuses a branch `origin` does not have. Stored in the clone's local git config (`orchestrator.base`): shared by every worktree, never committed, kept through `abort` and archiving. Setting the default branch's name clears it. |
| `orch.sh base set <branch> --flow` | Correct the active flow's own base branch instead, leaving the checkout setting alone. Only while the flow has no branch: before `branch create`, or after `redo review` retires it. Stores the name as given. Refuses an invalid branch name or one `origin` does not have. |
| `orch.sh base show` | Print the base branch in effect and its source: `set`, or `default`. |
| `orch.sh base clear` | Go back to the default branch. Succeeds when nothing was set. |
| `orch.sh pr release [--force] <title> <body-file>` | Open the **release PR** (see GLOSSARY.md): a non-draft PR from the base branch into the default branch. Its body starts with one `Closes #N` line per still-open issue that any PR merged into the base branch refers to (`Refs`, `Closes`, `Fixes` or `Resolves #N`, anywhere in the body). Refuses on the default branch, while a release PR is already open, and with nothing to close unless `--force`. Pushes nothing. |

`/orchestrator:doctor` reports the base branch in effect, and FAILs when the
one you set is gone from `origin`.

A PR into a base branch other than the default says `Refs #N` rather than
`Closes #N`, because GitHub only closes issues on merges into the default
branch. `/orchestrator:release` closes them: the model writes the release PR's
title and summary, and `orch.sh pr release` writes the `Closes` lines.

A command must not share its bare name with a host built-in command (for
example Claude Code's `/plan`, `/review`, `/status` or `/doctor`), because the
typeahead lists both.

## Why separate sessions

The separate sessions are the point: fresh context per phase, and room for
the human-in-the-loop exchanges that `orch-to-spec` (test seams) and the spec
review depend on.

## Activation

A `PostToolUse` hook on `Skill(orch-interview)`, and on the mattpocock-skills
entry points named above when they are installed, starts a planning session.
It fires once per session, stays quiet when a flow is already running, and
tells the model that once a shared understanding is reached, the next step
is a human's call, not the model's: call `AskUserQuestion` with exactly three
options, start the flow (`orchestrator:orch-flow`), a quick implementation
(`orchestrator:orch-quick-implement`), or a blueprint only (publish the spec,
offer a spec review, publish the ticket breakdown, then stop), and do whichever
the human picks.

`/clear` (and Junie's `/new`) resets the once-per-session marker: a
`SessionStart` hook on source `clear`, `hook-session-start.sh`, deletes the
session's planning markers, so the next planning run in the fresh context gets
the message again and the edit guard is no longer armed. Compaction keeps them.

Junie has no `PostToolUse` event, so the same hook also runs on
`UserPromptSubmit` and fires there when the prompt names a grilling entry
point (`/orch-interview`, `/orchestrator:interview`, `/grilling`, `$grill-me`,
`/wayfinder`, and so on). It sends nothing when Junie picks grilling on its own. Junie routes grilling into its plan
mode, whose plan agent ends on Junie's own plan screen instead of asking the
closing question. So when the human confirms that screen, which submits
`Implement the suggested plan`, the hook asks the question there, before any
file is edited. On Junie the question is asked with its `ask_user` tool. On Claude Code the `UserPromptSubmit` entry exits silently.

A `PreToolUse` hook on `Edit`/`Write` enforces that: during a planning session
with no flow started, or with only a `done` flow, source edits are denied. Agent
docs, scratch and flow-state files stay writable - the paths listed in
`scripts/planning-allowlist.sh`. The glossary and ADRs (`GLOSSARY.md`,
`GLOSSARY-MAP.md`, `CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/`) are records,
and planning never changes them in place: an edit to one is denied with a
redirect, and the exact wording goes into the plan instead, so the spec
carries it verbatim and it lands with the change it describes (ADR-0022).
This holds even when `domain-modeling` or `improve-codebase-architecture`
asks to update them inline. A third `PostToolUse` hook on the same `Skill`
matcher lifts the guard for a quick implementation: it deletes the session's
marker file when `orchestrator:orch-quick-implement` fires, without
`hook-guard.sh` itself changing. The guard does not arm on Junie (ADR-0025):
there the planning message and the snippet's standing planning section steer
planning away from source edits, and `orch.sh init`'s working-tree check
catches any at flow start.

## Layout

```
commands/                     start, next, status, doctor, redo, abort, release, spec-review, review, interview, to-spec, to-tickets, finding-triage
agents/                       the fresh agents: two reviewers (the review loop's and the review pass's), the review loop's fixer and closer, the spec review's four lenses, and the implementer
skills/orch-flow/             the state machine (judgment)
skills/orch-spec-review/      the spec review: consolidation of the issue's comments, then four lenses in a flow (three standalone), one batch question, plus a ticket question when an existing breakdown is touched
skills/orch-review/           the review loop: rubric, authority rules, terminal states; and the review pass, quick or standalone
skills/orch-handoff/          handoff templates, model-invocable unlike the upstream one
skills/orch-quick-implement/  the other route: issue, unattended spec review, orch-to-tickets, tdd, review pass, PR - no flow
skills/orch-interview/        the planning interview; hook-grilling.sh's message asks the closing question
skills/orch-to-spec/          turns the conversation into a spec and publishes it as an issue
skills/orch-to-tickets/       breaks an issue into tickets published as sub-issues, or collapses 0-1 into the issue
skills/orch-release/          the release PR: model writes title and summary, pr release writes Closes lines
skills/orch-finding-triage/   finding triage: scan the filed findings against the default branch, one batch per source PR, apply
scripts/orch.sh               every deterministic operation (mechanism)
scripts/doctor.sh             diagnostics plus triage-label/issue-adoption parsing, sourced by orch.sh and hook-grilling.sh
scripts/hook-*.sh             the four hooks; hook-grilling.sh also runs on UserPromptSubmit for Junie
scripts/hook-common.sh        payload reading and dual-host (Claude Code + Junie) output shared by the hooks
scripts/planning-allowlist.sh the planning allowlist and planning records, shared by the edit guard and orch.sh
scripts/test/                 shell tests
docs/host-capabilities.md     how each host provides each capability a skill names, and the fallbacks
docs/junie/AGENTS.md          Junie snippet: standing planning and finding-the-plugin sections (where orch.sh is, what to do when an orch-* skill or agent is hidden), and each skill's custom agents (JUNIE-5493 workaround)
hooks/hooks.json              hook wiring
```

Prose for judgment, bash for facts. Reading state, naming branches, resolving the
default branch, and validating handoffs all have one right answer, so they live in
`orch.sh` where they cannot drift between sessions.

### Resolving orch.sh

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

### Naming host capabilities

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

## Develop

```
claude --plugin-dir /path/to/orchestrator     # load the working tree directly
claude plugin validate .
scripts/test/all.sh                           # every suite; run once before committing
```

While iterating, run only the section you are working on, in quiet mode:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`, where
`<section>` is an extended regex matched against the `# ---` section titles. Run
`scripts/test/all.sh` once before committing: it runs all three suites, carries
on past a failing one, and prints each suite's FAIL lines and a summary line;
then it runs shellcheck over every shell file and prints its findings and a
`shellcheck: N findings` summary line, or `shellcheck: not installed - skipped`,
which fails the run only in CI.

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

Found a bug or want to propose a change? Open a GitHub issue on this repo -
label it `needs-triage` if it isn't already.

## Status

All four phases run. The spec phase works against the flow's issue, however it
arrived - published by `orch-to-spec` in this phase, or already adopted at
init, carrying the required `ready-for-agent` triage label, in which case
`orch-to-spec` is skipped entirely. Either way, it first proposes folding into
the issue body whatever the issue's comments say that the body does not, then
reviews the issue, body and comments, through four independent
lenses - Fidelity to the plan, Consistency with itself and the glossary,
Testability at the agreed seams, Implementability from the spec alone - each
a read-only agent (`orch-lens-fidelity`, `orch-lens-consistency`,
`orch-lens-testability`, `orch-lens-implementability`), and puts every finding
to the human as one batch of proposed edits; the edits they accept rewrite the
issue body, and the disposition is recorded on the issue and in the handoff.
When the issue already has a ticket breakdown and the accepted edits touch an
open ticket, the review then asks a ticket question: edit the tickets the
change touches, or retire the breakdown so the issue is broken down again.

The implement phase works the spec issue's published ticket breakdown by its
**frontier** (see GLOSSARY.md): `ticket next` names the ready tickets, and
up to the clone's parallel cap of them are built at once (ADR-0036). Each
ready ticket goes to a fresh `orch-implementer` agent, started in the
background, carrying only its number, the `orch.sh` path and the path of its
**ticket worktree**: `orch.sh ticket-worktree add` forks a ticket branch from
the flow's branch tip and checks it out under `.orchestrator/worktrees/`.
The agent builds that one ticket test-first from its own adapted copy of `tdd`'s rules, on its
ticket branch, commits its own work, and checks its commits against the
ticket's acceptance criteria, and that a test exercises every source file
they changed. It cannot start sub-agents or ask the human anything: a call it
cannot make alone comes back as a deviation in its report, a criterion it
could not meet as unmet, and a source file it could not cover as untested. When a
report is in hand, the driving session lands the ticket branch on the flow's
branch with `orch.sh ticket merge` (a rebase and a fast-forward), closes the
ticket, removes its worktree, and refills the free slots from the
re-queried frontier. A ticket whose merge conflicts is redone alone once
nothing else is in flight. When none remain, it runs the full verification
once on the combined branch and opens the one draft PR for the whole flow.
A collapsed breakdown, a cap of 1, or a host that cannot start a background
subagent builds one ticket at a time on the flow's branch, with no
worktrees. Leftover ticket worktrees from an interrupted run stop the next
implement phase and fail `doctor --flow`; `orch.sh ticket-worktree list`
shows them and `orch.sh ticket-worktree remove <n>` clears each.

| Command | What it does |
| --- | --- |
| `orch.sh parallel show` | Print the parallel cap: the clone's local git config key `orchestrator.parallel` when set, 3 otherwise. 1 means one ticket at a time. Set it with `git config orchestrator.parallel <n>`: shared by every worktree, never committed. |

The review phase is a bounded loop: a budget of iterations the human chooses
at the start (five by default), a fresh review from the base SHA every one of
them by the plugin's own two reviewer agents (standards and spec), a
blocking/major/nit rubric applied on top of their reports, and every blocking
finding fixed along with the majors and mechanical nits that need no decision -
one fix commit per iteration that fixed anything. The driving session only
triages and decides: a fresh fixer agent makes each fix commit, and a fresh
closer agent files what is left and comments on the PR. The loop never
polishes its own fixes, and its final iteration fixes only what is blocking.
The loop runs its whole budget; when it ends, every major and nit it left
becomes a GitHub issue labelled `review:major` or `review:nit` (a severity
the loop assigned), the repo's `needs-triage` (a label meaning a human
hasn't looked at it yet), and a category - `bug` for a Spec-axis finding,
`enhancement` for a Standards-axis one - with the reviewer's finding and the
loop's reasoning in the body. A filed finding returns to the pipeline
through **finding triage** (`/orchestrator:finding-triage`), which checks it
against the default branch and closes it as completed, or moves it to
`ready-for-agent`, `ready-for-human`, or `wontfix`. CI is waited on once per loop with a single flake rerun per flow.
It ends one of two ways: by marking the draft PR ready, or by a **bounded
stop** - the loop giving up before the PR is ready and recording why, rather
than looping forever - and it comments on the PR either way. After a bounded
stop, a human may run the phase again as a fresh loop with its own budget.
`/orchestrator:doctor` covers the machine, the repo, and the active flow,
including the review loop's iteration count against its budget, the PR's CI
status, and its draft state against the flow's phase.

## License

MIT - see [LICENSE](LICENSE).
