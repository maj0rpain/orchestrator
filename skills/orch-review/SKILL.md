---
name: orch-review
description: Run one review loop over an orchestrator flow's draft PR - a human-chosen budget of iterations, each a fresh review from the base SHA, fixing every blocking finding plus the majors and mechanical nits that need no decision, filing the rest as issues at the end, and either marking the PR ready or stopping with the reason recorded. Use from orch-flow's review phase, and when re-entering a flow that is already sitting at that phase after a bounded stop.
---

# Orchestrator review loop

One loop, one session, a **budget** of iterations the human names before the
first one runs. Every iteration is an independent look at the whole change;
the loop fixes what is **blocking** and whatever **major** or **nit** needs no
decision, runs its whole budget whatever any iteration finds, files every
other major and nit as a GitHub issue when it ends, and ends in exactly one
of two places: the PR marked **ready**, or a **bounded stop** with the reason
written down.

The value of the loop is the number of looks, not the re-review of fixes: the
fail-open nobody read until the fifth look still gets its fifth look. See
`docs/adr/0003-the-review-loop-fixes-blocking-only-and-files-the-rest.md`, and
`docs/adr/0016-the-review-loop-fixes-what-needs-no-decision.md` for what the
loop fixes now and the two guards that keep its fixes from churning.

The reviewing itself is done by `mattpocock-skills:code-review`'s parallel
sub-agents, spawned fresh every iteration and never shown your reasoning about
the fixes you just wrote. That is where the independence comes from, and it is
why one session may drive a whole loop - see
`docs/adr/0001-review-loop-runs-in-a-single-session.md`.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at neither path, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

## Before the first iteration

1. Read the handoff: `bash "$ORCH" handoff path review`. It is always
   `03-implement.md`, on every loop of the flow.
2. Take four facts from it, and take them from nowhere else: the **PR**, the
   **spec issue**, the **base SHA**, and the **verification command**. State
   holds the PR and the base SHA as well, and holds the same values; one
   authority is what keeps every loop of a flow reviewing the same change.
3. Read `01-plan.md`'s **Rejected alternatives** and `03-implement.md`'s
   **Deviations**, both in `dirname "$(bash "$ORCH" handoff path review)"`. Both are
   authority over the findings you are about to get.
4. `bash "$ORCH" state get iteration`. Zero means this is the flow's first loop.
   Anything else means a previous loop ended in a bounded stop and a human
   asked for more: read every `.orchestrator/review/iteration-NN.md` already
   there, because their **Filed** lists are what stop this loop re-filing
   what the previous one filed.
5. Ask the budget. **The question blocks** - ask it as a question
   (`AskUserQuestion` on both Claude Code and Junie). Ask once, before the
   first iteration, and never again mid-loop:
   - First loop: "How many review iterations?" Default 5. Any integer ≥ 1;
     there is no upper cap.
   - Re-entry: "How many more?" Same default and range. The new loop continues
     the iteration numbering, so set `budget` to `iteration + n`.

   Then `bash "$ORCH" state set budget <that number>`. The bound is mechanical from
   here: `review begin` enforces it, and a session that has argued with itself
   for four iterations cannot re-remember five as six.

## The iteration

1. `bash "$ORCH" review begin`. It prints the iteration number, or refuses with
   "budget of N iterations spent" - a refusal is the end of the loop, so go to
   **Termination**.
2. Invoke `mattpocock-skills:code-review` (see `docs/host-capabilities.md`
   under the plugin root for how your host invokes a skill), giving it the
   **base SHA** as the fixed point and the **spec issue** as the spec source.
   Always spell it with the `mattpocock-skills:` scope - the bare name is
   ambiguous with another `code-review` skill that may be installed alongside
   this plugin. On a host with no scoped names, invoke it through
   `bash "$ORCH" mp-skill code-review` for the same reason. **Every iteration reviews from the base SHA**, never from the
   previous iteration's HEAD: each is an independent look at the whole change,
   and the Spec axis cannot answer "is the spec implemented" from a diff
   containing one fix.
3. Triage every finding: apply the two demotions under **Authority** first,
   then the **Severity** rubric.
