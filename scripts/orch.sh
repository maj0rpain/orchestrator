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
# matters, the module load and main's dispatch. Each bash noun's code lives in
# its own module, scripts/orch/<noun>.sh, named as its tests in
# scripts/test/orch/<noun>.sh are; each helper lives in the module of the
# concept it serves, and scripts/orch/common.sh holds only the primitives no
# concept owns. scripts/orch/loader.sh, loaded beside common.sh, sources the
# modules through orch_load, so this file names none. Run as a command, orch.sh
# loads a module only when one of its functions is first called, through the
# stubs orch_stubs defines. Sourced, it loads every module at once, so a
# function replaced after the source line stays replaced; the one exception is
# a plain, unexported ORCH_SOURCE_LAZY=1 set before the source line, which loads
# on demand as a command does. A sourced start always unsets the variable. A
# new noun is Python (ADR-0067), as is a noun converted to it: it has no module
# here, and main's one case naming the converted nouns hands it to the orch
# package in scripts/orch_py/, through orch_python.
# PHASES, the flow phase list, is the Handoff module's: read it after orch_load
# handoff.
#
# Usage: orch.sh <command> [args]   (run `orch.sh help` for the list)

# The modules load through orch_load, which shellcheck cannot follow, so the
# constants set here for them to read look unused to it.
# shellcheck disable=SC2034
set -euo pipefail

# The bash version guard: the first lines after the options, ahead of every
# source line, because everything sourced below needs bash 4.2 and an older bash
# would die on a raw `declare` error instead. It depends on no other file, so it
# prints its own line - the one hand-written `orch: ` message (Coding Standards,
# section 2) - and stays bash 3.2-compatible: no [[ -v ]], declare -g or ${x,,}.
# ORCH_BASH_VERSION ("<major>.<minor>") fakes the running bash, because
# BASH_VERSINFO is readonly; unset or empty, the real version is read. `exit`
# stops a sourcing shell as well, as every other stop of this file does.
ORCH_BASH_JUDGED="${ORCH_BASH_VERSION:-${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}}"
if [ "${ORCH_BASH_JUDGED%%.*}" -lt 4 ] || { [ "${ORCH_BASH_JUDGED%%.*}" -eq 4 ] && [ "${ORCH_BASH_JUDGED#*.}" -lt 2 ]; }; then
  printf 'orch: bash %s is too old - orch.sh needs bash 4.2 or newer: brew install bash\n' "$ORCH_BASH_JUDGED" >&2
  exit 1
fi
unset ORCH_BASH_JUDGED

# A tool manager's shim (mise) can print a status line on stdout ahead of the
# tool's own output, which then lands in every `$(gh ...)` capture (#465).
# Silence it for every command this script runs, doctor.sh's checks included.
# Where mise is absent this does nothing.
export MISE_QUIET=1

