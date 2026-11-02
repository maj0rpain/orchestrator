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
a quick implementation. An autopilot flow is one whose phases a watcher starts.

**Flow state**:
What a checkout records about its flow, in `.orchestrator/state.json`: the
flow's slug, issue, base branch, branch, PR and phase, and the review
loop's counters. A checkout holds at most one. A flow whose state is at
phase `done` no longer counts as active. In an autopilot flow the phase label on
the issue, not the recorded phase, is the source of truth; the recorded phase is
the phase this checkout last moved to.

**Checkout**:
A working tree of the repo: the main checkout (the clone itself), a side
checkout, a ticket worktree, or a hand-made worktree (one the human made
with `git worktree add`). Each holds at most one flow.
_Avoid_: worktree, when the main checkout is meant too.

**Busy checkout**:
A checkout that holds work a new branch must not move: a flow
mid-pipeline, a branch the plugin made that has no PR yet, or a working
tree with changes outside the planning allowlist. A quick implementation
started in a busy checkout goes to a side checkout; a flow started in one
is offered a side checkout, except on a dirty tree, which `init` refuses.
_Avoid_: locked checkout, active checkout.

**Plugin-made branch**:
A branch the plugin made and records as its own: a flow's branch, a quick
implementation's branch, or a ticket branch. Any other branch is foreign: no
command syncs it, reclaims onto it, or discards work on it.
_Avoid_: owned branch.

**Side checkout**:
A git worktree the plugin makes inside the repo, so a second flow or a quick
implementation can run beside the work already in this checkout, in a session
of its own. Made when a quick implementation starts in a busy checkout, offered
when a flow does, or made when a human asks for one. It counts as a checkout in
its own right, so it holds at most one flow. One made for a quick implementation
records that implementation's issue, so a session opened in it picks the issue
up without being told. It is removed when its flow is archived with `archive` or
`/orchestrator:abort`, by `/orchestrator:finish` once its work is finished, or
by hand, and never with force. An autopilot flow gets one on its issue's first
pickup, recording that issue as a quick implementation's does, and every later
phase reuses it. _Avoid_: sibling worktree, flow worktree, second checkout.

**Finished**:
A side checkout is finished when a pull request from its branch has merged into
its base branch, every commit on its branch is held by one of its merged pull
requests, its working tree is clean, and it holds no flow or a flow at `done`.
A flow is finished when it is at `done` and its pull request has merged.
`/orchestrator:finish` cleans up only finished work.

**Phase**:
One of the four stages a flow passes through: **plan**, **spec**, **implement**,
**review**. Each phase runs in its own session with no memory of the previous
one - with one deliberate exception: a review loop drives all of its iterations
from a single session (ADR-0001), so inside the review phase the unit of fresh
context is the loop, not the iteration. The loop is the unit of fresh context
for its driver; the reviewers and the fixer get fresh context every iteration.
A flow's spec review is a step of the spec phase, not a phase of its own.
Unlike the review phase, the spec phase spans several sessions: when it writes
the spec, the session that publishes or rewrites the issue stops there; each
spec review round but the last stops after its changelog; and the last round,
the ticket breakdown and the handoff run in one more, all still in the spec
phase. In an autopilot flow each phase still runs in its own session, started by
the watcher instead of the human. An autopilot flow's spec is written in the
planning session, or for a hand-labelled issue is its body as it stands, so its
spec phase starts at the spec review.

Note the tense: the recorded phase names the stage that runs **next**, not the
one that just finished.

A flow leaves a phase only once the handoff it writes for the next one is
valid; the step back of a Redo retires the handoffs it makes stale.

**Handoff**:
The written record one phase leaves for the next, and the only thing that
crosses a phase boundary. A handoff references artefacts that already exist (an
issue, a PR, a diff) and states what exists nowhere else: reasoning, rejected
options, deviations. In an autopilot flow each handoff is one tagged comment on
the issue, its only copy.

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
triage label; the spec phase then rewrites its body from the plan when the
plan changed its scope or substance, by `orch-to-spec`'s rewrite mode, and
runs the spec review against it.
_Avoid_: existing issue, pre-existing issue, given issue.

