---
name: orch-quick-implement
description: Implement a small, already-understood change directly and hands-off, skipping the plan/spec/implement/review pipeline. Reached when a human picks "quick implementation" at hook-grilling.sh's closing question, runs /orchestrator:quick-implement [<issue>], or is invoked directly for work that plainly does not need the full flow. Still requires a linked issue, an unattended spec review, a published ticket breakdown, test-driven implementation, and a review pass before the PR opens.
---

# Orchestrator quick implementation

The other route from an approved plan to a pull request, alongside a flow -
see `GLOSSARY.md`'s **Quick implementation** entry and
`docs/adr/0006-quick-implementation-unblocks-the-edit-guard-by-deleting-the-planning-marker.md`.
A thin router, not a second pipeline: no phases, no handoff, no
`.orchestrator/state.json`. What it does not skip is this project's standard
for how a change gets made - test-driven, reviewed, then opened as a PR.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Steps here name capabilities (invoke a skill, start a fresh subagent,
start a background subagent).
`docs/host-capabilities.md` under the plugin root maps each one to your host.
Where your host's cell says **Fallback**, or **Unverified** and the capability
turns out missing, take the fallback it documents and list it under a **Host fallbacks** heading in the PR body (step 7).

## 1. Require a linked issue

Never proceed without one, and never decide silently whether to make one.

- An issue named in the arguments - `/orchestrator:quick-implement <issue>`,
  its leading issue number, never a flag such as `--side` - is the linked
  issue: use it, and publish none.
- A linked issue already exists (named earlier in this conversation, or on an
  already-checked-out branch): use it.
- Otherwise, publish one now with `bash "$ORCH" issue publish "<title>"
  <body-file>`, from the shared understanding just reached. It applies the
  `ready-for-agent` triage role's label and reads the title and label back
  before it reports success - never an ad hoc `gh` call.
- Either way, a glossary or ADR change (`GLOSSARY.md`, `GLOSSARY-MAP.md`,
  `docs/adr/`) the planning session decided goes into the linked issue's body
  word for word - the new or replaced text, naming the file and entry - never
  into those files during planning. It lands with the change it describes
  (ADR-0022). The standalone spec review in step 2 runs no Fidelity lens, so
  nothing else checks the wording survived.
- If neither holds - no linked issue, and `issue publish` fails - stop and
  say why. A quick implementation
  with no issue behind it is exactly the unaccountable path this skill exists
  to avoid.

With `--side` in the arguments, or when the human asked in words for a side
checkout, stop here once the issue is linked and go to **Starting in a side
checkout** below: steps 2-7 run in the side checkout's own session.

## 2. Run an unattended spec review

Run it on every run, whether the linked issue was just published in step 1 or
already existed, and ask nothing: a quick implementation is hands-off, and
the human's control here was the choice of route (ADR-0034). Invoke the
`orch-spec-review` skill and follow its **Standalone spec review** entry in
its **Unattended spec review** mode on the linked issue, through to its end.
That mode is the one definition of what the review does unattended - the
batch printed and applied as recommended, decision items and the ticket
follow-up taking their recommended option, retiring included - and this step
restates none of it. Fidelity does not run, and no plan file is written.

Remember the review's working directory - the one `spec-review begin`
printed: step 7 reads the review's `changelog.md` there.

If the review stops - the guard refuses, or a fetch or write fails - quick
implementation stops too: relay the review's message and do not go on to
step 3. If it retired the breakdown and the new breakdown then failed,
stop too; a rerun sees `ticket exists` exit 1 at step 3 and breaks the
issue down again. Note every host fallback the review takes, and list it
under the PR body's **Host fallbacks** in step 7 as well as in the review's
changelog comment. Failed lenses stay in the changelog only.

## 3. Publish the ticket breakdown

Unconditional, whether the linked issue was just published in step 1 or
already existed - never gated by a human choice of its own, the same treatment the flow's spec phase gives this same
step. No spec-writing step exists on this path, so the breakdown is drawn
directly off the linked issue as it stands after step 2's spec review -
it is the only spec this path has.

First run `bash "$ORCH" ticket exists <linked issue>`:

- **Exit 0**: the linked issue already has a breakdown - a blueprint, say.
  Skip the breakdown and ask nothing: step 2's spec review may already have
  reconciled the breakdown with the edits it applied, or retired it and
  broken the issue down again. It printed one word for step 5:
  `sub-issues` means step 5 works the linked issue's ticket frontier, and
  `collapsed` means step 5 treats the breakdown as collapsed.
- **Exit 1**: it has none. Invoke the `orch-to-tickets` skill on the linked
  issue and follow its **Unattended breakdown**: it accepts its own draft
  and asks nothing. It publishes 2 or more tickets as sub-issues of the linked
  issue, or collapses 0 or 1 into the linked issue under its fixed
  `## Ticket` heading, and reports which: the published numbers, or
  `collapsed`. Step 5 follows that outcome. If publishing fails, stop
  before step 4's branch and relay its message.
