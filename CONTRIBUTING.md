# Contributing

How the plugin is laid out, the authoring rules its docs lint enforces, and
how to develop and test it. What the plugin does is in
[README.md](README.md) and [docs/how-it-works.md](docs/how-it-works.md).
The docs lint is `scripts/test/docs_lint.sh`, and its header lists every rule
it enforces, each with its `scan_*` function.

## Reporting a bug

Found a bug or want to propose a change? Open a GitHub issue on this repo -
label it `needs-triage` if it isn't already.

## Develop

```
claude --plugin-dir /path/to/orchestrator     # load the working tree directly
claude plugin validate .
scripts/test/affected.sh                      # the suites a change maps to; run before each commit
scripts/test/all.sh                           # every suite; the command CI runs on a PR
scripts/test/orch_py_test.sh                  # the pytest suite alone, as all.sh runs it
```

While iterating, run only the section you are working on, in quiet mode:
`ORCH_TEST_ONLY=<section> ORCH_TEST_QUIET=1 scripts/test/orch_test.sh`, where
`<section>` is an extended regex matched, ignoring case, against the `# ---`
section titles (every top-level branch of an alternation must match a section),
e.g. `ORCH_TEST_ONLY='^branch create$'` or `ORCH_TEST_ONLY='^autopilot '`. Run
`scripts/test/affected.sh` before each commit. CI runs the whole suite on every
PR through all.sh, which starts its other suites one by one, each waiting for
a pool slot when none is free, then orch_test.sh, then the pytest suite
(orch_py_test.sh), then shellcheck over every shell file, so they overlap,
carries on past a failing one, and once all have finished prints each suite's
FAIL lines and a summary line, the pytest suite's first, then the others' in
the order of all.sh's `suites` list, then shellcheck's findings and a
`shellcheck: N findings` summary line, or `shellcheck: not installed -
skipped`, which fails the run only in CI. It ends on one verdict line, `all.sh:
PASS (<n> parts)` or `all.sh: FAIL (<part>, <part>, ...)`, naming each failed
part by its summary line's prefix (leftover temp files as `temp files`);
affected.sh ends the same way on `affected.sh: ...`, or on all.sh's verdict when
it falls back to the full suite.

**The Python package.** A noun converted to Python (ADR-0067) lives in the
`orch` package, `scripts/orch_py/orch/`, and its tests are pytest, in
`scripts/orch_py/tests/` (still no top-level `tests/`). The converted nouns so
far are `issue`, `finding-triage`, `verification`, `audit`, `review-pass`,
`spec-review`, `spec`, `breakdown`, `glossary`, `parallel`, `route`, `agent`,
`phase`, `redo`, `ticket`, `ticket-worktree`, `pr`, `review`, `doctor` with its
alias `health`, and the bare global commands `init`, `slug`, `status`,
`archive` and `help`; a
helper a converted noun needs is copied into the package module of the concept
it serves, under its bash name, and its bash copy stays while a bash caller
remains. `orch.sh` stays the one entry point: main's one case naming the
converted nouns calls `orch_python`, which runs the package as `python3 -m orch
<noun> <arg>...` would, in place of orch.sh, so stdin, stdout, stderr and the
exit code are the noun's own. It runs it through a `-c` bootstrap rather than
`-m`: `-m` puts the caller's directory ahead of `PYTHONPATH` and the standard
library, so a `json.py` or `orch.py` there would shadow the package or its
imports, and Python 3.9 has no `-P`. The bootstrap drops that directory from
`sys.path` before importing anything, puts the package directory first on
`sys.path` in its place, then runs
`orch/__main__.py` through `runpy`. The package directory never goes on
`PYTHONPATH`, which would split a plugin path holding a colon and hand the
directory on to every command the noun starts; the caller's own `PYTHONPATH` is
left as given. `help`'s option spellings, `-h` and `--help`, and a bare
`orch.sh` reach the same case and run `help`. The entry point,
`orch/__main__.py`, is in syntax every python3 compiles (no annotations,
f-strings or `from __future__` imports) and imports the rest of the package only
after its version check. With no `python3` on `PATH`, `orch_python`
dies before doing anything, exit 1, naming `orch.sh doctor`; the package's entry
point dies the same way below Python 3.9. `doctor` and `health` themselves,
which cannot point at doctor, name the install instead, on both sides.
orch.sh's ROOT block still runs first, and the package's own (`orch/root.py`)
gives the same death outside a checkout when it is run directly. A converted
noun keeps the bash noun's arguments, stdout, exit codes and `orch:` messages,
and its bash module and section file are deleted with it. The package uses only
the standard library; the dev dependencies (pytest, pytest-xdist,
pytest-timeout) are pinned in
`scripts/orch_py/requirements-dev.txt`, which the autopilot image installs into
a venv at `/opt/orch-dev`. Locally: `python3 -m venv .venv && .venv/bin/pip
install -r scripts/orch_py/requirements-dev.txt`. From `scripts/orch_py/`,
`python3 -m pytest` runs the whole suite, `-k <name>` the tests whose names
match, `-n <workers>` (or `-n auto`) spreads them over xdist workers.
`scripts/test/orch_py_test.sh` is the wrapper affected.sh runs on every call and
all.sh on every call but a shard group other than the first: it reports pytest's
result as a suite's FAIL lines and summary, and prints `not installed - skipped`
without pytest, which fails only under CI. The pytest suite is in neither
all.sh's suites list nor the durations file, and has no durations file of its
own. In affected.sh a change under `scripts/orch_py/` selects the base,
branch and autopilot sections, which call a converted noun's own verbs
through CLI dispatch (base's `pr open` and branch's `pr publish` fixtures) or
call a Python bridge directly via `orch_python_call` (autopilot's model/effort
validation and its merged-PR close `pr close_missed_tick`), hooks_test.sh, whose
paste guard rows run `spec-review check` through it, and the side-checkout
sections, whose `.orchestrator` entry classification scans the package and whose
merged-PR close is the `pr close_missed_finish` bridge. That is not every
section that reaches the package: most start a flow through `fake_flow`, whose
`init` runs through the dispatch, and some run `status` or `help`; CI's whole
run covers those.

orch_test.sh is the suite's runner and holds no test. Its `# ---` sections live
under `scripts/test/orch/`: `<noun>.sh` holds the sections for one orch.sh noun
(`branch.sh`, `handoff.sh`, `state.sh`, ...), `harness.sh` the harness's
own (the section filter, quiet mode, all.sh), `common.sh` the bottom-layer
check on `scripts/orch/common.sh`, `loader.sh` the loader's sections and
those about `orch.sh` itself (its bash version guard, its death outside a
checkout and its removed nouns), and `setup.sh` the shared setup and the
summary. A concept module with no noun gets
a section file named as the module is, beside the per-noun files: `checkout.sh`
for `scripts/orch/checkout.sh`, `comments.sh` for `scripts/orch/comments.sh`,
`filed-finding.sh` for `scripts/orch/filed-finding.sh`,
`issue-timeline.sh` for `scripts/orch/issue-timeline.sh`,
`liveness.sh` for `scripts/orch/liveness.sh`,
`marked-comment.sh` for
`scripts/orch/marked-comment.sh`, `session-log.sh` for
`scripts/orch/session-log.sh`, `standing.sh` for
`scripts/orch/standing.sh`, `trust.sh` for `scripts/orch/trust.sh`, and,
for the two bash sources outside `scripts/orch/`, `host.sh` for
`scripts/host.sh` and `triage-labels.sh` for `scripts/triage-labels.sh`. A
ticket's tests go in the file for the noun it touches; a new
noun is Python, its tests pytest in `scripts/orch_py/tests/`, and a new section
file is picked up by the runner with no edit. A noun file holds
only `# ---` sections, optionally preceded by a preamble: the text before its
first `# ---` line, run before that file's sections whenever one of them runs.

A parallel `orch_test.sh` run starts its kept sections longest-first, read from
`scripts/test/section-durations.tsv`, the durations file: one line per section,
other suite and the shellcheck run, tab-separated, of wall seconds, CPU seconds
(both in tenths of a second), the title and, on every line but shellcheck's, the
fingerprint of the test text the line was measured from: a section's own lines
and its file's preamble, or an other suite's whole file. A line whose
fingerprint no longer matches, or that has none, is stale. The file is a ledger:
`docs_lint.sh` fails (but not while `section-durations.sh` records the file,
below) on a section or suite with no line, a line with no section or suite, a
stale line, a title on two lines and a missing shellcheck line. The
runners read a three-column line and a four-column one alike.
Sections the file does not list start first, in walk order; the rest follow by
wall seconds, longest first, ties in walk order, so a run ends when its work
does. Output stays in walk order, and a filtered run orders the sections it kept
the same way; `ORCH_TEST_JOBS=1` runs in walk order in one shell. A line that
does not parse and a title that matches no section are ignored, and a missing
file gives walk order: for the runners the file costs speed only. The shared
test setup, the fakes and the code under test are in no fingerprint, so a change
there that makes every section dearer is seen only by a full refresh.

