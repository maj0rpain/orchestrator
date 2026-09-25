# The review loop fixes blocking only and files the rest

Superseded in part by ADR-0016: the loop now also fixes majors and
mechanical nits that need no decision. The full budget and the case for
repeated independent looks below still stand.

A review loop runs a fixed budget of iterations, each a fresh review of the
whole change from the base SHA. It fixes blocking findings inside the iteration
that found them. Every major and nit becomes a GitHub issue when the loop
terminates, with the reviewer's finding and the loop's reasoning in the body,
and is triaged later against the whole codebase. Nothing found ends a loop
early; only spending the budget does.

The design it replaces fixed majors as well as blocking findings and closed only
on an iteration whose review came back with nothing to fix. Ten iterations
across two loops on #8 showed why that cannot converge on a prose-heavy change:
every fix is new diff, new diff draws findings, and prose findings - whether a
comment is still accurate, whether two documents word a rule the same way - have
no pass/fail and are generated indefinitely by independent reviewers. Three of
loop 2's findings were against its own fixes. Meanwhile the executable part
converged by iteration 3, and the severity scale had three levels of which two
behaved identically.

The same data argues *for* iterating, but for a different reason than the old
design assumed. The value is not re-reviewing fixes; it is repeated independent
sampling of the same change. Loop 2's fifth iteration found a fail-open in
`ci_probe` that was in the original implementation, not in any fix - it took
five looks before a reviewer read that line. So the budget runs in full, and a
clean iteration is cheap enough now that buying the extra looks is worth more
than saving them.

## Consequences

The multi-loop apparatus goes: the `04-review.md` handoff, `review loop-next`,
the `loop` state key, per-loop record directories, and the closing nit question.
A flow can still enter the review phase more than once - after a bounded stop a
human may ask for more iterations - but each entry is a fresh loop with its own
budget, sharing one iteration numbering, and it re-reads `03-implement.md`
rather than anything a previous loop wrote.

A PR can be marked ready with majors open against it. That is the intended
outcome: a major means the change works, and the issue it became carries the
reasoning so triage can decide against the whole codebase whether it is worth
fixing at all. The bounded stop shrinks to two ways in - an unreviewed final fix,
or CI - and the last iteration's fixes are still never marked ready unreviewed.

The filing has to carry the reasoning. `.orchestrator/` is git-excluded and
eventually archived, so a filed finding stripped to one line would be worthless
weeks later; the issue body is the record, not a link to one.
