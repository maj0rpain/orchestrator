---
name: orch-to-spec
description: Turn the current conversation into a spec and publish it as a GitHub issue labelled for an agent - no interview, just synthesis of what has already been discussed, after one check of the test seams with the user. Use from orch-flow's spec phase, from a planning session's Blueprint route, or standalone when a user asks to write up or publish a spec, or runs /orchestrator:to-spec.
---

# Orchestrator to-spec

Adapted from the `to-spec` skill in `mattpocock-skills` 1.2.3.

Take the current conversation and what you know of the codebase, and turn it
into a spec published as one GitHub issue. Do not interview the user: synthesize
what is already known. The one exchange is the test-seams check in step 2.

This skill reads and writes no flow state. Inside a flow, the caller
(`orch-flow`'s spec phase) records the published issue; standalone, nothing is
recorded anywhere. Report the issue number to whoever invoked you.

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
   have not already. Use the vocabulary of the project's glossary
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

4. **Publish** it: `bash "$ORCH" issue publish "<title>" <body-file>`. It
   creates the issue, applies the `ready-for-agent` triage role's label (the
   repo's own name for it when `docs/agents/triage-labels.md` maps one), and
   reads the title and label back before it reports success. Never publish
   with an ad hoc `gh` call, and add no other triage label. If it fails, stop
   and say why: a spec that is not verifiably published is not published.

5. **Report** the published issue number.

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
