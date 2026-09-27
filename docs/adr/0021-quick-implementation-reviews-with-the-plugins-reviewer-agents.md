# Quick implementation reviews with the plugin's reviewer agents

Supersedes ADR-0018's note, added alongside ADR-0019, that quick
implementation's single pass still uses `code-review`. After this, nothing in
the plugin invokes `mattpocock-skills:code-review`.

Quick implementation's single pass starts the same two agents the review loop
does, `orch-reviewer-standards` and `orch-reviewer-spec`, with the same
four-variable prompt: the base SHA `branch off` now records, the linked issue
as the spec issue, iteration `01`, and a report path under a per-branch
directory `orch.sh` hands out. It is still one pass: the quick session fixes
what it agrees with itself, lists what it declines in the PR body, and files
nothing. A reviewer that fails twice stops the run before the PR opens, since
an axis nobody looked along is not a reviewed change.

ADR-0018 and ADR-0019 moved the loop and the ticket subagents off
`code-review` and left quick implementation on it by omission, not by
decision. That left two routes to a PR judging "reviewed" against different
Standards baselines: the loop against the plugin's pinned copy of the smell
baseline, quick implementation against whatever upstream version is
installed. The cost argument that drove ADR-0018 is weaker for one pass; the
deciding reason is that both routes should mean the same thing by reviewed.
Owning the reviewers here also takes Edit and Write away from them by their
tool list, and removes the ambiguous-name workaround the review step needed
for `code-review`.

The trade-off: quick implementation no longer tracks upstream `code-review`.
A change there reaches it only when someone copies it into the reviewer
briefs, as it already does for the loop.

## Considered Options

- **Keep `code-review` and write down why.** Rejected: it keeps two meanings of
  reviewed, and the upstream skill's cost and name ambiguity, for no gain
  specific to quick implementation.
- **Choose per host or by setting.** Rejected: adds a branch and settles
  nothing.
- **Fall back to `mp-skill code-review` where the agents cannot start.**
  Rejected: brings back the baseline drift on exactly the hosts least likely
  to be checked. The general-purpose-agent fallback the loop uses applies
  instead.
- **Compute the base SHA as a merge-base at review time.** Rejected as the
  primary source: a base merged in mid-branch silently shrinks the reviewed
  diff. Kept only as the fallback for branches made before `branch off`
  recorded the SHA.
