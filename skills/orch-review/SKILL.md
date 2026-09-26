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

You are the loop's **driver**. You start every agent, triage what the
reviewers report, wait on CI, and decide the terminal state; fresh plugin
agents do the rest. Two **reviewers** look at the change every iteration, a
**fixer** fixes when triage leaves something to fix, and a **closer** files
and reports once the loop ends. None of them sees your reasoning or another's,
which is where the independence comes from, and why one session may drive a
whole loop - see `docs/adr/0001-review-loop-runs-in-a-single-session.md`,
`docs/adr/0017-the-review-loops-driver-hands-fixing-and-filing-to-fresh-agents.md`
for why the driver hands off the fixing and filing, and
`docs/adr/0018-the-review-loop-owns-its-reviewer-briefs.md` for why the loop
starts its own reviewers.

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

1. Find the handoff: `bash "$ORCH" handoff path review`. It is always
   `03-implement.md`, on every loop of the flow. Read it one section at a
   time, through `bash "$ORCH" handoff section <file> <heading>`, and never
   whole:

   ```
   h="$(bash "$ORCH" handoff path review)"
   bash "$ORCH" handoff section "$h" "PR"        # likewise "Spec issue", "Base SHA", "Verification"
   ```
2. Take four facts from those sections, and take them from nowhere else: the
   **PR**, the **spec issue**, the **base SHA**, and the **verification
   command** - the **Verification** section's first line, alone; any line
   after it records a result, not part of the command. State holds the PR and the base SHA as well, and holds the same
   values; one authority is what keeps every loop of a flow reviewing the
   same change.
3. Read `01-plan.md`'s **Rejected alternatives** and `03-implement.md`'s
   **Deviations**, the same way:

   ```
   bash "$ORCH" handoff section "$(dirname "$h")/01-plan.md" "Rejected alternatives"
   bash "$ORCH" handoff section "$h" "Deviations"
   ```

   Both are authority over the findings you are about to get.
4. `bash "$ORCH" state get iteration`. Zero means this is the flow's first loop.
   Anything else means a previous loop ended in a bounded stop and a human
   asked for more: read every `.orchestrator/review/iteration-NN.md` record
   already there - the records, not the reviewers' reports beside them -
   because their **Filed** lists are what stop this loop re-filing what the
   previous one filed. Triage's **Met again** is the only check against them,
   since the closer reads only this loop's records. Any **open blocking**
   finding in the last of them still stands: it goes into this loop's first
   triage.
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
2. Start both reviewers in parallel - see **The reviewers** - and wait for
   both to return. **Every iteration reviews from the base SHA**, never from
   the previous iteration's HEAD: each is an independent look at the whole
   change, and the Spec axis cannot answer "is the spec implemented" from a
   diff containing one fix.
3. Read both report files, once each, and triage every finding in them, plus
   any **open blocking** finding the previous iteration left - or, on a
   re-entry's first iteration, the previous loop's final record: it still
   stands whether or not a reviewer met it again. Apply the two
   demotions under **Authority** first, then the **Severity** rubric, then
   give each finding one disposition:
   - **Fix** - every blocking finding, every major that needs no decision and
     changes no behaviour, and every mechanical nit, except where a rule below
     keeps it out.
   - **File** - every other major and nit, with the rule that kept it out:
     - **Loop-authored lines.** A major or nit on lines this loop's own fix
       commits wrote is filed, never fixed - fixes drawing findings drawing
       fixes is what never converges. Tell them apart with `git blame` on the
       flagged lines against the fix SHAs in *this* loop's iteration records -
       those numbered above the **loop boundary**, the `iteration` read in
       **Before the first iteration**, step 4; a previous loop's fixes are
       not loop-authored. A
       blocking finding there is still fixed.
     - **The final iteration** - the one whose number equals `budget` - fixes
       only what is blocking and files its majors and nits, since nothing
       reviews what it writes.
   - **Demoted**, with its authority - see **Authority**.
   - **Met again** - a finding a previous loop's **Filed** list already
     carries - the same file and line making the same claim, as the
     closer's deduplication matches, never the title alone - is neither
     fixed nor filed again; it keeps its issue number. This is the one owner
     of the already-filed rule: the closer files whatever this loop's records
     leave waiting and only reports what triage marked met again. A
     **Filed** entry with no file and line predates that format; match it on
     its title against the finding's claim.

   Done when every finding in both reports has exactly one disposition.
