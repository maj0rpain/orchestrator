# Issue tracker: GitHub

Issues and specs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

Resolve the repo first, and pin every `gh` call to it with `-R`, never to `gh`'s default repo: `repo="$(bash "<orch.sh>" repo show --name)"`. When `repo show` fails, stop: an empty `-R` would fall back to the default. Every recipe in this file assumes `$repo` is set this way.

- **Create an issue**: `gh issue create -R "$repo" --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> -R "$repo" --json title,body,labels,comments > <file>`, into a temporary file outside the repo (`mktemp`), then read that file, filtering comments by `jq`. Piped, `--comments` prints only the comments, without the title and body.
- **List issues**: `gh issue list -R "$repo" --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> -R "$repo" --body "..."`
- **Apply / remove labels**: `gh issue edit <number> -R "$repo" --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> -R "$repo" --comment "..."`

Do not infer the repo from `git remote -v` or leave it to `gh`: `orch.sh repo show --name` is the one answer (see **Repo** in `GLOSSARY.md`).

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set to `yes` if this repo treats external PRs as feature requests; `/triage` reads this flag.)_

When set to `yes`, PRs run through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> -R "$repo" --json title,body,comments > <file>`, into a temporary file outside the repo (`mktemp`), then read that file, and `gh pr diff <number> -R "$repo"` for the diff.
- **List external PRs for triage**: `gh pr list -R "$repo" --state open --json number,title,body,labels,author,authorAssociation,comments` then keep only `authorAssociation` of `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, or `NONE` (drop `OWNER`/`MEMBER`/`COLLABORATOR`).
- **Comment / label / close**: `gh pr comment -R "$repo"`, `gh pr edit -R "$repo" --add-label`/`--remove-label`, `gh pr close -R "$repo"`.

GitHub shares one number space across issues and PRs, so a bare `#42` may be either: resolve with `gh pr view 42 -R "$repo"` and fall back to `gh issue view 42 -R "$repo"`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> -R "$repo" --json title,body,comments > <file>`, into a temporary file outside the repo (`mktemp`), then read that file.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue with **child** issues as tickets.

- **Map**: a single issue labelled `wayfinder:map`, holding the Notes / Decisions-so-far / Fog body. `gh issue create -R "$repo" --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`/`prototype`/`grilling`/`task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: GitHub's **native issue dependencies**, the canonical, UI-visible representation. Add an edge with `gh api --method POST repos/$repo/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`, where `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/$repo/issues/<n> --jq .id`, _not_ the `#number` or `node_id`). GitHub reports `issue_dependencies_summary.blocked_by` (open blockers only, the live gate). Where dependencies aren't available, fall back to a `Blocked by: #<n>, #<n>` line at the top of the child body. A ticket is unblocked when every blocker is closed.
- **Frontier query**: list the map's open children (`gh issue list -R "$repo" --state open`, scoped to the map's sub-issues / task list), drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) or an assignee; first in map order wins.
- **Claim**: `gh issue edit <n> -R "$repo" --add-assignee @me`, the session's first write.
- **Resolve**: `gh issue comment <n> -R "$repo" --body "<answer>"`, then `gh issue close <n> -R "$repo"`, then append a context pointer (gist + link) to the map's Decisions-so-far.
