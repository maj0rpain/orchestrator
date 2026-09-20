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

## Prior requests

- #65: "The phase-runs-next tense rule is duplicated near-verbatim across three files" — filed by the review loop as a Standards-axis nit against PR #56
