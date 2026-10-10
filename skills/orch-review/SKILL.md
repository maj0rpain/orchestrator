---
name: orch-review
description: Run one review loop over an orchestrator flow's draft PR - a human-chosen budget of iterations, each a fresh review from the base SHA, fixing every blocking finding plus the majors and mechanical nits that need no decision, filing the rest as issues at the end, and either marking the PR ready or stopping with the reason recorded. Use from orch-flow's review phase, and when re-entering a flow that is already sitting at that phase after a bounded stop. Also holds the review pass, one look by the same two reviewers with no loop around it: run by orch-quick-implement before its PR opens, and standalone, outside any flow, when a human asks for a review of the current branch against a given issue or runs /orchestrator:review-pass <issue>.
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

The same two reviewers also run once with no loop around them, as a **review
pass** - see **Review pass**, the one definition of it.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
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
   bash "$ORCH" handoff section "$h" "PR"        # likewise "Spec issue", "Verification"
   ```
2. Take three facts from those sections, and take them from nowhere else:
   the **PR**, the **spec issue**, and the **verification command** - the
   **Verification** section's first line, alone; any line after it records a
   result, not part of the command. State holds the PR as well, and holds the
   same value; one authority is what keeps every loop of a flow reviewing
   the same change. The **base SHA** is the exception: every iteration's base
   sync moves it, so each iteration reads it from state after its sync (step
   2 of **The iteration**), never from the handoff, whose **Base SHA**
   records only its value at the end of implement.
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
   with the host's ask tool (`AskUserQuestion` on Claude Code, `ask_user`
   on Junie). Ask once, before the
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
2. **Base sync.** Bring the PR's branch up to date with its base before
   anyone looks at it, so the final clean iteration reviewed the code that
   will merge. Follow **A driver's base sync** in `agents/orch-resolver.md`
   under the plugin root (found as step 5 says), with the spec issue as the
   resolver's issue. Then read
   this iteration's **base SHA**: `bash "$ORCH" state get base_sha`, after the
   sync, for this iteration's reviewers and fixer.
   Keep the sync's **Merge resolutions**, per **Merge resolutions** in the
   same file, for this iteration's record and fixer. A resolver's
   `Verification` reading `fail` does not stop the iteration: the reviewers
   judge the merged code.

   A **failed sync** is a bounded stop. Write this iteration's record to
   `bash "$ORCH" review path` yourself, in the record's shape (step 5): no
   **Findings** - `None - no review ran: the base sync failed` - and
   `Verification` reading `not run - base sync failed`, **Merge resolutions**
   naming the failure, the resolver's report if one returned, and any merge
   left in progress. Leave that merge for the human, and go to
   **Termination**: its terminal state is a bounded stop whose reason names
   the unresolved merge, or the refusal.
3. Start both reviewers in parallel - see **The reviewers** - and wait for
   both to return. **Every iteration reviews from its base SHA**, the one
   step 2 read, never from the previous iteration's HEAD: each is an
   independent look at the whole change, and the Spec axis cannot answer "is
   the spec implemented" from a diff containing one fix.
4. Read both report files, once each, and triage every finding in them, plus
   any **open blocking** finding the previous iteration left - or, on a
   re-entry's first iteration, the previous loop's final record: it still
   stands whether or not a reviewer met it again. Apply the two
   demotions under **Authority** first, then the **Severity** rubric, then
   give each finding one disposition:
   - **Fix** - every blocking finding, every major that needs no decision,
     and every mechanical nit, except where a rule below keeps it out.
   - **File** - every other major and nit, with the rule that kept it out:
     - **Spec question.** A major whose fix needs a decision about *what the
       change does* - its behaviour - that the spec, plan and deviations
       leave unsettled: silent, ambiguous, or self-contradictory on it. It is
       filed with the rule `spec question`, and holds the PR out of **Ready**
       (see **Termination**). A finding that the change contradicts what the
       spec clearly asks for is blocking, not a spec question; a decision
       about structure only - which of two refactorings, which name - is an
       ordinary major that needs a decision, filed without blocking. Only a
       major can be one: a nit questioning behaviour was mis-ranked, and is a
       major. Classify by the finding's content, never by when or where it
       was found: one in the final iteration or on loop-authored lines still
       takes the rule `spec question`, and still blocks.
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
5. Nothing to fix means no fixer - a **clean iteration**. An iteration
   that starts a fixer is never clean, even if the fixer fixes nothing.
   Write the record to `bash "$ORCH" review path` yourself, in the shape the fixer's brief
   gives, reading just that section - the brief's last, whose template holds
   `##` headings of its own, so read to the end of the file:

   ```
   sed -n '/^## The record$/,$p' "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"
   ```

   If `CLAUDE_PLUGIN_ROOT` is unset, the plugin root is found as for `ORCH`:
   two directories above the `orch.sh` that `ls` printed, else two directories
   above this skill's own directory.

   `Verification` reads `not run - nothing changed`, **Fixed this
   iteration** and **Open blocking** read `None`, **Merge resolutions**
   holds step 2's, and **PR body** reads `Not checked - no
   commit`. Then go to step 1.
6. Otherwise start the **fixer** - see **The fixer** - and wait for it. Of the
   five or so lines it returns, keep two things for the rest of the loop:
   its commit SHA, for later iterations' loop-authored-lines check, and any
   blocking finding it could not fix, which is now **open blocking** and goes
   into the next iteration's triage. A major or nit it could not fix needs
   nothing from you: its record lists it as waiting to be filed, and the
   closer files it - a major listed with the rule `spec question` still holds
   the PR out of **Ready**.
7. Go to step 1. Nothing found ends the loop early; only the budget does,
   or a failed base sync at step 2. A
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
message. Each prompt carries five variables and nothing else - no spec body,
no diff, no brief, no word about earlier iterations or fixes:

```
Base SHA: <this iteration's base SHA>
Spec issue: #<spec issue>
Iteration: <NN>
Report path: <report path>
orch.sh: <the path ORCH holds>
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
Base SHA: <this iteration's base SHA>
Merge resolutions: <step 2's, per Merge resolutions in agents/orch-resolver.md>
Fixable list: <each finding: axis, severity, file:line, claim>
Triaged out: <each other finding: axis, severity, file:line, claim, disposition>
Fix SHAs: <this loop's earlier fix commits, or none>
Iteration: <NN> of budget <budget>
Verification command: <command>
Host fallbacks: <this iteration's, or none>
Missing looks: <each axis whose reviewer failed twice, or none>
Record path: <bash "$ORCH" review path>
orch.sh: <the path ORCH holds>
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
CI result: <the final record's ## CI section>
Host fallbacks: <every fallback the loop took, per docs/host-capabilities.md, or None (<host>).>
Terminal state: <ready, or stop and its reason; spec questions as stop - spec question: <file>:<line> <title>, one per question>
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
  settle. Those are filed, the options in the body. A fix that changes
  behaviour the spec settles makes the finding blocking; one whose behaviour
  the spec leaves unsettled makes it a **spec question** (step 4 of **The
  iteration**). A PR is marked ready with filed majors open against it - the
  issue carries the reasoning, and triage decides against the whole codebase
  whether it is worth fixing at all - unless one is a spec question this loop
  filed: that holds the PR out of **Ready** until a human rules on it. See
  `docs/adr/0042-a-spec-question-the-review-loop-files-holds-the-pr-in-draft.md`.
