---
name: orch-interview
description: Plan a change with the user before any code is written - an interview in rounds that settles every decision and sharpens the project's domain language, ending in a plan the orchestrator can carry to a flow, a quick implementation, or a blueprint. Use when the user asks to plan a feature or change with the orchestrator ("plan this", "let's plan"), or runs /orchestrator:interview. Not for stress-testing an idea for its own sake.
---

# Orchestrator plan

Adapted from the `grilling` and `domain-modeling` skills in `mattpocock-skills`
1.2.3.

This skill is the interview's discipline and its closing. The planning
session's state-dependent rules - what you may edit while planning, this repo's
triage label strings, and any flow running beside this session - arrive in the
planning hook's message when this skill starts. The rules for closing the
interview are the **Closing** section below.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths. If it prints nothing, `ORCH` is
`scripts/orch.sh` two directories above this skill's own directory (the plugin
root).

If `orch.sh` is at none of these paths, this is a skills-only install: stop, and
tell the human `orch.sh` is missing and to install the full orchestrator
plugin (`/plugin install orchestrator@orchestrator` on Claude Code, or
`maj0rpain/orchestrator` as a Junie extension, which is unverified).

Steps here name capabilities (ask the user a question, start a fresh
subagent). `docs/host-capabilities.md` under the plugin root maps each one to
your host. Where your host's cell says **Fallback**, or **Unverified** and the
capability turns out missing, take the fallback it documents and tell your
caller which.

## The interview

Interview the user until you reach a shared understanding. Map the plan as a
**design tree**: every decision branches into the decisions that hang off it.

Work the tree in **rounds**. The **frontier** is every decision whose
prerequisites are already settled: the questions you can ask now without
guessing at answers you have not heard yet. Ask the whole frontier in one
round, numbering each question and giving your recommended answer to each.
Then wait for the user's answers before the next round.

Two rules hold for every question in a round:

- **Define each new term.** The first time a question uses a term the user
  has not yet met in this interview - neither used by them nor defined in an
  earlier question - give it a one-line definition inline, in parentheses
  after it. This covers a config key, a glossary term, or a name you
  invented for the plan.
- **Give the reason for each recommendation.** Every **Recommended** line
  carries its reason in one clause, after "because".

Format a round like so:

```
**Q1 - <question title>**: <question body, possibly several paragraphs, possibly with choices; a term the user has not yet met appears as <term> (<one-line definition>)>

Recommended: <your recommended answer>, because <reason>

---

**Q2 - <question title>**: <question body>

Recommended: <your recommended answer>, because <reason>
```

A worked example round:

```
**Q1 - Timestamp zone**: Should the export write its timestamps in UTC or in the user's local zone?

Recommended: UTC, because exports are compared across machines in different zones.

---

**Q2 - Timestamp format key**: Where should `HWM_FORMAT` (the config key that sets how the last exported row's timestamp is written) live: in the export's config file, or as a flag on each run?

Recommended: In the config file, because every run of one export must read that timestamp the same way.
```

Each round's answers reshape the tree: settled decisions push the frontier
outward and unblock the questions that depended on them. Recompute the
frontier and ask the next round. A question whose answer depends on another
question still open in this round belongs to a later round, not this one.

Finding facts is your job, never the user's. When a frontier question needs a
fact from the environment - the code, the issue tracker, a tool's behaviour -
find it yourself, or start a subagent to find it; never ask the user for
anything you could look up. Do not block on it: a running exploration is an
unsettled prerequisite, so only the questions downstream of it wait; ask the
rest of the frontier now. The decisions are the user's: put each to them, and
wait.

When the plan fixes a bug, its **root cause** and every site that cause acts
at - each copy of the logic, each caller, each input it mishandles - are a
decision on the design tree, put to the user like any other and settled
before closing. Find the cause and its sites yourself; the user settles which
cause the fix removes, and how. The spec records them in its **Root cause**
subsection, and the fix removes the cause at every site listed: a
**root-cause fix**, not a symptom fix.

The interview is done when the frontier is empty: every branch of the design
tree visited, nothing left silently assumed. Do not act on the plan until the
user confirms you have reached a shared understanding; then close as the
**Closing** section says.

## Domain language

