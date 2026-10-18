scripts/orch/review.sh:363 cmd_review - gains `review known-items` op
scripts/orch/review.sh:377 review path - REVIEW_DIR/iteration-NN.md, where iteration-NN-known.md sits
scripts/orch/review.sh:501 review retire - globs iteration-*.md, will also move known files
scripts/orch/review-pass.sh:14 cmd_review_pass - gains `review-pass known-items` op; begin prints <prefix>
scripts/orch/handoff.sh:190 handoff section - prior art for heading extraction
scripts/orch/handoff.sh:16 PHASE_TABLE - Rejected alternatives / Deviations headings
scripts/orch/gh.sh:238 COMMENTS_RENDER_JQ - comment delimiter the builder splits PR/issue comments on
scripts/orch/pr.sh:257 pr comments/fetch - sources for review-pass known-items
scripts/test/docs_lint.sh:1591 scan_previously_declined - enforces five-variable review-pass prompt
scripts/test/orch/pr.sh:680 fake_pr_comment - fixture with ## Review / ## Host fallbacks
skills/orch-review/SKILL.md:81 Before the first iteration step 4 - loop boundary read
skills/orch-review/SKILL.md:108 The iteration step 2 - base sync, builder runs after it
skills/orch-review/SKILL.md:239 The reviewers - five-variable prompt and "nothing else"
skills/orch-review-pass/SKILL.md:39 Review pass steps 1-3 - begin, base SHA, five-variable prompt
skills/orch-review-pass/SKILL.md:126 Standalone step 2 - declines/rulings recognition, "hear nothing of this"
skills/orch-review-pass/SKILL.md:209 Standalone step 5 - comment headings Review/Spec rulings/Host fallbacks
skills/orch-quick-implement/SKILL.md:173 step 5 record bindings
skills/orch-quick-implement/SKILL.md:203 step 6 review pass
skills/orch-quick-implement/SKILL.md:221 step 7 PR body headings
agents/orch-reviewer-spec.md:14 prompt variables; :88 "report it anyway"; :73 report shape
agents/orch-reviewer-standards.md:123 report shape header
agents/orch-fixer.md:249 record template Waiting to be filed bullet
agents/orch-fixer.md:265 record template Filed bullet
agents/orch-implementer.md:256 hand-back Deviation line
skills/orch-handoff/SKILL.md:69 Rejected alternatives template (prose)
skills/orch-handoff/SKILL.md:147 Deviations template (prose)
docs/adr/0044-the-spec-review-hands-its-mechanical-steps-to-orch-sh.md:1 latest ADR; 0045 is free
