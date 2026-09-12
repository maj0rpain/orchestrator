# Shared mktemp/rm-f/die cleanup helper extraction

This project does not extract a shared helper for the `tmp="$(mktemp)"` →
do work → `rm -f "$tmp"` on failure then `die` → otherwise consume/move the
temp file shape, even where it repeats across a handful of call sites in
`scripts/orch.sh`.

## Why this is out of scope

Each site's cleanup differs slightly in ways that would make a shared helper
carry parameters or branches for what is otherwise three or four lines:
`cmd_spec fetch` renames the temp file into place on success, `cmd_pr_open`
only ever reads it as a scratch file, and `cmd_state set` overwrites the
target outright. A helper general enough to cover all three either grows a
mode flag per call site or leaves one of them still open-coding the cleanup —
in both cases the indirection costs more to read than the duplication it
would remove.

This project prefers a few similar lines at each of two or three call sites
over a premature abstraction built to serve them. If a fourth or fifth
call site appears with the *same* cleanup shape (not just a similar one),
that's a different weight of evidence and worth reconsidering — see
"Updating or removing out-of-scope files" in the triage skill.

```sh
# cmd_spec fetch: rename into place on success
tmp="$(mktemp "$file.XXXXXX")"
... write to "$tmp" ... || { rm -f "$tmp"; die "..."; }
mv "$tmp" "$file"

# cmd_pr_open: scratch-only, never moved
tmp="$(mktemp)"
... write to "$tmp" ... || { rm -f "$tmp"; die "..."; }
... read "$tmp" ...
```

## Prior requests

- #21: "Duplicated mktemp/rm-f/die cleanup shape between cmd_spec fetch and cmd_pr_open" — filed by the review loop as a Standards-axis nit against PR #20; the reviewers themselves judged extraction not clearly worth it across only two-to-three sites.