4. Nothing to fix means no fixer - a **clean iteration**. An iteration that
   starts a fixer is never clean, even if the fixer fixes nothing. Write the record
   to `bash "$ORCH" review path` yourself, in the shape the fixer's brief
   gives, reading just that section - the brief's last, whose template holds
   `##` headings of its own, so read to the end of the file:

   ```
   sed -n '/^## The record$/,$p' "<plugin root>/agents/orch-fixer.md"
   ```

   `Verification` reads `not run - nothing changed`, and **Fixed this
   iteration** and **Open blocking** read `None`. Then go to step 1.
5. Otherwise start the **fixer** - see **The fixer** - and wait for it. Of the
   five or so lines it returns, keep two things for the rest of the loop:
   its commit SHA, for later iterations' loop-authored-lines check, and any
   blocking finding it could not fix, which is now **open blocking** and goes
   into the next iteration's triage. A major or nit it could not fix needs
   nothing from you: its record lists it as waiting to be filed, and the
   closer files it.
6. Go to step 1. Nothing found ends the loop early; only the budget does. A
   **clean iteration** - nothing to fix, so no fixer - is the cheap case, and
   buying the extra looks is the point.

You never edit the change: every line the loop fixes is the fixer's. The one
exception is a host with no fresh subagent: there the **Host fallback** under
**Starting an agent** has you do the fixer's and the closer's work in this
session, and you record it as a host fallback.

## The reviewers

Two plugin agents under the plugin root's `agents/`, one per axis:

- **`orch-reviewer-standards`** - the Standards axis: the repo's documented
  coding standards, plus the plugin's own smell baseline.
- **`orch-reviewer-spec`** - the Spec axis: whether the change implements what
  the spec issue asked for.

Start both at once, as fresh agents (see **Starting an agent**), both in one
message. Each prompt carries four variables and nothing else - no spec body,
no diff, no brief, no word about earlier iterations or fixes:

```
Base SHA: <base SHA>
Spec issue: #<spec issue>
Iteration: <NN>
Report path: <report path>
```

The report paths sit beside the record `bash "$ORCH" review path` names, with
the axis as a suffix: `iteration-NN-standards.md` and `iteration-NN-spec.md`.
Each reviewer fetches the diff and the spec itself, writes its findings there
unranked, each with its file, line, and claim, and returns one line naming its
report and its finding count. A missing report, or one that says the base SHA
did not resolve or the diff was empty, is a failed review, not a clean one:
start that reviewer again once, and record a second failure in the record as
that axis's **missing look**. A missing look in the final iteration blocks
**Ready**: nothing looked along that axis last, so the loop cannot claim the
final look was clean.

The reviewers have no Edit or Write tool, and their briefs allow exactly one
write, the report. That is what keeps a review from quietly becoming a fix.

## The fixer

**`orch-fixer`**, under the same `agents/`, started fresh (see **Starting an
agent**) at most once per iteration, and only when triage left something to
fix. It fixes, verifies, commits once, pushes, and writes the iteration's
record; its brief carries the commit style, the record's format, and what to
do when the verification command stays red. Its prompt carries:

```
PR: #<pr>
Spec issue: #<spec issue>
Base SHA: <base SHA>
Fixable list: <each finding: axis, severity, file:line, claim>
Triaged out: <each other finding: axis, severity, file:line, claim, disposition>
Fix SHAs: <this loop's earlier fix commits, or none>
Iteration: <NN> of budget <budget>
Verification command: <command>
Host fallbacks: <this iteration's, or none>
Missing looks: <each axis whose reviewer failed twice, or none>
Record path: <bash "$ORCH" review path>
```

