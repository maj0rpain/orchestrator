# Context

The vocabulary this repo uses to talk about itself. Glossary only: no
implementation details, no spec, no decisions. Decisions live in `docs/adr/`.

## Flow

One run of the pipeline, from an approved plan to a pull request. A flow is
identified by its slug and holds exactly one issue, one branch, and one PR. One
flow at a time per checkout - except a flow at phase `done`, which doesn't
count against that limit: it no longer blocks a new one, which archives it
automatically rather than requiring it be cleared by hand. Its alternative,
for changes that don't need the pipeline, is a quick implementation.

## Base branch

The branch a flow or quick implementation forks from and opens its PR
against. The repo's default branch unless a human has set another for the
checkout - an integration branch such as `uat`, or a long-running feature
branch that several tickets feed. A flow fixes its base branch when it starts,
so changing the setting mid-flow never moves that flow's PR; a quick
implementation reads it when it branches. A flow's base SHA is the base
branch's tip at the moment it branched.
_Avoid_: target branch, integration branch (as the general term).

## Release PR

The PR that carries a base branch other than the default back into the
default branch, closing every still-open issue whose work reached the base
branch. Those issues stay open until it merges: a PR into a non-default base
branch refers to its issue rather than closing it, because the work has not
landed yet. Which issues it closes is read from what merged into the base
branch, never remembered by a human.

## Quick implementation

The other route from an approved plan to a pull request, alongside a flow.
Chosen once, by a human, at the close of a grilling session - never assumed by
the model. Skips the plan/spec/implement/review pipeline entirely: no phases,
no handoff, no `.orchestrator/state.json`. Still produces its own branch and
PR, and is still held to this project's standards for how a change gets made -
test-driven, reviewed, then opened as a PR.

## Doctor

A diagnostic surface a maintainer or agent can run at any time, via the
`doctor` command, to check that the machine, the repo, and the active flow are
sound. Organized into named scopes - `--env`, `--flow` - with bare `doctor`
covering everything. Every check it runs reports through one of three states -
`ok`, `warn`, or `FAIL` - and the overall report reflects the worst state seen
without aborting partway through.

## Ticket breakdown

The set of sub-issues `to-tickets` publishes against a flow's spec issue, or
against quick implementation's linked issue - each one a sub-issue of that
parent, not a second issue the flow or quick implementation now holds, and
may block, or be blocked by, other tickets in the same breakdown. When the
approved breakdown resolves to 0 or 1 tickets, no sub-issue is published at
all: the drafted ticket's content, if there is one, is folded into the
parent issue's own body instead, and the parent is worked directly as if it
were the sole ticket - a breakdown of one, collapsed onto its own parent
rather than split out beneath it.

## Ticket subagent

The fresh, non-fork agent that builds exactly one ticket of a ticket
breakdown and reports back structurally instead of blocking on a human, in
the implement phase or in quick implementation.

## Phase

One of the four stages a flow passes through: **plan**, **spec**, **implement**,
**review**. Each phase runs in its own session with no memory of the previous
one - with one deliberate exception: a review loop drives all of its iterations
from a single session (ADR-0001), so inside the review phase the unit of fresh
context is the loop, not the iteration. The loop is the unit of fresh context
for its driver; the reviewers and the fixer get fresh context every iteration.
The spec review is a step of the spec phase, not a phase of its own.

Note the tense: the recorded phase names the stage that runs **next**, not the
one that just finished.

## Handoff

The written record one phase leaves for the next, and the only thing that
crosses a phase boundary. A handoff references artefacts that already exist (an
issue, a PR, a diff) and states what exists nowhere else: reasoning, rejected
options, deviations.

## Review loop

One run of the review phase in one session: a budget of iterations, every one a
fresh review of the whole change from the base SHA, ending in a terminal state.
The session that runs it is the loop's driver: it starts the reviewers, triages
what they report, and decides the terminal state, but never edits the change
itself - that is the fixer's work, and filing is the closer's.
A flow runs a loop each time it enters the review phase; a flow's loops share
one iteration numbering, and only a human decides that a further loop happens.
That further-loop decision is re-entry, not Redo: re-entry reviews the same
accepted change for more looks, Redo disowns it.

## Redo

A deliberate step back to re-run a phase whose output was wrong - never the
review loop's own re-entry, which reruns the *same* accepted change for more
looks. `state.phase` names the phase that runs next, so redoing the phase that
just finished means stepping back one first: `spec -> implement -> review ->
done`, in reverse.

Redoing back to `implement` is only available once the review loop has reached
a terminal state, never mid-budget - re-entry already covers "give this change
more looks," so Redo only has a distinct meaning once the loop is done deciding
that on its own. Redoing back to `spec` re-reviews the flow's existing issue by
default, rather than publishing a second one.

## Budget

The number of iterations a review loop runs, chosen by a human when the loop
starts - five unless they say otherwise. A loop runs its whole budget: finding
nothing does not end it early, because every iteration is an independent look
at the same change, and the value of the loop is in the number of looks.

## Iteration

One pass within a review loop: review the change, triage what came back, fix
what the loop fixes, verify. Iterations are numbered from 1 and run on across a
flow's loops; a flow that has run none sits at 0. A loop runs as many as its
budget allows.

## Clean iteration

An iteration that fixed nothing and committed nothing. A loop can finish only
on a clean final iteration - and since a final iteration fixes only what is
blocking, that means one whose review found nothing blocking.

## Fixer

A fresh agent a review loop's driver starts within an iteration, and only when
triage left something the loop fixes. It fixes, verifies, commits, writes the
iteration's review record, and ends with the iteration: one fixer never sees
another iteration's work except through the records.

