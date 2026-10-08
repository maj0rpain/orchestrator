# A helper for the plain-issue-number guard

This project does not extract a helper for the one line that refuses an issue
number that is not a plain number, even though many `scripts/orch.sh` command
functions repeat it: `init --issue`, `issue ready`, `spec-review begin`,
`review-pass begin`, `finding-triage scan` and `apply`, `issue triage`, `pr
publish`, `ticket_sub_issues`, `ticket publish`, `ticket close`, `ticket
parent` and `ticket_edges_change`.

## Why this is out of scope

Each copy is a single line, and a helper would not shorten it. The copies also
differ: each names its own command's usage or context in the message, and some
die with `die` (exit 1) while `issue ready` dies with `die2` (exit 2). A helper
would need a mode argument and a message parameter, and would replace one line
with one call that a reader must look up to learn what the inline form already
shows. Coding-standards section 1 rules that out.

```sh
# what each command carries today - the check, the message and the exit in one place
case "$1" in ''|*[!0-9]*) die "issue must be a plain issue number, got: $1 ($usage)" ;; esac
```

The PR, iteration, redo and ticket-number guards check a different kind of
number and are not part of this list.

This fits the file's transaction-script style (see
`command-function-decomposition.md`) and the same reasoning as
`current-branch-helper.md`: a command function shows its whole precondition
check in place.

Reconsider if the guard grows beyond one line, for example into a remedy hint
shared by every caller. Keeping many multi-line copies in step would then cost
more than the lookup does.

## Prior requests

- #773: "the new `fetch)` arm copies the plain-issue-number guard and usage-error die from the `update|comment|comments` arm" - filed by the review loop as a Standards-axis major against PR #742. The duplication between those two arms was removed by merging them; the cross-command helper was declined in #849.
