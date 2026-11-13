# Coding Standards

Judgement calls for code in this repo that no lint or test enforces. The
Standards reviewer, ticket subagents and the fixer all read this doc. Rules a
check already enforces are left to that check.
Line width is one of them: see CONTRIBUTING's Develop section.

## 1. Reuse, then extract only what reacts the same

Call a helper that already does the job rather than writing its body again.
Extract a new helper when two or more call sites share both the shape and the
reaction to its result. Keep the duplication when a helper would need a mode
argument or callback to serve callers that react differently, or would replace
a single line with a single call. `.out-of-scope/` records extractions already
weighed and declined.

A change that introduces a helper moves onto it every existing site in the repo
that shares both the helper's shape and the reaction to its result. That move
is part of the change, not scope beyond it.

## 2. Route every `orch: ` message through `die`, `die2` or `warn`

Never write a hand-rolled `printf 'orch: ...' >&2`. `die` and `die2` print the
message and exit; `warn` prints it and returns, for a non-fatal message.

## 3. No variable named after a file-level helper

A variable - a function's local or a test section's top-level one - never takes
the name of a function defined at file level - for example `note`, `die`,
`now`, `trim` or tally's `bad`. The shadowing reads as a call where there is
none.

## 4. One meaning per variable

A variable holds one meaning over its whole lifetime. When a function needs a
second value, give it a second name rather than reusing the first.

## 5. Read a process substitution to EOF

Never leave a `while read … done < <(…)` loop early with `return`, `break` or
`exit`: the producer may still be writing, and where `SIGPIPE` is ignored it
prints a write error on stderr. Load the output with `mapfile -t` first and loop
over the array, or iterate a variable's words directly when there is no producer
to run.

## 6. A helper called once per item starts no external command for work bash can do

A helper called once per item (per file, per label, per issue, per worktree)
starts no external command for work bash can do itself, such as reading a small
file, taking a path's last component or testing membership in a list. Reach for
the primitives: `temp_file_make` for a private temp file, `file_read` to read a
file back.
