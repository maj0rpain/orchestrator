# Context

The vocabulary this repo uses to talk about itself. Glossary only: no
implementation details, no spec, no decisions. Decisions live in `docs/adr/`.

## Flow

One run of the pipeline, from an approved plan to a pull request. A flow is
identified by its slug and holds exactly one issue, one branch, and one PR. One
flow at a time per checkout. Its alternative, for changes that don't need the
pipeline, is a quick implementation.

## Quick implementation

The other route from an approved plan to a pull request, alongside a flow.
Chosen once, by a human, at the close of a grilling session - never assumed by
the model. Skips the plan/spec/implement/review pipeline entirely: no phases,
no handoff, no `.orchestrator/state.json`. Still produces its own branch and
PR, and is still held to this project's standards for how a change gets made -
test-driven, reviewed, then opened as a PR.

## Phase

One of the four stages a flow passes through: **plan**, **spec**, **implement**,
**review**. Each phase runs in its own session with no memory of the previous
one - with one deliberate exception: a review loop drives all of its iterations
from a single session (ADR-0001), so inside the review phase the unit of fresh
context is the loop, not the iteration. The spec review is a step of the spec
phase, not a phase of its own.

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
what is blocking, verify. Iterations are numbered from 1 and run on across a
flow's loops; a flow that has run none sits at 0. A loop runs as many as its
budget allows.

## Clean iteration

An iteration whose review found nothing blocking, so it fixed nothing and
committed nothing. A loop can finish only on a clean final iteration.

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

Which of three roles a finding plays. Only one of them is loop behaviour; the
other two are triage priorities on filed findings:

- **Blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. The only severity the loop fixes.
- **Major** - the change works but carries real cost: a documented standard
  breached, a smell with teeth, scope nobody asked for. Filed, never fixed by
  the loop.
- **Nit** - taste and judgement calls. Filed, never fixed by the loop.

## Filed finding

A major or nit turned into an issue when a loop terminates, carrying the
reviewer's finding and the loop's reasoning about it, deduplicated across
iterations and across a flow's loops. A filed finding enters triage against the
whole codebase rather than against one diff. Findings the loop demoted on a
human's earlier decision are reported, never filed.

## Review record

The written account of one iteration: what was found, at what severity, what was
done about it, which issues were filed, and what CI said. A record is a record -
it is read by humans after the fact, not by the loop to decide anything.

## Terminal state

One of the two ways a review loop can end: the PR marked ready, or a bounded
stop.

## Bounded stop

The terminal state of a loop that ended without the change being ready - because
its final iteration fixed something nothing has reviewed, or because CI could
not be called green. A stop is not a failed change and not a successful one.

## Flake rerun

The one permitted re-run of a failing CI check on the theory that it failed for
reasons unrelated to the change. The allowance belongs to the flow, not to the
iteration: one per flow, spent or not.

## Required check

A CI check that must pass before a change can land. Where branch protection
names them, those are the required checks; where it does not, every check on the
commit counts. A change with no checks at all is not thereby failing.