`ORCH_TEST_SHARD=<i>/<n>` makes `orch_test.sh` and `all.sh` run group `i` of `n`
balanced groups of the sections, so CI can run a full verification as several
jobs. The grouping depends only on the section titles, the durations file,
`all.sh`'s suite list and `n`: sections are dealt heaviest first, by CPU
seconds, to the group with the lowest total, group 1 starting with the CPU
seconds of the other suites and shellcheck, and a section the file does not
list weighs the median CPU of the listed sections the deal deals, all but the
isolation section (the lower middle on an even count; 1 second when none is
listed). The isolation section runs in
every group. `all.sh` runs the other suites, the pytest suite and shellcheck in
group 1 only. A malformed value, or any value with `ORCH_TEST_ONLY`, is
refused; an empty value counts as unset; `affected.sh` unsets it, and no runner
a section starts inherits it.

`scripts/dev/section-durations.sh` with no argument makes a full refresh of that
file: it runs `orch_test.sh`
once, unfiltered, with `ORCH_TEST_DURATIONS=<temporary file>`, which makes a
parallel run write one line per section it ran, then times each other suite of
all.sh's list and the shellcheck step, and writes a fingerprint on every line
but shellcheck's. A full refresh is unscaled: it sets the scale every later
recording is held to, so it is the human's call, made on a tree whose suite
passes, in the autopilot container.
It unsets `ORCH_TEST_ONLY` and `ORCH_TEST_SHARD`, refuses
`ORCH_TEST_JOBS=1`, and leaves the file unchanged, naming what failed, when
anything it measured fails.

`section-durations.sh --stale` records only what is out of date: a section or
suite with no line, a stale line, a line whose section or suite is gone, and a
title on two lines (every line of a section or suite title is removed and
measured afresh; of two shellcheck lines the first is kept, shellcheck never
measured). It measures those sections in one parallel `orch_test.sh` run, and
each such other suite as the full refresh does, together with five calibration
sections: the fresh sections whose recorded CPU is nearest 5.0 seconds, never
the isolation section (all of them when fewer than five are fresh). Each new
line is what was measured times the ratio of the calibration sections' recorded
CPU to their measured CPU, so a line is scaled to the full refresh's machine
and corrected for load. Every other line stays byte for byte. It prints the new
total on its last line. With nothing out of date it
changes nothing and exits 0; with only orphaned lines it removes them and
measures nothing; with something to measure and no fresh section it refuses,
naming the full refresh, and exits 1; anything it measures failing leaves the
file unchanged and exits 1; it refuses `ORCH_TEST_JOBS=1`.

Both modes time every other suite with `DOCS_LINT_RECORDING=1`, which only
`section-durations.sh` sets (`all.sh` and `affected.sh` unset it, CI never sets
it, and `docs_lint.sh --base-rules` ignores it). With it set, the full run
of `docs_lint.sh` skips the ledger freshness rule and says so, so the suite it
is measuring does not fail on the very lines being replaced. With it unset it
judges it.

The durations file orders the sections; nothing caps its total (ADR-0068). What
a session does:

- **Record before verifying.** A session that adds or edits tests runs
  `section-durations.sh --stale` before its ticket verification and commits the
  durations file with its change. After a forgotten recording, only
  `docs_lint.sh` needs running again.
- **A conflict in the durations file**: keep both sides' lines, then run
  `section-durations.sh --stale`.
- **A full refresh** is the human's call. A session whose `--stale` refuses for
  want of a fresh section stops for the human. A session that cannot ask (a
  ticket subagent, a fixer, a resolver) reports it and changes nothing more; a
  resolver still commits its merge resolution and reports the stop beside it.
  The session that started it asks: an autopilot session with `orch.sh
  autopilot ask`, an attended session with a blocking question.

