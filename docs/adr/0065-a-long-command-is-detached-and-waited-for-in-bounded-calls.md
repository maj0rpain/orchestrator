# A long command is detached and waited for in bounded calls

A verification run, a wait on CI and a wait on lenses can each take longer than
a host lets one tool call run. Claude Code's Bash tool waits 600 s in the
foreground, then moves the command to the background and later stops it. A
subagent cannot end its turn to wait, and a sleep or a process poll is refused.
On 2026-11-14, with five autopilot sessions on 8 CPUs, 60 Bash calls hit the 600
s limit and sessions polled or reran the suite instead of waiting (#3169).

Decision: `verification run`, `review ci` and `spec-review wait` are re-callable
commands. A verification run is detached from the call that starts it; the two
waits keep their deadline across calls. A call waits a bounded time, 570 s by
default; when the work is still going it prints a still-running line and exits
75, and the same command run again on an unchanged tree waits for the same work.
A verification run is identified by its checkout, command, HEAD and working-tree
state; a live run whose HEAD or tree has changed is stopped and replaced, or
refused when its process group cannot be stopped; and a detached run is stopped
at a ceiling, one hour by default. Sessions run their verification through
`verification run`, not bare: this amends ADR-0063's "Agents run their
verification command bare", and the rest of ADR-0063 stands, since `verification
run` measures and keeps nothing. It also amends ADR-0058's note that step f runs
the full verification bare: step f runs it through `verification run` as well.

## Considered Options

- **Run suites one at a time across the clone.** Closed as not planned (#3178):
  the last queued run still waits longer than one call, so it does not fit the
  limit alone.
- **Tie the cap to the CPU budget.** Rejected: it trades the watcher's
  throughput for a margin the suite's next growth erases, breaks on any other
  load, and cannot know another repo's suite cost.
- **Two new verbs, a start and a wait.** Rejected: every site would change from
  one command to two, and a session's habitual rerun would still start a second
  copy.
- **Keep the verification run bare and make only the two waits re-callable.**
  Rejected: the 2026-11-14 overruns were suite runs, so it leaves the logged
  cause in place.

## Consequences

- A re-callable command can exit before its work is done. Exit 75 means "still
  running", never pass or fail.
- A run can outlive its session. It is bounded by the ceiling, and a restarted
  phase with an unchanged tree collects its result.
- An autopilot session's live runs are stopped at its end, so a restarted phase
  never reattaches to one but still collects a finished run's result; a human's
  session's runs still outlive it.
- The 600 s figure is the host's. One setting, `ORCH_WAIT_BLOCK`, holds the
  block length kept under it, for all three commands.
