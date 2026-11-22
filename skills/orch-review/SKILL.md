---
name: orch-review
description: Run one review loop over an orchestrator flow's draft PR - a budget of iterations, chosen by the human or, in an autopilot flow, taken from the plan, each a fresh review from the base SHA, fixing every blocking finding plus the majors and mechanical nits that need no decision, filing the rest as issues at the end, and either marking the PR ready or stopping with the reason recorded. Use from orch-flow's review phase, and when re-entering a flow that is already sitting at that phase after a bounded stop. Not the review pass - one look by the same two reviewers with no loop around it, quick or standalone - which is the orch-review-pass skill.
---

# Orchestrator review loop

One loop, one session, a **budget** of iterations: the human names it before
the first one runs, or in an autopilot flow the plan sets it. Every iteration
is an independent look at the whole change; the loop fixes what is
**blocking** and whatever **major** or **nit** needs no
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
pass** - see the `orch-review-pass` skill, the one definition of it.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset and the host gave this skill's directory,
`ORCH` is `scripts/orch.sh` two directories above this skill's own directory
(the plugin root). Otherwise run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths.

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code,
`agy plugin install <clone-dir>` on Antigravity, or `maj0rpain/orchestrator` as
a Junie extension, which is unverified).

## Before the first iteration

**Every loop, first** - interactive or autopilot, before any
`autopilot answer` or budget question - run `bash "$ORCH" review terminal`. On
`pending` or `interrupted` the previous session died mid-loop: run
`bash "$ORCH" review resume`, read no reply, ask and pick no budget (the
recorded `iteration` and `budget` stand), and carry on from what it
prints. `rerun <i>`
runs iteration `<i>` again from step 2's sync under that number, without
`review begin`; `next` goes to step 1's `review begin`; `terminate` goes to
Termination. Before any of those, run the steps below as a first loop does,
minus step 5 and its budget (the recorded `budget` stands): steps 1-3 (the
handoff facts, **Rejected alternatives** and **Deviations**), step 4's reading
of the earlier records, and steps 6 and 7 (the agent settings and the
`Standards:` line). On a resume, `<loop boundary>` is not `state get
iteration`, which already holds the dead iteration's number: it is the number of
the highest-numbered record that has a `## Terminal state` section - the
previous loop's last record, ended by a bounded stop - or 0 when no record has
one. Every record above it is this loop's. A refusal (exit 1) is the human's to
settle: stop and show its
message. Only `stop`, and `none` on a first loop, take the paths below;
`ready`, `malformed` and `unreadable` keep their usual handling.

**In an autopilot flow** (`bash "$ORCH" autopilot active` exits 0), read
`autopilot.md` in this skill's directory for reply handling, `Rejected
alternatives` amendment, and autopilot budget sizing before steps 1-4 and
6-7 below.

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
   result, not part of the command. In a repo that names a branch
   verification that line is the branch verification, as the handoff records
   it. State holds the PR as well, and holds the
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
   asked for more, or an autopilot flow re-entered automatically (only a human
   decides that a further loop happens, except an autopilot flow's automatic
   re-entry): read every `.orchestrator/review/iteration-NN.md` record
   already there - the records, not the reviewers' reports beside them -
   because their **Filed** lists are what stop this loop re-filing what the
   previous one filed. Triage's **Met again** is the only check against them,
   since the closer reads only this loop's records. Any **open blocking**
   finding in the last of them still stands: it goes into this loop's first
   triage. A record with no `## Evidence` section is read per **Evidence**
   in `agents/orch-fixer.md` (under the plugin root).
5. **In an autopilot flow**, read **Autopilot budget** in `autopilot.md` in
   this skill's directory, set `budget` on a re-entry, and go to step 6.

