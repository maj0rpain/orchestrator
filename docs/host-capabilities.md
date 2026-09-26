# Host capabilities

Skills name a **capability** ("invoke a skill", "start a fresh subagent"), and
this table says how each **host** provides it. Read your host's column: Claude
Code has the Skill and Agent tools. "Junie" here and throughout the plugin
means the Junie CLI, not the Junie plugin for JetBrains IDEs. It has no Skill
tool, and its custom subagents are documented but not yet confirmed to load
from a Claude plugin's `agents/`.

A cell marked **Fallback** means that host lacks the capability. Do what
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
| Start a fresh subagent | The Agent tool, as a fresh general-purpose agent, or as one of the plugin's agents from `agents/` by its `orchestrator:<name>`. | A custom subagent from the plugin's `agents/`, run in its own context ([Junie CLI subagents](https://junie.jetbrains.com/docs/junie-cli-subagents.html)). Whether Junie loads a Claude plugin's `agents/` is not confirmed (#148). **Unverified**. Where it does not, take the fallback below. |
| Start a forked subagent | The Agent tool, as a fork. The plugin never asks for one: a fork inherits the context the plugin keeps out. | None. The plugin never asks for one. **Fallback**. |
| Start a fresh session | The human runs `/clear`. | The human runs `/new`. Whether the old session keeps running is unverified. |
| Run a plugin command | `/orchestrator:<command>`. | Whether Junie loads a Claude plugin's `commands/` is not confirmed. **Unverified**. |
| Inject context at planning time | A `PostToolUse` hook on `Skill(grilling)` (`hook-grilling.sh`). | No `PostToolUse` event and no Skill tool. The extension's `guidelines/orch-planning.md` carries the same message, worded conditionally. **Fallback**. |
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

Do the subagent's work yourself, in this session, from its brief alone. For
one of the plugin's agents, the brief is its file under `agents/`. Read
only the files and the issue the brief names, and write the report it asks
for before moving on. Where a skill spawns several at once, run them one at a
time, finishing each report before starting the next. The loop around the
subagent does not change: a ticket is still closed only once its report is
written.

### Start a forked subagent

Nothing to do. No skill asks for a fork, so no phase ever takes this
fallback. The row is marked so doctor reports it and a future skill that
wants a fork has to write the fallback here first.

### Run a plugin command

Invoke the `orch-flow` skill and ask for the section the command names
(start, next phase, status, doctor, redo, abort). Every command is a thin
route into `orch-flow`, so the skill alone is complete.

### Inject context at planning time

`guidelines/orch-planning.md` carries `hook-grilling.sh`'s planning nudge as
plain Markdown.
Guidelines load in every repo the extension is enabled in, so the file
applies itself only while a grilling session is running and no
flow is active. Keep it in step with `hook-grilling.sh`; `orch_test.sh` checks
its key points. Whether Junie loads `guidelines/` from a Claude-layout
extension is unverified. Where it does not, the `orch-flow` and
`orch-quick-implement` skill descriptions are the only prompt.

### Arm the edit guard

There is no real-time guard. `orch.sh init` refuses to start a flow while the
working tree has changes outside the planning allowlist (#126), so planning
edits are caught at flow start instead of prevented.

## Execute bit

Some hosts drop the execute bit on the plugin's scripts when they install or
update it: Junie does, and the first hook to run then fails with `Permission
denied` (#142). So nothing in the plugin relies on the bit. `hooks/hooks.json`
runs each hook as `bash "${CLAUDE_PLUGIN_ROOT}/scripts/<hook>.sh"`, and every
skill and doc runs `bash "$ORCH" …`, never the script alone.
`scripts/test/hooks_test.sh` enforces the hooks rule and runs each hook with
its script at mode 644; `scripts/test/orch_test.sh` enforces the `orch.sh`
rule.
