# Docs are linted by structure, never by wording

Skill, agent, command, README and glossary text is checked only by named
structural rules in `scripts/test/docs_lint.sh`: names resolve, routes reach
sections that exist, required headings are present and in order, and copies
that must match do match. No test pins a phrase or asserts that removed text
stays removed. The phrase pins caught any rewording rather than a broken
rule, and they forced a test edit on most prose-only commits. Drift between
prose copies is left to the review loop's Standards axis
(`.out-of-scope/duplicated-phase-runs-next-explanation.md`). The cost we
accept is that a sentence a model needs can be reworded or dropped without a
test failing, unless its heading goes with it.
