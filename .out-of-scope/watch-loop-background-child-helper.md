# Moving the watch loop onto the test tooling's background-child helper

This project does not move the autopilot watch loop's tick start onto
`test_jobs_run_child`, the test tooling's signal-reachable child start, even
though the watch repeated the sequence it owns (in bash `autopilot_watch`
when this was decided, Python's `watch_verb` and `Watch` now, in
`scripts/orch_py/orch/autopilot.py`).

## Why this is out of scope

The bash watch's two sites, its tick start and its sleep start, did share
the helper's shape: start the command in the background, keep its pid in a
variable the INT/TERM trap reads (`AUTOPILOT_WATCH_CHILD`), wait for it
keeping its status, clear the variable. Their reactions to the status (the
tick warns and carries on; the sleep discards it) were the caller's own, as
with section-durations. The move was declined for the home the helper would
need, not because the shape differs.

- `test_jobs_run_child` lives in the test tooling (`scripts/test/test_jobs.sh`),
  which the runners and dev scripts source. No `scripts/orch/` module sourced
  the test tooling for its own code, so a shipped module sourcing it would
  have crossed the plugin/test-tooling boundary. The Python watch is further
  still from it: a Python package sources no bash at all.
- A home both layers source would be a new cross-layer file for a five-line
  function. Here it would have served two sites in one function, which costs
  more than the duplication it removes.
- Moving the watch would also have made its trap read the test tooling's
  `TEST_JOBS_CHILD`. The watch kept its own stop (bash
  `autopilot_watch_stop_child`, exit 0 after ending its liveness record;
  Python's `Watch.stop_tick` now), not the runners' exit-130
  `test_jobs_stop_children`, so only the start would have been shared.

Python's watch holds the tick it waits on as `Watch.tick`, which its INT and
TERM handler's stop reads, and starts it through the autopilot module's own
child start, which the session wrapper's children share; its sleep is no
child, a signal cuts it short.

The two sites, as bash read when this was decided (`$AUTOPILOT_SELF` was
the plugin's orch.sh):

```sh
# the two sites in autopilot_watch
"$AUTOPILOT_SELF" autopilot tick >/dev/null &
AUTOPILOT_WATCH_CHILD=$!
wait "$AUTOPILOT_WATCH_CHILD" || rc=$?
AUTOPILOT_WATCH_CHILD=""
[ "$rc" = 0 ] || warn "autopilot watch: the tick failed (exit $rc); ..."
sleep "$every" &
AUTOPILOT_WATCH_CHILD=$!
wait "$AUTOPILOT_WATCH_CHILD" || true
AUTOPILOT_WATCH_CHILD=""
```

Reconsider if either of these happens: the plugin's own code (`scripts/orch/`
or `scripts/orch_py/orch/`) gains a further copy of the start-and-wait
sequence outside the autopilot module's child start, or a home both layers
source comes to exist for other reasons. Either changes the
weight of evidence.

## Prior requests

- #3035: "the autopilot watch loop's tick start and sleep start each repeat
  the sequence `test_jobs_run_child` owns" - filed by the review loop as a
  Standards-axis major against PR #3033, at the watch loop's tick start and
  sleep start.
