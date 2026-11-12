# Quick autopilot plans unattended and overrides ready-for-human

Amends ADR-0034: `orch-to-spec`'s Unattended rewrite is taken by a quick
autopilot as well as a quick implementation.

Sending an issue to autopilot took an attended planning session per issue: every
interview round, the label question, the test-seams check, the route question.
Many issues - notably the low-stakes ones finding triage files as
`ready-for-human` - are ones whose human trusts every recommendation the agent
would make, so the session was answering "recommended" over and over, one issue
at a time.

So `/orchestrator:quick-autopilot` plans unattended: each selected issue gets an
unattended interview whose every question takes its recommended answer, recorded
in the plan's Decisions; an unattended rewrite of its body as a spec, the seam
sketch taken; recommended Rounds and Budget; and `autopilot start`. It overrides
`ready-for-human` to `ready-for-agent`, because the human's control is the
selection itself, confirmed once, with each override shown before any write. It
never overrides `wontfix`, and an issue whose work is already done is skipped,
never closed. A fundamental item in the flow's later spec review still reaches
the human: running the command made the recommendations the human's decisions.
Its flow's spec review runs the plan's Rounds, as any autopilot flow's does
(ADR-0052), not ADR-0041's one round for a quick implementation: the human's
control over the spec is the one confirmation and the fundamental items, in
place of a planning close.

## Considered Options

- **Keep the attended interview per issue.** Rejected: it is the toil this
  removes.
- **Treat `ready-for-human` as held, as the planning close does.** Rejected: the
  low-stakes `ready-for-human` issues are the ones this command is for.
- **The hand-labelled path, the body reviewed as it stands.** Rejected: no
  interview would reach the body, and no seams would be agreed.
- **Ask before each override.** Rejected: the one confirmation already shows
  every override, and a question per issue defeats hands-off.
