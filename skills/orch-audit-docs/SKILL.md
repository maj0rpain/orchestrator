---
name: orch-audit-docs
description: Audit a repo's documentation against its code - scope the whole repo or a named path or direction, partition it into areas, hunt each area in a fresh read-only orch-doc-auditor subagent (at most 4 at once), rank the disagreements, show an HTML report, and hand picked findings to orch-interview, to orch.sh audit file, or both. Read-only. Use when the user asks to audit docs, find stale or drifted documentation, or runs /orchestrator:audit-docs.
---

# Orchestrator audit docs

Reads a repo's documentation against its code and reports where the text says
something the code does not do. It is the repo-wide counterpart of the
Standards reviewer's **doc-agreement check** (see `GLOSSARY.md`: **Docs
audit**), which sees only what one change touches. It ships for any repo. The
six steps below define this skill, and it invokes and depends on no upstream
skill (ADR-0028).

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

- **A named path or direction.** When the user names one - a directory, a
  file, "the review loop's skills" - that is the scope.
- **The whole repo.** Otherwise the scope is the whole repo, not hot spots:
  drift builds up in docs nobody touched.

The texts covered are exactly the doc-agreement check's: prose docs (README,
`docs/`, CONTRIBUTING, the glossary, ADRs), comments and docstrings, and agent
and skill instruction files. Say the scope in one line.

## 2. Partition

Split the scope into **areas**: each is a set of docs plus the code they
describe, given to one subagent, holding at most about 40 doc- or
comment-bearing files. Before any subagent starts, state the area count.

With more than 8 areas, ask the user to confirm or narrow the scope as a
blocking question (host capability *Ask a multiple-choice question*), and
start nothing until they answer. A narrowed scope returns to this step.

## 3. Hunt

`orch-doc-auditor` has no role, so it has no agent setting: this skill reads
no `agent get` and runs no `agent sync`. Start one fresh subagent per area
(see the *Start a fresh subagent* row of `docs/host-capabilities.md`), never a
fork, each an `orch-doc-auditor`, at most 4 at once; start the next as one
finishes. Each prompt names its area (the docs to read and the code they
describe), the repo root, and its own findings file in the temp directory. The
auditor has no Edit or Bash tool; its brief holds the method (doc-claim
driven), the finding fields and the ADR rule. A reply is the file's path and a
finding count; read each file.

A finding has its kind of text, its location (file and line), the doc passage,
the code it disagrees with, its confidence (**certain** or **likely**) and a
proposed fix. A pattern finding lists every site. **ADR rule**: an ADR is
never edited or proposed for editing; a contradicted ADR passage is a
**decision item** for a human, to amend the ADR with a new ADR or change the
code.

## 4. Rank

Read each finding yourself and drop any whose disagreement you cannot confirm
against the code. Merge duplicates that areas reported separately into pattern
findings. Group the rest by kind of text, in this order: agent and skill
instruction files, then glossary and prose docs, then comments and docstrings.
ADR decision items form a separate group ranked last, numbered in the same
sequence as every other finding; a decision item's proposed fix states both
options and recommends neither. Within a group, **certain** ranks above
**likely**. Number every finding in rank order, and name one **top
recommendation**: the finding to start with, and why.

## 5. Report

Write a self-contained HTML report to the temp directory (for instance
`"$TMP/audit-docs.html"`). It loads Tailwind and Mermaid from a CDN and holds
everything else inline. It carries the scope, the area count, the top
recommendation first, and every finding numbered in rank order, each with its
kind of text, location, passage, the code it disagrees with, confidence and
proposed fix.

Open it in the browser - `xdg-open <file>` on Linux, `open <file>` on macOS -
and tell the user its path. On a host that cannot open it, write a Markdown
summary in chat instead: the scope, the top recommendation, and one line per
finding.

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
  order, write its text (kind of text, passage, the code it disagrees with,
  confidence, proposed fix) to a finding file in the temp directory and run
  `bash "$ORCH" audit file "<title>" --category documentation
  --finding-file <file> --location
  <location>...`, one `--location` per site. It prints the issue number; when
  an open issue already has that title it files nothing and says so on
  stderr. Report the issue numbers, naming any that was already open rather
  than newly filed. A filing that fails stops the step: report the numbers
  already filed (they stay filed), the failure, and the findings not filed,
  and do not start the interview.
- **Interview.** Invoke `orch-interview` with the findings picked for
  `interview` together, as one change to plan, each with its location,
  passage, the code it disagrees with, and proposed fix. The interview ends
  in a flow, a quick implementation or a blueprint, like any other change.

On `none`, stop: this skill has changed nothing.
