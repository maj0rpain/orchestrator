---
name: orch-handoff
description: Write an orchestrator handoff file into .orchestrator/handoff/ so the next phase can start with fresh context. Use only from the orch-flow skill, at a phase boundary.
---

# Orchestrator handoff

Write the handoff for the phase that is ending. The upstream
`mattpocock-skills:handoff` writes to the OS temp directory and cannot be
model-invoked; this one writes into the repo's git-excluded `.orchestrator/handoff/`
and can.

`orch.sh` resolves as:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Get the path from `bash "$ORCH" handoff path <phase>`. Validate with
`bash "$ORCH" handoff validate <path>` and fix anything it flags before returning.

## What belongs in one

The reader is a fresh agent with no memory of this session.

- **Reference, do not copy.** The spec, the PR, the diff, and the ADRs already
  exist. Link them by number, URL, or path. Duplicated content goes stale in a way
  linked content does not.
- **Write what exists nowhere else.** Reasoning, rejected options, and the reasons
  behind a judgement call live only in the conversation that just happened.
- **Redact.** No keys, tokens, or personal data.
- Every required section must have content. "None" is a valid answer; blank is not,
  because a blank section reads as "not yet considered".
- **Record every host fallback.** Each template ends in **Host fallbacks**: one
  line per capability this phase ran through its documented fallback in the
  host capabilities reference (`docs/host-capabilities.md` under the plugin
  root), naming the capability, the fallback taken, and the step. A phase that
  used none writes `None (<host>).`, naming the host, so the reader can tell a
  full-capability run from an unchecked one.

## Templates

### `01-plan.md` (plan -> spec)

The only handoff whose content exists nowhere else, so it is the one worth
writing carefully.

```markdown
# Handoff: <slug>

## Decisions
<what was settled, and the shape of the thing being built>

## Rejected alternatives
<what was considered and ruled out, each with the reason it lost. Without this
the spec writer re-proposes what the user already killed, and nobody notices
until review.>

## Constraints
<hard limits: compatibility, dependencies, deadlines, things that must not change>

## Open assumptions
<what was assumed rather than confirmed, and what would break if it is wrong>

## Suggested skills
<skills the spec phase should call>

## Host fallbacks
<per **Record every host fallback** above>
```

### `02-spec.md` (spec -> implement)

```markdown
# Handoff: <slug>

## Spec issue
<URL and number. The spec itself lives there - do not restate it.>

## Seams
<the test seams agreed with the user, and why these and not lower ones>

## Spec review changelog
<the list orch-review-spec returned, per lens: applied edits one line
each, declined findings verbatim with the human's reason, "None" for a lens
that found nothing, "not run - <reason>" for one that failed>

## Ticket breakdown
<usually the parent issue number only - the tickets themselves are its
GitHub sub-issues, already published. The implement phase discovers them
live via `orch.sh ticket next`; do not duplicate the list here, it would go
stale. When the approved breakdown resolved to 0 or 1 tickets, no sub-issue
was published at all - the spec phase folded that single ticket's content
into the spec issue itself instead, and this section reads `None: work
directly against #<n>` (the spec issue's own number), the same convention
this project already uses for `Blocked by: None (can start immediately)`,
telling the implement phase to dispatch one subagent against `<n>` directly
rather than run a `ticket next`/`ticket close` loop against an empty
frontier>

## Suggested skills
<usually tdd, plus whatever the seams imply>

## Host fallbacks
<per **Record every host fallback** above>
```

### `03-implement.md` (implement -> review)

```markdown
# Handoff: <slug>

## PR
<URL and number. Draft. `pr open` writes the `Closes #<issue>` line itself -
the body file passed to it should not add a closing keyword of its own.>

## Spec issue
<URL and number - the Spec review axis diffs against it>

## Base SHA
<from state.json; the fixed point the review loop diffs from>

## Deviations
<where the implementation knowingly departed from the spec, and why. "None" if
it did not. This is how review tells an agreed change from scope creep.>

## Verification
<the exact command that proves the change works, as you just ran it. The review
loop runs this every iteration and treats a failure as blocking. You have the
tests fresh; review would be guessing.>

## Unmet criteria
<the acceptance criteria the ticket subagents reported unmet on their `Criteria`
lines, one bullet per ticket, or "None". Not covered by ADR-0002: the review
loop's Spec axis judges each as an ordinary finding.>

## Host fallbacks
<per **Record every host fallback** above>
```
