---
name: orch-audit-tests
description: Audit a repo's test suite for quality-preserving refactors ranked by the cost they save - scope git hot spots or a named direction, measure each test section (or file, on a large scope) sequentially, partition into areas, hunt each area in a fresh read-only orch-test-auditor subagent (at most 4 at once), rank the candidates, show an HTML report, and hand picked candidates to orch-interview, to orch.sh audit file, or both. Read-only. Use when the user asks to shrink, speed up or audit a test suite, or runs /orchestrator:audit-tests.
---

# Orchestrator audit tests

Reads the repo's test suite and proposes refactors that make it cheaper to run
without making it test less, ranked by the **suite cost** (see `GLOSSARY.md`:
**Test audit**) each one saves. It ships for any repo. The idea comes from
mattpocock's `improve-codebase-architecture`, as inspiration only: the seven
steps below define this skill, and it invokes and depends on no upstream skill
(ADR-0028).

**Read-only.** This skill changes no file in the repo: it edits nothing,
commits nothing, and opens no branch or PR. It only reads and runs the test
commands the repo's agent files document. Every file it writes - the
subagents' findings files, the report, and the finding file for each candidate
picked for filing - goes in one temp directory outside the repo (make it with
`mktemp -d`). Its one write outside that directory is `orch.sh audit file`, for
candidates the user picks for filing. The promise covers the audit itself: once
it hands picked candidates to `orch-interview`, what that interview and the
flow, quick implementation or blueprint it closes on write is theirs.

**The quality rule.** Every candidate names its replacement - the cheaper
test, fixture or seam that takes its place, or the existing test that already
covers it - and says why that replacement tests the behaviour just as well:
through the public interface, with the same confidence. A replacement that
checks less, mocks what the repo controls, or reaches past the public
interface fails the rule. A candidate that fails it is dropped, by the hunter
and again at step 4, and never reaches the report. Cost only ranks candidates
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

Time the scope's parts **once**, **sequentially**, one after another, in the
session, through the single-part command the repo's agent files document -
here, for instance, `ORCH_TEST_ONLY=<section> scripts/test/orch_test.sh`.
Never time parts in parallel: parts timed at once share the machine and every
number is wrong.

- When the scope holds about 40 sections or fewer, each section is one part.
- When it holds more, each test file is one part. Where the documented command
  selects sections only (as `ORCH_TEST_ONLY` does here), a file's part is one
  run of that command selecting every section in the file together, e.g. one
  ERE alternation of its section titles.

Time each run with bash's `time` builtin, which counts the children it waits
for: `TIMEFORMAT='%U %S %R'; time <command>` prints user, system and wall
seconds. A part's cost is its user plus system seconds. A part whose run
fails is reported as failed, with no cost.

When the repo's agent files document no single-part command, fall back to the
suite's whole-run cost only: time the full-suite command once, the same way,
and say that no part could be measured on its own.
Run it in the foreground and wait for it (host capability *Run a long
command*); never background it and sleep, poll or kill it. A run the host
moves to the background at its timeout is still waited for, as that row says.

Then run `bash "$ORCH" suite-cost history` and read the recorded runs of the
full verification command for the trend: whether the suite cost is growing,
and since which commit. No record means no trend; say so.

## 3. Partition

Split the scope into **areas**: each is a set of test files given to one
hunter, holding at most about 10 test files. An area is one hunter's share of
the scope, not a direction the user names; a hunter is the one
`orch-test-auditor` started for an area. Before any hunter starts, state the
area count.

With more than 8 areas, ask the user to confirm or narrow the scope as a
blocking question (host capability *Ask a multiple-choice question*), and
start nothing until they answer. A narrowed scope returns to step 1.

## 4. Hunt

