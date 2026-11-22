# Autopilot review loop

A reference file of the `orch-review` skill, read only when
`bash "$ORCH" autopilot active` exits 0.

## Before the first iteration

**In an autopilot flow** (`bash "$ORCH" autopilot active` exits 0) the loop
runs headless and asks the human nothing directly. First, when
`iteration` is not 0 - the previous loop ended in a bounded stop of any kind -
read the human's reply before anything else:
`bash "$ORCH" autopilot answer review <file>` (a `mktemp` file). It exits 1
when no reply follows the question, and after an automatic re-entry (a
re-entry comment is never a reply). After a stop for a spec question, re-post
the same question then with
`bash "$ORCH" autopilot ask review .orchestrator/review/question.md` (the
save point the asking site wrote) and stop - never assume
the recommendations. After any other stop (an open blocking, an unclean final
iteration, a missing look, CI), exit 1 means "carry on": the driver picks the
budget in step 5. Any other exit stops the loop, as a failed fetch does.

A reply, after any stop, is split. A budget it plainly names (step 5) is never
written to the spec body. Any ruling on what the change does is applied to the
spec issue's body: `bash "$ORCH" spec fetch <file>`, edit the body to carry the
ruling, then `bash "$ORCH" spec update <file>`. The reply **changes behaviour**
exactly when applying it edits the spec body; step 5's floor reads that.

When a ruling on a spec question brings back, in whole or in part, an entry in
the plan handoff's **Rejected alternatives**, amend that entry too, per the
handoff skill's **Amending Rejected alternatives** section. Check the ruling
against the plan comment's entries yourself; nothing before step 1 has fetched
the handoffs, so that section's fetch-where-nothing-fetched case applies. Take
the citation for the note from the previous loop's final iteration record,
whose `## Terminal state` names each spec question of the stop (`#<n>:
<file>:<line> <title>`, or `<file>:<line> <title> (not filed)`), tying each
ruling to the question it answers. Re-post the amendment before step 1, so
step 3 reads the amended entry. A ruling that reverses no
entry amends and re-posts nothing. A failed fetch or post stops the loop with
its `orch:` reason before `review begin`, as a failed reply fetch does.

Then carry on with the steps below, whose step 5 sizes the budget from the
plan or from what the previous loop left instead of asking.

### Autopilot budget

5. **In an autopilot flow** (`bash "$ORCH" autopilot active` exits 0) the
budget is never asked. On a first loop
(`iteration` is 0) `autopilot run` has already recorded the plan's budget:
read it with `bash "$ORCH" state get budget`, set nothing, ask nothing. On
a re-entry (`iteration` not 0, after any bounded stop) pick the number of
further iterations `n` yourself, by the **re-entry sizing rule**: judge it
from what the previous loop's records (step 4) left - any open blocking
still standing, and how much its final iterations still found - never from
the change's size.
- 2: a single stuck blocker (2, not 1: only a clean final iteration can
  go Ready).
- 3: steady remaining churn.
- 5: the final iterations were still finding new blocking findings.

Then `budget` is `iteration + n`, bounded thus:
- Floor: `n` is at least 2 when anything must be fixed - an open blocking
  finding carried in (a failing `## CI` among them), or a reply or ruling
  that changes behaviour - because only a clean final iteration can go
  Ready; otherwise at least 1.
- Ceiling: `n` is never more than the plan's budget (`autopilot budget`),
  except that the floor wins when the two conflict (a plan budget of 1 with
  something to fix runs 2), because a budget that cannot end clean only
  buys another stop.
- Override: a budget the human's reply plainly names ("run 2 more")
  replaces your pick, floored at 1; the ceiling does not apply to it.

Record the choice: the loop's first iteration record carries one header
line, `Re-entry budget: <n> - <one-clause reason>` (or `- from the reply`),
after `Spec issue:`. When that iteration starts a fixer, pass the line in
its prompt as `Re-entry budget:` and the fixer copies it; when the
iteration is clean, write it in the record you write yourself. First loops
and interactive re-entries carry no such line. It is for a human reading
the record: nothing parses it.

Then, on a re-entry, `bash "$ORCH" state set budget <that number>`. Go to
step 6.

## CI failure judgement

- **failing**, at **Termination** in an autopilot flow: judge it before it
  is called a reason. Read `bash "$ORCH" review ci-log <pr>`. The failure needs
  a decision, a human reason, when any of these holds: it would fail on the
  base tip too (judged from the log and the diff: it lies in code or config the
  change does not touch); its cause is infrastructure (secrets, permissions,
  runners, quota); a failing check is not an Actions run (the output says so);
  the fix needs a choice the spec leaves open; or you cannot tell which case it
  is, a job whose log could not be read among them. Otherwise it is a failure
  the change can fix, an automatic reason.

## Termination

**In an autopilot flow** the terminal action differs. Ready ends with
`bash "$ORCH" review ready` as above, which also moves the label to `orch:done`
and releases the claim; nothing more runs. A bounded stop - the PR staying in
draft - never ends by telling the human in the session. Write the stop reason,
the closer's filed issue numbers (and, for a spec question, each question with
its recommendation, numbered, as the interview formats them) to
`.orchestrator/review/question.md` in the side
checkout - the save point, which a fresh session re-posts when the human removes
`needs-human` without replying. Then classify each reason of the stop:

- **Automatic** - the final iteration was not clean, an open blocking finding
  remains, a look is missing, or CI is `failing` for a cause the change can fix
  (the **CI** judgement).
- **Human** - a spec question, CI `unreachable`, a failed base sync, known
  items that could not be built, or a CI failure that needs a decision (the
  **CI** judgement).

A stop with any human reason runs
`bash "$ORCH" autopilot ask review .orchestrator/review/question.md`, which
posts it as a question comment, labels the issue `needs-human` and releases the
claim; then stop. Removing `needs-human` starts another loop, with a budget the
driver sizes from what this one left, which reads the reply first, per the
top of **Before the first iteration**.

A stop whose every reason is automatic is an **automatic re-entry**: run
`bash "$ORCH" autopilot reenter review .orchestrator/review/question.md` with
the same file, holding the stop reason and the closer's filed issue numbers. It
posts a re-entry comment with no @mention, adds no label, leaves the phase at
`orch:review` and releases the claim; then stop. The watcher starts another
loop, which sizes its budget by step 5's re-entry sizing rule. The third bounded
stop in a row asks the human instead; `autopilot reenter` takes that path
itself.
