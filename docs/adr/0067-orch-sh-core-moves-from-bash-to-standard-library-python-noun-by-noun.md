# orch.sh's core moves from bash to standard-library Python, noun by noun

**Context.** The bash suite costs about 1,110 CPU-seconds a full run - 375
sections, about 200 `git init`/`mktemp -d` fixtures, shellcheck at 138 s - with
every assertion spawning processes. On a 3 GiB, 8-CPU autopilot container two
concurrent flows thrashed memory and turned a verification run into more than
an hour, and weeks of tuning the suite did not close the gap.

**Decision.** New code for `orch.sh`'s nouns is Python 3.9+, standard library
only at runtime, in `scripts/orch_py/`. A noun still in bash takes bash
changes - fixes, and the callers a conversion switches - until its own issue
converts it. `orch.sh` stays the one entry point
and keeps the `orch.sh <noun> <verb>` grammar, handing each converted noun to
`python3 -m orch`. Nouns move one at a time, those no other module loads
first, so skills, agents and hooks never change. Shared file formats
(`state.json`, handoff files) are pinned by golden files both languages are
tested against while both exist. A converted noun's bash tests are deleted
with it. Its replacement tests are pytest (dev-only, pinned in
`requirements-dev.txt`), in-process against fakes of the `git` and `gh`
adapters, plus a few end-to-end CLI checks. Hooks move last.

## Considered Options

- **Go.** Fast, but a plugin installed by git clone needs prebuilt binaries
  per platform.
- **TypeScript.** Needs a JS runtime the native Claude Code install does not
  provide.
- **A big-bang rewrite.** No shippable steps.
- **Further tuning of the bash suite.** Tried for weeks.

## Consequences

Users need `python3` 3.9+. Bash and Python coexist for a
while, with some helpers duplicated. The suite budget,
`section-durations.tsv`, `affected.sh` and the bash job pool shrink with each
noun and go when the last bash section does. The pytest suite sits outside
the suite budget, so its growth is guarded by review alone; this amends
ADR-0063's and ADR-0066's suite-budget line for that suite.