When the interview is about an issue, read it as soon as it is named - before
the first round when the arguments name it, else before the next round once
the conversation names it: `bash "$ORCH" issue fetch <n> <file>` writes its
body as plain multi-line text, and `bash "$ORCH" issue comments <n> <file>` its
comments, each into its own `mktemp` file outside the repo. Open both files
with the Read tool, never `cat`, so a large issue is read once, in full; an
empty comments file means no comments. Never read it with `gh issue view`. If
either fetch fails, report its `orch:` message and stop before the next round.

Sharpen the project's domain model as you plan. Before the first round, list
the glossary's term names with `bash "$ORCH" glossary terms`, and fetch the
entries for the terms in play with `bash "$ORCH" glossary show <term>...` -
again on any round that brings a further term in. A failed glossary command is
reported with its `orch:` message, and the step carries on without glossary
entries, never reading `GLOSSARY.md` whole in their place. With a
`GLOSSARY-MAP.md` at the root, read each glossary the map points to instead.
Read the ADRs under `docs/adr/` before the first round too, then keep these
habits on every round:

- **Challenge against the glossary.** When the user uses a term that conflicts
  with the glossary, call it out at once: "The glossary defines 'cancellation'
  as X, but you seem to mean Y. Which is it?"
- **Sharpen fuzzy language.** When a term is vague or overloaded, propose one
  precise canonical term: "By 'account', do you mean the Customer or the
  User? Those are different things."
- **Discuss concrete scenarios.** When relationships between concepts are in
  play, stress-test them with specific scenarios, invented to probe the edge
  cases and force the boundaries between concepts to be precise.
- **Cross-reference the code.** When the user states how something works,
  check whether the code agrees, and surface a contradiction: "The code
  cancels whole Orders, but you just said partial cancellation is possible.
  Which is right?"
- **Name the docs the plan will make stale.** When the plan changes or
  removes something a doc describes, name each such doc by document and
  section (the README's Install section), so the spec lists it under
  **Docs to update**.
- **Offer an ADR sparingly.** Only when all three hold: the decision is
  **hard to reverse** (changing your mind later costs something real), it is
  **surprising without context** (a future reader would ask why), and it is
  **the result of a real trade-off** (there were genuine alternatives, and one
  was picked for specific reasons). Missing any one, skip the ADR.

## Unattended interview

The interview with no human in it, taken only by a quick autopilot's
planner subagent, which reads this section and **The interview** and **Domain
language** above from this file, never loading the
skill through the Skill tool, and never starts the **Closing**: no route
question, no interviewed-issue question, no done-close. The attended interview
is unchanged. Everything in **The interview** and **Domain language** holds -
the design tree, rounds, fact-finding, the domain-language habits, the root
cause of a bug - with these differences only:

- **Every question takes its recommended answer.** Ask the human nothing and
  wait for no answer: each round is put as written, then every question in it
  takes its **Recommended** answer, and the next round's frontier is computed
  from those answers.
- **Each round is printed** as an unattended printout, with its questions and
  the answers taken: see **Unattended printout** in `docs/turn-final-reply.md`
  under the plugin root. It is not a turn-final reply, and the interview goes on
  in the same turn.
- **Each question and the answer taken is recorded**, to go under the plan's
  `## Decisions`.
- **An issue found already done is reported as skipped**, naming the commit, PR
  or issue that did the work, and the interview stops there: it closes nothing,
  moves no label and writes nothing.
- **There is no planning close.** The interview is done when the frontier is
  empty; there is no confirmation of a shared understanding to wait for.

## Glossary and ADR wording goes into the plan

A term the interview resolves, or an ADR it decides to record, is written into
the plan, never into `GLOSSARY.md`, `GLOSSARY-MAP.md`, or `docs/adr/` now. Those
files are records, and a record changes only with the change it describes
(ADR-0022). Write the exact wording - the new or replaced text, and which file
and entry it goes in - into the plan, so the spec or the linked issue carries
it verbatim and it lands with the implementation.

The glossary stays a glossary: an entry defines a term, free of
implementation detail. Implementation decisions belong in the plan, not in a
glossary entry.

## Closing

These are the closing rules of every planning session. The planning hook's
message supplies what depends on the session: this repo's triage label strings
for the roles named below (`ready-for-agent`, `wontfix`, `ready-for-human`), and
whether a flow is active beside this session. Use those label strings wherever
a step names a role. Every question below is asked as one blocking question to
the user. On Junie: the ask tool is `ask_user`, and a skill is run by reading
`"${CLAUDE_PLUGIN_ROOT}/skills/<name>/SKILL.md"` and following it verbatim,
since Junie has no Skill tool. If `CLAUDE_PLUGIN_ROOT` is unset, the plugin
root is found as for `ORCH`: two directories above the `orch.sh` that `ls`
printed, else two directories above this skill's own directory.

### Beside an active flow

When the hook's message names an active flow, decide at the close from this
planning session's conversation which of two cases applies. If the planning was
about that flow's own work, ask no route question and skip the interviewed-issue
step and the done-close: the next step is that flow's, so point the user to the
flow's next or redo (the hook's message names them for the host). Otherwise
run the interviewed-issue step and the done-close below unchanged, then the
route question unless the done-close applies.

