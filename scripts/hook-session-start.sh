#!/usr/bin/env bash
#
# Resets the session's planning markers when a fresh session starts in the
# same session ID: SessionStart with source "clear", which Claude Code fires
# on /clear and Junie on /new (per Junie CLI's bundled docs). The context the
# planning message went into is gone, so the next planning run must get it
# again, and the edit guard must not stay armed in a context that was never
# told why. hooks.json matches only "clear": compact, startup and resume keep
# the markers, because a compacted session is still the same planning session.
#
# Deletes both kinds, grilling (Claude Code, arms the edit guard) and planning
# (Junie, ADR-0025), each named through hook_marker_path. Emits no context and
# never fails the session start: no session_id, a missing marker, or a failed
# deletion all end in a silent exit 0.

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

hook_read_payload 2>/dev/null || exit 0
# The source check also stands guard for a host that ignores the matcher.
[ -n "$session" ] || exit 0
[ "$(printf '%s' "$input" | jq -r '.source // ""' 2>/dev/null)" = clear ] || exit 0

rm -f "$(hook_marker_path grilling)" "$(hook_marker_path planning)" 2>/dev/null
exit 0
