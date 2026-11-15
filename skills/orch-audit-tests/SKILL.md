---
name: orch-audit-tests
description: Audit a repo's test suite for quality-preserving refactors ranked by the CPU cost they save - scope git hot spots or a named direction, measure each test section (or file, on a large scope) sequentially, partition into areas, hunt each area in a fresh read-only orch-test-auditor subagent (at most 4 at once), rank the candidates, show an HTML report, and hand picked candidates to orch-interview, to orch.sh audit file, or both. Read-only. Use when the user asks to shrink, speed up or audit a test suite, or runs /orchestrator:audit-tests.
---

# Orchestrator audit tests

Reads the repo's test suite and proposes refactors that make it cheaper to run
without making it test less, ranked by the CPU cost each one saves (see
`GLOSSARY.md`: **Test audit**). It ships for any repo. The idea comes from
mattpocock's `improve-codebase-architecture`, as inspiration only: the seven
steps below define this skill, and it invokes and depends on no upstream skill
(ADR-0028).

**Read-only.** This skill changes no tracked file in the repo and nothing
`git status` shows: it edits nothing tracked, commits nothing, and opens no
branch or PR. It only reads and runs the test commands the repo's agent files
document. Its working files - each area's findings file, the ranked file and the
report - go in its run directory,
`.orchestrator/audit/<kind>-<stamp>/`, which `orch.sh audit begin` makes
and git-excludes (ADR-0064). Its writes outside that directory are the git
exclude `audit begin` ensures and `orch.sh audit file`, for candidates the
user picks for filing. The promise covers the audit itself: once it hands
picked candidates to `orch-interview`, what that interview and the flow,
quick implementation or blueprint it closes on write is theirs.

Every candidate must pass **the quality rule** in the Brief of
`agents/orch-test-auditor.md` (under the plugin root). Cost only ranks the
candidates that pass; it never justifies testing less.

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

Steps here name capabilities (start a fresh subagent, run a subagent pool,
open a report in the
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
`docs/host-capabilities.md`. Then run `bash "$ORCH" audit begin tests` once,
before the first hunter starts; it prints the run directory, git-excluded,
where every working file goes. This skill runs no `agent sync`, which would
write `.junie/agents/` in the checkout (ADR-0060). Start one fresh subagent per
area (see the *Start a fresh subagent* row of `docs/host-capabilities.md`),
never a fork, each an `orch-test-auditor`, run as a subagent pool of 4 (host
capability *Run a subagent pool*, size hint: the area's file count; see that row
of `docs/host-capabilities.md`).
Each prompt names its area (the test files), the repo root, the measured cost of
each part in the area, and its own findings file, `area-<k>.md` in
the run directory (<k> the area's number from 1). The hunter has no Edit or Bash
tool, so it times nothing; its brief holds the quality rule, the six kinds, the
fields each candidate states (among them the replacement, why it tests as well,
and the expected saving, measured or estimated) and the findings-file format
(`@@ finding <k>` blocks, `@@ none` when empty). A reply is the file's path and
a candidate count; read each file.
When the pool took a fallback tier, tell the user which.

Check every candidate again against the quality rule, per **The quality rule**
in `agents/orch-test-auditor.md` (under the plugin root), and drop each one
that fails it: it names no replacement, or no reason it tests as well, or its
reason does not hold.

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

Then write the ranked file, `ranked.md` in the run directory. Its lines are
`@@ scope <text>` (the scope in one line), `@@ areas <count>`, any number
of `@@ note <heading>` blocks (text shown in the report's head under that
heading), which carry the timing mode (per section, per file or only as one
whole run) and the measured cost of each part, `@@ top <n>` followed by
why that finding comes first, and one `@@ finding <n>` block per kept
finding, numbered from 1 in order with no gap; `@@ none` takes the place
of `@@ top` and every finding when ranking kept nothing. No line of text
starts with `@@`. A finding block is a list of fields, each opening a line
with its label and a colon. Point at each kept finding with
`From: <area file>:<k>` (e.g. `area-2:3`, finding 3 of `area-2.md`;
several sources comma-separated, merged in `From:` order), restate only
the fields ranking changed, and give each a `Title:` - one line naming the
finding's kind and location, the issue's title if it is filed - and a
`Category: <c>`: `Category: enhancement`. The strength, cost saved (marked
estimated where it is) and before/after are fields like any other. List
under `Overlaps:` the numbers of each finding whose fix would change the
same function or the same lines. A finding written whole needs no `From:`.
Each finding stands alone: it names no other finding and never the report.

## 6. Report

Run `bash "$ORCH" audit report "<run>" "<run>/report.html"`,
<run> being the run directory. It renders the self-contained HTML report from
`ranked.md` and the area files: the scope, area count, notes and recorded
commit in its head, the top recommendation first, then every finding in
rank order. A refusal names the line that is wrong: fix it in the ranked
file and run the command again. Never write HTML or a script that writes it.

Open it in the browser - `xdg-open <file>` on Linux, `open <file>` on macOS -
and tell the user its path. On a host that cannot open it, write a Markdown
summary in chat instead: the scope, the area count, whether parts were timed
per section, per file, or only as one whole run, the top
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

- **File.** Run `bash "$ORCH" audit file --run "<run>" <numbers>` once, with
  the numbers picked for `file`, comma-separated. It files the findings in
  number order from the ranked file, with the title, category, locations and
  text each already holds, and writes each issue's `**Related:** #a #b` line
  for the picked findings that overlap. Write no per-finding file and pass no
  title, category or location. It prints one line per finding: its number, its
  issue number and `filed` or `open`. Report the issue numbers from those
  lines, naming any that was already open rather than newly filed. A failure
  stops the step: report what was filed (it stays filed), the failure, and what
  was not filed, and do not start the interview; the same command is the retry.
- **Interview.** Invoke `orch-interview` with the candidates picked for
  `interview` together, as one change to plan, each with its kind, location,
  replacement, why it tests as well, and its measured cost saved. The interview
  ends in a flow, a quick implementation or a blueprint, like any other change.

On `none`, stop: this skill has changed nothing.
