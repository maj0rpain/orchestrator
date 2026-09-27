# Single source for the planning message on each host

**Retired by #202.** There is no second copy left to share a source with.
`guidelines/orch-planning.md` is deleted: Junie now receives the planning
message from `scripts/hook-grilling.sh` itself, through a `UserPromptSubmit`
hook, and only the sentence on how to run the next skill differs between the
hosts. The reasoning below rested on the Junie copy being always loaded and
so having to state its own condition, which no longer holds. It is kept for
the record only. Do not cite it to reject a request.

## Former reasoning

This project did not generate the planning message that
`scripts/hook-grilling.sh` injected on Claude Code and the one
`guidelines/orch-planning.md` carried for Junie from one shared source. The
two copies were close in content but not in wording: the hook's message was
injected only when grilling ran with no active flow, so it could state its
instructions without conditions, while the always-loaded Junie guidelines file
had to open with the condition that turned it on and explain how to run a
skill on a host with no Skill tool. A generator would have needed a template
made mostly of slots. The parts that had to agree were checked mechanically
by `scan_planning_nudge`, which #202 replaced with hook tests for the Junie
output.

## Prior requests

- #134: "Planning message is duplicated in hook-grilling.sh and guidelines/orch-planning.md", filed from the seventh review of #131 (standards axis)
