# An autopilot review loop re-enters itself when its stop asks nothing

An autopilot review loop that ends in a bounded stop used to ask the human
every time, labelling the issue `needs-human`, even when the stop left
nothing to decide: an unclean final iteration, an open blocking finding,
a missing look, or a CI failure the change caused. The human's only
move was to lift the label. Such a stop is now an automatic re-entry:
a re-entry comment with no @mention, the phase left at `orch:review`,
and the watcher starts the next loop, whose budget the driver sizes by
the re-entry sizing rule. A stop with any reason that needs the human -
a spec question, CI unreachable, a failed base sync, known items not built,
or a CI failure needing a decision - still asks. The third bounded stop in
a row asks too, so a stuck blocker cannot spend usage unattended; a reply
or question resets the count. The flake rerun becomes one per loop rather
than one per flow, since automatic re-entries add CI waits; this amends
ADR-0007, under which the flake-rerun allowance belonged to the flow -
`iteration` and `budget` still do.

This amends ADR-0052, under which every autopilot review loop's bounded stop
asked the human, and the glossary's "only a human decides that a further
loop happens" for autopilot flows. Interactive flows still ask, because
a human is in the session and the budget question costs one click. The
trade-off is unattended loops spending usage, bounded by the cap, against
needless pings to the human.