CI (`.github/workflows/test.yml`): a PR runs the whole suite once, in the
autopilot container, as 4 jobs, each `all.sh` with its `ORCH_TEST_SHARD=<i>/4`
(the image's `EXTRA_BUILD_COMMAND` checks in group 1 only), a `pytest` job
that runs the pytest suite alone on Python 3.9, the minimum, on
`ubuntu-24.04`, and a final `suite` job that needs both the container groups
and the `pytest` job and passes only when all four groups and the `pytest` job
did. Each group restores the image's base-tools
layer (apt packages, `gh`, Claude Code) from the repo's GitHub Actions cache
and still builds the image from the PR's commit; group 4 also writes the cache,
and a cold or unreadable cache costs time only. A push to `main` runs `all.sh`
unsplit on the runner (the container suite does not run there) and, in a
separate job, builds the image from scratch with no cache read and writes the
cache, so every PR's first run starts warm. Both jobs that run the suite
start it with SIGPIPE ignored (`trap '' PIPE`), so the PR gate sees what main's
run sees and the ignored disposition catches write-error bugs; the default
disposition is covered by local runs where the shell starts at it (a WSL shell
may not). The suite runs on a
PR's `opened`, `synchronize` and `reopened`; a newer run for the same PR
cancels the older one, and a push to `main` is never cancelled. The changelog
fragment check has its own workflow (see the fragment paragraph below).

A case lives once, in the section of the module it exercises. The Standing
sections own what a transition does on its own: its writes, its write chain
(the "writes that landed: ..." wording) and the claim staying held when a write
fails partway. Each command section owns its refusals, usage, success path and
own messages, plus exactly one partway-failure case, which shows the command
passes its own reason first and exits 1.

orch_test.sh runs its sections in parallel, `ORCH_TEST_JOBS` at a time (default:
75% of the usable CPUs, rounded down, at least 1, or `ORCH_TEST_POOL_PERCENT`
percent of them (a positive integer, above 100 too), and all of them under `CI`,
which ignores the setting; usable CPUs are the online cores, lowered to a
cgroup v2 `cpu.max` quota;
`ORCH_TEST_JOBS=1` runs them sequentially in one shell), so every section must
pass on its own. all.sh and affected.sh each run at most that many shellcheck
processes at once, one file per process, and orch_test.sh, all.sh, affected.sh
and orch_py_test.sh each lower their own niceness to 10 outside `CI`.
Each section of a parallel run has a deadline, `ORCH_TEST_SECTION_TIMEOUT` whole
seconds (default 600), counted from the section's own start; past it the runner
stops the section's process tree and reports `section '<title>' timed out`. A
positive integer is required, and `ORCH_TEST_JOBS=1` runs have no deadline.
Every runner draws its jobs from the job pool (GLOSSARY.md): slot lock files
under `~/.cache/orchestrator/test-job-pool`, as many as that default (so
`ORCH_TEST_POOL_PERCENT`, read from each run's own environment, sizes the pool;
an invalid value fails every runner with
`<runner>: ORCH_TEST_POOL_PERCENT='<value>' is not a positive integer`), each
held with `flock` while one section child, one shellcheck process, one xdist
worker of the pytest suite (`orch_py_test.sh` holds a slot per worker) or one
whole suite other than `orch_test.sh` and the pytest suite runs, so the pool
share bounds the whole run, every suite included, and no more test jobs run at
once than the pool holds; two or three sessions verifying at once queue for
slots (`orch_test.sh: waiting for a job slot (N in use)` on stderr, once) and a
killed holder's slot is freed by the kernel. `ORCH_TEST_JOBS=N` caps how many
slots a run asks for and never bypasses the pool, bounding the whole run at
min(N, the pool's size) slots, nested runners included; a run asking for more
jobs than the pool holds queues; `ORCH_TEST_JOBS=1` holds one slot for its whole
one-shell run. `CI` bypasses the
pool, as does a runner started inside a slot of the same pool (the runner marks
its children with `ORCH_TEST_POOL_HELD`); a pool that cannot be created, opened
or locked runs unpooled. The test-only `ORCH_TEST_POOL_DIR` names another pool
directory. Runs that disagree on the size share the directory unchanged: each
tries slots 1 to its own size, so a larger run also uses the higher slots while
all contend for the low ones, and concurrency is bounded by the largest size
among the active runs; no size is recorded there.
A slot bounds jobs, not cores: to cap cores outright use CPU affinity, for
example `taskset -c 0-7 <command>`.
Test-helper placement is checked by `scripts/test/orch/harness.sh`'s
test-helper placement section; its failure message states the rule. Copying a
helper's whole body is checked too: see Test helpers below.

orch.sh's own code is laid out the same way: `scripts/orch/<noun>.sh` holds one
bash noun's code, named as that noun's test file is, and a helper lives in the
module of the concept it serves, whichever modules call it. A converted noun
has no bash module: its code is in the Python package (see The Python package
in Layout).
`scripts/orch/common.sh` holds only the primitives no concept owns (die, warn,
note, capture and the like) and calls nothing a noun module defines; its test
section checks this. For bash callers the gh adapter layer stays whole in
`gh.sh`, whichever bash module calls it; a converted noun reaches GitHub
through the Python gh adapter, `scripts/orch_py/orch/gh.py`, instead. A bash
command that reaches GitHub - a GitHub operation, or a function or
whole command that makes one - is captured through the gh module's pair
`gh_capture` and `gh_capture_err`, never through bare `capture` or
`capture_err`: the pair resolves the Repo in the caller's shell first, so that
shell resolves it once (a subshell that resolves first does so for itself and
cannot hand the memo back). The concept modules with no noun, `checkout.sh`
(the Checkout module:
the walk over every checkout), `comments.sh` (the Comments module: reading an
issue's or a PR's trusted comments once, `comments_trusted_read`, with the
rendering in `orch/comments.py`),
`filed-finding.sh` (the Filed finding module:
whether an issue's labels mark a filed finding, and whether finding triage has
yet to triage it, for autopilot's untriaged-finding gate),
`issue-timeline.sh` (the Issue timeline module: one
issue's comment history, read once and asked in domain terms),
`liveness.sh` (the Liveness module: whether the process behind a record
(a claim, a watch) is still running - the run records,
the start-time reader, the record-alive rule, the watch pidfile and the
session log naming and its 14-day retention),
`marked-comment.sh` (the Marked comment module: writing and recognising
the issue comments whose first line names their kind), `session-log.sh` (the
Session log module: what a phase session's log says about usage limits, read
in one pass), `standing.sh` (the
Standing module: an issue's label set, its read and its claims), `trust.sh`
(the Trust module: which comments and which PRs orch.sh reads and which issues
autopilot runs on), live among the modules too.
`scripts/orch/loader.sh` (beside `common.sh`, always loaded) holds the loader:
the stub table, its per-copy cache under `~/.cache/orchestrator/`, the stub
dispatch (`orch_stubs`, `orch_stub`), `orch_load`, which sources a module once
per shell, and the load trace (`ORCH_LOAD_TRACE=<file>` appends `<module>
<depth>` per load). orch.sh names no module: it loads each through
`orch_load`, so a bash noun's module needs only a case in `main`; a new noun
is Python (ADR-0067), in the `orch` package, as **The Python package** above
says.
Run as a command, `orch.sh` loads a module only when one of its functions is
first called: at start the loader defines a stub for each function a module
defines at column 0, and the first call loads that module. Sourced, it loads
every module at once, in C-locale name order, so a function replaced after the
`source` line stays replaced; only a plain, unexported `ORCH_SOURCE_LAZY=1` set
before the `source` line loads on demand, and a sourced start always unsets it.
Reading another module's top-level variable: a top-level variable is one a
module assigns outside any function, plainly or through `readonly`,
`declare`, `export` or `typeset`. A function, or a module's own top-level
code, that reads another module's top-level variable names
`orch_load <that module>` earlier in its own
text than the first such read, so on-demand loading never reads an unset
variable. The variables of the always-loaded files (`orch.sh`, `common.sh`,
`loader.sh` and the files `orch.sh` sources from `scripts/` itself) are exempt.
harness.sh's `orch_load before cross-module reads` section enforces it
over the real tree; its failure names the file, the function or `top level`,
and the variable.
When a command's load trace shows a module more than once, it was loaded in
subshells (a command substitution, a pipeline): load it with `orch_load` in
the main shell before the first subshell that needs it. The load sits at the
command's entry for a module every run reaches, or before the shared loop, as
`side-checkout list` does; inside the one op, branch or function
that has the need, so a run that never reaches it loads nothing more; and,
where that branch itself runs inside a
subshell, in the main shell behind a guard that tests the same condition, such
as `if autopilot_active; then orch_load marked-comment; fi` for a load only an
autopilot session needs.
The shared test assertion `assert_trace_loads_once <label> <trace>`, in
`setup.sh`, checks a trace an existing run wrote for it; two assertions over a
trace belong to one section file each, in its preamble: `assert_loads_once
<label> <cmd>...`, in `autopilot.sh`, checks a command's trace, and
`assert_trace_names_no <label> <trace> <module>...`, in `loader.sh`, asserts a
trace names none of the given modules.

shellcheck is needed for `all.sh`'s lint step. `.shellcheckrc` holds its source
settings; severity is a command-line option only, so a manual run needs
`-S warning` to match `all.sh`. Each section file under `scripts/test/orch/`
opens with a shellcheck shell directive and a never-run `source setup.sh` line
behind a `source=setup.sh` directive, so shellcheck reads setup.sh's
definitions; a new section file copies those lines.

**Line width** is 80 columns: no covered line is longer than 80. It covers
every `*.md` under `skills/`, `agents/`, `commands/` and `docs/`, the root
`README.md`, `CONTRIBUTING.md`, `GLOSSARY.md` and `CLAUDE.md`, and the
whole-line comments of every `*.sh` under `scripts/`, outside heredoc bodies;
never `CHANGELOG.md`, `changelog.d/` or shell code. Frontmatter, fenced code,
table rows, lines with a URL, `# shellcheck` directives and one-token lines
are exempt. `scripts/dev/width.sh` is the one rule, in two forms: `width.sh
[--root <dir>] <file>...` checks the given files, judging coverage by each
file's path inside `--root` or else its own git repo root, and `width.sh --root
<dir>` scans every covered file under `<dir>`. It names each over-long line's
file, line and length, and exits 0 with or without findings. `docs_lint.sh`'s
`scan_line_width` wraps the second form.
The project's edit hook, `scripts/dev/hook-edit-width.sh`, runs the width
tool and, for a `.sh` file, shellcheck on each edited file, and on each `.md` or
`.sh` file a Bash call changed in the checkout holding its cwd (a PreToolUse
snapshot of the dirty files, compared on PostToolUse or PostToolUseFailure).

`--plugin-dir` is the development loop: it loads the working tree, so edits take
effect on the next session with no push. The installed copy is a clone of the
default branch pinned to `version` in `plugin.json`, so changes reach it only
after a push plus `/plugin marketplace update orchestrator`.

Every PR to `main` adds one **changelog fragment** and never bumps the version
by hand. The fragment is `changelog.d/<issue>.md`, `<issue>` all digits (a PR
closing several issues names it for one of them); beside the fragments,
`changelog.d/` holds only the tracked `changelog.d/.gitkeep`, which keeps the
directory on `main` after a release and is never a fragment. The fragment is
named for the PR's issue - in a flow or a quick implementation, the spec
issue, never a ticket - and is written once: by the one ticket subagent when
the breakdown collapsed onto the issue, else by the session driving the flow
or quick implementation after its last ticket lands; no other ticket subagent
writes or edits it. Its first line is exactly
`bump: patch`, `bump: minor` or `bump: major` - semver judgement: patch for
fixes and docs, minor for new features, major for breaking changes - and the
rest, after any blank lines, is the CHANGELOG prose for the change, non-empty
and holding no heading line (a line of `#` marks at column 0 followed by a space
or nothing), since the release adds the entry's one `## ` heading:

```
bump: minor

`orch.sh widget frob` frobs the widget (#123): ...
```

Two PRs never touch the same fragment, so PRs open at the same time never
conflict on `plugin.json` or `CHANGELOG.md`. On every push to `main`, the
version-bump Action (`.github/workflows/version-bump.yml`) runs
`scripts/version-bump.sh`, which gathers every fragment on `main` into one
version bump: `version` raised by the highest level among them, one `## <new
version>` entry on top of `CHANGELOG.md` carrying their prose in issue-number
order, the fragments deleted, `.gitkeep` left in place. The Action commits that
as `Release <version>` and pushes it; a push that loses a race with another
merge leaves the fragments to that merge's run. Run `scripts/version-bump.sh`
from a scratch copy of the checkout to see how a fragment renders: it edits the
files in place and does not commit. `scripts/test/version_bump_test.sh` tests
it.

CI enforces the rule through its own workflow, `.github/workflows/fragment.yml`,
which runs the fragment rule through `docs_lint.sh --base-rules`, and reruns
on a PR's body and label edits; the ledger's freshness rule runs in the
suite's whole lint, on a push to `main` too: a PR to `main` adds exactly one
well-formed fragment, and never changes `version`, adds a `## ` heading to
`CHANGELOG.md`, or modifies or deletes an existing fragment or `.gitkeep`;
the fragment's issue is no sub-issue, its parent looked up with `gh api` and
named when it has one. An epic's child shipped as its own PR is a known false
positive, cleared by detaching it from its parent on GitHub. A pure CI or
repo-hygiene PR carries the `no-version-bump` label, which waives the fragment
and ships no version bump; the other rules still hold.

### Test helpers

`scripts/dev/helpers.sh` is the helper index, read from the code so it cannot
drift: run it rather than grepping for a helper. Bare, it lists every function
of orch.sh's modules (`scripts/orch/*.sh`) under a `# <path>` header per
module, each with the first line of the comment above it - its second line
where the first holds only the `<name> <args>:` signature - or `-` where there
is none; `cmd_*` entry points are left out. `--tests` lists the shared test
setup (`scripts/test/orch/setup.sh`), the gh adapter fake
(`scripts/test/gh_adapter_fake.sh`) and the assertion tally
(`scripts/test/tally.sh`: `ok`, `bad`, `skip`, which count even inside a
`( ... )` subshell, and `tally_summary`, the ending each standalone suite
calls) and the bounded FIFO wait (`scripts/test/fifo.sh`: `fifo_bounded`,
`fifo_read_line` for a read) and the counting fixture
(`scripts/test/counting.sh`: `counting_bin`, `counting_starts`,
`counting_argv_bin`, which logs only the starts whose arguments match,
`counting_glob_bin`, which logs only those whose arguments match a glob,
`counting_stdin_bin`, which records the bytes offered on stdin, and
`counting_bytes`, their sum) and the failing-command fixture
(`scripts/test/fails.sh`: `fails_bin`, a stub that fails the calls whose
arguments match a glob, with any status, and runs the real command otherwise)
instead - their fixtures, fakes and assertions. A
`<file>` argument lists that one bash file alone, e.g.
`scripts/dev/helpers.sh scripts/orch/base.sh`. harness.sh's helper index
section checks it against what bash itself defines.

A section's `HOME` starts with the stub cache of the tree under test: the runner
builds it once per run, the seed, and `setup.sh` copies it into each fresh
`HOME` (mode 600, a file of its own). The cache tests and any test that runs
`orch.sh` from a copied or planted tree still rebuild, as the file is named from
its tree. A seed that cannot be built or copied leaves the run unseeded,
silently.

A test that needs a `HOME` of its own calls `seeded_home`, which exports a
throwaway `HOME` that starts with its own copy of the same seed, so isolating a
test costs no rebuild; `healthy_repo` uses it. It prints nothing and
succeeds, and in an unseeded run the `HOME` holds no cache file.

`sourced_orch` sets `ORCH_SOURCE_LAZY=1`, so it loads orch.sh's modules on
demand, as the command does and so a test's shell starts cheaply, except in its
`eval` form (`sourced_orch eval <code>`); `sourced_orch_script` loads every
module, as the code it runs may replace or name any function. Only
`sourced_orch` sets the variable outside the loader's own section file: the
harness section on the on-demand sourcing variable (#2820) fails on any other
test file naming it.

A test file may not write out a helper's whole body either: harness.sh's helper
body copies section runs `helper_copies` over the orch suite's section files,
`setup.sh` and the sourceable test helpers, and fails with one line per copy,
naming the copy's file and line, the helper and the file defining it. The
helpers checked are those at the top level of `setup.sh`, of each sourceable
test helper and of each section file's preamble (a preamble helper only in its
own file). A copy is a run of lines equal to the body once blank and
comment-only lines are dropped and each line is trimmed, a trailing comment and
heredoc bodies not counted; a one-line body also matches inside a longer line.
A body is checked from 2 lines, or 1 line of at least 40 characters; a
near-copy or a partial copy stays with review. Replace the copy with a call, or
exempt a deliberate repeat with a comment on the line just before it,
`# copy-of <helper>: <reason>`, naming that helper and giving a reason.

The fixtures to reach for first:

- `fake_flow <slug>`: a section's usual starting point - a fresh repo, the
  GitHub fake, and a flow named `<slug>` just started in it.
- `fake_github`: a fresh, empty store-backed GitHub fake that every orch.sh
  the test runs talks to in place of gh.
- `fake_issue <n> <state> [labels...]`: seeds issue #n in that fake, open or
  closed, with its labels.
- `state_fixture <key> <value>`: arranges state.json directly, for the keys
  `state set` refuses (phase, branch, pr, iteration, ...).

The pytest suite has fakes of its own, never the bash harness's fixtures:
each test uses `tmp_path` and `monkeypatch`, and an in-process test hands a
noun's `run` its fakes (`issue.run(argv, gh=..., git=..., env=...)`). ADR-0067
excepts code a fake would only restate: Lines fate is tested against real
repositories; the verification noun's `run` is handed the real `Git` adapter
on real repositories and starts real processes, since process lifetime is the
behaviour under test; and the init, archive and status nouns' `run` is handed
the real `Git` adapter on real repositories where git's worktree and
git-status semantics are the behaviour under test - init's archive of a done
flow and its git exclude, archive's side-checkout teardown, status's listing of
the other checkouts - as are the checkout scan's and the side-checkout
module's own tests. So are the ticket nouns' git cases, handed the real `Git`
adapter on real repositories where git's history semantics are the behaviour
under test - the ticket noun's close, merge and reclaim, and the
ticket-worktree noun's add, list and remove and its teardown. So are the review
noun's cases where git's worktree and discard semantics are the behaviour under
test - `review resume`'s discard of the flow branch's work and `review ready`'s
side-checkout pointer - and doctor's checks that read git's worktrees and
history, in a real repository.

- `orch.gh_fake.FakeGh`, the gh adapter's fake, and `FakeStore`, which seeds
  and reads the shared fake store: the file store
  `scripts/test/gh_adapter_fake.sh` documents, in the layout the bash
  `fake_*` helpers write. `orch.gh.adapter` picks the fake whenever
  `ORCH_GH_FAKE_STORE` is set, as `fake_github` sets it, and the fake honours
  the store's failure files (`fail/<operation>` with `.after` and `.times`,
  `offline`, `ratelimit`) under `adapter_<method name>`, the bash adapter's
  name for an operation both keep, so a bash section's `fake_fail` reaches a
  converted noun it runs through orch.sh. A bash stand-in
  (`adapter_stood_in`) cannot reach Python: a case that needs one for a
  converted verb is a pytest test.
- `orch.git.FakeGit`, the git adapter's in-memory fake. Each git operation is
  tested against a real repository in `tmp_path` and against the fake,
  asserting the same answers. The operations `orch.git.COULD_NOT` names answer
  what `seed(<operation>, <args>..., answer=...)` set for their arguments, and
  their "could not" value for a call nothing was seeded for - but for
  `config_value`, which falls back to the fake's stored local, then global,
  config before giving None, so what `config_set` writes reads back.
- In `conftest.py`: `clean_env`, autouse, clears the variables that would
  change what a test resolves, sets `GIT_TERMINAL_PROMPT=0` so git never
  blocks prompting on a PTY, and puts the real-gh guard first on `PATH`,
  failing a test that reaches gh; `fixture_gh` is a fixture gh answering by
  exact argv, for the real gh adapter's contract tests (ADR-0033).

To debug, run one section under `bash -x`. The suite selects whole `# ---`
sections, not single cases, and in parallel mode each section re-runs in a
child bash that does not inherit `-x`, so run it sequentially:
`ORCH_TEST_ONLY='^<section>$' ORCH_TEST_JOBS=1 bash -x
scripts/test/orch_test.sh`.

`orch.sh`, its modules and the test suite target bash 4.2+: `mapfile`, `declare
-A` and `printf -v` are fine. `orch.sh` refuses to start below 4.2: its version
guard, the first lines after the shell options, prints one line and exits,
and those lines stay bash 3.2-compatible, beside the hook scripts.
The `hook-*.sh` scripts and every module a hook
sources (`flow-state.sh`, `host.sh`, `bash-walk.sh`, `paste-guard.sh`,
`planning-allowlist.sh`, `triage-labels.sh`) stay bash 3.2-compatible (no
namerefs, no `mapfile`, no `declare -A`), because they run under macOS's
`/bin/bash`.
The code and tests also run on the autopilot image's tools - jq 1.6, bookworm's
mawk (no regex interval expressions) and git 2.39 - as their floor, and the
container CI jobs enforce it.

### Measuring a lens

`scripts/dev/lens-bench.sh` measures what a lens definition costs, over
enough runs to tell its effect from run-to-run noise. Each lens with a
benchmark has a fixture, `scripts/dev/lens-bench/<lens>/`: `spec.md`, the
spec body the lens reads; `map.md`, its baseline map, when it has one; and
`snapshot`, the commit whose tree the lens explores. The Implementability
fixture is the 801e6f97 round-1 spec body and baseline map on snapshot
`0fea0b6`, the map pruned from 27 locations to 25 by dropping two no decision
in the spec depends on (#1244). A new lens's benchmark is a new fixture
directory and nothing else.

A human starts the runs, since they need a live `claude` (an agent's nested
`claude -p` with a custom agent is blocked):

```
scripts/dev/lens-bench.sh run implementability --definition <rev> --out <dir> [-n N] [--model M]
```

It reads `agents/orch-lens-<lens>.md` at `<rev>`, a commit and never a file
path, checks the snapshot out in a temporary git worktree (removed when the
runs end or fail; your checkout is never touched), and starts N `claude -p`
runs from it, 5 by default, on model M, `claude-opus-5-5` by default. Each
run's lens transcript and map land in `<dir>/run-1` .. `run-N`, beside
`lens`, `revision`, `model`, `spec.md` and the baseline `map.md`. A failed run
stops it, keeping the runs before it; an INT or TERM stops the running
`claude -p` at once, keeps the runs before it and removes the worktree; the
output directory must not exist.

Anyone, an agent included, measures directories: `scripts/dev/lens-bench.sh
measure <dir>...` prints a Markdown report on stdout, with no `claude`.

To compare against a run made elsewhere, such as the #1196 baseline
transcript, lay it out by hand as a one-run directory: write `lens`,
`revision` and `model`, copy the fixture's `spec.md` and `map.md`, and put the
lens agent's transcript
(`~/.claude/projects/<cwd-slug>/<session>/subagents/agent-*.jsonl`) at
`run-1/transcript.jsonl` and the map it wrote at `run-1/map.md`. Pass that
directory to `measure` beside the new ones for a reference row.

## Layout

```
commands/                     start, next, flow-status, health, redo, abort, finish, release, spec-review, review-pass, sync, interview, quick-implement, quick-autopilot, to-spec, to-tickets, finding-triage, audit-docs, audit-code, audit-tests, questions
agents/                       the fresh agents: two reviewers (the review loop's and the review pass's), the review loop's fixer and closer, the spec review's four lenses, the implementer, the resolver of a merge conflict, the docs audit's doc auditor, the code audit's code auditor, and the quick autopilot's planner (orch-autopilot-planner, Claude Code only)
skills/orch-flow/             the state machine (judgment); the spec and implement phases sit in `phase-spec.md` and `phase-implement.md` reference files beside SKILL.md
skills/orch-spec-review/      the spec review: consolidation of the issue's comments, then four lenses in a flow (three standalone), one batch question applied by `orch.sh spec-review apply`, plus a ticket question when an existing breakdown is touched; the spec-phase and standalone entries (`spec-phase.md`, `standalone.md`), batch-file grammar (`batch-file.md`), view/answer/apply/changelog rules (`applying.md`), unattended mode (`unattended-spec-review.md`) and ticket step (`tickets-follow-the-spec.md`) sit in reference files beside SKILL.md
skills/orch-review/           the review loop only: rubric, authority rules, terminal states; autopilot-only rules (`autopilot.md`), CI/termination/closer (`termination.md`) and triage/severity/authority/clean-record rules (`triage.md`) sit in reference files beside SKILL.md
skills/orch-review-pass/      the review pass, quick or standalone: one look by the two reviewers, no loop
skills/orch-sync/             a base sync on demand: branch sync, a resolver on a conflict, one PR comment, an offered review pass
skills/orch-handoff/          handoff templates and the Rejected alternatives amendment, model-invocable unlike the upstream one
skills/orch-quick-implement/  the other route: issue (possibly rewritten from the plan by orch-to-spec's Unattended rewrite), unattended spec review, orch-to-tickets, tdd, review pass, PR - no flow
skills/orch-interview/        the planning interview, and its `## Closing` section: the closing rules hook-grilling.sh's message points to; the unattended interview sits in its `unattended.md` reference file
skills/orch-quick-autopilot/  the quick autopilot: selects with `autopilot candidates`, one confirmation, one orch-autopilot-planner per issue, a summary - Claude Code only
skills/orch-to-spec/          turns the conversation into a spec: publishes it as a new issue, or rewrites a given issue's body - attended, or in the Unattended rewrite form a quick implementation or a quick autopilot takes
skills/orch-to-tickets/       breaks an issue into tickets published as sub-issues, or collapses 0-1 into the issue
skills/orch-release/          the release PR: model writes title and summary, pr release writes Closes lines
skills/orch-finding-triage/   finding triage: scan the filed findings against the default branch, one batch per source PR, apply; --bundle groups them into bundles
skills/orch-questions/        gathers the pending autopilot questions, a fresh subagent recommending per issue, one batch per issue, replies via `orch.sh autopilot reply`, then offers `resume` on stops and replied issues
skills/orch-audit-tests/     audits a repo's test suite for cost-cutting refactors read-only: scope, measure sequentially, partition into areas, hunt in read-only orch-test-auditor subagents, rank by cost saved, HTML report, hand off to orch-interview and `orch.sh audit file`
skills/orch-audit-docs/      audits a repo's documentation against its code read-only: scope, partition into areas, hunt in read-only orch-doc-auditor subagents, rank, HTML report, hand off to orch-interview and `orch.sh audit file`
skills/orch-audit-code/      audits a repo's source code for latent bugs, inefficiencies and architecture deepenings read-only: scope, partition into areas, hunt in read-only orch-code-auditor subagents, rank, HTML report, hand off to orch-interview and `orch.sh audit file`
scripts/orch.sh               the entry point for every deterministic operation (mechanism): path resolution, shared constants, the module list, main, whose one case naming the converted nouns hands each to the orch package through orch_python
scripts/orch/<noun>.sh        one module per orch.sh noun still in bash (branch.sh, handoff.sh, ...), sourced by orch.sh, named as its test file
scripts/orch_py/orch/         the orch Python package (ADR-0067), one module per converted noun (issue.py, finding_triage.py, verification.py, audit.py, review_pass.py, spec_review.py, spec.py, breakdown.py, glossary.py, parallel.py, route.py, agent.py, slug.py, status.py, init.py, archive.py, help.py, phase.py, redo.py, ticket.py, ticket_worktree.py, pr.py, review.py, doctor.py, each named as its noun with each - as _) beside the helpers it rebuilt, among them filed_finding.py (the Filed finding module's categories, labels and body parse, the filing checks audit file and review file make: the flag parse, the input and location checks, the needs-triage label and the body temp file, and what review file alone needs: each severity's label and its upsert, the category a review axis starts in, and the body render; the bash filed-finding.sh keeps only the review label test and the untriaged-finding check autopilot's gate makes), common.py (the primitives no concept owns, among them normalize_slug, dir_stamp, the code-fence rule, the git exclude writer audit begin and review-pass begin use, and move_files_aside), lines_fate.py (the Lines fate module, a concept module with no noun: what became of a range of a file's lines at a ref since a commit filed them, read by finding triage's scan), planning_allowlist.py (the Python copy of scripts/planning-allowlist.sh's lists, texts and matcher, pinned to it by a parity test, and the dirty-path scan the flow-start check refuses with), flow_state.py (the Flow state reader and seed writer: state.json read by the bash Flow state module's multi-key rules, pinned to it by golden files, the seed init writes and creates (flow_state_seed, flow_state_create), pinned to bash init's bytes by the seed/ golden files, the multi-key writer (state_write_many, several keys in one write), the phase writers (phase_write, and phase_write_try, which returns failure for a caller that words its own, each taking further keys to write with the phase), the flow-holding guard, require_state_exists, the no-flow refusal archive makes, require_state_read, a command's entry read of the keys it needs, with its no-flow and unreadable refusals, require_state, the refusal of no flow or an unreadable one, require_value, a required field's refusal, and the flow base fallback status reads (flow_base_fallback_into)), known_items.py (the Known items module, its one copy: a record's entries, tagged bullets and the known-items file), handoff.py (a heading's lines and its count outside code fences, `handoff path` through the file adapter and, under autopilot, the comment adapter, handoff validation - the required sections, `handoff_report` and `handoff_check` - pinned to the bash validator by the golden handoffs of tests/handoff_report/, and the retire a redo sets stale handoffs aside with, handoffs_written_from and handoff_retire, with its file and comment adapters, and the checks doctor makes of the handoffs due: the phase list from a phase (phases_from) and handoff_ready, handoff_doctor_missing, handoff_fetched and handoff_fetch_due), issue_timeline.py (an issue's trusted comments read once, and its live handoffs, for the comment adapter), marked_comment.py (the first line of every kind of marked comment - the spec review changelog's opening, the retired handoff marker the comment retire posts - and recognising the marked comments the issue, review-pass and spec-review nouns read), ticket.py (the ticket noun - publish, next, list, close, report save and show, parent, merge and reclaim, beside exists, block, unblock, retire and reset - and the ticket concept the other nouns reach: a breakdown's sub-issue listing, the `## Blocked by` and `## Ticket` reads and rewrites, `ticket exists`, `ticket block`, `ticket unblock` and `ticket retire`, as spec-review apply runs them, and `ticket_create`, `ticket_link`, `ticket_links_verified` and `blockers_set`, as breakdown publish runs them, `require_no_open_tickets`, phase advance's open-tickets refusal, which `pr open` and `pr publish` call too, and `ticket reset` and `ticket retire`, as redo runs them), ticket_worktree.py (the ticket-worktree noun - add, list and remove - and the Ticket worktree concept the ticket noun's close, merge and reclaim reach: a ticket number's check and its worktree's path, ticket_facts, one read returning a TicketFacts record with its worktree states, and the requirements on it, the merged check of a ticket branch, and ticket_worktree_teardown, with its two failure results), autopilot.py (the autopilot noun as its conversion stands, not yet routed through orch.sh: the verb dispatch with its unknown-op refusal and every usage line, and the verbs converted so far - settings, show, with the settings' lookup and validation, the model and effort checked by agent.py in process, active, rounds and budget, start, through standing.py's standing_start, and candidates - and the concept every Python noun reads: whether this is an autopilot session, the plan's `## Autopilot` block report, the pause files' UTC timestamps, and the GitHub limit record gh.py's limit handling makes in an autopilot process, the GitHub limit pause and a session's hit file, pinned to autopilot.sh's reading of the pause by tests/github_pause/), standing.py (the Standing module's phase label test, the claim release, orch:running removed then the claim ref deleted, that spec pause --round makes in an autopilot flow, and the finished phase's close, standing_finish, the phase label moved by standing_move_label, then the phase recorded, then the claim released, and what doctor reads of an autopilot flow's standing: the standing and claims reads (standing_read, claims_read), the host id, the live phase and redo phase reads and the label verdict), pr.py (the pr noun - open, publish, release, comment, comments, fetch, read, update, draft and ready - with the PR-writing standard's body check and the push-then-issue-line step open and publish share; the merged-PR close, behind the bridges autopilot's tick and side-checkout's sweep call once each, close_missed_tick and close_missed_finish, the latter called in-process by side_checkout.py's sweep too; and the current branch's open PR, which review-pass reads too), branch.py (the branch concept as far as the busy refusal's branch signal, the terminal-state read, redo, the ticket nouns and pr need it: the PR, retired and forked-from keys read off a branch, the PR and forked-from keys written (branch_pr_set, the PR key's writer, which pr open and pr publish call), the branch kinds, whether a branch records a base, the flow's branch name and its redo form, a ticket branch's name, the issue a flow or quick branch name gives, the discard rule's own-branch proof and discard, and branch_retire, every arm of bash `branch retire`), review.py (the review noun, all twelve verbs: the verb dispatch with its unknown-op refusal and every usage line; begin, path, terminal, resume and retire, with the budget fallback and its default of 5 (review_budget_fallback) that status and redo read too; file, built on filed_finding.py; known-items, built on known_items.py; standards with the Standards resolution under it (standards_resolve_source); ci and ci --no-wait, the grace from the push, the no-CI-evidence skip and wait.py's stored total; rerun and ci-log, over the failing counted checks; ready, the CI gate pr ready makes too (ci_ready_gate, with ci_counted, ci_counted_probe, ci_classify and ci_unreachable under it), the PR marked ready, then phase.py's finish called in process; what doctor's three review checks read in process, review_terminal_report, ci_probe and standards_resolve_source; and the review loop's terminal-state read: the record path, the record's terminal section, the flat-record-gone check, the terminal record with its pre-redo-<n>/ fallback, and the classification, pinned by the golden review records of tests/review_terminal/, and review_retire, `review retire`'s move of the records into pre-redo-<n>/), base.py (the base concept's default-branch lookup, the base branch in effect now, as base_branch_into reads it for init, and the base a branch belongs to, as recorded_base_into reads it), host.py (the host, the plugin and flow commands a message names for it, and the stop block naming the fresh session's next step that the phase noun's boundary and advance and spec pause print), checkout.py (the Checkout concept as far as a converted noun needs it: the main checkout, the current branch and a checkout's branch, the branch a rebase in progress is rebasing (checkout_branch_or_rebasing, which review resume reads), the checkout a branch is checked out in, the ticket-worktree path, the checkout scan init, status and archive read - every checkout with its kind (checkouts, checkout_classify, checkout_kind), what one holds (checkout_holding) - whether a merge or a rebase is in progress, the ticket-worktree listing and refusal (ticket_worktrees_under, refuse_ticket_worktrees, whose bash copies the bash Checkout module keeps for side-checkout's walk), the busy-checkout refusal, and the discard rule's pieces (ADR-0054): the flow-branch proof, the work to discard and the discard sequence), side_checkout.py (the Side checkout concept as far as the checkout scan and archive need it: the ownership marker, where a flow is archived and the archive itself (archive_root, archive_flow), and the teardown, a side checkout archived into the main checkout's archive then removed, with its or-exit wrapper, and the glossary's **Finished**, side_checkout_finished, which doctor's finished-side-checkouts check reads, and the side-checkout verbs Python autopilot reaches, ported for the side-checkout conversion while the bash noun keeps its own copies: add (side_checkout_add, the short slug and its clash suffixes a picked-up issue's side checkout is named by), the finished sweep (side_checkout_prune, its merged-PR close calling pr.py's close_missed_finish in-process), and the two lookups, side_checkouts_dir and side_checkout_for_issue), repo.py (the Repo pin and its resolution, the owner/name split and whether the host came from origin's SSH URL), triage_labels.py (the triage labels table and the expected labels doctor checks), and liveness.py (the `<pid> <start-time>` record and issue_alive, whether an issue's claim is alive) and wait.py (the Wait module's one copy: the re-callable block and a re-callable wait's stored total, its format pinned by the golden files of tests/wait/, with the provisional guard, the limited mark and the decision whether a GitHub rate-limit wait fits in the block, which gh.py's limit handling asks); doctor.py the doctor noun and its alias health (the reporter, the env and flow check registries, the GitHub probe each answer is read once by, and doctor's own checks, each a registry entry named for the bash check it replaced); audit.py the audit noun (begin, report, file and file --run, and the drift line of an audit-filed body that the issue noun reads); review_pass.py the review-pass noun (begin and known-items); spec.py the spec noun (fetch, update, comment and comments on the flow's issue through the issue noun in-process, pause and pause --round with their markers, round-dir and round), with the spec concept's round directory: its state files, the saved answer, the hold and the round's local tail, the reset, the carry and the round count's parse, read by the golden round directories and saved-answer lines of tests/spec_round/; glossary.py the glossary noun (terms, show and match: the root GLOSSARY.md's entry grammar as pure functions over text, and show_file, docs_lint's reader of one entry from any file); parallel.py the parallel noun (show: the parallel cap, read through git.py's config_value); route.py the route noun (show: the default route, read the same way); slug.py the slug noun (common.py's normalize_slug, printed); init.py the init noun (the busy and planning-allowlist refusals, the adoption gate, the trust warning, the seed, the archive of a done flow, the folders and git exclude, and the state write); status.py the status noun (the flow lines, the "No active flow" line and the listing of the other checkouts); archive.py the archive noun (the flow archived in place in the main checkout, or from a side checkout into the main checkout's archive and the worktree then removed, through side_checkout.py); help.py the help noun (the command list, moved verbatim from bash cmd_help and pinned byte for byte by tests/help/golden.txt); phase.py the phase noun (advance and boundary, and finish, the phase recorded or, in an autopilot session, the Standing finish, which review ready calls in process); redo.py the redo noun (review and spec, with redo_midway, the half-finished-redo predicate the terminal-state read shares, the retire plan, the attempt retire - the PR closed, then the branch retired through branch.py's branch_retire and recorded in one state write - and the closing write); agent.py the agent noun (set, show, clear, get, sync and roles, the HostSpec table, .junie/agents/ copy-sync, the bridge functions autopilot and docs_lint call, and autopilot_setting_check, the autopilot model and effort check behind the bridge, which the Python autopilot noun calls in process); breakdown.py the breakdown noun (publish and state: the draft parse in memory, the publishing order, and the save point, which ticket.py's retire removes, in the layout the bash noun wrote); spec_review.py the spec-review noun (begin, check, apply, wait and prompt), with spec_review_batch.py (the batch and lens findings parse and the validation check and apply share), spec_review_tickets.py (the ticket items parse and the offline checks) and spec_review_apply.py (the machinery the apply verb calls: the answer, the edits, the changelog, the saved answer and --resume, and the GitHub writes); verification.py the verification noun (a re-callable command, its runner started through its own copy of the bootstrap, at the module's `__main__` entry point): standard library only, Python 3.9+; __main__.py the entry point (the version check, in syntax every python3 compiles), cli.py the noun table, gh.py and git.py the only places gh and git run (gh.py's operations among them the sub-issue listing, link and unlink, the blocker list, add and remove that the ticket commands call, claim_delete, the claim ref's push to origin, and what doctor asks: the auth status probe for a host, the repo's label list, gh's local default repo, the sub-issue support probe and the merged-PRs read; git.py's push, with its reason, and git_failed, which hands a failed run's stderr on as bash let it through), gh_fake.py the gh adapter's fake on the shared fake store, with its claim seeder and reader (claim and claim_held, as fake_claim_seed and fake_claim_held), root.py the ROOT block
scripts/orch_py/tests/        the pytest suite: in-process tests of each noun against the fakes (the verification noun's against real repositories and real processes, and the worktree and git-status cases of init, archive and status, and the ticket noun's close, merge and reclaim and the ticket-worktree noun's add, list, remove and teardown, and the review noun's resume discard and ready side-checkout pointer, against real repositories, ADR-0067's exceptions for what a fake would only restate), two of the review reads doctor makes in process (ci_probe and standards_resolve_source) called directly on a plain directory and the gh fake in test_review_doctor.py, review_terminal_report, whose one caller is doctor, tested through doctor, the gh adapter's contract tests against a fixture gh, the git adapter's tests against a real repository and its fake, doctor's report, every group and check through doctor.run, in test_doctor.py, and the end-to-end checks of orch.sh's dispatch (test_dispatch.py), doctor's own python3 refusal and the running bash's version line among them; conftest.py the clean environment and the real-gh guard, and the shared fixtures, among them the real-repository ones the checkout, side-checkout, archive, status, init and ticket tests share (worktree_add, mark_side, hold_flow, done_flow, side_checkout, archive_main, the FakeGit side checkouts doctor and the side-checkout sweep share (linked_worktree, SideCheckouts, sha_of), and the pinned archive_clock with its ARCHIVE_STAMP and archived, the file helpers files_under and orch_files, and the ticket nouns' ticket_repo with its TICKET_PARENT and TICKET7, orch_tw, wt_path, added, git_of, has_branch, lock_ref and rebasing)
scripts/orch_py/requirements-dev.txt the pinned dev dependencies: pytest, pytest-xdist, pytest-timeout (the package itself needs none)
scripts/orch_py/pytest.ini    the pytest settings: the tests folder, the package on the module path, the per-test timeout, no cache directory
scripts/orch/checkout.sh      the Checkout module, a concept module with no noun: checkouts, the one walk over every checkout
scripts/orch/comments.sh      the Comments module, a concept module with no noun: reading an issue's or a PR's trusted comments once (comments_trusted_read); the rendering lives in orch/comments.py
scripts/orch/filed-finding.sh the Filed finding module, a concept module with no noun: the review label test and the untriaged-finding check autopilot's gate makes
scripts/orch/issue-timeline.sh the Issue timeline module, a concept module with no noun: an issue's comment history, read once and asked for its newest question, latest stop, limit stops, re-entry comments and live handoffs
scripts/orch/liveness.sh      the Liveness module, a concept module with no noun: whether the process behind a record (a claim, a watch) is alive - the run records, the start-time reader, the record-alive rule, the watch pidfile, the session log names, deleted after 14 days
scripts/orch/marked-comment.sh the Marked comment module, a concept module with no noun: the kinds of marked issue comment, writing their first line and the jq prelude recognising them
scripts/orch/session-log.sh   the Session log module, a concept module with no noun: what a phase session's log says about usage limits - one pass over the log, its limit stop, reset, early pause and final reply
scripts/orch/standing.sh      the Standing module, a concept module with no noun: where an autopilot flow's issue stands - the label set, the host id, the read and the claims
scripts/orch/trust.sh         the Trust module, a concept module with no noun: which comments and which PRs orch.sh reads and which issues autopilot runs on - the one filter dropping a comment whose author is not an owner, member or collaborator, the one filter dropping a fork PR, and the issue trust check
scripts/orch/common.sh        the primitives no concept owns (die, capture, ..., and autopilot_active, whether this is an autopilot session, which checkout and handoff ask)
scripts/orch/loader.sh        the module loader, always loaded beside common.sh: the stub table, its per-copy cache under ~/.cache/orchestrator/, the stub dispatch (orch_stubs, orch_stub), orch_load (once per shell) and the ORCH_LOAD_TRACE load trace
scripts/orch/gh.sh            the gh adapter layer (ADR-0033): gh(), the capture pair gh_capture and gh_capture_err, every adapter_* operation, the GitHub limit record its limit handler makes in an autopilot process (the GitHub limit pause and a session's hit file, with the pause put, the pause-file paths and the reset cap), the ORCH_GH_ADAPTER hook
scripts/triage-labels.sh      the triage-label parser and LABELS_DOC, sourced by orch.sh and hook-grilling.sh; its sections in scripts/test/orch/triage-labels.sh
scripts/host.sh               the one host detector: host_detect (environment) and host_from_project_path (hook payload), sourced by orch.sh and hook-common.sh; its sections in scripts/test/orch/host.sh
scripts/flow-state.sh         the Flow state module: state.json's keys, defaults, reading and writing, sourced by orch.sh and hook-common.sh; the state format's owner and the writer of every change after a flow's seed, with a Python reader and seed writer beside it (scripts/orch_py/orch/flow_state.py), pinned to it by the golden state.json files in scripts/orch_py/tests/flow_state/: the reader by those under read/ and refused/, which the state section reads too, and the seed by those under seed/, which only pytest reads
scripts/hook-*.sh             the seven hooks; hook-bash.sh makes the one decision on plugin subagents' and autopilot Bash calls, in order: deny an unquoted pgrep or pkill word under every mode, else deny a plain stdin read under any mode but bypassPermissions, else rewrite the command to close stdin under bypassPermissions; hook-grilling.sh sends only the session's state and points to orch-interview's Closing section, and also runs on UserPromptSubmit for Junie, hook-paste-guard.sh is Claude Code only, hook-paste-stop-guard.sh its Stop half
scripts/paste-guard.sh        the transcript scan and paste check the two paste guards share, sourced by hook-paste-guard.sh and hook-paste-stop-guard.sh
scripts/bash-walk.sh          the command walker the Bash hook sources, sourced by hook-bash.sh
scripts/hook-common.sh        payload reading and dual-host (Claude Code + Junie) output shared by the hooks
scripts/planning-allowlist.sh the planning allowlist and planning records, shared by the edit guard and orch.sh, with a Python copy beside it (scripts/orch_py/orch/planning_allowlist.py) that a pytest parity test pins to it
scripts/autopilot-container.sh the autopilot container's entrypoint: checks the env file, configures git and the permission mode, clones the repo, writes and validates the other autopilot and role settings in it, then execs the watcher; `scripts/test/autopilot_container_test.sh` tests it
scripts/autopilot-up.sh        brings the autopilot compose projects up or rebuilds them from the checkout (how-it-works' Updating the plugin); `scripts/test/autopilot_up_test.sh` tests it
docker/                       the autopilot container: `Dockerfile`, `compose.yaml` and `.env.example` (how-it-works' Autopilot Setup documents them)
scripts/version-bump.sh       the version-bump Action's script: changelog fragments into one version bump (Develop)
scripts/dev/helpers.sh        the helper index: every module or test helper with its one-line purpose (Develop, Test helpers)
scripts/dev/lens-bench.sh     the lens benchmark: run collects headless runs of a lens definition, measure turns them into a Markdown report of per-run cost, coverage, a summary and a diagnosis of the turns spent locating code the spec names (Develop, Measuring a lens)
scripts/dev/section-durations.sh rewrites scripts/test/section-durations.tsv: a full refresh measures every orch_test.sh section, the other suites and shellcheck; `--stale` records only the lines out of date (Develop)
scripts/dev/width.sh          the line-width rule, whole: which files it covers and which lines are past 80 columns; docs_lint.sh's scan_line_width wraps it (Develop)
scripts/dev/hook-edit-width.sh the project's edit hook, registered in .claude/settings.json: width.sh and shellcheck on each edited file and each file a Bash call changed (Develop)
scripts/dev/lens-bench/       the lens benchmark's fixtures, one directory per lens: its spec body, baseline map and snapshot commit
scripts/test/                 shell tests: the suites in all.sh's `suites` list (orch_test.sh is the orch.sh suite's runner), all.sh, and affected.sh, the ticket and branch verification, which runs what a change selects and falls back to all.sh only in the cases its header lists
scripts/test/orch_py_test.sh  the pytest suite's wrapper, run by all.sh and affected.sh outside the durations file: pytest from the /opt/orch-dev venv or python3, its xdist workers drawn from the job pool, its result as a suite's FAIL lines and summary
scripts/test/lens-bench/      lens_bench_test.sh's hand-built benchmark output directories
scripts/test/tally.sh         the assertion tally every suite sources: ok, bad and skip append to a per-run file, so an assertion inside a subshell counts; tally_summary is the ending each standalone suite calls
scripts/test/counting.sh      the counting fixture the orch.sh suite's runner, hooks_test.sh and docs_lint.sh source: counting_bin makes a directory holding a stub, which its caller puts first on PATH, that logs one line per start and runs the real command, counting_starts reads the count, counting_argv_bin makes the stub log only the starts whose joined arguments equal a given string, counting_glob_bin makes it log only those whose padded arguments match a glob, counting_stdin_bin makes counting_bin's stub also record the bytes offered on its stdin, counting_bytes sums them
scripts/test/fails.sh         the failing-command fixture the orch.sh suite's runner and hooks_test.sh source: fails_bin makes a directory holding a stub, which its caller puts first on PATH, that exits with a given status (0 allowed), after an optional stderr line, when its space-padded arguments match a glob, and runs the real command for every other call
scripts/test/test_jobs.sh     the job-count, job pool and priority helpers orch_test.sh, all.sh, affected.sh and section-durations.sh all source: the default ORCH_TEST_JOBS (ORCH_TEST_POOL_PERCENT) and the renice to 10, and the signal-reachable child start (test_jobs_run_child, with its INT/TERM stop) that section-durations.sh and lens-bench.sh use, and the suite start (test_jobs_suite_start, with its start order test_jobs_start_order and children marker test_jobs_held_marker) all.sh and affected.sh start each suite through, orch_test.sh's parallel section start each section child, and section-durations.sh each suite but orch_test.sh
scripts/test/report.sh       the report helpers all.sh, affected.sh and section-durations.sh source: a suite's FAIL block and summary line, the shellcheck summary, the temp-files failure record, and the run's verdict line, whose PASS or FAIL comes from the failed parts recorded
scripts/test/test_tree.sh    how the runners read the test tree, which orch_test.sh, all.sh, affected.sh, docs_lint.sh and section-durations.sh source (harness.sh reaches it through orch_test.sh): SECTION_TITLE_AWK, the section-title rule, suites_read, the reader of all.sh's suite list, suites_unlisted, the runners all.sh's list leaves out, listed, the runners' one membership test of a word in a list, section_files, the noun files of the walk, ledger_fingerprints and ledger_fingerprints_all, the ledger's fingerprints, ledger_states, the ledger's freshness rule, titles_regex, the anchored ORCH_TEST_ONLY pattern for a list of titles, durations_total, tenths_text, the shared tenths formatter, shellcheck_files, SHELLCHECK_CMD, shellcheck_start and shellcheck_join (the pooled shellcheck step), TENTHS_AWK and DURATIONS_AWK
scripts/test/git_env.sh      `test_git_env_clear`, which every suite runner sources and calls first: it unsets git's repo-local variables and the commit-identity variables, so a suite run from a git hook never writes to the caller's repository, and exports GIT_TERMINAL_PROMPT=0 so git never blocks prompting on a PTY
scripts/test/shell_code.awk    the SHELL_CODE_AWK library, the one rule of what counts as code in a shell file: setup.sh, docs_lint.sh, width.sh and the helper index each load it whole
scripts/test/orch/setup.sh    the orch.sh suite's shared setup (helpers used by more than one file) and summary
scripts/test/orch/harness.sh  the harness's own sections: isolation, the section filter, quiet mode, all.sh
scripts/test/orch/common.sh   the bottom-layer check on scripts/orch/common.sh
scripts/test/orch/loader.sh   the loader's sections: orch_load, on-demand loading, the stub table cache, and the entry script's own: the removed mp-skill and suite-cost nouns, the bash version guard, and the death outside a checkout (#931)
scripts/test/orch/<noun>.sh   one file per orch.sh noun (branch.sh, handoff.sh, ...): its sections, after an optional preamble
scripts/test/orch/checkout.sh the Checkout module's sections, named as the module is
scripts/test/orch/host.sh          the host detector's sections (scripts/host.sh), named as the file is
scripts/test/orch/triage-labels.sh the triage-label parser's sections (scripts/triage-labels.sh), named as the file is
scripts/test/orch/comments.sh      the Comments module's sections, named as the module is
scripts/test/orch/filed-finding.sh the Filed finding module's sections, named as the module is
scripts/test/orch/issue-timeline.sh the Issue timeline module's sections, named as the module is
scripts/test/orch/liveness.sh      the Liveness module's sections, named as the module is
scripts/test/orch/marked-comment.sh the Marked comment module's sections, named as the module is
scripts/test/orch/session-log.sh    the Session log module's sections, named as the module is
scripts/test/orch/standing.sh       the Standing module's sections, named as the module is
scripts/test/orch/trust.sh          the Trust module's sections, named as the module is
docs/how-it-works.md          the phases, every command in full, the base branch, hosts, and activation
docs/host-capabilities.md     how each host provides each capability a skill names, and the fallbacks
docs/driver-loop.md           the driver loop (loop steps a-f, its slots, dispatching a subagent) the implement phase and a quick implementation both run
docs/repo-setup.md            everything orch.sh reads from a repo: Standards declaration, verification lines, glossary, ADR directory, triage labels
docs/pr-writing.md            the PR-writing standard: style rules, body and release layouts, and the comment shape every PR body and comment follows
docs/turn-final-reply.md      the turn-final reply procedure and the unattended-printout rule, written once
docs/adr/                     the architecture decision records
docs/agents/                  this repo's agent-skill configuration: issue tracker, triage labels, domain docs, CLI conventions, coding standards
docs/junie/README.md          Junie CLI setup: the AGENTS.md snippet and the per-prompt fallback
docs/junie/AGENTS.md          Junie snippet: standing planning and finding-the-plugin sections (where orch.sh is, what to do when an orch-* skill or agent is hidden), and each skill's custom agents (JUNIE-5493 workaround)
docs/antigravity/README.md    Antigravity CLI setup: native plugin install, direct skill invocation, doctor, and current fallbacks
hooks/hooks.json              hook wiring
```

### Prose for judgment, bash for facts

Reading state, naming branches, resolving the default branch, and validating
handoffs all have one right answer, so they live in `orch.sh` where they
cannot drift between sessions.

## Resolving orch.sh

Only Claude Code expands `CLAUDE_PLUGIN_ROOT` in skills. Junie expands it only
inside `hooks/hooks.json` (which keeps `${CLAUDE_PLUGIN_ROOT}` as is), while
Antigravity CLI uses `PLUGIN_ROOT` in hooks and does not load
`hooks/hooks.json`. Antigravity CLI gives the model each skill's own
directory, so the relative path works directly without a shell probe. Junie
CLI's agent shell has no `JUNIE_EXTENSION_ROOT` either, and Junie does not tell
the model a skill's own directory. So every skill that runs `orch.sh`, other
than a Claude-Code-only one (see below), states the path one way, in this
order: the `ORCH=` line, then the relative path when the host gave the skill's
directory, then the Junie CLI install lookup:

````
```
ORCH="${CLAUDE_PLUGIN_ROOT}/scripts/orch.sh"
```

If `CLAUDE_PLUGIN_ROOT` is unset and the host gave this skill's directory,
`ORCH` is `scripts/orch.sh` two directories above this skill's own directory
(the plugin root). Otherwise run `ls
"$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` (the Junie CLI
install). If it prints one path, `ORCH` is that path. If it prints more than
one, stop and show the human the paths.
````

The Junie step is prose carrying a literal `ls`, not a bash line that sets
`ORCH`, because hosts may not keep shell variables between calls. The glob uses
`$HOME/.junie`, the one install path confirmed so far, and its one-level
`extensions/*/orchestrator` matches the installed extension but not the
marketplace clone under `extensions/marketplaces/`. Keep the relative-path
sentence, the Junie `ls` sentence and the two "If it prints" sentences intact,
in that order, then call `bash "$ORCH" <subcommand>` everywhere else. Do not
copy the scripts into a skill. Commands never run `orch.sh`: each is a thin
route into a skill, usually an `orch-flow` section (see [Naming host
capabilities](#naming-host-capabilities)).

A skill that reads another file under the plugin root names it as
`"${CLAUDE_PLUGIN_ROOT}/<path>"`, and the same file carries a sentence starting
``If `CLAUDE_PLUGIN_ROOT` is unset, the plugin root is``, naming the same
steps the `ORCH` fallback does: two directories above this skill's own
directory when the host gave it, else two directories above the `orch.sh` that
`ls` printed. `docs_lint.sh` fails when a skill or command mentions
`CLAUDE_PLUGIN_ROOT` any other way, runs `orch.sh` without these steps in order
or without `bash`, names the plugin root without both steps in order in that
same sentence, or names a path through a `<plugin root>/` placeholder.

A skill that is Claude Code only, like the quick autopilot, takes a second form
instead. It is marked by its frontmatter `description:` ending in "Claude Code
only." (read from the frontmatter only, never the body; a command is never
marked, so one whose description ends so stays cross-host). Its form is the
`ORCH=` line, then one stop for when `orch.sh` is not at that path, saying the
skill is Claude Code only and needs the full plugin. The stop names `ORCH` or
`orch.sh`, never `CLAUDE_PLUGIN_ROOT`. It leaves out the Junie lookup, the "If
it prints" steps, the relative fallback, the plugin-root fallback sentence and
orch-flow's skills-only stop text. `docs_lint.sh` still requires the `ORCH=`
line of a marked skill that uses `orch.sh`, or the `ORCH` variable written
without braces, and still flags `CLAUDE_PLUGIN_ROOT` outside it, and flags a
marked skill that carries the Junie lookup or any skills-only stop text. Every
other skill and every command stays on the cross-host form above. A marked
skill that names a file under the plugin root defines the plugin root there as
two directories above `ORCH`, since it has no fallback sentence to define it.

## Naming host capabilities

Skills and the agent briefs under `agents/` describe capabilities ("invoke a
skill", "start a fresh subagent", "ask a multiple-choice question") in
host-neutral prose and point at
[docs/host-capabilities.md](docs/host-capabilities.md),
which maps each capability to each host and documents the fallback where a host
lacks one. Never hardcode a host's ask-tool name (`AskUserQuestion`, `ask_user`,
`ask_question`) in `skills/` or `agents/`; `docs_lint.sh` fails on any
occurrence. A phase records every fallback it took in its handoff's **Host
fallbacks** section, which `handoff validate` requires for flows started on
1.0.0 or later (a flow already in progress at upgrade is exempt); an agent
records its own where its brief says. Commands are Claude Code shortcuts only:
each one routes
to a skill, or to one section of it (usually an `orch-flow` section), and holds
no behaviour of its own, so invoking the skill on another host is complete.
`docs_lint.sh` fails when a skill, or an agent that invokes a skill, never
points at the reference, when a skill or agent offers a `/orchestrator:<cmd>`
that has no `commands/<cmd>.md`, or when a command runs `orch.sh` or routes to a
section that does not exist, or when the reference lacks its **Run a subagent
pool**
row and fallback subsection, or a subagent pool site (`orch-quick-autopilot`'s
step 3, an
audit's Hunt step) does not name that capability.

## Command names

A command must not share its bare name with a host built-in command (for
example Claude Code's `/plan`, `/review`, `/status` or `/doctor`), because the
typeahead lists both. `scripts/test/docs_lint.sh` enforces this against its
list of Claude Code built-ins.
