#!/usr/bin/env bash
#
# PreToolUse hook on Edit and Write.
#
# Injected context is a suggestion that can drift an hour into a long planning
# session - which is exactly when it matters. This is the mechanism half: while
# planning is live and no flow has started, code edits are denied, and the
# rejection lands back in the model's context as a correction.
#
# The allowlist of planning artifacts lives in planning-allowlist.sh, shared
# with orch.sh's flow-start working-tree check.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

hook_read_payload
# Claude Code names the file under file_path. Junie's Edit/Write input may use
# path instead, and may be relative to the working directory.
file="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // ""')"
case "$file" in ''|/*) ;; *) file="$cwd/$file" ;; esac

# Only guard sessions the grilling hook has marked as planning. A payload
# with no session_id (Junie's PreToolUse) is never guarded - ADR-0013.
[ -n "$session" ] || exit 0
[ -e "${TMPDIR:-/tmp}/orchestrator-grilling-${session}" ] || exit 0
[ -n "$file" ] || exit 0

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# A flow is already running: the guard's job is done and the phases police
# themselves from here.
if [ -f "$root/.orchestrator/state.json" ]; then exit 0; fi

rel="${file#"$root"/}"
if planning_allowlisted "$rel"; then exit 0; fi

# Anything outside the repo is somebody else's business.
case "$file" in "$root"/*) ;; *) exit 0 ;; esac

reason="Blocked by the orchestrator: this is a planning session and no flow has
started, so '$rel' should not be edited yet.

Finish planning, then call the Skill tool with \"orchestrator:orch-flow\" to write the
handoff and begin the spec phase. Implementation happens in its own session, on
its own branch, from a written spec.

Planning artifacts you may still edit: $(planning_allowlist_text)."

hook_emit_deny "$reason"
