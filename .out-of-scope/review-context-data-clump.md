# Bundling the PR, spec issue and base SHA into one value

This project does not bundle the PR, the spec issue and the base SHA into a
single value, record or file, even though the three are passed together
everywhere in the review loop: in the reviewer, fixer and closer prompts, and
in each review record's header.

## Why this is out of scope

"Data Clumps" is a smell in code, where a group of arguments that always
travel together can become one type. Here the three values are not function
arguments. They are lines of text in a subagent's prompt and in a Markdown
record. Nothing can carry them as one unit: a prompt is text, and the agent
that reads it starts with no memory of anything before it.

One way to bundle them would be a shared file that each agent reads to get
the three values. That adds a file read and a path to pass, which is still one
value per prompt, and the agent loses the plain view of the values it works
from. The handoff design keeps every prompt self-contained on purpose, so
three short lines that repeat are the intended shape.

Orchestrator state already holds these values in `.orchestrator/state.json`
and reads them through `orch.sh`. The prompts copy them so each agent starts
with nothing to look up.

## Prior requests

- #163: "PR, spec issue and base SHA travel together through every agent prompt and record header" — review-loop Standards nit against PR #154
