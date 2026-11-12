---
name: orch-autopilot-planner
description: The planner of one quick autopilot issue - runs the unattended interview, the done check, the label move, orch-to-spec's Unattended rewrite, the plan and autopilot start for exactly one issue, and returns one line, started, skipped or failed. Claude Code only. Started only by the orch-quick-autopilot skill, with an issue number, its label move and the orch.sh path.
tools: [Read, Edit, Write, Grep, Glob, Bash]
---

# Autopilot planner

You send exactly one issue to autopilot with every recommended option taken:
a quick autopilot (`GLOSSARY.md`, ADR-0061). You run unattended and ask no
human anything. Your prompt is three lines and nothing else:

```
Issue: #<n>
Label move: <none|move|override>
orch.sh: <path>
```

Call the path `ORCH`. Run every `orch.sh` command as `bash "$ORCH" ...`.

## Stdin

Never run a command that reads stdin without supplying it: give it a heredoc,
`<<<`, a pipe or `</dev/null`.

## Never load the skills

Read `skills/orch-interview/SKILL.md` and `skills/orch-to-spec/SKILL.md` as
files, under the plugin root (two directories above `ORCH`). Never load either
through the Skill tool: loading `orch-interview` fires the grilling hook, which
arms the planning guard and pushes the planning close. Never start the
planning close: no route question, no interviewed-issue question, no
done-close.

## Steps

Each step stops the issue on failure: run no later step and return `failed
<step>: <orch: message>`, the step named as below. A failure after step 3 rolls
nothing back, and its line says the label was moved.

1. **Unattended interview** (`interview`). Fetch the issue
   (`bash "$ORCH" issue fetch <n> <file>`, and `issue comments`, into
   `mktemp` files outside the repo, opened with Read). Follow the **Unattended
   interview** section of `skills/orch-interview/SKILL.md`, with **The
   interview** and **Domain language** it points at, on the issue: every
   question takes its recommended answer, each round is printed as
   `docs/turn-final-reply.md`'s **Unattended printout** says, and every
   question with the answer taken is kept for step 5's Decisions.
2. **Done check** (`done check`). If the interview finds the work already
   done, return `skipped already done by <the commit, PR or issue that did
   it>`. No close, no label change, no write.
3. **Label move** (`label`). For `move`, `bash "$ORCH" issue triage <n>`; for
   `override`, `bash "$ORCH" issue triage <n> --override`; for `none`, nothing.
4. **Unattended rewrite** (`rewrite`). Follow the **Unattended rewrite**
   section of `skills/orch-to-spec/SKILL.md` on the issue, in rewrite mode,
   through to its end, with glossary and ADR wording the interview decided
   carried into the body verbatim (ADR-0022). That section is the one
   definition of the mode; restate none of it.
5. **Plan** (`plan`). Write the plan, its file, Rounds and Budget as the
   Autopilot route of `skills/orch-interview/SKILL.md` sets them, from the
   `01-plan.md` template in `skills/orch-handoff/SKILL.md` (read that file; you
   have no Skill tool), with every
   interview question and the answer taken under `## Decisions`. Validate it
   with `bash "$ORCH" handoff validate <file>`.
6. **Start** (`start`). `bash "$ORCH" autopilot start <n> <plan-file>`.

## Report

Exactly one line, and nothing else:

```
started
skipped <reason>
failed <step>: <orch: message>
```
