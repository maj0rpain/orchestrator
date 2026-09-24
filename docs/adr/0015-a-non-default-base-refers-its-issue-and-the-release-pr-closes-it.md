# A non-default base refers its issue and the release PR closes it

A flow or quick implementation can now fork from and target a **base branch**
other than the default, such as `uat` or a long-running feature branch. Every
orchestrator PR used to open with `Closes #N`, but GitHub only acts on a
closing keyword when the PR merges into the default branch. A PR into `uat`
leaves its issue open, and so does the eventual `uat -> main` PR, because only
that PR's own body counts. Keeping `Closes` would make the PR claim something
it never does, and leave the human remembering which issues went into `uat`.

We decided that a PR into a non-default base branch says `Refs #N`, and a
**release PR** (`orch.sh pr release`, `/orchestrator:release`) carries the
base branch into the default branch with one `Closes #N` line per
still-open issue. The script builds that list when the command runs, from
the bodies of every PR merged into the base branch (`Refs`, `Closes`, `Fixes`
or `Resolves`, anywhere in the body), so hand-opened PRs count too. An issue
therefore stays open until its work reaches the default branch, which is
what "closed" should mean.

## Considered Options

- A GitHub Action that closes an issue when its PR merges into the base
  branch. Rejected: it closes issues before the work ships, and it installs
  workflow files in the user's repo, which orchestrator otherwise never
  touches.
- A tracking label on each issue whose work went into the base branch, read
  back at release time. Rejected: it is extra state that can drift from what
  actually merged, where the merged PR bodies are the record itself.

## Consequences

PRs into the default branch are unchanged and still say `Closes #N`. The
`Refs` line on every other PR is deliberate, not a missed closing keyword.
Issues stay open while their work sits on the base branch, and the release
PR's body is written by the script, not the model, so no issue drops off the
list. `pr release` reads PR bodies rather than GitHub's
`closingIssuesReferences`, because GitHub only links closing keywords on PRs
into the default branch and never links a `Refs` line.
