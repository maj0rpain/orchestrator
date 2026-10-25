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
- **the branch**: the branch every ticket branch merges into, and that
  loop step f verifies.
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

- **a. Entry check.** `bash "$ORCH" ticket reclaim <the issue>`: it recovers
  what a dead run left (ADR-0054) - a merged ticket closed, an unmerged
  ticket with a saved report merged and closed, any other leftover discarded
  so its ticket is rebuilt - and prints one line per action. Exit 3 means a
  saved ticket's merge conflicted (`conflict <n>`): resolve it as loop step e
  says, with a fresh resolver in place of the dead subagent - it starts the
  rebase itself - then run `ticket reclaim` again. Any other failure stops
  the run, naming it. This runs on every path.
- **b. Pick the path.** Read the cap: `bash "$ORCH" parallel show`. Take the
  **sequential path** when the breakdown is collapsed, the cap is 1, or the
  host cannot start a background subagent (record that last one under **the
  record**'s host fallbacks, per `docs/host-capabilities.md`'s **Start a
  background subagent** row). It runs one ticket at a time, never in
  parallel, and every ticket still builds in its own ticket worktree
  (ADR-0055): `bash "$ORCH" ticket-worktree add <n>`, then dispatch the
  subagent (below) with the `Worktree:` line, in the foreground, then land
  its report exactly as loop step d does - save, `ticket merge`, `ticket
  close`, `ticket-worktree remove`. Collapsed, the ticket is **the issue**
  itself, built in `t<the issue>`: its branch is merged and its worktree
  removed, and `ticket close` is never run on it. It dispatches that one
  subagent, lands it, and goes to loop step f. Otherwise it loops: `bash
  "$ORCH" ticket next <the issue>` - nothing ready means the frontier is
  exhausted, so go to loop step f - then the ticket as above, and go around
  again. Any other case takes the parallel path, loop steps c-e.
- **c. Fill the free slots.** Keep an in-flight set of tickets in this
  session. While fewer than the cap are in flight, take the next ticket `bash
  "$ORCH" ticket next <the issue>` prints that is neither in flight nor
  queued to run alone: `bash "$ORCH" ticket-worktree add <n>`, then dispatch
  a subagent (below) for it in the background, its prompt carrying the
  `Worktree:` line with the path `ticket-worktree add` printed. Stop filling
  when `ticket next` has nothing more.
- **d. As each report returns**, record it, save it with `bash "$ORCH"
  ticket report save <n> <file>` (the report in a `mktemp` file; a refused
  save stops like any exit 1 below), then `bash "$ORCH" ticket merge
  <n>`, then `bash "$ORCH" ticket close <n>`, then `bash "$ORCH"
  ticket-worktree remove <n>`, then refill (loop step c). Run the four as
  separate calls, each only after the previous one exits 0 - never chained
  with `;`. A ticket is merged
  and closed whatever its `Verification` or `Criteria` line says, and is
  closed only after its merge succeeds. A collapsed breakdown's ticket is
  merged and its worktree removed, never closed. A report is six lines,
  the sixth `Evidence`; one with no `Evidence:` line reads as
  `Evidence: None` and is processed as normal, never as malformed. Any exit
  1 from `ticket merge`, `ticket close` or `ticket-worktree remove`,
  a dispatch that fails, or a report that comes back malformed stops
  refilling: the tickets still in flight report and are processed as
  normal, then **the stop** happens, naming every failure. A leftover
  worktree is reclaimed at the next entry check and shows in `doctor`
  (`doctor --flow` inside a flow).
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
background on the parallel path and in the foreground on the sequential
one, on the `implementer` setting. The driver reads it, and the
`resolver` setting **A driver's ticket resolution** starts its resolvers on,
once, before loop step a, per **Agent settings** in
`docs/host-capabilities.md`: `bash "$ORCH" agent get implementer` and
`bash "$ORCH" agent get resolver`. Every ticket subagent and resolver of the
run starts on those, and a ticket subagent resumed to resolve its own merge
conflict keeps the setting it started with. A host that cannot start it
natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback; record it
under **the record**'s host fallbacks, along with any fallback that section
says the agent takes.
