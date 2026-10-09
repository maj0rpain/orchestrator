# Orchestrator

The vocabulary this repo uses to talk about itself. Glossary only: no
implementation details, no spec, no decisions. Decisions live in `docs/adr/`.

## Language

### Flow and phases

**Flow**:
One run of the pipeline, from an approved plan to a pull request. A flow is
identified by its slug and holds exactly one issue, one branch, and one PR. One
flow at a time per checkout - a second flow runs in a side checkout - except a
flow at phase `done`, which doesn't count against that limit: it no longer
blocks a new one, which archives it automatically rather than requiring it be
cleared by hand. Its alternative, for changes that don't need the pipeline, is
a quick implementation.

**Side checkout**:
A git worktree the plugin makes inside the repo, so a second flow or a quick
implementation can run beside the work already in this checkout, in a session
of its own. Offered when a flow is already mid-pipeline, or made when a human
asks for one. It counts as a checkout in its own right, so it holds at most
one flow. One made for a quick implementation records that implementation's
issue, so a session opened in it picks the issue up without being told. It is
removed when its flow is archived with `archive` or
`/orchestrator:abort`, by `/orchestrator:finish` once its work is finished, or
by hand, and never with force.
_Avoid_: sibling worktree, flow worktree, second checkout.

**Finished**:
A side checkout is finished when its branch's pull request has merged into its
base branch, its working tree is clean, and it holds no flow or a flow at
`done`. A flow is finished when it is at `done` and its pull request has
merged. `/orchestrator:finish` cleans up only finished work.

**Phase**:
One of the four stages a flow passes through: **plan**, **spec**, **implement**,
**review**. Each phase runs in its own session with no memory of the previous
one - with one deliberate exception: a review loop drives all of its iterations
from a single session (ADR-0001), so inside the review phase the unit of fresh
context is the loop, not the iteration. The loop is the unit of fresh context
for its driver; the reviewers and the fixer get fresh context every iteration.
A flow's spec review is a step of the spec phase, not a phase of its own.

Note the tense: the recorded phase names the stage that runs **next**, not the
one that just finished.

A flow leaves a phase only once the handoff it writes for the next one is
valid; the step back of a Redo retires the handoffs it makes stale.

**Handoff**:
The written record one phase leaves for the next, and the only thing that
crosses a phase boundary. A handoff references artefacts that already exist (an
issue, a PR, a diff) and states what exists nowhere else: reasoning, rejected
options, deviations.

**Redo**:
A deliberate step back to re-run a phase whose output was wrong - never the
review loop's own re-entry, which reruns the *same* accepted change for more
looks. `state.phase` names the phase that runs next, so redoing the phase that
just finished means stepping back one first: `spec -> implement -> review ->
done`, in reverse.

Redoing back to `implement` is only available once the review loop has reached
a terminal state, never mid-budget - re-entry already covers "give this change
more looks," so Redo only has a distinct meaning once the loop is done deciding
that on its own. Redoing back to `spec` re-reviews the flow's existing issue by
default, rather than publishing a second one, and retires that issue's ticket
breakdown so the redone spec is broken down again.

**Adopted issue**:
An issue given to a flow at init, instead of one the spec phase publishes.
Checked once, at init, for existing, open, and carrying the `ready-for-agent`
triage label; the spec phase then skips writing a spec entirely and runs the
spec review straight against it.
_Avoid_: existing issue, pre-existing issue, given issue.

**Interviewed issue**:
An open issue a planning session was run about, or the open issue the human names in its place when the session closes. When the human confirms the plan, the session offers to move it to the `ready-for-agent` triage label, since the interview settled what triage would have. A blueprint drawn from that session rewrites this issue as its spec issue rather than publishing a new one.
_Avoid_: planned issue, subject issue.

### Repository and tooling

