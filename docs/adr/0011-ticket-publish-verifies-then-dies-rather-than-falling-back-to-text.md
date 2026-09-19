# `ticket publish` verifies then dies, rather than falling back to text

`orch.sh ticket publish` (`scripts/orch.sh`'s `cmd_ticket_publish`, added in
#82) creates a ticket, links it as a native sub-issue of its parent, and adds
a native blocking edge for every `--blocked-by` argument. Immediately after
writing those links it reads them straight back: the parent's `sub_issues`
listing must contain the child, and the child's `blocked_by` listing must
match the requested set exactly (`ticket_links_verified`). A mismatch gets
one retry; a second failure calls `die`, naming the ticket, and stops the
caller there.

`to-tickets` itself already defines a fallback for repos where native
sub-issues are unavailable: a text-based `Blocked by:` convention written
into the issue body. `ticket publish` does not use it. Falling silently back
to that convention whenever a write or a readback failed would have been the
easy path - the ticket still gets created, so nothing "fails" from the
caller's point of view - but nothing downstream reads the text form. The
implement phase's and quick implementation's frontier query (`ticket next`)
reads only the native `sub_issues`/`issue_dependencies_summary` relationship;
a ticket that silently fell back to text would look, to that query, exactly
like one with no dependency information at all. A blocked ticket could then
surface as "ready" before its blocker actually closed, or a ticket could
vanish from the parent's sub-issue list entirely, and nothing in the flow
would notice until a human happened to read the issue body by hand.

The text convention still exists in `to-tickets` for the case the fallback
was actually meant for: a repo where sub-issues are unavailable outright,
caught in advance by `doctor --env`'s advisory probe, not discovered
partway through publishing a breakdown.

## Consequences

A GitHub outage or permissions problem during `ticket publish` now stops the
phase that called it, loudly, naming the ticket that didn't verify - rather
than leaving a breakdown with some tickets silently invisible to `ticket
next`. Because the retry re-reads rather than re-writes, a false-negative
readback (a momentary API lag between the write and the following `GET`)
gets a second chance before anything dies. The cost lands entirely on the
publishing step: `to-tickets`' text-based convention becomes dead prose for
any repo this project actually targets, kept only as documentation of the
one case - a pre-sub-issues GitHub instance - where it would still apply.
