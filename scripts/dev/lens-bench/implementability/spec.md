## Problem Statement

Reviewers keep raising findings that have already been dealt with, and nobody checks the deviations an implementer records.

- In the #1120 review loop, about eight findings came back for three to five iterations each, even though every one was already in an earlier record's **Waiting to be filed** list or in `03-implement.md`'s **Deviations**. Examples: the `@@` parser duplication in `spec-review.sh`, the `j` reuse in `spec_review_apply`, and `- declined`. Each iteration the driver demoted them again, reaching the same outcome on the same rule.
- In stepbro, a standalone `/orchestrator:review-pass 45` re-raised two declines already listed in the PR body.
- In stepbro e3bbb56a, an implementer's hand-back carried a `Deviation:` line about building another member's key. The first review pass never checked what came of it (`memberKeyOf` was fed a made-up interaction object), so a second `/review-pass` was needed to find it.

The human pays for every repeated finding twice: once in reviewer output, and again in driver triage that only re-derives an outcome already on record. Deviations, meanwhile, get no review at all.

## Solution

Each reviewer still reviews the diff blind, exactly as today. When it writes its report, it opens a **known-items file** and holds back every finding that a known item already carries, unless that item's location or cause has changed. The Spec reviewer also reads the recorded deviations *before* it reviews, and treats each one as something to verify. orch.sh builds the known-items file mechanically from the records, handoffs, PR and issue where those items already live. Every reviewer prompt names the file as a sixth variable, in the review loop and in both kinds of review pass. The driver's own filters (demotion, met again, a pass's earlier declines) stay as the backstop.

## User Stories

1. As a human running a review loop, I want a finding already waiting to be filed in an earlier iteration not raised again, so that I don't pay for the same finding every iteration.
2. As a human running a review loop, I want a finding an earlier loop already filed not raised again, so that a re-entered loop doesn't re-review what is already on the tracker.
3. As a human running a review loop, I want a finding that a plan's rejected alternative already rules out not raised, so that the reviewer doesn't re-propose a road the plan closed.
4. As a human running a review loop, I want a finding that a recorded deviation covers not raised as missing, so that a deliberate departure isn't reported as a gap.
5. As a human, I want the Spec reviewer to verify what each deviation built in place of the spec, so that a defect inside a deviation (the stepbro `memberKeyOf` case) is found on the first look.
6. As a human, I want a deviation that no commit actually carries out reported as **wrong**, so that a hand-back claiming work that never landed is caught.
7. As a human running a standalone review pass, I want the declines of earlier passes on the PR not raised again, so that each pass only shows me what's new.
8. As a human running a standalone review pass, I want the spec questions already ruled (by `Spec ruling:` comments on the spec issue or **Spec rulings** in PR comments) not raised again, so that a ruled question stays ruled.
9. As a human, I want a known item whose location or cause has changed still raised, and marked as re-raised with what changed, so that a regression or a moved defect isn't hidden by the known list.
10. As a human, I want each report to say how many known items it held back, so that I can see the filter working without reading the list.
11. As a reviewer, I want the known items delivered as a file named in my prompt, so that my prompt stays a few short variables and the lists stay out of the driver's context.
12. As a reviewer, I want to open the known items only when I write my report, so that knowing a region is "known" doesn't make me read past a different defect beside it.
13. As a driver, I want the known-items file built by one orch.sh command, so that I copy no headings by hand and the extraction has a test seam.
14. As a driver, I want my demotion, met-again and earlier-decline filters left unchanged, so that a reviewer that ignores or misreads the list is still caught.
15. As a driver, I want an unmarked re-raise of a known item triaged exactly as today (demoted, met again, previously declined), so that the backstop needs no new rule.
16. As a quick implementation, I want my implementers' `Deviation:` lines recorded in the PR body under a **Deviations** heading, so that my review pass and any later standalone pass can read them.
17. As a quick implementation, I want my review pass to get my deviations before the PR exists, so that the one look the change gets before its PR checks them.
18. As the closer, I want each **Waiting to be filed** bullet to carry its file and line, so that the known items, and the issues filed from them, name a location without a lookup.
19. As a maintainer, I want ADR-0045 to record why reviewers filter after a blind review, and ADRs 0002, 0018 and 0029 to point at it, so that the decision trail stays readable.
20. As a maintainer, I want the glossary to name a **Known item**, so that briefs, skills and ADRs share one term.

## Implementation Decisions

### Root cause

Both reviewers are blind by design. Each prompt carries five variables "and nothing else - no word about earlier iterations or fixes". Every check against already-dealt-with items runs only after the reviewers report: the loop's triage (**Authority** demotions, **Met again**) and the standalone pass's drop of earlier declines. So every iteration and every pass re-raises those items, and the driver triages them to the same outcome again. Separately, the Spec brief says "A recorded deviation or a rejected alternative may explain a finding - report it anyway", and nothing tells it to verify what a deviation built instead. A quick implementation never records its implementers' `Deviation:` lines at all: its PR body has no **Deviations** heading, so its review pass has no source for them.

The cause acts at these sites, and the fix covers every one:

- **orch-review skill, The reviewers**: the five-variable prompt shape and its "nothing else" sentence. The driver also has to build the known-items file each iteration before it starts the reviewers.
- **orch-review-pass skill**: **Review pass** step 3's five-variable prompt shape, and standalone step 2's "The reviewers hear nothing of this".
- **orch-reviewer-spec brief**: its prompt variables, its steps (read deviations before the review, filter at report time), its report shape, and the "report it anyway" line.
- **orch-reviewer-standards brief**: its prompt variables, its steps (filter at report time), and its report shape.
- **orch-quick-implement skill**: step 5's record, step 6's pass, and step 7's PR body, which has no **Deviations** heading.
- **orch-fixer brief, The record**: the **Waiting to be filed** bullet carries no location.
- **orch.sh**: has no command that builds the known items.

### Shape

1. **Reviewer-side fix, driver filters kept as the backstop.** Demotion, met again and the standalone pass's earlier-decline drop all stay unchanged.
2. **Blind first, filter last.** Each reviewer reviews the diff blind, exactly as today, and opens the known items only when it writes its report. It drops each finding that a known item already carries (same file, same claim, judged on substance; line numbers may move) when that item's location and cause are unchanged. It judges "unchanged" by reading the current code against the known item's location and claim; no per-item SHA is recorded. Each report gets a line under its header, `Known items held back: <N>`. The count stays in the report and is not copied into the iteration record.
3. **The Spec reviewer reads deviations first, as things to verify.** The Spec brief's "report it anyway" line is replaced with these rules:
   - A requirement that a listed deviation sets aside is not reported missing.
   - The deviation's own code is reviewed like any other code.
   - A listed deviation that no commit carries out is reported **wrong**.

   The Standards reviewer treats deviations only as known items and gets no verify instruction. ADR-0002's decision (a deviation outranks the Spec axis) stands, and covered deviations still become recorded notes in triage. Only ADR-0002's premise that the reviewer cannot see deviations changes.
4. **Re-raise marker.** A reviewer that re-raises a known item whose location or cause changed marks the bullet `` re-raised (<known item's source>): <what changed> ``. Triage treats an unmarked match as before (demoted, met again, or previously declined).
5. **Delivery: a sixth prompt variable**, `Known items: <path>`, always passed to both reviewers, in the loop and in both kinds of review pass. In the loop, the file sits beside the iteration's report paths as `iteration-NN-known.md`. In a review pass it sits beside the pass's reports as `<prefix>-known.md`.
6. **File shape.** One file with two headings, always both present:

   ```
   ## Deviations
   <deviation bullets, as recorded>
   ## Known items
   - <the line as recorded> - <source>
   ```

   `<source>` is one of: `waiting to be filed, iteration NN`, `filed, iteration NN`, `rejected alternative`, `declined`, `spec ruling`. A heading with nothing under it reads `None.`. A source's own `None`/`None.`/`None declined.` line contributes nothing.
7. **Location in Waiting to be filed.** The fixer's record template changes its **Waiting to be filed** bullet to ``- <Axis>/<severity>: `<file>:<line>` <claim> - <rule>``, using `-` in place of `<file>:<line>` when the finding gave `-`. **Filed** entries already carry `<file>:<line>`. The driver's own record for a clean iteration has nothing waiting to be filed, so it is unaffected.
8. **Built mechanically by orch.sh** (ADR-0044's direction). The builders copy lines out of headings and do no matching or judgement; matching stays with the reviewer.
   - **`orch.sh review known-items <path> <loop boundary>`**, in the review command's module. It needs flow state. `<loop boundary>` is the `iteration` the driver read before the loop's first iteration. Sources:
     - **Waiting to be filed** from every record numbered above the boundary;
     - **Filed** from every record at or below it;
     - `03-implement.md`'s **Deviations**, copied under `## Deviations`;
     - `01-plan.md`'s **Rejected alternatives**.

     The driver runs it in each iteration after the base sync and before it starts the reviewers.
   - **`orch.sh review-pass known-items <issue> <path> [--deviations <file>]`**, in the review-pass command's module. It needs no flow state. Sources:
     - lines under **Review** in the PR body and in any PR comment carrying both a **Review** and a **Host fallbacks** heading (the recognition rule standalone step 2 uses), source `declined`;
     - lines under **Spec rulings** in PR comments, and the spec issue's `Spec ruling:` comments, source `spec ruling`;
     - the PR body's **Deviations** heading, copied under `## Deviations`.

     With no open PR, only the spec issue's rulings are read. `--deviations <file>` copies that file's lines under `## Deviations` in place of the PR body's heading; a quick implementation uses it because its pass runs before the PR exists. When GitHub cannot be read, the builder dies with an `orch:` message, and the pass stops as step 2 does today.
9. **Quick implementation records deviations.** Step 5's record gains the PR body's **Deviations** heading: one bullet per ticket whose `Deviation` line is not `None`, naming the ticket, or `None.`. Step 6 writes those bullets to a file and passes it to `review-pass known-items --deviations`. Step 7's PR body carries the **Deviations** heading, so a later standalone pass reads it from there.
10. **Versioning**: a `changelog.d/1140.md` fragment, `bump: minor` (new reviewer input and new orch.sh subcommands).

### New ADR: `docs/adr/0045-reviewers-filter-known-items-after-a-blind-review.md` (verbatim)

> # Reviewers filter known items after a blind review
>
> Amends ADR-0018: a reviewer's prompt carries a sixth variable, `Known items: <path>`. Amends ADR-0002: the Spec reviewer now sees the deviations; a recorded deviation still outranks it. Amends ADR-0029: a review pass's reviewers are told the pass's known items.
>
> Every reviewer prompt used to carry nothing about earlier iterations, so each look was independent. The cost was re-raising: in #1120's loop about eight findings recurred across three to five iterations, each already waiting to be filed or covered by a deviation, and each triaged again by the same driver to the same outcome. The second opinion blindness promised never arrived, because the same rule ruled it each time. Blindness also cost the deviations their review: a reviewer that cannot see a deviation cannot check what was built in its place.
>
> A reviewer now reviews the diff blind, as before, and opens the known items only when writing its report. It drops each finding that a known item already carries - same file, same claim - and re-raises one only when its location or cause has changed, marked as re-raised. It reports how many it held back. The Spec reviewer reads the deviations before its review, as things to verify. The driver's own filters - demotion, met again, a pass's earlier declines - stay as the backstop.
>
> ## Considered Options
>
> - **Keep the reviewers blind and make the driver's matching cheaper.** Rejected: the waste is the reviewers' repeated output, and deviations would stay unverified.
> - **Give the reviewers the known items before they review.** Rejected: a reviewer told a region is known reads past it, and misses a different defect beside the known one.

ADRs 0002, 0018 and 0029 each gain a one-line note at the top, "Amended by ADR-0045: ...", in the style of their existing "Superseded in part by" notes.

### Glossary: `GLOSSARY.md` (verbatim)

New entry **Known item**, placed beside **Finding** / **Filed finding**:

> **Known item**:
> A finding a review has already dealt with - waiting to be filed or filed by a review loop, set aside by a rejected alternative or a deviation, declined by a review pass, or answered by a spec ruling - that a reviewer is told about so it does not raise it again. A reviewer raises a known item again only when its location or cause has changed.
> _Avoid_: known issue, duplicate

Appended to the **Review pass** entry, as its final sentence before `_Avoid_`:

> Its reviewers are told the pass's known items, and drop the findings those already carry.

## Testing Decisions

- **One seam**: the orch.sh CLI, run by `orch_test` against the faked GitHub adapters (ADR-0033). The tests check only the file each builder writes and its exit status, never how it got there.
- **`review known-items`**, a section in the review noun's test file:
  - each source lands under its heading with its source tag;
  - only records above the loop boundary contribute **Waiting to be filed**, and only records at or below it contribute **Filed**;
  - `03-implement.md`'s **Deviations** lands under `## Deviations`, and `01-plan.md`'s **Rejected alternatives** under `## Known items`;
  - an empty or `None` source contributes nothing, and an empty heading reads `None.`;
  - a missing or non-numeric boundary is refused.
- **`review-pass known-items`**, a section in the review-pass noun's test file:
  - declines from the PR body and from a comment with both **Review** and **Host fallbacks** land as `declined`; a comment without both headings is ignored, and `None declined.` contributes nothing;
  - **Spec rulings** lines and the issue's `Spec ruling:` comments land as `spec ruling`;
  - the PR body's **Deviations** lands under `## Deviations`, and `--deviations <file>` replaces it;
  - with no open PR, only the issue's rulings are read;
  - an unreadable GitHub dies with an `orch:` message and writes no file.
- **Prior art**: the `review-pass begin` and `review file` sections (faked adapters, PR and issue fixtures), and the `handoff section` tests for heading extraction.
- Brief and skill prose gets no wording tests (ADR-0027). `docs_lint.sh` and harness.sh's placement section must keep passing.

## Out of Scope

- Dropping or loosening the driver-side filters (demotion, met again, earlier declines).
- Giving the reviewers the known items before they review.
- Inlining the known items in the prompt.
- Recording a SHA per known item. If "location or cause unchanged" proves too loose, that can come later.
- Copying the held-back count into the iteration record.
- Deviations to the Standards reviewer as things to verify.
- PR-body declines as a source for a review loop: only review passes write declines.

## Further Notes

- **Rejected alternatives from the plan**: driver-side matching made cheaper; known items given before the review (anchoring); driver filters dropped; known items inlined in the prompt (ADR-0018 keeps prompts to short variables); the driver writing the file from prose (it is mechanical extraction, which orch.sh owns, ADR-0044); only the previous iteration's **Waiting to be filed**, as this issue first proposed (an item can skip an iteration, so every earlier record of this loop counts, plus earlier loops' **Filed** and the plan's **Rejected alternatives**).
- **Constraints**: reviewers stay read-only (one write, the report). Each helper goes in the module of the concept it serves, per CLAUDE.md. The builders key off the record and handoff headings as they stand: **Waiting to be filed**, **Filed**, **Deviations**, **Rejected alternatives**, **Review**, **Host fallbacks**, **Spec rulings**.

