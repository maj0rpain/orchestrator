---
name: handoff
description: Write an orchestrator handoff file into .orchestrator/handoff/ so the next phase can start with fresh context. Use only from the orchestrator:flow skill, at a phase boundary.
---

# Orchestrator handoff

Write the handoff for the phase that is ending. The upstream
`mattpocock-skills:handoff` writes to the OS temp directory and cannot be
model-invoked; this one writes into the repo's git-excluded `.orchestrator/handoff/`
and can.

Get the path from `"$ORCH" handoff path <phase>`. Validate with
`"$ORCH" handoff validate <path>` and fix anything it flags before returning.

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
```

### `02-spec.md` (spec -> implement)

```markdown
# Handoff: <slug>

## Spec issue
<URL and number. The spec itself lives there - do not restate it.>

## Seams
<the test seams agreed with the user, and why these and not lower ones>

## Spec review changelog
<what the spec review changed, or "Not reviewed - spec review not built yet">

## Suggested skills
<usually tdd, plus whatever the seams imply>
```

### `03-implement.md` (implement -> review)

```markdown
# Handoff: <slug>

## PR
<URL and number. Draft.>

## Spec issue
<URL and number - the Spec review axis diffs against it>

## Base SHA
<from state.json; the fixed point code-review diffs from>

## Deviations
<where the implementation knowingly departed from the spec, and why. "None" if
it did not. This is how review tells an agreed change from scope creep.>

## Verification
<the exact command that proves the change works, as you just ran it. The review
loop runs this every iteration and treats a failure as blocking. You have the
tests fresh; review would be guessing.>

## Already found and fixed
<what implement's own closing code-review caught, so review iteration 1 does not
re-report it>
```