## Closer

A fresh agent a review loop's driver starts once, at termination, to turn the
loop's unfixed findings into filed findings and tell the PR what the loop did.

## Adopted issue

An issue given to a flow at init, instead of one `to-spec` publishes during
the spec phase. Checked once, at init, for existing, open, and carrying the
`ready-for-agent` triage label; the spec phase then skips `to-spec` entirely
and runs the spec review straight against it.
_Avoid_: existing issue, pre-existing issue, given issue.

## Spec review

One look at a spec, taken once in the spec phase after the issue exists -
published by `to-spec` or already adopted at init - and before its handoff is
written. Four lenses read the spec independently; every finding they report
is put to a human with a proposed edit, and only the edits the human accepts
change the spec. A spec review runs once - it is not a loop and has no
budget.

## Lens

One of the four angles a spec review takes, each answering one question of the
spec and nothing else:

- **Fidelity** - does the spec say what the plan decided? Read against the
  plan's decisions, rejected alternatives, and constraints.
- **Consistency** - does the spec agree with itself, with the glossary, and
  with the recorded decisions?
- **Testability** - can every story and decision be proven at the agreed
  seams?
- **Implementability** - could a fresh session build it from the spec alone,
  and does the codebase allow what it asks?

Findings stay with the lens that reported them and are never ranked across
lenses.

## Seam

The public boundary a test observes behaviour at. Seams are agreed with a human
in the spec phase, recorded in the spec and its handoff, and that agreement is
the only one: the implement phase tests at the seams it is given and does not
re-ask. A seam the code turns out not to allow is a deviation, recorded like
any other.

## Finding

One problem a review reports - about the change, from the review phase, or
about the spec, from a spec review. Only a finding about the change carries a
**severity**, which the review phase assigns; the reviewer itself reports
findings unranked. A finding about the spec carries no severity: a human
accepts or declines the edit it proposes, and it is never filed.

## Severity

Which of three roles a finding plays - how wrong the change is, and so which
findings the loop may fix without asking anyone:

- **Blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. Always fixed, in every iteration - or,
  when the fixer cannot, left open, holding the change out of ready.
- **Major** - the change works but carries real cost: a documented standard
  breached, a smell with teeth, scope nobody asked for. Fixed by the loop
  unless the fix needs a decision, changes behaviour, or would touch the
  loop's own fixes; filed otherwise.
- **Nit** - taste and judgement calls. Fixed by the loop only when it is a
  mechanical nit; filed otherwise.

A final iteration fixes only what is blocking: a major or nit found there is
filed, so a working change is never held in draft by a style finding.

## Mechanical nit

A nit with exactly one correct fix, confined to the lines it names, changing
no behaviour and leaving no wording or taste to choose - a typo, an unused
import, a comment naming the wrong function, a broken link. Rewording prose is
never mechanical, however small.

## Loop-authored lines

Lines the current review loop's own fix commits wrote. A major or nit on them
is filed, never fixed; a blocking finding on them is still fixed. A previous
loop's fixes are not loop-authored for the next one.

## Filed finding

A major or nit the loop did not fix, turned into an issue when a loop
terminates - because its fix needed a decision, would have changed behaviour,
was not mechanical, landed on loop-authored lines, was found in a final
iteration, or the fixer could not fix it. It carries the reviewer's finding
and the loop's reasoning about it, including which of those kept it out of the
loop, deduplicated across
iterations and across a flow's loops. A filed finding enters triage against
the whole codebase rather than against one diff: a later loop that meets it
again leaves it alone, and tells the human it did. Findings the loop demoted on
a human's earlier decision are reported, never filed.

## Review record

The written account of one iteration: what was found, at what severity, what was
done about it, which issues were filed, and what CI said. Humans read it after
the fact; later iterations and loops read it for what earlier ones fixed and
filed, since no fixer or closer remembers anything the records do not say.

## Terminal state

One of the two ways a review loop can end: the PR marked ready, or a bounded
stop.

## Bounded stop

The terminal state of a loop that ended without the change being ready - because
its final iteration fixed something nothing has reviewed, left a blocking
finding its fixer could not fix, or lacked one of its two looks, or because CI
could not be called green. A stop is not a failed change and not a successful one.

## Flake rerun

The one permitted re-run of a failing CI check on the theory that it failed for
reasons unrelated to the change. The allowance belongs to the flow, not to the
iteration: one per flow, spent or not.

## Required check

A CI check that must pass before a change can land. Where branch protection
names them, those are the required checks; where it does not, every check on the
commit counts. A change with no checks at all is not thereby failing.

## Host

The agent CLI that has the plugin installed and runs its skills - Claude Code,
Junie, and so on. Claude Code is the reference host; every other host is
supported to the extent it can do what the plugin asks, and anything it
cannot do is reported rather than silently skipped.

## Capability

Something a skill needs its host to do - invoke a skill, start a fresh
subagent, start a fresh session - named for what it does rather than for any
host's tool. `docs/host-capabilities.md` says how each host provides each one.

## Host fallback

What a skill does instead when its host lacks a capability, as documented in
`docs/host-capabilities.md`. Every fallback a phase takes is recorded under
**Host fallbacks** in its handoff, so a reduced run is never mistaken for a
full one.

## Planning allowlist

The files a planning session may legitimately change: the glossary, ADRs,
agent docs, and scratch and flow-state files. Anything outside it is source,
which planning never touches. The edit guard denies edits outside it while
planning, where the host can arm the guard. A flow will not start while the
working tree has changes outside it (ADR-0013).
