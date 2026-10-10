# The driver loop

The procedure that builds a ticket breakdown, one frontier after another, with
one `orch-implementer` per ticket (ADR-0036). A flow's implement phase and a
quick implementation both run it: each skill's session is the loop's driver,
reads this doc, and binds its slots below to its own run before loop step a.
Commands run through the caller's `$ORCH`.

## Slots

Each caller binds these six slots; the loop names them in bold wherever it
depends on them.

- **the issue**: the issue whose frontier is built - the issue `ticket next`
  is given, and the issue on the resolver's `Spec issue:` line.
- **the branch**: the branch every ticket commits to on the sequential path,
  and that loop step f verifies.
- **the record**: where the driver records host fallbacks, a resolution's
  **Merge resolutions**, and loop step f's verification command and `pass` or
  `fail`.
- **the judge**: what carries a failed loop step f verification, since a
  failure does not stop the run.
- **the stop**: what stops when loop step d's failures stop refilling.
- **after loop step f**: where the run goes next.

The caller also says whether the breakdown is **collapsed**, and what that
means for its run; loop step b takes it as a fact.

## The loop

Its steps are lettered a-f, so that a "loop step" never reads as one of the
caller's numbered steps.

- **a. Entry check.** `bash "$ORCH" ticket-worktree list`. If it prints
  anything, stop and name each leftover ticket worktree: a dead run's state,
  never built over. A human clears each with `bash "$ORCH" ticket-worktree
  remove <n>`. This runs on every path, sequential included.
- **b. Pick the path.** Read the cap: `bash "$ORCH" parallel show`. Take the
  **sequential path** when the breakdown is collapsed, the cap is 1, or the
  host cannot start a background subagent (record that last one under **the
  record**'s host fallbacks, per `docs/host-capabilities.md`'s **Start a
  background subagent** row). It creates no ticket worktree, and every ticket
  commits to **the branch**, one at a time, never in parallel. Collapsed, it
  dispatches the one subagent and goes to loop step f. Otherwise it loops:
  `bash "$ORCH" ticket next <the issue>` - nothing ready means the frontier
  is exhausted, so go to loop step f - then dispatch a subagent (below) for
  the ticket, with no `Worktree:` line; record its report, then `bash
  "$ORCH" ticket close <n>` - only now that the report is back, never
  before - and go around again. Any other case takes the parallel path, loop
  steps c-e.
- **c. Fill the free slots.** Keep an in-flight set of tickets in this
  session. While fewer than the cap are in flight, take the next ticket `bash
  "$ORCH" ticket next <the issue>` prints that is neither in flight nor
  queued to run alone: `bash "$ORCH" ticket-worktree add <n>`, then dispatch
  a subagent (below) for it in the background, its prompt carrying the
  `Worktree:` line with the path `ticket-worktree add` printed. Stop filling
  when `ticket next` has nothing more.
- **d. As each report returns**, record it, then `bash "$ORCH" ticket merge
  <n>`, then `bash "$ORCH" ticket close <n>`, then `bash "$ORCH"
  ticket-worktree remove <n>`, then refill (loop step c). A ticket is merged
  and closed whatever its `Verification` or `Criteria` line says, and is
  closed only after its merge succeeds. Any exit 1 from `ticket merge`,
  `ticket close` or `ticket-worktree remove`, a dispatch that fails, or a
  report that comes back malformed stops refilling: the tickets still in
  flight report and are processed as normal, then **the stop** happens,
  naming every failure. A leftover worktree surfaces at the next entry check
  and in `doctor` (`doctor --flow` inside a flow).
- **e. On a merge conflict** (`ticket merge` exits 3), resolve it, not
  rebuild it (ADR-0038), by **A driver's ticket resolution** in
  `agents/orch-resolver.md` (under the plugin root), **the issue** on the
  resolver's `Spec issue:` line. That section says how to resolve, what
  counts as a failed resolution, and its fallback to rebuilding the ticket
  alone. A resolution's **Merge resolutions** go in **the record**. When
  nothing is in flight, dispatch a ticket queued to run alone in a fresh
  worktree (`ticket-worktree add`) from the updated tip, on its own, and
  process its report as in loop step d before refilling. When the frontier
  and queue are exhausted and nothing is in flight, go to loop step f.
- **f. Verify the combined branch**, on every path, sequential included: run,
  on **the branch**, the full-verification command the reports'
  `Verification` lines name, once - joined with ` && ` into one line when
  they name different commands. Its command and `pass` or `fail` go in **the
  record**. A failure does not stop the run: **the judge** carries it.

Once loop step f has run, go **after loop step f**.

## Dispatching a subagent

Start the plugin's `orch-implementer` agent exactly as the **Starting this
agent** section of `agents/orch-implementer.md` (under the plugin root) says,
for the ticket named above. On Claude Code it is the agent named
`orch-implementer` under the `orchestrator:` plugin scope, run in the
background on the parallel path. A host that cannot start it natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback; record it
under **the record**'s host fallbacks, along with any fallback that section
says the agent takes.
