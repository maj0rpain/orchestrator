# Shared accessor for review-terminal-state's word/detail output

This project does not extract a shared classify-and-describe helper, or a
shared word/detail accessor, for the terminal-state string returned by the
review-terminal-state classifier — even though both its parsing (word vs.
detail) and the messaging built on top of the resulting word are duplicated
across two or three call sites.

## Why this is out of scope

The classifier itself is already properly deduplicated — call sites don't
recompute it, they each just ask "what to do with the result" differently:
`cmd_redo_review` decides whether Redo may proceed, `check_flow_review_terminal`
decides what doctor should print, and the flow skill's prose describes the
same three cases in FAQ form for a human reader. A shared "classify and
describe" helper generic enough to serve all three either grows a mode
argument for how each caller wants to react, or leaves the prose copy (which
isn't code at all) out of the shared path regardless. Similarly, the
word/detail split is two lines of parsing at two call sites — a dedicated
accessor would replace two lines with a function call to look them up.

This project prefers a few duplicated lines at two or three call sites over
an abstraction that has to grow parameters to fit callers that genuinely
react differently. If a fourth call site appears with the same reaction
shape (not just the same parsing), that's a different weight of evidence —
see "Updating or removing out-of-scope files" in the triage skill.

## Prior requests

- #58: "Terminal-state classification is re-derived independently in three places" — filed by the review loop as a Standards-axis nit against PR #56
- #59: "review_terminal_state's word/detail result is parsed ad hoc instead of via a shared accessor" — filed by the review loop as a Standards-axis nit against PR #56
