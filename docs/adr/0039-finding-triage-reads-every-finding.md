# Finding triage reads every finding

Supersedes in part ADR-0031: its skill no longer reads only the changed, gone and unknown findings.

`finding-triage scan`'s `unchanged` says only that a finding's filed lines have no change since its filed SHA. A filed finding often names one site of something spread across several - one copy of duplicated code, one caller of a missing helper, one statement of a rule written twice - and its fix can land at another site, leaving the filed lines as they were. A triage on 2026-10-08 found 8 of 33 `unchanged` findings already fixed (#857). Finding triage now reads every finding against the default branch; the scan's result directs the read - the touching commit for `changed`, where the code went for `gone`, the scan's reason for `unknown`, and the commits since the filed SHA and every location the body names for `unchanged` - and is never proof that a finding still holds.

## Considered Options

- **Follow every `file:line` a finding's body names**, and report `changed` when any of them moved. Rejected: it still misses a fix at a site the body does not name, such as a new helper.
- **A separate `unchanged-here` result** for untouched lines in a changed file. Rejected: it still needs a read, so it adds a category without removing the inference.