5i. **Interactive only.** Never reached in an autopilot flow. Ask the budget.
   **The question blocks** - ask it as a question
   with the host's ask tool (see `docs/host-capabilities.md`). Ask once,
   before the first iteration, and never again mid-loop:
   - First loop, whenever `iteration` is 0 - a flow's first loop, and the
     first loop after a Redo: "How many review iterations?" Options 3, 5 and
     8, plus Other for any integer ≥ 1; there is no upper cap. Suggest one
     from the size of the change, by your own judgement, as the planning
     interview's closing route question recommends a route from the scope
     of the work when no default route is set (`orch-interview`'s Closing).
     Weigh lines and files changed
     (`git diff --stat` from the base SHA), the ticket count (`bash "$ORCH"
     ticket list <spec issue>`, one line per sub-issue; no lines means a
     collapsed breakdown, which counts as 1 ticket), and how many modules or
     skills the change touches. Risk weighs above raw size: a small change
     to the review loop's or flow state's own machinery deserves more looks
     than a large docs change.
     - 3: small - one site, one ticket.
     - 5: medium - a few files, 2-3 tickets.
     - 8: large - many modules, 4+ tickets, or the loop or state machinery
       itself.
   - Re-entry: "How many more?" Options 2, 3 and 5, plus Other for any
     integer ≥ 1 (so 1 stays reachable). Suggest one by the **re-entry sizing
     rule** (judge from what step 4's records left, never change size):
     2 for a single stuck blocker (only a clean final iteration can go
     Ready), 3 for steady remaining churn, 5 when the final iterations
     were still finding new blocking findings.

     The new loop continues the iteration numbering, so set `budget` to
     `iteration + n`.

   List the suggested option first, with " (Recommended)" appended to its
   label and a one-clause reason - the size, or what the last loop left - in
   its description, or in the question text where the host's options have
   no description. Exactly one option carries "(Recommended)".

   Then `bash "$ORCH" state set budget <that number>`. The bound is mechanical
   from here: `review begin` enforces it, and a session that has argued with
   itself for four iterations cannot re-remember five as six.
6. Read the agent settings, once, for the whole loop: `bash "$ORCH" agent get
   reviewer`, `agent get fixer`, `agent get closer` and `agent get resolver`,
   per **Agent settings** in `docs/host-capabilities.md` under the plugin
   root. Every reviewer, fixer and closer this loop starts, and every
   resolver its base syncs start, runs on these, never re-read per
   iteration.
7. Resolve the standards documents, once, for the whole loop: `bash "$ORCH"
   review standards` prints one line, `Standards: ` and the repo's standards
   documents, every path one that exists (a declared list may name a section,
   `path#Heading`), or `Standards: none`. Keep it
   verbatim: every reviewer this loop starts gets that same line, never
   re-resolved per iteration (see **The reviewers**).

## The iteration

1. `bash "$ORCH" review begin`. It prints the iteration number, or refuses with
   "budget of N iterations spent" - a refusal is the end of the loop, so go to
   **Termination**.
2. **Base sync.** Bring the PR's branch up to date with its base before
   anyone looks at it, so the final clean iteration reviewed the code that
   will merge. Follow **A driver's base sync** in `agents/orch-resolver.md`
   under the plugin root (two directories above `ORCH`), with the spec issue as
   the resolver's issue. Then read
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
3. **Build the known items**, after the base sync and before anyone looks:

   ```
   bash "$ORCH" review known-items <known path> <loop boundary>
   ```

   `<known path>` sits beside the record `bash "$ORCH" review path` names, as
   `iteration-NN-known.md`, and `<loop boundary>` is the `iteration` read in
   **Before the first iteration**, step 4. It overwrites any file already
   there with `03-implement.md`'s **Deviations**, this loop's **Waiting to be
   filed**, earlier loops' **Filed** and `01-plan.md`'s **Rejected
   alternatives**, each tagged with its source.

   A **refusal** is a bounded stop, as a failed base sync is. Write this
   iteration's record to `bash "$ORCH" review path` yourself, in the
   record's shape (step 5): no **Findings** - `None - no review ran: known
   items could not be built: <orch: message>` - `Verification` reading `not
   run - known items could not be built`, and **Merge resolutions** holding
   step 2's base sync as usual. Go to **Termination**: its terminal state
   reads `stop - known items could not be built.`

   Then start both reviewers in parallel - see **The reviewers** - and wait for
   both to return. **Every iteration reviews from its base SHA**, the one
   step 2 read, never from the previous iteration's HEAD: each is an
   independent look at the whole change, and the Spec axis cannot answer "is
   the spec implemented" from a diff containing one fix.
4. Read both report files, once each, and triage every finding in them, plus
   any **open blocking** finding the previous iteration left - or, on a
   re-entry's first iteration, the previous loop's final record: it still
   stands whether or not a reviewer met it again.
   When that record's `## CI` section reads `failing`, it enters this first
   triage as a blocking finding too, alongside any open blocking finding: name
   the failing check, and run `bash "$ORCH" review ci-log <pr>` yourself for the
   log excerpt (the record holds none), and mark it CI-found in the fixable
   list with that excerpt.
   Every iteration's triage also looks at CI once, without waiting: run
   `bash "$ORCH" review ci --no-wait` (one pass of the probe, never a wait,
   writing no state, wait file or guard). Only `failing` matters: read
   `bash "$ORCH" review ci-log <pr>` and judge the failure by **CI failure
   judgement** in `termination.md`, here in every flow. A failure the change
   can fix is a blocking finding of this iteration, marked CI-found in the
   fixable list with the log excerpt. A failure that looks flaky rather than
   caused by the change, or that needs a decision by that rule, raises nothing
   and is left to **Termination**, which alone may spend the flake rerun. On a
   re-entry's first iteration, a failure the previous record's `## CI` section
   brought in and the look shows again is one finding, not two. `green`, `none`,
   `pending` and `unreachable` raise nothing, and an iteration whose look
   printed `pending` can still be clean. **Termination** is unchanged.

   Read `triage.md` in this skill's directory and apply **Authority**,
   **Severity**, and **Dispositions and triage rules** until every finding
   in both reports has exactly one disposition.
5. Nothing to fix means no fixer - a **clean iteration**. An iteration
   that starts a fixer is never clean, even if the fixer fixes nothing.
   Write the record to `bash "$ORCH" review path` yourself per
   **Clean-iteration record** in `triage.md`, then go to step 1.
6. Otherwise start the **fixer** - see **The fixer** - and wait for it. Of the
   five or so lines it returns, keep two things for the rest of the loop:
   its commit SHA, for later iterations' loop-authored-lines check, and any
   blocking finding it could not fix, which is now **open blocking** and goes
   into the next iteration's triage. A major or nit it could not fix needs
   nothing from you: its record lists it as waiting to be filed, and the
   closer files it - a major listed with the rule `spec question` still holds
   the PR out of **Ready**.
7. Go to step 1. Nothing found ends the loop early; only the budget does,
   a failed base sync at step 2, or known items step 3 could not build. A
   **clean iteration** - nothing to fix, so no fixer - is the cheap case, and
   buying the extra looks is the point.

You never edit the change: every line the loop fixes is the fixer's. The one
exception is a host with no fresh subagent: there the **Host fallback** under
**Starting an agent** has you do the fixer's and the closer's work in this
session, from the fixer's brief, so you follow the fixer's release-record
rule, and you record it as a host fallback.

## The reviewers

Two plugin agents under the plugin root's `agents/`, one per axis:

- **`orch-reviewer-standards`** - the Standards axis: the repo's documented
  coding standards, the plugin's own smell baseline, a doc-agreement check
  that no doc is left disagreeing with the code, and a glossary parse check
  when the change edits `GLOSSARY.md`, whose findings you rank blocking.
- **`orch-reviewer-spec`** - the Spec axis: whether the change implements what
  the spec issue asked for.

Start both at once, as fresh agents (see **Starting an agent**), both in one
message. Each prompt carries seven variables and nothing else - no spec
body, no diff, no brief, no word about earlier iterations or fixes beyond
the known-items file the sixth names. The seventh is the line step 7 of
**Before the first iteration** resolved, so a reviewer reads the standards
documents it lists instead of discovering them:

```
Base SHA: <this iteration's base SHA>
Spec issue: #<spec issue>
Iteration: <NN>
Report path: <report path>
orch.sh: <the path ORCH holds>
Known items: <the iteration-NN-known.md step 3 of The iteration built>
Standards: <the line review standards printed>
```

Each reviewer reviews blind and opens the known items only when it writes its
report, holding back each finding a known item already carries while its
location and cause are unchanged; the Spec reviewer also reads the file's
`## Deviations` before its review, to verify what each deviation built. See
`docs/adr/0045-reviewers-filter-known-items-after-a-blind-review.md`.

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
Re-entry budget: <autopilot re-entry's first iteration only, step 5; else omit>
Base SHA: <this iteration's base SHA>
Merge resolutions: <step 2's, per Merge resolutions in agents/orch-resolver.md>
Fixable list: <each finding: axis, severity, file:line, sites, claim; a CI-found finding marked so, with its `review ci-log` excerpt>
Triaged out: <each other finding: axis, severity, file:line, sites, claim, disposition>
Fix SHAs: <this loop's earlier fix commits, or none>
Iteration: <NN> of budget <budget>
Verification command: <command - the branch verification in a repo that names one>
Host fallbacks: <this iteration's, or none>
Missing looks: <each axis whose reviewer failed twice, or none>
Record path: <bash "$ORCH" review path>
orch.sh: <the path ORCH holds>
```

A disposition names its reason: the authority for a demotion, the rule for
a finding to file, the issue number for one met again. A pattern finding's
entry carries its site list after its `file:line`, as `` Sites: `<file>:<line>`,
`<file>:<line>` ``, every site exactly as the report wrote it, so triage never
drops a site; a finding with one site has no `sites` part.

## Starting an agent

The reviewers, the fixer, and the closer are all started the same way: as a
fresh subagent, never a fork, which would inherit this context. On Claude
Code that is the Agent tool with `subagent_type` set to the agent's name under
the `orchestrator:` plugin scope, on its role's setting from **Before the
first iteration** step 6, per **Agent settings** in
`docs/host-capabilities.md`.

**Host fallback.** A host that cannot start one of them natively takes
`docs/host-capabilities.md`'s **Start a fresh subagent** fallback, with the
prompt given for that agent (here, or in `termination.md` for the closer). The
review phase writes no handoff, so record the fallback in the iteration's
record and pass it to the closer for the PR comment.

## Termination

Read `termination.md` in this skill's directory for **CI**, **Termination**,
and **The closer** (and `autopilot.md` for autopilot terminal actions).
