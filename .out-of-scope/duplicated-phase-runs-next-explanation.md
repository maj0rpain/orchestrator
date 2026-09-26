# Duplicated "phase names what runs next" explanation across docs

This project does not deduplicate the sentence explaining that the recorded
phase names the stage that runs next (so redoing the phase that just
finished means stepping back one first), even though a close paraphrase of
it appears in the glossary, the Redo command's own doc, and the flow skill.

## Why this is out of scope

Each copy is written for a different, standalone reader: the glossary entry
defines the term once for anyone building a mental model of the project; the
command doc is a short stub read fresh, with no memory of any other file, by
whichever phase invokes it; the skill's fuller Redo section spells out the
consequence for an agent mid-task. This project's phase and skill docs are
deliberately self-contained — each runs in its own session with no memory of
the last — so a reader landing on any one of them needs the explanation
restated in place rather than needing to go cross-reference the glossary.
Introducing a "see CONTEXT.md" pointer instead would save three sentences at
the cost of every one of those standalone reads.

## The same rule for the review loop's agents

The review loop's agents follow the same rule, and more strictly.
Each agent in `agents/` is started as a fresh subagent. Its brief is the only
file it is certain to read, and a brief cannot include a shared file. So the
things each agent needs are written out in that agent's own brief:

- the read-only rules, the pin-the-change step and the report format, which
  both reviewer briefs share;
- the prompt fields, described once in the orch-review skill for the driver
  that sends them and again in the agent file for the agent that receives
  them;
- the Severity rubric, given as a glossary definition in `CONTEXT.md` and
  restated in the skill that applies it;
- the rules that keep a finding unfixed, which the glossary, the driver's
  triage, the fixer's could-not-fix list and the closer's filing each need.

Every copy has a real risk of drifting from the others. Adding a rule to the
unfixed list in PR #154 took edits in four files. That cost is accepted: a
single owner with pointers from everywhere else would leave each reader one
file short of what it needs. Drift is caught by the review loop's Standards
axis when the copies disagree, not by removing the copies.

## Prior requests

- #65: "The phase-runs-next tense rule is duplicated near-verbatim across three files" — filed by the review loop as a Standards-axis nit against PR #56
- #160: "The reasons a finding is left unfixed are listed separately in four files" — review-loop Standards nit against PR #154
- #161: "The two reviewer briefs repeat their read-only, pin-the-change and report sections" — review-loop Standards nit against PR #154
- #162: "The Severity rubric is written out in both CONTEXT.md and the orch-review skill" — review-loop Standards nit against PR #154
- #166: "Each fixer and closer prompt field is described in both the skill and the agent file" — review-loop Standards nit against PR #154