**Interviewed issue**:
An open issue a planning session was run about, or the open issue the human
names in its place when the session closes. When the human confirms the plan,
the session offers to move it to the `ready-for-agent` triage label, since the
interview settled what triage would have, and asks nothing when it already
carries it - unless the plan finds its work already done, when the session
offers to close it as done instead. A blueprint drawn from that session rewrites
this issue as its spec issue rather than publishing a new one; a quick
implementation started from it may rewrite it from the plan, as **Quick
implementation** says. _Avoid_: planned issue, subject issue.

### Autopilot flow

**Autopilot flow**:
A flow whose phases are started by a watcher rather than a human. Its phase is
recorded as a label on its issue, its handoffs are issue comments, and its
questions reach the human as issue comments. It stops for the human only on a
fundamental item, a bounded stop (a spec question the review loop meets among
them), a refusal (an untrusted issue among them), or a failure; a session cut
off by a usage limit is waited out instead, as a limited issue, short of the
third such stop in a row of one phase.
_Avoid_: auto flow, headless flow.

**Watcher**:
The process that starts each autopilot flow's next phase, in that flow's side
checkout, within the repo's cap.

**Claim**:
A watcher's exclusive hold on one issue's next phase - a ref on origin that only
one watcher can create. _Avoid_: lock (unqualified).

**Phase label**:
The `orch:` label on an issue that records an autopilot flow's phase.

**Standing**:
Where an autopilot flow's issue stands: its phase label, whether a session is
running on it, whether it waits on the human or on a usage limit, and the claim
held on it, if any. Every change to it is one of a fixed set of transitions.
_Avoid_: protocol state, issue status.

**Fundamental item**:
A material spec review item whose edit would change what the human decided in
planning - reversing or changing a decision the plan recorded, reviving a
rejected alternative, or adding or dropping scope beyond the plan. In an
autopilot flow's spec review it is the only kind of item that reaches the human.

**Save point**:
What a phase writes to its checkout so that a fresh session - started after the
human answers its question, or after the phase died partway - resumes from it,
never redoing or repeating what already landed and never re-exploring code.

**Discard rule**:
What a restarted phase does with uncommitted or in-progress work a dead session
left: discarded in a ticket worktree always, and on the flow's own branch - or
a quick implementation's own branch - in every checkout except an interactive
flow's main checkout, where it is refused with the discard command named.

**Hand-labelled issue**:
An issue a human gave a phase label by hand, without the planning close's
autopilot route. Its plan comment is the minimal one, and its body is reviewed
as it stands.

**Plan comment**:
The issue comment tagged `<!-- orch:handoff 01-plan -->` that holds an autopilot
flow's plan handoff.

**Marked comment**:
An issue comment whose first line names its kind to orch.sh: a hidden
`<!-- orch:<kind> <arg> -->` marker (question, limit stop, handoff, refusal,
failure), or a visible opening the human reads too (the spec review's
`## Spec review` heading, a `Spec ruling:` line). Question comment, Plan comment
and the rest are kinds of marked comment. Only a trusted comment can be one. A
PR comment's `Spec ruling:` line, read by the review pass, is not a marked
comment; the trust filter drops an untrusted PR comment before the review pass
reads its rulings all the same.

**Trusted comment**:
An issue or PR comment whose author is the repo's owner, a member of its
organisation, or a collaborator on it. orch.sh reads only trusted comments;
any other comment is dropped before any marked comment, answer or spec text
is read from it.
_Avoid_: verified comment.

**Trusted issue**:
An issue whose author has a role on the repo (as for a trusted comment), or
whose body and title were each last written by someone other than its
author; a title never renamed follows the body, a renamed one its newest
renamer. An autopilot flow runs only on a trusted issue.

**Issue timeline**:
An autopilot flow's issue's comment history, read once and asked in domain
terms: its newest question comment and whether a trusted comment follows it, its
latest stop, its limit stops in a row for a phase, and its live handoffs. Only
the timeline and the Marked comment module know how a comment's kind is marked.
_Avoid_: comment log.

**Question comment**:
The issue comment tagged `<!-- orch:question <phase> -->` that asks the human an
autopilot phase's numbered questions.

