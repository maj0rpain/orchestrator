---
name: orch-release
description: Open the release PR that carries the base branch back into the default branch, closing every still-open issue whose work reached the base branch. Use when the human asks to release the base branch (for instance a uat or feature branch), or runs /orchestrator:release.
---

# Orchestrator release

Opens a **release PR** (see `CONTEXT.md`): the PR that carries a base branch
other than the default back into the default branch. PRs into that base
branch only refer to their issues (`Refs #N`), so this PR is the one that
closes them. `orch.sh pr release` decides which issues those are, from the
bodies of the PRs merged into the base branch. You write the title and the
summary, and nothing else.

On a host with no plugin commands, the human reaches this skill by asking for
a release rather than running `/orchestrator:release`.

`orch.sh` resolves as:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

This skill needs no capability beyond running shell commands.
`docs/host-capabilities.md` under the plugin root maps the others to each host.

## 1. Resolve the base branch

Run `"$ORCH" base show`. It prints `<branch> (set)` or `<branch> (default)`.
If the source is `default`, stop: there is nothing to release, because work
already lands on the default branch. Tell the human they can set another base
branch with `"$ORCH" base set <branch>`.

Run `"$ORCH" default-branch` to name the default branch.

## 2. Write the title and summary

Read what the release carries, for instance with
`git fetch origin` and `git log --oneline origin/<default>..origin/<base>`.

- **Title:** short, naming the base branch and what the release delivers,
  e.g. `Release uat: base branch setting and release PRs`.
- **Summary:** a body file (a temp file outside the repo) with a few lines on
  what is being released, grouped by theme.

Never write `Closes`, `Fixes`, `Resolves` or `Refs` lines into the summary.
`pr release` writes one `Closes #N` line per issue above your body, and it is
the only source of that list, so no issue can be dropped from it.

## 3. Open the release PR

Run `"$ORCH" pr release "<title>" <body-file>`. Add `--force` before the title
only when the human has explicitly asked to release even though nothing would
be closed. Never add it on your own after a refusal.

On success it prints the PR number. The PR is opened ready for review, not as
a draft. It pushes nothing, because the base branch is already on `origin`.

## 4. Report

- **Opened:** give the PR number, and the issues its body closes.
- **Refused:** relay the reason `pr release` printed and stop. It refuses when
  the base branch is the default branch, when a release PR from the base
  branch is already open (it prints that PR's number, so point the human at
  it), and when no PR merged into the base branch refers to a still-open issue.
  In the last case, say that `--force` opens the release PR anyway, and use it
  only if the human asks.

Leave the base branch setting alone. Clearing it after the release PR merges
is the human's call (`"$ORCH" base clear`).