# The directory this script sits in, which every sourced module lives in too.
# Worked out by parameter expansion, as dirname would print it, so no call
# spawns a process to find it: a bare name means the current directory.
ORCH_SOURCE="${BASH_SOURCE[0]}"
case "$ORCH_SOURCE" in
  /*/*|[!/]*/*) ORCH_SCRIPTS="${ORCH_SOURCE%/*}" ;;
  /*) ORCH_SCRIPTS="/" ;;
  *) ORCH_SCRIPTS="." ;;
esac
# The plugin root: the directory above ORCH_SCRIPTS, which is also where every
# skill resolves orch.sh and the capabilities reference from. Resolved in a
# subshell, so it is a plain assignment, marked readonly with the rest.
ORCH_PLUGIN="$(CDPATH='' cd -- "$ORCH_SCRIPTS/.." && pwd)"
readonly ORCH_SOURCE ORCH_SCRIPTS ORCH_PLUGIN
# The Flow state module: the state format, ORCH_DIR_NAME and now, shared with
# the hooks. Marked readonly here, where orch.sh has always fixed it, since the
# module assigns it plainly.
source "$ORCH_SCRIPTS/flow-state.sh"
readonly ORCH_DIR_NAME
# The directories the plugin writes to and keeps out of git status: its flow
# state, and .scratch/, where planning drafts land. The one list both
# exclude_orch_dirs and doctor's exclude check read.
readonly EXCLUDED_DIRS=("$ORCH_DIR_NAME/" ".scratch/")
# The most issues or PRs one list call asks gh for, where gh needs a bare
# --limit. Three kinds of listing pass it. The search-backed issue listings run
# oldest first and warn when they reach it, so a cut drops the newest. The
# merged-PR close backstop's listing is search-backed too and runs newest
# created first, as its search states, and never warns, so a cut there drops the
# oldest. The other PR listings run newest first, as gh lists them, and never
# warn, so a cut drops the oldest. Overridable
# through the environment, like review ci's ORCH_CI_* knobs, so a test can turn
# it down; a raised override stops counting at ISSUE_SEARCH_CAP for every
# search-backed listing - the issue listings and the merged-PR backstop's -
# since the other PR listings run no search. It stays out of the documented
# command surface.
readonly ISSUE_LIST_LIMIT="${ORCH_ISSUE_LIST_LIMIT:-1000}"
# The most rows GitHub's search returns, whatever --limit asks for.
readonly ISSUE_SEARCH_CAP=1000

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
# A gh call failing for want of a repo in a subshell signals this shell (gh.sh):
# the trap dies with the remedy. Set here, not in repo.sh, which is loaded on
# demand and may not be loaded yet when the signal arrives.
# Its exit 1 suits commands that reserve nothing; one that reserves exit 1 for a
# "no" resolves the repo itself and dies through die2 before this can fire.
trap 'die "$REPO_REMEDY"' USR1
# The triage-label parser and LABELS_DOC, its one home; marked readonly here,
# where orch.sh has always fixed it, since the module assigns it plainly.
source "$ORCH_SCRIPTS/triage-labels.sh"
readonly LABELS_DOC
# The host module the hooks share: host_detect, host_from_project_path (#281).
source "$ORCH_SCRIPTS/host.sh"
# The primitives no concept owns, die among them, ahead of the ROOT block,
# which dies through die outside a git repository.
source "$ORCH_SCRIPTS/orch/common.sh"
# The module loader: orch_load, the load trace.
source "$ORCH_SCRIPTS/orch/loader.sh"

# Outside a checkout, the remedy names the one the caller came from: an agent
# whose cwd drifted into a mktemp directory still has OLDPWD (#1523).
if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
  target="the repo's checkout (its root or a worktree)"
  if [ -n "${OLDPWD:-}" ] && came_from="$(git -C "$OLDPWD" rev-parse --show-toplevel 2>/dev/null)"; then
    target="the checkout you came from, $came_from,"
  fi
  die "not inside a git repository ($PWD) - cd into $target and run orch.sh there; a mktemp path is for files, not the working directory"
fi
readonly ROOT
readonly ORCH="$ROOT/$ORCH_DIR_NAME"
STATE="$(flow_state_file "$ROOT")"
readonly STATE
readonly HANDOFF_DIR="$ORCH/handoff"
readonly REVIEW_DIR="$ORCH/review"
# Where an autopilot flow fetches a handoff comment to read it as a file.
readonly HANDOFF_SCRATCH_DIR="$ORCH/scratch"

# The modules, after the ROOT block, whose constants they read: every file
# beside common.sh but common.sh and loader.sh - the noun modules and the
# concept modules with no noun of their own - loaded through orch_load: run as
# a command, each on first call of one of its functions; sourced plainly, all
# of them in the C-locale order of their names without .sh. No module is named
# here.
# doctor.sh is one of the noun modules, with one rule more: the dependency runs
# one way, doctor.sh calling into this file and the other modules, which call
# nothing doctor.sh defines but cmd_doctor, from main(), and the reporters d_ok,
# d_warn, d_fail and d_remedy, from a check living in the module of the concept
# it serves (none does today: check_standards_declaration, check_agent_settings
# and check_glossary are doctor's own) (scripts/test/orch/doctor.sh holds
# this).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  orch_stubs
else
  # Sourced: every module, unless ORCH_SOURCE_LAZY is a plain, unexported 1.
  read -r _ lazy_flags _ < <(declare -p ORCH_SOURCE_LAZY 2>/dev/null || echo "declare -- x") || true
  if [ "${ORCH_SOURCE_LAZY:-}" = 1 ] && [[ "$lazy_flags" != *x* ]]; then
    orch_stubs
  else
    orch_load_all
  fi
  unset ORCH_SOURCE_LAZY lazy_flags
fi

# The one definition of the planning allowlist and the planning records,
# shared with hook-guard.sh so the flow-start check and the edit guard can
# never disagree about them.
source "$ORCH_SCRIPTS/planning-allowlist.sh"

# The -c bootstrap shared by orch_python and orch_python_call: drops the empty
# entry -c puts first on sys.path (the caller's directory) before importing
# anything, puts the package directory, argv[1], first in its place, and runs
# the orch package's __main__ through runpy so require_python stays the single
# Python 3.9+ version gate. The directory goes on sys.path, never PYTHONPATH,
# which splits a plugin path holding a colon and would hand the directory on
# to every command the noun starts; the caller's PYTHONPATH is left as given.
readonly ORCH_PYTHON_BOOTSTRAP='
import sys
if sys.path and sys.path[0] == "":
    del sys.path[0]
sys.path.insert(0, sys.argv.pop(1))
import runpy
runpy.run_module("orch", run_name="__main__", alter_sys=True)
'

# orch_python_require <noun>: checks that python3 is on PATH; warns and returns
# 1 when absent (exit 1 even for a verb that reserves 1 for a "no", the
# carve-out in coding-standards rule 2). The package's entry point checks the
# 3.9+ version itself.
orch_python_require() {
  if ! command -v python3 >/dev/null 2>&1; then
    warn "orch.sh ${1:-} needs python3 3.9 or newer (found none) - run orch.sh doctor"
    return 1
  fi
}

# orch_python <noun> [<arg>...]: runs a noun converted to Python (ADR-0067) in
# place of this process, so stdin, stdout, stderr and exit code are its own.
# `-m` itself is not used: it puts the caller's directory ahead of PYTHONPATH
# and the standard library, so a json.py or orch.py there would shadow the
# package or its imports, and Python 3.9 has no -P to stop it.
orch_python() {
  orch_python_require "${1:-}" || exit 1
  exec python3 -c "$ORCH_PYTHON_BOOTSTRAP" "$ORCH_PLUGIN/scripts/orch_py" "$@"
}

# orch_python_call [--as <command>] <noun> <func> [<arg>...]: runs a named
# function of a converted noun in a child Python process, routed through
# orch.__main__ so bash callers receive stdout, stderr and the exit code. A
# python3 missing or older than 3.9 is refused naming `orch.sh <command>`, the
# command the user ran (default <noun>), on both sides of the bridge.
orch_python_call() {
  local usage="usage: orch_python_call [--as <command>] <noun> <func> [<arg>...]"
  local as="${1:-}"
  if [ "${1:-}" = --as ]; then
    as="${2:-}"
    if [ $# -lt 4 ] || [ -z "$as" ]; then warn "$usage"; return 1; fi
    shift 2
  fi
  [ $# -ge 2 ] || { warn "$usage"; return 1; }
  orch_python_require "$as" || return 1
  python3 -c "$ORCH_PYTHON_BOOTSTRAP" "$ORCH_PLUGIN/scripts/orch_py" --call --as "$as" "$@"
}

main() {
  local cmd="${1:-help}"
  shift || true
  case "$cmd" in
    # The nouns converted to Python, the one place naming them: each runs
    # through orch_python, and has no module of its own here. Among them
    # init, phase, redo, ticket, ticket-worktree, pr and review, and the bare
    # global commands slug, status, archive and help, help with its option
    # spellings, which the Python entry point runs as help; a bare orch.sh is
    # help too.
    issue|finding-triage|verification|audit|review-pass|spec-review|spec|breakdown|glossary|parallel|route|agent|slug|status|archive|help|-h|--help|init|phase|redo|ticket|ticket-worktree|pr|review)
      orch_python "$cmd" "$@" ;;
    doctor|health) cmd_doctor "$@" ;;
    default-branch) cmd_default_branch "$@" ;;
    base)          cmd_base "$@" ;;
    autopilot)     cmd_autopilot "$@" ;;
    repo)          cmd_repo "$@" ;;
    state)         cmd_state "$@" ;;
    handoff)       cmd_handoff "$@" ;;
    branch)        cmd_branch "$@" ;;
    side-checkout) cmd_side_checkout "$@" ;;
    *) die "unknown command: $cmd (run 'orch.sh help')" ;;
  esac
}

# Run as a command, not when sourced: a test sources this file to reach a
# helper such as has_review_label directly.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then main "$@"; fi