**Repo**:
The GitHub repo whose issues, PRs and checks the orchestrator reads and
writes. The one the checkout's `origin` remote points at, unless the caller
names another; never the one `gh` would pick by default. In a fork, that is
the fork, not the upstream. Its default branch is the one **Base branch**
falls back to.
_Avoid_: upstream, gh's default repo (as the general term).

**Base branch**:
The branch a flow or quick implementation forks from and opens its PR
against. The repo's default branch unless a human has set another for the
checkout - an integration branch such as `uat`, or a long-running feature
branch that several tickets feed. A flow fixes its base branch when it starts.
Neither a later change to the setting nor a redo moves it; a human can correct
it explicitly only while the flow has no branch: before it first branches, or
after `redo review` retires that branch. A quick implementation reads it when
it branches. A flow's base SHA is the base
branch's tip at the moment it branched, or at its latest base sync. A quick
implementation's base SHA means the same, recorded on its branch.
_Avoid_: target branch, integration branch (as the general term).

**Base sync**:
Bringing a flow's or quick implementation's branch up to date with its base
branch: merging the remote base branch's tip into it, never rebasing, and
moving its base SHA to that tip. A conflict is resolved by what each side
meant, never by picking a side. It runs before the change is first reviewed,
at the start of every review-loop iteration, and on demand.
_Avoid_: rebase, update branch.

**Resolver**:
The fresh agent that finishes one in-progress merge or rebase. It reads why
each side changed before resolving a hunk, keeps both intents where it can,
names any intent it drops, runs the repo's checks, and commits. It never
aborts.

**Release PR**:
The PR that carries a base branch other than the default back into the
default branch, closing every still-open issue whose work reached the base
branch. Those issues stay open until it merges: a PR into a non-default base
branch refers to its issue rather than closing it, because the work has not
landed yet. Which issues it closes is read from what merged into the base
branch, never remembered by a human.

**Doctor**:
A diagnostic surface a maintainer or agent can run at any time, via the
`doctor` command, to check that the machine, the repo, and the active flow are
sound. Organized into named scopes - `--env`, `--flow` - with bare `doctor`
covering everything. Every check it runs reports through one of three states -
`ok`, `warn`, or `FAIL` - and the overall report reflects the worst state seen
without aborting partway through.

**Planning allowlist**:
The files a planning session may legitimately change: agent docs, and
scratch and flow-state files. Anything outside it is either source, which
planning never touches, or a record - the glossary and ADRs - which planning
never changes in place: a change planning decides for a record is written
word for word into the spec, or into the linked issue's body for a quick
implementation, and lands with the change it describes. The edit
guard denies edits outside it while planning, on a host where the guard
arms - not Junie (ADR-0025) - and a flow at `done` does not disarm it. A flow
will not start while the working tree has changes outside it (ADR-0013).

### Quick implementation and blueprint

**Quick implementation**:
The other route from an approved plan to a pull request, alongside a flow.
Chosen once, by a human, at the close of a planning session - never assumed by
the model. Skips the plan/spec/implement/review pipeline entirely: no phases,
no handoff, no `.orchestrator/state.json`. Still produces its own branch and
PR, and is still held to this project's standards for how a change gets made -
test-driven, reviewed, then opened as a PR. Its review is a review pass, and
it names what it declines in the PR. Meant for small changes, run hands-off:
it takes an unattended spec review of its linked issue before its ticket
breakdown, on every run, and accepts its own draft breakdown without asking.
It skips that breakdown when the linked issue is a blueprint, including when
its spec review retired the blueprint's breakdown and broke the issue down
again.

**Blueprint**:
Everything a change needs before implementation, carried no further: its spec issue - published new, or the interviewed issue rewritten, its earlier breakdown retired and broken down again if the human chooses - reviewed if the human chose to, and its ticket breakdown. Chosen once, by a human, at the close of a planning session, as the alternative to starting a flow or a quick implementation. A flow later adopts it, or a quick implementation links it; either way its ticket breakdown is already published and is not run again, unless a spec review changes the spec and retires that breakdown - by the human's choice, or by its own recommendation in an unattended spec review.
_Avoid_: planning-only, parked spec, banked spec.