- **nit** - taste and judgement. Fixed only when **mechanical**: exactly one
  correct fix, confined to the lines it names, no behaviour change, no wording
  or taste to choose - a typo, an unused import, a comment naming the wrong
  function, a broken link. Rewording prose is never mechanical, however small.
  Filed otherwise.

A major or nit on **loop-authored lines** or found in
the **final iteration** is filed, never fixed - see step 4 of **The
iteration** - though a spec question found there still holds the PR out of
**Ready**.

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
  none would make this plugin unusable in its own repo. It arrives without
  waiting the grace when the repo shows no evidence of CI - no workflow files
  in the head, no required checks on the base branch, and no check or status
  on an earlier PR commit or the base tip - and its detail line says which.
- **failing** - a required check failed, and the detail lines name which.
  Required means required by the branch protection of the PR's base branch. If it
  looks flaky rather than caused by the change, the flow has **one** flake
  rerun: `bash "$ORCH" state get flake_rerun_used` reads `true` once it is spent and
  empty while it is not. Spend it with `bash "$ORCH" review rerun <pr>`, which
  reruns the failed jobs of the GitHub Actions run behind the PR's first failed
  or cancelled check:

  - **exit 0** - the rerun started. Only this spends the flake rerun.
  - **exit 1** - that check is not an Actions run, so there is no rerun to
    spend: a **bounded stop** on the spot, spending nothing.
  - **exit 2** - anything else (GitHub unreadable, the rerun refused): a
    **bounded stop**.

  On exit 0, record `bash "$ORCH" state set flake_rerun_used true` and ask `review ci` again. A
  second failure is a **bounded stop**. That second ask restarts the
  fifteen-minute wait rather than inheriting what is left of the first, because
  a rerun restarts the checks - so this one path, once per flow, can wait longer
  than the cap.
