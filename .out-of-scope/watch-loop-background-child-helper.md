# Moving the watch loop onto the test tooling's background-child helper

This project does not move the autopilot watch loop's tick start and sleep
start onto `test_jobs_run_child`, the test tooling's signal-reachable child
start, even though the two sites repeat the sequence it owns.

## Why this is out of scope

The two sites do share the helper's shape: start the command in the
background, keep its pid in a variable the INT/TERM trap reads
(`AUTOPILOT_WATCH_CHILD`), wait for it keeping its status, clear the variable.
Their reactions to the status (the tick warns and carries on; the sleep
discards it) are the caller's own, as with section-durations. The move is
declined for the home the helper would need, not because the shape differs.

- `test_jobs_run_child` lives in the test tooling (`scripts/test/test_jobs.sh`),
  which the runners and dev scripts source. No `scripts/orch/` module sources
  the test tooling for its own code, so a shipped module sourcing it would
  cross the plugin/test-tooling boundary.
- A home both layers source would be a new cross-layer file for a five-line
  function. Here it would serve two sites in one function, which costs more
  than the duplication it removes.
- Moving the watch would also make its trap read the test tooling's
  `TEST_JOBS_CHILD`. The watch would still keep its own stop
  (`autopilot_watch_stop_child`, exit 0 after ending its liveness record), not
  the runners' exit-130 `test_jobs_stop_children`, so only the start would be
  shared.

```sh
# the two sites in autopilot_watch today
"$(autopilot_self)" autopilot tick >/dev/null &
AUTOPILOT_WATCH_CHILD=$!
wait "$AUTOPILOT_WATCH_CHILD" || rc=$?
AUTOPILOT_WATCH_CHILD=""
[ "$rc" = 0 ] || warn "autopilot watch: the tick failed (exit $rc); ..."
sleep "$every" &
AUTOPILOT_WATCH_CHILD=$!
wait "$AUTOPILOT_WATCH_CHILD" || true
AUTOPILOT_WATCH_CHILD=""
```

Reconsider if either of these happens: the plugin's own modules
(`scripts/orch/`) gain a further copy of the start-and-wait sequence, or a
home both layers source comes to exist for other reasons. Either changes the
weight of evidence.

## Prior requests

- #3035: "the autopilot watch loop's tick start and sleep start each repeat
  the sequence `test_jobs_run_child` owns" - filed by the review loop as a
  Standards-axis major against PR #3033, at the watch loop's tick start and
  sleep start.
