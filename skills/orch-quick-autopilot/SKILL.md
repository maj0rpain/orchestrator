---
name: orch-quick-autopilot
description: Send one or more issues to autopilot taking every recommended option - a quick autopilot. Selects the issues with `orch.sh autopilot candidates`, shows them once with their label moves and the skipped ones with reasons, asks the one confirmation, then runs one orch-autopilot-planner subagent per issue, at most 4 at once, and ends with a started, skipped and failed summary. Use when the human runs /orchestrator:quick-autopilot <n>..., --all or --limit <k>. Claude Code only.
---

# Orchestrator quick autopilot

See `GLOSSARY.md`'s **Quick autopilot** entry and
`docs/adr/0061-quick-autopilot-plans-unattended-and-overrides-ready-for-human.md`.
Claude Code only, like every autopilot feature: on a host that cannot start
autopilot, stop and say so. This skill selects, confirms once and dispatches;
each issue's work is the `orch-autopilot-planner` agent's.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `orch.sh` is not at that path, stop and tell the human the quick autopilot is
Claude Code only and needs the full orchestrator plugin
(`/plugin install orchestrator@orchestrator`).

Steps here name capabilities (start a fresh subagent, start a background
subagent, ask the user a question). `docs/host-capabilities.md` under the plugin
root (two directories above `ORCH`) maps each one to your host.

## 1. Select

The arguments are exactly one form: one or more issue numbers, `--all`, or
`--limit <k>`. With none, or more than one form, stop and say so. Run
`bash "$ORCH" autopilot candidates <the arguments, unchanged>`. It writes
nothing, and prints one line per issue: the number, then `eligible <none|move|
override>` or `skip <reason>`. If it fails, stop and relay its `orch:` message.
Write nothing to any issue before step 2's confirmation.

## 2. Confirm, once

Show the eligible issues, each with its planned label move (`none`, `move` or
`override`; an `override` replaces a human's `ready-for-human` triage), and the
skipped issues with their reasons. Then ask the one question this skill asks:
whether to send the eligible issues to autopilot. Recommend yes.

With no eligible issue, ask nothing: report the skips and stop. On a no, stop
with nothing written.

## 3. Run one agent per issue

For each eligible issue, start a fresh `orch-autopilot-planner`
subagent, in the background, at most 4 at once: start the next as one returns.
Its prompt is exactly these three lines, and nothing else:

```
Issue: #<n>
Label move: <none|move|override>
orch.sh: <the path ORCH holds>
```

It needs no agent setting: it starts on the session's model and effort. Each
returns one line: `started`, `skipped <reason>` or `failed <step>: <orch:
message>`. One issue's failure never stops the batch: go on with the rest.

## 4. Summarise

End with the summary of every issue: the started, the skipped (the
confirmation's skips, and the agents' `skipped` lines, with their reasons - an
issue found already done names what did the work, and is not closed), and the
failed with their `orch:` messages. A `failed` line after the label move says
the label was moved: a later `/orchestrator:quick-autopilot <n>` plans that
issue again from its interview. Say that the watcher picks the started issues
up; this skill starts no watcher.