- **unreachable** - GitHub would not answer, or the checks were still pending at
  the cap. A **bounded stop**: marking a PR ready over a result nothing ever
  produced claims a verification that never happened.

## Termination

Reached when `review begin` refuses, or from a failed base sync (step 2 of
**The iteration**). The same close-out runs whichever terminal state
follows, in this order:

1. **CI.** Wait on it, spending the flake rerun if it applies - see **CI**.
   Append a `## CI` section to the final iteration's record (`bash "$ORCH"
   review path` still names it, because the refusal spent nothing), in the
   shape `agents/orch-fixer.md`'s **The record** shows: first line the word
   `review ci` printed, then its detail lines, then a line saying so if the
   flake rerun was spent.
2. **Decide the terminal state** - **Ready** or **Bounded stop**, below.
3. **Start the closer** with that decision - see **The closer** - and wait
   for its issue numbers. A stop for spec questions has no issue numbers
   yet: its `Terminal state:` input names each question as `stop - spec
   question: <file>:<line> <title>`, one per question. The closer's return
   carries a `Spec questions:` line naming each with the number it got.
4. **Write `## Terminal state`** into the final iteration's record: first
   line `ready`, or `stop` with its reason either on the same line after a
   separator (`-`, `–`, `—`, `:`) or on the lines below. Blank lines under
   the heading are skipped. Any other first line reads as `malformed`, and
   redo refuses it. A stop for spec questions names each from the closer's
   `Spec questions:` line, with its number:
   `stop - spec question #<n>: <file>:<line> <title>`; one the closer could
   not file reads `stop - spec question: <file>:<line> <title> (not filed)`,
   and still blocks.
5. **Run the terminal action.**

**Ready** - all five hold: the final iteration was clean, its record lists no
**open blocking** finding and no **missing look**, CI said `green` or
`none`, and no record of this loop - numbered above the **loop boundary** -
lists a spec question waiting to be filed. A spec question a previous loop
filed and triage marks **met again** does not count: the human re-entering
review after that stop is the ruling, so only spec questions this loop newly
files block. The terminal action is `bash "$ORCH" review ready`, which marks the
PR ready and records the flow `done` as one operation. No question is asked
first: a loop that ends well ends without parking on a prompt.

