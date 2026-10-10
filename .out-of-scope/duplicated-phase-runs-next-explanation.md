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
Introducing a "see GLOSSARY.md" pointer instead would save three sentences at
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
- the Severity rubric, given as a glossary definition in `GLOSSARY.md` and
  restated in the skill that applies it;
- the rules that keep a finding unfixed, which the glossary, the driver's
  triage, the fixer's could-not-fix list and the closer's filing each need.

Every copy has a real risk of drifting from the others. Adding a rule to the
unfixed list in PR #154 took edits in four files. That cost is accepted: a
single owner with pointers from everywhere else would leave each reader one
file short of what it needs. Drift is caught by the review loop's Standards
axis when the copies disagree, not by removing the copies.

## Where the rule stops

Keeping every copy holds for an explanation or a consequence a reader needs
in place: a fresh subagent or a standalone stub that sees only its own file,
or a skill's own consequence of a shared contract, as #339 keeps. It does not
hold for a whole procedure a driver session runs and can read from a shared
doc it already cites, as both driver skills cite **A driver's base sync** in
the resolver's brief. Such a procedure takes one copy and pointers to it.

The driver loop is the instance (#675): its loop steps a-f and its
**Dispatching a subagent** paragraph were written out in both `orch-flow`'s
implement phase and `orch-quick-implement`'s implement step, and now live
once, in `docs/driver-loop.md`, with each skill binding the doc's slots to
its own run. A Standards finding that a skill lacks its own copy of the loop
is not a missing copy, and a copy put back is a duplicate.

This sits beside the "self-contained" reasoning above and the #339 entry
below; neither changes.

## Prior requests

- #65: "The phase-runs-next tense rule is duplicated near-verbatim across three files" — filed by the review loop as a Standards-axis nit against PR #56
- #160: "The reasons a finding is left unfixed are listed separately in four files" — review-loop Standards nit against PR #154
- #161: "The two reviewer briefs repeat their read-only, pin-the-change and report sections" — review-loop Standards nit against PR #154
- #162: "The Severity rubric is written out in both CONTEXT.md and the orch-review skill" — review-loop Standards nit against PR #154
- #166: "Each fixer and closer prompt field is described in both the skill and the agent file" — review-loop Standards nit against PR #154
- #211: "Opening paragraph and reporting rules are duplicated word for word across the four lens agents" (review-loop Standards nit against PR #209)
- #339: "The ticket exists exit contract is written twice, in orch-flow and orch-quick-implement" (review-loop Standards nit against PR #332). The two copies agree on the exit codes but not on what exit 0's word settles: the flow's step 6 **Ticket breakdown**, or quick implementation's step 5 frontier. Each caller's reader needs its own consequence in place; the exit codes themselves are stated once, in `cmd_ticket_exists`'s header comment.
- #370: "The comments paragraph is pasted into all four spec-review lens briefs" (review-loop Standards nit against PR #363). Each lens is a fresh subagent that sees only its own brief and the files it is given, so each brief says in place that the spec is the body and its comments together.
- #675: "The driver loop is written twice, in orch-flow and orch-quick-implement" (review-loop Standards finding). Not kept: a whole procedure a driver session runs moved to `docs/driver-loop.md` - see **Where the rule stops**.
