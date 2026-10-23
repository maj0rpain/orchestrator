# A busy checkout sends a quick implementation to a side checkout

Supersedes in part ADR-0037: its side checkouts, their sweep and its removal
rules hold. Its "a human can ask for one where no check could see the need, such
as a second quick implementation, which keeps no state" does not.

A checkout counted as occupied only when a flow was mid-pipeline, read from
`.orchestrator/state.json`. A quick implementation keeps no state, so a second
one started in the same checkout could not tell, and its `branch off` checked
out a new branch from the base, moving the first one's branch and carrying its
uncommitted edits along. A flow's `branch create` did the same, with no check at
all. The human guarded against it by asking for a side checkout by hand.

A **busy checkout** is a checkout that holds work a new branch must not move: a
flow mid-pipeline, a branch the plugin made that has no PR yet, or a working
tree with changes outside the planning allowlist. One check decides it, reading
only local git and state facts, and `orch.sh branch busy` exposes it. A branch
counts as having a PR once `pr open` or `pr publish` records
`branch.<b>.orchestrator-pr` in its git config, so the check never asks GitHub.
`branch off`, `branch create` and `init` each refuse a busy checkout with exit
3, each checking the signals that apply to it: `branch create` skips the flow
signal, the flow mid-pipeline being its own, and `init` skips the dirty tree,
which keeps its own exit-1 refusal so a stray planning edit is never quietly
taken into a side checkout.

A quick implementation runs `branch busy` once its issue is linked, and on a
busy checkout goes straight to a side checkout, asking nothing and printing one
line naming what holds the checkout. `branch off` exiting 3 later does the same.
A flow started in a busy checkout is still offered one, as before.

## Consequences

The human no longer has to ask for a side checkout for a second quick
implementation. A quick implementation that stopped before its PR keeps its
checkout busy until the human switches off its branch, and the busy line names
that branch. A branch made before the PR marker existed has no marker, so it
counts as busy until the human switches off it; the cost is a side checkout. On
the `branch off` route, the side checkout's session runs the spec review a
second time. A flow's implement phase meeting a busy checkout at `branch create`
stops and tells the human what to clear, since its state already lives in this
checkout.

## Considered Options

- **A lock file under `.orchestrator/`.** Rejected: a crashed session would
  leave a stale lock.
- **Asking GitHub whether the branch has a PR.** Rejected: the check stays
  local, with no network call.
- **Always running a quick implementation in a side checkout.** Rejected: most
  quick implementations run alone, and a side checkout costs a new session.
- **Asking before moving to a side checkout.** Rejected: a quick implementation
  is hands-off, and the move costs nothing the human must weigh.