**Pending question**:
An autopilot flow's newest question comment that no
trusted comment follows yet, on an open issue labelled `needs-human`.
`/orchestrator:questions` puts each one to the human with its own recommendation
and posts the reply.

**Pickup rule**:
The rule a watcher picks issues by: open, a phase label other than `orch:done`,
and neither `orch:running` nor `needs-human`, while no limit pause holds.

**Pickup**:
A watcher taking one claimed issue to a running session: its issue-trust
check, its side checkout, its flow, its plan comment, a redo when the label
stepped back one phase, then `orch:running` and the session. A failed or refused
step stops the issue and releases the claim.

**Limited issue**:
An autopilot flow's issue whose last session stopped on a Claude Code usage
limit, labelled `orch:limited` in place of `needs-human`. A tick once the limit
pause has passed picks its phase up again; a third such stop in a row of one
phase waits on the human. _Avoid_: rate-limited issue.

**Limit pause**:
The stretch in which a clone's watcher picks up no issue: from a session
stopping on a usage limit, or ending with its five-hour usage at 90% or more,
until the latest usage reset any of them named - or, for a stop that named
none, an hour after it. Running sessions are left alone.

**Cap**:
The most autopilot sessions a repo runs at once, counted as the claim refs on
origin. It is soft: watchers acting in the same instant can overshoot it.

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
`health` command or `orch.sh doctor`, to check that the machine, the repo, and
the active flow are sound. Organized into named scopes - `--env`, `--flow` -
with bare `doctor` covering everything. Every check it runs reports through one
of three states - `ok`, `warn`, or `FAIL` - and the overall report reflects the
worst state seen without aborting partway through.

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

**Agent setting**:
The model and reasoning effort a role's agents run with: each chosen per role
and per host by the user, or else inherited from the session that starts them.
Each host has its own setting, since hosts name models and efforts differently.
A role is one of six groups of the plugin's agents that share a setting:
implementer, lens, reviewer, fixer, closer and resolver.

**Agent copy**:
A project-scope copy of one of the plugin's agents that `orch.sh agent sync`
writes into a checkout's `.junie/agents/`, its frontmatter carrying that role's
Junie agent setting and a marker line saying sync owns it. Never committed; sync
writes over or deletes only a file that carries the marker.

### Quick implementation and blueprint

**Quick implementation**:
The other route from an approved plan to a pull request, alongside a flow.
Chosen once, by a human, at the close of a planning session - never assumed by
the model. Skips the plan/spec/implement/review pipeline entirely: no phases,
no handoff, no `.orchestrator/state.json`. Still produces its own branch and
PR, and is still held to this project's standards for how a change gets made -
test-driven, reviewed, then opened as a PR. Its review is a review pass, and
it names what it declines in the PR. A spec question its review pass meets
opens the PR as a draft, naming the question, rather than being settled
unattended. Meant for small changes, run hands-off:
it takes an unattended spec review of its linked issue before its ticket
breakdown, on every run. Before that review, it rewrites the linked issue from
the plan when the issue is the interviewed issue of the planning session in
the same conversation and the plan changed its scope or substance, judged
without asking; otherwise it reviews the issue as it stands. It accepts its
own draft breakdown without asking. It skips that breakdown when the linked
issue is a blueprint, including when its spec review retired the blueprint's
breakdown and broke the issue down again, but not when its rewrite retired
that breakdown.

**Blueprint**:
Everything a change needs before implementation, carried no further: its spec
issue - published new, or the interviewed issue rewritten, its earlier breakdown
retired and broken down again if the human chooses - reviewed if the human chose
to, and its ticket breakdown. Chosen once, by a human, at the close of a
planning session, as the alternative to starting a flow or a quick
implementation. A flow later adopts it, or a quick implementation links it;
either way its ticket breakdown is already published and is not run again,
unless a spec review changes the spec and retires that breakdown - by the
human's choice, or by its own recommendation in an unattended spec review - or a
flow's spec phase, finding the plan changed it, rewrites it from the plan and
the human has that rewrite retire that breakdown, or a quick implementation's
rewrite from the plan retires it. _Avoid_: planning-only, parked spec, banked
spec.

**Unattended rewrite**:
`orch-to-spec`'s rewrite mode asking the human nothing, taken only by a quick
implementation.

