# The spec review shows its material edits in full and lists its minor ones

Supersedes ADR-0004 in part: the spec review still ranks nothing across lenses,
but its session now marks each item material or minor. Supersedes ADR-0044 in
part: a minor edit may change the issue after the human has read only its
one-line summary.

Superseded in part by ADR-0048: a material item is no longer shown in full, and
the batch question's Other answer may also be show <n>, which names no
departure.

Superseded in part by ADR-0049: the changelog no longer tags the minor items
applied by the human's answer.

Superseded in part by ADR-0051: the one batch question is a turn-final
plain-text question, not an ask-tool call.

Once `spec-review check` printed every item in full, a round-1 batch ran to
100-200 lines, and across 207 recorded rounds the human answered something other
than Apply as recommended about six times. Most items reword, clarify or
cross-reference; few change what gets built. Reading all of them in full cost
attention that the few material ones needed.

So the session marks each item **material** (its edit changes behaviour, scope,
an interface, an acceptance criterion or a test seam) or **minor**. Decision
items, `contradicts-the-plan` items, and recommend-decline items whose edit
would be material are always material; `check` enforces the first two, and the
third is the session's judgement. The view shows material items in full and
minor items one line each; the one batch question covers both, and its Other
answer names only departures from the recommendation. The changelog tags each
minor item applied by the human's answer, so the history shows it was applied
without being shown in full; an unattended review's changelog carries no tag.

## Considered Options

- **Ask about decision items only.** Rejected: an edit that adds a seam or
  changes scope is as consequential as a decision, with no options to show it.
- **Lenses rate their own findings.** Rejected: a lens sees one angle, and
  lenses never rank (ADR-0004).
- **Hide minor items, showing only a count.** Rejected: the one-line list lets
  the human catch a misclassified item.
- **Apply an all-minor round without asking.** Rejected: in an attended review
  nothing changes the issue unasked.