### Interviewed issue

If the planning was about an open issue - named in the interview's arguments or
its conversation - that is the interviewed issue, and this step comes before
the route question. With no interviewed issue, skip this step entirely. When the
done-close below applies, it replaces this step: run no check and ask no label
question. Otherwise, before asking anything, run `bash "$ORCH" issue triage <n>
--check` - never a raw `gh` call - and follow what it prints:

- `ready`: ask no label question. Name #<n> as the interviewed issue in one
  sentence and go straight to the route question.
- `wontfix` or `ready-for-human`, a held label: ask one blocking question,
  naming that label: "#<n> carries `<label>`. Override it and move #<n> to
  `ready-for-agent`?", with the options "Override and move", "Skip", or "It's a
  different issue". On "Override and move", run `bash "$ORCH" issue triage <n>
  --override`. If that fails, report its `orch:` message, warn the user that
  `init --issue` will refuse #<n> until it carries `ready-for-agent`, and
  continue to the route question.
- `movable`: ask one blocking question, naming its number: "Move #<n> to
  `ready-for-agent`", "Skip", or "It's a different issue". On a move, run
  `bash "$ORCH" issue triage <n>`. If it exits 2, the issue carries `wontfix` or
  `ready-for-human` and it printed which: ask the user whether to override that
  label; on a yes, rerun it with `--override`; on a no, skip the relabel. On any
  other failure, warn the user that `init --issue` will refuse #<n> until it
  carries `ready-for-agent`, and continue to the route question.
- If the check itself fails, ask no label question: warn the user, relaying the
  check's `orch:` reason, that `init --issue` will refuse #<n> until it carries
  `ready-for-agent`, and continue to the route question.

On "Skip", go straight to the route question. On "It's a different issue", the
user names it: run the check on that issue instead and follow the same branches
for it.

### Done-close

If the planning settles that the interviewed issue's work is already done - a
commit, PR or issue already did it - skip the interviewed-issue step's move to
`ready-for-agent` and the route question. Instead ask one blocking question that
names the commit, PR or issue that did the work, with two options: "Close #<n>
as done (duplicate of #<m>)" when another issue, #<m>, did the work, else "Close
#<n> as done (completed)"; and "Leave #<n> open". On the close, write the
closing comment, naming what did the work, to a file outside the tracked tree
(`mktemp`), then run `bash "$ORCH" issue close <n> (--completed |
--duplicate-of <m>) --comment-file <file>` - never a raw `gh` call - and report
the outcome. If the close fails, report its `orch:` message and stop; the issue
stays open. On "Leave #<n> open", stop. A free-text answer that the work is not
done sends the interview back into rounds. With no interviewed issue and the
plan's work already done, ask no question: report what did the work and stop.

### Route question

Before you implement anything, and without editing any file first, ask the
user how to carry the plan out, with these route options:

1. Start the orchestrator flow - the full plan -> spec -> implement -> review
   pipeline, with its own handoff and review loop.
2. Quick implementation - hands-off, for small changes: implement this
   directly, with no further questions before the PR.
3. Blueprint only - write the spec (rewriting the interviewed issue, if there
   is one) and its ticket breakdown, then stop; implement later.
4. Autopilot flow - hands the plan to the autopilot watcher, which carries it
   through spec, implement and review unattended and asks the human only by
   comment on the issue.

On Junie: ask exactly three options, 1 to 3; there is no Autopilot flow.

Keep the route options in the order above unless you recommend one. To
recommend a route from the scope of the work (Quick implementation for a
one-site fix, say), list it first, append " (Recommended)" to its label, and
give that scope-based reason in one clause in its description, or in the
question text where options have no description. At most one route option
carries "(Recommended)", and a route option moved out of the order above always
carries it. Do not ask the user to type a command.

Run the chosen route yourself: on "Start the orchestrator flow", run the
orch-flow skill; on "Quick implementation", the orch-quick-implement skill; on
"Blueprint only", each step of the Blueprint route below as its skill; on
"Autopilot flow", the Autopilot route below. The orchestrator's skills are
model-invocable: call them, do not hand them to the user.

Side checkout. When the hook's message names no active flow, a request from the
human for a side checkout - a git worktree of its own, opened in its own
session - is honoured: run orch-flow or orch-quick-implement as asked for a side
checkout, which takes that skill's **Starting in a side checkout** section (on
Claude Code, pass args `--side`). When it names an active flow, "Blueprint only"
is the one route run in this checkout, whose branch belongs to the running flow:
"Start the orchestrator flow" and "Quick implementation" proceed only in a side
checkout, so run their skills only on that route (on Claude Code, with args
`--side`) - never in this checkout.

### Blueprint route

When the interviewed-issue step settled an interviewed issue - the one this
planning was about, or the one the user named under "It's a different issue" -
whatever happened to its label - moved, already ready, skipped, or the check
failed - write the spec in rewrite mode on that issue, replacing #<n>'s body
instead of publishing a new issue (orch-to-spec, handed #<n>). Only with no
interviewed issue, publish the spec as a new issue (orch-to-spec). Either way,
write any glossary or ADR wording the planning decided into the issue body
verbatim.

The route's steps run in this order, and one rule covers every step: when a
step stops or fails, stop there - run no later step, and report why it stopped.
orch-to-spec stops when it ends without reporting the issue number. Once it has
reported the number, ask the user how many spec review rounds to run on it, as
one blocking question, with the options 2, 1, 3, and Other for any other whole
number from 0 up, where 0 skips the review. 0 is the deliberate lower bound.
Recommend a count sized to the spec you just wrote: 1 for a one-site spec, 2 by
default, 3 for a large or cross-cutting spec (many acceptance criteria, several
modules, a new noun or ADR). List the recommended count first, append
" (Recommended)" to its label, and give that scope-based reason in one clause.
An Other that is not a whole number from 0 up is asked again, naming the range;
ask every time, never assume.

On a count of 1 or more, run the standalone orch-spec-review for that many
rounds (on Claude Code, args `<n> --rounds <count>`; on Junie, follow
orch-spec-review for issue #<n> with `--rounds <count>`). Then publish its
ticket breakdown (orch-to-tickets) against that issue, unless rewrite mode
reported the breakdown `kept`: then skip that step. Rewrite mode reports the
breakdown; run no breakdown check of your own. If orch-to-tickets fails after
rewrite mode retired a breakdown, the report also says that #<n> carries its
new body and no ticket breakdown, and needs `/orchestrator:to-tickets <n>`.
Then stop: do not implement or edit source. Report the issue number and how to
pick it up later: `/orchestrator:start --issue <n>`, or a quick implementation
that names the issue.

### Autopilot route

Claude Code only. The route ends in the plan handoff; this planning session
writes no flow state and makes no side checkout, so run neither `init` nor
`side-checkout add`.

First write the spec: run the orch-to-spec skill - in
rewrite mode, args set to the interviewed issue's number, when there is one,
else in publish mode - with its test-seams check. Then write the plan with the
`orch-handoff` skill's `01-plan.md` template, including its `## Autopilot`
block, to a file named `01-plan.md` in a fresh `mktemp -d` directory outside
the repo (`handoff validate` looks sections up by basename; this session runs
without `ORCH_AUTOPILOT`, so `autopilot start` is the check that covers the
`## Autopilot` block): Rounds sized by the spec phase's rule - 1 for a one-site
spec, 2 by default, 3 for a large or cross-cutting spec - and Budget, the
review loop's iteration budget, sized by the review loop's rule from the scope
the interview settled - 3 for one site and one ticket, 5 for a few files and
2-3 tickets, 8 for many modules, 4+ tickets, or the review loop's or flow
state's own machinery, risk weighing above size. Last run `bash "$ORCH"
autopilot start <issue> <plan-file>`, <issue> being the spec's issue number.
When a step stops or fails, stop there and report why; the route ends in
`autopilot start`. Then report that the watcher picks the issue up.
