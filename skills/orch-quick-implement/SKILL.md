---
name: orch-quick-implement
description: Implement a small, already-understood change directly and hands-off, skipping the plan/spec/implement/review pipeline. Reached when a human picks "quick implementation" at hook-grilling.sh's closing question, runs /orchestrator:quick-implement [<issue>], or is invoked directly for work that plainly does not need the full flow. Still requires a linked issue - rewritten from the plan, unattended, when it is the interviewed issue and the plan changed it - an unattended spec review, a published ticket breakdown, test-driven implementation, and a review pass before the PR opens.
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
Resolve it in this order, taking the first that holds:

1. An issue named in the arguments - `/orchestrator:quick-implement <issue>`,
   its leading issue number, never a flag such as `--side` - is the linked
   issue: use it, and publish none.
2. Otherwise, the side checkout's recorded issue: `bash "$ORCH" side-checkout
   issue` prints it and exits 0 when this checkout is a side checkout made
   for a quick implementation. Use it, and publish none. Any other exit means
   there is none: go on.
3. Otherwise, a linked issue already named earlier in this conversation, or
   on an already-checked-out branch: use it.
4. Otherwise, publish one now with `bash "$ORCH" issue publish "<title>"
   <body-file>`, from the shared understanding just reached. It applies the
   `ready-for-agent` triage role's label and reads the title and label back
   before it reports success - never an ad hoc `gh` call.

When an issue is named in the arguments, still run `side-checkout issue`:
if it records a different issue, the argument wins, and your reply to the
human carries a one-line note naming both - the argument's issue used, the
recorded one set aside. No file or PR body carries that note.

- Whichever issue is linked, a glossary or ADR change (`GLOSSARY.md`, `GLOSSARY-MAP.md`,
  `docs/adr/`) the planning session decided goes into the linked issue's body
  word for word - the new or replaced text, naming the file and entry - never
  into those files during planning. It lands with the change it describes
  (ADR-0022). The standalone spec review in step 2 runs no Fidelity lens, so
  nothing else checks the wording survived.
- If none of the four yields an issue - `issue publish` fails too - stop
  and say why. A quick implementation
  with no issue behind it is exactly the unaccountable path this skill exists
  to avoid.

Once the issue is linked, rewrite it from the plan when both of these hold,
and ask nothing (ADR-0034):

- (a) the linked issue is this conversation's **interviewed issue** - the
  open issue the planning session was about, or the one the human named in
  its place at the close - however it was linked, arguments included; and
- (b) comparing its body with the plan shows the plan changed its scope or
  substance, glossary or ADR wording the planning decided included. Judge
  this yourself, unattended.

The rewrite is the `orch-to-spec` skill's rewrite mode on the linked issue,
in its **Unattended rewrite** form, followed through to its end. That mode is
the one definition of what the rewrite does unattended, and this step
restates none of it. Remember the breakdown outcome word it reports, and on
`kept` its edited-ticket count, for step 7's **Issue rewrite** line. If it stops, quick implementation stops too: relay
its message, and make no side checkout and go on to no step 2.

Otherwise, review the issue as it stands, with no rewrite, and remember why
for step 7. These are the no-rewrite cases:

- there was no interview in this conversation;
- the issue is a side checkout's recorded issue, whose session has no
  interview;
- the issue was published fresh in option 4, so it is already written from
  the plan;
- the body already reflects the plan - a blueprint its own route just
  rewrote, say, or an issue the interview only confirmed.

With `--side` in the arguments, or when the human asked in words for a side
checkout, stop here once the issue is linked, and any rewrite is done, then
go to **Starting in a side checkout** below: the side checkout's own session
runs steps 1-7, its step 1 finding the issue already linked.

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
  Skip the breakdown and ask nothing: step 1's rewrite may already have
  reconciled the breakdown with the rewritten body, and step 2's spec review
  with the edits it applied, or the review retired it and broke the issue
  down again. A rewrite that retired the breakdown leaves none, so this
  check exits 1. It printed one word for step 5:
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

Build the linked issue's ticket frontier with the driver loop in
`docs/driver-loop.md` (under the plugin root): loop steps a-f and its
**Dispatching a subagent**, bound here as:

- **the issue**: the linked issue;
- **the branch**: the quick implementation's branch;
- **the record**: the PR body's **Host fallbacks**, **Merge resolutions** and
  **Verification** headings (step 7);
- **the judge**: the review pass and the PR;
- **the stop**: quick implementation stops, before the review and the PR,
  naming every failure;
- **after loop step f**: **Base sync** below, then **6. Review**.

The breakdown is collapsed when step 3 found or made no sub-issue - `ticket
exists` printed `collapsed`, or `orch-to-tickets` reported `collapsed`: no
`ticket next`/`ticket close` loop runs against the linked issue, and the
sequential path dispatches exactly one subagent, for the linked issue itself
as the ticket.

**Base sync**: bring the quick implementation's branch up to date with its
base, so the review pass reviews the merged code. Follow **A driver's base
sync** in `agents/orch-resolver.md` (under the plugin root), with the linked
issue as the resolver's issue. Its **Merge resolutions** go under a **Merge
resolutions** heading in the PR body (section 7). A failed sync stops quick
implementation before the review and the PR, naming the failure; any merge
left in progress stays for the human. A resolver's `Verification` reading
`fail` does not stop it: the review pass and the PR carry it.

## 6. Review

Run a review pass: invoke the `orch-review` skill and follow its **Review
pass** section only, with the linked issue as its spec issue. It is one pass,
never that skill's multi-iteration loop. The loop's budget, severity triage and
filed findings are exactly what a quick implementation chooses to skip.

If the pass stops, stop before opening the PR. This skill promises a review
before the PR, so it never opens one with an axis unreviewed.

The pass's declines go under a **Review** heading in the PR body (step 7),
with `None declined.` when there are none. Its spec questions go under a
**Spec questions** heading in the PR body: this run is unattended, so it
never settles one by picking a behaviour, and never declines one - the PR
opens as a draft instead (step 7). Any host fallback it takes goes under the
PR body's **Host fallbacks**.

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
carries an **Issue rewrite** heading, always present and separate from
**Spec review decisions**, holding one line that says what this run did
in step 1: `Rewrote #<n> from the plan (breakdown: <word>)`, with `<word>`
the outcome word the rewrite reported, as defined in `orch-to-spec`'s
**Rewrite the issue** step 5 - except when the word is `kept` and the
edited-ticket count is above 0, when it is `Rewrote #<n> from the plan
(breakdown: kept, <k> tickets edited)`, with `<k>` the count. A `kept` with
no count reported reads as a count of 0. Or the line is `As it
stands: <reason>`, such as `As it stands: no interview in this
conversation` or `As it stands: the interview only confirmed the issue`.
In a side checkout's session the line is `As it stands: a side checkout's
recorded issue; any rewrite ran in the session that made the side
checkout`. It
carries a **Verification** heading with step 5's combined verification: the
command it ran, then `pass` or `fail`, and a **Merge resolutions** heading
with step 5's base sync's and loop step e's ticket resolutions, per
**Merge resolutions** in `agents/orch-resolver.md` (under the plugin
root). It carries a **Spec questions** heading, always present and separate
from **Review**: each spec question step 6's pass recorded, one line each as
the pass records it, or `None.` when it recorded none. It
ends with a **Host fallbacks** heading listing every fallback this run took -
including any the spec review in step 2 took - or `None (<host>).` It
pushes the branch and opens the PR against the base branch `branch off`
recorded. With one or more spec questions, append `--draft`:
`bash "$ORCH" pr publish <issue> "<title>" <body-file> --draft` opens the
PR as a draft. Without any, it opens without the flag, not a draft. A failed `pr
publish`, with `--draft` or without, stops this skill, relaying its reason;
one with `--draft` is never retried without it. The body starts with `Closes #<issue>` when that
base branch is the default branch, and `Refs #<issue>` otherwise - the
issue closes when the release PR carries the work into the default branch
(the `orch-release` skill). Either way `pr publish` writes that line, so the
body file carries no closing keyword of its own. Without a spec question it
is not a draft, because the review pass in step 6 already happened, so there
is no loop left to promote it - a draft would leave it stuck with nothing
watching it. With one, the draft waits on a human's ruling, not on a loop:
the human resumes with a standalone review pass (`/orchestrator:review-pass
<issue>`), which asks the questions and marks the PR ready once every one is
ruled. See
`docs/adr/0043-a-spec-question-met-in-a-review-pass-reaches-a-human-before-the-pr-is-ready.md`.

