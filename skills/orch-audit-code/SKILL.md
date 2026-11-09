---
name: orch-audit-code
description: Audit a repo's source code for latent bugs, inefficiencies and architecture worth deepening - scope git hot spots or a named direction, partition it into areas, hunt each area in a fresh read-only orch-code-auditor subagent (at most 4 at once), rank the candidates, show an HTML report, and hand picked findings to orch-interview, to orch.sh audit file, or both. Read-only. Use when the user asks to audit the code, find latent bugs, inefficiencies or architecture to deepen, or runs /orchestrator:audit-code.
---

# Orchestrator audit code

Reads a repo's source code for latent bugs, inefficiencies and architecture
worth deepening (see `GLOSSARY.md`: **Code audit**), which the review sees only
where a change touches. It ships for any repo. The six steps below define this
skill, and it invokes and depends on no upstream skill (ADR-0028).

**Read-only.** This skill changes no file in the repo: it edits nothing,
commits nothing, and opens no branch or PR. Every file it writes - the
subagents' findings files, the report, and the finding file for each finding
picked for filing - goes in one temp directory outside the repo (make it with
`mktemp -d`). Its one write outside that directory is `orch.sh audit file`,
for findings the user picks for filing. The promise covers the audit itself:
once it hands picked findings to `orch-interview`, what that interview and the
flow, quick implementation or blueprint it closes on write is theirs.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths. If it prints nothing, `ORCH` is
`scripts/orch.sh` two directories above this skill's own directory (the plugin
root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Steps here name capabilities (start a fresh subagent, open a report in the
browser, invoke a skill from a step, ask a multiple-choice question).
`docs/host-capabilities.md` under the
plugin root maps each one to your host. Where your host's cell says
**Fallback**, or **Unverified** and the capability turns out missing, take
the fallback it documents and tell the user which.

## 1. Scope

- **A named direction.** When the user names one - a directory, a file, a
  feature, "bugs in the review loop" - that is the scope. Naming kinds in it
  (latent bugs, inefficiencies, architecture deepenings) narrows the hunt to
  those kinds.
- **Git hot spots.** Otherwise the scope is the source files changed most
  often in the last 90 days (for instance `git log --since=90.days.ago
  --name-only --pretty=format:`, counted by file), so improvements land where
  code keeps changing.

Test files are never candidates, so this audit does not overlap
`orch-improve-tests`; a hunter may still read them as evidence. Say the scope
and the kinds in one line.

## 2. Partition

Split the scope into **areas**: each is a set of source files given to one
subagent, holding at most about 40 source files. Before any subagent starts,
state the area count.

With more than 8 areas, ask the user to confirm or narrow the scope as a
blocking question (host capability *Ask a multiple-choice question*), and
start nothing until they answer. A narrowed scope returns to this step.

## 3. Hunt

Read `bash "$ORCH" agent get auditor` once, before the first hunter, and pass
the `model` and `effort` it prints on each start, per **Agent settings** in
`docs/host-capabilities.md`. This skill runs no `agent sync`, which would write
`.junie/agents/` in the checkout (ADR-0060). Start one fresh subagent per area
(see the *Start a fresh subagent* row of `docs/host-capabilities.md`), never a
fork, each an `orch-code-auditor`, at most 4 at once; start the next as one
finishes. Each prompt names its area (the source files), the kinds to hunt, the
repo root, and its own findings file in the temp directory. The auditor has no
Edit or Bash tool; its brief holds the three kinds, the evidence each needs,
the ADR rule and the findings-file format (`@@ finding <k>` blocks, `@@ none`
when empty). A reply is the file's path and a finding count; read each file.

A candidate has its kind, its location(s), its evidence, its confidence
(**certain** or **likely**), a before/after and a proposed fix. A pattern
finding lists every site. The evidence per kind:

- **Latent bug**: a failure scenario - a concrete input or state, and the code
  path to a wrong output or crash, quoted with file and line.
- **Inefficiency**: the repeated or avoidable work, and how often it runs per
  call or per loop, quoted from the code. No timing.
- **Architecture deepening**: the friction point, the deletion test, and a
  before/after of the interface.

**ADR rule**: an ADR is never edited or proposed for editing. An architecture
candidate that goes against an ADR appears only when the friction is concrete,
and then as an **ADR decision item**: its fix states both options (a new ADR
amending it, or a code change) and recommends neither.

## 4. Rank

Re-read the code for every candidate yourself and drop any you cannot confirm;
a latent bug without a confirmed failure scenario never reaches the report.
Merge duplicates that areas reported separately into pattern findings. Group
the rest in this order: latent bugs, then inefficiencies, then architecture
deepenings, then ADR decision items last. Number every candidate in one
sequence. Within a group, **certain** ranks above **likely**. Give each a
strength (**strong**, **worth it** or **marginal**), and name one **top
recommendation**: the candidate to start with, and why.

## 5. Report

Write a self-contained HTML report to the temp directory (for instance
`"$TMP/audit-code.html"`). It loads Tailwind and Mermaid from a CDN and holds
everything else inline. It carries the scope, the area count, the top
recommendation first, and every candidate numbered in rank order, each with its
kind, location, evidence, confidence, strength, before/after and proposed fix.

Open it in the browser - `xdg-open <file>` on Linux, `open <file>` on macOS -
and tell the user its path. On a host that cannot open it, write a Markdown
summary in chat instead: the scope, the top recommendation, and one line per
candidate.

## 6. Hand off

Ask which findings to take forward, as a **turn-final reply**, per
`docs/turn-final-reply.md` under the plugin root: step 5's Markdown summary -
or, where the report opened in the browser, its path - and then the pick
question with its answers spelled out:

- `interview <numbers>`
- `file <numbers>`
- both, separated by `;` (e.g. `interview 2,5; file 3,7`)
- `none`

Numbers are comma-separated, and a number may not appear in both lists. Any
other reply is a **near-miss reply** (the doc's **Near-miss reply**), restated
in one line, e.g. "Take findings 2 and 5 to the interview and file 3 and 7".
Nothing is picked on a guess. On *No*, or on a clear question, the doc's
**Question path** runs: pick nothing, and end the turn again on the summary,
or the report's path, and the pick question.

With both lists, filing runs first, then the interview.

- **File.** For each finding picked for `file`, one at a time in number
  order, write its text (kind, evidence, confidence, strength, before/after,
  proposed fix) to a finding file in the temp directory and run
  `bash "$ORCH" audit file "<title>" --category <bug|enhancement>
  --finding-file <file> --location
  <location>...`, one `--location` per site: `--category bug` for a latent
  bug, `--category enhancement` for an inefficiency or an architecture
  deepening (an ADR decision item is an architecture deepening). It prints the
  issue number; when an open issue already has that title it files nothing and
  says so on stderr. Report the issue numbers, naming any that was already open
  rather than newly filed. A filing that fails stops the step: report the
  numbers already filed (they stay filed), the failure, and the findings not
  filed, and do not start the interview.
- **Interview.** Invoke `orch-interview` with the findings picked for
  `interview` together, as one change to plan, each with its location,
  evidence, before/after, and proposed fix. The interview ends in a flow, a
  quick implementation or a blueprint, like any other change.

On `none`, stop: this skill has changed nothing.
