# Section durations are recorded in per-branch fragments folded on merge

Every change that added or edited tests rewrote its sections' lines in
the one durations file. Its lines sit in walk order, so two open changes
re-recording neighbouring or identical sections edited touching hunks;
GitHub then marked the later PR CONFLICTING, and with auto-sync on the
watcher filed a sync request, and each sync is a headless session plus
a resolver. Of 52 PRs carrying a Merge resolutions comment, 9 resolved a
conflict in that file (#3784).

Decision: `section-durations.sh --stale` writes only its branch's durations
fragment, beside the durations file, and never the file itself. Every reader
reads the effective record: per title the line whose fingerprint matches the
test text, from the file and every fragment; failing that the last fragment's
line in name order, then the file's line; the `shellcheck` line from the file
alone. On every push to main the
version-bump Action runs `section-durations.sh --fold`, which writes the
effective record into the durations file and deletes the fragments, measuring
nothing. A full refresh still writes the file and deletes every fragment.

Trade-off accepted: the record is spread over the file and the unfolded
fragments between a merge and its fold, and two changes that each record the
same section, with test text that merges cleanly, leave a stale line a later
change re-records.

## Considered Options

- **A `.gitattributes` merge driver.** Rejected: GitHub's mergeability check
  runs no custom merge driver, so the PR still reads CONFLICTING and the sync
  session still runs; it saves only the resolver, and only in clones that set
  the driver's git config.
- **Regenerate the file at merge time by measuring in CI.** Rejected: it drops
  the per-PR suite budget gate and the scale of the last full refresh's
  machine.
- **One durations file per section.** Rejected: about 377 files for the same
  effect.
