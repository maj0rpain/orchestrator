# Shared gh-state-fetch helper across differing error paths

This project does not extract a shared helper for the `gh issue view
--json state` / `gh pr view --json state` fetch-and-branch shape, even where
it repeats across call sites in `scripts/orch.sh`, when those call sites
report failure differently.

## Why this is out of scope

The shape looks identical at a glance — fetch a resource's state, branch on
it — but the call sites don't agree on what happens when it's missing or
wrong. `validate_adopted_issue` (adoption's one-time precondition check)
calls `die` to abort the whole command immediately; `check_flow_issue` (a
`doctor` check) calls `d_fail` to record a non-fatal finding and keep
checking everything else. A shared helper general enough to cover both either
takes a callback/mode argument for how to report failure, or leaves one
caller still open-coding its own version — in both cases the indirection
costs more to read than the two or three lines of duplication it would
remove.

```sh
# validate_adopted_issue: fatal, aborts the command
state="$(gh issue view "$issue" --json state --jq .state 2>/dev/null)" \
  || die "issue #$issue could not be read from GitHub - check it exists and gh is authenticated."

# check_flow_issue: non-fatal, one finding among many doctor checks
issue_state="$(gh issue view "$issue" --json state --jq .state 2>/dev/null)" || issue_state=""
case "$issue_state" in
  OPEN)   d_ok "issue #$issue open" ;;
  CLOSED) d_fail "issue #$issue is closed."; d_remedy "gh issue reopen $issue" ;;
  *)      d_fail "issue #$issue could not be read from GitHub."; d_remedy "gh issue view $issue" ;;
esac
```

## Prior requests

- #33: "gh issue view --json state shape is duplicated between validate_adopted_issue and check_flow_issue" — filed by the review loop as a Standards-axis nit against PR #29; already considered and declined during that PR's own implementation, with the same reasoning recorded in its `03-implement.md` handoff.
