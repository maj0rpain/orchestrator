# Unattended interview

A reference file of the `orch-interview` skill, read only by a quick
autopilot's planner subagent.

The interview with no human in it, taken only by a quick autopilot's
planner subagent, which reads this file, and from the interview skill's file
(`SKILL.md` in this directory) the sections **The interview**, **Domain
language** and **Glossary and ADR wording goes into the plan**, never loading
the skill through the Skill tool, and never starts the **Closing**: no route
question, no interviewed-issue question, no done-close. The attended interview
is unchanged. Everything in **The interview** and **Domain language** holds -
the design tree, rounds, fact-finding, the domain-language habits, the root
cause of a bug - with these differences only:

- **Every question takes its recommended answer.** Ask the human nothing and
  wait for no answer: each round is put as written, then every question in it
  takes its **Recommended** answer, and the next round's frontier is computed
  from those answers.
- **Each round is printed** as an unattended printout, with its questions and
  the answers taken: see **Unattended printout** in `docs/turn-final-reply.md`
  under the plugin root. It is not a turn-final reply, and the interview goes on
  in the same turn.
- **Each question and the answer taken is recorded**, to go under the plan's
  `## Decisions`.
- **An issue found already done is reported as skipped**, naming the commit, PR
  or issue that did the work, and the interview stops there: it closes nothing,
  moves no label and writes nothing.
- **It never resolves "next issue".** Its planner is always given an issue
  number, so `orch.sh issue next` is never run.
- **There is no planning close.** The interview is done when the frontier is
  empty; there is no confirmation of a shared understanding to wait for.
