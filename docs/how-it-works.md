# How it works

The detail behind [README.md](../README.md): what each phase does, every
command in full, the base branch, hosts, and the hooks that start a planning
session. Terms in bold are defined in [GLOSSARY.md](../GLOSSARY.md).

## The routes, step by step

A planning session - `orch-interview`, or one of the
[`mattpocock-skills`](https://github.com/mattpocock/skills) grilling entry
points - ends, once a shared understanding is reached, on one
`AskUserQuestion`: flow, quick implementation, or blueprint only.

- **Flow.** `/orchestrator:start` writes `01-plan.md`; then `/clear`.
  - The spec session: `orch-to-spec` publishes the issue (or it was already
    adopted at init), the spec review runs, and `orch-to-tickets` publishes
    the tickets; it writes `02-spec.md`. Then `/clear`.
  - The implement session: branch `orch/<issue>-<slug>`, one subagent per
    ticket, `ticket next`/`close`, a draft PR; it writes `03-implement.md`.
    Then `/clear`.
  - The review session: the bounded review loop - triage, fix, verify, CI -
    ending ready, or on a bounded stop. After a bounded stop, `/clear` and a
    fresh review session may run again.
- **Quick implementation** (`orchestrator:orch-quick-implement`): an issue,
  an unattended spec review, `orch-to-tickets` publishing tickets, branch
  `quick/<issue>-<slug>`, one subagent per ticket building test-first, a
  review pass, and a PR.
- **Blueprint only**: `orch-to-spec` publishes the issue, a spec review is
  offered, `orch-to-tickets` publishes the tickets, and it stops.

A quick implementation is for work that does not need the pipeline - see
GLOSSARY.md's **Quick implementation** entry. It skips all four phases: no
handoff, no `.orchestrator/state.json`, just a linked issue, `orch-to-tickets`
publishing that issue's ticket breakdown, the same
one-`orch-implementer`-per-ticket driver loop the implement phase uses,
building its frontier in parallel (ending in `pr publish` instead of a draft
`pr open`), a review pass by the plugin's own reviewer agents, and a PR. A
human can run another review pass of the same branch on demand, with
`/orchestrator:review <issue>` - see GLOSSARY.md's **Review pass** entry.

The plugin carries everything it runs: `orch-to-spec` writes the spec,
`orch-to-tickets` breaks it into tickets, each ticket subagent builds its
ticket test-first, and the plugin owns the state, the handoffs, the branch,
the PR, and the reviewer agents that both the review loop and a review pass
start. If you have `mattpocock-skills` installed, its `grilling`, `grill-me`,
`grill-with-docs`, and `wayfinder` also start a planning session.

Handoffs live in `.orchestrator/handoff/`. It and `.scratch/`, where planning
drafts land, are ignored via `.git/info/exclude` so running the flow never
dirties a repo's working tree.

## The phases

All four phases run.

### Spec

The spec phase works against the flow's issue, however it arrived -
published by `orch-to-spec` in this phase, or already adopted at init,
carrying the required `ready-for-agent` triage label, in which case
`orch-to-spec` is skipped entirely. Either way, it first proposes folding into
the issue body whatever the issue's comments say that the body does not, then
reviews the issue, body and comments, through four independent lenses -
Fidelity to the plan, Consistency with itself and the glossary, Testability at
the agreed seams, Implementability from the spec alone - each a read-only
agent (`orch-lens-fidelity`, `orch-lens-consistency`, `orch-lens-testability`,
`orch-lens-implementability`), and puts every finding to the human as one
batch of proposed edits; the edits they accept rewrite the issue body, and the
disposition is recorded on the issue and in the handoff. When the issue
already has a ticket breakdown and the accepted edits touch an open ticket,
the review then asks a ticket question: edit the tickets the change touches,
or retire the breakdown so the issue is broken down again.

### Implement

The implement phase works the spec issue's published ticket breakdown by its
**frontier**: `ticket next` names the ready tickets, and up to the clone's
parallel cap of them are built at once (ADR-0036). Each ready ticket goes to a
fresh `orch-implementer` agent, started in the background, carrying only its
number, the `orch.sh` path and the path of its **ticket worktree**: `orch.sh
ticket-worktree add` forks a ticket branch from the flow's branch tip and
checks it out under `.orchestrator/worktrees/`. The agent builds that one
ticket test-first from its own adapted copy of `tdd`'s rules, on its ticket
branch, commits its own work, and checks its commits against the ticket's
acceptance criteria, and that a test exercises every source file they
changed. It cannot start sub-agents or ask the human anything: a call it
cannot make alone comes back as a deviation in its report, a criterion it
could not meet as unmet, and a source file it could not cover as untested.
When a report is in hand, the driving session lands the ticket branch on the
flow's branch with `orch.sh ticket merge` (a rebase and a fast-forward),
closes the ticket, removes its worktree, and refills the free slots from the
re-queried frontier. A ticket whose merge conflicts is resolved, not rebuilt:
the driver resumes the ticket's own implementer to rebase and resolve it in
its worktree (or starts a fresh `orch-resolver` there), and only if that
resolution fails is the ticket redone alone once nothing else is in flight.
When none remain, it runs the full verification once on the combined branch,
runs a base sync to bring the flow's branch up to date with its base, and
opens the one draft PR for the whole flow.

A collapsed breakdown, a cap of 1, or a host that cannot start a background
subagent builds one ticket at a time on the flow's branch, with no worktrees.
Leftover ticket worktrees from an interrupted run stop the next implement
phase and fail `doctor --flow`; `orch.sh ticket-worktree list` shows them and
`orch.sh ticket-worktree remove <n>` clears each.

#### Parallel cap

| Command | What it does |
| --- | --- |
| `orch.sh parallel show` | Print the parallel cap: the clone's local git config key `orchestrator.parallel` when set, 3 otherwise. 1 means one ticket at a time. Set it with `git config orchestrator.parallel <n>`: shared by every worktree, never committed. |

### Review

The review phase is a bounded loop: a budget of iterations the human chooses
at the start (five by default), a fresh review from the base SHA every one of
them by the plugin's own two reviewer agents (standards and spec), a
blocking/major/nit rubric applied on top of their reports, and every blocking
finding fixed along with the majors and mechanical nits that need no
decision - one fix commit per iteration that fixed anything. The driving
session only triages and decides: a fresh fixer agent makes each fix commit,
and a fresh closer agent files what is left and comments on the PR. The loop
never polishes its own fixes, and its final iteration fixes only what is
blocking. The loop runs its whole budget; when it ends, every major and nit
it left becomes a GitHub issue labelled `review:major` or `review:nit` (a
severity the loop assigned), the repo's `needs-triage` (a label meaning a
human hasn't looked at it yet), and a category - `bug` for a Spec-axis
finding, `enhancement` for a Standards-axis one - with the reviewer's finding
and the loop's reasoning in the body. CI is waited on once per loop with a
single flake rerun per flow.

It ends one of two ways: by marking the draft PR ready, or by a **bounded
stop** - the loop giving up before the PR is ready and recording why, rather
than looping forever - and it comments on the PR either way. After a bounded
stop, a human may run the phase again as a fresh loop with its own budget.

### Finding triage

A filed finding returns to the pipeline through **finding triage**
(`/orchestrator:finding-triage`), which checks it against the default branch
and closes it as completed, or moves it to `ready-for-agent`,
`ready-for-human`, or `wontfix`; with `--bundle`, it groups the
already-triaged findings of one code area into a **bundle** issue and closes
each as its duplicate.

### Doctor

`/orchestrator:doctor` covers the machine, the repo, and the active flow,
including the review loop's iteration count against its budget, the PR's CI
status, and its draft state against the flow's phase. It also FAILs on
changes in the working tree outside the planning allowlist: every phase
commits its own work before it ends, so such changes are a bug in the phase
that left them.

## Commands in detail

| Command | What it does |
| --- | --- |
| `/orchestrator:start [slug] [--issue N] [--side]` | Start a flow from an approved plan. Runs in the planning session. `--side` starts it in a side checkout up front; one is also offered when a flow is already mid-pipeline here. |
| `/orchestrator:next` | Run the next phase. Run it in a fresh session. |
| `/orchestrator:status` | Phase, issue, branch, PR, and the flow's health. |
| `/orchestrator:doctor` | Diagnose the machine, the repo, and the active flow. |
| `/orchestrator:redo` | Step back one phase and re-run it. |
| `/orchestrator:abort` | Archive the flow to `.orchestrator/archive/`. |
| `/orchestrator:finish` | Clean up every finished side checkout: its PR merged on GitHub, its tree clean, any flow at `done`. Archives its flow into the main checkout, removes it, and deletes its local branch; archives the main checkout's finished flow in place. Removes nothing when GitHub cannot be read. |
| `/orchestrator:release` | Open the release PR that carries the base branch into the default branch (see [Base branch](#base-branch)). |
| `/orchestrator:spec-review <issue> [--rounds <n>]` | Review any spec issue on demand, outside a flow: a standalone spec review, of 1 round unless `--rounds` gives another count. |
| `/orchestrator:review <issue>` | Review the current branch against an issue on demand, outside a flow: a standalone review pass. Drops findings an earlier pass on the branch's open PR already declined, fixes what it agrees with, and posts what it declines - and what it dropped as previously declined - on that PR. |
| `/orchestrator:sync` | Run a **base sync** on demand, on any plugin-made branch, inside or outside a flow - a done flow's included: merge `origin`'s tip of its base branch in with `orch.sh branch sync`, never rebasing. A conflict is resolved by a fresh `orch-resolver`, its **Merge resolutions** posted as one PR comment; then, unless an active flow holds the branch, it asks whether to run a review pass against the branch's issue (from its name, or asked for when the name carries none). |
| `/orchestrator:interview` | Start a planning session: an interview that reaches a shared understanding, then asks how to carry it forward. |
| `/orchestrator:quick-implement [<issue>] [--side]` | Start a quick implementation, the route with no flow: with an issue number, that issue is its linked issue; with none, it finds or publishes one. `--side` asks for a side checkout up front. |
| `/orchestrator:to-spec [<issue>]` | Turn the current conversation into a spec, outside any flow: publish it as a new issue, or, given an issue number, rewrite that issue's body as the spec (rewrite mode). |
| `/orchestrator:to-tickets <issue>` | Break an existing issue into tickets published as its sub-issues, or collapse it into the issue, outside any flow. |
| `/orchestrator:finding-triage [--all] [<issue> \| --pr <n>] \| --bundle` | Finding triage: check the review loop's open filed findings against the default branch and move each out of `needs-triage`, one batch of proposed outcomes per source PR. `--all` is a re-check: it also takes findings already triaged, proposing each only close as completed or leave as is. `--bundle` groups the open findings already triaged to `ready-for-agent` or `ready-for-human` by code area into bundle issues, one batch across source PRs, through `orch.sh finding-triage bundle --title <t> --body-file <f> --state <ready-for-agent\|ready-for-human> --category <bug\|enhancement> <member>...`: each bundle is labelled `finding-bundle` and restates its members, and each member is closed as a duplicate of it (`orch.sh finding-triage bundle --into <B> <member>...` resumes a partly failed bundle). |

## Base branch

Flows and quick implementations fork from the repo's default branch unless
you set another **base branch** for the checkout - for instance a `uat`
branch that gathers a multi-ticket project:

| Command | What it does |
| --- | --- |
| `orch.sh base set <branch>` | Set the base branch. Refuses a branch `origin` does not have. Stored in the clone's local git config (`orchestrator.base`): shared by every worktree, never committed, kept through `abort` and archiving. Setting the default branch's name clears it. |
| `orch.sh base set <branch> --flow` | Correct the active flow's own base branch instead, leaving the checkout setting alone. Only while the flow has no branch: before `branch create`, or after `redo review` retires it. Stores the name as given. Refuses an invalid branch name or one `origin` does not have. |
| `orch.sh base show` | Print the base branch in effect and its source: `set`, or `default`. |
| `orch.sh base clear` | Go back to the default branch. Succeeds when nothing was set. |
| `orch.sh branch sync` | Bring the current plugin-made branch up to date with its base branch: merge `origin`'s tip of the base into it (never a rebase, never the local base), record that tip as its base SHA, and push with a plain push when the branch has an upstream. Exit 3 on a conflict, the merge left in progress for a resolver; exit 1 on a refusal. Rerunning it after the conflict is committed finishes the sync. |
| `orch.sh pr release [--force] <title> <body-file>` | Open the **release PR**: a non-draft PR from the base branch into the default branch. Its body starts with one `Closes #N` line per still-open issue that any PR merged into the base branch refers to (`Refs`, `Closes`, `Fixes` or `Resolves #N`, anywhere in the body). Refuses on the default branch, while a release PR is already open, and with nothing to close unless `--force`. Pushes nothing. |

`/orchestrator:doctor` reports the base branch in effect, and FAILs when the
one you set is gone from `origin`.

A PR into a base branch other than the default says `Refs #N` rather than
`Closes #N`, because GitHub only closes issues on merges into the default
branch. `/orchestrator:release` closes them: the model writes the release
PR's title and summary, and `orch.sh pr release` writes the `Closes` lines.

## Hosts

The plugin runs on Claude Code and on the Junie CLI; Junie's setup is in
[docs/junie/README.md](junie/README.md), and
[docs/host-capabilities.md](host-capabilities.md) maps each capability to
each host.

Doctor reports the host it detects and the capabilities that host lacks
(from [docs/host-capabilities.md](host-capabilities.md)). It reads Claude
Code from `CLAUDECODE` or `CLAUDE_PLUGIN_ROOT` and Junie from
`JUNIE_SHIM_PATH` (set in Junie CLI's agent shell) or `JUNIE_EXTENSION_ROOT`
(set for extension hooks); set `ORCHESTRATOR_HOST=claude` or `junie` where
neither reaches the shell. Install the whole plugin, not just its skills:
every skill runs `scripts/orch.sh`.

## Activation

A `PostToolUse` hook on `Skill(orch-interview)`, and on the
`mattpocock-skills` entry points named above when they are installed, starts
a planning session. It fires once per session and tells the model that once a
shared understanding is reached, the next step is a human's call, not the
model's: call `AskUserQuestion` with exactly three options, start the flow
(`orchestrator:orch-flow`), a quick implementation
(`orchestrator:orch-quick-implement`), or a blueprint only (publish the spec,
offer a spec review, publish the ticket breakdown, then stop), and do
whichever the human picks.

Beside a flow already running in the checkout (any phase but `done`), it
still sends the planning rules, with a closing that names that flow - its
issue, or its slug when it has none, and its phase - and states two branches
for the model to pick from. Planning about that flow's own issue gets no
route question, only a pointer to `/orchestrator:next` or
`/orchestrator:redo`. Planning about anything else gets the interviewed-issue
step and the route question, which says Blueprint only is the one route that
runs in this checkout: "Start the orchestrator flow" and "Quick
implementation" proceed in a side checkout, a git worktree of their own
opened in its own session. With no flow running, the message tells the model
to honour a human's request for a side checkout.

`orch.sh side-checkout add <slug> --issue N` makes a side checkout for a
quick implementation and records `N`, its issue, in the side checkout's
ownership marker; without `--issue` the marker records nothing. Run inside a
checkout, `orch.sh side-checkout issue` prints the recorded issue, and exits 1
in a checkout that is not a side checkout or records none, so a session
opened there picks the issue up without being told. `side-checkout list`
appends `quick #N` to each side checkout that records one.

`/clear` (and Junie's `/new`) resets the once-per-session marker: a
`SessionStart` hook on source `clear`, `hook-session-start.sh`, deletes the
session's planning markers, so the next planning run in the fresh context
gets the message again and the edit guard is no longer armed. Compaction
keeps them.

Junie has no `PostToolUse` event, so the same hook also runs on
`UserPromptSubmit` and fires there when the prompt names a grilling entry
point (`/orch-interview`, `/orchestrator:interview`, `/grilling`,
`$grill-me`, `/wayfinder`, and so on). It sends nothing when Junie picks
grilling on its own. Junie routes grilling into its plan mode, whose plan
agent ends on Junie's own plan screen instead of asking the closing question.
So when the human confirms that screen, which submits `Implement the
suggested plan`, the hook asks the question there, before any file is
edited. On Junie the question is asked with its `ask_user` tool. On Claude
Code the `UserPromptSubmit` entry exits silently.

A `PreToolUse` hook on `Edit`/`Write` enforces that: during a planning
session with no flow started, or with only a `done` flow, source edits are
denied. Agent docs, scratch and flow-state files stay writable - the paths
listed in `scripts/planning-allowlist.sh`. The glossary and ADRs - the paths
its `PLANNING_RECORDS` lists - are records, and planning never changes them
in place: an edit to one is denied with a redirect, and the exact wording
goes into the plan instead, so the spec carries it verbatim and it lands with
the change it describes (ADR-0022). This holds even when `domain-modeling` or
`improve-codebase-architecture` asks to update them inline. A third
`PostToolUse` hook on the same `Skill` matcher lifts the guard for a quick
implementation: it deletes the session's marker file when
`orchestrator:orch-quick-implement` fires, without `hook-guard.sh` itself
changing. The guard does not arm on Junie (ADR-0025): there the planning
message and the snippet's standing planning section steer planning away from
source edits, and `orch.sh init`'s working-tree check catches any at flow
start.
