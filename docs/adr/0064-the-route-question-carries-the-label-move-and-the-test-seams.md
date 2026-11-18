# The route question carries the label move and the test seams

Amends ADR-0004 (seams are agreed with the human in the spec phase) and
ADR-0050 (the flow's rewrite still asks its test-seams check).

Beside the round count a blueprint or an autopilot flow asks, a planning
close asked up to three questions in a row: whether to move the interviewed
issue to `ready-for-agent`, how to carry the plan out, and, once a route
wrote the spec, whether the sketched test seams were right. Over the
planning sessions of 2026-11-14 the human accepted the move 7 of 7 times and
the seams 7 of 7 times, and picked a route other than the recommended one 4
of 4 times. Each accepted question cost a round trip and added nothing.

Decision: on these matters the route question is the planning close's one
question. It names the test seams in one line; picking a route accepts them
and moves a movable interviewed issue to `ready-for-agent`. A free-text
answer changes the seams, leaves the label, names another issue or declines
every route. A held label (`wontfix`, `ready-for-human`) keeps its own
override question, because it is a human's ruling. Seams agreed there travel
with the plan - in the conversation, or in the plan handoff's Decisions for a
flow - and `orch-to-spec` asks its test-seams check only where none were
agreed, as one line whose first option accepts. The question recommends the
user's default route when one is set, else a route from the scope of the
work; the human still picks.

## Considered Options

- **Keep three questions.** Rejected: the label and seams answers never
  differed from the recommendation, and the route answer differed from it
  every time.
- **Print the seams and go on without asking.** Rejected: some hosts hide
  text written beside a tool call (ADR-0051), so the human might never see
  the line, and the seams would stop being an agreement.
- **Take the default route without asking.** Rejected: a route is chosen by
  a human at each close, never assumed.
- **Fold a held label's override into the route question too.** Rejected: a
  held label is a human's ruling, and the measured acceptances cover only
  the movable case.
- **A fifth "Skip" option on the route question.** Rejected: Claude Code's
  ask tool takes at most four options, and the four routes fill them.