**Bounded stop** - anything else, and the recorded reason says which, naming
the finding where there is one. The final iteration was not clean: it started
a fixer, whether for a blocking finding this review made or for open blocking
carried in. Nothing has reviewed what it wrote, and marking a PR ready over
that claims a verification that never happened. An open blocking finding or a missing look
remains in the final record. Or this loop filed a spec question, a
behaviour decision the spec left open: the reason names each, so a human
rules on it before the PR goes ready. Or a base sync that failed, the reason naming
the unresolved merge or the refusal. Or CI: `failing` with the flake rerun
spent or the failure not looking flaky, or `unreachable`. The terminal action is to
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

## Review pass

One look at a change by the two reviewers above, with no loop around it: no
budget, no severity, no fixer, no closer, nothing filed. A quick
implementation runs one before its PR opens (the `orch-quick-implement`
skill's step 6), and a human may run one on demand (see **Standalone review
pass**). Nothing else in this skill applies to a pass. The loop's
rule that the driver never edits does not apply either, because a review pass
has no driver: the session that runs it fixes what it agrees with itself.

The caller names the spec issue and says where the declines, spec questions
and host fallbacks go.

1. **Begin.** Run `bash "$ORCH" review-pass begin <issue>`. If it dies,
   relay its message and stop. It refuses a detached HEAD, the base branch,
   and an issue or branch that an active flow holds: that change belongs to
   that flow, never to a review pass. Otherwise it prints this pass's report
   prefix, `.../iteration-NN` - `<prefix>` from here on - and `NN` is this
   pass's number. Each pass on a branch takes the next number, so a second
   pass never overwrites the first.
2. **Base SHA.** Run `bash "$ORCH" branch base-sha`. That is the base
   branch's tip that `branch off` recorded, or that its latest base sync
   moved it to, or, on a branch made without it, the merge-base with its
   base branch.
3. **Start both reviewers** - `orch-reviewer-standards` and
   `orch-reviewer-spec` - at once, as fresh agents, never forks, both in one
   message (see **Starting an agent** for how to start one). Each prompt
   carries these five variables and nothing else - no issue body, no diff,
   no brief:

   ```
   Base SHA: <base SHA>
   Spec issue: #<issue>
   Iteration: <NN>
   Report path: <prefix>-<standards|spec>.md
   orch.sh: <the path ORCH holds>
   ```

4. **A failed review.** A missing report, or one that says the base SHA did
   not resolve or the diff was empty, is a failed review, not a clean one.
   Start that reviewer again once. If it fails a second time, stop the pass
   and tell the human which axis failed. A pass never claims an axis nobody
   looked along.
5. **Fix.** Read both reports, and fix, yourself, every finding you agree
   with that is not a spec question (step 7). Use no fixer agent, no closer,
   no severity, no budget, and file nothing. Commit the fixes as one commit.
6. **Declines.** Record each finding you decline, one line each:
   `` `file:line` - <claim> - <reason> `` - its `file:line`, or `-` when the
   report gave `-` for its location; the finding's claim, in a few words;
   and your reason for declining it. If you declined none, the record says
   `None declined.` The caller says where this record goes. A spec question
   is never declined.
7. **Spec questions.** A finding is a **spec question**, the third outcome
   beside fix and decline, when its fix needs a decision about *what the
   change does* - its behaviour - that the spec, plan and deviations leave
   unsettled: silent, ambiguous, or self-contradictory on it. This is the
   review loop's test (step 4 of **The iteration**) without its "only a
   major" clause: a pass has no severity, so judge it by the finding's
   content alone. A finding that the change contradicts what the spec
   clearly asks for is not one: fix it. A decision about structure only -
   which of two refactorings, which name - is not one either: fix or
   decline it as any other finding. Never fix a spec question by picking a
   behaviour, and never decline one: hand it to the caller. Record each, one
   line each: `` `file:line` - <the open behaviour, phrased as a question> ``,
   with `-` in place of `file:line` when the report gave `-` for its
   location. The caller says where this record goes, and what happens to
   the PR. See
   `docs/adr/0043-a-spec-question-met-in-a-review-pass-reaches-a-human-before-the-pr-is-ready.md`.

A host that cannot start the reviewers natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback, with the
prompt above. Record each fallback where the caller puts host fallbacks.

