# Phase: spec

A reference file of the `orch-flow` skill, read only when `state get phase`
prints `spec`.

0. Check `bash "$ORCH" state get issue`. Empty means no `--issue` was given -
   run the phase from step 1, exactly as it does for every flow that has no
   adopted issue. Non-empty means the issue already exists and is already
   recorded, so steps 1-3 do not run; instead run the round check, the
   marker check and 0a-0d below. Three cases reach them: an issue adopted after
   an interview about it, whose body predates the plan; a blueprint adopted at
   init, whose body is already a spec; and a default `redo spec`, whose body
   carries the edits the previous spec review accepted, newer than `01-plan.md`.
   Because nothing records an issue's origin
   (`docs/adr/0005-an-adopted-issues-origin-is-not-recorded.md`), a spec phase
   resumed after its own step 3, or after a step-0c rewrite, reaches them too:
   that session stopped with `spec pause`, so the resumed phase takes the marker
   check and goes straight to step 4. A spec phase resumed after a spec review
   round paused takes the round check instead.
   - **Round check.** Run `bash "$ORCH" spec round` first, ahead of the
     marker check. It reads the round marker, the file `spec pause --round`
     and `spec round-dir` leave in the handoff folder. When it prints
     `<k> <n>`, ask nothing and run round k of n in this session: step 4's
     review from round k, with no round count asked. When it prints
     `<k> <n> applying`, a spec-review apply died partway: run
     `bash "$ORCH" spec-review apply <dir> --resume --round <k>/<n>` (it
     reruns with the answer it saved) and go on from the round it completes.
     When it prints `done <n>`, every round has run - the session that ran
     the last one failed after it, say in the ticket breakdown - so ask
     nothing and go to step 5. Only when
     it exits 1, no round marker for this issue, go on to the marker check.
     Any other exit is a failure: relay its `orch:` message and stop, leaving
     the state where it is.
   - **Marker check.** If `.orchestrator/handoff/spec-paused` exists and
     holds the issue number `state get issue` prints, ask nothing and go to
     step 4. `spec pause` writes it when the session that wrote the spec
     stops, so the spec is already written and the rewrite decision would be
     made about an issue just written. A marker naming another issue counts
     as no marker: go on to 0a.
   - **0a. Redo check.** If any `.orchestrator/handoff/pre-redo-spec-*` folder
     exists, ask nothing and go to step 4. `redo spec` leaves that folder for
     either kind of redo and nothing removes it for the rest of the flow, so
     it means a `redo spec` ran in this flow: the issue body is newer than
     `01-plan.md`, and a rewrite would silently undo reviewed work.
   - **0b. Make the rewrite decision.** Ask nothing. Read the body first
     with `bash "$ORCH" issue fetch <n> <file>` (a `mktemp` file outside the
     repo), opened with the Read tool, never `cat`, and compare it with
     `01-plan.md` (`bash "$ORCH" handoff path spec`). Then decide:
     **Rewrite** when the plan changed the issue's scope or substance,
     including any glossary or ADR wording the planning decided and the
     plan's agreed seams line when the body does not state those seams - a
     blueprint's too, so the rewrite's retire-or-keep question still meets
     its breakdown; **As it stands** otherwise: a blueprint the plan did not
     change (the body is already a spec), an issue the interview only
     confirmed, or a body that already reflects the plan. Before acting,
     print one line naming the decision and its reason, so a human watching
     can stop a wrong one: `Rewriting #<n> from the plan: <reason>` or
     `Reviewing #<n> as it stands: <reason>`. The line is not a turn-final
     reply: see **Unattended printout** in `docs/turn-final-reply.md` under
     the plugin root, and go on to 0c or the review in the same turn.
   - **0c. On Rewrite**, invoke the `orch-to-spec` skill in rewrite mode on
     the issue (args `<n>`), from `01-plan.md` - its **Rejected alternatives**
     section is load-bearing, as in step 1 - and follow it. Its test-seams
     check comes with it, asked only when `01-plan.md` records no agreed
     seams, and so does its retire-or-keep breakdown question, unchanged;
     step 5 then reads what it left (`retired` leaves no
     breakdown, so the issue is broken down again; `kept` skips it). If it
     stops without reporting the issue number, stop the phase: leave the
     state as it is (the phase stays `spec`), say what blocked, and leave
     whatever it already published - a replaced body, a retired breakdown -
     in place; a re-run of the phase reaches 0b again. Otherwise stop the
     session, as at the end of step 3.
   - **0d. On As it stands**, go to step 4.