**Blocking edge**:
A native GitHub dependency recording that one ticket of a breakdown cannot
start until another, its blocker, is closed. `ticket next` reads only
these, never a ticket body's `## Blocked by` text.

**Ticket breakdown**:
The set of sub-issues published against a spec issue (a flow's, a quick
implementation's linked issue, or a blueprint's) - each one a sub-issue of that
parent, not a second issue the flow or quick implementation now holds, and
may block, or be blocked by, other tickets in the same breakdown. When the
approved breakdown - in a quick implementation, the drafted one - resolves to 0 or 1 tickets, no sub-issue is published at
all: the drafted ticket's content, if there is one, is folded into the
parent issue's own body instead, and the parent is worked directly as if it
were the sole ticket - a breakdown of one, collapsed onto its own parent
rather than split out beneath it.

**Ticket subagent**:
The fresh, non-fork agent that builds exactly one ticket of a ticket
breakdown, test-first, and checks its own work against that ticket's
acceptance criteria, and that a test exercises every source file it changed,
before reporting. It never reviews its work beyond those checks: review
belongs to the review loop, or to a review pass. It reports back
structurally instead of blocking on a human; a criterion it cannot meet alone
is reported as unmet, and a changed source file no test exercises is reported
as untested, both for the review loop's Spec axis to judge. Used in the
implement phase and in quick implementation. When its frontier is built in
parallel, it builds on a ticket branch in its own ticket worktree; otherwise
on the one branch, one ticket at a time. When its ticket branch conflicts as
it is merged, it is resumed to resolve the conflict itself, since it knows
its ticket's intent.

**Ticket branch**:
The branch one ticket subagent builds a single ticket on, forked from its
flow's or quick implementation's branch at the tip, and merged back into it
before the ticket closes. It is local and short-lived, gone once merged, and
is not the flow's one branch.

**Ticket worktree**:
The git worktree a ticket branch is checked out in, so ticket subagents of one
breakdown can build at the same time without sharing a working tree.

**Frontier**:
The open tickets of a ticket breakdown with no open blocker - what `ticket
next` prints. Several can be built at once, up to the clone's parallel cap.

### Spec review

**Spec review**:
One look at a spec issue, taken once. Usually a step of a flow's spec phase,
after the issue exists - published by the spec phase or already adopted at
init - and before its handoff is written. A human may also ask for one on
demand, against any issue, and a quick implementation takes an unattended one
before its ticket breakdown: either way a standalone spec review, which belongs to no
flow and leaves no handoff. It first proposes folding into the body anything
the issue's comments say that the body does not - a triage agent brief, a
follow-up - so the body stays the one place the spec is written. Its lenses
then read the spec, body and comments, independently - four in a flow, three
in a standalone review; every finding they report, and every consolidation item, is
put to a human with a proposed edit, and only the edits the human accepts
change the spec - in an unattended spec review, the recommended ones. When the issue already has a ticket breakdown and the
accepted edits touch an open ticket, it then raises the ticket question - how that
breakdown should follow - which a human answers, and an unattended spec
review answers with its own recommendation: edits to the tickets the change touches, or retiring
the breakdown so the issue is broken down again. A spec review runs once - it is not a loop and has no budget;
another look is another spec review.

**Unattended spec review**:
A standalone spec review that asks the human nothing: every recommended edit
is applied, every decision item takes its recommended option, and a ticket
breakdown the edits touch follows its recommended option, retiring included.
The batch is still shown and the changelog still records it all. Only a quick
implementation takes one.
_Avoid_: auto spec review, silent spec review.

**Consolidation item**:
One proposed edit in a spec review that folds into the spec body what an
issue comment says and the body does not - a triage agent brief, a
follow-up. The review's own session drafts it, never a lens, and it reaches
the human ahead of the lenses' findings, in the same batch, accepted or
declined like any other proposed edit, or applied as recommended in an
unattended spec review. Two comments that contradict each
other become one decision item instead. A comment that opens with a
`## Spec review` heading is the review's own history and never produces one.
_Avoid_: fold (as a noun), proposed fold.

