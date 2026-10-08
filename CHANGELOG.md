# Changelog

## 3.19.1

The gh adapter and its test fake carry one copy of each step (#664). The
adapter's relabel, close and PR create take named options in place of comma
lists and placeholder positionals, one `url_number` parses both creates' URLs,
and one `capture` holds the stderr temp-file scaffolding. The fake's
countdowns, comment author and timestamp, close-with-comment and next-number
steps each have one helper, and `orch_test.sh` seeds and reads comments
through one writer and one reader.

## 3.19.0

A second flow or a quick implementation can now run beside an active flow in
a **side checkout**: a git worktree the plugin makes under
`.orchestrator/checkouts/<slug>`, marked as its own, with a session of its
own (#57). `init` and `branch off` refuse beside a flow mid-pipeline with exit
code 3 (#720), and the flow and quick-implementation skills offer a side
checkout on that exit, or up front with `--side` or when asked in words
(#728). The planning message routes Start and Quick implementation to a side
checkout beside an active flow (#729). New `orch.sh side-checkout add`,
`list`, `remove` and `prune` (#722, #724, #726). `archive` in a side checkout
moves the flow into the main checkout's archive before removing the worktree,
never with force (#724). New `/orchestrator:finish` sweeps every finished side
checkout - its PR merged, its tree clean, any flow at `done` - and the same
sweep runs at the start of every `side-checkout add` (#726). New
`/orchestrator:quick-implement [<issue>] [--side]` (#723). `status` lists
every other checkout (#725); `doctor --flow` fails on changes outside the
planning allowlist (#721), and `doctor --env` warns about finished side
checkouts, with `review ready` pointing to `/orchestrator:finish` (#727).

## 3.18.0

A blueprint drawn from a planning session about an open issue now rewrites
that issue as its spec instead of publishing a duplicate (#704). The spec
skill gains a rewrite mode, reached standalone as `/orchestrator:to-spec <n>`:
it replaces issue `<n>`'s body, keeping its title, asks before the rewrite
whether to retire or keep an existing ticket breakdown, and reports the
breakdown `kept`, `retired` or `none` (#706). The planning hook's Blueprint
instructions hand the interviewed issue's number to the spec skill - whether
the human moved its label or answered Skip, and for the issue named under
"It's a different issue" - publish a new issue only without one, and skip
`orch-to-tickets` when the breakdown was kept (#707). New `orch.sh issue ready
<n>` exits 0 when the issue carries the repo's `ready-for-agent` label, and
rewrite mode warns when it does not (#705).

## 3.17.1

Every flow state key is now defined once, in one `STATE_KEYS` table in
`orch.sh` - its read-back default, its init seed and its owner - which
`state get`, `state set` and `init` all read, so adding a key is one row
(#305). `cmd_init`'s comment on `base` now points to `base_set_flow`'s header
rather than restating its rule (#516). One behaviour change: `state set` now
stores a value of digits followed by a newline as a string, like any other
value that is not all digits, where it used to die on jq's `tonumber` error
(#711).

## 3.17.0

`orch.sh default-branch --sha` prints the default SHA - the full SHA of
`origin/<default>` as it stands, without fetching - and the finding-triage
skill reads it after its scan instead of running `git rev-parse` itself
(#442). `default-branch` now refuses any argument other than `--sha`.
`finding-triage scan` warns on stderr when a severity's filed-finding list
reaches the issue-list limit, `ISSUE_LIST_LIMIT` (1000), which `pr release`'s
merged-PR list now shares (#437). The rest tidies finding triage without
changing behaviour: the category helpers `category_for_axis` and
`category_other` (#435), one emitter for the scan's line (#436), one
`plugin_cmd` behind `flow_cmd` and `finding_triage_cmd` (#580), and one
review-label scan under `has_review_label` and `has_filed_severity_label`
(#581). The docs lint's closer-filing check now states its contract: the
closer's body format, not orch.sh's parser (#441).

## 3.16.1

The planning message reaches the session again in two cases where it was
silenced (#640). A `SessionStart` hook on source `clear`
(`hook-session-start.sh`) deletes the session's planning markers, so a
planning run after `/clear` (Junie: `/new`) gets the message and the edit
guard is no longer armed in the fresh context; compaction keeps them.
Planning beside an active flow no longer gets silence: it gets the planning
rules, with a closing that names that flow - its issue, or its slug with "has
no issue yet", and its phase - and states two branches: about that flow,
point to `/orchestrator:next` or `/orchestrator:redo` (on Junie, the orch-flow
skill file's **Next phase** and **Redo** sections); otherwise the
interviewed-issue step and the route question, where Blueprint only is the
one route that runs in this checkout and a flow or a quick implementation
must start from a separate checkout. Junie's plan-confirmation message
carries the same two branches. ADR-0008 and ADR-0022 gain notes.

## 3.16.0

The implement phase and quick implementation build a ticket breakdown's
frontier in parallel: up to the clone's parallel cap of ready tickets at
once (`orchestrator.parallel`, default 3, read with `orch.sh parallel
show`), each ticket subagent in the background on its own ticket branch in
its own ticket worktree under `.orchestrator/worktrees/`. New `orch.sh`
commands `ticket-worktree add`, `list` and `remove` manage the worktrees, and
`ticket merge` lands a finished ticket branch on the flow's branch by a
rebase and a fast-forward before the ticket closes; a ticket whose merge
conflicts is redone alone. The implementer takes an optional `Worktree:`
prompt line. The combined branch is verified once after the frontier is
exhausted, and that run fills the implement handoff's Verification section
or a Verification heading in the quick implementation's PR body. A collapsed
breakdown, a cap of 1, or a host without background subagents (Junie, a new
**Start a background subagent** fallback) keeps the one-at-a-time loop.
Leftover ticket worktrees stop the next run, fail `doctor --flow`, and make
`archive` refuse. ADR-0036 records why, superseding ADR-0010 in part (see
issue #618).

## 3.15.0

Every fix of a defect is now a root-cause fix: it names the cause, searches
for every site the cause acts at, and fixes them all. The implementer has a
new **Root-cause fixes** section - triggered by a `bug` label, a spec's
**Root cause** subsection, or a ticket that fixes a defect - and its fetch
now reads labels and that subsection; the fix commit carries a `Root cause:`
paragraph. The fixer's blocking fix is the smallest fix that removes the
cause; a cause out of reach gets the symptom fix and is filed as a major,
`root cause out of reach`. A bug spec gains a **Root cause** subsection, the
interview settles the cause as a design decision, the Spec reviewer treats
an unfixed listed site as missing, and the Standards reviewer has a new
**Root-cause check**. Major and nit fixes are unchanged. ADR-0035 records
why (see issue #659).

## 3.14.0

Quick implementation runs hands-off: it asks nothing between its linked issue
and its PR. It always runs a spec review, in `orch-spec-review`'s new
**Unattended spec review** mode, which prints its batch and applies every
recommendation - decision items and the ticket follow-up included, retiring
included - and opens its changelog comment by saying so. It then breaks the
issue down with `orch-to-tickets`' new **Unattended breakdown**, which checks
its own draft instead of quizzing. The PR body lists each decision item the
review took under **Spec review decisions**. The planning session's closing
question now says quick implementation is hands-off and for small changes.
A human-run spec review, the flow's spec phase and the Blueprint route still
ask. ADR-0034 records why (see issue #616).

## 3.13.5

`CLAUDE.md` has a new `## Layout` section saying where the shell scripts
(`scripts/`) and tests (`scripts/test/`) live, and that there is no top-level
`tests/` and `hooks/` holds only `hooks.json`, so subagents stop guessing
paths before reading the README (see issue #609).

## 3.13.4

The repo has a written coding standard, `docs/agents/coding-standards.md`,
pointed to from `CLAUDE.md`'s new `## Coding standards` section. Every
non-fatal `orch: ` message now goes through a new `warn` helper, and docs lint
flags a script message that names `orch.sh redo` or `orch.sh abort` literally
instead of through `flow_cmd`: the base-set refusal now names the host's redo
command. `cmd_ticket_retire`'s local `note`, which shadowed the `note` helper,
is renamed `comment_file` (see issue #608).

## 3.13.3

`orch.sh review terminal` reads a review record's `## Terminal state` the way
markdown is written: blank lines under the heading are skipped, the first line
is trimmed, and `stop` may carry its reason on the same line after `-`, `–`,
`—` or `:`. Any other non-empty section now classifies as `malformed`, printing
the expected shape, instead of silently reading as `interrupted`. `redo review`
refuses a malformed record and says to rewrite its first line, and
`doctor --flow` FAILs on it with the same remedy (see issue #604).

## 3.13.2

`orch.sh issue triage` no longer refuses a filed finding that finding triage
has already moved: one carrying `ready-for-agent`, `ready-for-human` or
`wontfix` takes the ordinary path, so a planning interview can move a
`ready-for-human` finding to `ready-for-agent` with `--override`, keeping its
`review:<severity>` and category labels. A finding in `needs-triage`, in
`needs-info`, or with no triage-state label is still refused, whatever
`--override` says, and the refusal now says it is not yet triaged and names
finding triage (see issue #586).

## 3.13.1

`orch.sh ticket publish --blocked-by` and `ticket block`/`unblock --by` refuse
an issue-number list with an empty entry (`1,,2`, `,5`, `5,`) instead of
skipping it, and a repeated `--blocked-by` is refused rather than replacing
the first. Publish's blocked-by readback retries a transient read failure
(see issues #585 and #594).

## 3.13.0

A planning interview about an open issue - the **Interviewed
issue** - offers, before the route question, to move that issue to the
repo's `ready-for-agent` triage label, so `init --issue` can adopt it without
a manual relabel. The new `orch.sh issue triage <n> [--override]` does the
move: one relabel, verified by reading the labels back, then one comment. It
refuses closed issues and filed findings, and exits 2 on `wontfix` or
`ready-for-human` until the human approves `--override`. A failed move warns
and the close carries on to the route question. Label names follow the
repo's triage-labels doc (see issue #571).

## 3.12.3

`orch.sh` reaches GitHub through need-based adapter operations - issue, PR,
label, comment, CI, sub-issue, dependency and repo reads and writes - instead
of raw `gh` calls, and the test suite fakes GitHub at those operations with
one store-backed, in-process fake, pinned to the real adapter by contract
tests; `stub_gh` and `GH_STUB_*` are gone (ADR-0033). Output and exit codes
are unchanged, with these edges: `issue create` and `pr create` fail when
`gh` succeeds but prints no URL, and `ticket block`, `unblock`, `publish` and
`retire` report the link or edge failure, not a separate "could not read
issue" line, when an issue's database id cannot be read (see issue #280).

## 3.12.2

`orch.sh finding-triage scan` reports a finding whose lines it followed to
the default branch, untouched since the filing while the file changed only
elsewhere, as `unchanged` - no longer as `changed` with a commit that never
touched those lines. It falls back to the newest commit touching the file
only when `git log -L` can't follow the range, and the finding-triage skill's
result bullets say so (see issue #433).

## 3.12.1

The fixer's PR-body check has a defined path when `orch.sh pr fetch` or
`pr update` fails: the step ends without a retry, the failure is not a
finding, and the loop goes on. The review record's **PR body** section gains
a fourth shape, `Not updated - <reason>`, which after a failed `pr update`
lists the corrections that did not land, and the fixer's return line reports
it (see issue #448).

## 3.12.0

`orch.sh` works on one GitHub repo, made explicit: `GH_REPO` when the caller
sets it, else the checkout's `origin` remote - never the repo `gh` would pick
by default, so in a fork whose `gh` default points upstream nothing is read
or written upstream. Every `gh` call in `orch.sh` and `doctor.sh` is pinned to
it, `orch.sh repo show [--name]` prints it, and doctor reports it, warning
when `gh`'s default repo differs. The flake rerun goes through the new
`orch.sh review rerun <pr>`. Skill and agent prose pins its own `gh` calls
with `-R`, the closer posts its PR comment through `orch.sh pr comment`, the
reviewer prompts carry an `orch.sh:` line, and the docs linter flags any `gh`
call in a skill or agent that lacks `-R` (see issue #520).

## 3.11.2

`orch.sh finding-triage scan` and `apply` give their locals names that say
what they hold: `new_start`/`new_end` for the mapped line range,
`resolved_sha` for the resolved filing commit, `default` for the default
branch, and `stale_category` for the category label to remove (see issue
#439). Behaviour is unchanged.

## 3.11.1

`orch.sh finding-triage apply` handles its possibly-empty list of labels to
remove with one idiom per job: close-fixed guards its relabel on the list's
count, every expansion uses the same bash-3.2-safe splice, and the declaration
sits with the function's other locals (see issue #438). Behaviour is
unchanged; tests now cover a finding applied without `needs-triage`.

## 3.11.0

`orch.sh base set <branch> --flow` corrects the active flow's own base branch,
leaving the checkout's setting alone, while the flow has no branch: before
`branch create`, or after `redo review` retires it. `branch create`'s
missing-base error now names it, and orch-flow's implement phase offers it
(see issue #479).

## 3.10.4

`GLOSSARY.md` now defines **Default SHA**, **Source PR** and **Category**, the
terms `orch-finding-triage` relies on, and its **Finding triage** entry names
the category kept or flipped (see issue #443).

## 3.10.3

`orch.sh`'s branch-name check drops its separate empty-name test and relies on
`git check-ref-format --branch` alone, which already rejects an empty name (see
issue #486). Behaviour is unchanged: an empty name is still no valid branch
name, so `default-branch` falls back exactly as before.

## 3.10.2

`orch-spec-review`'s **Tickets follow the spec** now says how a failed `issue
update` stops the review before comparing a failed `ticket block` or `ticket
unblock` to it (see issue #501). The sentences are reordered; the meaning is
unchanged.

## 3.10.1

`orch.sh finding-triage scan` no longer dies silently with exit 141 when a
filed finding's file has diff hunks after the finding's line (see issue #502).
The line mapping's awk stops reading the diff early, and under `pipefail` the
`git diff` feeding it took SIGPIPE and ended the whole scan; that SIGPIPE is
now let through. Line mapping and the scan's output are unchanged.

## 3.10.0

A published ticket's blocking edges can now be repaired in place (see issue
#488). `orch.sh ticket block <n> --by N,N,...` adds a blocking edge on open
ticket `<n>` for each sibling blocker it lacks, and `ticket unblock <n> --by
N,N,...` removes each one it has; both read the edges back, retrying once on a
mismatch, and rewrite the ticket's `## Blocked by` section to match, leaving the
rest of the body byte for byte. A repeat changes nothing, and re-running a
failed run finishes it. `orch-to-tickets` repairs wrong edges with these
commands, never ad hoc `gh`. `orch-spec-review` no longer recommends retiring a
breakdown when the accepted edits change only which open tickets block which:
each edge change is one item in its ticket question, applied with `ticket
block`/`unblock` after any text edit to the same ticket, and logged as one
changelog line per edge. Adding, removing or re-ordering slices still
recommends **Retire and break down again**. `GLOSSARY.md` defines **Blocking
edge**.

## 3.9.2

The base branch no longer picks up a tool manager's noise (see issue #465).
`orch.sh` exports `MISE_QUIET=1`, so a mise shim around `gh` stays silent, and
`default_branch` accepts an answer only when it is a valid branch name: a
multi-line answer, or the output of a `gh` that failed, falls through to
`origin/HEAD` and then to `main` instead of being recorded as the base.

## 3.9.1

Whether a severity gets filed is now answered in one place, an
`is_filed_severity` helper built on `FILED_SEVERITIES` (see issue #434).
`review file` and finding triage's single-issue check both call it, and
`review file`'s usage line and refusal message list the filed severities from
the constant rather than by hand. No behaviour changes.

## 3.9.0

The implementer's acceptance self-check now also names, for each source file
its commits changed, the test that exercises it (see issue #425). A file no
test loads or runs is covered then and there if it can be; one it cannot cover
is listed on the report's `Criteria` line after `untested:`, and orch-flow's
implement handoff carries it under **Unmet criteria**, so the review loop's
Spec axis judges it like an unmet criterion. The report stays five lines.

## 3.8.0

`review ci` no longer pays its 60-second grace in a repo with no CI (see issue
#474). Before waiting, it looks for evidence of CI: workflow files in the PR
head, required checks on the base branch (classic protection or a ruleset),
and any check or status on an earlier PR commit or the base branch tip. With
none of them, a PR with nothing reported is `none` at once; any signal
present, or one it cannot read, keeps the grace. The grace itself now counts
from the head's push, read from the remote-tracking ref's reflog, rather than
from the call. `none` gains a detail line naming which path reached it. See
ADR-0032.

## 3.7.1

This repo's `GLOSSARY.md` now follows upstream's glossary layout (see issue
#462): an `# Orchestrator` title, one `## Language` section, and the terms
grouped under six `###` subheadings, each as a `**Term**:` entry. No term's
name or text changed.

## 3.7.0

The skills and agents now point at `GLOSSARY.md` and `GLOSSARY-MAP.md` instead
of `CONTEXT.md` and `CONTEXT-MAP.md`, following upstream's rename (see issue
#461). Rename your own repo's glossary files to match, with `git mv` to keep
their history. Until you do, nothing breaks: the edit guard and `init` still
protect `CONTEXT.md` and `CONTEXT-MAP.md` as planning records, alongside the
new names. This repo's own glossary is now `GLOSSARY.md`.

## 3.6.0

An interview round now defines new terms and gives the reason for each
recommendation (see issue #424). The first time a question uses a term the
user has not yet met in the interview - a config key, a glossary term, an
invented name - it carries a one-line definition inline, and every
**Recommended** line states its reason in one clause. The round format's
template in `orch-interview` shows both, followed by a worked example round.

## 3.5.0

The Testability lens of a spec review now reports a step that changes
persistent state - a file, a commit, an issue or label, a recorded state
value - but names only its success path (see issue #421). Such a step must
name what happens on failure and in every mode the spec mentions (a dry-run,
a debug run, a flag), and the Testing Decisions must call for a test that
asserts each branch. The rule is the lens Brief's new item (c); its findings
carry the `(judgement call)` label, a heuristic the human weighs.

## 3.4.0

A standalone review pass no longer brings back findings an earlier pass on the
same PR already declined (see issue #418). Before it fixes anything, it reads
the declines of every earlier review pass on the branch's PR - the PR body's
**Review** heading (a quick implementation's pass) and every earlier
standalone-pass comment - through the new `orch.sh pr comments <file>` and the
existing `pr fetch`. It drops each finding that names the same file and makes
the same claim as an earlier decline, line numbers ignored, and lists it under
a new **Previously declined** heading in its PR comment, between **Review** and
**Host fallbacks**. The reviewers stay fresh: their prompt is unchanged. A
review pass's decline line now also records the finding's claim:
`` `file:line` - <claim> - <reason> ``. `pr comments` writes every comment on
the current branch's open PR in `issue comments`' format, exiting 1 when the
branch has no open PR (the pass behaves as before) and 2 when GitHub cannot be
read (the pass stops). New orch_test and docs_lint checks cover both.

## 3.3.4

The Junie snippet, `docs/junie/AGENTS.md`, gains a permanent section,
`## orchestrator plugin: finding the plugin` (see issue #416). It carries the
`orch.sh` lookup as the skills state it, says the plugin root is two
directories above that `orch.sh`, and says to resolve both once per session.
It also says a hidden orch-* skill or agent is not a missing dependency: a
hidden skill is read from `skills/<name>/SKILL.md` and followed in the
session, and a hidden agent is started as a fresh general-purpose agent
briefed with `agents/<name>.md`, each per its `docs/host-capabilities.md`
section and recorded under **Host fallbacks**. Re-append the snippet to
`~/.junie/AGENTS.md` to pick it up. A new docs_lint rule pins the section.

## 3.3.3

`orch.sh doctor --flow` no longer flags a `done` flow whose branch was deleted
after merge (see issue #415). In phase `done`, a branch gone locally reports
`ok    branch: <branch> gone - expected after merge` instead of a FAIL, and a
branch not on origin reports `ok    upstream: none - expected after merge`
instead of a warn with a `git push -u origin` remedy. Every other phase reports
exactly as before.

## 3.3.2

Issue and PR reads no longer go through piped `--comments`, which prints only
the comments when stdout is not a terminal (see issue #414). The implementer's
ticket fetch, to-tickets' parent fetch and `docs/agents/issue-tracker.md`'s
read conventions now use one `gh issue view --json title,body,comments` (or
`gh pr view --json`) call written to a temporary file outside the repo, so the
title and body always arrive and a large issue cannot overflow tool output.

## 3.3.1

`.scratch/`, where planning drafts land, is now kept out of `git status`
alongside `.orchestrator/` (see issue #423). `orch.sh init` and `orch.sh
review-pass begin` add both lines to `.git/info/exclude`, never writing one
twice. Doctor's exclude check covers both: still one warn-only check, whose
warning names each missing line and whose remedy appends only those.

## 3.3.0

The review loop's fixer now re-checks the PR body after each fix commit (see
issue #420). A new step between **Push** and **Write the record** reads the
body with `orch.sh pr fetch`, checks it against `git diff <base SHA>..HEAD`,
and rewords or removes every helper, function, file or stated reason the diff
no longer supports, writing the result back with `orch.sh pr update`.
Statements the diff cannot settle are left alone. The check runs only when the
fixer made a commit, and adds none of its own.

Two new `orch.sh` commands back it: `pr fetch <file>` writes the current
branch's open PR body to a file, and `pr update <file>` replaces it, refusing
a file whose first line is not the PR's existing `Closes`/`Refs #<issue>`
line.

Each iteration's review record gains a `## PR body` section between
`## Waiting to be filed` and `## CI`: one line per corrected statement,
`None`, or `Not checked - no commit`.

A quick implementation now checks its drafted PR body the same way before
step 7's `pr publish`, against `git diff <base SHA>..HEAD` with the base SHA
from `orch.sh branch base-sha`, correcting the body file in place. No live
PR is edited and nothing is recorded, since the body is fixed before anyone
sees it.

## 3.2.0

The plugin now triages its own filed findings (see issue #426). A new
`/orchestrator:finding-triage` command, skill `orch-finding-triage`, takes the
open `review:major` and `review:nit` issues still labelled `needs-triage`,
checks each against the default branch, and puts one numbered batch of
proposed outcomes per source PR to the human: close as completed,
`ready-for-agent`, `ready-for-human`, or `wontfix`. It applies them only once
the human answers, and never grills or edits the glossary or ADRs.

Two new `orch.sh` commands back it. `finding-triage scan [<issue> | --pr <n>]`
is read-only: it fetches the default branch and prints one tab-separated line
per finding, saying whether the code it names is `unchanged`, `changed` (with
the commit), `gone`, or `unknown` (with the reason). `finding-triage apply`
is finding triage's one write to GitHub: it posts the comment, moves the
issue out of `needs-triage`, and closes or labels it.

`orch.sh review file` now takes `--axis <spec|standards>` and labels every
filed finding with a category from it: `bug` for a Spec finding, `enhancement`
for a Standards one. The closer passes the axis.

## 3.1.6

`orch-review`'s **Review pass** step 3 now points to **Starting an agent**
only for how to start one (see issue #354). It no longer names the fallback
a host takes or the loop's rule for recording it, so the paragraph closing
**Review pass** is the one place that says which fallback a host takes and
where a pass records it. Step 3's paragraph is also reflowed. Behaviour does
not change.

## 3.1.5

`orch-review`'s **Standalone review pass** now runs **Review pass** steps 1
to 6 with the human's issue instead of restating its begin and base-SHA
steps, so those are told once (see issue #351). **Review pass** step 1 now
defines `<prefix>`. The standalone section keeps only what differs: where
the issue number comes from, the active-flow note on `begin`'s message,
commit and push, the report, and the edit-guard note. Behaviour does not
change.

## 3.1.4

`orch.sh`'s exit-2 failures in `pr comment` and `ticket exists` now go
through one `die2` helper, a sibling of `die` that exits 2, instead of seven
hand-written `printf 'orch: ...' >&2; exit 2` pairs (see issue #347). Their
stderr, exit status and stdout do not change, and new tests pin each one.

## 3.1.3

The README's Layout row for `skills/orch-spec-review/` now names the
review's first step, the consolidation of the issue's comments, ahead of
its lenses (see issue #369).

## 3.1.2

The header comment on `orch.sh pr comment` no longer claims its exit codes
work as `ticket exists` signals them (see issue #353). It states the
command's own contract - 0 posted, 1 no open PR, 2 everything else - and
names the one rule the two share: a GitHub that cannot be read exits 2,
never 1. Behaviour does not change.

## 3.1.1

`orch.sh state set` now stores `true` and `false` as JSON booleans, matching
what `init` seeds, so `flake_rerun_used` keeps one type in `state.json` (see
issue #397). `state get` falls back to a key's default only for a null or
missing value, so a stored `false` reads back as `false` for every key.

## 3.1.0

A spec review on an issue that already has a ticket breakdown now brings that
breakdown in line with the edits the human accepts (see issue #382). When
those edits touch an open ticket, the review asks one more question: apply
proposed edits to the touched tickets, or retire the breakdown so the issue
is broken down again - by the flow's spec phase, or by the standalone review
itself. Closed tickets are never edited, only listed. The outcome is recorded
in a new **Tickets** section of the review's changelog comment. A retired
ticket's comment now says its spec changed rather than naming a redo, and the
new `orch.sh ticket list <parent>` prints every sub-issue with its state.

## 3.0.2

The README's Layout row for `skills/orch-interview/` no longer says the
skill ends on the closing question: the planning hook's message asks it, and
the skill defers to that message (see issue #333).

## 3.0.1

The glossary now defines the spec review's **consolidation item**, and
`CONTEXT.md` and the `orch-spec-review` skill call it that instead of a
"proposed fold"; "fold" stays a verb (see issue #365).

## 3.0.0

Breaking: the planning entry point is renamed `interview`, so that typing
`/plan` no longer lists the plugin command beside Claude Code's built-in
`/plan` (see issue #373). There is no deprecated alias: the old names no
longer exist, and on Junie the old entry points no longer fire the planning
hook.

Migration - update any muscle memory, notes, or scripts that name them:

| Old name              | New name                   |
| --------------------- | -------------------------- |
| `/orchestrator:plan`  | `/orchestrator:interview`  |
| `orch-plan`           | `orch-interview`           |

- The skill still triggers on its own when you say "plan this" or "let's
  plan", and the interview, the planning message and the edit guard are
  unchanged. "Planning session" stays the glossary term, and the plan phase
  and its `01-plan.md` handoff keep their names.
- The planning hook matches `Skill(orch-interview)` on Claude Code, and
  `orch-interview` (any scope) or `/orchestrator:interview` on Junie. A bare
  `/interview` is not ours and fires nothing.
- The README's `## Commands` section gains an authoring rule: a command must
  not share its bare name with a host built-in command. The existing clashes
  (`/orchestrator:review`, `/orchestrator:status`, `/orchestrator:doctor`)
  are tracked in issue #374 and left unchanged for now.
- The skill-name guard in the test suite now flags the old command and skill
  names.

## 2.10.0

- The spec review now reads an issue's comments as well as its body (see
  issue #360, and ADR-0030). Before the lenses' findings, the session running
  the review proposes one **consolidation item** per comment that says
  something the body does not - a triage agent brief, a follow-up - as
  concrete body text. These come first in the batch, under a
  **Consolidation** heading, and are answered under the same one question as
  the lens findings. The review's own `## Spec review` changelogs are
  skipped. The changelog gains a **Consolidation** section ahead of the lens
  headings. The lenses read the comments too: a gap a comment fills is not a
  finding, and a comment contradicting the body or another comment is. A
  failed comments fetch stops the review, as a failed body fetch does.
- New `orch.sh issue comments <n> <file>` and `orch.sh spec comments <file>`,
  which write every comment of an issue to a file, each opened by a
  `<!-- comment @<login> <createdAt> -->` marker line. No comments: an empty
  file. `spec comments` refuses a done flow, as `spec fetch` does.

## 2.9.0

- A default `redo spec` now retires the kept issue's ticket breakdown before
  it steps the flow back, so the redone spec phase breaks the spec down again
  instead of silently keeping stale tickets (see issue #334). Each old
  sub-issue is closed as not planned if still open, commented on, and
  unlinked from the issue; a collapsed `## Ticket` section is cut from the
  issue body. If GitHub fails while retiring, `redo spec` dies with the phase
  still `implement`, and a re-run resumes. `--new-issue` is unchanged.
- New `orch.sh ticket retire <parent>`, which does that retirement. A repeat
  on an already-retired breakdown changes nothing.
- `ticket exists` no longer counts a `## Ticket` line inside a code fence as
  a collapsed breakdown, the same heading `ticket retire` cuts.

## 2.8.1

- Quick implementation's step 6 no longer restates the review pass's own
  rules - what `review-pass begin` prints, why it refuses, and the
  fails-twice retry - and leaves them to `orch-review`'s **Review pass** (see
  issue #350, and ADR-0029). It still stops before opening the PR when the
  pass stops.

## 2.8.0

- A **review pass** - one look by the two plugin reviewers with no loop
  around it - is defined once, in the `orch-review` skill's **Review pass**
  section (see issue #341, and ADR-0029). Quick implementation's step 6 runs
  it instead of its own copy, so its pass number now counts up per branch and
  it refuses an issue or branch an active flow holds.
- New `/orchestrator:review <issue>`: a standalone review pass of the current
  branch against an issue, outside any flow. The session fixes what it agrees
  with in one commit, pushed when the branch has an upstream, and posts the
  findings it declines and any host fallbacks as one comment on the branch's
  open PR, or reports them in the session when there is none.
- New `orch.sh review-pass begin <issue>`, which guards the pass and prints
  its numbered report prefix under `.orchestrator/review-pass/<branch>/`, and
  `orch.sh pr comment <file>`, which posts a file on the current branch's
  open PR (exit 1: no open PR; exit 2: GitHub could not be read).
- Removed: `orch.sh quick path`. Reports already under `.orchestrator/quick/`
  are left where they are.

## 2.7.0

- The plugin no longer requires `mattpocock-skills` (see issue #326, and
  ADR-0028). `orch-to-spec` and `orch-to-tickets`, adapted from
  mattpocock-skills 1.2.3, write the spec and break it into tickets, and are
  usable standalone as `/orchestrator:to-spec` and
  `/orchestrator:to-tickets <issue>`. `orch-plan` (`/orchestrator:plan`) is the
  plugin's own planning entry point; mattpocock's `grilling`, `grill-me`,
  `grill-with-docs`, and `wayfinder` still start planning when installed.
- The planning session's closing question gains a third option, **Blueprint
  only**: publish the spec, offer a spec review, publish the ticket breakdown,
  then stop. A flow adopting the issue, or a quick implementation linking it,
  skips the breakdown that already exists, decided by the new
  `orch.sh ticket exists <parent>`.
- `orch.sh issue publish` applies the `ready-for-agent` role's label and
  verifies the title and label by readback, dying after one failed retry.
- No setup step: a missing `docs/agents/` falls back to GitHub and the
  canonical triage label names. Doctor no longer checks for mattpocock-skills
  or `issue-tracker.md`, and a missing `triage-labels.md` is not a failure.
- Removed: `orch.sh mp-skill` and `ORCHESTRATOR_MATTPOCOCK_ROOT`, which is now
  ignored if set.

## 2.6.8

- The docs linter reads markdown sections through one `md_section` reader,
  and the lens agents' `## Brief` check now uses it (see issue #297). Its
  checks and messages are unchanged.

## 2.6.7

- `phase advance` names the out-param it hands the `require_*` presence
  checks `_unused`, so it reads as discarded (see issue #308).

## 2.6.6

- orch-flow's rule against hand-editing `.orchestrator/state.json` now also
  says `issue`, `budget`, and `flake_rerun_used` change only through
  `orch.sh state set` (see issue #313).

## 2.6.5

- `redo spec` now names its retire directory
  `handoff/pre-redo-spec-YYYYMMDD-HHMMSS/`, the same UTC timestamp shape
  `archive` uses, instead of `…THHMMSSZ` (see issue #312). One `dir_stamp`
  helper in `orch.sh` owns that shape for both commands. Archive directory
  names are unchanged.

## 2.6.4

- `handoff validate` on a missing file now prints `FAIL  handoff not found:
  <file>` on stdout and exits 1, the same shape as an invalid handoff, instead
  of dying. `phase advance` on a missing handoff keeps that FAIL line, and its
  die line now gives only the remedy: `write <file> before leaving the <phase>
  phase` (see issues #316, #309). Both commands share one `handoff_check`
  helper for the not-found check and the FAIL-line relay.

## 2.6.3

- `redo review` and `redo spec` retire their stale handoffs into exactly the
  directory they name, so `redo review`'s implement handoff always pairs with
  `review/pre-redo-N/` (see issues #304, #310). If that directory already
  holds one of the handoffs, redo stops with a message naming it and moves no
  handoff. Its earlier steps have already run by then (for `redo review`: the
  branch retire, PR close, ticket reset and `review retire`; for
  `redo spec --new-issue`, the issue close).

## 2.6.2

- Internal: the phase boundary's `Next:` line is now named by
  `next_phase_cmd`, beside `flow_cmd`, so host-aware command naming lives in
  one place (see issue #307). No output change on any host.

## 2.6.1

- The docs linter no longer pins or bans phrases outside a copy-match (see
  issue #290, ADR-0027). The skills-only stop text is checked only by its
  copy-match against orch-flow's, which is flagged when it carries none. The
  bans on naming the Skill or Agent tool as the step and on `no host can` are
  dropped, and the `no plugin commands` requirement becomes a route check:
  each `/orchestrator:<cmd>` a skill or agent offers must have a
  `commands/<cmd>.md`.

## 2.6.0

- A phase change now validates its handoff (see issue #279). New
  `orch.sh phase advance` leaves spec or implement only once the handoff it
  writes for the next phase validates and the state that phase needs is
  recorded; on a FAIL the phase stays. It refuses at review (use
  `review ready`) and at done. `orch.sh phase boundary` prints the block that
  ends a phase with the host's `Next:` line, and `orch-flow` relays both
  verbatim instead of composing the boundary itself.
- `orch.sh state set` accepts only `issue`, `budget`, and `flake_rerun_used`.
  Any other key, `phase` included, is refused with a message naming the
  command that owns it, so the phase moves only through `phase advance`,
  `review ready`, and redo.
- Every state read goes through one getter with one table of per-key
  defaults. Two visible changes: `state get flake_rerun_used` prints `false`
  rather than an empty line when the flag is unset, and `state get` on a key
  the table does not know now fails (exit 1, `unknown state key: <key>`)
  where it used to print an empty line.
- Redo retires the handoffs it makes stale: `redo review` moves
  `03-implement.md` into `.orchestrator/handoff/pre-redo-N/`, and `redo spec`
  moves `02-spec.md` (and `03-implement.md`) into
  `.orchestrator/handoff/pre-redo-spec-<UTC timestamp>/`.

## 2.5.5

- The orch.sh test suite is split in two (see issue #278, ADR-0027). The
  structural docs rules moved to a new linter, `scripts/test/docs_lint.sh`,
  which also checks required headings and that every backticked `orch-<name>`
  resolves to a skill or agent. The phrase pins and removed-text assertions
  were dropped, and the handoff templates in `orch-handoff` are now checked
  against `handoff validate`. Tests and docs only; no behaviour change.

## 2.5.4

- The glossary's **Finding** entry names its two sources about the change
  together (see issue #249). Docs only; no behaviour change.

## 2.5.3

- The `03-implement.md` handoff template calls the Spec axis by its glossary
  name instead of "Spec review axis" (see issue #241). Docs only; no behaviour
  change.

## 2.5.2

- `orch.sh help` says the `spec` ops refuse once the flow is done and points at
  `issue <op> <n> <file>` (see issue #226). Help text only; no behaviour change.

## 2.5.1

- The Redo section of `orch-flow` says why redo skips the confirmation Abort
  asks for (see issue #62): abort ends the flow with no successor phase, while
  redo always leaves a live flow behind and every transition it makes can be
  undone. Docs only; no behaviour change.

## 2.5.0

- The fixer and closer have tool allowlists (see issue #262, ADR-0026). Both
  declare `tools: [Read, Edit, Write, Grep, Glob, Bash]`, the implementer's
  list, so neither can start sub-agents, invoke a skill, or block on a human.
  The fixer builds a blocking behaviour fix test-first from its own adapted
  copy of `tdd`'s rules instead of invoking `mattpocock-skills:tdd`, and
  `doctor` no longer checks that `tdd` is installed. A test fails if any
  agent loses its `tools:` list or lists `Agent`, `Skill` or `AskUserQuestion`.

## 2.4.0

- On Junie, planning is a nudge, not a guard (see issue #266, ADR-0025). A
  Junie grilling session no longer arms the edit guard, so source edits are
  allowed; the planning message and the closing question on `Implement the
  suggested plan` keep working. The `PreToolUse` `Read` lift ADR-0023 added is
  removed, and the guard's denial names only the `orchestrator:orch-quick-implement`
  Skill call. `docs/junie/AGENTS.md` gains a standing planning section: no
  source edits while planning, and glossary and ADR wording written into the
  plan. `orch.sh init`'s working-tree check is the Junie backstop, and doctor
  reports the edit guard as a capability Junie lacks. Claude Code's guard is
  unchanged.

## 2.3.7

- Junie users can append `docs/junie/AGENTS.md` to `~/.junie/AGENTS.md` (see
  issue #264). It works around
  [JUNIE-5493](https://youtrack.jetbrains.com/issue/JUNIE-5493), whose
  capability filter hides the plugin's custom agents, by stating which agents
  each skill needs. The README gives the append command, and naming the agent
  in your own prompt stays as a fallback. Remove the marker-wrapped snippet
  once JUNIE-5493 is fixed.

## 2.3.6

- Every agent's `tools:` line is a YAML flow list, which Claude Code and Junie
  CLI both read as the allowlist (see issue #204, ADR-0024). On Junie a
  native start of the implementer, whose comma-form list named Skill, got no
  tools at all. The implementer no longer uses the Skill tool: it builds
  test-first from its own adapted copy of `mattpocock-skills` 1.2.3 `tdd`'s
  rules, with no `mp-skill tdd` route. The fixer still invokes `tdd`.

## 2.3.5

- Quick implementation lifts the edit guard on Junie (see issue #260,
  ADR-0023). Junie's `PreToolUse` now carries `session_id`, so the planning
  marker arms the guard there, and nothing on Junie could lift it. The
  quick-implement hook also runs on `PreToolUse` `Read`, and deletes the
  session's marker on a read of this install's
  `skills/orch-quick-implement/SKILL.md` - not a repo checkout's copy. The
  guard's planning denial names both ways to lift it. Doctor no longer
  reports the edit guard as missing on Junie, only as unverified.

## 2.3.0

- Planning records glossary and ADR changes in the spec instead of editing
  them (see issue #186, ADR-0022). `CONTEXT.md`, `CONTEXT-MAP.md` and
  `docs/adr/` leave the planning allowlist: the edit guard denies an edit to
  one while planning with a reason saying to write the exact wording into the
  plan, and `init` refuses a dirty one under its own heading with the same
  redirect. The `01-plan.md` template asks for such changes under
  **Decisions** as verbatim replacement text, and quick implementation puts
  them in the linked issue's body.
- The edit guard and the grilling hook treat a flow at phase `done` as no
  flow, so a finished flow no longer switches planning's protections off.

## 2.2.1

- The glossary's **Ticket subagent** entry no longer says "unmet" twice
  about one criterion (see issue #182).

## 2.2.0

- Quick implementation's single-pass review starts the plugin's own
  `orch-reviewer-standards` and `orch-reviewer-spec` agents instead of
  `mattpocock-skills:code-review` (see issue #189, ADR-0021). A reviewer that
  fails twice stops the run before the PR opens, and the PR body lists every
  declined finding under **Review**. `branch off` now records the base SHA,
  `branch base-sha` prints it, and `quick path` hands out the per-branch
  report directory.
- Nothing in the plugin invokes `code-review` any more, so doctor requires
  only `to-spec`, `to-tickets` and `tdd`, and no longer fails an install
  without `code-review`.

## 2.1.2

- Doctor requires exactly the mattpocock skills the plugin reads (see issue
  #191): `to-spec`, `to-tickets`, `tdd` and `code-review`. It no longer fails
  an install missing `implement` or `handoff`, which nothing reads, and now
  fails one missing `to-tickets` or `tdd`, in every install layout. A test
  keeps doctor's list in step with the skills and agents that invoke them.

## 2.1.1

- ADR-0002 is marked superseded in part by ADR-0018 (see issue #173): the
  Spec axis is reviewed by the plugin's own `orch-reviewer-spec` agent, not
  `code-review`'s Spec sub-agent, and ADR-0002's decision stands. ADR-0018's
  Supersedes paragraph names ADR-0002 in turn, and ADR-0002's title now reads
  "the Spec axis".

## 2.1.0

- Quick implementation offers a spec review of its linked issue before its
  ticket breakdown (see issue #237). It asks on every run, with **Run a spec
  review (Recommended)** and **Skip**. Run follows `orch-spec-review`'s
  standalone entry unchanged, and a review that stops stops quick
  implementation too. `to-tickets` then reads the issue as it stands after the
  review, and the review's host fallbacks also reach the PR body's **Host
  fallbacks**. Skip records nothing. Later steps are renumbered 3-7.
- The grilling hook's closing question is tested to offer exactly two options.

## 2.0.0

Breaking: the standalone spec review's command and skill are renamed
`spec-review`, matching the glossary's **Spec review** and `code-review` (see
issue #235). There is no deprecated alias: the old names no longer exist.

Migration - update any muscle memory, notes, or scripts that name them:

| Old name                        | New name                        |
| ------------------------------- | ------------------------------- |
| `/orchestrator:review-spec`     | `/orchestrator:spec-review`     |
| `orchestrator:orch-review-spec` | `orchestrator:orch-spec-review` |

- The flow's spec phase invokes `orch-spec-review`. A flow already under way
  needs nothing: `orch.sh` never names the skill, and handoffs name it only in
  prose.
- The review loop's reviewer reports are headed `# Spec axis - iteration <NN>`
  and `# Standards axis - iteration <NN>`, so the Spec-axis report is no longer
  called a spec review.
- The skill-name guard in the test suite now flags the old command and skill
  names.

## 1.8.0

- New `orch.sh spec-review begin <n>` starts a standalone spec review (see
  issue #224). It refuses while an active flow holds issue `<n>` - pointing at
  `/orchestrator:next` at phase `spec` and `/orchestrator:redo` at
  `implement` or `review` - and otherwise empties
  `.orchestrator/spec-review/<n>/` and prints its path. It reads `state.json`
  only to compare, works with no state file, and never writes state.
- `orch-review-spec`'s **Standalone spec review** steps call it once, in
  place of the prose guard and the prose `rm -rf` of the working directory.
  The review's refusals and their pointers are unchanged.

## 1.7.2

- `orch.sh doctor --env` detects Junie CLI from `JUNIE_SHIM_PATH`, which Junie
  CLI exports to its agent shell, as well as from `JUNIE_EXTENSION_ROOT` (see
  issue #205). Junie is still checked before Claude Code's signals.

## 1.7.1

- The test suite no longer keeps a verbatim copy of the four spec-review lens
  briefs (see issue #212). It checks structure instead: each lens agent has a
  non-empty `## Brief` section, and `orch-review-spec` carries no
  `**<Lens> brief.**` heading.

## 1.7.0

A spec review can run standalone, against any issue, outside a flow (see
issue #185).

- New command `/orchestrator:review-spec <issue>` runs `orch-review-spec`'s
  new **Standalone spec review** entry. With no number it asks for one; it
  never reads the issue from flow state.
- The standalone entry refuses when a flow that is not `done` holds the same
  issue, pointing at `/orchestrator:next` at phase `spec` and
  `/orchestrator:redo` at `implement` or `review`. It works in
  `.orchestrator/spec-review/<issue>/`, wiped at the start of each run, and
  never writes flow state, handoffs, or `02-spec.md`.
- Consistency, Testability, and Implementability run as in a flow. Fidelity
  has no plan to check against, and is shown as **not run - standalone
  review, no plan to check against**.
- New `orch.sh issue comment <n> <file>` posts a comment with no flow state.
  `spec comment` now delegates to it, and `spec fetch/update/comment` die
  when the flow is `done`, naming the flow's issue and pointing at
  `issue <op> <n>`.
- `CONTEXT.md`'s **Spec review**, **Lens**, and **Phase** entries and
  ADR-0004 describe the standalone review.

## 1.6.0

The spec review's four lenses run as read-only plugin agents (see issue
#177).

- Four new agents, `orch-lens-fidelity`, `orch-lens-consistency`,
  `orch-lens-testability`, and `orch-lens-implementability`, each own their
  lens's brief and the shared reporting rules. Their tools are Read, Grep,
  and Glob only, so a lens started as a plugin agent cannot edit anything.
- `orch-review-spec`'s "The lenses" section is now a lens-to-agent table and
  the spawn rule. Each prompt carries only the paths the lens reads, and each
  lens returns its findings as its reply. The retry rule, per-lens findings,
  the batch, and both changelogs are unchanged.
- On a host that cannot start the plugin's agents natively, the skill takes
  `docs/host-capabilities.md`'s "Start a fresh subagent" fallback with each
  lens's agent file as its brief. That fallback now says a lens loses its
  tool restriction there, and that a lens's report is the findings it
  returns.

## 1.5.11

Junie CLI gets the planning message only when grilling starts, instead of
with every request (see issue #202).

- `hook-grilling.sh` also runs on `UserPromptSubmit`. On Junie it fires when
  the prompt names a grilling entry point (`/grilling`, `$grill-me`,
  `$grill-with-docs`, `/wayfinder`, `/improve-codebase-architecture`), once
  per session and never with a flow active. On Claude Code that entry exits
  silently. When Junie picks grilling on its own, no message is sent.
- On Junie the closing question names Junie's `ask_user` tool. Junie routes
  grilling into its plan mode, whose plan agent ends on Junie's own plan
  screen without asking, so the question is asked again when the human picks
  "Confirm and implement" in a session that grilled.
- The Junie message names the `SKILL.md` files of this install to follow,
  since Junie has no Skill tool. The rest of the planning message is shared
  by both hosts.
- `guidelines/orch-planning.md` is deleted, so Junie no longer pays about 0.5k
  tokens per request for it. `orch.sh doctor --env` on Junie no longer lists
  "Inject context at planning time" as a capability the host lacks.
- The hooks read the repo from Junie's `project_path`, since Junie's `cwd` is
  `~/.junie`.

## 1.5.10

The host capabilities reference states what Junie CLI does with the plugin's
agents (see issue #203).

- Junie CLI loads the plugin's `agents/`, but its capability filter usually
  hides them, and a visible one gets no tools yet (#204). Its **Start a fresh
  subagent** cell is now **Fallback**, not **Unverified**, so `orch.sh doctor
  --env` on Junie lists it under what the host lacks.
- The fallback's first tier covers a host that cannot start the plugin's
  agent natively - it did not load `agents/`, or hid it - so a run on Junie
  records the capability filter as the reason, not "did not load".
- The README's Junie paragraph documents the prompt workaround for the
  filter, which pays off only once #204 is fixed.

## 1.5.9

Skills find `orch.sh` on Junie CLI with their first command (see issue #201).

- Every skill that runs `orch.sh` now looks for the Junie CLI install with
  `ls "$HOME"/.junie/extensions/*/orchestrator/scripts/orch.sh` when
  `CLAUDE_PLUGIN_ROOT` is unset, before the path relative to the skill. More
  than one match stops the skill and shows the human the paths.
- `orch-review`'s plugin-root sentence takes the same step.
- `orch_test.sh`'s resolution lint requires the Junie steps, in order, in
  every file that runs `orch.sh`, and the Junie step inside the plugin-root
  sentence wherever it appears.

## 1.5.8

`orch.sh handoff section` refuses a handoff that repeats the requested
heading (see issue #168).

- `handoff section <file> <heading>` exits non-zero with `repeated section:
  ## <heading> in <file>` when the heading appears more than once, and prints
  no body. It used to print every matching section's body joined together as
  if they were one. A single match and a missing heading behave as before.

## 1.5.7

The review loop says exactly what a reviewer started through the host
fallback loses: the Edit and Write restriction (see issue #167).

- `docs/host-capabilities.md`'s **Start a fresh subagent** fallback and
  ADR-0018 no longer call the named reviewer agents mechanically read-only.
  The reviewers keep Bash, so read-only behaviour through Bash always rested
  on the brief; the fallback loses only the Edit and Write restriction. The
  reviewers' tools are unchanged.

## 1.5.6

The fixer pushes only when it made a commit (see issue #165).

- `orch-fixer`'s **Push** step runs only if its **Commit once** step made a
  commit. A fixer that fixed nothing skips the push, and still writes its
  record and returns `no commit`.

## 1.5.5

The final review record names the section the CI answer goes in: `## CI`
(see issue #159).

- `orch-review`'s **Termination** step 1 appends the answer under `## CI`:
  the word `review ci` printed, its detail lines, and a line saying so if the
  flake rerun was spent. The closer's `## Filed` and the driver's `## Terminal state`
  follow it.
- The record template in `orch-fixer`'s brief shows `## CI`, `## Filed`, and
  `## Terminal state` as termination-only sections, and the fixer is told to
  leave all three out by name.
- `orch-closer`'s **CI result** prompt field points at that section.
  `orch.sh review terminal` still reads only `## Terminal state`.

## 1.5.4

The fixer's brief names its host fallback for the `mattpocock-skills:tdd`
skill, and the host-capability lint covers `agents/` (see issue #157).

- `orch-fixer`'s first step says what to do on a host with no Skill tool:
  `bash "<orch.sh>" mp-skill tdd`, per `docs/host-capabilities.md`'s **Invoke a
  skill from a step**, recorded under the iteration record's **Host
  fallbacks**. `orch-review` now passes the fixer the `orch.sh` path in its
  prompt, as it already did the closer.
- README's "Naming host capabilities" rule names the agent briefs under
  `agents/` alongside skills and commands.
- `orch_test.sh` scans `agents/*.md` with the skill checks; an agent must
  point at `docs/host-capabilities.md` when it invokes a skill.

## 1.5.3

`orch-review`'s clean-iteration record command reads the fixer's brief
through `CLAUDE_PLUGIN_ROOT`, not a `<plugin root>` placeholder (see issue
#155).

- The `sed` command reads `"${CLAUDE_PLUGIN_ROOT}/agents/orch-fixer.md"`, and
  the sentence beside it names the unset fallback: two directories above the
  skill, as for `ORCH`.
- `orch_test.sh` accepts a `"${CLAUDE_PLUGIN_ROOT}/<path>"` in a skill that
  carries that fallback sentence, and fails on any `<plugin root>/`
  placeholder in a skill, command, or guideline.

## 1.5.2

The review loop's vocabulary reads the same in the glossary, `orch-review`
and ADR-0017 (see issue #169, covering #156, #170 and #171).

- The driver's "never edits the change" rule states its one exception: on a
  host with no fresh subagent, the driver does the fixer's and the closer's
  work in its own session and records it as a host fallback.
- **Clean iteration** has one meaning: triage left nothing to fix, so no fixer
  ran. An iteration whose fixer ran but fixed nothing is not clean.
- The glossary's Ready condition names open blocking, whether found in the
  final iteration or carried in, and the missing look, matching the skill.
- `CONTEXT.md` gains **Driver**, **Reviewer**, **Open blocking** and
  **Missing look** entries.

## 1.5.1

A failing full verification is recorded in the implement handoff's
**Verification** section, not under **Deviations** (see issue #184).

- `orch-flow`'s implement phase writes the verification command, its result,
  and on a `fail` the ticket that reported it, all under **Verification**:
  the command alone on the first line, the result on its own line after it.
- `orch-review` takes only that first line as the verification command.
- **Deviations** holds only the tickets' reported deviations, as the handoff
  template defines it. The review loop still treats a failure as blocking.

## 1.5.0

`orch-implementer` finds its spec issue through `orch.sh` instead of calling
the sub-issue endpoint with `gh api` itself (see issue #179).

- New `orch.sh ticket parent <n>` prints a sub-issue's parent issue number, or
  nothing when the issue has no parent, and fails on any gh error.
- The implementer's prompt is now two lines, the ticket number and the path of
  the plugin's `orch.sh`, the same way `orch-closer` receives it. The same
  path serves its `mp-skill tdd` route on a host with no Skill tool, and the
  dispatching skill records that fallback.

## 1.4.2

The closer files only what its own review loop left unfixed, and the driver's
triage is the one owner of the already-filed rule (see issue #164, covering
#172 and #158).

- `orch-closer` gets a **Loop boundary** in its prompt and gathers majors and
  nits only from records numbered above it, leaving earlier loops' records
  alone.
- A finding a later iteration of the same loop fixed is no longer filed.
- The closer no longer checks **Filed** lists itself; it sets aside only what
  triage marked met again.
- **Filed** entries read `#<n> <severity>: <file>:<line> <title>`, and triage's
  **Met again** matches on file, line, and claim instead of the title alone.
  An older entry with no file and line is matched on its title against the
  finding's claim.
- ADR-0020 records the decision and supersedes ADR-0017 in part.

## 1.4.1

Starting a plugin agent is defined once (see issue #181).

- `docs/host-capabilities.md`'s **Start a fresh subagent** fallback is the one
  definition of how a plugin agent is started on a host that cannot start it
  natively: first a fresh general-purpose agent briefed with the agent's file,
  then in-session work that takes the host fallback for any capability the
  brief names. `orch-review`, `orch-flow`, and `orch-quick-implement` point at
  it and keep only where they record the fallback.
- The implement phase and quick implementations now take that first tier too,
  instead of going straight to in-session work on a host that has fresh
  subagents but does not load the plugin's `agents/`.
- `orch-implementer`'s dispatch contract lives once, in the **Starting this
  agent** section of `agents/orch-implementer.md`.

## 1.4.0

Ticket subagents run as the plugin's own `orch-implementer` agent and no
longer review their own work (see issue #176 and
`docs/adr/0019-ticket-subagents-check-acceptance-criteria-and-leave-review-to-the-loop.md`).

- The implement phase and quick implementations start `orch-implementer`
  with only the ticket number. It builds the ticket test-first through
  `mattpocock-skills:tdd`, commits, checks its commits against the ticket's
  acceptance criteria, and returns five lines: `Ticket`, `Commits`,
  `Verification`, `Criteria`, `Deviation`.
- Its tools are Read, Edit, Write, Grep, Glob, Bash, and Skill: it cannot
  start sub-agents or ask the human a question. Per-ticket
  `mattpocock-skills:code-review` is gone; the review loop reviews the whole
  change. Quick implementation's own single-pass review is unchanged.
- `03-implement.md`'s **Already found and fixed** section is now **Unmet
  criteria**: the criteria the ticket subagents reported unmet, for the review
  loop's Spec axis to judge. The implement phase assembles it, **Deviations**,
  and **Verification** from the reports.

## 1.3.0

The review loop's driving session hands its work to fresh plugin agents, so
a loop stays within its context budget (see issue #149,
`docs/adr/0017-the-review-loops-driver-hands-fixing-and-filing-to-fresh-agents.md`
and `docs/adr/0018-the-review-loop-owns-its-reviewer-briefs.md`).

- The plugin ships an `agents/` directory with four agents:
  `orch-reviewer-standards`, `orch-reviewer-spec`, `orch-fixer`, and
  `orch-closer`.
- Two reviewer agents replace `mattpocock-skills:code-review` in the review
  loop. They have no Edit or Write tool, and each writes its report to a file
  and returns one line. The implement phase and quick implementations still
  use `code-review`.
- A fixer is started at most once per iteration, only when triage leaves
  something to fix. It fixes, verifies, commits, pushes, and writes that
  iteration's review record; on a clean iteration the driver writes it. A
  closer is started once at termination to file the unfixed findings and
  comment on the PR. The driver triages, waits on CI, and decides the
  terminal state, and never edits the change.
- `orch.sh handoff section <file> <heading>` prints one section of a handoff,
  so the driver reads only what it needs.
- "Junie" means the Junie CLI throughout the docs. `orch.sh doctor` reports
  the host as `Junie CLI`, and a fresh subagent there is now unverified, not
  missing: the Junie CLI documents custom subagents, but loading them from a
  plugin's `agents/` is unconfirmed (#148). The inline fallback stays.

## 1.2.0

The review loop now fixes what needs no decision, not only what is blocking
(see issue #146 and
`docs/adr/0016-the-review-loop-fixes-what-needs-no-decision.md`).

- A major is fixed unless its fix needs a choice the plan, spec, and
  deviations did not settle, or would change behaviour. A nit is fixed only
  when it is mechanical. Everything else is filed, as before.
- A major or nit on lines the current loop's own fix commits wrote is filed,
  never fixed, and the final iteration fixes only what is blocking.
- A filed issue's "why not fixed" line names the rule that kept it out of the
  loop. Findings a previous loop already filed are left alone and listed for
  the human in the PR comment.
- `orch.sh review file`'s rejection of `blocking` no longer says the loop
  fixes blocking only.

## 1.1.1

The plugin no longer relies on its scripts' execute bit, which some hosts
(Junie) drop on install or update, so the first hook failed with `Permission
denied` (see issue #142 and `docs/host-capabilities.md`, "Execute bit").

- `hooks/hooks.json` runs all three hooks through `bash`.
- Every skill, the README and host capabilities run `bash "$ORCH" …` instead
  of `"$ORCH" …`.
- `scripts/test/hooks_test.sh` fails if a hook command skips `bash`, and runs
  each hook at mode 644. `scripts/test/orch_test.sh` fails if a skill,
  command, guideline, the README or host capabilities runs `orch.sh` without
  `bash`.

## 1.1.0

Flows and quick implementations can now work against a **base branch** other
than the default, such as `uat` or a long-running feature branch, and a
**release PR** carries it back into the default branch (see issue #135 and
`docs/adr/0015-a-non-default-base-refers-its-issue-and-the-release-pr-closes-it.md`).
With nothing set, every fork and PR works exactly as before.

- `orch.sh base set <branch>`, `base show` and `base clear` set, print and
  remove the base branch. `base set` refuses a branch `origin` does not have.
  The setting lives in the clone's local git config (`orchestrator.base`): it
  is shared by every worktree, never committed, and kept through `abort` and
  archiving.
- A flow records its base branch in `state.json` at `init`, and `branch
  create` and `pr open` fork from and target it, so changing the setting
  mid-flow never moves that flow's PR. A flow started before this release
  uses the default branch.
- `branch off` forks a quick implementation from the base branch and records
  it on the branch (`branch.<name>.orchestrator-base`), and `pr publish`
  targets it.
- Forking stops with an error when `origin` says the base branch does not
  exist, and falls back to the local copy only when `origin` can't be reached.
- A PR into the default branch still starts with `Closes #N`. A PR into any
  other base branch starts with `Refs #N`, since GitHub would not close the
  issue on merge anyway.
- `orch.sh pr release [--force] <title> <body-file>` and
  `/orchestrator:release` (skill `orch-release`) open the release PR: a
  non-draft PR from the base branch into the default branch, with one
  `Closes #N` line per still-open issue referenced by any PR merged into the
  base branch. It refuses on the default branch, while a release PR is
  already open, and with nothing to close unless `--force`.
- `status` prints a `base:` line for the active flow.
- `doctor` reports the base branch in effect and where it came from, FAILs
  when a set base branch is gone from `origin`, and warns when `origin` can't
  be reached to check.

## 1.0.0

Breaking: every orchestrator skill now carries an `orch-` prefix, whatever the
host (see `docs/adr/0014-orchestrator-skills-carry-an-orch-prefix.md`). Bare
skill names collide on hosts that list skills without a plugin namespace, such
as Junie, where orchestrator's `handoff` shadowed mattpocock's.

Migration - update any muscle memory, notes, or scripts that name a skill:

| Old name                       | New name                            |
| ------------------------------ | ----------------------------------- |
| `orchestrator:flow`            | `orchestrator:orch-flow`            |
| `orchestrator:handoff`         | `orchestrator:orch-handoff`         |
| `orchestrator:review`          | `orchestrator:orch-review`          |
| `orchestrator:review-spec`     | `orchestrator:orch-review-spec`     |
| `orchestrator:quick-implement` | `orchestrator:orch-quick-implement` |

The slash commands (`/orchestrator:start`, `/orchestrator:next`, and so on) are
unchanged. The skill directories moved from `skills/<name>/` to
`skills/orch-<name>/`.

A flow started on 1.0.0 needs a `## Host fallbacks` section in every handoff
(`01-plan.md`, `02-spec.md`, `03-implement.md`), and `handoff validate` /
`doctor --flow` fail without one. A flow already under way when you upgrade is
exempt, so it finishes as it would have on 0.x.

Also new in 1.0.0 (see issue #121):

- Junie is supported as a second host. `docs/host-capabilities.md` maps each
  capability the skills rely on to each host, with documented fallbacks.
- Skills find `orch.sh` relative to their own directory when
  `CLAUDE_PLUGIN_ROOT` is unset.
- mattpocock-skills are found in Claude's plugin cache, Junie's extension
  cache, or the `skills` CLI store (`~/.agents`), or wherever
  `ORCHESTRATOR_MATTPOCOCK_ROOT` points.
- `orch.sh init` refuses to start a flow while the working tree has changes
  outside the planning allowlist.
- Doctor reports the detected host (override with `ORCHESTRATOR_HOST`) and the
  capabilities it lacks.
- `guidelines/orch-planning.md` carries the planning nudge on Junie.
