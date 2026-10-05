# The plugin triages its own filed findings

The review loop files every major and nit it does not fix as an issue labelled `review:<severity>` and `needs-triage`, and a flow adopts only a `ready-for-agent` issue. Triage is the only way back into the pipeline, and the plugin never owned it: ADR-0028 brought spec, ticket and planning skills in-house and left triage to whatever the user installs. Upstream `triage` is generic: it checks whether a requested feature exists, not whether the code a finding names at a given SHA has changed since, so findings already fixed on the default branch were briefed for agents. It also edits the glossary and ADRs inline while grilling, the edit ADR-0022 keeps out of planning so a record changes only with the change it describes.

The plugin now owns **finding triage**: the `orch-finding-triage` skill, over the issues the closer files and nothing else. A mechanical `orch.sh finding-triage scan` sorts each finding still labelled `needs-triage` as unchanged, changed, gone or unknown against the default branch, and the skill reads only the last three. Findings are put to the human one batch per source PR. A finding already fixed is closed as completed, naming the commit, not as `wontfix`: it was real and it was fixed, and a `wontfix` would read as a decision against it. Upstream `triage` stays for every other issue.

The closer also labels each filed finding `bug` (Spec axis) or `enhancement` (Standards axis) when filing it, and finding triage confirms or flips that category.

## Considered Options

- **Replace upstream triage entirely**, adapted from mattpocock-skills 1.2.3 as `orch-to-spec` was. Rejected: the state machine, briefs and out-of-scope knowledge base work today, and a copy stops following upstream (the ADR-0028 trade-off) for no gain on the part that failed.
- **Only a mechanical sweep in `orch.sh`**, run before upstream triage. Rejected: it leaves the brief, and the inline glossary edits, to a skill that does not know the filed-finding format or ADR-0022.
- **Stop filing nits, list them in the PR comment only.** Rejected: a nit kept only in a PR comment is lost once the PR merges. Staleness is fixed at triage time instead.
