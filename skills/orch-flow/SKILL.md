---
name: orch-flow
description: Drive the plan/spec/implement/review pipeline recorded in .orchestrator/state.json. Use when a planning session's plan has just been approved, when the user asks to start, advance, check, diagnose, redo, abort, or finish a flow, or runs /orchestrator:start, /orchestrator:next, /orchestrator:flow-status, /orchestrator:health, /orchestrator:redo, /orchestrator:abort, or /orchestrator:finish.
---

# Orchestrator flow

Four phases, four sessions: **plan -> spec -> implement -> review**. Each phase
runs with fresh context, reading a handoff file the previous phase wrote. You
are driving exactly one phase. Do the phase, write the handoff, stop.

## Resolve the script first

Every deterministic operation lives in `orch.sh`, so that reading state, naming
branches, and validating handoffs cannot drift between sessions:

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset and the host gave this skill's directory,
`ORCH` is `scripts/orch.sh` two directories above this skill's own directory
(the plugin root). Otherwise run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths. Run `bash "$ORCH" help` for the full
command list. Never reimplement what it already does.

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code,
`agy plugin install <clone-dir>` on Antigravity, or `maj0rpain/orchestrator` as
a Junie extension, which is unverified).

## Host capabilities

Steps here name capabilities: invoke a skill, ask a multiple-choice question,
start a fresh subagent, start a background subagent, start a fresh
session. Skills are named bare
(`orch-handoff`); on Claude Code the scoped name is `orchestrator:<name>`.
`docs/host-capabilities.md` under the plugin root maps each capability to your
host. Where your host's cell says **Fallback**, or **Unverified** and the
capability turns out missing, take the fallback it documents and record it in
this phase's handoff under **Host fallbacks**. Where this file offers the human
an `/orchestrator:<command>`, here or in a skill this flow runs, and your host
has no plugin commands, offer the matching section of this skill instead.

## Starting a flow

Reached when a planning session's plan is approved. Runs in the planning
session, which holds the only copy of the plan.

1. Read the user's arguments, if any (on Claude Code, `/orchestrator:start`'s):
   a slug, `--issue N`, `--side`, any of them, or none. Pull `--issue N` and
   `--side` out first. Whatever remains is the slug; use it as given. With
   none left, pick a slug from the plan's subject, kebab-case. Confirm it in
   one line. With `--side`, or when the human asked in words for a side
   checkout, skip steps 2-6 and go to **Starting in a side checkout** below.
