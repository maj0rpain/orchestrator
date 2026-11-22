# Phase: implement

A reference file of the `orch-flow` skill, read only when `state get phase`
prints `implement`.

1. Read `bash "$ORCH" handoff path implement` and fetch the spec issue it names.
2. `bash "$ORCH" branch create` - creates `orch/<issue>-<slug>` off the flow's
   base branch (recorded in state at `init`) and records the base SHA the review
   will diff against. When it dies because the flow's base does not exist on
   origin, offer the maintainer the repair rather than an abort: `bash "$ORCH"
   base set <branch> --flow` points the flow at another base, then rerun `branch
   create`. A working tree with changes outside the planning allowlist, or a
   merge or rebase in progress, on the flow's branch is a dead session's
   leftover: `branch create` discards it (ADR-0054) - except in an interactive
   flow's main checkout, where it refuses instead, exit 1, naming the exact
   discard command and touching nothing. Relay that line and tell the human to
   run the command if the changes are not wanted, or commit them, then run
   `/orchestrator:next` again. When it exits 3, the checkout is a busy
   checkout - a branch the plugin made that has no PR yet. Stop the
   phase with the state left where it is, relay the busy line it printed, and
   tell the human to switch off the named branch, then run
   `/orchestrator:next` again. The flow's state already exists here, so it is
   never moved to a side checkout.

   **In an autopilot flow** (`bash "$ORCH" autopilot active` exits 0) neither
   case is offered: an exit 3, or a base missing on origin, is a failure. Ask
   no question and offer no `base set`; stop the phase with the state left
   where it is and exit, relaying the line `branch create` printed. The claim
   stays held, so the watcher labels the issue `needs-human` with a failure
   comment naming the phase, exit code and log.
3. Build the ticket frontier with the driver loop in `docs/driver-loop.md`
   (under the plugin root): loop steps a-f and its **Dispatching a
   subagent**, bound here as:

   - **the issue**: the spec issue;
   - **the branch**: the flow's branch;
   - **the record**: the implement handoff - its **Host fallbacks**, and
     step 6's **Merge resolutions** and **Verification**;
   - **the judge**: the review loop;
   - **the stop**: the phase stops, naming every failure;
   - **after loop step f**: this phase's step 4.

   The driver saves every returned report but a stop report (loop step d).
   Steps 5 and 6 read them back with `bash "$ORCH" ticket report show <n>`,
   for every saved ticket report, none held only in this session.

   Whether the breakdown is collapsed comes from structure, not from the
   handoff: run `bash "$ORCH" ticket exists <spec issue>`.
   **`sub-issues`** means the spec issue is a parent whose GitHub sub-issues
   carry the real tickets, and the loop works its frontier. **`collapsed`**
   means the breakdown collapsed to 0 or 1 tickets and published no
   sub-issue: no `ticket next`/`ticket close` loop runs against it, since an
   empty frontier there means nothing was ever split out, not "already done."
   The sequential path dispatches exactly one subagent, for the spec issue
   itself, in its own ticket worktree `t<spec issue>`: merged, never closed.
   **Exit 1**
   means no breakdown exists: the phase stops, naming it. **Exit 2** means
   GitHub could not be read, or `ticket exists` was misused: the phase stops,
   leaving the state where it is.

   The phase reads its agent settings once, before loop step a, as
   **Dispatching a subagent** says, per **Agent settings** in
   `docs/host-capabilities.md`: `bash "$ORCH" agent get implementer` and
   `bash "$ORCH" agent get resolver`. Step 4's base sync starts its resolver
   on that same `resolver` setting.
4. **Base sync.** Bring the flow's branch up to date with its base before
   its PR opens, by **A driver's base sync** in
   `agents/orch-resolver.md` (under the plugin root), with the spec issue
   as the resolver's issue. Keep its **Merge
   resolutions** for step 6. A failed sync stops the phase before `pr open`,
   leaving the state where it is: say what blocked it, per **Rules**. A
   resolver's `Verification` reading `fail` does not stop it.
5. `bash "$ORCH" pr open "<title>" <body-file>`. The PR opens as a draft;
   marking it ready is the review loop's success condition. The PR targets the
   flow's base branch. `pr open` itself writes the issue line ahead of the
   body - `Closes #<issue>` when the base branch is the default branch, `Refs
   #<issue>` otherwise - so the body file carries no closing keyword of its
   own. On a restart that updates the PR the flow already records, the line
   follows the base that PR actually targets, and `pr open` warns when that
   differs from the flow's base.
   Write the body file, a temporary file outside the repo, by the
   `## Style rules` and `## Body layout` sections of `docs/pr-writing.md`
   (under the plugin root), which own its headings and style. Its
   **Summary**, **Evidence** and **Merge Danger**
   are judged against `git diff <base SHA>..HEAD`, with the base SHA from
   `bash "$ORCH" branch base-sha`; **Evidence** draws on
   the `Evidence` lines (each saved report's sixth), and its last line is step
   3's combined verification command with `pass` or `fail`. This site adds
   no audit heading of its own: the implement handoff carries the
   deviations and merge resolutions. `pr open` refuses a body missing a
   piece the layout requires, naming each; fix the body file and rerun it.
   Append `--label <name>` once for each label the repo's own instructions
   (its `CLAUDE.md`, `AGENTS.md` or `CONTRIBUTING.md`) require on this PR,
   judged against the same diff - none when they require
   none. The PR then carries them from creation, so CI's first run sees
   them; never add one afterwards with `gh pr edit`. A `pr open` that fails
   on a label stops the phase, relaying its reason.
6. Invoke the `orch-handoff` skill for `03-implement.md`, assembling these
   sections from every saved ticket report, step 3's combined verification and
   step 4's base sync:
   - **Deviations**: one bullet per ticket whose `Deviation` line is not
     `None`, naming the ticket and holding all of its deviations. "None" only
     if not one ticket reported a deviation, never left blank.
   - **Unmet criteria**: one bullet per ticket whose `Criteria` line names an
     unmet criterion or an `untested:` file, naming the ticket, each
     criterion, and each untested file. "None" otherwise.
   - **Verification**: from step 3's combined verification - the one run
     over the whole branch once the frontier was exhausted, not any ticket's
     - in the shape the `orch-handoff` template gives. A `fail` stays here,
     never under **Deviations**: a failing verification is not a deviation.
   - **Merge resolutions**: step 4's base sync's and loop step e's ticket
     resolutions, per **Merge resolutions** in `agents/orch-resolver.md`
     (under the plugin root).
   - **Base SHA**: `bash "$ORCH" state get base_sha`, read after step 4's
     sync moved it.
   Then validate it: `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path
   review)"`, fixing and re-validating until it passes.
7. `bash "$ORCH" phase advance`. It validates `03-implement.md` again and checks
   the branch, base SHA, and PR are recorded before recording the review phase;
   on a FAIL the phase stays at implement - fix what it names and run it again.
   Relay its output (see **Printing the boundary**).
