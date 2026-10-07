# The spec review is one pass, and its reversals amend the plan handoff

Superseded in part by ADR-0030: a failed comments fetch now stops the review too.

Superseded in part by ADR-0034: a quick implementation's spec review is unattended, and its ticket follow-up takes its own recommendation, retiring included.

A spec review runs once, in the spec phase, after the issue exists - published
by `to-spec` or already adopted at init - and before `02-spec.md` is written.
Four lenses read the issue as fresh sub-agents and report findings; every
finding reaches the human as a proposed edit in one batch; the edits the human
accepts rewrite the issue body. There is no budget, no second pass, and no
severity: findings stay with the lens that reported them and are never ranked
across lenses. The one document the review may change besides the issue is
`01-plan.md`, and only its **Rejected alternatives** section, and only when
the human has just declined to restore something the plan ruled out.

The review is one pass because of what ADR-0003 measured: prose findings never
converge. A spec is all prose. The code loop's later iterations paid off
because a reviewer eventually read a specific line of code and found a defect
that was there all along; four lenses over one issue body do not have that
shape, and a second pass over an edited body would draw findings against the
edits, as loop 2 of #8 did. The human's control sits at the batch decision
instead, where they may decline every edit, and a human who wants another
look after the edits has redo.

The findings carry no severity, and none is filtered before the human sees it,
because the review loop's rubric and demotions both rest on a recorded human
decision - a deviation the user agreed to, an alternative the plan rejected -
and the spec review has none yet. The human is present and disposes of every
finding themselves. A finding the session believes is wrong is presented with
that recommendation rather than dropped, and a Fidelity finding that says the
spec re-proposes a rejected alternative is presented first, labelled, rather
than applied automatically: the plan's rejection was made with less context
than the human has now, with the spec in front of them, and they may reverse
it.

That reversal is what makes the review write into the plan handoff. The review
loop demotes any finding that proposes a rejected alternative, on the strength
of `01-plan.md` alone (ADR-0002's shape, one section over). If the spec review
let the human reverse a rejection and left the plan handoff saying it still
stood, the review loop would later demote a code reviewer for proposing the
spec's own choice, and would do so citing a decision the human had already
undone. So the declined `contradicts the plan` item amends the matching entry
to say it was reversed in the spec review and why. A later phase editing an
earlier phase's handoff is otherwise never done, and the amendment is confined
to the one section whose only reader acts on it as authority.

Seams follow the same rule in the other direction. They are agreed with the
human in the spec phase, recorded in the issue's **Testing Decisions** and the
spec handoff, and the implement phase tests at the seams it is given without
asking again. The Testability lens reads them from the issue rather than from
anything the spec session remembers, so seams agreed in conversation and never
written down surface as a finding the review catches, not as a gap the
implement phase discovers.

## Consequences

The spec phase can end with a spec that departs from the plan. That is the
intended outcome, and it is only safe if it is visible: the changelog comment
on the issue records **spec departs from the plan** with its reason (the
human's, or **declined as recommended** when they took the review's advice),
`02-spec.md` carries the same changelog, and the plan handoff's entry says it
was reversed. Nothing downstream has to remember the reversal, because every
document it might consult has been told.

A lens that fails twice is recorded as **not run** rather than stopping the
phase: three lenses and a visible gap is a spec review, a silent gap is not,
and no issue body at all is the one thing that stops it.

The failure mode to watch for is the amendment being used for anything else.
Its authority comes entirely from a human having declined a specific
`contradicts the plan` finding with the spec in view; a session that edits
**Rejected alternatives** for its own reasons is rewriting the authority the
review loop reads, and no later phase could tell.

## Note: standalone spec review (2026-09-27)

A spec review may also be standalone: a human runs one on demand against any
issue, outside a flow (#185). A standalone review never writes the plan
handoff - there is none - and Fidelity does not run in it, so it has no
`contradicts the plan` items and nothing to amend. The one-pass decision is
unchanged: inside a flow, another look is still redo; outside one, it is
another standalone review.

## Note: tickets follow the spec (2026-10-04)

When the spec review's accepted edits touch an open ticket of an existing breakdown, it asks the human a second question: how the breakdown should follow the edits just accepted - per-ticket edits, or retiring the breakdown so it is broken down again. This is not a second pass. No lens runs and the spec is not reviewed again; the question only brings existing tickets in line with a spec the human has already decided. The one-pass decision is unchanged. The review may now also write the issue's tickets - their bodies, or retiring the breakdown and, in a standalone review, breaking the issue down again - and only to follow edits the human has already accepted.
