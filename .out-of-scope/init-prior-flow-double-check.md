# Collapsing init's two checks for a prior flow

`cmd_init` in `scripts/orch.sh` looks at `$STATE` twice: once up front to
refuse when an unfinished flow is still active, and again further down to
archive a done one. This project keeps those as two separate checks rather
than folding them into one.

## Why this is out of scope

The two checks sit at two different points in init's precondition order, and
that order is deliberate:

```bash
if [ -f "$STATE" ] && [ "$(jq -r .phase "$STATE")" != "done" ]; then
  die "a flow is already active ..."          # 1. refuse first
fi
require_clean_outside_allowlist               # 2. dirty-tree backstop
[ -z "$issue" ] || validate_adopted_issue "$issue"   # 3. adoption check
if [ -f "$STATE" ]; then
  archive_note="$(cmd_archive)"               # 4. archive last
fi
```

Refusal has to come before anything else, so a second flow is rejected before
it can do any work. Archiving has to come after every other precondition, so
a dirty tree or a bad `--issue` leaves a done flow untouched and re-runnable
rather than archived for nothing. The steps between the two checks are why
the checks are split. Since the review finding was filed, the gap has grown:
the dirty-tree check (#126) now sits there too.

The refuse and archive steps therefore cannot merge into one branch. The most
a refactor could do is read the prior phase into a variable once and branch
on that variable twice. That swaps a cheap file test for a variable and adds
state that lives across the function, and it reads no more directly than
what is there now.

## Prior requests

- #73: "cmd_init tests [ -f "$STATE" ] twice in quick succession" - filed by
  the review loop as a Standards-axis nit against PR #72
