# A `current_branch` helper for the detached-HEAD refusal

This project does not extract a helper for the one line that reads the current
branch and refuses a detached HEAD, even though several `scripts/orch.sh`
command functions repeat it word for word.

## Why this is out of scope

The duplicated code is a single line, and a helper would not shorten it.
Each call site would still need a line, `branch="$(current_branch)"`, and a
reader would then have to look up the helper to learn two things the inline
form already shows: which git command runs, and that the command dies on a
detached HEAD.

```sh
# what each command function carries today - the git call and the refusal in one place
branch="$(git symbolic-ref --quiet --short HEAD)" || die "not on a branch (detached HEAD)"
```

This fits the file's transaction-script style (see
`command-function-decomposition.md`): a command function shows its whole
precondition check in place. The line is also unlike the rejected helpers in
`shared-cleanup-helper-extraction.md` and `shared-gh-state-fetch-helper.md`.
There the callers behaved differently. Here the copies are identical, but
there is too little code to be worth pulling out.

Reconsider if the refusal grows beyond one line, for example into a remedy
hint or a special case for the default branch. Keeping several multi-line
copies in step would then cost more than the lookup does.

## Prior requests

- #247: "cmd_quick, cmd_branch_base_sha and cmd_pr_publish carry three copies of the current-branch/detached-HEAD line; a current_branch helper would collapse them" - filed by the review loop as a Standards-axis nit against PR #246.
