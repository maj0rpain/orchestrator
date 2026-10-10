#!/usr/bin/env bash
#
# orch.sh - deterministic operations for the orchestrator plugin.
#
# Everything orch.sh does has exactly one right answer: reading and writing
# state, validating handoffs, resolving the default branch, archiving. Prose
# instructions re-derive these slightly differently every session, so they live
# here instead. Judgment lives in the flow skill; mechanism lives here.
#
# This file is the one entry point, and a thin one: path resolution, the
# constants more than one module reads, the top-level statements whose order
# matters, the source list and main's dispatch. Each noun's code lives in its
# own module, scripts/orch/<noun>.sh, named as its tests in
# scripts/test/orch/<noun>.sh are; the helpers more than one module uses live
# in scripts/orch/common.sh. Every module is sourced eagerly, from the explicit
# list below, so a missing one fails at startup naming the file. A new noun
# gets its own module, a case in main and a line in that list.
#
# Usage: orch.sh <command> [args]   (run `orch.sh help` for the list)

set -euo pipefail

# A tool manager's shim (mise) can print a status line on stdout ahead of the
# tool's own output, which then lands in every `$(gh ...)` capture (#465).
# Silence it for every command this script runs, doctor.sh's checks included.
# Where mise is absent this does nothing.
export MISE_QUIET=1

