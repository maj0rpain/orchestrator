# A second flow gets a worktree, not a key

`init` refuses a second flow, and until now the only guidance was "use a
second checkout" - a sentence with no tooling behind it. The obvious
temptation is to let a second flow live in the *same* directory, distinguished
by a key passed to every command (`/orchestrator:next 60`), switching which
branch is checked out underneath it as needed. That was rejected: git only
ever has one branch checked out per working directory outside of worktrees, so
a key-based scheme means re-implementing, by hand, exactly what a worktree
already does - and doing it worse, since every switch risks stomping whatever
the previous flow's session left uncommitted.

A worktree-dispatched subagent (the Agent tool's `isolation: "worktree"`) was
considered too, keeping everything inside one Claude Code window instead of
asking for a second session. Rejected for now: `to-spec`, `review-spec`, and
`redo` all need a human mid-phase, and a backgrounded flow's question landing
unprompted in whatever conversation happens to be open defeats the reason to
background it in the first place.

So: when `init` would refuse, it now offers a git worktree instead - a sibling
directory, checked out from the default branch, with its own `orch.sh init`
run inside it and its own `.orchestrator/state.json`, completely isolated from
the flow already running. The wrapper's job ends at creating the worktree and
printing the exact command to open a second session there; nothing routes
commands by key, because the working directory itself disambiguates which
flow a command means.

## Consequences

Cleanup rides on the same lifecycle event that already exists: archiving a
flow (via `/orchestrator:abort` or after `done`) also removes its worktree, so
there is nothing new to remember. `git worktree remove` refuses on
uncommitted or unpushed state, and this feature never overrides that with
`--force` - archive already treats every artefact as recoverable, not
disposable, and a dirty worktree is no exception. Because every phase already
commits and pushes before it ends, a dirty tree at a phase boundary is always
a bug in that phase; `doctor --flow`, which already runs at the top of every
`/orchestrator:next`, now checks for one, so it surfaces immediately at the
boundary that caused it rather than later as an opaque worktree-removal
failure. `orch.sh status` also stops being purely directory-scoped: it
cross-references `git worktree list` against which paths carry a
`.orchestrator/state.json` and summarises every sibling flow, not just the
current one.
