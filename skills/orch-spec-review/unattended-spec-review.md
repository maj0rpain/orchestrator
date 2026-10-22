# Unattended spec review

A reference file of the `orch-spec-review` skill, read only in an unattended
run.

The mode a quick implementation takes, and only a quick implementation: a
standalone spec review that asks the human nothing (ADR-0034). It is the one
definition of the mode - quick implementation's own steps never restate its
rules. Everything in the skill's **Standalone spec review** holds, with these
differences only:

- **Rounds**: it always runs exactly **1** round, and asks no round-count
  question; a `--rounds` value is never passed to it.
- **Consolidation and the lenses** run unchanged: Consistency, Testability
  and Implementability, with Fidelity not run.
- **Disposition**: `batch.md` is written and checked with `spec-review
  check` until it passes, as in an attended review, and the batch printed by
  pasting `check`'s stdout word for word, as in an attended review - the
  same compact view: the material items as one list, each under its batch number, on one
  line with its summary and its reason, a decision item's options one line
  each, no citation and no diff, and the minor and resolved ones one line each under **Minor edits** - so a human watching can see what is applied and
  interrupt. Then no question is asked and nothing waits: the batch is
  applied at once as **Apply as recommended** - every proposed edit applied,
  every **recommend decline** item skipped, and every decision item takes
  its recommended option.
- **Applying**: the standalone call in **Applying the answer**, with the
  answer `recommended` and `--unattended` added:

  ```
  bash "$ORCH" spec-review apply <dir> recommended --round 1/1 --issue <issue> --unattended
  ```

  `apply` takes no other answer with `--unattended`. It writes the
  changelog's fixed unattended opening line and one
  `decision (<n>): took <letter> - <label>, as recommended` line per
  decision item taken; a quick implementation lists those lines in its PR
  body. Declined items record **declined as recommended: <reason>**.
- **Tickets follow the spec** runs as usual when `apply` pauses with exit 3:
  `tickets.md` is drafted and checked with `spec-review check <dir>
  --tickets` until it passes, and its items printed by pasting that
  command's stdout word for word; then no question is asked,
  and `apply` runs again with `--tickets recommended`, its one ticket answer
  in this mode. `tickets.md`'s `@@ recommend` line picks **Apply as
  recommended** or **Retire and break down again**.
- **A retire** is followed, after the round, by `orch-to-tickets`'
  **Unattended breakdown**, never its quiz.
- **Failures** are unchanged: a guard refusal, a failed fetch or a failed
  write stops the review, and the quick implementation that ran it with it.
  A refusal of `batch.md` or `tickets.md` is fixed and `apply` run again, as
  in an attended review.
