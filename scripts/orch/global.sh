# shellcheck shell=bash
# global.sh - orch.sh's bare global command with no module of its own:
# archive. slug, status and help are converted nouns (orch/slug.py,
# orch/status.py, orch/help.py). Its tests: scripts/test/orch/global.sh.
# Sourced by orch.sh, after common.sh and the ROOT block.

# Archive rather than delete: the moment you want a handoff back is precisely
# the moment you just threw it away. The directory is git-excluded anyway.
# In a side checkout, git worktree remove would delete the archive with the
# worktree - it deletes ignored files - so the flow moves to the main
# checkout's archive first, and only then is the worktree removed (ADR-0037).
cmd_archive() {
  require_state_exists
  local archive_home
  archive_home="$(archive_root "$ROOT")" || die "could not read the checkouts - nothing was archived"
  # Only a side checkout archives anywhere but in place.
  if [ "$archive_home" = "$ROOT" ]; then
    archive_flow "$ROOT" "$archive_home"
    return
  fi
  # A refused removal is kept and warned of: the archive has still succeeded.
  side_checkout_archive_and_remove_or_exit "$ROOT" "$archive_home" "$(pwd -P)" warn || true
}
