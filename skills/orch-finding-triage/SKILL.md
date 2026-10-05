---
name: orch-finding-triage
description: Triage the review loop's filed findings - the open review:<severity> issues still labelled needs-triage - against the current default branch, putting one numbered batch of proposed outcomes per source PR to the human (close as completed when already fixed, ready-for-agent, ready-for-human, or wontfix, each with its bug/enhancement category kept or flipped), and applying the answered batch. Use when the human asks to triage filed findings or review:* issues, or runs /orchestrator:finding-triage [<issue> | --pr <n>]. Not for any other issue - upstream triage keeps those.
---

# Orchestrator finding triage

**Finding triage** (see `CONTEXT.md`) checks open **filed findings** against
the current default branch and moves each out of `needs-triage`: closed as
completed when the code it names has since been fixed, otherwise to
`ready-for-agent`, `ready-for-human`, or `wontfix`. It takes only the issues
the closer files - those labelled `review:<severity>` and `needs-triage` - and
nothing else; upstream `triage` keeps every other issue. Why the plugin owns
this step is recorded in
`docs/adr/0031-the-plugin-triages-its-own-filed-findings.md`.

What this skill never does:

- **No direct `gh`.** `orch.sh finding-triage scan` lists and sorts the
  findings, `orch.sh issue fetch` reads a body, and `orch.sh finding-triage
  apply` is the one write. Never call `gh` yourself.
- **No grilling.** A finding whose fix needs a decision goes to the human as
  `ready-for-human`, with the options its body names; you do not decide it
  here, and you write no agent brief beyond the triage comment.
- **No record edits.** Never edit `CONTEXT.md`, `CONTEXT-MAP.md` or anything
  under `docs/adr/` (ADR-0022): a record changes only with the change it
  describes.
- **No subagent.** This skill does all its work in this session, so it needs
  no host fallback for one.
- **No flow state.** It reads and writes nothing under `.orchestrator/`, and
  runs the same with or without an active flow. It changes no branch, HEAD or
  working tree.

On a host with no plugin commands, the human reaches this skill by asking to
triage filed findings rather than running `/orchestrator:finding-triage`.

`orch.sh` resolves as:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

This skill needs shell commands and one capability beyond them: ask a
multiple-choice question. `docs/host-capabilities.md` under the plugin root
maps it to each host.

## 1. Scan

The caller's arguments narrow the scan: nothing (every open filed finding
still in `needs-triage`), one issue number, or `--pr <n>` (the findings filed
from PR `<n>`). Run, with that narrowing:

```
bash "$ORCH" finding-triage scan [<issue> | --pr <n>]
```

It fetches `origin/<default>` and prints one tab-separated line per finding:

```
<issue>	<pr>	<file>:<line>	<result>	<detail>
```

- `unchanged` - the file has no change since the filed SHA. The finding still
  holds; it needs no read.
- `changed` - `<detail>` is the full SHA of the newest commit touching the
  finding's lines (or its file).
- `gone` - the file no longer exists on the default branch.
- `unknown` - `<detail>` says why: an unreachable SHA, or a body that does not
  parse.

If it dies, relay its reason and stop. If it prints nothing, tell the human
there is no filed finding to triage and stop.

Run `bash "$ORCH" default-branch` to name the default branch, and
`git rev-parse origin/<default>` for the **default SHA** the rest of the
triage is checked at.

## 2. Judge

For every finding, read its filed body with
`bash "$ORCH" issue fetch <issue> <file>` (a temp file outside the repo): its
`**Axis:**`, `**Severity:**`, `**Location:**`, `**PR:**` and `**Why not fixed
in the loop:**` lines, the claim, and any options it names.

For each `changed`, `gone` or `unknown` result, read the code on the default
branch at the finding's location - `git show origin/<default>:<file>`, never
by checking anything out - and judge whether the finding still holds:

- `changed`: read the touching commit (`git show <detail>`) and the code at
  the location now.
- `gone`: deletion is never proof of a fix. Look for where the code moved
  (`git log --diff-filter=D --follow`, or a search on the default branch) and
  judge it there; if it is truly gone, the finding no longer holds.
- `unknown`: judge from the body's claim against today's code, and name the
  scan's reason in the proposal.

An `unchanged` result still holds without a read.

For a finding that still holds, find its current location on the default
branch - `file:line at <default SHA>` - for the comment in step 4.

## 3. Propose one batch per source PR

Group the findings by their source PR, one batch per PR, PRs in ascending
order. Within a batch, number the findings and give each one proposed outcome
with a one-line reason:

- **Close as completed** - the finding no longer holds. Name the commit the
  scan reported. With none (`gone`, `unknown`), name the default SHA at which
  the finding was found not to hold, and why.
- **ready-for-agent** - it still holds, and its filed "Why not fixed" reason
  does not call for a decision.
- **ready-for-human** - it still holds, and its fix needs a decision. List the
  options the filed body names.
- **wontfix** - proposed only with a reason. The human can always choose it.

Each still-open outcome also states its category, `bug` or `enhancement`:
keep it, or flip it with a one-line reason - a Standards finding that is a
real defect becomes `bug`, a Spec finding that is a nice-to-have becomes
`enhancement`. The category in place is the one the closer's rule sets from
the body's `**Axis:**` line - `bug` for Spec, `enhancement` for Standards -
and that is also the default for a finding filed before categories, which
carries none.

Present each batch and ask **one blocking question** per batch with the
multiple-choice question capability, the batch and the call in the same
response:

- **Accept as proposed (Recommended)** - every finding takes its proposed
  outcome and category.
- **Other** - the exceptions by number, each with the outcome (and, for an
  open one, the category) it should take instead, e.g.
  `2 wontfix: out of scope; 4 ready-for-human`. Any finding not named takes
  its proposal. The question text states this format.

Nothing is written before the answer. Presenting the batch is not the end of
the step; the answer is. A wrong proposal costs nothing until then.

## 4. Apply the answered batch

Once a batch is answered, apply each finding in it with one call, writing its
comment to a temp file outside the repo first. `apply` prepends the
AI-generated disclaimer itself; do not write it.

```
bash "$ORCH" finding-triage apply <issue> <close-fixed|wontfix> --comment-file <file>
bash "$ORCH" finding-triage apply <issue> <ready-for-agent|ready-for-human> --category <bug|enhancement> --comment-file <file>
```

The comment, by outcome:

- **Close as completed** (`close-fixed`): names the commit, or the default
  SHA, from step 3, and why the finding no longer holds.
- **ready-for-agent** / **ready-for-human**: re-anchors the location to
  `file:line at <default SHA>`, says the finding was checked against the
  default branch, and gives the reason for its state; a `ready-for-human`
  comment lists the options. A flipped category gives its reason.
- **wontfix**: gives the reason.

If an `apply` dies, relay its reason, stop applying, and report what was and
was not applied.

## 5. Report

Per PR, list each finding's issue number and the outcome applied (with its
category, for an open one), and any finding left untouched with why. Nothing
else changed: no flow state, branch, or record file.
