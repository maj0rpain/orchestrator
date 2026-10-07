# The implementer carries its own TDD rules

Superseded in part by ADR-0026: the fixer no longer invokes `mattpocock-skills:tdd`; the shared-file option this ADR deferred is rejected for now, to be reopened if a third reader appears; and this ADR's statement that agents have no way to locate a plugin file at runtime no longer holds: the plugin root sits beside the `orch.sh` path every agent receives.

Superseded in part by ADR-0035: the minimal implementation of a ticket that fixes a defect is now the smallest one that removes the defect's cause, at every site it acts at.

Supersedes in part ADR-0019: `orch-implementer`'s tools are Read, Edit,
Write, Grep, Glob, and Bash, without Skill, and it builds test-first from
its own adapted copy of `tdd`'s rules instead of invoking the skill.
ADR-0019's reasons
for restricting them stand - without Agent it cannot start sub-agents,
without a question tool it cannot block on a human.

The implementer no longer invokes `mattpocock-skills:tdd`. Its brief carries
an adapted copy of that skill's rules, taken from `mattpocock-skills` 1.2.3:
what a good test is, the anti-patterns, and the rules of the loop, with
`tests.md` and `mocking.md` folded in. Invoking it needed the Skill tool on
Claude Code and an `mp-skill tdd` route everywhere else, and on Junie CLI
a native start of the implementer, whose comma-form `tools:` listed Skill,
got no tools at all; whether the form or the Skill entry caused it was
never isolated (#204). Owning the rules removes Skill from the list and the host split
from the brief.

The copy is adapted, not verbatim. Upstream `tdd` confirms seams with the
user, calls the Skill tool for `codebase-design`, and sends refactoring to
`code-review`; the implementer cannot ask, has no Skill tool, and leaves
review to the review loop. It tests at the seams its brief already names,
the spec's Testing Decisions.

The trade-off, as with ADR-0018's smell baseline: the copy no longer tracks
upstream, and a change there reaches the implementer only when someone
copies it across. The fixer still invokes `mattpocock-skills:tdd`.

## Considered Options

- **Keep Skill in the list.** Rejected: whether Junie tolerates an unknown
  entry was unverified, and the fix would have waited on JetBrains.
- **Drop the implementer's `tools:` line.** Rejected: it gives up ADR-0019's
  denial of Agent and the question tool.
- **Vendor the copy into a shared file.** Deferred: the implementer is its
  only reader, and agents have no way yet to locate a plugin file at
  runtime. #262 decides this when it adds a second reader.
