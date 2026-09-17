# Redo resets the review loop's iteration and budget

Everywhere else, `iteration`, `budget`, and the flake-rerun allowance belong to
the *flow*: they run on across every loop a flow enters and never reset on
ordinary re-entry after a bounded stop. Redo breaks that rule on purpose.
Stepping a flow back from `review` to `implement` resets `iteration` to 0 and
has the review skill ask for a fresh budget the next time it runs, because a
redone implementation is a different change - reviewing it "from iteration 6"
would carry over a look-count that belonged to the attempt it just replaced.
`flake_rerun_used` does not reset alongside them: it stays a per-flow
allowance, spent or not, regardless of which attempt is currently live.

## Consequences

The old loop's records and branch are retired, not deleted, so the reset loses
nothing: `.orchestrator/review/iteration-NN.md` files move into
`pre-redo-N/` before the counter restarts at 1, and the old branch is renamed
`orch/<issue>-<slug>-redo-N` rather than force-pushed over. `redo_count` is the
field to read for "how many times has this flow been redone" - `iteration`
alone no longer answers that once a redo has happened.