4. Fix what the **Severity** rubric lets the loop fix, writing the fixes
   yourself: every blocking finding, every major that needs no decision and
   changes no behaviour, and every mechanical nit. A **blocking finding about
   behaviour** goes through the `mattpocock-skills:tdd` skill, so the fix
   arrives with a failing test that proves the problem was real; a major or
   nit fix does not, but the verification command in step 5 must still pass
   over it. Everything else is recorded for filing, with the rule that kept it
   out:
   - **Loop-authored lines.** A major or nit on lines this loop's own fix
     commits wrote is filed, never fixed - fixes drawing findings drawing fixes
     is what never converges. Tell them apart with `git blame` on the flagged
     lines against the fix SHAs in *this* loop's iteration records - those
     numbered above the `iteration` read in **Before the first iteration**,
     step 4; a previous loop's fixes are not loop-authored. A blocking finding there is still
     fixed.
   - **The final iteration** - the one whose number equals `budget` - fixes
     only what is blocking and files its majors and nits, since nothing reviews
     what it writes.
   - **Already filed.** A finding a previous loop's **Filed** list already
     carries is neither fixed nor filed again; record it with its issue number
     as met again.
5. Run the verification command. A failure is a blocking finding, and it is
   fixed in this iteration like any other.
6. Commit once, subject in this repo's plain imperative style (`Replace precheck
   and state validate with one doctor command`), describing the fix rather than
   the iteration; the body lists the findings addressed and points at the
   record. An iteration that fixed nothing makes no commit.
7. Push. CI is not waited on here.
8. Write the record to `bash "$ORCH" review path`: every finding with its axis and
   severity on one line, which were fixed - blocking, major, and nit alike -
   and the fix commit SHA, which were demoted and on what authority, which are
   waiting to be filed and the rule that kept each out, and which were met
   again already filed, with the issue number. The fix SHAs listed here are
   what later iterations of this loop blame against.
9. Go to step 1. Nothing found ends the loop early; only the budget does. A
   **clean iteration** - nothing fixed and nothing committed - is the cheap
   case, and buying the extra looks is the point.

## Severity

`code-review` reports findings unranked across two axes and refuses to rank
across them. The ranking is yours, and it decides which findings the loop may
fix without asking anyone:

- **blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. Always fixed, in every iteration.
- **major** - the change works but carries real cost: a documented standard
  breached, a smell with teeth, scope nobody asked for. Fixed, unless the fix
  needs a choice between alternatives the plan, spec, and deviations did not
  settle, or would change behaviour - a major means the change works, so a fix
  that changes behaviour was never a major fix. Those are filed, the options
  in the body. A PR is marked ready with filed majors open against it - the
  issue carries the reasoning, and triage decides against the whole codebase
  whether it is worth fixing at all.
- **nit** - taste and judgement. Fixed only when **mechanical**: exactly one
  correct fix, confined to the lines it names, no behaviour change, no wording
  or taste to choose - a typo, an unused import, a comment naming the wrong
  function, a broken link. Rewording prose is never mechanical, however small.
  Filed otherwise.

A major or nit on **loop-authored lines** or found in
the **final iteration** is filed, never fixed - see step 4 of **The
iteration**.

Major and nit are triage priorities on a filed finding, which is why they live
in the issue's label rather than its title: the label can change.

## Authority: what the loop refuses to act on

Applied before the rubric. Both would overturn a decision a human already made
with more context than you have:

- **Covered deviations.** A Spec-axis finding covered by `03-implement.md`'s
  **Deviations** section becomes a recorded note: not fixed, not filed. See
  `docs/adr/0002-recorded-deviations-outrank-the-spec-axis.md`. Anything the
  section does *not* cover gets the normal rubric, so scope creep is still
  caught.
- **Rejected alternatives.** A finding proposing something `01-plan.md`'s
  **Rejected alternatives** ruled out becomes a recorded note with the reason it
  lost: not fixed, not filed. Demote on `code-review`'s **output**, and leave
  its sub-agent prompts alone: filtering the output also catches a rejected
  design arrived at by a different route.

Demoted findings go in the record and the PR comment, and are never filed: an
issue whose only correct triage is "close" is noise, but a deliberate omission
nobody merging can see is indistinguishable from a defect.

## CI

Waited on **once per loop**, at **Termination**, and never inside an
iteration: that would block a single session for most of an hour, and the fix
commits are pushed as they land anyway.

`bash "$ORCH" review ci` polls the PR's checks and prints one of four words, exiting
non-zero on the last two:

- **green** - carry on.
- **none** - the repo has no checks. Carry on: requiring CI in a repo that has
  none would make this plugin unusable in its own repo.
- **failing** - a required check failed, and the detail lines name which.
  Required means required by the branch protection of the PR's base branch. If it
  looks flaky rather than caused by the change, the flow has **one** flake
  rerun: `bash "$ORCH" state get flake_rerun_used` reads `true` once it is spent and
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
  Actions run has no rerun to spend and is a **bounded stop** on the spot. Then
  record `bash "$ORCH" state set flake_rerun_used true` and ask `review ci` again. A
  second failure is a **bounded stop**. That second ask restarts the
  fifteen-minute wait rather than inheriting what is left of the first, because
  a rerun restarts the checks - so this one path, once per flow, can wait longer
  than the cap.
- **unreachable** - GitHub would not answer, or the checks were still pending at
  the cap. A **bounded stop**: marking a PR ready over a result nothing ever
  produced claims a verification that never happened.

## Termination

Reached when `review begin` refuses. The same close-out runs whichever
terminal state follows, in this order:

1. Wait on CI: `bash "$ORCH" review ci`. Append the answer to the final iteration's
   record (`bash "$ORCH" review path` still names it, because the refusal spent
   nothing).
2. File the findings - see **Filing**. Every unfixed major and nit from every
   record of this flow, stop included: a bounded stop loses no findings.
3. Post the PR comment - see **The PR comment**.
4. Decide the terminal state:

**Ready** - the final iteration was clean, and CI said `green` or `none`.
Append `## Terminal state` to the final iteration's record, first line
`ready`, before the terminal action itself. `bash "$ORCH" review ready` marks the
PR ready and records the flow `done` as one operation. No question is asked
first: a loop that ends well ends without parking on a prompt.

