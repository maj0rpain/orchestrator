# orchestrator on the Antigravity CLI

Antigravity CLI (`agy`) loads this repo natively through
`.antigravity-plugin/plugin.json`. See
[docs/host-capabilities.md](../host-capabilities.md) for the live capability
matrix and [docs/how-it-works.md's Hosts section](../how-it-works.md#hosts)
for host detection and why the whole plugin must be installed.

## Install

Clone the repository and install it as a user-level plugin:

```
git clone https://github.com/maj0rpain/orchestrator.git
agy plugin install ./orchestrator
```

`agy plugin install` unpacks the plugin into
`~/.gemini/config/plugins/orchestrator/`, copying `skills/`, `agents/`, and
`scripts/` alongside the promoted `plugin.json`.

For a single workspace instead of a user-level install, place the checkout at
`.agents/plugins/orchestrator/` inside that workspace. In both layouts
Antigravity gives the model the exact path of each `SKILL.md`, so skills
resolve `scripts/orch.sh` two directories above the skill's directory without
needing `CLAUDE_PLUGIN_ROOT`.

## Running skills

Antigravity CLI does not load Claude Code's `commands/` directory from native
plugins. Invoke skills directly by name:

- `/orch-interview` to plan a change
- `/orch-flow` to start or continue a flow
- `/orch-quick-implement` for a quick implementation
- `/orch-spec-review` or `/orch-review-pass` for standalone reviews

For a fresh session between flow phases, run `/clear` (alias `/new`) and then
ask for the next phase with `/orch-flow`.

## Host detection and doctor

Antigravity CLI exports `ANTIGRAVITY_AGENT` and `ANTIGRAVITY_CONVERSATION_ID`
to `run_command` shells, so `orch.sh` detects `antigravity` automatically. If
you run `orch.sh` in a terminal outside Antigravity, set:

```
export ORCHESTRATOR_HOST=antigravity
bash ~/.gemini/config/plugins/orchestrator/scripts/orch.sh doctor
```

`orch.sh doctor` reports the capabilities Antigravity CLI currently falls back
on or leaves unverified, checks for stray skills-only copies in
`~/.gemini/config/skills`, and verifies `git`, `gh`, `jq`, `python3`, and repo
config.

## Current fallbacks

- **Plugin subagents (#4056)**: native loading of `agents/` is not wired yet,
  so skills start a fresh general-purpose subagent via `invoke_subagent`
  briefed with the agent's file under `agents/`.
- **Lifecycle hooks (#4057)**: planning-context injection, the planning edit
  guard, the batch paste guard, and the Bash stdin/pgrep guard hooks are not
  wired yet; skills follow their documented fallbacks and `orch.sh init` checks
  the working tree at flow start.
- **Autopilot**: headless autopilot (`orch.sh autopilot`) is Claude Code only
  and refuses on Antigravity CLI.