**Lens**:
One of the four angles a spec review takes, each answering one question of the
spec and nothing else:

- **Fidelity** - does the spec say what the plan decided? Read against the
  plan's decisions, rejected alternatives, and constraints.
- **Consistency** - does the spec agree with itself, with the glossary, and
  with the recorded decisions?
- **Testability** - can every story and decision be proven at the agreed
  seams?
- **Implementability** - could a fresh session build it from the spec alone,
  and does the codebase allow what it asks?

Findings stay with the lens that reported them and are never ranked across
lenses. Fidelity needs a plan, so a standalone spec review runs without it and
records it as not run.

**Seam**:
The public boundary a test observes behaviour at. Seams are agreed with a human
in the spec phase, recorded in the spec and its handoff, and that agreement is
the only one: the implement phase tests at the seams it is given and does not
re-ask. A seam the code turns out not to allow is a deviation, recorded like
any other.

### Review loop

**Review loop**:
One run of the review phase in one session: a budget of iterations, every one a
fresh review of the whole change from the base SHA, ending in a terminal state.
The session that runs it is the loop's **driver**: it starts the reviewers,
triages what they report, and decides the terminal state, but never edits the
change itself - that is the fixer's work, and filing is the closer's - except
on a host with no fresh subagent, where it does their work itself (see
**Driver**).
A flow runs a loop each time it enters the review phase; a flow's loops share
one iteration numbering, and only a human decides that a further loop happens.
That further-loop decision is re-entry, not Redo: re-entry reviews the same
accepted change for more looks, Redo disowns it.

**Review pass**:
One look at a change by the two reviewers a review loop starts, with no loop
around it: no budget, no severity, nothing filed. The session that starts it
fixes the findings it agrees with and records each one it declines, with its
reason. A quick implementation takes one before its PR opens. A human may also
ask for one on demand, against an issue and the branch they are on - after a
quick implementation, say - which is a standalone review pass. Another look is
another review pass. A standalone review pass drops any finding an earlier
review pass on the same PR already declined, and lists it as previously
declined. A branch or issue an active flow holds belongs to that flow, never
to a review pass.
_Avoid_: single pass, quick review

**Budget**:
The number of iterations a review loop runs, chosen by a human when the loop
starts - five unless they say otherwise. A loop runs its whole budget: finding
nothing does not end it early, because every iteration is an independent look
at the same change, and the value of the loop is in the number of looks.

**Iteration**:
One pass within a review loop: sync the branch with its base, review the
change, triage what came back, fix what the loop fixes, verify. Iterations are
numbered from 1 and run on across a flow's loops; a flow that has run none
sits at 0. A loop runs as many as its budget allows. A review pass labels its
reviewer prompts with its own pass number, counted from `01` on each branch; it
is not part of a loop.

**Clean iteration**:
An iteration whose triage left nothing to fix, so no fixer ran. An iteration
whose fixer ran but fixed nothing is not clean: its triage found something to
fix, and whatever blocking finding the fixer could not fix is now **open
blocking**.

A loop finishes **Ready** only on a clean final iteration that leaves no open
blocking finding - one found in this iteration or carried in from an earlier
one - and no **missing look**, with CI green or absent. Anything else is a
bounded stop.

**Driver**:
The session that runs a review loop. It syncs the branch with its base,
starts the reviewers, the fixer, the closer and, on a conflict, a resolver,
triages what the reviewers report, waits on CI, and decides the
terminal state. It does not edit the change: every line the loop fixes is the
fixer's, and filing is the closer's. The one exception is a host with no fresh
subagent: there the driver takes the host-capabilities **Start a fresh
subagent** fallback, does the fixer's and the closer's work in its own
session, and records that as a host fallback.

