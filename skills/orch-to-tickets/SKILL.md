---
name: orch-to-tickets
description: Break a spec issue into tracer-bullet tickets, each declaring its blocking edges, and publish them to GitHub as sub-issues - or, for a breakdown of 0 or 1 tickets, collapse it into the issue itself. Use from orch-flow's spec phase, quick implementation, or a planning session's Blueprint route, or standalone when a user asks to break an issue into tickets, or runs /orchestrator:to-tickets <issue>. Quick implementation runs it unattended: no quiz, its own draft accepted.
---

# Orchestrator to-tickets

Adapted from the `to-tickets` skill in `mattpocock-skills` 1.2.3.

Break a spec issue (the **parent**) into **tickets**: tracer-bullet vertical
slices, each declaring the tickets that **block** it. Publish two or more as
GitHub sub-issues of the parent; collapse zero or one into the parent itself.

This skill reads and writes no flow state, inside a flow or out of it: every
`orch.sh` call it makes names the parent issue outright. It reports one of two
outcomes to whoever invoked it: the published ticket numbers, or `collapsed`.

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

### 1. Gather context

The parent is the issue number you were given (a caller's spec issue, or the
argument to `/orchestrator:to-tickets`). Fetch it and read its full body and
comments, written to a temporary file outside the repo (`mktemp`). The read
is pinned to the repo `orch.sh` resolves, never `gh`'s default repo, and runs
only once that resolves - an empty `-R` would fall back to the default:

```bash
repo="$(bash "$ORCH" repo show --name)" &&
  gh issue view <parent> -R "$repo" --json title,body,comments > <file>
```

When `repo show` fails, stop and tell the human what it printed. Otherwise
read that file.

### 2. Explore the codebase (optional)

If you have not already explored the codebase, do so to understand the current
state of the code. Ticket titles and descriptions use the project's glossary
vocabulary (`GLOSSARY.md`, when there is one), and respect the ADRs in the area
you are touching.

Look for opportunities to prefactor the code to make the implementation
easier: make the change easy, then make the easy change.

### 3. Draft vertical slices

Break the work into **tracer bullet** tickets:

- Each slice cuts a narrow but complete path through every layer (schema, API,
  UI, tests): vertical, not a horizontal slice of one layer.
- A completed slice is demoable or verifiable on its own.
- Each slice is sized to fit in a single fresh context window.
- Any prefactoring comes first.

Give each ticket its **blocking edges**: the other tickets that must complete
before it can start. A ticket with no blockers can start immediately.

**Wide refactors are the exception to vertical slicing.** A wide refactor is
one mechanical change (rename a column, retype a shared symbol) whose blast
radius fans across the whole codebase, so a single edit breaks every call site
at once and no vertical slice can land green. Sequence it as
**expand-contract** instead. First expand: add the new form beside the old so
nothing breaks. Then migrate the call sites in batches sized by blast radius
(per package, per directory), each batch its own ticket blocked by the expand,
keeping CI green batch to batch because the old form still exists. Finally
contract: delete the old form once no caller remains, in a ticket blocked by
every migrate batch. When even the batches cannot stay green alone, keep the
sequence but let them share a final integrate-and-verify ticket that every
batch blocks; green is promised only there.

### 4. Quiz the user

Present the proposed breakdown as a numbered list. For each ticket, show:

- **Title**: a short descriptive name
- **Blocked by**: which other tickets, if any, must complete first
- **What it delivers**: the end-to-end behaviour this ticket makes work

Ask the user:

- Does the granularity feel right (too coarse, too fine)?
- Are the blocking edges correct: does each ticket depend only on tickets that
  genuinely gate it?
- Should any tickets be merged or split further?

Iterate until the user approves the breakdown. A breakdown of 0 or 1 tickets
is a legitimate outcome: the parent is already one ticket's worth of work.

### 5. Publish, or collapse

**2 or more tickets: publish.** Write each ticket's body from the template
below into a file outside the repo's tracked tree (`.scratch/` serves), then
publish the tickets in dependency order, blockers first, so each ticket's
blocking edges name real issue numbers:

```
bash "$ORCH" ticket publish <parent> "<title>" <body-file> [--blocked-by N,N,...]
```

`ticket publish` creates the issue, links it as a sub-issue of the parent,
records each `--blocked-by` edge, applies the `ready-for-agent` triage role's
label, and reads all of it back before it reports success. Never publish with
an ad hoc `gh` call. If it fails, stop and report which tickets were published
before it did.

When a published ticket's blocking edges are wrong - any number missing or extra -
repair them in place rather than retiring the breakdown:

```
bash "$ORCH" ticket block <n> --by N,N,...
bash "$ORCH" ticket unblock <n> --by N,N,...
```

`ticket block` adds each missing edge, `ticket unblock` removes each extra one;
both read the edges back and rewrite the ticket's `## Blocked by` section to
match. Never repair edges with an ad hoc `gh` call.

**0 or 1 tickets: collapse.** No sub-issue is created; the parent is worked
directly, as its own sole ticket. Record that in the parent's body, always
through the stateless issue verbs:

1. `bash "$ORCH" issue fetch <parent> <file>`, with `<file>` outside the
   repo's tracked tree.
2. Append to the end of that file a section headed by exactly this line:

   ```
   ## Ticket
   ```

   holding the single drafted ticket's **What to build** and **Acceptance
   criteria**, or, for a breakdown of 0 tickets, one line saying the issue is
   worked directly as its own ticket. Append beneath the existing content:
   never replace, reorder, or reword any of it. The heading is fixed because
   `bash "$ORCH" ticket exists <parent>` detects a collapsed breakdown by that
   exact line.
3. `bash "$ORCH" issue update <parent> <file>`.

Collapsing is the one change this skill makes to the parent. Otherwise, do not
close or modify the parent issue.

### 6. Report

The published ticket numbers in publishing order, or `collapsed`.

## Unattended breakdown

The mode a quick implementation takes, and only a quick implementation: a
breakdown that asks the human nothing (ADR-0034). It is also what follows a
retire in `orch-spec-review`'s **Unattended spec review**.

Steps 1-3, 5 and 6 run as written. Step 4, the quiz, is replaced:

- Check the draft yourself against step 3's rules: each ticket a vertical
  slice, verifiable on its own and sized for one fresh context window, with
  any prefactoring first, a wide refactor sequenced as expand-contract, and
  each blocking edge naming only a ticket that genuinely gates it. Merge,
  split or re-edge the draft until it holds.
- Print the breakdown as step 4 presents it - each ticket's **Title**,
  **Blocked by** and **What it delivers** - so a human watching can see it.
- Ask nothing, and go straight to step 5: it publishes 2 or more tickets, or
  collapses 0 or 1 into the parent.

A failure in step 5 stops the breakdown as it does in the attended process,
and the quick implementation that ran it stops with it.

## Ticket template

```markdown
## Parent

#<parent>

## What to build

The end-to-end behaviour this ticket makes work, from the user's perspective,
not a layer-by-layer implementation list.

## Acceptance criteria

- [ ] Criterion 1
- [ ] Criterion 2

## Blocked by

- #<blocking ticket>, one per line, or "None (can start immediately)".
```

Avoid specific file paths or code snippets: they go stale fast. The exception
is a snippet a prototype produced that encodes a decision more precisely than
prose can (a state machine, a reducer, a schema, a type shape): inline it,
trimmed to its decision-rich parts, and note that it came from a prototype.
