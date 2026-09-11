# orchestrator

A Claude Code plugin that separates **planning**, **spec writing**,
**implementation**, and **review** into four phases, each running in a fresh
session, connected by handoff files.

The problem it solves: one long session that plans, specs, builds, and reviews
carries every earlier phase's context into the next. The reviewer already
believes the implementer's reasoning. Splitting the phases and passing only a
written handoff between them means each phase judges the work, not the story
behind it.

It conducts [`mattpocock-skills`](https://github.com/mattpocock/skills) rather
than replacing it: `to-spec` writes the spec, `implement` builds it, `code-review`
reviews it. This plugin owns the state, the handoffs, the branch, and the PR.

## Install

```
/plugin marketplace add https://github.com/maj0rpain/orchestrator.git
/plugin install orchestrator@orchestrator
```

The repo doubles as its own single-plugin marketplace, so there is no separate
marketplace repo. Installs at user scope, so it is available in every project on
that machine.

**Use the full HTTPS URL, not the `owner/repo` shorthand.** While this repo is
private, the shorthand resolves over SSH and fails without a key on the machine;
the HTTPS URL uses your existing git credential helper (`gh auth setup-git`).
If the repo is ever made public, the shorthand works and this caveat goes away.

Requires the `mattpocock-skills` plugin, plus `gh`, `jq`, and `git`. Run
`/mattpocock-skills:setup-matt-pocock-skills` once per repo first - the spec phase
reads `docs/agents/issue-tracker.md` and fails without it. `/orchestrator:start`
checks all of this up front, and `/orchestrator:doctor` reports it at any time.

## The flow

```
  planning session          you approve the plan
  (grill-me / wayfinder  ->  /orchestrator:start  ->  01-plan.md
   / improve-codebase-…)                               |
                                                       | /clear
  spec session         to-spec publishes the issue  <--+
                       spec review                  ->  02-spec.md
                                                       |
                                                       | /clear
  implement session    branch orch/<issue>-<slug>   <--+
                       implement, push, draft PR    ->  03-implement.md
                                                       |
                                                       | /clear
  review session       bounded review loop          <--+
                       triage, fix, verify, CI      ->  ready, or a bounded stop
                                                       |
                                                       | /clear (after a bounded stop)
                                                       +--> review session
```

Handoffs live in `.orchestrator/handoff/`, ignored via `.git/info/exclude` so
running the flow never dirties a repo's working tree.

## Commands

| Command | What it does |
| --- | --- |
| `/orchestrator:start [slug]` | Start a flow from an approved plan. Runs in the planning session. |
| `/orchestrator:next` | Run the next phase. Run it in a fresh session. |
| `/orchestrator:status` | Phase, issue, branch, PR, and the flow's health. |
| `/orchestrator:doctor` | Diagnose the machine, the repo, and the active flow. |
| `/orchestrator:redo` | Step back one phase and re-run it. |
| `/orchestrator:abort` | Archive the flow to `.orchestrator/archive/`. |

## Why separate sessions

`handoff`, `implement`, `to-spec`, `wayfinder`, and `improve-codebase-architecture`
are all marked `disable-model-invocation: true` upstream, so the Skill tool cannot
invoke them. The flow works around this by reading their `SKILL.md` files directly
and following them, which is what the Skill tool would have injected anyway.

That makes invocability a solved problem, **but the separate sessions remain the
point**: fresh context per phase, and room for the human-in-the-loop exchanges
that `to-spec` (test seams) and the spec review depend on. If those upstream flags
ever change, the architecture does not need to.

## Activation

A `PostToolUse` hook on `Skill(grilling)` catches all three planning entry points
- `grill-me`, `wayfinder`, and `improve-codebase-architecture` all route through
it. It fires once per session, stays quiet when a flow is already running, warns
early if the repo is unconfigured, and tells the model to close with
`Plan approved?` rather than offering to implement.

A `PreToolUse` hook on `Edit`/`Write` enforces that: during a planning session
with no flow started, source edits are denied. Planning artifacts stay writable -
`CONTEXT.md`, `CONTEXT-MAP.md`, `docs/adr/`, `docs/agents/`, `.scratch/`,
`.orchestrator/` - because `improve-codebase-architecture` and `domain-modeling`
legitimately write them mid-planning.

## Layout

```
commands/         start, next, status, doctor, redo, abort
skills/flow/      the state machine (judgment)
skills/review/    the review loop: rubric, authority rules, terminal states
skills/handoff/   handoff templates, model-invocable unlike the upstream one
scripts/orch.sh   every deterministic operation (mechanism)
scripts/hook-*.sh the two hooks
scripts/test/     shell tests
hooks/hooks.json  hook wiring
```

Prose for judgment, bash for facts. Reading state, naming branches, resolving the
default branch, and validating handoffs all have one right answer, so they live in
`orch.sh` where they cannot drift between sessions.

## Develop

```
claude --plugin-dir /path/to/orchestrator     # load the working tree directly
claude plugin validate .
scripts/test/orch_test.sh && scripts/test/hooks_test.sh
```

`--plugin-dir` is the development loop: it loads the working tree, so edits take
effect on the next session with no push. The installed copy is a clone of the
default branch pinned to `version` in `plugin.json`, so changes reach it only
after a push plus `/plugin marketplace update orchestrator`. Bump `version` when
publishing a change worth pulling.

## Status

All four phases run. The review phase is a bounded loop: a budget of iterations
the human chooses at the start (five by default), `code-review` from the base
SHA every one of them, a blocking/major/nit rubric applied on top of it, and
only blocking findings fixed - one fix commit per iteration that fixed anything.
The loop runs its whole budget; when it ends, every major and nit becomes a
GitHub issue labelled `review:major` or `review:nit` plus `needs-triage`, with
the reviewer's finding and the loop's reasoning in the body. CI is waited on
once per loop with a single flake rerun per flow. It ends by marking the draft
PR ready, or by stopping with the reason recorded - and comments on the PR
either way. After a bounded stop, a human may run the phase again as a fresh
loop with its own budget. `/orchestrator:doctor` covers the machine, the repo,
and the active flow.

Still to come: `orchestrator:review-spec` (fidelity, testability, consistency,
implementability), and a review check group in `doctor`.

## License

MIT - see [LICENSE](LICENSE).
