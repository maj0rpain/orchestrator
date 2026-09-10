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

If `CLAUDE_PLUGIN_ROOT` is unset, it is `scripts/orch.sh` two directories above
this file.

## Before the first iteration

1. Read the handoff: `"$ORCH" handoff path review`. On loop 1 that is
   `03-implement.md`; on any later loop it is the `04-review.md` the previous
   loop wrote, and its **Already settled** section is binding - everything named
   there was decided by a human and is neither re-reported nor re-asked.
2. Take four facts from it, and take them from nowhere else: the **PR**, the
   **spec issue**, the **base SHA**, and the **verification command**.
3. Read `01-plan.md`'s **Rejected alternatives** and `03-implement.md`'s
   **Deviations**. Both sit in the directory the handoff you just read came from
   (`dirname "$("$ORCH" handoff path review)"`), and both are authority over the
   findings you are about to get.

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
   **blocking finding about behaviour** goes through the `mattpocock-skills:tdd`
   skill, so the fix arrives with a failing test that proves the problem was
   real.
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
9. Did this iteration fix anything? Then iterate. The fixes are a new diff and
   nothing has reviewed them, which is the whole reason the bound exists. The
   loop closes on an **iteration whose review came back with nothing blocking or
   major to fix** - the iteration that therefore fixed nothing and made no
   commit. "I just fixed everything the last review found" is not that test: it
   is true at the end of every iteration that fixed anything.

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
  **never fixed inside an iteration**. Fixing one there manufactures a fresh
  diff for the next iteration to find, which is exactly the non-convergence the
  bound exists to catch. The single exception is **Closing the loop**, which
  asks which nits to fix once no iteration will follow.

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

Waited on **once per loop**, in exactly one of two places: **Closing the loop**
step 2, once the nit fixes are pushed, or a **Bounded stop**, where someone
taking the loop over needs the whole picture rather than a blank. Never inside
an iteration: that would block a single session for most of an hour, and the fix
commits are pushed as they land anyway.

`"$ORCH" review ci` polls the PR's checks and prints one of four words, exiting
non-zero on the last two:

- **green** - carry on.
- **none** - the repo has no checks. Carry on: requiring CI in a repo that has
  none would make this plugin unusable in its own repo.
- **failing** - a required check failed, and the detail lines name which. If it
  looks flaky rather than caused by the change, the flow has **one** flake
  rerun: `"$ORCH" state get flake_rerun_used` reads `true` once it is spent and
  empty while it is not. Spend it on the run behind the failing check -
  `gh run rerun` needs that run's id, and with none it opens a prompt a session
  driving `gh` from non-interactive bash cannot answer:

  ```
  link="$(gh pr checks <pr> --json bucket,link \
    -q 'first(.[] | select(.bucket == "fail" or .bucket == "cancel") | .link)')"
  run="${link##*/runs/}"          # .../actions/runs/N/job/M -> N/job/M
  gh run rerun "${run%%/*}" --failed
  ```

  It reruns GitHub Actions and nothing else, so a failing check that is not an
  Actions run has no rerun to spend and is a **Bounded stop** on the spot. Then
  record `"$ORCH" state set flake_rerun_used true` and ask `review ci` again. A
  second failure is a **Bounded stop**. That second ask restarts the
  fifteen-minute wait rather than inheriting what is left of the first, because
  a rerun restarts the checks - so this one path, once per flow, can wait longer
  than the cap.
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

Then, in this order:

1. Fix the chosen **in place** items, run the verification command, and commit
   and push them the way an iteration would - one commit, same subject style.
   `review ready` over an uncommitted working tree marks a PR ready on a change
   that is not in it, and a PR comment citing commit SHAs nobody wrote cites
   nothing. Nothing chosen, or everything handed off: no commit.

   A verification failure here is blocking, and a nit fix is what broke it.
   Revert that fix rather than iterating on it: the loop is otherwise clean, and
   no nit is worth either a broken change or a **Bounded stop**. Record it as
   reverted and say so in the PR comment.
2. Wait on CI: `"$ORCH" review ci`. This is the once-per-loop wait the **CI**
   section describes, and it comes last so the answer covers the fixes as well
   as the change. Append the answer to the last iteration's record
   (`"$ORCH" review path`): every other record carries what CI said, and a loop
   that ends well is the one whose record should not be the blank.
   `failing` or `unreachable` here is a **Bounded stop**.
3. Go to the terminal state that leaves.

## Terminal states

**Success** - nothing chosen, or everything chosen was fixed in place and
verified. Post the PR comment, then `"$ORCH" review ready`, which marks the PR
ready and records the flow `done` as one operation.

**Handoff** - a clean loop whose chosen work needs a loop of its own. Post the PR
comment. Call the Skill tool with `orchestrator:handoff` to write the file at
`"$ORCH" handoff path review-next`, validate it with
`"$ORCH" handoff validate "$("$ORCH" handoff path review-next)"` - not with
`handoff path review`, which until `loop-next` runs still names the file this
loop *read* - then run `"$ORCH" review loop-next` and print the boundary. It is
a **loop** boundary, not the phase one `flow` prints, because `phase` stays
`review` and the phase is precisely what has not completed. `<n>` is the loop
that just finished, which is one less than the number `loop-next` printed:

```
Loop <n> complete. Handoff written to <path>.

  Next: /clear, then /orchestrator:next
```

`/clear` then `/orchestrator:next` lands in the next loop.

**Bounded stop** - three ways in, and the recorded reason says which. Two are
the bound: blocking or major still open after five iterations, or an iteration
that fixed something and had no sixth iteration left to review the fixes. The
second is not a failure of the change, but it is not a success either - nothing
has reviewed what iteration five wrote, and marking a PR ready over that claims
a verification that never happened. The third is CI, which does not involve the
bound at all: `failing` with the flake rerun spent or the failure not looking
flaky, or `unreachable`. The rerun is offered once per flow, at the **CI**
section's `failing` bullet; a stop reached past it is not a second offer.

Wait on CI here if the bound ended the loop before it was asked
(`"$ORCH" review ci`), and record the answer whatever it is: someone taking
over a stopped loop needs the whole picture, not a blank. Then post the PR
comment, record the stop reason and the surviving findings, and stop. **Leave
`phase` at `review` and the PR in draft**: `done` means "this succeeded", never
"this stopped". Skip the nit question entirely - nobody wants to be asked about
taste while the change is still broken. Reached from **Closing the loop** step
2 it has already been asked, and nothing re-opens it.

## The PR comment

One comment at **every** loop termination, success and stop alike, posted before
the terminal action:

```
gh pr comment <pr> --body-file <file>
```

`.orchestrator/` is git-excluded and eventually archived, so the PR is the only
durable surface another human ever sees; a single comment at the very end would
compress a three-loop flow and lose the trail.

Carry: iterations run, what was fixed with commit SHAs, covered deviations,
rejected-alternative proposals with the reason each lost, declined nits, the CI
result, and what happens next.
