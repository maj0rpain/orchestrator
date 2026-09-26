# CLI Conventions

`orch.sh`'s subcommand grammar: when a command acts on a thing, the thing comes
first. `orch.sh <noun> <verb> [args...]` - e.g. `orch.sh branch retire <old>
<new>`, `orch.sh review file <major|nit> <title> --body-file <file>`.

## Current nouns

| Noun      | Verbs                                              |
| --------- | --------------------------------------------------- |
| `base`    | `set`, `show`, `clear`                               |
| `branch`  | `create`, `off`, `retire`                            |
| `issue`   | `fetch`, `update`, `publish`                         |
| `pr`      | `open`, `publish`, `release`                         |
| `review`  | `begin`, `path`, `file`, `ready`, `ci`, `terminal`, `retire` |
| `spec`    | `fetch`, `update`, `comment`                         |
| `ticket`  | `publish`, `next`, `close`, `reset`, `parent`        |
| `state`   | `get`, `set`                                         |
| `handoff` | `path`, `validate`, `section`                        |

This table is a map of the shape, not the source of truth for arguments or
behavior - run `orch.sh help` for the live list.

## Exceptions

Two kinds of command don't take this shape, deliberately:

- **Bare global commands** with no noun to act on: `doctor`, `init`, `slug`,
  `status`, `archive`, `help`, `mp-skill`, `default-branch`. Each is already
  the whole idea; splitting it into a fake noun+verb pair would just add
  ceremony.
- **`redo review` / `redo spec`**: verb-first on purpose. These act on the
  redo mechanism itself (step the flow back a phase), not on ops belonging to
  a `redo` noun the way `review`'s or `spec`'s subcommands act on ops
  belonging to those nouns.

## Going forward

A new subcommand that operates on an existing or new noun follows
`<noun> <verb> [args...]`. Reach for a flat, hyphenated verb only if it falls
into one of the two exceptions above - it's the shape the CLI used to use
across the board, and issue #60 retired it everywhere else.