- **Any other exit**: GitHub could not be read. Stop and say why.

## 4. Branch

Get the slug from `bash "$ORCH" slug "<short description>"` - the same
normalisation `orch.sh init` applies to a flow's slug, exposed as a primitive
rather than re-derived here - then `bash "$ORCH" branch off "quick/<issue>-<slug>"`.
`branch off` forks it off the base branch (`bash "$ORCH" base show`) the same way
a flow's own `branch create` does, but records no flow state - a quick
implementation keeps none. It records that base branch on the branch itself,
so the PR in step 7 targets it even if the setting changes meanwhile.

`branch off` exits 3, and only then, when this checkout holds a flow
mid-pipeline: a quick implementation must never move that flow's checkout off
its branch. **On exit 3, and on no other failure**, offer the human a side
checkout as a multiple-choice question: run this quick implementation in a
side checkout, a git worktree of its own beside the flow, or stop. On a yes,
go to **Starting in a side checkout** below. On a no, or on any other `branch
off` failure, relay the refusal and stop.

## 5. Implement

Build the linked issue's ticket frontier with the driver loop below. If step
3's breakdown is collapsed (no sub-issue published), no `ticket
next`/`ticket close` loop runs against the linked issue: the sequential path
dispatches exactly one subagent (below), for the linked issue itself as the
ticket.

**The driver loop** (ADR-0036). Its steps are lettered a-f, so that a "loop
step" never reads as one of this skill's numbered sections:

- **a. Entry check.** `bash "$ORCH" ticket-worktree list`. If it prints
  anything, stop and name each leftover ticket worktree: a dead run's
  state, never built over. A human clears each with `bash "$ORCH"
  ticket-worktree remove <n>`. This runs on every path, sequential
  included.
- **b. Pick the path.** Read the cap: `bash "$ORCH" parallel show`. Take the
  **sequential path** when the breakdown is collapsed, the cap is 1, or the
  host cannot start a background subagent (list that last one under the PR
  body's **Host fallbacks**, per `docs/host-capabilities.md`'s **Start a
  background subagent** row). It creates no ticket worktree, and every
  ticket commits to the one branch, one at a time, never in parallel.
  Collapsed, it dispatches the one subagent and goes to loop step f.
  Otherwise it loops: `bash "$ORCH" ticket next <linked issue>` - nothing
  ready means the frontier is exhausted, so go to loop step f - then
  dispatch a subagent (below) for the ticket, with no `Worktree:` line;
  record its report, then `bash "$ORCH" ticket close <n>` - only now that
  the report is back, never before - and go around again. Any other case
  takes the parallel path, loop steps c-e.
- **c. Fill the free slots.** Keep an in-flight set of tickets in this
  session. While fewer than the cap are in flight, take the next ticket
  `bash "$ORCH" ticket next <linked issue>` prints that is neither in
  flight nor queued to run alone: `bash "$ORCH" ticket-worktree add <n>`,
  then dispatch a subagent (below) for it in the background, its prompt
  carrying the `Worktree:` line with the path `ticket-worktree add`
  printed. Stop filling when `ticket next` has nothing more.
- **d. As each report returns**, record it, then `bash "$ORCH" ticket merge
  <n>`, then `bash "$ORCH" ticket close <n>`, then `bash "$ORCH"
  ticket-worktree remove <n>`, then refill (loop step c). A ticket is merged
  and closed whatever its `Verification` or `Criteria` line says, and is
  closed only after its merge succeeds. Any exit 1 from `ticket merge`,
  `ticket close` or `ticket-worktree remove`, a dispatch that fails, or a
  report that comes back malformed stops refilling: the tickets still in
  flight report and are processed as normal, then quick implementation
  stops, before the review and the PR, naming every failure. A leftover
  worktree surfaces at the next entry check and in `doctor`.
- **e. On a merge conflict** (`ticket merge` exits 3), resolve it, not
  rebuild it (ADR-0038), by **A driver's ticket resolution** in
  `agents/orch-resolver.md` (under the plugin root), the linked issue on
  the resolver's `Spec issue:` line. That section says how to resolve,
  what counts as a failed resolution, and its fallback to rebuilding the
  ticket alone. A resolution's **Merge resolutions** go under the PR
  body's **Merge resolutions** heading (section 7). When nothing is in
  flight, dispatch a ticket queued to run alone in a fresh worktree
  (`ticket-worktree add`) from the updated tip, on its own, and process its
  report as in loop step d before refilling. When the frontier and queue
  are exhausted and nothing is in flight, go to loop step f.
- **f. Verify the combined branch**, on every path, sequential included:
  run, on the quick implementation's branch, the full-verification command
  the reports' `Verification` lines name, once - joined with ` && ` into one
  line when they name different commands. Its command and `pass` or `fail`
  go under a **Verification** heading in the PR body (section 7). A failure
  does not stop the run: the review pass and the PR carry it.

Once loop step f has run, sync the branch with its base (**Base sync**
below), then continue at **6. Review**.

**Base sync**: bring the quick implementation's branch up to date with its
base, so the review pass reviews the merged code. Follow **A driver's base
sync** in `agents/orch-resolver.md` (under the plugin root), with the linked
issue as the resolver's issue. Its **Merge
resolutions** - the resolver's `Files`, `Dropped` and `Verification`
lines, or `None` when the sync merged cleanly - go under a **Merge
resolutions** heading in the PR body (section 7). A failed sync stops quick
implementation before the review and the PR, naming the failure; any merge
left in progress stays for the human. A resolver's `Verification` reading
`fail` does not stop it: the review pass and the PR carry it.

**Dispatching a subagent**: start the plugin's `orch-implementer` agent
exactly as the **Starting this agent** section of
`agents/orch-implementer.md` (under the plugin root) says, for the ticket
named above. On Claude Code it is the agent named
`orch-implementer` under the `orchestrator:` plugin scope, run in the
background on the parallel path. A host that cannot start it natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback; list it
under the PR body's **Host fallbacks**, along with any fallback that section
says the agent takes.

## 6. Review

Run a review pass: invoke the `orch-review` skill and follow its **Review
pass** section only, with the linked issue as its spec issue. It is one pass,
never that skill's multi-iteration loop. The loop's budget, severity triage and
filed findings are exactly what a quick implementation chooses to skip.

If the pass stops, stop before opening the PR. This skill promises a review
before the PR, so it never opens one with an axis unreviewed.

The pass's declines go under a **Review** heading in the PR body (step 7),
with `None declined.` when there are none. Any host fallback it takes goes
under the PR body's **Host fallbacks**.

## 7. Open the PR

Commit, and draft the body file described below. Then, before `pr publish`,
check the body file against what the branch actually changed, by the rule in
step 5 of `agents/orch-fixer.md` (under the plugin root): what to correct, how,
and when the check is done. The diff is `git diff <base SHA>..HEAD`, with the
base SHA from `bash "$ORCH" branch base-sha`. Only this differs: the check
reads and corrects the local body file, before `pr publish`, so there is no
`pr fetch` and no `pr update` - no live PR is edited - and nothing is
recorded about the check.

Then open the PR with `bash "$ORCH" pr publish <issue> "<title>"
<body-file>` - the same boundary `pr open` draws for a flow, kept out of
skill prose. The body carries a **Review** heading listing every finding
step 6 declined, with its location, claim and reason, or `None declined.`,
and a **Spec review decisions** heading listing every decision item step 2's
unattended spec review took for the human: each `decision (<n>)` line of
`changelog.md` in that review's working directory, or `None.` when it has
none. If `changelog.md` is missing, stop before `pr publish` and say so -
never write `None.` then, since the decisions taken are unknown. It
carries a **Verification** heading with step 5's combined verification: the
command it ran, then `pass` or `fail`, and a **Merge resolutions** heading
with step 5's base sync's and one bullet per ticket conflict loop step e
resolved, naming the ticket and holding its report's `Files`, `Dropped`
and `Verification` lines, or `None` when there were neither. It
ends with a **Host fallbacks** heading listing every fallback this run took -
including any the spec review in step 2 took - or `None (<host>).` It
pushes the branch and opens the PR against the base branch `branch off`
recorded, not as a draft. The body starts with `Closes #<issue>` when that
base branch is the default branch, and `Refs #<issue>` otherwise - the
issue closes when the release PR carries the work into the default branch
(the `orch-release` skill). Either way `pr publish` writes that line, so the
body file carries no closing keyword of its own. Not a draft because the
review pass in step 6 already happened, so there is no loop left to
promote it - draft would leave it stuck with nothing watching it.

## Starting in a side checkout

Reached from step 1 (`--side`, or the human asking) or from step 4 (a yes to
the offer on exit 3). It runs in this session, after step 1 has linked or
published the issue, with any glossary or ADR wording in its body. The issue
is the hand-off: no plan file is written.

1. Get the slug from `bash "$ORCH" slug "<short description>"`.
2. `bash "$ORCH" side-checkout add <slug>`. It first sweeps finished side
   checkouts and reports them; a failed sweep is reported and `add` carries
   on. Its last line of output is the side checkout's path. If `add` fails -
   a side checkout with that slug already exists under `checkouts/`, or the
   base branch cannot be fetched - relay its message and stop.
3. Print the one command that opens a session in the side checkout - `cd
   <path> && claude` on Claude Code, `cd <path> && junie` on Junie - and tell
   the human to run `/orchestrator:quick-implement <issue>` there, with the
   linked issue's number (on a host with no plugin commands, to ask for this
   skill on issue `<issue>`). This session's work is done: that session runs
   steps 1-7, finding the issue already linked.
