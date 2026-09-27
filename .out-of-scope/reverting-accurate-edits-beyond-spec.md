# Reverting accurate edits that went beyond the spec

This project does not undo a merged edit just because the review loop's Spec
axis called it scope creep. That covers an edit that is accurate, agrees
with the rules around it, and either changes no behaviour or brings a
command in line with a sibling that already works that way.

## Why this is out of scope

The Spec axis flags scope creep so a human can see it before merge. Once the
PR has merged, a finding like that is no longer about a risk. It is about
where the edit came from. The edits filed this way were one of:

- housekeeping that kept prose accurate after the change (the README's
  "Naming host capabilities" paragraphs and the host-capabilities fallback
  section, once a command could route to a skill other than `orch-flow`);
- fixes the loop wrote for its own earlier Standards findings (the
  `scan_capabilities` section check, which tests the new command's route);
- framing that a cold-started agent needs to read its brief correctly (the
  lens agents' opening paragraph and closing "your reply is the report"
  line: see the review-loop section of
  `duplicated-phase-runs-next-explanation.md` for why each agent file
  carries what it needs);
- a change in error order that makes a command match its sibling
  (`orch.sh spec` with no op now reports the unknown op first, as
  `orch.sh issue` already did, and the message lists the valid ops).

Reverting any of these would make the docs or tests less accurate, or make
two sibling commands disagree again, just so the diff matches the spec's
list of edits. The spec's scope protects the human from surprises before
merge. It is not a list to restore afterwards.

An edit beyond the spec that is *wrong*, or that changes behaviour in a way
nobody would pick, is not covered here. Triage it on its merits.

## Prior requests

- #210: "Lens agents carry prose beyond the brief and the four reporting rules" (Spec-axis finding against PR #209)
- #222: "orch.sh spec with no op dies with \"unknown spec op\" instead of the usage line" (Spec-axis finding against PR #218)
- #228: "README Naming host capabilities paragraphs and orch-review-spec layout line reworded beyond the spec's README edits" (Spec-axis finding against PR #218)
- #229: "host-capabilities Run a plugin command fallback section rewritten beyond the spec's row note" (Spec-axis finding against PR #218)
- #230: "scan_capabilities refactored to check a named section in any orch- skill, unrequested by the spec" (Spec-axis finding against PR #218)
