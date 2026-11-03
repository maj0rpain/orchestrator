#!/usr/bin/env bash
#
# PreToolUse hook on Edit, Write, MultiEdit and NotebookEdit.
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
# The file being written, absolute and physical - see hook_tool_path.
file="$(hook_tool_path)"

# Only guard sessions the grilling hook has marked as planning. A payload
# with no session_id is never guarded. On Junie the grilling hook writes a
# marker under another name, which this hook never reads, so the guard does
# not arm there - ADR-0025.
[ -n "$session" ] || exit 0
[ -e "$(hook_marker_path grilling)" ] || exit 0
[ -n "$file" ] || exit 0

# The repo policed is the file's own: the git toplevel of its nearest existing
# ancestor directory. The file is physical, so the toplevel is too. The payload
# cwd follows the model's cd and decides nothing here. A file in no git repo is
# somebody else's business.
dir="${file%/*}"
while [ -n "$dir" ] && [ ! -d "$dir" ]; do dir="${dir%/*}"; done
dir="${dir:-/}"
if [ "$(git -C "$dir" rev-parse --is-inside-git-dir 2>/dev/null)" = true ]; then
  # Inside a git dir the file belongs to the repo whose git dir it is (a hook is
  # code). A git dir with core.worktree set, a submodule's absorbed one, still
  # answers --show-toplevel with its own tree, so this is asked first: judge the
  # file against the working tree above the outermost .git it sits in.
  [ "$(git -C "$dir" rev-parse --is-bare-repository 2>/dev/null)" = false ] || exit 0
  common_gitdir="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || exit 0
  # A git dir that is no .git and sits under none (a separate git dir, a bare
  # repo's) names no working tree: the file is in no working tree.
  outer_gitdir="$common_gitdir"
  case "$common_gitdir" in
    */.git) ;;
    */.git/*) outer_gitdir="${common_gitdir%%/.git/*}/.git" ;;
    *) exit 0 ;;
  esac
  root="$(cd "${outer_gitdir%/*}" && pwd -P)" || exit 0
elif ! root="$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)"; then
  exit 0
fi

# A flow is already running: the guard's job is done and the phases police
# themselves from here. A done flow is not running, so it keeps the guard armed.
state_file="$(flow_state_file "$root")"
if flow_state_active "$state_file"; then exit 0; fi

rel="${file#"$root"/}"
if planning_allowlisted "$rel"; then exit 0; fi

# Anything outside the repo is somebody else's business.
case "$file" in "$root"/*) ;; *) exit 0 ;; esac

# Under an allowlisted prefix but no planning artifact: say what to do.
if planning_excluded "$rel"; then
  if [ "$file" = "$state_file" ]; then
    hook_emit_deny "Blocked by the orchestrator: '$rel' is flow state, and flow state is written only by orch.sh. To begin a flow, call the Skill tool with \"orchestrator:orch-flow\"."
  else
    hook_emit_deny "Blocked by the orchestrator: '$rel' is another checkout's source. Edit it from a session opened in that checkout."
  fi
  exit 0
fi

if planning_record "$rel"; then
  hook_emit_deny "Blocked by the orchestrator: '$rel' is a record of decisions, and planning does not change records in place. $(planning_record_redirect)"
  exit 0
fi

# Only the Skill lift: the guard does not arm on Junie - ADR-0025.
reason="Blocked by the orchestrator: this is a planning session and no flow has
started, so '$rel' should not be edited yet.

Finish planning, then call the Skill tool with \"orchestrator:orch-flow\" to write the
handoff and begin the spec phase. Implementation happens in its own session, on
its own branch, from a written spec.

If the human chose quick implementation instead, lift this block:
call the Skill tool with \"orchestrator:orch-quick-implement\".

Planning artifacts you may still edit: $(planning_allowlist_text)."

hook_emit_deny "$reason"
