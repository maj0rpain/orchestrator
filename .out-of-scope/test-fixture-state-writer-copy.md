# Sharing `state_write`'s value coercion with the test fixture

This project does not remove the copy of `state_write`'s jq coercion from
the `state_fixture` helper in `scripts/test/orch_test.sh`. The coercion
stores `"null"` as null and an all-digit value as a number.

## Why this is out of scope

`state_fixture` exists so tests can arrange keys that `state set` refuses
on purpose. Two ways exist to drop the copy, and both cost more than four
lines of jq:

- A test-only route into `state_write`: an env knob or a hidden subcommand
  in `orch.sh` whose only job is to let tests bypass the guards that
  `state set` exists to enforce.
- A shared filter file that `orch.sh` and the suite both read: a new
  runtime dependency, located relative to the script, just to save a test
  fixture four lines.

The risk is small and easy to see. If `state_write`'s coercion changes, the
fixture's comment says it mirrors the writer, and the behaviour tests that
read those keys back through `state get` would show any mismatch.

## Prior requests

- #311: "state_fixture copies state_write's jq coercion line for line" (filed by the review loop as a Standards-axis nit against PR #303)
