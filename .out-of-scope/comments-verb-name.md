# Renaming the `comments` verb on `orch.sh issue` and `orch.sh spec`

This project keeps `comments` as the verb that fetches an issue's comments to
a file (`orch.sh issue comments <n> <file>`, `orch.sh spec comments <file>`),
even though it sits one letter from `comment`, which posts a file as a
comment.

## Why this is out of scope

- The callers are skills, whose prose spells out the command they run. People
  rarely type these by hand, so a one-letter typo is unlikely.
- `comments` mirrors gh's own `--comments` / `--json comments`, the field the
  command reads, and pairs with `fetch` for the body: `fetch` gets the body,
  `comments` gets the comments.
- The alternatives are worse under `docs/agents/cli-conventions.md`. A
  hyphenated verb such as `fetch-comments` is the flat shape issue #60
  retired. A new noun, such as `comments fetch`, splits one issue's
  operations across two nouns.
- Renaming would change the CLI surface the spec settled, along with every
  skill, test and doc that names it, for a naming preference.

The typo risk is real. `issue comments 23 f` overwrites `f`, the file an agent
meant to post. If a skill is ever found doing this, reopen the question then.

## Prior requests

- #372: "The verb comments is one letter from comment on the issue and spec nouns" (review-loop Standards nit against PR #363)
