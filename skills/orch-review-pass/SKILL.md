---
name: orch-review-pass
description: Run a review pass - one look at a change by the orchestrator's two reviewers, orch-reviewer-standards and orch-reviewer-spec, with no loop around it - no budget, no severity, no fixer, no closer, nothing filed; the session that runs it fixes what it agrees with and records what it declines and the spec questions it meets. Use from orch-quick-implement's step 6 before its PR opens, and standalone, outside any flow, when a human runs /orchestrator:review-pass <issue> or asks for a review of the current branch against a given issue.
---

# Orchestrator review pass

One look at a change by the orchestrator's two reviewers, with no loop
around it. A quick implementation runs one before its PR opens, and a human
may run one on demand. This skill is the one definition of it.

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

## Review pass

One look at a change by the two reviewers, `orch-reviewer-standards` and
`orch-reviewer-spec`, with no loop around it: no budget, no severity, no
fixer, no closer, nothing filed. A quick implementation runs one before its
PR opens (the `orch-quick-implement` skill's step 6), and a human may run one
on demand (see **Standalone review pass**). A review pass has no driver: the
session that runs it fixes what it agrees with itself.

The caller names the spec issue and says where the declines, spec questions
and host fallbacks go. A caller with deviations to hand - a quick
implementation, whose PR does not exist yet - also names a file of them, for
step 3's `--deviations`. The caller also names the pass's **verification
command**, for step 5's suite-cost check, or says it has none, and where
a skipped check is reported.

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
3. **Start both reviewers.** First build the pass's known items: run
   `bash "$ORCH" review-pass known-items <issue> <prefix>-known.md`, adding
   `--deviations <file>` when the caller handed one. It writes the earlier
   passes' declines, the spec rulings and the deviations to that file. If it
   dies, relay its message and stop the pass, as a failed review does. Then
   start `orch-reviewer-standards` and `orch-reviewer-spec` at once, both in one message, each as a fresh
   subagent, never a fork, which would inherit this context. Start each as
   `docs/host-capabilities.md`'s **Start a fresh subagent** row describes for
   the host: on Claude Code, the Agent tool with `subagent_type` set to
   `orchestrator:<agent>`. Each prompt carries these six variables and
   nothing else - no issue body, no diff, no brief:

   ```
   Base SHA: <base SHA>
   Spec issue: #<issue>
   Iteration: <NN>
   Report path: <prefix>-<standards|spec>.md
   orch.sh: <the path ORCH holds>
   Known items: <prefix>-known.md
   ```

4. **A failed review.** A missing report, or one that says the base SHA did
   not resolve or the diff was empty, is a failed review, not a clean one.
   Start that reviewer again once. If it fails a second time, stop the pass
   and tell the human which axis failed. A pass never claims an axis nobody
   looked along.
5. **Fix.** Read both reports, and fix, yourself, every finding you agree
   with that is not a spec question (step 7). Use no fixer agent, no closer,
   no severity, no budget, and file nothing. Commit the fixes as one commit.
   The Spec report's `## Set aside` lines are not findings: each is a
   requirement a known deviation set aside on purpose - one the caller
   handed in with `--deviations`, or, in a standalone pass, one the PR
   body's **Deviations** heading lists - and that record of the deviations
   already carries it: a quick implementation's PR body, under
   **Deviations**, or the open PR's own. Fix none of them, and record none
   as a decline or a spec question.

   **Suite cost.** Before fixing, run once, with the caller's verification
   command:

   ```
   bash "$ORCH" suite-cost check -- <verification command>
   ```

   It prints one verdict line. Handle `grew <pct> - <finding text>` like
   any other finding, at location `suite` - the suite as a whole - with the
   finding text as its claim: fix it, or decline it with its reason. `off`,
   `ok` and `unmeasured` raise nothing, and so does a `check` that dies:
   relay its `orch:` message. With `unmeasured`, relay any `orch:` warning
   `check` printed with it too, so a base run's setup failure reads as one. When the caller has no verification command,
   skip the check, and say so where the caller says. It is not a
   smell-baseline finding, so no pass leaves it out.
6. **Declines.** Record each finding you decline, one line each:
   `` `file:line` - <claim> - <reason> `` - its `file:line`, or `-` when the
   report gave `-` for its location; the finding's claim, in a few words;
   and your reason for declining it. If you declined none, the record says
   `None declined.` The caller says where this record goes. A spec question
   is never declined.
7. **Spec questions.** A finding is a **spec question**, the third outcome
   beside fix and decline, when its fix needs a decision about *what the
   change does* - its behaviour - that the spec, plan and deviations leave
   unsettled: silent, ambiguous, or self-contradictory on it. A pass has no
   severity, so judge it by the finding's content alone. This is the
   glossary's **Spec question** entry, as it applies to a pass. A finding
   that the change contradicts what the spec clearly asks for is not one:
   fix it. A decision about structure only - which of two refactorings,
   which name - is not one either: fix or decline it as any other finding.
   Never fix a spec question by picking a behaviour, and never decline one:
   hand it to the caller. Record each, one line each:
   `` `file:line` - <the open behaviour, phrased as a question> ``,
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
   its message names the command to run instead. The pass's verification
   command is the full-suite command the repo's agent files (`CLAUDE.md`,
   `AGENTS.md`) document. When they document none, the pass has none: its
   suite-cost check is skipped, and step 5's **Suite cost** says so.
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
   file and makes the same claim, judged on the claim's substance, never on
   a title or wording alone; line numbers are ignored, since they move
   between passes. A finding at `-` matches on the claim alone, and an
   older decline line with no claim matches on file plus reason. The
   reviewers were already told these declines, through **Review pass** step
   3's known items, and hold back what they carry; this drop is the
   backstop for a finding a reviewer raised again anyway.

   A `grew` verdict from **Review pass** step 5's suite-cost check comes
   later, in neither report, and its claim's numbers change every run, so
   it matches an earlier decline at `suite` on that location alone. When
   step 3 meets a `grew` and an earlier decline is at `suite`, drop it the
   same way - neither fixed nor declined again - and keep it aside for
   step 5's **Previously declined**.

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
   A Source beginning `root-cause check` or `test-cost check`, or naming no
   baseline smell, is never one; nor is any Spec-report finding. A smell that matched an earlier
   decline is already under **Previously declined** and is not counted.
   A `grew` verdict from **Review pass** step 5's suite-cost check is in
   neither report and is never one: it is kept, whatever `--smells` says.
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

   After the commit and push, when the branch has an open PR (step 2's
   `pr comments` exited 0), run **Checking the PR body** in
   `agents/orch-fixer.md` (under the plugin root), against the base SHA
   **Review pass** step 2 read, fetching the body afresh: step 2's copy
   predates the commit. Its outcome goes to step 5's **PR body**. With no
   fixes there is no commit, and no check.
