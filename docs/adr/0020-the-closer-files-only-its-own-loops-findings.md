# The closer files only its own loop's findings; triage owns the already-filed rule

Supersedes ADR-0017 in part: its driver, fixer, and closer, and the closer's
filing and PR comment, stand; its closer filing "across the flow's records"
does not.

The closer reads only the records of the loop that started it: those numbered
above the **loop boundary**, the `iteration` the driver read before the loop's
first iteration. Records of earlier loops, and `pre-redo-N/`, are left alone.
While gathering, it drops a major or nit that a later iteration of the same
loop fixed, matched on the file, line, and claim its deduplication uses.

Whether a finding is already filed is decided once, by the driver's triage:
a finding a previous loop's **Filed** list carries is marked **Met again**,
and the closer files nothing so marked and checks no **Filed** list itself.
To make that match as exact as the closer's own deduplication, a **Filed**
entry now carries the finding's file and line -
`#<n> <severity>: <file>:<line> <title>` - and triage matches on file, line,
and claim, never the title alone.

Gathering across the whole flow gave the already-filed rule two owners: triage
marked a finding met again, and the closer separately set aside anything a
**Filed** list in any record carried (#164). It also filed a finding an early
iteration left waiting even when a later iteration of the same loop fixed it
(#172). And triage matched a previous loop's **Filed** entries on title alone
while the closer deduplicated on file, line, and claim, so a reworded claim on
re-entry was filed twice (#158).

## Considered Options

- **The closer reads only this loop's records; triage owns every cross-loop
  match.** Chosen: one owner, and the closer's input shrinks to what its own
  loop produced.
- **Triage marks previous loops' filed items met again, and the closer keeps
  reading every record.** Rejected: the closer would still meet earlier
  loops' waiting findings and need its own rule to skip them - the second
  owner again.
- **Amend the spec to let the closer match Filed lists itself.** Rejected:
  it keeps two matchers with different identities, which is what #158 is.

## Consequences

The closer's prompt carries the loop boundary. **Filed** lists written before
this format carry no file and line; triage matches such an entry on its title
against the finding's claim, and existing records are not rewritten.
