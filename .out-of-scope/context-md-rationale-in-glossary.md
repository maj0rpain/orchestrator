# CONTEXT.md entries stating rationale, not just definitions

This project does not enforce CONTEXT.md's "glossary only, no decisions"
scope rule strictly enough to bar an entry from explaining *why* a
constraint holds, when that explanation is what makes the term's boundary
legible on its own.

## Why this is out of scope

CONTEXT.md's stated scope pushes decisions out to `docs/adr/`, but a handful
of entries (Quick implementation, and now Redo) already state a behavioral
constraint together with a sentence of the reasoning behind it, because the
constraint reads as arbitrary without it. Splitting that sentence out into
an ADR every time would leave the glossary entry stating a boundary with no
hint why it's drawn there, forcing a reader to go open an ADR just to trust
a one-line rule they'd otherwise take at face value. The line between
"definition" and "decision" isn't crisp enough here to make policing it
worth the churn.

## Prior requests

- #67: "CONTEXT.md's Redo entry states decision rationale, crossing its own glossary-only scope rule" — filed by the review loop as a Standards-axis nit against PR #56, with the reviewing sub-agent itself flagging it as borderline