## Standalone review pass

A human may ask for a review pass on demand - `/orchestrator:review-pass <issue>`,
or in plain words - after a quick implementation, say, or on any branch. It
reviews the branch they are on, from its base SHA, with the given issue as the
spec. It is **Review pass** above with the differences below, never a review
loop: no budget, and nothing filed. See
`docs/adr/0029-a-review-on-demand-is-a-review-pass-not-a-loop.md`.

The issue number comes from the human: the command's one numeric argument, or
the issue they named. With no number, ask for one and wait. Never take it from
`state.json` or the active flow. `--smells` may come before or after the
number, and keeps the Standards reviewer's smell-baseline findings (step 2).
Any other argument starting `--` stops the pass before `review-pass begin`:
say so, naming the argument.

By default a standalone pass leaves out the smell-baseline findings: in PR
138's retro every pass listed 7 to 9 minor smells, fixing them added new diff
for the next pass to pick at, and the passes never converged. A quick
implementation's pass, **Review pass** above, keeps them: it is one look, and
the only Standards look the change gets before its PR (ADR-0021).

1. **Run the pass**: **Review pass** steps 1 to 4, with the human's issue.
   When step 1 dies because an active flow holds this issue or this branch,
   its message names the command to run instead.
2. **Earlier declines and questions.** Before fixing anything, read what
   earlier review passes on the branch's PR declined and asked. Run
   `bash "$ORCH" pr comments <prefix>-comments.md`:
   - exit 0: the PR's comments are in the file (an empty file when there
     are none). Also run `bash "$ORCH" pr fetch <prefix>-body.md` for the
     PR body; if it fails, stop and say so, relaying its reason;
   - exit 1: the branch has no open PR; there is nothing to read, and the
     pass goes on as if no pass had run before;
   - exit 2: GitHub could not be read; stop and say so, relaying its
     reason.

   An earlier review pass is the PR body - a quick implementation's pass -
   or any comment, carrying both a **Review** and a **Host fallbacks**
   heading; its declines are the lines under **Review**. `None declined.`
   contributes nothing, and a comment without both headings is ignored.
   Drop every finding in the two reports that matches an earlier decline,
   and keep it aside for step 5. A finding matches when it names the same
   file and makes the same claim, judged as triage's **Met again** judges
   a finding against an earlier one; line numbers are ignored, since they
   move between passes. A finding at `-` matches on the claim alone, and an
   older decline line with no claim matches on file plus reason. The
   reviewers hear nothing of this: their prompts stay **Review pass** step
   3's five variables.

   Also read every **Spec questions** heading in the PR body and comments:
   its lines are the PR's **earlier spec questions**. They are never matched
   as earlier declines - only lines under **Review** are - and `None.`
   contributes none. An earlier spec question is **ruled** when a **Spec
   rulings** heading in any PR comment lists it, or when a `Spec ruling:`
   comment on the spec issue already answers it. Keep the earlier spec
   questions not yet ruled for step 3, beside the pass's own. With no open
   PR there are none.

   Whether or not there is a PR, read the spec issue's comments with
   `bash "$ORCH" issue comments <issue> <prefix>-issue-comments.md`; if it
   fails, stop and say so, relaying its reason. Its `Spec ruling:` comments
   are the rulings already recorded - by an earlier pass, or by this one
   before a commit or push failed (step 4).

   Then, unless the human passed `--smells`, drop every smell-baseline
   finding still kept, and count them: that count is step 5's hidden
   smells. A **smell-baseline finding** is a Standards-report finding whose
   Source reads `possible <smell> (judgement call)`, with `<smell>` one of
   the twelve in `agents/orch-reviewer-standards.md`'s **Smell baseline**.
   A Source beginning `root-cause check`, or naming no baseline smell, is
   never one; nor is any Spec-report finding. A smell that matched an earlier
   decline is already under **Previously declined** and is not counted.
   Hidden smells are neither fixed nor declined. The reviewers are unchanged:
   the Standards reviewer still reports smells.
