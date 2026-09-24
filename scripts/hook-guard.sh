#!/usr/bin/env bash
#
# PreToolUse hook on Edit and Write.
#
# Injected context is a suggestion that can drift an hour into a long planning
# session - which is exactly when it matters. This is the mechanism half: while
# planning is live and no flow has started, code edits are denied, and the
# rejection lands back in the model's context as a correction.
#
# The allowlist is the set of files the three planning entry points legitimately
# write: improve-codebase-architecture and domain-modeling update CONTEXT.md and
# ADRs inline, and wayfinder writes tickets under .scratch/ on a local tracker.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"

input="$(cat)"
session="$(printf '%s' "$input" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$input" | jq -r '.cwd // ""')"
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // ""')"

# Only guard sessions the grilling hook has marked as planning.
[ -e "${TMPDIR:-/tmp}/orchestrator-grilling-${session}" ] || exit 0
[ -n "$file" ] || exit 0

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# A flow is already running: the guard's job is done and the phases police
# themselves from here.
if [ -f "$root/.orchestrator/state.json" ]; then exit 0; fi

rel="${file#"$root"/}"
case "$rel" in
  CONTEXT.md|CONTEXT-MAP.md|docs/adr/*|docs/agents/*|.scratch/*|.orchestrator/*) exit 0 ;;
esac

# Anything outside the repo is somebody else's business.
case "$file" in "$root"/*) ;; *) exit 0 ;; esac

reason="Blocked by the orchestrator: this is a planning session and no flow has
started, so '$rel' should not be edited yet.

Finish planning, then call the Skill tool with \"orchestrator:orch-flow\" to write the
handoff and begin the spec phase. Implementation happens in its own session, on
its own branch, from a written spec.

Planning artifacts you may still edit: CONTEXT.md, CONTEXT-MAP.md, docs/adr/,
docs/agents/, .scratch/, .orchestrator/."

hook_emit_deny "$reason"
