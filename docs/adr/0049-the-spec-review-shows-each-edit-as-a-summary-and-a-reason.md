# The spec review shows each edit as a summary and a reason

Supersedes ADR-0048 in part: a material item no longer shows its word diff or the findings it cites, and the batch question's Other answer may also be a free-text question, which names no departure. Supersedes ADR-0047 in part: the changelog no longer tags the minor items applied by the human's answer. Supersedes ADR-0044 in part: a material edit may change the issue after the human has read only its summary and reason.

Superseded in part by ADR-0051: the batch question is no longer asked with the ask tool, so its Other answer forms - a departure list, `show <n>`, a question - are typed as the reply to a turn-final plain-text question.

The word diffs still made the view long enough to read as noise, and the human decided from the summaries anyway, asking for more when they needed it. So each material item is one line, its summary and its reason, and a decision item adds one line per option. `check` refuses a summary of more than 30 words, and the skill asks for one sentence stating what the spec will say after the edit. `show <n>` prints items in full, and a free-text question is answered in chat before the batch question is asked again. With every item now shown as a summary, a tag marking the ones applied unread would mark them all, so it is dropped.

## Considered Options

- **Keep the word diff, drop only the citations.** Rejected: the diff was the bulk of the noise.
- **Summary only, no reason.** Rejected: the reason is what the human weighs the edit by.
