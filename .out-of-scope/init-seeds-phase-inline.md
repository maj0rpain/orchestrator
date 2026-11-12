# Seeding `phase` inline in `cmd_init`

This project does not seed `phase: "spec"` directly in `cmd_init`'s `jq -n`
seed object. `init` seeds `phase: null` and then calls `phase_write spec`,
even though that costs a second state write and a second `updated` stamp.

## Why this is out of scope

`phase_write` is the internal writer of `state.phase` for `advance`,
`review ready`, and `init`'s seed. `redo_step_back`, each redo's single
closing write, also writes the phase and repeats the same `PHASES`
membership check. Every way the phase gets set therefore goes through that
membership check against `PHASES`. If the seed wrote the phase inline, a
further writer would exist that skips that check, and anyone adding a phase
or renaming one would have to remember the seed object as well.

The extra write is cheap. The moment where `phase` is null exists only
inside one `init` call, and `init` holds no lock that another reader could
race against. A single owner of the phase field is worth more here than
saving one `jq` pass.

## Prior requests

- #315: "cmd_init seeds phase null and then calls phase_write spec" (filed by the review loop as a Standards-axis major against PR #303)
