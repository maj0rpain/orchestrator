# Side checkouts live inside the repo, and finished ones are swept

Supersedes in part ADR-0008: its "a second flow gets a worktree, not a key" holds. Its sibling directory, its checking the worktree out on the base branch, its claim that removal refuses on unpushed state, its "nothing new to remember" cleanup, and its telling the plugin's own worktree by a flow's state file do not.

ADR-0008 planned a second flow's worktree as a directory beside the repo. That litters the folder that holds the human's repos, one directory per flow. A side checkout instead lives under the repo's own `.orchestrator/checkouts/`, which is already excluded from git. ADR-0036 already nests ticket worktrees under `.orchestrator/`, rejecting sibling directories because a subagent editing outside its session's project folder draws a prompt on every edit. A side checkout gets a session of its own, so the prompts do not apply; it nests to keep the human's folder of repos clean. Archiving the main checkout's flow skips `checkouts/`, so it never moves a live worktree.

A side checkout starts on no branch, at the base branch's tip on origin, because git refuses to check out one branch in two worktrees and the main checkout usually holds the base branch. A marker file in the worktree's own git directory, which git removes with the worktree, is what makes it a side checkout. The presence of a flow's state file is not, since a hand-made worktree can hold a flow too. The plugin never removes a worktree without the marker, and never sweeps a flow in a worktree a human made; the main checkout's own flow stays the plugin's to archive, as it is today.

`git worktree remove` deletes ignored files, `.orchestrator/` among them, so archiving in a side checkout moves the flow's files to the main checkout's archive before removing the worktree. It never uses force: a dirty worktree is reported and kept. It does not refuse on unpushed commits, but the flow's branch survives removal, so they are kept.

Quick implementations get side checkouts too. `branch off` refuses beside a flow mid-pipeline as `init` does, and a human can ask for one where no check could see the need, such as a second quick implementation, which keeps no state.

## Consequences

Cleanup is one command, `/orchestrator:finish`. It sweeps every side checkout whose work is finished: archive, remove, and delete its local branch with `-D`. The same sweep runs at the start of every `side-checkout add`, so forgetting the command cannot pile side checkouts up. Finished is read from GitHub's PR state, not git ancestry, because a squash or rebase merge never makes the branch an ancestor of its base. The same fact makes `-D` safe where `-d` would refuse. GitHub unreachable means nothing is removed. A finished flow in the main checkout is archived in place, and its branch is left checked out. `doctor --flow`'s dirty-tree check, which ADR-0008 planned for any change, fails only on changes outside the planning allowlist, since planning's own edits may still be uncommitted when the spec phase starts.

## Considered Options

- **Sibling directories beside the repo** (ADR-0008's plan). Rejected: they clutter the human's folder of repos.
- **Sweeping at every session start.** Rejected: a GitHub call on every session start, and it could remove a side checkout a still-open session is working in.
- **Archiving a hand-made worktree's finished flow.** Rejected: the marker is the line between what the plugin manages and what the human does.
