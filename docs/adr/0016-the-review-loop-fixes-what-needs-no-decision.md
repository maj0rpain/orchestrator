# The review loop fixes what needs no decision

Supersedes ADR-0003 in part: its full budget and its case for repeated
independent looks stand; its "blocking only" rule does not.

A review loop fixes every blocking finding, as before. It now also fixes a
major unless the fix needs a choice between alternatives the plan, spec, and
deviations did not settle, or would change behaviour - a major means the
change works, so a fix that changes behaviour was never a major fix. It fixes
a nit only when the nit is mechanical: exactly one correct fix, confined to
the lines it names, no behaviour change, no wording or taste to choose.
Rewording prose is never mechanical. Everything else is filed at termination,
as before.

Filing everything but blocking left PRs marked ready with a queue of cheap,
uncontroversial issues behind them - an unused import or a breached standard
with one obvious remedy costs more to triage later than to fix now.

ADR-0003's objection still holds, so two guards keep it from recurring. The #8
churn came from fixes drawing findings drawing fixes, three of loop 2's
findings being against its own fixes. So a major or nit on lines the current
loop's own fix commits wrote is filed, never fixed; a blocking finding there is
still fixed. And prose findings, which no reviewer ever stops generating, are
kept out of the fixable set by the mechanical-nit rule.

The final iteration fixes only what is blocking and files its majors and nits.
A fix in the final iteration still forces a bounded stop, since nothing
reviews it; letting a style finding force that stop would hold a working
change in draft over something that does not make it wrong.

## Considered Options

- **Fix every major, whatever it takes.** Rejected: some majors have several
  reasonable remedies, and a loop picking between designs mid-run is a decision
  this pipeline sends to a human everywhere else.
- **Cap fixes per location instead of excluding loop-authored lines.**
  Rejected: the exclusion targets the exact pattern #8 recorded and is
  mechanically checkable against the fix commits.
- **Treat every earlier loop's fixes as loop-authored too.** Rejected: a human
  re-entering review is asking for better code, earlier fixes included. The
  exclusion is per loop.
- **Fix, on re-entry, a finding a previous loop already filed, and close its
  issue.** Rejected: once filed it belongs to triage. The loop leaves it alone
  and tells the human it met it again, so they can triage it.

## Consequences

The **Clean iteration** that ready requires still means a final iteration that
fixed nothing - which, since a final iteration fixes only blocking, is one that
found nothing blocking. Earlier iterations now commit more often.

A major fix does not go through `tdd`; the verification command must still
pass. The filed issue's "why not fixed" line now names which rule kept it out
of the loop. `review file` still files only majors and nits.
