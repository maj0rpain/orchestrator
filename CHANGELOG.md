# Changelog

## 1.2.0

The review loop now fixes what needs no decision, not only what is blocking
(see issue #146 and
`docs/adr/0016-the-review-loop-fixes-what-needs-no-decision.md`).

- A major is fixed unless its fix needs a choice the plan, spec, and
  deviations did not settle, or would change behaviour. A nit is fixed only
  when it is mechanical. Everything else is filed, as before.
- A major or nit on lines the current loop's own fix commits wrote is filed,
  never fixed, and the final iteration fixes only what is blocking.
- A filed issue's "why not fixed" line names the rule that kept it out of the
  loop. Findings a previous loop already filed are left alone and listed for
  the human in the PR comment.
- `orch.sh review file`'s rejection of `blocking` no longer says the loop
  fixes blocking only.

## 1.1.1

The plugin no longer relies on its scripts' execute bit, which some hosts
(Junie) drop on install or update, so the first hook failed with `Permission
denied` (see issue #142 and `docs/host-capabilities.md`, "Execute bit").

- `hooks/hooks.json` runs all three hooks through `bash`.
- Every skill, the README and host capabilities run `bash "$ORCH" …` instead
  of `"$ORCH" …`.
- `scripts/test/hooks_test.sh` fails if a hook command skips `bash`, and runs
  each hook at mode 644. `scripts/test/orch_test.sh` fails if a skill,
  command, guideline, the README or host capabilities runs `orch.sh` without
  `bash`.

## 1.1.0

Flows and quick implementations can now work against a **base branch** other
than the default, such as `uat` or a long-running feature branch, and a
**release PR** carries it back into the default branch (see issue #135 and
`docs/adr/0015-a-non-default-base-refers-its-issue-and-the-release-pr-closes-it.md`).
With nothing set, every fork and PR works exactly as before.

- `orch.sh base set <branch>`, `base show` and `base clear` set, print and
  remove the base branch. `base set` refuses a branch `origin` does not have.
  The setting lives in the clone's local git config (`orchestrator.base`): it
  is shared by every worktree, never committed, and kept through `abort` and
  archiving.
- A flow records its base branch in `state.json` at `init`, and `branch
  create` and `pr open` fork from and target it, so changing the setting
  mid-flow never moves that flow's PR. A flow started before this release
  uses the default branch.
- `branch off` forks a quick implementation from the base branch and records
  it on the branch (`branch.<name>.orchestrator-base`), and `pr publish`
  targets it.
- Forking stops with an error when `origin` says the base branch does not
  exist, and falls back to the local copy only when `origin` can't be reached.
- A PR into the default branch still starts with `Closes #N`. A PR into any
  other base branch starts with `Refs #N`, since GitHub would not close the
  issue on merge anyway.
- `orch.sh pr release [--force] <title> <body-file>` and
  `/orchestrator:release` (skill `orch-release`) open the release PR: a
  non-draft PR from the base branch into the default branch, with one
  `Closes #N` line per still-open issue referenced by any PR merged into the
  base branch. It refuses on the default branch, while a release PR is
  already open, and with nothing to close unless `--force`.
- `status` prints a `base:` line for the active flow.
- `doctor` reports the base branch in effect and where it came from, FAILs
  when a set base branch is gone from `origin`, and warns when `origin` can't
  be reached to check.

## 1.0.0

Breaking: every orchestrator skill now carries an `orch-` prefix, whatever the
host (see `docs/adr/0014-orchestrator-skills-carry-an-orch-prefix.md`). Bare
skill names collide on hosts that list skills without a plugin namespace, such
as Junie, where orchestrator's `handoff` shadowed mattpocock's.

Migration - update any muscle memory, notes, or scripts that name a skill:

| Old name                       | New name                            |
| ------------------------------ | ----------------------------------- |
| `orchestrator:flow`            | `orchestrator:orch-flow`            |
| `orchestrator:handoff`         | `orchestrator:orch-handoff`         |
| `orchestrator:review`          | `orchestrator:orch-review`          |
| `orchestrator:review-spec`     | `orchestrator:orch-review-spec`     |
| `orchestrator:quick-implement` | `orchestrator:orch-quick-implement` |

The slash commands (`/orchestrator:start`, `/orchestrator:next`, and so on) are
unchanged. The skill directories moved from `skills/<name>/` to
`skills/orch-<name>/`.

A flow started on 1.0.0 needs a `## Host fallbacks` section in every handoff
(`01-plan.md`, `02-spec.md`, `03-implement.md`), and `handoff validate` /
`doctor --flow` fail without one. A flow already under way when you upgrade is
exempt, so it finishes as it would have on 0.x.

Also new in 1.0.0 (see issue #121):

- Junie is supported as a second host. `docs/host-capabilities.md` maps each
  capability the skills rely on to each host, with documented fallbacks.
- Skills find `orch.sh` relative to their own directory when
  `CLAUDE_PLUGIN_ROOT` is unset.
- mattpocock-skills are found in Claude's plugin cache, Junie's extension
  cache, or the `skills` CLI store (`~/.agents`), or wherever
  `ORCHESTRATOR_MATTPOCOCK_ROOT` points.
- `orch.sh init` refuses to start a flow while the working tree has changes
  outside the planning allowlist.
- Doctor reports the detected host (override with `ORCHESTRATOR_HOST`) and the
  capabilities it lacks.
- `guidelines/orch-planning.md` carries the planning nudge on Junie.