A disposition names its reason: the authority for a demotion, the rule for
a finding to file, the issue number for one met again.

## The closer

**`orch-closer`**, under the same `agents/`, started fresh (see **Starting an
agent**) once per loop, at **Termination**, after the terminal state is
decided. It files every unfixed major and nit across this loop's records -
those numbered above the **loop boundary**, less any a later iteration of
this loop fixed - through `orch.sh review file`, posts the loop's one PR
comment, writes the **Filed** list into the final record, and returns the
issue numbers; its brief carries the Filing and PR-comment rules. Its prompt carries:

```
PR: #<pr>
Records directory: .orchestrator/review/
Final record: <bash "$ORCH" review path>
Loop boundary: <the iteration read in Before the first iteration, step 4>
CI result: <review ci's answer, and any flake rerun spent>
Host fallbacks: <every fallback the loop took, per docs/host-capabilities.md, or None (<host>).>
Terminal state: <ready, or stop and its reason>
What happens next: <the PR marked ready and the flow done, or the flow left at review for a human to re-enter>
orch.sh: <the path ORCH holds>
```

## Starting an agent

The reviewers, the fixer, and the closer are all started the same way: as a
fresh subagent, never a fork, which would inherit this context. On Claude
Code that is the Agent tool with `subagent_type` set to the agent's name under
the `orchestrator:` plugin scope.

**Host fallback.** A host that cannot start one of them natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback, with the
prompt given for that agent here. The review phase writes no handoff, so
record the fallback in the iteration's record and pass it to the closer for
the PR comment.

## Severity

The reviewers report findings unranked, one report per axis, and never rank
across the two. The ranking is yours, and it decides which findings the loop
may fix without asking anyone:

- **blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. Always handed to the fixer, in every
  iteration; one the fixer could not fix stays **open blocking**, is never
  filed, and holds the loop out of **Ready**.
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
the **final iteration** is filed, never fixed - see step 3 of **The
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
  lost: not fixed, not filed. Demote on the reviewers' **reports**, and leave
  their briefs alone: filtering the reports also catches a rejected design
  arrived at by a different route.

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

1. **CI.** Wait on it, spending the flake rerun if it applies - see **CI**.
   Append the answer to the final iteration's record (`bash "$ORCH" review
   path` still names it, because the refusal spent nothing).
2. **Decide the terminal state** - **Ready** or **Bounded stop**, below.
3. **Start the closer** with that decision - see **The closer** - and wait
   for its issue numbers.
4. **Write `## Terminal state`** into the final iteration's record: first
   line `ready`, or `stop` followed by the reason.
5. **Run the terminal action.**

**Ready** - all four hold: the final iteration was clean, its record lists no
**open blocking** finding and no **missing look**, and CI said `green` or
`none`. The terminal action is `bash "$ORCH" review ready`, which marks the
PR ready and records the flow `done` as one operation. No question is asked
first: a loop that ends well ends without parking on a prompt.

**Bounded stop** - anything else, and the recorded reason says which, naming
the finding where there is one. The final iteration was not clean: it started
a fixer - which, since it fixes only what is blocking, means it found
something blocking:
nothing has reviewed what it wrote, and marking a PR ready over that claims a
verification that never happened. An open blocking finding or a missing look
remains in the final record. Or CI: `failing` with the flake rerun spent or
the failure not looking flaky, or `unreachable`. The terminal action is to
stop: **leave `phase` at `review` and the PR in draft**, and tell the human
the reason and the closer's issue numbers. `done` means "this succeeded",
never "this stopped". A human may re-enter the review phase from here; that
is a fresh loop with its own budget, and **Before the first iteration**
describes it.

`## Terminal state` is written exactly once, here, only once a terminal state
has actually been decided - never guessed or backfilled. It is what
`bash "$ORCH" redo review` and `doctor --flow` both read, through the same
`review_terminal_state` classifier, to tell a loop that genuinely finished
from one whose driving session simply died mid-budget.
