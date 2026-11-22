# Triage, severity, and clean-iteration records

A reference file of the `orch-review` skill, read at step 4 of **The
iteration** when triaging the reviewers' reports and writing a
clean-iteration record.

## Dispositions and triage rules

Apply the two demotions under **Authority** first, then the **Severity**
rubric, then give each finding one disposition:

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
  closer's deduplication matches, never the title alone - is
  neither fixed nor filed again; it keeps its issue number. This is the one
  owner of the already-filed rule: the closer files whatever this loop's
  records leave waiting and only reports what triage marked met again. A
  **Filed** entry with no file and line predates that format; match it on
  its title against the finding's claim.

A **pattern finding** - one whose report bullet carries a `Sites:` list,
every site with the first included - is one finding, triaged once, never
one per site. **Loop-authored lines**, **the final iteration** and
**Met again** judge it by its first site, its leading `file:line`, the
finding's location for every consumer; the fixer applies loop-authored
lines and the final iteration to each of its other sites, and defers
those they keep out.

A reviewer holds back what its known items already carry, so most of
what earlier iterations dealt with never reaches you; these filters stay
the backstop for what it lets through. A finding marked `` re-raised
(<source>): <what changed> `` is a known item whose location or cause
changed: triage it as any other finding. An unmarked finding that matches
a known item is triaged as before - demoted, or met again. The Spec
report's `## Set aside` lines are not findings: each becomes a recorded
note under **Covered deviations** (see **Authority**), not fixed, not
filed, and given no disposition.

Done when every finding in both reports has exactly one disposition.

## Clean-iteration record

Write the record to `bash "$ORCH" review path` yourself, in the shape the
fixer's brief gives, reading just that section - the brief's last, whose
template holds `##` headings of its own, so read to the end of the file:

```
sed -n '/^## The record$/,$p' "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"
```

If `CLAUDE_PLUGIN_ROOT` is unset, the plugin root is found as for `ORCH`:
two directories above the `orch.sh` that `ls` printed, else two directories
above this skill's own directory.

`Verification` reads `not run - nothing changed`, **Fixed this
iteration**, **Evidence** and **Open blocking** read `None`, and **Merge
resolutions** holds step 2's. **Waiting to be filed** lists each major or nit
left unfixed in the template's location-bearing bullet,
``- <Axis>/<severity>: `<file>:<line>` <claim> - <rule>``, a pattern
finding's deferred sites in one such bullet led by the first, with
``Sites: `<file>:<line>`, `<file>:<line>`.`` after the claim (none for
a single deferred site), with `-` in
place of `<file>:<line>` when the finding gave `-`, or reads `None`.
**PR body** depends on that base sync:
- **Merge resolutions** is not `None` - step 2 resolved a conflict, so
  the diff from the base SHA changed while the PR was open: before
  writing the record, run **Checking the PR body** yourself, against
  this iteration's base SHA, reading just that section:

  ```
  sed -n '/^## Checking the PR body$/,/^## /p' "${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"
  ```

  (its last line is the next section's heading). **PR body** holds the
  check's outcome value, a `Not updated - <reason>` with its unlanded
  corrections included. A `Not updated` is never a finding and does not
  hold the PR out of **Ready**, exactly as a fixer's does not: the record
  shows it.
- **Merge resolutions** is `None`: **PR body** reads `Not checked - no
  commit`.

Then go to step 1.

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
  breached, a smell with teeth, scope nobody asked for, a doc the change left
  disagreeing with the code. Fixed, unless the fix
  needs a choice between alternatives the plan, spec, and deviations did not
  settle. Those are filed, the options in the body. A fix that changes
  behaviour the spec settles makes the finding blocking; one whose behaviour
  the spec leaves unsettled makes it a **spec question** (**Dispositions and
  triage rules** above). A PR is marked ready with filed majors open against it
  - the issue carries the reasoning, and triage decides against the whole
  codebase whether it is worth fixing at all - unless one is a spec question
  this loop filed: that holds the PR out of **Ready** until a human rules on
  it. A finding that the change contradicts an ADR is one: it takes the `spec
  question` rule, and the ADR is never edited. See
  `docs/adr/0042-a-spec-question-the-review-loop-files-holds-the-pr-in-draft.md`.
- **nit** - taste and judgement. Fixed only when **mechanical**: exactly one
  correct fix, confined to the lines it names, no behaviour change, no wording
  or taste to choose - a typo, an unused import, a comment naming the wrong
  function, a broken link. Rewording prose is never mechanical, however small.
  Filed otherwise.

A major or nit on **loop-authored lines** or found in the **final iteration**
is filed, never fixed - see **Dispositions and triage rules** above - though a
spec question found there still holds the PR out of **Ready**.

Major and nit are triage priorities on a filed finding, which is why they live
in the issue's label rather than its title: the label can change.

## Authority: what the loop refuses to act on

Applied before the rubric. Both would overturn a decision a human already made
with more context than you have:

- **Covered deviations.** A Spec-axis finding covered by `03-implement.md`'s
  **Deviations** section becomes a recorded note: not fixed, not filed. Each
  line under the Spec report's `## Set aside` heading - a requirement a
  listed deviation sets aside - becomes one such note too, so the PR comment
  still repeats every covered deviation. See
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