**Blocking edge**:
A native GitHub dependency recording that one ticket of a breakdown cannot
start until another, its blocker, is closed. `ticket next` reads only
these, never a ticket body's `## Blocked by` text.

**Ticket breakdown**:
The set of sub-issues published against a spec issue (a flow's, a quick
implementation's linked issue, or a blueprint's) - each one a sub-issue of that
parent, not a second issue the flow or quick implementation now holds, and
may block, or be blocked by, other tickets in the same breakdown. When the
approved breakdown - in a quick implementation, the drafted one - resolves to 0
or 1 tickets, no sub-issue is published at all: the drafted ticket's content, if
there is one, is folded into the parent issue's own body instead, and the parent
is worked as if it were the sole ticket, built in its own ticket worktree,
`t<parent>`, and never closed by the build - a breakdown of one, collapsed
onto its own parent rather than split out beneath it.

**Ticket subagent**:
The fresh, non-fork agent that builds exactly one
ticket of a ticket breakdown, test-first, and checks its own work against
that ticket's acceptance criteria, and that a test exercises every source
file it changed, before reporting. It never reviews its work beyond those
checks: review belongs to the review loop, or to a review pass. It reports
back structurally instead of blocking on a human; a criterion it cannot meet
alone is reported as unmet, and a changed source file no test exercises is
reported as untested, both for the review loop's Spec axis to judge. Used
in the implement phase and in quick implementation. It always builds on
a ticket branch in its own ticket worktree, whether its frontier is built
in parallel or one ticket at a time. When its ticket branch conflicts as
it is merged, it is resumed to resolve the conflict itself, since it knows
its ticket's intent.

**Ticket branch**:
The branch one ticket subagent builds a single ticket on, forked from its
flow's or quick implementation's branch at the tip, and merged back into it
before the ticket closes - or, for a collapsed breakdown, with no ticket
closed. It is local and short-lived, gone once merged, and
is not the flow's one branch.

**Ticket worktree**:
The git worktree a ticket branch is checked out in - every ticket subagent
builds in one, so tickets of one breakdown can build at the same time without
sharing a working tree, and a ticket's landing is its branch merging.

**Frontier**:
The open tickets of a ticket breakdown with no open blocker - what `ticket
next` prints. Several can be built at once, up to the clone's parallel cap.

**Driver loop**:
The procedure that builds a ticket breakdown, one frontier
after another: one ticket subagent per ticket, in parallel up to the clone's
parallel cap or one at a time, each ticket's report saved as it returns,
then the ticket merged and closed - a collapsed breakdown's merged, never
closed - then one verification of the combined branch. The implement phase
and a quick implementation both run it.

### Spec review

**Spec review**:
One review of a spec issue, in one or more rounds. Usually a step of a flow's
spec phase, after the issue exists - published by the spec phase or already
adopted at init - and before its handoff is written. A human may also ask for
one on demand, against any issue, and a quick implementation takes an unattended
one before its ticket breakdown: either way a standalone spec review, which
belongs to no flow and leaves no handoff. An autopilot flow's is also
unattended, but in the flow, one per round for its planned round count. It first
proposes folding into the body anything the issue's comments say that the body
does not - a triage agent brief, a follow-up - so the body stays the one place
the spec is written. Its lenses then read the spec, body and comments,
independently - four in a flow, three in a standalone review; every finding they
report, and every consolidation item, is put to a human with a proposed edit,
and only the edits the human accepts change the spec - in an unattended spec
review, the recommended ones. When the issue already has a ticket breakdown and
the accepted edits touch an open ticket, it then raises the ticket question -
how that breakdown should follow - which a human answers, and an unattended spec
review answers with its own recommendation: edits to the tickets the change
touches, or retiring the breakdown so the issue is broken down again. A spec
review runs its whole round count, each round reading the body the previous one
published. It is not a loop - no severity, nothing filed - and a review started
after it ends is a new spec review, with its own round count.

