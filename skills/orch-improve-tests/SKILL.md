---
name: orch-improve-tests
description: Evaluate a repo's test suite and propose quality-preserving refactors ranked by the cost they save - scope by git hot spots or a named direction, measure each test file or section sequentially, hunt six kinds of candidate in a fresh subagent, rank them, show an HTML report, and hand the picked one to orch-interview. Read-only. Use when the user asks to shrink, speed up or evaluate a test suite, or runs /orchestrator:improve-tests.
---

# Orchestrator improve tests

Evaluates the repo's test suite and proposes refactors that make it cheaper
to run without making it test less, ranked by the **suite cost** (see
`GLOSSARY.md`) each one saves. It ships for any repo. The idea comes from
mattpocock's `improve-codebase-architecture`, as inspiration only: the six
steps below define this skill, and it invokes and depends on no upstream
skill (ADR-0028).

**Read-only.** This skill changes no file in the repo: it edits nothing,
commits nothing, and opens no branch, issue or PR. It only reads, runs the
test commands the repo's agent files document, and writes its report to the
temp directory, outside the repo. A candidate it proposes becomes its own
change only through step 6's hand-off.

**The quality rule.** Every candidate names its replacement - the cheaper
test, fixture or seam that takes its place, or the existing test that already
covers it - and says why that replacement tests the behaviour just as well:
through the public interface, with the same confidence. A replacement that
checks less, mocks what the repo controls, or reaches past the public
interface fails the rule. A candidate that fails it is dropped, at step 3 and
again at step 4, and never reaches the report. Cost only ranks candidates
that pass; it never justifies testing less.

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

Steps here name capabilities (start a fresh subagent, open a report in the
browser, invoke a skill from a step, ask a multiple-choice question).
`docs/host-capabilities.md` under the
plugin root maps each one to your host. Where your host's cell says
**Fallback**, or **Unverified** and the capability turns out missing, take
the fallback it documents and tell the user which.

## 1. Scope

Decide which tests to look at.

- **A named direction.** When the user names one - a directory, a test file,
  a feature, "the slow integration tests" - that is the scope.
- **Hot spots.** Otherwise, scope by recent hot spots in git history: the test
  files changed most often lately, and the test files covering the source
  files changed most often. For instance
  `git log --since=90.days --name-only --format= | sort | uniq -c | sort -rn |
  head -n 30`, kept to the test files and to the sources whose tests you can
  find.

Read the repo's agent files (`CLAUDE.md`, `AGENTS.md`) and contributor docs
for how its tests are laid out and run. Say the scope in one line before
measuring.

## 2. Measure

Time each test file or section in scope **once**, **sequentially**, one after
another, through the single-file command the repo's agent files document -
here, for instance, `ORCH_TEST_ONLY=<section> scripts/test/orch_test.sh`.
Never time parts in parallel: parts timed at once share the machine and every
number is wrong.

Time each run with bash's `time` builtin, which counts the children it waits
for: `TIMEFORMAT='%U %S %R'; time <command>` prints user, system and wall
seconds. A part's cost is its user plus system seconds. A part whose run
fails is reported as failed, with no cost.

When the repo's agent files document no single-file command, fall back to the
suite's whole-run cost only: time the full-suite command once, the same way,
and say that no part could be measured on its own.

Then run `bash "$ORCH" suite-cost history` and read the recorded runs of the
full verification command for the trend: whether the suite cost is growing,
and since which commit. No record means no trend; say so.

## 3. Hunt

Start a fresh subagent - never a fork - to hunt candidates. Its prompt holds
the scope, the measured cost of each part, the trend, the quality rule above
word for word, and the six kinds below. It reads the tests in scope and the
code they exercise, changes no file, and returns its candidates.

The six kinds of candidate:

- **Duplicated coverage**: a test re-asserts a behaviour an existing test
  already covers.
- **Expensive seam**: a test observes a behaviour at a costlier seam when a
  cheaper seam gives the same confidence through a public interface.
- **Per-test setup**: setup rebuilt for each test that a shared fixture could
  provide.
- **Waiting**: a sleep, wait or poll in a test.
- **Dead or implementation-coupled tests**: a test that can no longer fail,
  or one that breaks on a refactor that changes no behaviour.
- **Measured outliers**: a part whose measured cost is far above the others'
  for what it covers.

Each candidate it returns has: its kind; its location (file and test or
section); its measured cost, from step 2; its replacement; why the
replacement tests as well; and the cost it expects to save, in CPU seconds,
with how that figure was reached.

Read every candidate against the quality rule yourself and drop each one
that names no replacement, or no reason it tests as well, or whose reason
does not hold.

## 4. Rank

Rank the candidates that remain by measured cost saved, largest first. A
saving estimated from a part's measured cost ranks above one with no
measurement behind it.

Give each candidate a recommendation strength - **strong**, **worth it** or
**marginal** - weighing the cost saved against the size and risk of the
change. Name one **top recommendation**: the candidate to start with, and why.

## 5. Report

Write a self-contained HTML report to the temp directory, outside the repo
(for instance `"$(mktemp -d)/improve-tests.html"`). It loads Tailwind and
Mermaid from a CDN and holds everything else inline. It carries:

- the scope, the measured cost of each part, and the trend from
  `suite-cost history`;
- the top recommendation, first;
- each candidate in rank order, with its kind, location, strength, cost saved,
  and a **before/after**: the test as it is beside the test as proposed,
  with why the after tests as well.

Open it in the browser - `xdg-open <file>` on Linux, `open <file>` on macOS -
and tell the user its path. On a host that cannot open it, write a Markdown
summary in chat instead: the scope, the trend, the top recommendation, and
one line per candidate with its rank, kind, location, strength, cost saved,
and replacement.

## 6. Hand off

Ask the user which candidate to take forward, if any, as a **turn-final
reply**: end your turn on one plain-text reply, with no tool call in it,
holding step 5's Markdown summary - or, where the report opened in the
browser, its path - and then the pick question with its answers spelled
out: a candidate's number, or `none`. The user's next message is the
answer. Never ask it with the multiple-choice question capability, and
never write the summary in a response that also calls a tool: some hosts
hide a long text written in the same response as a tool call, and the user
never sees it (ADR-0051).
A number and `none` are matched after trimming surrounding whitespace,
letter case and trailing punctuation: `None.` is `none`, `2.` is `2`.

A **near-miss reply** is neither a candidate's number, nor `none`, nor
clearly a question: a typo, extra words, or a number no candidate has. It
is never guessed at and never re-shown. State in one line what you would
do (e.g. "Take candidate 2 forward"), then ask a short confirmation with
the multiple-choice question capability, nothing long in front of it:
*Yes, apply that* / *No, I'll answer again*. *Yes, apply that* does
exactly what the line states. Any other reply to the confirmation - *No*, a
free-text answer, or a dismissed ask - counts as *No*. Nothing is ever picked on
a guess.

On *No*, or on a reply that is clearly a question, the question path runs:
answer the question in chat, pick nothing, then end your turn again on the
summary, or the report's path, and the pick question in one plain-text
reply, with no tool call.

The one they pick goes
to the `orch-interview` skill: invoke it with the candidate - its kind,
location, replacement, why it tests as well, and its measured cost saved - as
the change to plan. The interview ends in a flow, a quick implementation or a
blueprint, like any other change. When the user picks none, stop: this skill
has changed nothing.
