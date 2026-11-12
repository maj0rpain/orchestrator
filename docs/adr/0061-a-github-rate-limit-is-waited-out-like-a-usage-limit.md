# A GitHub rate limit is waited out like a usage limit

Amends ADR-0056 (a usage-limit stop is retried after its reset).

ADR-0056 retries a usage-limit stop and leaves every other failure to the
human. A GitHub API rate limit is, like a usage limit, a stop that needs no
decision, only time, yet it reached the human as a failure, usually as a
generic stale-claim failure, because the stop's own writes need GitHub too.

Decision: a GitHub API rate limit, recognised where `orch.sh`'s `gh` guard
sees it fail, is waited out as a limited issue. It shares the usage
limit's standing and its one counter of limit stops in a row, so the third
of either cause waits on the human. Its comment names the cause. It adds
no `orch:limited` label, because it can be written only after the reset
it would announce. Its pause stops the tick's own GitHub calls, not only
pickup.

## Considered Options

- **Share everything, the label and the pause's scope included.**
  Rejected: a pause that only blocks pickup lets the tick keep calling
  GitHub under the limit, and a label that lands after the wait is over
  announces nothing.
- **A separate standing: its own label, counter, marker and pause.**
  Rejected: it doubles the pickup rule and the stop paths for a response
  that is identical (wait for the reset, restart under ADR-0054), and lets
  alternating causes retry up to five times.
- **Detect it from the session log or the `rate_limit` endpoint at
  session end.** Rejected: a log scan matches test output and docs that
  mention rate limits, and the endpoint cannot see secondary limits.