**Bounded stop** - two ways in, and the recorded reason says which. The final
iteration fixed something - which, since it fixes only what is blocking,
means it found something blocking: nothing has reviewed what it wrote, and
marking a PR ready over that claims a verification that never happened. Or CI: `failing`
with the flake rerun spent or the failure not looking flaky, or `unreachable`.
Append `## Terminal state` to the final iteration's record, first line `stop`,
followed by the reason, before stopping. **Leave `phase` at `review` and the
PR in draft**: `done` means "this succeeded", never "this stopped". A human
may re-enter the review phase from here; that is a fresh loop with its own
budget, and **Before the first iteration** describes it.

`## Terminal state` is written exactly once, here, only once a terminal state
has actually been decided - never guessed or backfilled. It is what
`bash "$ORCH" redo review` and `doctor --flow` both read, through the same
`review_terminal_state` classifier, to tell a loop that genuinely finished
from one whose driving session simply died mid-budget.

## Filing

At termination, gather every major and nit from every
`.orchestrator/review/iteration-NN.md` of this flow, demoted findings already
excluded and fixed ones with them. Deduplicate: findings at the same file and
line making the same claim are one finding, however many iterations reported
it. Skip any already carrying an issue number from a previous loop - once
filed, a finding belongs to triage - and list it for the human in the PR
comment and your closing message as met again. File each of the rest:

```
bash "$ORCH" review file <major|nit> "<title>" --body-file <file>
```

It creates the `review:<severity>` label if the repo lacks it, resolves the
repo's own name for `needs-triage` from `docs/agents/triage-labels.md`, opens
the issue with both, and prints the number. The title is the
finding's one-line claim with no prefix - the severity lives in the label.
Nothing calls `gh issue create` or `gh label create` directly.

The body carries, in this order:

1. the reviewer's finding, verbatim;
2. the axis - Standards or Spec;
3. the severity, and the one-line reason it was assigned;
4. the file and line, at the PR's head SHA;
5. a link to the PR;
6. one line on why it was not fixed in the loop, naming the rule that kept it
   out: its fix needs a decision (list the options), would change behaviour,
   the nit is not mechanical, it sits on loop-authored lines, or it was found
   in the final iteration.

`.orchestrator/` is git-excluded and eventually archived, so the body is the
record, not a link to one.

Write the numbers back into the final iteration's record as a **Filed** list -
number, severity, title - so a human reading the trail can follow a finding to
its issue, and the next loop can see what is already filed.

## The PR comment

One comment at **every** termination, ready and stop alike, posted before the
terminal action:

```
gh pr comment <pr> --body-file <file>
```

The PR is the only durable surface another human ever sees. Carry: iterations
run, what was fixed - blocking, majors, and nits - with severity and commit
SHAs, the issues filed with number, severity, and title, the findings met
again already filed with their issue numbers so the human can triage them,
covered deviations, rejected-alternative proposals with the reason each lost,
the CI result, the host fallbacks the loop took (per
`docs/host-capabilities.md`, or `None (<host>).`), and what happens next.