1. Read `bash "$ORCH" handoff path spec`. The **Rejected alternatives** section
   is load-bearing: do not re-propose anything it rules out.
2. Invoke the `orch-to-spec` skill and follow it. It checks the test
   seams with the user only when the plan handoff records no agreed seams, and
   reports the issue it published.
3. Record the published issue: `bash "$ORCH" state set issue <number>`.
   Then stop the session: the spec review runs in a fresh one, without this
   session's code exploration. Run `bash "$ORCH" spec pause`; it writes the
   `spec-paused` marker, leaves the phase at `spec`, and prints the stop
   block. Relay its output verbatim and say nothing after it, as **Printing
   the boundary** says for a phase boundary. On a non-zero exit, relay its
   `orch:` message and stop. The fresh session's step 0 takes the marker
   check to step 4. Step 0d and step 0a explore no code, so they go to step
   4 in this session and never stop here.
4. Ask the round count. First fetch the spec body, so the recommendation
   rests on the spec: `bash "$ORCH" spec fetch <file>`, with `<file>` a
   scratch file under `.orchestrator/`, and open it with the Read tool.
   Size the recommendation from it: **1** for a one-site spec, **2** by
   default, **3** for a large or cross-cutting spec (many acceptance
   criteria, several modules, a new noun or ADR). A failed fetch stops the
   phase, as `spec-phase.md`'s step 1 says for its own fetch.
   **The question blocks** - ask it as one question
   with the host's ask tool (see `docs/host-capabilities.md`), before the
   first round: "How many spec review rounds?" Any integer >= 1; there
   is no upper cap. Options: **2**, **1**, **3**, and **Other**
   for any other number, the recommended one listed first, its label
   followed by " (Recommended)" and its description giving the scope-based
   reason in one clause. 0 is not offered, deliberately: a flow's spec is
   always reviewed. An Other that is not a whole number of 1 or more is asked
   again, naming the range. It is asked every time this step starts at
   round 1 - on `redo spec` and for an adopted issue too - and never when
   step 0's round check resumes a later round. Nothing is written to
   `state.json`: from round 1 on the count lives in the round marker `spec
   round-dir` writes.

   Then invoke the `orch-spec-review` skill and follow it for that many
   rounds, its spec-phase entry: read `spec-phase.md` in that skill's
   directory alongside its main file. It owns the review - each round four
   lenses, one batch question,
   the body rewritten with what the human accepts, and, when the accepted
   edits touch an open ticket of an existing breakdown, a ticket question
   that edits those tickets or retires the breakdown. This step is
   part of the phase, not an option in it: no spec reaches the implement phase
   unreviewed, and the human's control is at each round's batch, where they may
   decline every edit.

   Each round but the last runs in its own session. After round k of n,
   k < n, has applied its answer - and amended `01-plan.md`'s **Rejected
   alternatives** for any declined `contradicts the plan` item - run
   `bash "$ORCH" spec pause --round <k>/<n>`. It writes the round marker
   and prints the stop block: relay it verbatim and say nothing after it,
   as **Printing the boundary** says; nothing asks whether to stop the
   review there. On a non-zero exit, relay its `orch:` message and stop.
   The fresh session's round check runs round k+1. Round n runs to
   completion in its session, and the phase goes on to step 5 there.
