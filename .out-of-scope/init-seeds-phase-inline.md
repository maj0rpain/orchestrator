# Seeding `phase` inline in `cmd_init`

This project does not seed `phase: "spec"` directly in `cmd_init`'s `jq -n`
seed object. `init` seeds `phase: null` and then calls `phase_write spec`,
even though that costs a second state write and a second `updated` stamp.

## Why this is out of scope

`phase_write` is the one internal writer of `state.phase`. The #279 spec
says so directly: "`advance`, `review ready`, `redo review`, `redo spec`,
and `init`'s seed all route through it". Every way the phase gets set
therefore goes through one membership check against `PHASES`. If the seed
wrote the phase inline, a second writer would exist that skips that check,
and anyone adding a phase or renaming one would have to remember the seed
object as well.

The extra write is cheap. The moment where `phase` is null exists only
inside one `init` call, and `init` holds no lock that another reader could
race against. A single owner of the phase field is worth more here than
saving one `jq` pass.

## Prior requests

- #315: "cmd_init seeds phase null and then calls phase_write spec" (filed by the review loop as a Standards-axis major against PR #303)
