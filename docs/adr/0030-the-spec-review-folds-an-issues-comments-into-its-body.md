# The spec review folds an issue's comments into its body

Supersedes in part ADR-0004: a failed comments fetch now stops the review too, as a missing body does, because the lenses would otherwise review half the spec.

The spec review used to read only the issue body. But spec content often
arrives as a comment: triage posts its agent brief as one, and a human
clarifies a spec in a follow-up. No lens saw those comments, and the
implement phase, which reads only the body, never saw them either.

The spec review now fetches the issue's comments as well as its body. Before
the lenses' findings, the review's session proposes one consolidation item
for each comment that says something the body does not, skipping the
review's own `## Spec review` changelogs. These items go to the human in the
same batch, under the same one question. The lenses also read the comments,
so they don't report a gap a comment fills, and they do report a comment
that contradicts the body or another comment. The body stays the single
truth every later phase reads. After a review, the comments are history.

Consolidation happens only in the spec review. Skipping the review leaves the
comments unconsolidated.

## Considered Options

- **A fifth lens for comment completeness.** Rejected: comparing comments with
  the body is mechanical and needs no independent look.
- **Consolidating silently before the lenses run.** Rejected: only edits a
  human accepts change the issue.
- **Teaching every body reader to read comments.** Rejected: the same rule
  would live in several skills and drift apart, and the implement phase would
  have to reconcile two sources.