## Starting in a side checkout

Reached from step 1 (`--side`, or the human asking) or from step 4 (a yes to
the offer on exit 3). It runs in this session, after step 1 has linked or
published the issue, with any glossary or ADR wording in its body. The issue
is the hand-off: no plan file is written. Before the hand-off, on either
route, print step 1's rewrite outcome - the rewrite and its breakdown
outcome, or the reason there was none - since the side checkout's session
records only that any rewrite ran here.

1. Get the slug from `bash "$ORCH" slug "<short description>"`.
2. `bash "$ORCH" side-checkout add <slug> --issue <issue>`, with the linked
   issue's number: the side checkout records it, so the session opened there
   picks it up (step 1). It first sweeps finished side
   checkouts and reports them; a failed sweep is reported and `add` carries
   on. Its last line of output is the side checkout's path. If `add` fails -
   a side checkout with that slug already exists under `checkouts/`, or the
   base branch cannot be fetched - relay its message and stop.
3. Print the one command that opens a session in the side checkout. On
   Claude Code it is `cd <path> && claude "/orchestrator:quick-implement
   <issue>"`, with the linked issue's number: the session opens with the
   command already typed. On Junie it is `cd <path> && junie`: tell the human
   to run `/orchestrator:quick-implement` there, no number needed, since the
   side checkout records the issue (on a host with no plugin commands, to ask
   for this skill). This session's work is done: that session runs steps
   1-7, finding the issue already linked.
