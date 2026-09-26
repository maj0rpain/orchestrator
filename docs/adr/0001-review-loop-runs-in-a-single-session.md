# The review loop runs in a single session

Superseded in part by ADR-0018: the reviewing is now done by the plugin's own
reviewer agents, not `code-review`'s sub-agents. One session per loop, and
the reviewers' independence from its reasoning, still stand.

Every other phase of a flow gets its own session, because the whole point of the
plugin is that a phase should judge the work rather than inherit the story
behind it. The review phase deliberately breaks that rule: one session drives
all of a loop's iterations, reviewing, triaging, fixing, and verifying.

It breaks the rule because the rule is already satisfied one level down. The
actual reviewing is done by `code-review`'s parallel sub-agents, which are
spawned fresh every iteration and see only the diff, the spec, and the repo's
standards - never the driving session's reasoning about the fixes it just wrote.
The contamination that fresh sessions exist to prevent is narrative, and no
narrative reaches the reviewers. What the driving session accumulates is
bookkeeping: which findings are open, what has been tried, how many iterations
are left. Discarding that between iterations would mean rebuilding it from the
records every time, and paying a `/clear` and an `/orchestrator:next` for the
privilege.

## Consequences

A review session is long-lived, and where other phases end after one unit of
work this one may run five. That is also why the CI wait was moved out of the
iteration and to the end of the loop (see the review skill): with a wait inside
each iteration, a single session could spend most of an hour blocked.

Fresh context does return at the loop boundary rather than the iteration
boundary: a flow that re-enters the review phase after a bounded stop starts a
fresh loop in a new session, which reads the implement handoff and the earlier
iteration records rather than anything the previous loop's session held (see
ADR-0003). The unit of context isolation is the loop, not the iteration.
