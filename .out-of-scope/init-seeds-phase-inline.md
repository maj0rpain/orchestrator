# Seeding `phase` inline in `cmd_init`

This project does not seed `phase: "spec"` directly in `init`'s seed object
(bash `cmd_init`'s `jq -n` object when this was decided, Python's
`flow_state_seed` now). `init` seeds `phase: null` and then calls
`phase_write spec`,
even though that costs a second state write and a second `updated` stamp.

## Why this is out of scope

The phase writers, `phase_write` and `phase_write_try` in
`scripts/orch_py/orch/flow_state.py`, are the internal writers of
`state.phase`. They serve `init`, now a Python noun, which
stamps its seed's phase through `phase_write`, and the Python `phase` noun:
`phase advance`, and `review ready`'s in-process `finish` and,
under autopilot, `standing_finish`, and the Python `redo` noun, whose
closing write (`redo_step_back`) goes through it. Each checks the phase
against the phase table. Every way the phase gets set therefore goes
through that check. If the seed wrote the phase inline, a
further writer would exist that skips that check, and anyone adding a phase
or renaming one would have to remember the seed object as well.

The extra write is cheap. The moment where `phase` is null exists only
inside one `init` call, and `init` holds no lock that another reader could
race against. A single owner of the phase field is worth more here than
saving one `jq` pass.

## Prior requests

- #315: "cmd_init seeds phase null and then calls phase_write spec" (filed by the review loop as a Standards-axis major against PR #303)
