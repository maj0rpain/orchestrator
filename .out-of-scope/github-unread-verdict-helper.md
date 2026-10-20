# A helper for the "could not read GitHub" verdict

This project does not extract a helper for the reaction the side-checkout
module (`scripts/orch/side-checkout.sh`) writes at three sites when a GitHub
read fails: setting `verdict` to `could not read GitHub: <reason>` and
returning 2. Two sites are in `finished_flow`, after `pr_state_draft_read` and
`pr_refs_read`, and one in `side_checkout_finished`, after
`adapter_prs_merged`.

## Why this is out of scope

The reaction ends in `return 2`, and a helper cannot return for its caller. A
helper could only set the verdict, so each site would still need its own
`return 2`, and one inline line would become one call. Coding-standards
section 1 excludes exactly that: a helper that replaces one line with one call
a reader must look up to learn what the inline form already shows.

The general form of this helper existed once, as `github_read`, and #1022
deleted it when the gh failure contract (`gh_reason`, `gh_die`, `gh_or_die`)
replaced it: a site that reacts to a failed read with a verdict, not a death,
calls `gh_reason` itself and keeps its reaction in place.

```sh
# what each site carries today - the read, the verdict and the status together
pr_state_draft_read "$pr" pr_state _is_draft err \
  || { verdict="could not read GitHub: $(gh_reason "$err")"; return 2; }
```

Reconsider if the reaction grows beyond one line, for example into a remedy
hint every site shares.

## Prior requests

- #1041: "the reaction `verdict=\"could not read GitHub: …\"; return 2` is written out three times" - filed by the review loop as a Standards-axis major against the gh adapter PR #1038, and bundled into #1106.
- #1106: the gh failure contract bundle, which declined the helper and added this record.
