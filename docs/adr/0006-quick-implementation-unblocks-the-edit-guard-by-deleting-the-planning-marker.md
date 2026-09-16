# Quick implementation unblocks the edit guard by deleting the planning marker

When a grilling session's human picks a quick implementation over starting a
flow, the model calls `orchestrator:quick-implement`; a hook on that `Skill`
call deletes the session's `orchestrator-grilling-<session>` marker, the same
marker `hook-guard.sh` already checks before blocking edits. We picked this
over exposing the session id to the model so it could delete the marker
itself, and over softening `hook-guard.sh`'s block to a non-blocking warning:
a `Skill` call is already the one reliable choke point this plugin's hooks
rely on (mirroring how `orchestrator:flow` is the choke point for the flow
path), so reusing it keeps both paths symmetric and keeps the guard's
enforcement mechanical rather than dependent on the model correctly reporting
its own state.

## Considered Options

- Model deletes the marker itself via Bash, once told the human chose quick
  implementation. Rejected: requires exposing the session id to the model in
  injected context just so it can compute the right file to delete, adding a
  data channel that exists for no other reason.
- Soften `hook-guard.sh` to a warning once the closing question has been
  asked. Rejected: the bug this fixes is a model silently deciding not to ask
  at all; a soft warning is exactly as easy to talk past as the scripted line
  it replaces.

## Consequences

Any future skill that wants to grant the same "planning is over, edits are
allowed" permission has to become another `Skill`-triggered hook rather than
flipping a flag - consistent with the pattern, but a new choke point each
time.
