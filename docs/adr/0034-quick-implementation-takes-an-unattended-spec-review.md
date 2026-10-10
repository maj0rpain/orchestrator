# Quick implementation takes an unattended spec review

Supersedes in part ADR-0004: in a quick implementation the spec review applies its own recommendations; the human's control there is the choice of route.

Quick implementation is meant for small changes, run hands-off. Yet each run stopped at up to three spec-review questions - whether to run a review at all, the batch, and the ticket follow-up when a linked blueprint's tickets were touched - plus `orch-to-tickets`' breakdown quiz. A human who picked quick implementation to walk away from small work had to keep coming back.

So quick implementation always runs a spec review, unattended: it prints its batch and applies every recommendation - decision items and the ticket follow-up included, retiring included - and then accepts its own draft ticket breakdown without the quiz. It also rewrites an interviewed issue from the plan unattended, when the plan changed its scope or substance, by `orch-to-spec`'s **Unattended rewrite**, before that review. The mode is defined once, in `orch-spec-review`'s **Unattended spec review**, `orch-to-tickets`' **Unattended breakdown** and `orch-to-spec`'s **Unattended rewrite**, and only quick implementation takes it. A human-run spec review, the flow's spec phase and the Blueprint route still ask.

Decision items are taken without the human, so the PR body lists each one, with the option taken, under **Spec review decisions**, and the review's changelog comment opens by saying it was applied unattended. A human who wants control of the spec uses a flow or a blueprint.

## Considered Options

- **Keep asking.** Rejected: it defeats hands-off.
- **Skip the spec review entirely.** Rejected: the review is cheap and catches gaps an unattended implementer would otherwise build on.
- **Override the questions in quick implementation's own prose.** Rejected: the batch rules would be defined twice, and two definitions of one review drift apart (ADR-0029).