**Reviewer**:
A fresh agent a review loop's driver starts for one axis - Standards or Spec -
in one iteration. It reviews the whole change from the base SHA, never from
the previous iteration's HEAD, and writes its findings, unranked, to a report
file. Two reviewers run every iteration, one per axis. A review pass starts
the same two reviewers once, outside any loop.
_Avoid_: spec review (for the Spec-axis reviewer or its report).

**Open blocking**:
A blocking finding the fixer could not fix. It is never filed: it carries into
the next iteration's triage - and, when a loop ends, into a re-entry's first
iteration - until a fixer fixes it, and while it stands in the final record it
blocks **Ready**.

**Missing look**:
An axis whose reviewer failed twice in one iteration, so that iteration
reviewed the change along the other axis only. A missing look in the final
iteration blocks **Ready**: nothing looked along that axis last.

**Fixer**:
A fresh agent a review loop's driver starts within an iteration, and only when
triage left something the loop fixes. It fixes, verifies, commits, corrects
any PR body statement its commit left unsupported (or records the corrections
that did not land when the body write fails), writes the iteration's review
record, and ends with the iteration: one fixer never sees another iteration's
work except through the records.

**Closer**:
A fresh agent a review loop's driver starts once, at termination, to turn the
loop's unfixed findings into filed findings and tell the PR what the loop did.
It reads only this loop's review records, and files nothing the driver's
triage marked met again; whether a finding is already filed is the driver's
call, never the closer's.

**Loop-authored lines**:
Lines the current review loop's own fix commits wrote. A major or nit on them
is filed, never fixed; a blocking finding on them is still fixed. A previous
loop's fixes are not loop-authored for the next one.

**Loop boundary**:
The `iteration` a review loop's driver reads before the loop's first
iteration. The loop's own records are those numbered above it; those at or
below it belong to earlier loops of the flow.

**Review record**:
The written account of one iteration: what was found, at what severity, what was
done about it, which issues were filed, and what CI said. Humans read it after
the fact; later iterations and loops read it for what earlier ones fixed and
filed, since no fixer or closer remembers anything the records do not say.

**Terminal state**:
One of the two ways a review loop can end: the PR marked ready, or a bounded
stop.

**Bounded stop**:
The terminal state of a loop that ended without the change being ready - because
its final iteration was not clean (it started a fixer, whose work nothing has
reviewed), left a blocking
finding its fixer could not fix, or lacked one of its two looks, or because CI
could not be called green. A stop is not a failed change and not a successful one.

**Flake rerun**:
The one permitted re-run of a failing CI check on the theory that it failed for
reasons unrelated to the change. The allowance belongs to the flow, not to the
iteration: one per flow, spent or not.

**Required check**:
A CI check that must pass before a change can land. Where branch protection
names them, those are the required checks; where it does not, every check on the
commit counts. A change with no checks at all is not thereby failing.

### Findings and triage

**Finding**:
One problem a review reports - about the change, from the review phase or a
review pass, or about the spec, from a spec review.
Only a finding about the change from the review phase carries a **severity**,
which the review phase assigns; the reviewer itself reports findings unranked.
A finding from a review pass carries none: the session that ran the pass
fixes it or declines it. A finding about the spec carries no
severity: a human accepts or declines the edit it proposes, or an unattended
spec review applies it as recommended, and it is never filed.

**Severity**:
Which of three roles a finding plays - how wrong the change is, and so which
findings the loop may fix without asking anyone:

- **Blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. Always fixed, in every iteration - or,
  when the fixer cannot, left open, holding the change out of ready.
- **Major** - the change works but carries real cost: a documented standard
  breached, a smell with teeth, scope nobody asked for. Fixed by the loop
  unless the fix needs a decision, changes behaviour, or would touch the
  loop's own fixes; filed otherwise.
- **Nit** - taste and judgement calls. Fixed by the loop only when it is a
  mechanical nit; filed otherwise.

A final iteration fixes only what is blocking: a major or nit found there is
filed, so a working change is never held in draft by a style finding.