2. `bash "$ORCH" init <slug>`, or `bash "$ORCH" init <slug> --issue N` when the
   user (or step 1's `--issue N`) named an already-open,
   already-triaged issue to adopt as the flow's spec instead of publishing a
   new one. `init` validates adoption immediately and dies if it cannot -
   report the failure and stop rather than continuing without an issue.
   It also refuses while the working tree has changes outside the planning
   allowlist, listing them: show the human the list and stop. Do not commit,
   stash, or discard them yourself - they may be the planning edits the guard
   exists to catch.
   Starting over a `done` flow archives it automatically and reports where.
   `init` exits 3, and only then, in a busy checkout: a flow still
   mid-pipeline (`spec`/`implement`/`review`), or a quick implementation
   still running here - a branch the plugin made that has no PR yet and was
   not retired by a redo. Dirty
   paths are not a busy signal here: they get the exit-1 refusal above.
   **On exit 3, and on no other failure**, offer the human a side checkout
   as a multiple-choice question, quoting the busy line `init` printed: start
   this flow in a side checkout, a git worktree of its own beside the work
   already here, or stop. On a yes, go to **Starting in a side checkout** below.
   On a no, report the refusal and save the plan as for any other failure.
   **Whenever `init` fails, save the plan before stopping** - a failed
   precondition must never cost the user their plan. Write it, in the
   `01-plan.md` template from the `orch-handoff` skill, to
   `.scratch/orch-plan-<slug>.md`. `.scratch/` is on the planning allowlist, so
   the file never causes a refusal of its own. Tell the human where it is. Once
   they have fixed what `init` reported, rerun from step 2, in this session or a
   fresh one given that file.
3. Invoke the `orch-handoff` skill to write `01-plan.md`, from this session's
   plan or from the `.scratch/orch-plan-<slug>.md` step 2 saved. **Do
   this before anything else that can fail.** `init` is the one check that runs
   first, because it creates the directory the handoff goes in.
4. `bash "$ORCH" handoff validate "$(bash "$ORCH" handoff path spec)"`. Fix and
   re-validate until it passes.
5. `bash "$ORCH" doctor --env`. Report its output; stop only on a non-zero exit.
   A `warn` is an observation the user should see, not a reason to cost them a
   restart - the plan is already safe on disk either way.
6. `bash "$ORCH" phase boundary`, and relay its output (see **Printing the
   boundary** below).

### Starting in a side checkout

Reached from step 1 (`--side`, or the human asking) or from step 2 (a yes to
the offer on exit 3). Still in the planning session, which holds the plan.
Every `orch.sh` command after the first runs inside the side checkout -
`cd "<path>" && bash "$ORCH" ...` each time, since the working directory is
what tells `orch.sh` which flow it means.

1. `bash "$ORCH" side-checkout add <slug>`. It first sweeps finished side
   checkouts and reports them; a failed sweep is reported and `add` carries
   on. Its last line of output is the side checkout's path. If `add` fails -
   the path already exists, or the base branch cannot be fetched - relay its
   message, save the plan to `.scratch/orch-plan-<slug>.md` as step 2 does,
   and stop.
2. Inside the side checkout, `bash "$ORCH" init <slug>`, or
   `bash "$ORCH" init <slug> --issue N` as in step 2 above. If it fails, save
   the plan to `.scratch/orch-plan-<slug>.md` in this checkout as step 2 does,
   tell the human the side checkout's path, and stop.
3. Invoke the `orch-handoff` skill to write `01-plan.md` into the side
   checkout's handoff folder: the path `bash "$ORCH" handoff path spec`
   prints when run inside the side checkout. Validate it there with
   `bash "$ORCH" handoff validate <that path>`, fixing and re-validating
   until it passes.
4. Print the one command that opens a session in the side checkout - `cd
   <path> && claude "/orchestrator:next"` on Claude Code, which opens it with
   the command already typed, `cd <path> && junie` on Junie, telling the human
   to run `/orchestrator:next` there (on a host with no plugin
   commands, to ask for this skill's **Next phase**). This session's work is
   done: the spec phase starts in that new session, like any other.

## Next phase

Reached by `/orchestrator:next`, or when the user asks to run the flow's next
phase. Run it in a fresh session: if the context still holds the previous
phase, tell the user to start a fresh session (Claude Code `/clear`, Junie
`/new`) and stop rather than continuing.

1. `bash "$ORCH" doctor --flow`. On a non-zero exit, report and stop - offer
   `/orchestrator:abort` or a concrete repair. Do not proceed on stale state.
2. `bash "$ORCH" state get phase`, then run that phase below.

### Phase: spec

Read `phase-spec.md` in this skill's directory and follow it.

### Phase: implement

Read `phase-implement.md` in this skill's directory and follow it.

### Phase: review

1. `bash "$ORCH" doctor --flow`.
2. Invoke the `orch-review` skill and follow it. It owns the
   loop; this file owns phase dispatch, and has nothing to add to a review
   beyond getting you there.

A flow may pass through this phase more than once. A loop that ends in a
bounded stop leaves `phase` at `review`, and a human who wants more looks runs
`/orchestrator:next` again: that is a fresh loop with its own budget, continuing
the flow's iteration numbering, and it reads `03-implement.md` like the first
one did.

## Printing the boundary

Every phase ends the same way, because the next phase needs a session this one
cannot start. `orch.sh` owns the block that says so, and its host's `Next:`
line: `phase advance` prints it on success, and `phase boundary` prints it at
flow start. The spec phase's stop after writing the spec ends the same way,
through `spec pause`, and so does each pause after a spec review round but
the last, through `spec pause --round`. Relay that output verbatim - never
compose the block yourself.

Say nothing after it. Do not start the next phase, and do not offer to.

## Status

Reached by `/orchestrator:flow-status`, or when the user asks where the flow
stands. Run `bash "$ORCH" status` and `bash "$ORCH" doctor --flow`, and report
both outputs. Read-only: do not start, advance, or repair a flow from here. If
`doctor` reports a problem, say what it found and stop.

## Doctor

Reached by `/orchestrator:health`, or when the user asks to diagnose the
machine, the repo, or the flow. Run `bash "$ORCH" doctor` and report its output.
Read-only: `doctor` prints a remedy for each problem that has one, and running
one is the user's call. A remedy is a runnable command, verbatim, wherever one
command fixes the problem; where none does (for example an edit to the repo's
own content, such as glossary entries, a Standards paragraph or a verification
line, or relabelling an issue) it is a short plain instruction saying what to
do: the file and the edit when the fix is to the repo's own content, otherwise
the action or the condition (such as what the watcher will run). A `FAIL` exits
non-zero and would block the flow; a `warn` is an observation and does not.

## Redo

`state.phase` names the phase that runs **next**, so re-running the phase that
just finished means stepping back one first. Only two directions are
supported - `review -> implement` and `implement -> spec` - each a mechanical
transition driven by `orch.sh`, not a per-artifact interview. Redo targeting
`phase: done` remains unsupported, exactly as today - it is not discussed by
the originating issue and is not expanded here.

**From `review`**: `bash "$ORCH" redo review`. It refuses unless the review loop
has reached a **bounded stop**, detected from the `## Terminal state` heading
the review skill's Termination step writes into the final iteration's
record. A PR marked ready has already moved `state.phase` to `done` as part
of that same termination - out of scope per above - so `stop` is the only
terminal state redo actually acts on. On a refusal, report the message and
stop rather than doing anything destructive:

- No loop has run yet: offer `/orchestrator:next` to start one.
- Still short of its budget: offer `/orchestrator:next` instead - that is what
  resumes a loop still mid-flight, and redo is for after a loop ends.
- The last iteration has no recorded terminal state: the session looks
  interrupted, not stopped - offer `/orchestrator:next` to resume it.
- The last iteration's terminal state is `malformed` - present, but its first
  line is not in the shape the message quotes: tell the user to rewrite the
  record's first line in that shape, not to run `/orchestrator:next`.

Once confirmed terminal, it runs without asking anything further - retiring
and closing are not destructive: the old branch is renamed aside
(`orch/<issue>-<slug>-redo-N`, never force-pushed over), the old draft PR is
closed with a comment pointing at the redo, the old loop's
`.orchestrator/review/iteration-NN.md` records move into `pre-redo-N/`,
the stale `03-implement.md` handoff moves into
`.orchestrator/handoff/pre-redo-N/` (the same N),
`state.branch`/`state.pr`/`state.base_sha` are cleared, `state.iteration` resets
to 0, `state.redo_count` increments, `flake_rerun_used` is left untouched
(`docs/adr/0007-redo-resets-the-review-loops-iteration-and-budget.md`), and
`state.phase` becomes `implement`.

A re-run after a death resumes the redo: while it is half-finished, the stopped
loop's last record is read from `pre-redo-N/` once it has moved, and
`review retire` moves whatever records are still flat into the folder its
first run made.

Abort differs on purpose: it ends the flow with no successor phase, so a
mistaken call loses the live flow's state, whereas redo always leaves a live
flow behind and every transition it makes can be undone by another `redo` or
`next`.

**From `implement`**: ask the human once whether to keep the existing spec
issue and re-review it, retiring its ticket breakdown (default), or publish a
fresh one. Then call
`bash "$ORCH" redo spec` or `bash "$ORCH" redo spec --new-issue` accordingly.
The default keeps the issue and retires its ticket breakdown - each sub-issue
closed as not planned if still open, commented on and unlinked, or the
collapsed `## Ticket` section cut from the body - then changes `state.phase`
to `spec`, so the spec phase's step 5 breaks the redone spec down again; the
spec phase's step 0 does the rest: the `pre-redo-spec-*` folder below makes
it skip the rewrite decision and go straight to the spec review.
If GitHub fails while retiring, or anything else dies before the step back
(including after `--new-issue` has closed the old issue), it dies with the
phase still `implement` and `state.issue` still recorded, and a re-run
resumes: the step back is one closing state write, taken last. Either way the
stale `02-spec.md` handoff, and `03-implement.md` if one exists, move into
`.orchestrator/handoff/pre-redo-spec-<UTC timestamp>/`, so `phase advance`
cannot leave the redone spec phase on them, and the `spec-paused` marker and
the round marker move with them, so neither can carry the redone phase past
step 0 or past round 1. It also retires the attempt's branch and PR, as
`redo review` does (branch renamed to `orch/<issue>-<slug>-redo-N`, PR closed
with a comment, `branch`, `pr` and `base_sha` cleared), and bumps
`state.redo_count` when it retires a branch; with no branch yet it retires
nothing. It refuses up front while ticket worktrees are left.
`01-plan.md` is never touched by either redo. `--new-issue`
additionally closes the old issue first (never deletes it) with a comment
explaining why, and clears `state.issue`, so `orch-to-spec` runs again from
scratch.

## Abort

1. Confirm with the user.
2. `bash "$ORCH" archive`. In a side checkout it moves the flow to the main
   checkout's archive, then removes the worktree, never with force: a dirty
   one is reported and kept. Relay what it prints, and when it says this
   session's working directory is gone, tell the user to close this session.
3. Report what survives: the branch, the spec issue, and the PR are untouched,
   so list whichever exist and let the user clean up.

## Finish

Reached by `/orchestrator:finish`, or when the user asks to clean up finished
side checkouts. It takes no arguments and asks nothing. Run
`bash "$ORCH" side-checkout prune` and relay its report: each side checkout
removed, each skipped with its reason, and any failure. A side checkout is
finished when GitHub reports its branch's PR merged into its base branch, its
working tree is clean, and any flow in it is at `done`. The sweep archives
each one's flow into the main checkout, removes the worktree, never with
force, and deletes its local branch. The main checkout's finished flow is
archived in place, and its branch stays checked out. A worktree the human
made is reported and left alone. When GitHub cannot be read, nothing is
removed: say so. When the report says this session's working directory is
gone, tell the user to close this session.

## Rules

- **One phase per session.** The context you accumulated is exactly what the
  next phase must not inherit.
- **One flow at a time.** `init` enforces it, per checkout. A second feature
  runs in a side checkout (see **Starting in a side checkout**).
- **Never merge.** The flow opens a draft PR and stops. Merging is the user's.
- **Never edit `.orchestrator/state.json` by hand; the phase moves only through
  `phase advance`, `review ready`, and redo, and `issue`, `budget`, and
  `flake_rerun_used` change only through `orch.sh state set`.**
- If a phase cannot finish, leave the state where it is, say what blocked it,
  and offer `/orchestrator:abort` (which archives rather than deletes).
