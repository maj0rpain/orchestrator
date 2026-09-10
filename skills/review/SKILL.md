---
name: review
description: Run one bounded review loop over an orchestrator flow's draft PR - review from the base SHA, triage findings into blocking/major/nit, fix, verify, commit, and either mark the PR ready or stop with the reason recorded. Use from orchestrator:flow's review phase, and when re-entering a flow that is already sitting at that phase.
---

# Orchestrator review loop

One loop, one session, at most five iterations. The loop reviews the draft PR,
triages what comes back, fixes what earns fixing, verifies, and ends in exactly
one of three places: the PR marked ready, a handoff to a fresh loop, or a stop
with the reason written down.

The reviewing itself is done by `code-review`'s parallel sub-agents, which are
spawned fresh every iteration and never see your reasoning about the fixes you
just wrote. That is where the independence comes from, and it is why one session
may drive a whole loop - see
`docs/adr/0001-review-loop-runs-in-a-single-session.md`.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

## Before the first iteration

1. Read the handoff: `"$ORCH" handoff path review`. On loop 1 that is
   `03-implement.md`; on any later loop it is the `04-review.md` the previous
   loop wrote, and its **Already settled** section is binding - everything named
   there was decided by a human and is neither re-reported nor re-asked.
2. Take four facts from it, and take them from nowhere else: the **PR**, the
   **spec issue**, the **base SHA**, and the **verification command**.
3. Read `01-plan.md`'s **Rejected alternatives** and `03-implement.md`'s
   **Deviations**. Both are authority over the findings you are about to get.

## The iteration

1. `"$ORCH" review begin`. It prints the iteration number and refuses past five;
   a non-zero exit means the bound is reached - go to **Bounded stop**.
2. Call the Skill tool with `mattpocock-skills:code-review`, giving it the
   **base SHA** as the fixed point and the **spec issue** as the spec source.
   **Every iteration reviews from the base SHA**, never from the previous
   iteration's HEAD: the Spec axis answers "is the spec implemented", and it
   cannot answer that from a diff containing one fix.
3. Triage every finding: apply the two demotions first, then the rubric.
4. Fix everything blocking and everything major, writing the fixes yourself. A
   **blocking finding about behaviour** goes through the `tdd` skill, so the fix
   arrives with a failing test that proves the problem was real.
5. Run the verification command. A failure is a blocking finding, and the
   iteration does not end clean.