**Mechanical nit**:
A nit with exactly one correct fix, confined to the lines it names, changing
no behaviour and leaving no wording or taste to choose - a typo, an unused
import, a comment naming the wrong function, a broken link. Rewording prose is
never mechanical, however small.

**Filed finding**:
A major or nit the loop did not fix, turned into an issue when a loop
terminates - because its fix needed a decision, would have changed behaviour,
was not mechanical, landed on loop-authored lines, was found in a final
iteration, or the fixer could not fix it. It carries the reviewer's finding
and the loop's reasoning about it, including which of those kept it out of the
loop, deduplicated across a loop's iterations by the closer and across a
flow's loops by the driver's triage. Its **Filed** entry names its file and
line, so a later loop's triage matches a finding it meets again on file, line,
and claim. A filed finding enters **finding triage** against the whole codebase rather
than against one diff: a later loop that meets it again leaves it alone, and
tells the human it did.
Findings the loop demoted on a human's earlier decision are reported, never
filed.

**Finding triage**:
Checking open filed findings against the current default branch and settling
each: closed as completed when the code it names has since been fixed,
otherwise to `ready-for-agent`, `ready-for-human`, or `wontfix`, with its
category kept or flipped - or, in a re-check, a finding already triaged left
as labelled. A finding whose fix needs a decision goes to a human, never to an
agent. The findings are checked at the default SHA and put to the human one
batch per source PR. It takes the findings still in `needs-triage`, or, as a
**re-check**, the open filed findings whatever their triage label. Not the
driver's triage, which ranks one iteration's findings inside a review loop.

**Re-check**:
A finding triage that also takes open filed findings already out of
`needs-triage` - every one, one source PR's, or one issue. One still in
`needs-triage` is triaged as usual; one already triaged is closed as completed
when it no longer holds, and otherwise left as labelled unless the human names
another outcome.

**Default SHA**:
The default branch's remote tip at the moment a finding triage starts: the
commit every finding in that triage is checked at, and the one its comments
cite. Not a base SHA, which is a base branch's tip at the moment a flow or
quick implementation branched, or at its latest base sync.

**Source PR**:
The PR whose review loop filed a finding, named on the filed finding's
`**PR:**` line.

**Category**:
A filed finding's `bug` or `enhancement` label. The closer sets it from the
finding's axis - `bug` for Spec, `enhancement` for Standards - and finding
triage keeps or flips it: a Standards finding that is a real defect becomes
`bug`, a Spec finding that is a nice-to-have becomes `enhancement`.

**Root-cause fix**:
A fix that removes a defect's cause everywhere that cause acts - every copy of the logic, every call site, every input it mishandles - rather than only the reported instance. Its opposite, a **symptom fix**, makes the reported case pass while the cause stays live elsewhere.
_Avoid_: foundational fix, proper fix

### Hosts

**Host**:
The agent CLI that has the plugin installed and runs its skills - Claude Code,
Junie, and so on. "Junie" always means the Junie CLI, not the Junie plugin
for JetBrains IDEs. Claude Code is the reference host; every other host is
supported to the extent it can do what the plugin asks, and anything it
cannot do is reported rather than silently skipped.

**Capability**:
Something a skill needs its host to do - invoke a skill, start a fresh
subagent, start a fresh session - named for what it does rather than for any
host's tool. `docs/host-capabilities.md` says how each host provides each one.

**Host fallback**:
What a skill does instead when its host lacks a capability, or cannot use it
for the step at hand (a Junie CLI capability filter hiding one of the
plugin's agents, say), as documented in
`docs/host-capabilities.md`. Every fallback a phase takes is recorded under
**Host fallbacks** in its handoff; a quick implementation records its
fallbacks, including any taken during its spec review, under its PR body's
**Host fallbacks**; and a standalone review pass records them in its PR
comment, or reports them in the session when the branch has no PR - so a
reduced run is never mistaken for a full one.
