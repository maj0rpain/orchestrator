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

### `04-review.md` (review loop -> the next review loop)

Written only when a clean loop's chosen work needs a loop of its own. Its path is
`"$ORCH" handoff path review-next`; `"$ORCH" review loop-next` files a copy under
the loop that wrote it and rolls the counter.

The first four sections are one-liners carried forward from `03` rather than
referenced. Not to save the reader a file - the review loop opens `03` anyway,
for its **Deviations** - but so that the four facts a loop runs on have exactly
one authority. The review skill takes them from the handoff "and from nowhere
else", and a fact with two homes is a fact that can disagree with itself. Carry
them verbatim: a base SHA that drifts from `03`'s silently changes what every
iteration diffs against. The review loop checks that one against
`state get base_sha` before it starts, so a drifted SHA stops a loop rather than
quietly moving its fixed point - the other three are still yours to get right.

```markdown
# Handoff: <slug>, loop <n>

## PR
<URL and number. Still draft.>

## Spec issue
<URL and number>

## Base SHA
<the same fixed point every loop reviews from>

## Verification
<the command, carried forward unchanged>

## Chosen work
<the nits the user chose, each with why it needs a loop rather than an in-place
fix>

## Already settled
<declined nits, covered deviations, and rejected-alternative proposals. This is
04's equivalent of 01's Rejected alternatives: without it loop 2 re-reports
everything loop 1 let go and asks the user the same questions again.>
```
