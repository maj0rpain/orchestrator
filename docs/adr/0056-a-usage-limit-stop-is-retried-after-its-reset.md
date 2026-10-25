# A usage-limit stop is retried after its reset

Amends ADR-0052 (an autopilot flow's phase lives on its issue, claimed
through a git ref).

#1451's plan rejected automatic retry, and an autopilot failure comment says
nothing is retried automatically: a failed session waits on the human.
ADR-0052 records how an autopilot flow's phase is kept and claimed, not this;
it is amended because its flow now restarts a phase without a human. A
session cut off by a usage limit needs no decision, only time, and since
ADR-0054 a restarted phase finishes what landed and discards what did not, so
restarting it needs no human either.

Decision: a usage-limit stop labels its issue `orch:limited` and a tick once
the limit pause has passed picks its phase up again, at most twice in a row
per phase before the stop falls back to `needs-human`; every other failure
still waits on the human. The reset comes from Claude Code's stream-json
`rate_limit_event`, with the message text as fallback.

## Considered Options

- **No retry.** Rejected: the human's inbox fills with issues that need
  nothing from them.
- **Unlimited retry.** Rejected: a phase bigger than a usage window would
  loop forever.
- **Killing every running session at the first limit.** Rejected: loses work
  that needs no model call, and multiplies mid-phase deaths.
