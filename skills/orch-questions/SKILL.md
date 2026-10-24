---
name: orch-questions
description: Gather the current repo's pending autopilot questions (open needs-human issues whose newest question comment no comment follows), form a second recommendation for each in a fresh parallel subagent, put them to the human one batch per issue, oldest first, post each confirmed reply with orch.sh autopilot reply, then offer orch.sh autopilot resume on refusal and failure stops and on issues already replied to. Use when the human asks for the pending autopilot questions or runs /orchestrator:questions.
---

# Orchestrator questions

Puts every **Pending question** (see `GLOSSARY.md`) of the current repo to the
human, each with this skill's own recommendation beside the session's, and
posts the reply in the autopilot's grammar. The verbs it drives are `orch.sh
autopilot questions`, `reply` and `resume`; they need no flow state, so this
skill runs from any checkout of the repo, with or without an active flow.

What this skill never does:

- **No direct `gh`.** Every GitHub read and write goes through `orch.sh`.
- **No reply without confirmation.** Each reply is shown in full and posted
  only on the human's yes.
- **No `recommended` in a reply.** See step 4.

`orch.sh` resolves as:

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

Steps here name capabilities (start a fresh subagent, ask a multiple-choice
question). `docs/host-capabilities.md` under the plugin root maps each one to
your host. Where your host's cell says **Fallback**, or **Unverified** and the
capability turns out missing, take the fallback it documents and tell the user
which.

## 1. List

Run `bash "$ORCH" autopilot questions`. It prints one tab-separated line per
issue: the issue number, a kind (`question`, `replied` or `stop`), the phase,
and the URL of the comment the kind is about. When it reports that nothing is
pending, relay that line and stop.

## 2. Recommend

For each `question` issue, start one fresh subagent - never a fork - all in
parallel. Its prompt holds the issue number, the `ORCH` path and the phase.
It reads, through `orch.sh` and never raw `gh`:

- the issue body (the spec): `bash "$ORCH" issue fetch <issue> <file>`;
- the comments, including the plan comment (`<!-- orch:handoff 01-plan -->`),
  the spec-review changelogs and the question comment itself: `bash "$ORCH"
  issue comments <issue> <file>`;
- for a `review`-phase question, the linked PR's body and diff: `bash "$ORCH"
  pr read <issue> <file>`.

Each file is a `mktemp` file outside the repo, opened with the Read tool. The
subagent reads nothing outside GitHub, so no save point, and changes no file in
the repo. It returns the question comment's `createdAt` (from the comments it
read) and, for each numbered question, the session's recommendation, its own
recommendation with a one-clause reason, and a flag where the two disagree.

## 3. Ask

Put one batch per issue to the human, ordered by the `createdAt` the
subagents returned, the oldest question first. Show each question with its
options, the session's recommendation, this skill's recommendation and reason,
and any disagreement flag. The answer grammar for a batch:

- `<k>: <option>`
- `<k>: recommended` (this skill's recommendation)
- `<k>: session` (the session's recommendation)
- `<k>: <free text>`
- `all: recommended`, `all: session`
- `skip` - leave the issue untouched and go on.

## 4. Reply

Write the reply to a `mktemp` file outside the repo as the grammar line `1:
<option>, 2: <option>, ...`. Write every accepted recommendation as the option
it picked. Never write the word `recommended`: `autopilot answer` leaves the
next session to read it as its own recommendation, so here it is only an input
to this skill. Free text goes in verbatim. Show the reply in full and ask the
human to confirm. On confirmation, run `bash "$ORCH" autopilot reply <issue>
<file>`. Report a refusal or failure with its `orch:` message and go on to the
next issue.

## 5. Stops and replied

After the last batch:

- For each `stop` issue, show the stop comment (read with `bash "$ORCH" issue
  comments <issue> <file>`; its URL is on the listing line), including the
  detail it holds, the session log path when it names one. Offer to run
  `bash "$ORCH" autopilot resume <issue>`, which lets the watcher retry the
  phase, confirmed per issue.
- For each `replied` issue, offer `bash "$ORCH" autopilot resume <issue>`,
  confirmed per issue.
