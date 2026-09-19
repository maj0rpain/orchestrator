# A done flow is archived by the next `init`, not on its own

A flow at phase `done` blocked `init` exactly like one mid-pipeline, forcing
every finished flow to be archived by hand before the next could start - the
third time this happened, it was clearly a step of the pipeline rather than an
exception. `init` now archives a `done` flow itself and proceeds, rather than
archiving the moment `review ready` sets the phase, or adding a separate
`/orchestrator:finish` command.

## Consequences

`init` validates any `--issue N` adoption *before* archiving, so a bad
adoption leaves the finished flow untouched and re-runnable. `init`'s
refusal for a flow still mid-pipeline (`spec`/`implement`/`review`) is
unchanged, wording included - a `done` flow simply never reaches that branch
anymore. `doctor --flow` no longer treats a `done` flow's now-closed issue
(closed by the PR's `Closes #<issue>` on merge) as a failure.

## Rejected alternatives

- **Archive immediately when `review ready` runs.** Closes the flow at the
  moment it succeeds, but loses `status` showing "done, PR #N ready"
  afterwards - a human checking what just happened would find nothing live.
- **A separate `/orchestrator:finish` command.** Explicit, but one more
  command to remember; forgetting it reproduces the original problem.

`done` staying visible until the next flow needs the slot, with no new
command to remember, won out over both.