**Round**:
One look within a spec review: consolidation, the lenses, one batch of proposed
edits put to the human, the accepted edits applied, the ticket question when
they touch an open ticket, and one changelog comment. Each round reads the body
as the previous round published it. A round's lenses read the rulings of the
earlier rounds of the same review, and reopen one only on evidence it did not
have. _Avoid_: pass, iteration (the review loop's).

**Round count**:
The number of rounds a spec review runs. A flow's spec phase asks the human for
it when the review starts, and a blueprint asks it in the planning hook's
closing message, before the review; both recommend a count sized to the spec - 2
by default, fewer for a one-site spec, more for a large one - and a blueprint
may answer 0 to skip the review. A spec review run on demand runs 1 unless given
another. A spec review runs its whole round count: a round that finds nothing
does not end it early. An autopilot flow's is chosen once, at the planning
close, and recorded in its plan. _Avoid_: budget (the review loop's).

**Round marker**:
The file in a flow's handoff folder naming the flow's issue, a spec review round
and the round count, written by `orch.sh`, from which `orch.sh spec round` tells
a fresh session the round to resume the review at. It is not a handoff, and it
is never in `state.json`.

**Unattended spec review**:
A spec review that asks the human nothing: every recommended edit
is applied, every decision item takes its recommended option, and a ticket
breakdown the edits touch follows its recommended option, retiring included.
The batch is still shown and the changelog still records it all. A quick
implementation takes one, standalone, of one round; an autopilot flow's spec
review is one, in the flow, per round for its planned round count, except that a
fundamental item reaches the human. _Avoid_: auto spec review, silent spec
review.

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

**Material item**:
A spec review item whose edit changes what gets built or how it is proven -
behaviour, scope, an interface, an acceptance criterion or a test seam. Every
decision item and every item recording that the spec contradicts the plan is
material, and so is a recommend-decline whose edit would be. The batch shows its
summary and its reason on one line, and for a decision item its reason, then
each option's summary on a line of its own; its full text, with the findings or
comments it cites, is shown on request. _Avoid_: high-severity item, important
edit.

**Minor item**:
A spec review item that is not material - wording, clarification, naming,
internal consistency, a cross-reference. The batch lists it in one line, and the
human's answer takes its recommendation unless they name it. _Avoid_: nit (the
review loop's), trivial edit.

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
in the spec phase, recorded in the spec, and that agreement is
the only one: the implement phase tests at the seams the spec gives and does not
re-ask. A seam the code turns out not to allow is a deviation, recorded like
any other. In an autopilot flow they are agreed in the planning session, which
writes the spec; a hand-labelled issue's are the ones its body states, accepted
by the human who labelled it.

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
reason. A spec question it meets is neither fixed nor declined but put to a
human: in the session by a standalone review pass, whose rulings are recorded
on the spec issue, or, in a quick implementation, by opening the PR as a draft
that names it. A standalone review pass marks ready a PR held in draft for spec
questions once every one is ruled. A quick implementation takes one before its
PR opens. A human may also ask for one on demand, against an issue and the
branch they are on - after a quick implementation, say - which is a standalone
review pass. A standalone review pass leaves out the Standards reviewer's
smell-baseline findings unless the human asks for them, and reports only how
many it left out; a quick implementation's review pass keeps them. Another look
is another review pass. A standalone review pass drops any finding an earlier
review pass on the same PR already declined, and lists it as previously
declined. A branch or issue an active flow holds belongs to that flow, never to
a review pass. Its reviewers are told the pass's known items, and drop the
findings those already carry. _Avoid_: single pass, quick review

**Budget**:
The number of iterations a review loop runs, chosen by a human when the loop
starts, from a number the driver suggests: for a flow's first loop, from the
size of the change; for a further loop, from what the loop before it left. A
loop runs its whole budget: finding nothing does not end it early, because
every iteration is an independent look at the same change, and the value of
the loop is in the number of looks. An autopilot flow's first loop runs the
budget chosen at the planning close; each loop after a bounded stop runs one
the driver chooses from what the loop before it left, never more than that
first budget, unless the human's reply names one.
A loop that resumes a pending or interrupted iteration asks for and picks no
budget: it keeps the one already recorded.

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
one - and no **missing look**, and files no spec question, with CI green or
absent. Anything else is a bounded stop.

**Driver**:
The session that runs a driver loop or a review loop, starting
the fresh agents that do the work and keeping the run's record. A review
loop's driver syncs the branch with its base, starts the reviewers,
the fixer, the closer and, on a conflict, a resolver, triages what the
reviewers report, waits on CI, and decides the terminal state. It does not
edit the change: every line the loop fixes is the fixer's, and filing is
the closer's. In a clean iteration whose base sync resolved a conflict,
it corrects the PR body itself (**Checking the PR body** in the fixer's
brief): the body is what the PR claims, not the change. The one exception
is a host with no fresh subagent: there the review loop's driver takes the
host-capabilities **Start a fresh subagent** fallback, does the fixer's
and the closer's work in its own session, and records that as a host
fallback. A driver loop's driver starts one ticket subagent per ticket
and saves each ticket's report as it returns, then merges and closes the
ticket - a collapsed breakdown's merged, never closed.

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
finding its fixer could not fix, lacked one of its two looks, or filed a spec
question, or because CI could not be called green. A stop is not a failed change
and not a successful one.

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
fixes it, declines it, or, when it is a spec question, puts it to a human,
unless a standalone review pass left it out as a
smell-baseline finding. A finding about the spec carries no severity: the spec
review's session marks the item proposing its edit material or minor, a human
accepts or declines that edit, or an unattended spec review applies it as
recommended, and it is never filed.

**Pattern finding**:
A finding whose claim holds at more than one place - one cause or one breached
rule recurring across sites. It lists every site, and its fix reaches or defers
each one.
_Avoid_: recurring finding

**Severity**:
Which of three roles a finding plays - how wrong the change is, and so which
findings the loop may fix without asking anyone:

- **Blocking** - the change is wrong: incorrect behaviour, a spec requirement
  missing or misimplemented, a security problem, a broken or missing test, or a
  failing verification command. Always fixed, in every iteration - or,
  when the fixer cannot, left open, holding the change out of ready.
- **Major** - the change works but carries real cost: a documented standard
  breached, a smell with teeth, scope nobody asked for. Fixed by the loop
  unless the fix needs a decision or would touch the loop's own fixes; filed
  otherwise. A major that is a spec question is filed and holds the PR out of
  ready.
- **Nit** - taste and judgement calls. Fixed by the loop only when it is a
  mechanical nit; filed otherwise.

A final iteration fixes only what is blocking: a major or nit found there is
filed, so a working change is never held in draft by a style finding - though a
spec question found there still holds it.

**Mechanical nit**:
A nit with exactly one correct fix, confined to the lines it names, changing
no behaviour and leaving no wording or taste to choose - a typo, an unused
import, a comment naming the wrong function, a broken link. Rewording prose is
never mechanical, however small.

**Spec question**:
A finding whose fix needs a decision about what the change does that the spec,
plan and deviations leave unsettled - silent, ambiguous, or self-contradictory
on it. A finding that the change contradicts what the spec clearly asks for is
blocking in a review loop, and fixed in a review pass, not a spec question; a
decision about structure only - which of two refactorings, which name - is not
one either. In a review loop only a major can be one; a review pass judges it by
content alone, with no severity. A spec question a review loop files holds the
PR out of ready, so a human rules on it before the PR is marked ready; one a
later loop meets again does not. One a review pass meets is neither fixed nor
declined: a standalone review pass puts it to the human, and one left unruled -
or met in a quick implementation - holds the PR in draft.

**Filed finding**:
A major or nit the loop did not fix, turned into an issue when a loop
terminates - because its fix needed a decision, was a spec question,
was not mechanical, landed on loop-authored lines, was found in a final
iteration, or the fixer could not fix it. It carries the reviewer's finding
and the loop's reasoning about it, including which of those kept it out of the
loop, deduplicated across a loop's iterations by the closer and across a
flow's loops by the driver's triage. Its **Filed** entry names its file and
line, so a later loop's triage matches a finding it meets again on file, line,
and claim. A filed finding enters **finding triage** against the whole codebase
rather than against one diff: a later loop that meets it again leaves it alone,
and tells the human it did.
A filed finding that is a spec question also holds the PR out of ready until a
human re-enters review. Findings the loop demoted on a human's earlier decision
are reported, never filed.

**Known item**:
Something a review has already dealt with - a finding waiting to be filed or
filed by a review loop, a road a rejected alternative closed, a deviation, a
finding declined by a review pass, or a question a spec ruling answered - that a
reviewer is told about so it does not raise it again. A reviewer raises a known
item again only when its location or cause has changed, and the Spec reviewer
reports a deviation no commit carries out. _Avoid_: known issue, duplicate

**Finding triage**:
Checking open filed findings against the current default branch and settling
each: closed as completed when the code it names has since been fixed,
otherwise to `ready-for-agent`, `ready-for-human`, or `wontfix`, with its
category kept or flipped - or, in a re-check, a finding already triaged left
as labelled. A finding whose fix needs a decision goes to a human, never to an
agent. The findings are checked at the default SHA and put to the human one
batch per source PR. It takes the findings still in `needs-triage`, or, as a
**re-check**, the open filed findings whatever their triage label. Not the
driver's triage, which ranks one iteration's findings inside a review loop. With
`--bundle`, it instead takes only the open findings already triaged to
`ready-for-agent` or `ready-for-human`, puts them to the human in one batch
across source PRs, and groups them by code area into bundles.

**Re-check**:
A finding triage that also takes open filed findings already out of
`needs-triage` - every one, one source PR's, or one issue. One still in
`needs-triage` is triaged as usual; one already triaged is closed as completed
when it no longer holds, and otherwise left as labelled unless the human names
another outcome.

**Bundle**:
One issue that carries several filed findings from one code area, so they are
worked on together. Its body restates each member - its claim, location at the
default SHA, and any options - so it reads alone. Each member is closed as a
duplicate of it. A bundle is not a filed finding: it carries no `review:` label,
and finding triage never takes it. _Avoid_: consolidated issue (a consolidation
item is a spec review's)

**Member**:
A filed finding carried by a bundle, closed as its duplicate.

**Default SHA**:
The default branch's remote tip at the moment a finding triage starts: the
commit every finding in that triage is checked at, and the one its comments
cite. Not a base SHA, which is a base branch's tip at the moment a flow or
quick implementation branched, or at its latest base sync.

**Source PR**:
The PR whose review loop filed a finding, named on the filed finding's
`**PR:**` line.

**Category**:
A filed finding's or a bundle's `bug` or `enhancement` label. The closer sets it
from the finding's axis - `bug` for Spec, `enhancement` for Standards and
Suite-cost - and finding triage keeps or flips it: a Standards finding that is
a real defect becomes `bug`, a Spec finding that is a nice-to-have becomes
`enhancement`. A bundle's is `bug` whenever any member's is.

**Root-cause fix**:
A fix that removes a defect's cause everywhere that cause acts - every copy of
the logic, every call site, every input it mishandles - rather than only the
reported instance. Its opposite, a **symptom fix**, makes the reported case pass
while the cause stays live elsewhere. _Avoid_: foundational fix, proper fix

**Suite cost**:
The CPU time, user plus system, that one passing run of a verification command
takes, as `orch.sh suite-cost run` records it with that command on the machine
that ran it, or `suite-cost check` records it for a base it had to measure or a
head and base it measured to confirm a growth. The baseline is the base commit's
own runs, never an earlier commit's, so a base with none is measured first. A
verdict `check` confirmed is stored and reused while the head, base commit,
command and threshold are unchanged, so an unchanged tree is not measured again.
A run made with uncommitted changes is recorded as dirty: it can measure the
head, never the base. Recorded only for a run no other suite-cost run
overlapped. Compared, lowest sample against lowest sample, only between runs of
the same command on the same machine, and a growth is confirmed by measuring
head and base once more before it counts; below the floor nothing compares it.
Growth past the threshold is a finding with no reviewer behind it: in a review
loop a major the driver raises from `check`'s verdict, and in a review pass a
finding the session handles like any other.

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

**Turn-final reply**:
One plain-text reply that ends a session's turn with no tool call in it,
holding a long block and then the question about it, its answer words spelled
out; the human's next message is the answer. It is never written beside a tool
call, since some hosts hide such text (ADR-0051). A block printed only so a
human watching can see it, asking nothing, is not one, and never ends the
turn.
