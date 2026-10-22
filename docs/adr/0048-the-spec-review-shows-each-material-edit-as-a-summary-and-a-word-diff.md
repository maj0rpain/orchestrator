# The spec review shows each material edit as a summary and a word diff

Supersedes ADR-0047 in part: a material item is no longer shown in full, and the batch question's Other answer may also be `show <n>`, which names no departure. Supersedes ADR-0044 in part: a material edit rewritten past the diff's limit may change the issue after the human has read only its summary and reason.

Superseded in part by ADR-0049: a material item no longer shows its word diff or the findings it cites, and the batch question's Other answer may also be a free-text question, which names no departure.

Superseded in part by ADR-0051: the one batch question, and `show <n>` within it, are a turn-final plain-text question, not an ask-tool call.

Showing material items in full still ran long: each item quoted its findings whole, often the same finding under two items, and its Current and Proposed text as whole paragraphs in code blocks that did not wrap, even when only a phrase changed. Before the view was mechanical, the session summarised items itself, and its summaries were unreliable.

So `check` renders each material item as one entry of a numbered list: its summary, a one-line reason the session writes as `@@ why` and `check` requires, its findings cited by lens and number, and its edit as a word diff with five words of context. A diff of more than 40 changed words collapses to one line naming its size. `check --full <n>...` prints the named items as before, and the human asks for them through the batch question. The changelog still tags only minor items: a material edit's wording is still shown, as a diff, and a separate tag for a collapsed diff was rejected.

## Considered Options

- **The session writes a free summary of each item.** Rejected: that was the unreliable view this replaced.
- **Summary only, no wording.** Rejected: most material edits are short, and the human should read their wording.
- **Keep the full view and only indent it.** Rejected: the length came from the full text, not from the layout.
