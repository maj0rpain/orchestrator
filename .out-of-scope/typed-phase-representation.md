# Typed/enum representation for flow phase

This project does not introduce a typed or enum representation for a flow's
phase, keeping it a plain string compared via bare literals, even where a
comparison like `[ "$phase" = done ]` reads like it wants a named constant.

## Why this is out of scope

Phase is already string-typed everywhere in this codebase — read via a
plain JSON string field, listed as a plain string constant, and compared
with bare literals at every call site, not just the ones flagged here. A
typed representation would be a deliberate, repo-wide convention change,
not something a single call site should adopt unilaterally; doing it in
isolation would leave some comparisons typed and others not, which is worse
than the current uniform (if primitive) convention.

## Prior requests

- #74: "Phase comparisons use bare string literals, not a typed representation" — filed by the review loop as a Standards-axis nit against PR #72, with the reviewing sub-agent itself noting this matches established house style
