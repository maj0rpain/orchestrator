# CI, Termination, and the closer

A reference file of the `orch-review` skill, read once the loop reaches
**Termination** (when `review begin` refuses, a base sync fails, or known
items could not be built).

## CI

Waited on **once per loop**, at **Termination**, and never inside an
iteration: that would block a single session for most of an hour, and the fix
commits are pushed as they land anyway. Each iteration's triage only looks at
it, once, with `review ci --no-wait`, which never waits and writes no state,
wait file or guard, so
the flake rerun and the stored wait total are as they were (see **The
iteration**, step 4).

`review ci` is a **re-callable command**. Run `bash "$ORCH" review ci` in the
foreground and wait for it (host capability *Run a long command*), and run the
same command again each time it exits 75, which means still running, never a
word below; the fifteen-minute total is kept across calls. Never background it
and sleep, poll or kill it.

`bash "$ORCH" review ci` polls the PR's checks and prints one of four words,
exiting non-zero on the last two:

- **green** - carry on.
- **none** - the repo has no checks. Carry on: requiring CI in a repo that has
  none would make this plugin unusable in its own repo. It arrives without
  waiting the grace when the repo shows no evidence of CI - no workflow files
  in the head, no required checks on the base branch, and no check or status
  on an earlier PR commit or the base tip - and its detail line says which.
- **failing** - a required check failed, and the detail lines name which.
  Required means required by the branch protection of the PR's base branch. If
  it looks flaky rather than caused by the change, the loop has **one** flake
  rerun: `bash "$ORCH" state get flake_rerun_used` reads `true` once it is spent
  and `false` while it is not. Spend it with `bash "$ORCH" review rerun <pr>`,
  which reruns the failed jobs of every GitHub Actions run behind the failing
  checks `review ci` counted (the required ones, else all), once each:

  - **exit 0** - every rerun started. Only this spends the flake rerun.
  - **exit 1** - a failing check is not an Actions run, so no rerun could
    make CI green and none was started: a **bounded
    stop** on the spot, spending nothing.
  - **exit 2** - anything else (GitHub unreadable, the rerun refused): a
    **bounded stop**.

  On exit 0, record `bash "$ORCH" state set flake_rerun_used true` and ask
  `review ci` again, run the same way: re-called while it exits 75 (host
  capability *Run a long command*). A
  second failure is a **bounded stop**. That second ask
  restarts the fifteen-minute wait rather than inheriting what is left of the
  first, because a rerun restarts the checks - so this one path, once per loop,
  can wait longer than the cap. A second ask that times out is **unreachable**
  like the first.
- **unreachable** - GitHub would not answer, or the checks were still pending at
  the cap. A **bounded stop**: marking a PR ready over a result nothing ever
  produced claims a verification that never happened.

A `review ci` the host stops at its timeout is run again, as one that exited
75 is: the total is kept.

### CI failure judgement

- **failing**, at **Termination** in an autopilot flow (and in step 4 of **The
  iteration** in every flow): judge it before it is called a reason. Read
  `bash "$ORCH" review ci-log <pr>`. The failure needs a decision, a human
  reason, when any of these holds: it would fail on the base tip too (judged
  from the log and the diff: it lies in code or config the change does not
  touch); its cause is infrastructure (secrets, permissions, runners, quota); a
  failing check is not an Actions run (the output says so); the fix needs a
  choice the spec leaves open; or you cannot tell which case it is, a job whose
  log could not be read among them. Otherwise it is a failure the change can
  fix, an automatic reason.

## Termination

Reached when `review begin` refuses, from a failed base sync (step 2 of
**The iteration**), or from known items that could not be built (step 3).
The same close-out runs whichever terminal state follows, in this order:

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
that claims a verification that never happened. An open blocking finding or a
missing look remains in the final record. Or this loop filed a spec question, a
behaviour decision the spec left open: the reason names each, so a human
rules on it before the PR goes ready. Or a base sync that failed, the reason
naming the unresolved merge or the refusal. Or known items that could not be
built, the reason reading `stop - known items could not be built.` Or CI:
`failing` with the flake rerun spent or the failure not looking flaky, or
`unreachable`. The terminal action is to stop: **leave `phase` at `review` and
the PR in draft**, and tell the human the reason and the closer's issue numbers.
`done` means "this succeeded", never "this stopped". A human may re-enter the
review phase from here; that is a fresh loop with its own budget, and **Before
the first iteration** describes it.

**In an autopilot flow** the terminal action differs: read **Termination**
in `autopilot.md` in this skill's directory.

`## Terminal state` is written exactly once, here, only once a terminal state
has actually been decided - never guessed or backfilled. It is what
`bash "$ORCH" redo review` and `doctor --flow` both read, through the same
`review_terminal_state` classifier, to tell a loop that genuinely finished
from one whose driving session simply died mid-budget.

## The closer

**`orch-closer`**, under the plugin root's `agents/`, started fresh (see
**Starting an agent** in `SKILL.md`) once per loop, at **Termination**, after
the terminal state is decided. It files every unfixed major and nit across this
loop's records - those numbered above the **loop boundary**, less any a later
iteration of this loop fixed - through `orch.sh review file`, posts the loop's
one PR comment, writes the **Filed** list into the final record, and returns
the issue numbers; its brief carries the Filing and PR-comment rules. Its
prompt carries:

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
