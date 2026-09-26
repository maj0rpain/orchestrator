# Changelog

## 1.5.1

A failing full verification is recorded in the implement handoff's
**Verification** section, not under **Deviations** (see issue #184).

- `orch-flow`'s implement phase writes the verification command, its result,
  and on a `fail` the ticket that reported it, all under **Verification**.
- **Deviations** holds only the tickets' reported deviations, as the handoff
  template defines it. The review loop still treats a failure as blocking.

## 1.5.0

`orch-implementer` finds its spec issue through `orch.sh` instead of calling
the sub-issue endpoint with `gh api` itself (see issue #179).

- New `orch.sh ticket parent <n>` prints a sub-issue's parent issue number, or
  nothing when the issue has no parent, and fails on any gh error.
- The implementer's prompt is now two lines, the ticket number and the path of
  the plugin's `orch.sh`, the same way `orch-closer` receives it. The same
  path serves its `mp-skill tdd` route on a host with no Skill tool, and the
  dispatching skill records that fallback.

## 1.4.2

The closer files only what its own review loop left unfixed, and the driver's
triage is the one owner of the already-filed rule (see issue #164, covering
#172 and #158).

- `orch-closer` gets a **Loop boundary** in its prompt and gathers majors and
  nits only from records numbered above it, leaving earlier loops' records
  alone.
- A finding a later iteration of the same loop fixed is no longer filed.
- The closer no longer checks **Filed** lists itself; it sets aside only what
  triage marked met again.
- **Filed** entries read `#<n> <severity>: <file>:<line> <title>`, and triage's
  **Met again** matches on file, line, and claim instead of the title alone.
  An older entry with no file and line is matched on its title against the
  finding's claim.
- ADR-0020 records the decision and supersedes ADR-0017 in part.

## 1.4.1

Starting a plugin agent is defined once (see issue #181).

- `docs/host-capabilities.md`'s **Start a fresh subagent** fallback is the one
  definition of how a plugin agent is started on a host that cannot start it
  natively: first a fresh general-purpose agent briefed with the agent's file,
  then in-session work that takes the host fallback for any capability the
  brief names. `orch-review`, `orch-flow`, and `orch-quick-implement` point at
  it and keep only where they record the fallback.
- The implement phase and quick implementations now take that first tier too,
  instead of going straight to in-session work on a host that has fresh
  subagents but does not load the plugin's `agents/`.
- `orch-implementer`'s dispatch contract lives once, in the **Starting this
  agent** section of `agents/orch-implementer.md`.

## 1.4.0

Ticket subagents run as the plugin's own `orch-implementer` agent and no
longer review their own work (see issue #176 and
`docs/adr/0019-ticket-subagents-check-acceptance-criteria-and-leave-review-to-the-loop.md`).

- The implement phase and quick implementations start `orch-implementer`
  with only the ticket number. It builds the ticket test-first through
  `mattpocock-skills:tdd`, commits, checks its commits against the ticket's
  acceptance criteria, and returns five lines: `Ticket`, `Commits`,
  `Verification`, `Criteria`, `Deviation`.
- Its tools are Read, Edit, Write, Grep, Glob, Bash, and Skill: it cannot
  start sub-agents or ask the human a question. Per-ticket
  `mattpocock-skills:code-review` is gone; the review loop reviews the whole
  change. Quick implementation's own single-pass review is unchanged.
- `03-implement.md`'s **Already found and fixed** section is now **Unmet
  criteria**: the criteria the ticket subagents reported unmet, for the review
  loop's Spec axis to judge. The implement phase assembles it, **Deviations**,
  and **Verification** from the reports.

## 1.3.0

The review loop's driving session hands its work to fresh plugin agents, so
a loop stays within its context budget (see issue #149,
`docs/adr/0017-the-review-loops-driver-hands-fixing-and-filing-to-fresh-agents.md`
and `docs/adr/0018-the-review-loop-owns-its-reviewer-briefs.md`).

- The plugin ships an `agents/` directory with four agents:
  `orch-reviewer-standards`, `orch-reviewer-spec`, `orch-fixer`, and
  `orch-closer`.
- Two reviewer agents replace `mattpocock-skills:code-review` in the review
  loop. They have no Edit or Write tool, and each writes its report to a file
  and returns one line. The implement phase and quick implementations still
  use `code-review`.
- A fixer is started at most once per iteration, only when triage leaves
  something to fix. It fixes, verifies, commits, pushes, and writes that
  iteration's review record; on a clean iteration the driver writes it. A
  closer is started once at termination to file the unfixed findings and
  comment on the PR. The driver triages, waits on CI, and decides the
  terminal state, and never edits the change.
- `orch.sh handoff section <file> <heading>` prints one section of a handoff,
  so the driver reads only what it needs.
- "Junie" means the Junie CLI throughout the docs. `orch.sh doctor` reports
  the host as `Junie CLI`, and a fresh subagent there is now unverified, not
  missing: the Junie CLI documents custom subagents, but loading them from a
  plugin's `agents/` is unconfirmed (#148). The inline fallback stays.

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
