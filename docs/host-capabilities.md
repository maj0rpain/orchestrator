# Host capabilities

Skills name a **capability** ("invoke a skill", "start a fresh subagent"), and
this table says how each **host** provides it. Read your host's column: Claude
Code has the Skill and Agent tools; Junie has neither.

A cell marked **Fallback** means that host lacks the capability. Do what
[Fallbacks](#fallbacks) says for it, and record it: one line naming the
capability, the fallback taken, and the step, in the phase's handoff under
**Host fallbacks** (see the `orch-handoff` skill). A review loop records its
fallbacks in its terminal PR comment, and a quick implementation records them
in its PR body. A run that needed none says so, naming the host.

Adding a host means adding one column. Fill a cell only with a verified fact,
and write "unverified" for anything not yet confirmed. The Junie column comes
from the documentation bundled with Junie CLI 3419.7.

`orch.sh doctor` reads this table: every row whose cell in the detected
host's column is marked **Fallback** is reported as a capability that host
lacks, so keep the marker on exactly those cells.

| Capability | Claude Code | Junie |
| --- | --- | --- |
| Invoke a skill | The Skill tool, by scoped name (`orchestrator:orch-flow`, `mattpocock-skills:tdd`). | No Skill tool. The human runs `/<name>` or writes `$<name>` in a prompt, or Junie picks a skill automatically. **Fallback** for the model. |
| Ask a multiple-choice question | `AskUserQuestion`. | `AskUserQuestion`. |
| Start a fresh subagent | The Agent tool, as a fresh general-purpose agent. | Subagents are only picked and started automatically by Junie, with no explicit fresh or fork control. **Fallback**. |
| Start a forked subagent | The Agent tool, as a fork. The plugin never asks for one: a fork inherits the context the plugin keeps out. | None. The plugin never asks for one. |
| Start a fresh session | The human runs `/clear`. | The human runs `/new`, which starts another live session. The old one keeps running. |
| Run a plugin command | `/orchestrator:<command>`. | Unverified whether Junie loads a Claude plugin's `commands/`. **Fallback**. |
| Inject context at planning time | A `PostToolUse` hook on `Skill(grilling)` (`hook-grilling.sh`). | No `PostToolUse` event and no Skill tool. **Fallback**. |
| Arm the edit guard | A `PostToolUse` hook on `Skill` writes the planning marker, and `hook-guard.sh` denies source edits (ADR-0013). | Nothing arms it: no `PostToolUse` event. **Fallback**. |

## Fallbacks

### Invoke a skill

Read the skill's `SKILL.md` and follow it verbatim, which is what the Skill
tool would have injected:

- An orchestrator skill (`orch-*`) is `skills/<name>/SKILL.md` under the plugin
  root, the directory `orch.sh`'s `scripts/` sits in.
- A mattpocock-skills skill is `"$ORCH" mp-skill <name>`. Use that, not a skill
  of the same bare name, because Junie lists skills unscoped and another
  plugin's `code-review` may shadow mattpocock's.

### Start a fresh subagent

Do the subagent's work yourself, in this session, from its brief alone. Read
only the files and the issue the brief names, and write the report it asks
for before moving on. Where a skill spawns several at once, run them one at a
time, finishing each report before starting the next. The loop around the
subagent does not change: a ticket is still closed only once its report is
written.

### Run a plugin command

Invoke the `orch-flow` skill and ask for the section the command names
(start, next phase, status, doctor, redo, abort). Every command is a thin
route into `orch-flow`, so the skill alone is complete.

### Inject context at planning time

The plugin's `guidelines/` file carries the planning nudge (#129). Whether
Junie loads it from this plugin's layout is unverified. Where it does not,
the `orch-flow` and `orch-quick-implement` skill descriptions are the only
prompt.

### Arm the edit guard

There is no real-time guard. `orch.sh init` refuses to start a flow while the
working tree has changes outside the planning allowlist (#126), so planning
edits are caught at flow start instead of prevented.
