# Context

The vocabulary this repo uses to talk about itself. Glossary only: no
implementation details, no spec, no decisions. Decisions live in `docs/adr/`.

## Flow

One run of the pipeline, from an approved plan to a pull request. A flow is
identified by its slug and holds exactly one issue, one branch, and one PR. One
flow at a time per checkout.

## Phase

One of the four stages a flow passes through: **plan**, **spec**, **implement**,
**review**. Each phase runs in its own session with no memory of the previous
one.

Note the tense: the recorded phase names the stage that runs **next**, not the
one that just finished.

## Handoff

The written record one phase leaves for the next, and the only thing that
crosses a phase boundary. A handoff references artefacts that already exist (an
issue, a PR, a diff) and states what exists nowhere else: reasoning, rejected
options, deviations.

## Review loop

One bounded sequence of iterations, ending either when an iteration's review
comes back with nothing blocking or major to fix, or when it exhausts its bound. A flow may run more than one: a loop that
finishes can hand off to a fresh loop, which starts with a new session and its
own bound. Only a human decides that a further loop happens.

## Iteration

One pass within a review loop: review the change, triage what came back, fix,
verify. Iterations are numbered from 1; a loop that has run none sits at 0. A
loop is bounded to five.

## Finding

One problem a review reports about the change. A finding carries a **severity**,
which the review phase assigns — the reviewer itself reports findings unranked.

## Severity

Which of three roles a finding plays in whether the flow can finish:

- **Blocking** — the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test. The
  flow cannot finish while one is open.
- **Major** — the change works but carries real cost: a documented standard
  breached, a smell with teeth, behaviour nobody asked for. Fixed, but does not
  by itself keep the flow from finishing.
- **Nit** — taste and judgement calls. Recorded and never blocking, and never
  fixed inside the loop.

## Review record

The written account of one iteration: what was found, at what severity, what was
done about it, and what CI said. A record is a record — it is read by humans
after the fact, not by the loop to decide anything.

## Flake rerun

The one permitted re-run of a failing CI check on the theory that it failed for
reasons unrelated to the change. The budget belongs to the flow, not to the
iteration: one per flow, spent or not.

## Required check

A CI check that must pass before a change can land. Where branch protection
names them, those are the required checks; where it does not, every check on the
commit counts. A change with no checks at all is not thereby failing.
