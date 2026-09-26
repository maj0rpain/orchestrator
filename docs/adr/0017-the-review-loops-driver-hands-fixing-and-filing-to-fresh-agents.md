# The review loop's driver hands fixing and filing to fresh agents

Superseded in part by ADR-0020: the closer now reads only this loop's
records, and the driver's triage alone decides what is already filed.

Supersedes the argument in ADR-0001's body that the driving session's
bookkeeping must stay in its context. ADR-0001's claim of one driving session
per loop stands.

The session that drives a review loop is now its **driver**: it starts every
agent, triages the reviewers' reports, waits on CI, spends the flake rerun,
and decides the terminal state. It never edits the change, except on a host
with no fresh subagent: there it takes the host-capabilities fallback, does the
fixer's and the closer's work in its own session, and records that as a host
fallback. When triage leaves something the loop fixes, it starts a fresh
`orch-fixer`, which fixes, verifies, commits, pushes, writes the iteration's
review record, and returns about five lines. At termination it starts a fresh `orch-closer`, which files
the unfixed majors and nits across the flow's records, posts the one PR
comment, and returns the issue numbers. A clean iteration starts no fixer; the
driver writes its record itself.

Keeping the bookkeeping in one context made that context the problem. A
measured budget-4 loop peaked at 134k tokens against a 120k target: each
iteration added 11-15k even when it fixed nothing, and a fix iteration added
file reads, edits, the `tdd` skill, and test output on top. A budget-5 loop
with a fix in it could not stay under the target. Handing the fix turns and
the filing to fresh agents leaves the driver a few thousand tokens per
iteration. The bookkeeping ADR-0001 kept in context now lives in the records,
which is where the fixer and closer read it from.

The fixer is fresh every iteration, so it builds no story about its own
earlier fixes, and it never asks a human anything: what it cannot fix goes in
the record. A major or nit it could not fix is filed. A blocking finding it
could not fix, including a failing verification command, becomes **open
blocking**: never filed, carried into the next iteration's triage, and a bar
to **Ready** while it remains in the final record. So is a **missing look** in
the final iteration - a reviewer whose report failed twice: a final iteration
with one axis unreviewed cannot vouch that the change is clean.

## Considered Options

- **Trim in place** - keep one session doing the work, with reports in files
  and the spec by reference. Rejected: an estimated 30-40% saving per
  iteration, not enough once iterations fix things.
- **One session per iteration**, reversing ADR-0001. Rejected: it brings back
  the human babysitting every iteration that ADR-0001 was written to avoid.
- **A fixer that runs every iteration and also triages.** Rejected: it pays
  sub-agent startup (~32k, mostly cache reads) even on clean iterations, and
  splits the triage from the session that owns the terminal decision.
- **One fixer kept alive for the whole loop.** Rejected: its own context grows
  every iteration, so the bloat moves one level down, along with the story
  about its own fixes that fresh agents exist to prevent.
