---
name: orch-interview
description: Plan a change with the user before any code is written - an interview in rounds that settles every decision and sharpens the project's domain language, ending in a plan the orchestrator can carry to a flow, a quick implementation, or a blueprint. Use when the user asks to plan a feature or change with the orchestrator ("plan this", "let's plan"), or runs /orchestrator:interview. Not for stress-testing an idea for its own sake.
---

# Orchestrator plan

Adapted from the `grilling` and `domain-modeling` skills in `mattpocock-skills`
1.2.3.

This skill is the interview's discipline and nothing more. The planning
session's rules - what you may edit while planning, and the question that
closes it - arrive in the planning hook's message when this skill starts.
Follow that message; it is the one source for both.

```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset, run `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh`
(the Junie CLI install). If it prints one path, `ORCH` is that path.
If it prints more than one, stop and show the human the paths.
If it prints nothing, `ORCH` is `scripts/orch.sh`
two directories above this skill's own directory (the plugin root).

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

**Q2 - Watermark format**: Where should `HWM_FORMAT` (the config key that sets how the high-water mark - the last exported row's timestamp - is written) live: in the export's config file, or as a flag on each run?

Recommended: In the config file, because every run of one export must read the mark the same way.
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

The interview is done when the frontier is empty: every branch of the design
tree visited, nothing left silently assumed. Do not act on the plan until the
user confirms you have reached a shared understanding; then close as the
planning hook's message says.

## Domain language

Sharpen the project's domain model as you plan. Read `CONTEXT.md` (or, with a
`CONTEXT-MAP.md` at the root, the context it points to for the area you are
touching) and the ADRs under `docs/adr/` before the first round, then keep
these habits on every round:

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
- **Offer an ADR sparingly.** Only when all three hold: the decision is
  **hard to reverse** (changing your mind later costs something real), it is
  **surprising without context** (a future reader would ask why), and it is
  **the result of a real trade-off** (there were genuine alternatives, and one
  was picked for specific reasons). Missing any one, skip the ADR.

## Glossary and ADR wording goes into the plan

A term the interview resolves, or an ADR it decides to record, is written into
the plan, never into `CONTEXT.md`, `CONTEXT-MAP.md`, or `docs/adr/` now. Those
files are records, and a record changes only with the change it describes
(ADR-0022). Write the exact wording - the new or replaced text, and which file
and entry it goes in - into the plan, so the spec or the linked issue carries
it verbatim and it lands with the implementation.

The glossary stays a glossary: an entry defines a term, free of
implementation detail. Implementation decisions belong in the plan, not in a
glossary entry.
