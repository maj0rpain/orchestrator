# The plugin measures no suite cost

Superseded in part by ADR-0065: sessions run their verification through
`verification run`, not bare; the rest of this ADR stands.

`orch.sh suite-cost` recorded the CPU time of each passing verification run, and
`suite-cost check` compared a change's head with its base commit once per
review-loop iteration and once per review pass, raising a major past 15% growth.
To compare, it ran the whole suite on any base commit with no record, and twice
more to confirm a growth. In the autopilot container on 2026-11-12 to 2026-11-14
it gave 504 verdicts: 380 `unmeasured`, 124 `ok`, none `grew`, for about 44
extra whole-suite runs (#3179). The same commit measured from 1076 to 1320
CPU-seconds on one machine, a spread wider than the threshold, and a suite that
grows a fraction of a percent per change passes a per-change check every time
(#3180). Meanwhile the suite's cost about doubled.

Decision: the `suite-cost` noun - `run`, `check`, `history`, its record, verdict
file and active-run markers - is removed, and so are the review loop's and
review pass's suite-cost check, the closer's `suite-cost` axis and `review file
--axis suite-cost`. Agents run their verification command bare. Suite growth is
held by this repo's suite budget (#3180), not by the plugin.

Trade-off accepted: a repo using the plugin gets no per-change warning that its
suite grew, and the test audit has no recorded trend until a ledger replaces it.

## Considered Options

- **An opt-in config key, off by default.** Rejected: keeps about 2,500 lines of
  code and tests, and the queue planned to make it measure under load (#3178),
  for a check whose noise exceeds its threshold.
- **Skip the check only where a repo names a branch verification (#3179).**
  Rejected: every other repo keeps paying the base runs for no signal.
- **Measure the head in the review loop.** Rejected: one or two more whole-suite
  runs per flow, for the same blind spot to slow growth.
