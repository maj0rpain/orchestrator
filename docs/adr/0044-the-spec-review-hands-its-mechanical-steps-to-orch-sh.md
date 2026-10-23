# The spec review hands its mechanical steps to orch.sh

Supersedes ADR-0030 in part: `orch.sh` now leaves the review's own changelog
comments out of the comments file, so the session no longer skips them itself.

Superseded in part by ADR-0047: a minor edit may change the issue after the
human has read only its one-line summary.

Superseded in part by ADR-0048: a material edit rewritten past the diff's limit
may change the issue after the human has read only its summary and reason.

Superseded in part by ADR-0049: a material edit may change the issue after the
human has read only its summary and reason.

A spec review's session used to apply each accepted edit by hand, retyping old
and new text one tool call at a time, write the changelog by hand, and read
every earlier round's changelog among the issue's comments. Each step needed no
judgement, but each was a turn that re-read the session's whole context.
Measured over 54 reviews, the step after the batch answer cost about as much as
discovery.

So the session now keeps only the judgement: consolidation, the disposition, and
the wording of each edit. It writes the batch once to a batch file, with an
exact anchor and replacement per edit. `orch.sh spec-review apply` takes the
human's answer as given, applies the accepted items, follows the tickets,
publishes the body, and writes and posts the changelog in one call, pausing once
for the ticket question when an edit touches an issue that has a ticket
breakdown. It refuses the whole batch if any accepted anchor does not match
exactly once. Each lens writes its findings to its own file, and the batch file
cites them instead of quoting them. The comments file leaves out the review's
own `## Spec review` comments.

## Considered Options

- **A fresh subagent applies the edits.** Rejected: cheaper turns, but the text
  is still retyped and the step stays untested.
- **Instruct the session to apply every edit in one scripted call.** Rejected:
  it shrinks the turn count only, and it drifts.
- **Show the human only a summary of each edit, with the wording in the file.**
  Rejected: only edits a human has read may change the issue.
- **Apply the edits that match and report the rest.** Rejected: the body and the
  changelog would disagree.