3. **Fix, decline and ask**: **Review pass** steps 5 to 7, on the
   findings step 2 kept, with three differences.
   - **Ask first.** Before fixing anything, put the spec questions - the
     pass's own (**Review pass** step 7) and the earlier ones step 2 kept -
     to the human as one batch, each with a recommended answer and its
     reason, and wait. A question a `Spec ruling:` comment on the spec issue
     already answers (step 2) is not asked: that comment rules it, and the
     change is fixed per it below. A question the human leaves without an
     answer stays **unruled**.
   - **Post each ruling.** For each question the human ruled, post one
     comment on the spec issue, `Spec ruling: <question> - <answer>`, with
     `bash "$ORCH" issue comment <issue> <file>`. When a post fails, stop the
     pass before the commit, naming the ruling not recorded and relaying
     its reason: that question stays unruled, and nothing is committed.
   - **Fix per the rulings.** Then fix the change per each ruling, recorded
     ones from step 2 included, beside the other fixes: every fix, ruled
     ones included, lands in step 4's one commit.

   The pass's declines, rulings, unruled questions and host fallbacks go to
   step 5 below.
4. **Commit and push.** The fixes are one commit, as the pass says. When the
   branch has an upstream (`git rev-parse --abbrev-ref @{upstream}`
   succeeds), push it, so an open PR shows the fixes. With no fixes there is
   nothing to commit or push. When the commit or push fails after step 3
   posted rulings, stop and say the fix did not land: the rulings stay on
   the spec issue, and a rerun finds them there (step 2) and does not ask
   them again.
5. **Report.** Write `<prefix>-comment.md` with six headings, **Review** -
   the declines, or `None declined.` - **Previously declined** - each
   finding step 2 dropped as an earlier decline, as its `file:line` and
   claim, or `None.` - **Spec rulings** - each ruling step 3 posted, as
   `<question> - <answer>`, or `None.` - **Spec questions** - each question
   left unruled, as **Review pass** step 7 records it, or `None.` - **Host
   fallbacks** - each fallback taken, or `None (<host>).` - and **Smells**,
   exactly one line: `<N> hidden - rerun with --smells to see them.` when
   step 2 hid N >= 1, `None hidden.` when it hid none, or `Included
   (--smells).` with `--smells`. **Smells** is its own heading, never a line
   under **Review**, so a later pass's step 2 reads no smell as a decline.

   Then, when the branch has an open PR (step 2's `pr comments` exited 0),
   set its state before posting:
   - **Unruled questions.** When at least one question is left unruled, run
     `bash "$ORCH" pr draft`. It does nothing to a PR already a draft. On
     failure, relay its reason, say the PR stayed ready, and name the open
     questions in the session.
   - **Marking ready.** When the PR's body or comments carry at least one
     spec question under a **Spec questions** heading, every one of those
     is ruled - in this pass, or as step 2 found - and none of this pass's
     own is left unruled, run `bash "$ORCH" pr ready`. A draft held for any
     other reason, with no spec question in its body or comments, is never
     marked ready. On failure, relay its reason and say the PR stays a
     draft.

   Either way, then post the report: run
   `bash "$ORCH" pr comment <prefix>-comment.md`:
   - exit 0: the comment is posted; tell the human, with the PR number it
     printed;
   - exit 1: the branch has no open PR; report the declines, the previously
     declined findings, the spec rulings, the unruled spec questions, host
     fallbacks and the **Smells** line in the session instead. The questions
     were still asked, and the rulings are on the spec issue;
   - exit 2: GitHub could not be read, or the post failed; stop and say so,
     relaying its reason. Never report this as nothing declined.

A standalone review pass does not lift the planning edit guard (ADR-0006,
ADR-0025). In a session where planning ran and neither a flow nor a quick
implementation lifted it, the pass's first edit is denied: stop, and tell the
human to run the review pass in a fresh session.