5. Run `bash "$ORCH" breakdown state <spec issue>` first, with the spec issue
   from `bash "$ORCH" state get issue`. It prints one word, and exits 2 when
   GitHub cannot be read (relay its message and stop).

   **`complete`** means the issue already has a whole ticket breakdown - as for
   a blueprint adopted at init, one a step-0c rewrite kept, or one published
   in full; a default `redo spec` retires the breakdown first, so it never
   reaches this answer. Skip the breakdown and ask nothing: step 4's spec
   review may already have reconciled the breakdown with the edits it applied.

   **`partial`** means a breakdown was approved and saved but not fully
   published: run `bash "$ORCH" breakdown publish <spec issue> <saved draft>`
   on the saved draft (`.orchestrator/breakdown/<spec issue>/draft.md`) with no
   quiz and no new draft, and report its published numbers.

   **`none`** means there is no breakdown: invoke the `orch-to-tickets` skill
   on the
   just-reviewed spec issue and follow it, through its own quiz until the
   user approves a breakdown. It publishes 2 or more tickets as sub-issues,
   or collapses 0 or 1 into the spec issue under its fixed `## Ticket`
   heading, and reports which: the published numbers, or `collapsed`. This
   step is part of the phase, not an option in it, the same way the review
   above is not: no spec reaches the implement phase without its breakdown.
   A step-0c rewrite or a step-4 review that retired the breakdown also
   lands here.

   **Exit 2** means GitHub could not be read: stop, leaving the state
   where it is, say what blocked, and offer `/orchestrator:abort`.
6. Invoke the `orch-handoff` skill for `02-spec.md`; validate it with
   `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path implement)"`,
   fixing and re-validating until it passes.
7. `bash "$ORCH" phase advance`. It validates `02-spec.md` again and checks the
   issue is recorded before recording the implement phase; on a FAIL the phase
   stays at spec - fix what it names and run it again. Relay its output (see
   **Printing the boundary**).

## In an autopilot flow

When `bash "$ORCH" autopilot active` exits 0 the spec phase runs unattended
and stops for the human only on a fundamental item of the spec review
(ADR-0052). Step 0 is skipped: the plan's `## Autopilot` block settled what it
decides, so the issue is reviewed as it stands - no rewrite decision, no
marker check, no redo check. The round check still runs, first. Step 4 asks
no round-count question: the count is `bash "$ORCH" autopilot rounds`. The
round check's `<k> <n> applying` means a spec-review apply died partway: run
`bash "$ORCH" spec-review apply <dir> --resume --round <k>/<n>` (it reruns
with the answer it saved) and go on from the round it completes. The round
check's `<k> <n> waiting` means round k holds fundamental items back
for the human's reply (`.orchestrator/spec-rounds/<k>/fundamental.md`): read
the reply with `bash "$ORCH" autopilot answer spec <file>` (a `mktemp` file
outside the repo). When it dies because no reply has come, re-post the
question with `bash "$ORCH" autopilot ask spec <file>` (the held-back items
from `fundamental.md`, as the round's first ask wrote them) and stop: the
phase never assumes the recommendations. With a reply, translate it into
`spec-review apply`'s answer grammar over the fundamental items, run
`bash "$ORCH" spec-review apply <dir> <answer> --round <k>/<n>` again - it
applies the whole batch in batch order (the other items as recommended),
follows the tickets, publishes the body, posts the round's one changelog and
removes `fundamental.md` - and go on to the round's pause, or, after round n,
to step 5.
Rounds run through the `orch-spec-review` skill, which runs unattended in
autopilot; step 5's breakdown runs `orch-to-tickets`' **Unattended breakdown**.
After `apply`, the plan handoff's **Rejected alternatives** entry that a
declined `contradicts the plan` item matches is amended, and the plan comment
re-posted, as the handoff skill's **Amending Rejected alternatives** section
says.
