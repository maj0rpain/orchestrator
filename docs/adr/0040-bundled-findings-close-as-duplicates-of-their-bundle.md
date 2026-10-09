# Bundled findings close as duplicates of their bundle

Filed findings arrive one per issue, but several often name the same code area, and working them one flow at a time repeats the same reading and touches the same lines. Finding triage's `--bundle` mode groups the already-triaged open findings by code area into one **bundle** issue each. Every member is commented `Bundled into #B` and closed as a duplicate of the bundle, keeping its labels; the bundle restates each member in its body, carries `finding-bundle` with a triage state and category, and carries no `review:` label, so finding triage never takes it again. An open bundle is never appended to: it may already be a flow's spec issue.

## Considered Options

- **Members as sub-issues of the bundle.** Rejected: a sub-issue is a ticket, and `ticket next` and the implement phase would treat members as a ticket breakdown.
- **Members stay open until the bundle's PR closes them.** Rejected: the same work would sit in the `ready-for-agent` queue twice, and a member could be adopted on its own.
- **Members closed as not planned.** Rejected: it reads as a decision against the finding, when its work has only moved.
