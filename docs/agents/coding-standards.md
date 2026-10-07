# Coding Standards

Judgement calls for code in this repo that no lint or test enforces. The
Standards reviewer, ticket subagents and the fixer all read this doc. Rules a
check already enforces are left to that check.

## 1. Reuse, then extract only what reacts the same

Call a helper that already does the job rather than writing its body again.
Extract a new helper when two or more call sites share both the shape and the
reaction to its result. Keep the duplication when a helper would need a mode
argument or callback to serve callers that react differently, or would replace
a single line with a single call. `.out-of-scope/` records extractions already
weighed and declined.

## 2. Route every `orch: ` message through `die`, `die2` or `warn`

Never write a hand-rolled `printf 'orch: ...' >&2`. `die` and `die2` print the
message and exit; `warn` prints it and returns, for a non-fatal message.

## 3. No local named after a file-level helper

A local variable never takes the name of a function defined at file level -
for example `note`, `die`, `now` or `trim`. The shadowing reads as a call where
there is none, and hides the helper from the rest of the function.

## 4. One meaning per variable

A variable holds one meaning over its whole lifetime. When a function needs a
second value, give it a second name rather than reusing the first.