5. **Report.** Write `<prefix>-comment.md` to the comment shape of
   `docs/pr-writing.md` (under the plugin root), which owns its style; this
   step adds only the comment's own parts. In this order:
   1. **Lead**: 1-3 lines stating the pass's outcome - what it fixed,
      declined and left open - with no preamble.
   2. **`## Summary` and `## Evidence`**, only when step 4's fix commit
      changed code. **Summary** says what the fix changed. **Evidence**
      comes from that fix's test runs only, never invented: each test it
      wrote or ran that now passes, with the red run of each that failed
      first, and as its last line the verification command it ran after the
      fix, with `pass` or `fail`. With no fix commit, leave both headings
      out.
   3. **Eight headings**, every one present, in this order, each with its
      `None.` form when empty:
      - `## Review` - the declines, or `None declined.`;
      - `## Previously declined` - each finding step 2 dropped as an
        earlier decline, as its `file:line` and claim, or `None.`;
      - `## Spec rulings` - each ruling step 3 posted, as
        `<question> - <answer>`, or `None.`;
      - `## Spec questions` - each question left unruled, as **Review
        pass** step 7 records it, or `None.`;
      - `## Host fallbacks` - each fallback taken, or `None (<host>).`;
      - `## Smells` - exactly one line: `<N> hidden - rerun with --smells to
        see them.` when step 2 hid N >= 1, `None hidden.` when it hid none,
        or `Included (--smells).` with `--smells`;
      - `## PR body` - step 4's check's outcome value, `Not checked - no
        commit` when the pass made no commit, or `Not checked - no open PR`
        when it committed on a branch with no open PR;
      - `## Suite cost` - exactly one line: the verdict `suite-cost check`
        printed, or `Skipped - no full-suite command documented.` when step
        1 found none.

   A `grew` the pass declined is also a line under **Review**, at `suite`.
   **Smells** is its own heading, never a line under **Review**, so a
   later pass's step 2 reads no smell as a decline.

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
     fallbacks, the **Smells** line, the **PR body** outcome and the
     **Suite cost** line in the session instead. The questions
     were still asked, and the rulings are on the spec issue;
   - exit 2: GitHub could not be read, or the post failed; stop and say so,
     relaying its reason. Never report this as nothing declined.

A standalone review pass does not lift the planning edit guard (ADR-0006,
ADR-0025). In a session where planning ran and neither a flow nor a quick
implementation lifted it, the pass's first edit is denied: stop, and tell the
human to run the review pass in a fresh session.
