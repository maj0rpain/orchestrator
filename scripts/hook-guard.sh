#!/usr/bin/env bash
#
# PreToolUse hook on Edit and Write.
#
# Injected context is a suggestion that can drift an hour into a long planning
# session - which is exactly when it matters. This is the mechanism half: while
# planning is live and no flow has started, code edits are denied, and the
# rejection lands back in the model's context as a correction.
#
# The allowlist of planning artifacts, and the planning records (glossary and
# ADRs) that get their own redirect, live in planning-allowlist.sh, shared with
# orch.sh's flow-start working-tree check.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/hook-common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/planning-allowlist.sh"

hook_read_payload
# The file being written, absolute and normalized - see hook_tool_path.
file="$(hook_tool_path)"

# Only guard sessions the grilling hook has marked as planning. A payload
# with no session_id is never guarded; Junie's PreToolUse carries one from
# build 3419.7 - ADR-0023.
[ -n "$session" ] || exit 0
[ -e "${TMPDIR:-/tmp}/orchestrator-grilling-${session}" ] || exit 0
[ -n "$file" ] || exit 0

root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)" || exit 0

# A flow is already running: the guard's job is done and the phases police
# themselves from here. A done flow is not running, so it keeps the guard armed.
if hook_flow_active "$root"; then exit 0; fi

rel="${file#"$root"/}"
if planning_allowlisted "$rel"; then exit 0; fi

# Anything outside the repo is somebody else's business.
case "$file" in "$root"/*) ;; *) exit 0 ;; esac

if planning_record "$rel"; then
  hook_emit_deny "Blocked by the orchestrator: '$rel' is a record of decisions, and planning does not change records in place. $(planning_record_redirect)"
  exit 0
fi

# Named on every host: Junie's PreToolUse may lack project_path, so the host
# cannot be told apart here - ADR-0023.
reason="Blocked by the orchestrator: this is a planning session and no flow has
started, so '$rel' should not be edited yet.

Finish planning, then call the Skill tool with \"orchestrator:orch-flow\" to write the
handoff and begin the spec phase. Implementation happens in its own session, on
its own branch, from a written spec.

If the human chose quick implementation instead, either of these lifts this block:
call the Skill tool with \"orchestrator:orch-quick-implement\", or, on a host
with no Skill tool, read $(hook_quick_skill_file) with the Read tool.

Planning artifacts you may still edit: $(planning_allowlist_text)."

hook_emit_deny "$reason"