Read `bash "$ORCH" agent get auditor` once, before the first hunter, and pass
the `model` and `effort` it prints on each start, per **Agent settings** in
`docs/host-capabilities.md`. This skill runs no `agent sync`, which would write
`.junie/agents/` in the checkout (ADR-0060). Start one fresh subagent per area
(see the *Start a fresh subagent* row of `docs/host-capabilities.md`), never a
fork, each an `orch-test-auditor`, at most 4 at once; start the next as one
finishes. Each prompt names its area (the test files), the repo root, the
measured cost of each part in the area, the trend, and its own findings file in
the temp directory. The hunter has no Edit or Bash tool, so it times nothing;
its brief holds the quality rule, the six kinds, the fields each
candidate states and the findings-file format (`@@ finding <k>` blocks, `@@
none` when empty). A reply is the file's path and a candidate count; read each
file.

Its brief defines the six kinds of candidate and the fields each states, among
them the replacement, why it tests as well, and the expected saving, measured
or estimated.

Read every candidate against the quality rule yourself and drop each one
that names no replacement, or no reason it tests as well, or whose reason
does not hold.

## 5. Rank

Merge duplicates that areas reported separately (notably a duplicated-coverage
pair seen from both sides) into one candidate naming every location.

Rank the candidates that remain in one numbered sequence by measured cost
saved, largest first. A saving measured from a part's cost ranks above an
estimated one. A saving inside a file timed as a whole counts as estimated,
marked so in the report, and so does every saving when only the whole-run
fallback was timed.

Give each candidate a recommendation strength - **strong**, **worth it** or
**marginal** - weighing the cost saved against the size and risk of the
change. Name one **top recommendation**: the candidate to start with, and why.

## 6. Report

Write a self-contained HTML report to the temp directory (for instance
`"$TMP/audit-tests.html"`). It loads Tailwind and Mermaid from a CDN and holds
everything else inline. It carries:

- the scope, the area count, whether parts were timed per section, per file,
  or only as one whole run, the measured cost of each part, and the trend from
  `suite-cost history`;
- the top recommendation, first;
- each candidate in rank order, with its kind, location, strength, cost saved
  (marked estimated where it is), and a **before/after**: the test as it is
  beside the test as proposed, with why the after tests as well.

Open it in the browser - `xdg-open <file>` on Linux, `open <file>` on macOS -
and tell the user its path. On a host that cannot open it, write a Markdown
summary in chat instead: the scope, the area count, whether parts were timed
per section, per file, or only as one whole run, the trend, the top
recommendation, and one line per candidate with its rank, kind, location,
strength, cost saved (marked estimated where it is, as for a saving inside a
file timed as a whole), and replacement.

## 7. Hand off

Ask which candidates to take forward, as a **turn-final reply**, per
`docs/turn-final-reply.md` under the plugin root: step 6's Markdown summary -
or, where the report opened in the browser, its path - and then the pick
question with its answers spelled out:

- `interview <numbers>`
- `file <numbers>`
- both, separated by `;` (e.g. `interview 2,5; file 3,7`)
- `none`

Numbers are comma-separated, and a number may not appear in both lists. Any
other reply is a **near-miss reply** (the doc's **Near-miss reply**), restated
in one line, e.g. "Take candidates 2 and 5 to the interview and file 3 and 7".
Nothing is picked on a guess. On *No*, or on a clear question, the doc's
**Question path** runs: pick nothing, and end the turn again on the summary,
or the report's path, and the pick question.

With both lists, filing runs first, then the interview.

- **File.** For each candidate picked for `file`, one at a time in number
  order, write its text (kind, location, measured cost, replacement, why it
  tests as well, expected saving and whether it is measured or estimated,
  strength) to a finding file in the temp directory and run
  `bash "$ORCH" audit file "<title>" --category enhancement --finding-file
  <file> --location <location>...`, one `--location` per site, each the
  `<file>:<start>-<end>` the hunter reported. The title is one line naming the
  candidate's kind and location. It prints the issue number; when an open issue
  already has that title it files nothing and says so on stderr. Report the
  issue numbers, naming any that was already open rather than newly filed. A
  filing that fails stops the step: report the numbers already filed (they stay
  filed), the failure, and the candidates not filed, and do not start the
  interview.
- **Interview.** Invoke `orch-interview` with the candidates picked for
  `interview` together, as one change to plan, each with its kind, location,
  replacement, why it tests as well, and its measured cost saved. The interview
  ends in a flow, a quick implementation or a blueprint, like any other change.

On `none`, stop: this skill has changed nothing.
