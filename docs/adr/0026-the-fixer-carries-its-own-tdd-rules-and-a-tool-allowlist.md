# The fixer carries its own TDD rules, and the fixer and closer have tool allowlists

Superseded in part by ADR-0035: a blocking fix's "then the smallest fix" is now the smallest fix that removes the cause, at every site it acts at; major and nit fixes are unchanged.

Supersedes in part ADR-0024: the fixer no longer invokes
`mattpocock-skills:tdd`; the shared rules file ADR-0024 deferred is
rejected for now, to be reopened if a third reader appears; and ADR-0024's
statement that agents have no way to locate a plugin file at runtime no
longer holds: the plugin root sits beside the `orch.sh` path every agent
receives.

`orch-fixer` and `orch-closer` now declare the same `tools:` list as
`orch-implementer`: Read, Edit, Write, Grep, Glob, and Bash. ADR-0019's
reasons apply to both word for word. Without Agent they cannot start
sub-agents, and without a question tool they cannot block on a human in the
middle of an unattended review loop. Both rules were ones the briefs could
only ask for before.

Dropping Skill means the fixer can no longer invoke `tdd`, so its brief
carries its own adapted copy of the skill's rules, taken from
`mattpocock-skills` 1.2.3. This is a second copy, not the implementer's.
The fixer uses only a narrow part of TDD: one failing test per blocking
behaviour finding, proving the problem was real, then the smallest fix. Its
copy keeps what a good test is, mocking only at boundaries, and the
implementation-coupled and tautological anti-patterns. It replaces the
red-green loop with rules for a fix. A finding no existing seam can observe
is fixed without a test, and the record says why. A test that passes on the
unfixed code is not a proof, so the finding stays open blocking for the
next iteration's triage rather than being fixed on the fixer's own
judgement.

With the fixer changed, nothing in the plugin invokes `tdd` as a skill, and
`doctor` stops checking that it is installed.

The trade-off: two adapted copies drift from upstream and from each other.
A change to one reaches the other only when someone copies it across.

## Considered Options

- **Keep Skill in the fixer's list.** Rejected: it brings back the
  unverified Junie behaviour ADR-0024 avoided, and keeps the host split in
  the fixer's brief.
- **A shared rules file both agents read.** Rejected for now: every
  implementer run would pay an extra read, and the implementer-specific
  rules (seams from Testing Decisions, no asking) would have to be split
  out. An agent can locate such a file, because the plugin root sits beside
  the `orch.sh` path every agent receives, so this is worth reopening if a
  third reader appears.
- **Have the fixer read the implementer's section in place.** Rejected: it
  ties one agent's brief to another's, including the rules that do not
  apply to a fix.
