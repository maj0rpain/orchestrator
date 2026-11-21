# The suite budget is removed

Supersedes in part ADR-0063, ADR-0066 and ADR-0067: their suite-budget lines.

`scripts/test/suite-budget` capped the durations file's CPU total, and
docs_lint failed a change whose total was over it and above its base's (#3180).
By 2026-11-21 `main` itself was over (1165.8 of 1160), so every change that
re-recorded a section failed whatever it cost (#3956). The verification noun's
conversion (#3939) moved test helpers into `autopilot.sh`'s preamble, which made
all of that file's sections stale. Re-recording them raised the total by 5.2
CPU s, though timing the same sections at the base and the head on one idle
machine found them within a few percent of each other: the rise was older drift
coming to light, not cost the change added. ADR-0067 already removes the
budget, the durations file and the bash job pool once the last bash section
goes, and the bash test tree is not expected to grow before then.

Decision: the suite budget is removed now - the budget file, docs_lint's
total rule and budget-alone rule, `DOCS_LINT_BASE`, which existed only to hand
those rules a base, and the budget on `section-durations.sh --stale`'s last
line. The durations file and its freshness rule stay: `orch_test.sh` starts its
sections longest first from it.

Trade-off accepted: a change that makes the bash suite slower is caught by
review alone until the bash suite is gone, as the pytest suite's growth already
was.

## Considered Options

- **Raise the budget in a change of its own.** Rejected: the next change that
  makes a whole file's sections stale meets the same drift, and the budget goes
  with the bash suite anyway.
- **Make the costliest autopilot sections cheaper.** Rejected: those sections
  are deleted when the autopilot noun converts.
- **Disable the total rule and keep the budget file.** Rejected: it leaves a
  number nothing enforces, and docs that describe it.
