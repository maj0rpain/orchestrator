# A shared state.json path or reader for the hooks

This project does not extract a shared helper, such as a `hook_state_file`
path function or a common state reader, for the two places the hooks read
`.orchestrator/state.json`: `hook_flow_active` in `scripts/hook-common.sh`
and the active-flow block of `scripts/hook-grilling.sh`.

## Why this is out of scope

- **The path is one line at each site.** Both build
  `$1/.orchestrator/state.json` (the grilling hook as
  `$root/.orchestrator/state.json`) in a single assignment, so a path helper
  would replace a single line with a single call.
- **The two reads react differently.** `hook_flow_active`
  (`scripts/hook-common.sh:120`) answers yes or no, and tolerates unreadable
  state: any state.json that is not at phase `done` counts as a running flow.
  The planning hook needs a JSON object, to name the flow by its issue, slug
  and phase, and leaves the flow unnamed when the file is not one.
- **No other hook script builds the path.** `hook-guard.sh` only calls
  `hook_flow_active`.

```sh
# hook_flow_active: yes or no, unreadable state still counts as a flow
local state="$1/.orchestrator/state.json"
[ -f "$state" ] || return 1
[ "$(jq -r '.phase // ""' "$state" 2>/dev/null)" != "done" ]

# hook-grilling.sh: a JSON object, read for issue, slug and phase
state="$root/.orchestrator/state.json"
if jq -e 'type == "object"' "$state" >/dev/null 2>&1; then
  flow_issue="$(jq -r '.issue // "" | tostring' "$state")"
  ...
fi
```

This is section 1 of `docs/agents/coding-standards.md`: reuse, then extract
only what reacts the same. Here the shared code is one line, and the reads
around it react differently.

Reconsider if a third hook script builds the path, or if two readers come to
need the same fields with the same reaction to unreadable state.

## Prior requests

- #694: "The new active-flow block rebuilds the `$root/.orchestrator/state.json` path and reads `.phase` from it again" - filed by the review loop as a Standards-axis major against PR #688. Declined in #851, the spec that made the planning message's Blueprint stop rule one rule.
