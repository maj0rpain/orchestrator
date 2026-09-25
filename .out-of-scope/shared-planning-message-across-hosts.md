# Single source for the planning message on each host

This project does not generate the planning message that
`scripts/hook-grilling.sh` injects on Claude Code and the one
`guidelines/orch-planning.md` carries for Junie from one shared source. It
also does not widen the test so that every sentence of one must appear in the
other. The two copies stay hand-written, with a "Change one, change the other"
note in the hook.

## Why this is out of scope

The two copies are close in content but not in wording, because each is
written for a different host and reader:

- The hook's message is injected only when grilling is running with no active
  flow, so it can state its instructions without conditions and can name
  Claude Code's tools directly.
- The Junie guidelines file is always loaded, so it has to open with the
  condition that turns it on ("only when a grilling session is running and no
  flow is active"). It also has to explain how to run a skill on a host that
  has no Skill tool.

If one copy were generated from the other, the generator would need a
template with slots for exactly those host-specific parts. Most of the text
would become slots, and the result would be harder to read and edit than two
short files. A strict "every hook sentence must appear in the guidelines"
test fails for the same reason: the sentences are meant to differ.

The parts that really must agree are already checked mechanically.
`scan_planning_nudge` in the test suite checks the guidelines file for a fixed
list of key points: the conditional wording, the active-flow check, both
options, the multiple-choice question, and both skill names. A separate test
keeps the planning allowlist in step with `scripts/planning-allowlist.sh`. The
remaining prose rarely changes. When it does, the note in the hook is enough.

This follows the same reasoning as
[duplicated-phase-runs-next-explanation.md](duplicated-phase-runs-next-explanation.md):
text that each standalone reader needs is restated in place rather than
shared.

## Prior requests

- #134: "Planning message is duplicated in hook-grilling.sh and guidelines/orch-planning.md", filed from the seventh review of #131 (standards axis)
