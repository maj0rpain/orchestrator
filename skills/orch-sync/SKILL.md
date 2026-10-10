---
name: orch-sync
description: Run a base sync on demand - bring the current plugin-made branch (a flow's orch/ branch, including a done flow's, or a quick/ branch) up to date with its base branch by merging origin's tip of the base, inside or outside a flow. Starts a resolver on a conflict, corrects the PR body against the diff after a resolved conflict, records its Merge resolutions and the body corrections as one PR comment, and offers a review pass unless an active flow holds the branch. Use when a human runs /orchestrator:sync, or asks to catch a branch or PR up with its base.
---

# Orchestrator base sync, on demand

A **base sync** (see `GLOSSARY.md`) brings a branch up to date with its base
branch: it merges the remote base branch's tip into it, never rebasing, and
moves its base SHA to that tip. A flow runs one before its PR opens and at
the start of every review-loop iteration, and a quick implementation before
its review pass. This skill runs one when a human asks - after the review
loop marked the PR ready and the base moved again, say. See
`docs/adr/0038-a-merge-conflict-is-resolved-not-rebuilt.md`.

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

Steps here name capabilities (start a fresh subagent, ask a multiple-choice
question, invoke a skill). `docs/host-capabilities.md` under the plugin root
maps each one to your host. Where your host's cell says **Fallback**, or
**Unverified** and the capability turns out missing, take the fallback it
documents and name it in your report to the human.

The sync acts on the branch checked out here, whatever it is. `orch.sh branch
sync` itself decides whether the plugin made it - the branch this checkout's
flow holds, or one whose git config records its base - and refuses any
other, the base branch included.

## 1. Sync

Follow **A driver's base sync** in `agents/orch-resolver.md` (under the
plugin root), steps 1 to 4, on the current branch. The resolver's issue is
the one the branch's name carries - the number after `orch/` or `quick/` in
`orch/<issue>-…` or `quick/<issue>-…`. On a branch whose name carries no
issue, it is the issue the human gives: ask for one and wait.

- **Exit 0 on the first `branch sync`** - a clean merge, or nothing to
  merge: tell the human which, and stop. Nothing more happens: no PR body
  check, no comment, no review pass. Neither rewrites the branch's own
  lines, so the PR body stands as it is.
- **A failed sync** - a refusal, a failed resolution, or a rerun that does
  not exit 0: relay the failure and stop, as that section's step 4 says,
  leaving any merge in progress for the human. Never abort it.
- **A conflict resolved** - the rerun exited 0: the sync stands. Go to
  step 2.

## 2. Check the PR body and record the Merge resolutions

The resolved merge may have removed or rewritten code the PR body
describes, so correct the body before recording the merge. First learn
whether the branch has an open PR: run `bash "$ORCH" pr comments <file>`,
to a temporary file outside the repo (`mktemp`):

- **Exit 0**: there is an open PR. Run **Checking the PR body** in
  `agents/orch-fixer.md` (under the plugin root), unattended, against the
  base SHA `bash "$ORCH" branch base-sha` prints after the sync. Keep its
  outcome value for the comment.
- **Exit 1**: the branch has no open PR. Skip the check, write and post
  no comment, and put the **Merge resolutions** in your report to the
  human instead, saying the PR body check was skipped - there is no PR.
  Step 2 ends here.
- **Exit 2**: GitHub could not be read. The check does not run; its
  outcome is `Not updated - <reason>`, `<reason>` being the `orch.sh`
  message.

Never ask the human whether to correct the body: the check makes its
corrections and records them.

Then write one comment to a temporary file outside the repo (`mktemp`): a
**Merge resolutions** heading, then the sync's **Merge resolutions**, per
**Merge resolutions** in `agents/orch-resolver.md` (under the plugin root),
then a **PR body** heading holding the check's outcome value. Post it with
`bash "$ORCH" pr comment <file>`:

- **Exit 0**: posted. Tell the human the PR number it printed, and the PR
  body lines the check corrected, if any.
- **Exit 1**: the PR closed since the probe. Put the **Merge resolutions**
  and the **PR body** outcome in your report to the human instead.
- **Any other exit**: report the failure with its message, and the **Merge
  resolutions** and the **PR body** outcome with it, since the corrections
  may already have reached GitHub. The sync still stands: it is merged,
  recorded and pushed, and nothing is undone.

A resolver `Verification` line reading `fail` is reported too, never acted on
here: a review pass judges it.

## 3. Offer a review pass

Only after a conflict was resolved. Read `bash "$ORCH" state get phase` and
`bash "$ORCH" state get branch`. When both succeed, the phase is not `done`,
and the branch is the current branch, this checkout's active flow holds it:
offer no review pass, since a branch an active flow holds belongs to that
flow (ADR-0029). Tell the human that the flow's next review-loop iteration
syncs and reviews the merged code.

Otherwise - no flow here, a `done` flow, or a flow holding another branch -
ask the human, as a multiple-choice question, whether to run a review pass
against step 1's issue - the one the branch's name carries, or the one the
human gave: run it now, or not. On a yes, invoke the `orch-review`
skill and follow its **Standalone review pass** section with that issue -
one pass, never a review loop. On a no, stop.
