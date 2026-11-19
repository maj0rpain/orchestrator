# Repo setup

Everything `orch.sh` reads from a repo, one section per item a repo's setter
writes. Each section says what reads the item, its exact format, what happens
when it is missing, what happens when it is unreadable, and which `orch.sh
doctor` line reports it. Doctor's states are `ok`, `warn` and `FAIL`; a
missing item is `ok` when the code has a fallback, naming it, and `warn` when
it has none.

## Standards declaration

- **Read by**: `orch.sh review standards`, which resolves the list of
  standards documents the Standards reviewer reads, and the review loop and
  review pass that start it.
- **Format**: in a root agent file - `CLAUDE.md` or `AGENTS.md`; with neither,
  `CODING_STANDARDS.md` or `CONTRIBUTING.md` - a paragraph starting
  `Standards:`, outside a code fence. It lists backticked repo-relative paths.
  Each is a file, or `path#Heading`, naming one section by its heading text,
  which must match exactly once in that file. A path may not leave the repo.
  Example:
  ``Standards: `CONTRIBUTING.md#Develop`, `docs/agents/cli-conventions.md`.``
- **Missing**: the list is crawled instead: the root agent files and the
  documents they point to, two hops, and the reviewer keeps those about how
  code is written. When the crawl finds nothing, the reviewers apply the smell
  baseline alone.
- **Unreadable**: a declaration with no entries, an entry naming a missing
  file, a `#Heading` that matches no heading or several, or a path that leaves
  the repo stops the review with a message naming the cause.
- **Doctor line**: "Standards declared in ...", or "no Standards: declaration
  - the list is crawled ...", or "no Standards: declaration and nothing to
  crawl - the reviewers apply the smell baseline alone", or a `FAIL` carrying
  the resolution's message.

## Verification lines

- **Read by**: the implementer, fixer and resolver agents and the driver of a
  flow, to find the command to run.
- **Format**: a line outside a fenced code block, in the root `CLAUDE.md`,
  `AGENTS.md` or `CONTRIBUTING.md` (read in that order), starting
  `Ticket verification:` or `Full verification:`, followed by the command (an
  optional `Branch verification:` line is below).
  Example: `Full verification: scripts/test/all.sh`.
- **Missing**: no ticket verification means tickets run the full verification
  (ADR-0058). No full verification means agents use the command the
  instructions document, which orch.sh cannot define.
- **Unreadable**: a label with no command after it leaves the agents no command
  to run. Two lines naming different commands for one label leave agents to
  pick; the first one found is the one doctor reports.
- **Doctor line**: one line per label. `ok` reads `Full verification: <command>
  (<file>)` or `Ticket verification: <command> (<file>)`; with no ticket
  verification it is also `ok`, reading "no 'Ticket verification:' line -
  tickets run the full verification (ADR-0058)". `warn` for no full
  verification or for two commands for one label; `FAIL` for a label with no
  command. Doctor never runs the command.
- **Branch verification**: an optional `Branch verification: <command>` line,
  read from the same files in the same order, outside a fenced code block. It
  is the command the combined-branch check runs; with no such line that check
  runs the full verification. Doctor reports it as it reports the other two
  labels: `ok` reading `Branch verification: <command> (<file>)`, or, with no
  line, `ok` reading "no 'Branch verification:' line - the combined-branch
  check runs the full verification"; `warn` for two different commands;
  `FAIL` for the label with no command. Its command's first word is checked
  as installed, as for the other two. This plugin's own docs lint checks,
  by structure only, that its own `CLAUDE.md` line is well formed and sits in
  the Testing section; no such placement is required of your repo.

## Glossary

- **Read by**: `orch.sh glossary` (`terms`, `show`, `match`), which the skills,
  the spec review's Consistency lens and the Standards reviewer's glossary
  parse check use. It reads the root `GLOSSARY.md` only.
- **Format**: an entry starts at a `**Term**:` line, optionally after a `- ` or
  `* ` bullet, with the definition on the same line or below. It runs to the
  next entry start, the next line starting with `#`, or the end of the file. An
  `_Avoid_:` line inside an entry lists its aliases, comma-separated. A
  numbered list item and an unbolded `Term:` are no entries, and `**Term** -
  ...` is none either. Example: `**Doctor**: the diagnostic command.`
- **Missing**: no glossary is read; the Consistency lens reads none and the
  glossary parse check does not run. A `GLOSSARY-MAP.md` is read by the skills
  only; orch.sh never parses the glossaries it points to.
- **Unreadable**: a file that gives no entries stops every glossary command
  with `GLOSSARY.md has no entries orch.sh can read`, never "no terms".
- **Doctor line**: "no GLOSSARY.md ..." (`ok`), "N glossary entries read"
  (`ok`; a count far below what you wrote means some entries did not parse),
  or a `FAIL` carrying the command's message.

## ADR directory

- **Read by**: the skills, and handed to the spec review's lenses as the ADR
  directory.
- **Format**: `docs/adr`, a directory of Markdown files.
- **Missing**: no ADRs are read.
- **Unreadable**: a `docs/adr` that exists and is no directory cannot be read
  as one.
- **Doctor line**: "no docs/adr" (`ok`), "docs/adr holds N ADRs" (`ok`, the
  Markdown files directly in it), or a `FAIL`.

## Triage labels

- **Read by**: the spec phase, which labels its issue, and every command that
  names a triage label.
- **Format**: the five canonical names - `needs-triage`, `needs-info`,
  `ready-for-agent`, `ready-for-human`, `wontfix` - each of which must exist as
  a label on the GitHub repo. A repo with other names maps them in the table of
  `docs/agents/triage-labels.md`.
- **Missing**: with no mapping doc, the canonical names apply. A label the repo
  lacks stops the spec phase after its exchange is spent.
- **Unreadable**: a mapping doc that lists no triage labels is a `FAIL`.
- **Doctor line**: "N triage labels documented in ..." or "no
  docs/agents/triage-labels.md" (`ok`), and "every triage label exists on the
  repo" or a `FAIL` naming the missing ones.

## What needs no setup

- The git-exclude lines: `orch.sh init` writes them (see
  `docs/how-it-works.md`).
- The phase, category and bundle labels: created on first use (see
  `docs/how-it-works.md`).
- The base branch: resolved by `orch.sh base` (see `docs/how-it-works.md`).
- Agent settings: `orch.sh agent` reads them, and doctor reports them (see
  `docs/how-it-works.md`).
- Autopilot settings: `orch.sh autopilot` reads them (see
  `docs/how-it-works.md`).

Run `orch.sh doctor` to check the setup described in the sections above "What
needs no setup".