6. Commit once, subject in this repo's plain imperative style (`Replace precheck
   and state validate with one doctor command`), describing the fix rather than
   the iteration; the body lists the findings addressed and points at the record.
   An iteration that fixed nothing makes no commit.
7. Push. CI is not waited on here.
8. Write the record to `"$ORCH" review path`: every finding with its axis and
   severity on one line, what was fixed, what was deferred and why, the fix
   commit SHA, and what CI said if it was asked.
9. Nothing blocking or major left open? Go to **Closing the loop**. Otherwise
   iterate.

## Severity

`code-review` reports findings unranked across two axes and refuses to rank
across them. The ranking is yours:

- **blocking** - wrong behaviour, a spec requirement missing or misimplemented, a
  security problem, a broken or missing test, or a failing verification command.
  The loop cannot finish while one is open.
- **major** - it works, but carries real cost: a documented standard breached, a
  smell with teeth, scope nobody asked for. Fixed by the loop; does not on its
  own hold the loop open.
- **nit** - taste and judgement. Recorded, deduplicated across iterations, and
  **left alone until the loop is otherwise clean**. Fixing nits inside the loop
  manufactures a fresh diff for the next iteration to find, which is exactly the
  non-convergence the bound exists to catch.

## Authority: what the loop refuses to act on

Applied before the rubric. Both would overturn a decision a human already made
with more context than you have:

- **Covered deviations.** A Spec-axis finding covered by `03-implement.md`'s
  **Deviations** section becomes a recorded note: not fixed, not blocking. See
  `docs/adr/0002-recorded-deviations-outrank-the-spec-axis.md`. Anything the
  section does *not* cover gets the normal rubric, so scope creep is still
  caught.
- **Rejected alternatives.** A finding proposing something `01-plan.md`'s
  **Rejected alternatives** ruled out becomes a nit, recorded with the reason it
  lost. Demote on `code-review`'s **output**, and leave its sub-agent prompts
  alone: filtering the output also catches a rejected design arrived at by a
  different route.

Both classes go in the record, the closing report, and the PR comment. A
deliberate omission that nobody merging can see is indistinguishable from a
defect.

## CI

Waited on **once per loop**, after blocking and major are clear, or at the
five-iteration stop - someone taking over a failed loop needs the whole picture,
not a blank. Not once per iteration: that would block a single session for most
of an hour, and the fix commits are pushed as they land anyway.

`"$ORCH" review ci` polls the PR's checks and prints one of four words, exiting
non-zero on the last two:

- **green** - carry on.
- **none** - the repo has no checks. Carry on: requiring CI in a repo that has
  none would make this plugin unusable in its own repo.
- **failing** - a required check failed, and the detail lines name which. If it
  looks flaky rather than caused by the change, the flow has **one** flake rerun:
  `"$ORCH" state get flake_rerun_used` reads `true` once it is spent and empty
  while it is not. Spend it with `gh run rerun --failed`, record
  `"$ORCH" state set flake_rerun_used true`, and ask `review ci` again. A second
  failure is a **Bounded stop**.
- **unreachable** - GitHub would not answer, or the checks were still pending at
  the cap. A **Bounded stop**: marking a PR ready over a result nothing ever
  produced claims a verification that never happened.

## Closing the loop

Only on a clean loop. Report the covered deviations and the rejected-alternative
proposals - **report them, do not ask about them**: they are settled, and asking
re-opens them.

Then put the accumulated nits to the user as a numbered multi-select, each with
its axis and a one-line read on what fixing it would take. **The question
blocks.** "No answer" and "no, thanks" are different answers, and a PR promoted
out of draft because nobody replied is a claim nobody made. A session parked on a
question is visible and harmless.

Classify each chosen nit, state the classification, and let the user overrule it:

- **in place** - localized, no behaviour change, existing tests cover it.
- **needs a loop** - changes behaviour, adds a seam, or touches several modules.

The test is "would this change need reviewing?". If **any** chosen item needs a
loop, the whole set hands off rather than being fixed here.

## Terminal states

**Success** - nothing chosen, or everything chosen was fixed in place and
verified. Comment on the PR, then `"$ORCH" review ready`, which marks the PR
ready and records the flow `done` as one operation.

**Handoff** - a clean loop whose chosen work needs a loop of its own. Comment on
the PR. Call the Skill tool with `orchestrator:handoff` to write the file at
`"$ORCH" handoff path review-next`, validate it with `"$ORCH" handoff validate`,
run `"$ORCH" review loop-next`, and print the boundary. `phase` stays `review`,
so `/clear` then `/orchestrator:next` lands in the next loop.

**Bounded stop** - five iterations with blocking or major still open, CI failing,
or CI unreachable. Comment on the PR, record the stop reason and the surviving
findings, and stop. **Leave `phase` at `review` and the PR in draft**: `done`
means "this succeeded", never "this stopped". Skip the nit question entirely -
nobody wants to be asked about taste while the change is still broken.

## The PR comment

One comment at **every** loop termination, success and stop alike.
`.orchestrator/` is git-excluded and eventually archived, so the PR is the only
durable surface another human ever sees; a single comment at the very end would
compress a three-loop flow and lose the trail.

Carry: iterations run, what was fixed with commit SHAs, covered deviations,
rejected-alternative proposals with the reason each lost, declined nits, the CI
result, and what happens next.
