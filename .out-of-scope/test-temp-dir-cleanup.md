# Cleaning up the test suites' temp directories

This project does not add cleanup for the `mktemp -d` directories that its
bash test suites and test fakes create, such as `GH_FAKE_DIR` in
`scripts/test/gh_adapter_fake.sh`.

## Why this is out of scope

Leaving temp directories behind is how the whole suite works, not a slip in
one file. `orch_test.sh` makes a fresh `mktemp -d` for each fixture repo,
each fake `HOME`, each stub directory, each bare origin and each worktree,
and registers no traps. Only `docs_lint.sh` cleans up after itself, because
it owns a single fixtures root. Every directory lives under `$TMPDIR`, which
the OS clears, and a test run never reads one that an earlier run left
behind.

Fixing only the adapter fake would leave every other directory as it is.
The fake is also the hardest one to fix:

- It is sourced into each `orch.sh` subprocess through `ORCH_GH_ADAPTER`, so
  each process gets its own `GH_FAKE_DIR` by design. Its readback counters
  and the record of the last created issue are per process. A directory
  shared across the test run would change what the fake answers.
- An `EXIT` trap set while sourcing would be installed into `orch.sh`
  itself, the code under test, and any trap `orch.sh` adds later would
  replace it.

```sh
# gh_adapter_fake.sh - sourced into every orch.sh process the test starts
GH_FAKE_DIR="$(mktemp -d)"   # per process on purpose: readback state
```

Reconsider if leftover directories ever cause a real problem, such as filling
a CI runner's disk. That would call for one suite-wide temp root with a
single trap, not a fix in one file.

## Prior requests

- #337: "GH_FAKE_DIR mktemp directory in gh_adapter_fake.sh is never removed" (review-loop Standards nit against PR #332)
