---
name: orch-to-spec
description: Turn the current conversation into a spec - no interview, just synthesis of what has already been discussed, after one check of the test seams with the user - and either publish it as a new GitHub issue labelled for an agent, or, given a leading issue number (rewrite mode), rewrite that issue's body as the spec. Use from orch-flow's spec phase, from a planning session's Blueprint route, or standalone when a user asks to write up or publish a spec, or runs /orchestrator:to-spec or /orchestrator:to-spec <n>.
---

# Orchestrator to-spec

Adapted from the `to-spec` skill in `mattpocock-skills` 1.2.3.

Take the current conversation and what you know of the codebase, and turn it
into a spec: published as one new GitHub issue, or, in rewrite mode, written
over an existing issue's body. Do not interview the user: synthesize
what is already known. The one exchange is the test-seams check in step 2, and
in rewrite mode the retire-or-keep question when the issue already has a ticket
breakdown.

This skill reads and writes no flow state. Inside a flow, the caller
(`orch-flow`'s spec phase) records the published issue; standalone, nothing is
recorded anywhere. Report the issue number to whoever invoked you.

## Modes

Read your arguments first. A leading issue number - `704` or `#704` - selects
**rewrite mode** on that issue: the spec replaces that issue's body instead of
being published as a new issue. With no leading issue number, the skill runs in
**publish mode**: it publishes a new issue, as below. A planning session's
Blueprint route hands over its interviewed issue this way, and
`/orchestrator:to-spec <n>` reaches rewrite mode standalone.

Rewrite mode keeps the issue's title always: it replaces the body only. It
posts no comment preserving the old body; GitHub's edit history keeps it.

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

Steps here name capabilities (ask the user a question).
`docs/host-capabilities.md` under the plugin root maps each one to your host.
Where your host's cell says **Fallback**, or **Unverified** and the capability
turns out missing, take the fallback it documents and tell your caller which.

## Process

1. **Explore** the repo to understand the current state of the code, if you
   have not already. In rewrite mode, also read the issue's current body:
   `bash "$ORCH" issue fetch <n> <file>`, into a file outside the repo's
   tracked tree. If it fails, stop and say why. Use the vocabulary of the project's glossary
   (`GLOSSARY.md`, when there is one) throughout the spec, and respect the ADRs
   in the area you are touching.

2. **Check the test seams.** Sketch the seams at which the feature will be
   tested. Prefer existing seams to new ones, and the highest seam possible.
   Where a new seam is needed, propose it at the highest point you can. The
   fewer seams across the codebase the better; the ideal number is one.

   Check with the user that these seams match their expectations. That
   exchange is the point of this step: do not skip it.

3. **Write the spec** from the template below into a body file outside the
   repo's tracked tree (`.scratch/` serves). A glossary or ADR change
   (`GLOSSARY.md`, `docs/adr/`) the conversation decided goes into the body word
   for word, naming the file and entry - never into those files now. It lands
   with the change it describes (ADR-0022).

   In rewrite mode, fold in whatever of the issue's original body still holds.

4. **Publish** it. In rewrite mode, follow **Rewrite the issue** below
   instead of this step. In publish mode: `bash "$ORCH" issue publish "<title>" <body-file>`. It
   creates the issue, applies the `ready-for-agent` triage role's label (the
   repo's own name for it when `docs/agents/triage-labels.md` maps one), and
   reads the title and label back before it reports success. Never publish
   with an ad hoc `gh` call, and add no other triage label. If it fails, stop
   and say why: a spec that is not verifiably published is not published.

5. **Report** the issue number: the published issue's in publish mode; in
   rewrite mode, report as **Rewrite the issue** says.

## Rewrite the issue

Rewrite mode's publish step, on issue `<n>`. Every step runs in the Blueprint
route and standalone alike.

1. **Check for a breakdown, before the body is replaced:**
   `bash "$ORCH" ticket exists <n>`.
   - Exit 1 (no breakdown): carry on. The breakdown outcome is `none`.
   - Exit 0 (it prints `sub-issues` or `collapsed`): ask the user whether to
     **retire** the breakdown and break the issue down again, or **keep** it.
     On **keep**, copy any `## Ticket` section of the current body (from the
     fetch in step 1, read through the line before the next `## ` heading or
     the end of the body) into the new body verbatim, unchanged. The outcome
     is `kept` or `retired`.
   - Exit 2 (GitHub could not be read): stop and say why. Never read it as
     "no breakdown": that would publish a second one.
2. **Replace the body:** `bash "$ORCH" issue update <n> <body-file>`. The
   title is never changed, and no comment preserving the old body is posted.
   If it fails, stop and say why. Never fall back to `issue publish`, and run
   no ticket step.
3. **On retire**, run `bash "$ORCH" ticket retire <n>` now, after the update,
   so it cuts any `## Ticket` section from the body just written. If it
   fails, stop and say why, and run no ticket step: `orch-to-tickets` does
   not run.
4. **Read the label:** `bash "$ORCH" issue ready <n>`. Apply no triage label:
   the interviewed-issue step already put the label question.
   - Exit 0: nothing to say.
   - Exit 1: warn that `/orchestrator:start --issue <n>` will refuse the
     issue until it carries the `ready-for-agent` label (the repo's own name
     for it when `docs/agents/triage-labels.md` maps one).
   - Exit 2: warn that the label could not be checked, and carry on: the
     rewrite has already landed.
5. **Report** the issue number and its breakdown outcome - `kept`,
   `retired`, or `none` - so a caller runs `orch-to-tickets` on the issue
   unless the outcome is `kept`. Standalone, on `retired`, also report that
   the issue needs `/orchestrator:to-tickets <n>`.

## Spec template

```markdown
## Problem Statement

The problem the user is facing, from the user's perspective.

## Solution

The solution to the problem, from the user's perspective.

## User Stories

A LONG, numbered list of user stories, each in the form:

1. As a <actor>, I want a <feature>, so that <benefit>

This list should be extensive and cover every aspect of the feature.

## Implementation Decisions

The implementation decisions made. This can include:

- the modules that will be built or modified
- the interfaces of those modules that will change
- technical clarifications from the developer
- architectural decisions
- schema changes
- API contracts
- specific interactions

For a bug spec, add a **Root cause** subsection (`### Root cause`): the
defect's cause, and every site it acts at - each copy of the logic, each
caller, each input it mishandles. The fix removes the cause at all of them,
and the Spec axis holds the change to that list.

## Testing Decisions

The testing decisions made. Include:

- what makes a good test here (only external behaviour, never implementation
  details)
- which modules will be tested, at the seams agreed in step 2
- prior art for the tests (similar tests already in the codebase)

## Out of Scope

What is out of scope for this spec.

## Further Notes

Any further notes about the feature.
```

Do not put specific file paths or code snippets in the spec: they go stale
fast. The exception is a snippet a prototype produced that encodes a decision
more precisely than prose can (a state machine, a reducer, a schema, a type
shape): inline it within the relevant decision, trimmed to its decision-rich
parts, and note that it came from a prototype.