readonly ORCH_DIR_NAME=".orchestrator"
# The directories the plugin writes to and keeps out of git status: its flow
# state, and .scratch/, where planning drafts land. The one list both
# exclude_orch_dirs and doctor's exclude check read.
readonly EXCLUDED_DIRS=("$ORCH_DIR_NAME/" ".scratch/")
readonly PHASES="spec implement review done"
# The directory this script sits in, which every sourced module lives in too.
# Worked out by parameter expansion, as dirname would print it, so no call
# spawns a process to find it: a bare name means the current directory.
ORCH_SOURCE="${BASH_SOURCE[0]}"
case "$ORCH_SOURCE" in
  /*/*|[!/]*/*) ORCH_SCRIPTS="${ORCH_SOURCE%/*}" ;;
  /*) ORCH_SCRIPTS="/" ;;
  *) ORCH_SCRIPTS="." ;;
esac
readonly ORCH_SOURCE ORCH_SCRIPTS
# The most issues or PRs one list call asks gh for, where gh needs a bare
# --limit: the labelled-issue list finding-triage scan reads, and the merged-PR
# bodies pr release reads. A list that reaches it may be missing entries past
# it. Overridable through the environment, like review.sh's ORCH_CI_* knobs,
# so a test can turn it down; it stays out of the documented command surface.
readonly ISSUE_LIST_LIMIT="${ORCH_ISSUE_LIST_LIMIT:-1000}"
# The severities a filed finding carries as review:<severity> - the ones
# `review file` files. Blocking is always fixed in the loop, never filed.
readonly FILED_SEVERITIES="major nit"

# The repo orch.sh works on (#520): GH_REPO when the caller set it, else the
# owner/name parsed from the checkout's origin remote - never gh's own default
# repo, which in a fork is the upstream. repo_resolve sets REPO_NAME to
# [HOST/]OWNER/REPO and REPO_SOURCE to GH_REPO or origin, printing nothing; it
# returns non-zero, with both empty, when nothing resolves. A caller that must
# have a repo dies with REPO_REMEDY; doctor reports REPO_CAUSE, giving the
# remedy on a line of its own, and names the bare REPO_MISSING on its skipped
# line.
REPO_MISSING="no GitHub repo to work on"
REPO_CAUSE="$REPO_MISSING: origin is missing or not a GitHub owner/name"
REPO_REMEDY="$REPO_CAUSE - set GH_REPO=<owner>/<repo>"
readonly SIDE_CHECKOUT_MARKER="orchestrator-side-checkout"
# The triage-label parser and LABELS_DOC, its one home; marked readonly here,
# where orch.sh has always fixed it, since the module assigns it plainly.
source "$ORCH_SCRIPTS/triage-labels.sh"
readonly LABELS_DOC
# The one host detector, host_detect, shared with the hooks (#281).
source "$ORCH_SCRIPTS/host.sh"
# The shared helpers, die among them, ahead of the ROOT block, which dies
# through die outside a git repository.
source "$ORCH_SCRIPTS/orch/common.sh"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository ($PWD) - run orch.sh from inside the repo's checkout"
readonly ROOT
readonly ORCH="$ROOT/$ORCH_DIR_NAME"
readonly STATE="$ORCH/state.json"
readonly HANDOFF_DIR="$ORCH/handoff"
readonly REVIEW_DIR="$ORCH/review"
readonly TICKET_WORKTREES="$ORCH/worktrees"

# The noun modules, after the ROOT block, whose constants they read. doctor.sh
# is one of them, with one rule more: the dependency runs one way, doctor.sh
# calling into this file and the other modules, which call nothing doctor.sh
# defines but cmd_doctor, from main() (scripts/test/orch/doctor.sh holds this).
source "$ORCH_SCRIPTS/orch/base.sh"
source "$ORCH_SCRIPTS/orch/branch.sh"
source "$ORCH_SCRIPTS/orch/doctor.sh"
source "$ORCH_SCRIPTS/orch/finding-triage.sh"
source "$ORCH_SCRIPTS/orch/gh.sh"
source "$ORCH_SCRIPTS/orch/global.sh"
source "$ORCH_SCRIPTS/orch/handoff.sh"
source "$ORCH_SCRIPTS/orch/init.sh"
source "$ORCH_SCRIPTS/orch/issue.sh"
source "$ORCH_SCRIPTS/orch/parallel.sh"
source "$ORCH_SCRIPTS/orch/phase.sh"
source "$ORCH_SCRIPTS/orch/pr.sh"
source "$ORCH_SCRIPTS/orch/redo.sh"
source "$ORCH_SCRIPTS/orch/repo.sh"
source "$ORCH_SCRIPTS/orch/review.sh"
source "$ORCH_SCRIPTS/orch/review-pass.sh"
source "$ORCH_SCRIPTS/orch/side-checkout.sh"
source "$ORCH_SCRIPTS/orch/spec.sh"
source "$ORCH_SCRIPTS/orch/spec-review.sh"
source "$ORCH_SCRIPTS/orch/state.sh"
source "$ORCH_SCRIPTS/orch/ticket.sh"
source "$ORCH_SCRIPTS/orch/ticket-worktree.sh"

# The one definition of the planning allowlist and the planning records,
# shared with hook-guard.sh so the flow-start check and the edit guard can
# never disagree about them.
source "$ORCH_SCRIPTS/planning-allowlist.sh"

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    doctor)        cmd_doctor "$@" ;;
    default-branch) cmd_default_branch "$@" ;;
    base)          cmd_base "$@" ;;
    parallel)      cmd_parallel "$@" ;;
    repo)          cmd_repo "$@" ;;
    init)          cmd_init "$@" ;;
    slug)          cmd_slug "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    phase)         cmd_phase "$@" ;;
    branch)        cmd_branch "$@" ;;
    issue)         cmd_issue "$@" ;;
    pr)            cmd_pr "$@" ;;
    ticket)        cmd_ticket "$@" ;;
    ticket-worktree) cmd_ticket_worktree "$@" ;;
    side-checkout) cmd_side_checkout "$@" ;;
    review)        cmd_review "$@" ;;
    spec)          cmd_spec "$@" ;;
    spec-review)   cmd_spec_review "$@" ;;
    review-pass)   cmd_review_pass "$@" ;;
    finding-triage) cmd_finding_triage "$@" ;;
    redo)          cmd_redo "$@" ;;
    status)        cmd_status "$@" ;;
    archive)       cmd_archive "$@" ;;
    help|-h|--help) cmd_help ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

# Run as a command, not when sourced: a test sources this file to reach a
# helper such as is_filed_severity directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
