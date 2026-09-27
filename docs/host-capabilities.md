# Host capabilities

Skills name a **capability** ("invoke a skill", "start a fresh subagent"), and
this table says how each **host** provides it. Read your host's column: Claude
Code has the Skill and Agent tools. "Junie" here and throughout the plugin
means the Junie CLI, not the Junie plugin for JetBrains IDEs. It has no Skill
tool, and it loads the plugin's `agents/`, but its capability filter can hide
them from the model.

A cell marked **Fallback** means that host lacks the capability, or cannot
use it for the step at hand. Do what
[Fallbacks](#fallbacks) says for it, and record it: one line naming the
capability, the fallback taken, and the step, in the phase's handoff under
**Host fallbacks** (see the `orch-handoff` skill). A review loop records its
fallbacks in its terminal PR comment, and a quick implementation records them
in its PR body. A run that needed none says so, naming the host.

A cell marked **Unverified** means nobody has confirmed whether that host has
the capability. Try it; if it is missing, take the fallback and record it the
same way.

Adding a host means adding a column here, and teaching `doctor.sh` to detect
it and name its install methods (#132). Fill a cell only with a verified fact,
and write "unverified" for anything not yet confirmed. The Junie CLI column comes
from the documentation bundled with Junie CLI 3419.7.

`orch.sh doctor` reads this table: every row whose cell in the detected
host's column is marked **Fallback** is reported as a capability that host
lacks, and every row marked **Unverified** as unverified, so keep each marker
on exactly its own cells.

| Capability | Claude Code | Junie CLI |
| --- | --- | --- |
| Invoke a skill from a step | The Skill tool, by scoped name (`orchestrator:orch-flow`, `mattpocock-skills:tdd`). | No Skill tool, so the model cannot invoke one mid-step. A human still starts one with `/<name>`, or Junie picks one automatically. Naming a skill as `$<name>` in a prompt is unverified. **Fallback**. |
| Ask a multiple-choice question | `AskUserQuestion`. | `AskUserQuestion`. |
| Start a fresh subagent | The Agent tool, as a fresh general-purpose agent, or as one of the plugin's agents from `agents/` by its `orchestrator:<name>`. | Junie CLI documents custom subagents, each run in its own context ([Junie CLI subagents](https://junie.jetbrains.com/docs/junie-cli-subagents.html)). It loads the plugin's `agents/` as custom agents (#200), but a capability filter at agent start usually hides them, and starting a hidden agent by name fails with `Unknown agent`. A visible one gets no tools yet (#204), so a native start does not pay off today. **Fallback**. Take the fallback below, whose first tier is a fresh general-purpose agent briefed with the agent's file, and record the reason as the agent hidden by Junie's capability filter. The README's Junie paragraph has a prompt workaround for the filter. |
| Start a forked subagent | The Agent tool, as a fork. The plugin never asks for one: a fork inherits the context the plugin keeps out. | None. The plugin never asks for one. **Fallback**. |
| Start a fresh session | The human runs `/clear`. | The human runs `/new`. Whether the old session keeps running is unverified. |
| Run a plugin command | `/orchestrator:<command>`. | Whether Junie loads a Claude plugin's `commands/` is not confirmed. **Unverified**. |
| Inject context at planning time | A `PostToolUse` hook on `Skill(grilling)` (`hook-grilling.sh`). | A `UserPromptSubmit` hook (`hook-grilling.sh`, #202) that fires when the prompt names a grilling entry point as `/<name>` or `$<name>` (`grilling`, `grill-me`, `grill-with-docs`, `wayfinder`, `improve-codebase-architecture`). Its context reaches the main agent only, and only the interactive TUI fires the event. Gap: when Junie picks grilling on its own, no prompt names it and no message is sent. |
| Arm the edit guard | A `PostToolUse` hook on `Skill` writes the planning marker, and `hook-guard.sh` denies source edits (ADR-0013). | Nothing arms it: no `PostToolUse` event. **Fallback**. |

## Fallbacks

### Invoke a skill from a step

Read the skill's `SKILL.md` and follow it verbatim, which is what the Skill
tool would have injected:

- An orchestrator skill (`orch-*`) is `skills/<name>/SKILL.md` under the plugin
  root, the directory `orch.sh`'s `scripts/` sits in.
- A mattpocock-skills skill is `bash "$ORCH" mp-skill <name>`. Use that, not a skill
  of the same bare name, because Junie lists skills unscoped and another
  plugin's `code-review` may shadow mattpocock's.

### Start a fresh subagent

This is the one definition of how any of the plugin's agents (its files under
`agents/` in the plugin root) is started when the host cannot start it
natively. The skill that starts the agent says only which agent, with which
prompt, and where to record the fallback. Take the first tier that fits:

1. **A fresh general-purpose agent.** On a host that has fresh subagents but
   cannot start the plugin's agent natively (did not load `agents/`, or hid
   it, as Junie's capability filter does), or cannot restrict an agent's tools,
   start a fresh general-purpose agent - still never a fork. Its prompt is the
   one the skill would have given the plugin's agent, plus the path of the
   agent's file, to read and follow as its brief. An agent whose file
   restricts its tools loses that restriction this way and keeps its brief's
   instruction. For a reviewer that is only the Edit and Write restriction:
   it keeps Bash either way, so its read-only behaviour through Bash always
   rested on the brief.
2. **In this session.** On a host with no fresh subagent at all, do the
   subagent's work yourself, in this session, from its brief alone: for one of
   the plugin's agents, its file under `agents/`. Read only the files and the
   issue the brief names, and write the report it asks for before moving on.
   Where the brief names a capability this host lacks, take that capability's
   fallback from this file too, and record it where the starting skill
   says - a brief that invokes `mattpocock-skills:tdd` as a skill becomes
   `bash "$ORCH" mp-skill tdd` on a host with no Skill tool. Where a skill starts several agents at
   once, run them one at a time, finishing each report before starting the
   next. The loop around the subagent does not change: a ticket is still
   closed only once its report is written.

Record the tier taken where the starting skill says, with the reason: which
agent was not available, and why.

### Start a forked subagent

Nothing to do. No skill asks for a fork, so no phase ever takes this
fallback. The row is marked so doctor reports it and a future skill that
wants a fork has to write the fallback here first.

### Run a plugin command

Invoke the `orch-flow` skill and ask for the section the command names
(start, next phase, status, doctor, redo, abort). Every command is a thin
route into `orch-flow`, so the skill alone is complete.

### Arm the edit guard

There is no real-time guard. `orch.sh init` refuses to start a flow while the
working tree has changes outside the planning allowlist (#126), so planning
edits are caught at flow start instead of prevented.

## Finding orch.sh

Only Claude Code sets `CLAUDE_PLUGIN_ROOT` in a skill's shell. Junie CLI's agent
shell does not set `JUNIE_EXTENSION_ROOT` either - only `JUNIE_DATA`,
`JUNIE_SHIM_PATH`, and `JUNIE_TMPDIR` - and Junie does not tell the model a
skill's own directory (#201). So every skill that runs `orch.sh` looks for the
Junie CLI install with a literal
`ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` before falling back
to the path relative to the skill; README.md, "Resolving orch.sh", gives the
order.

## Execute bit

Some hosts drop the execute bit on the plugin's scripts when they install or
update it: Junie does, and the first hook to run then fails with `Permission
denied` (#142). So nothing in the plugin relies on the bit. `hooks/hooks.json`
runs each hook as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<hook>.sh"`, and every
skill and doc runs `bash "$ORCH" …`, never the script alone.
`scripts/test/hooks_test.sh` enforces the hooks rule and runs each hook with
its script at mode 644; `scripts/test/orch_test.sh` enforces the `orch.sh`
rule.
