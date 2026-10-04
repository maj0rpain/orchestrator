# The plugin owns its spec, ticket, and planning skills

The plugin no longer depends on `mattpocock-skills`. `to-spec` and
`to-tickets` become the plugin's `orch-to-spec` and `orch-to-tickets`,
adapted from mattpocock-skills 1.2.3: GitHub only, published through
`orch.sh` so verify-then-die covers the spec as well as its tickets, and
with the 0-1-ticket collapse as the skill's own rule rather than an
exception to someone else's. `orch-plan` is the plugin's own planning entry
point. Setup is no longer required: `docs/agents/triage-labels.md` still
wins when present, and the canonical label names apply when it is not.

By 2.6 the plugin read only two upstream skills, both
`disable-model-invocation`, through a resolver that searched four install
locations, a doctor check, and a lint rule: more machinery than the skills
themselves. ADR-0024 and ADR-0026 had already taken `tdd` in-house.

A blueprint's ticket breakdown is not run again: a flow that adopts an
issue, or a quick implementation that links one, skips the breakdown when
the issue already has sub-issues or the collapsed ticket's fixed heading.
Breaking one down again is a deliberate `/orchestrator:to-tickets`.

The trade-off, as with ADR-0018 and ADR-0024: the copies no longer follow
upstream. mattpocock's `grilling`, `grill-me`, `grill-with-docs`, and
`wayfinder` still start a planning session when installed.

## Considered Options

- **Copy only `to-spec`/`to-tickets`, keep setup and planning upstream.**
  Rejected: the README would still have to say mattpocock is required.
- **Drop every reference, including upstream entry points.** Rejected: it
  breaks users who plan through `grill-with-docs`, and keeping their names
  in the hook's pattern costs nothing.
- **Ask on every pickup whether to re-break a blueprint.** Rejected:
  re-breaking is rare, and the standalone skill already covers it.
