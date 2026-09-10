# orchestrator

A Claude Code plugin. **This is a blank shell** — the directory layout and
manifests are in place, but there are no commands, agents, skills, or hooks yet.

## Install

```
/plugin marketplace add maj0rpain/orchestrator
/plugin install orchestrator@orchestrator
```

The repo doubles as its own single-plugin marketplace, so no separate
marketplace repo is needed.

For local development, point Claude Code at the working tree instead:

```
claude --plugin-dir /home/patlinux/Git/orchestrator
```

## Layout

```
.claude-plugin/
  plugin.json       # plugin manifest (required)
  marketplace.json  # lets this repo be added as a marketplace
commands/           # slash commands: one .md file per command
agents/             # subagents: one .md file per agent
skills/             # skills: one directory per skill, each with SKILL.md
hooks/hooks.json    # hook configuration
scripts/            # helper scripts invoked by commands/hooks
.mcp.json           # MCP servers bundled with the plugin
```

Only `.claude-plugin/plugin.json` is required. Empty directories are kept with
`.gitkeep` files and can be deleted if unused.

## Authoring reference

### Commands — `commands/<name>.md`

Becomes `/<name>` (or `/orchestrator:<name>` when names collide).

```markdown
---
description: One line shown in the slash-command list.
argument-hint: [target]
allowed-tools: Bash(git status:*), Read
---

Instructions for Claude. `$ARGUMENTS` interpolates what the user typed;
`$1`, `$2` interpolate positional args.
```

Subdirectories namespace commands: `commands/db/migrate.md` → `/db:migrate`.

### Agents — `agents/<name>.md`

```markdown
---
name: reviewer
description: When this agent should be invoked. Written for the calling model.
tools: Read, Grep, Glob
model: sonnet
---

The agent's system prompt.
```

### Skills — `skills/<name>/SKILL.md`

```markdown
---
name: my-skill
description: What it does and when to use it, including trigger phrases.
---

Skill instructions. Supporting files live alongside SKILL.md and are
referenced by relative path.
```

### Hooks — `hooks/hooks.json`

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "command", "command": "${CLAUDE_PLUGIN_ROOT}/scripts/check.sh" }
        ]
      }
    ]
  }
}
```

Use `${CLAUDE_PLUGIN_ROOT}` for any path inside the plugin — it resolves to the
plugin's install directory, which is not the user's working directory.

## Validate

```
claude plugin validate .
```

## License

MIT — see [LICENSE](LICENSE).
