# The flow's spec phase decides an adopted issue's rewrite

Supersedes in part ADR-0034: the flow's spec phase no longer asks whether to rewrite an adopted issue from the plan. It decides by the rule that used to pick the recommended answer - rewrite when the plan changed the issue's scope or substance, else review it as it stands - and prints its decision. The human had always taken the recommended answer, so the question cost a round trip and added nothing. The rewrite itself stays attended: its test-seams check and its retire-or-keep question are still asked, and the spec review's batch still asks.

## Considered Options

- **Keep asking** - rejected, the answer never differed from the recommendation.
- **Always rewrite** - rejected, it would overwrite a blueprint that is already a spec.
- **Use the Unattended rewrite** - rejected, the flow is the route a human picks to keep control of the spec.
