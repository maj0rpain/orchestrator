#!/usr/bin/env bash
#
# orch.sh - deterministic operations for the orchestrator plugin.
#
# Everything orch.sh does has exactly one right answer: reading and writing
# state, validating handoffs, resolving the default branch, archiving. Prose
# instructions re-derive these slightly differently every session, so they live
# here instead. Judgment lives in the flow skill; mechanism lives here.
#
# This file is the one entry point, and a thin one: every noun is Python
# (ADR-0067), run from the orch package in scripts/orch_py/ as `python3 -m orch
# <noun> ...` would run it, through the -c bootstrap below. The package owns
# the noun list, the unknown-command death and the death outside a git
# repository; this file keeps only what must run before Python can: the bash
# version guard, the python3 check and the handoff. It is run, never sourced.
#
# Usage: orch.sh <command> [args]   (run `orch.sh help` for the list)

set -euo pipefail

# The bash version guard: the first lines after the options, because the hooks
# and doctor still need bash 4.2, and an older bash would die on a raw error
# instead. It depends on no other file, so it prints its own line - a
# hand-written `orch: ` message (Coding Standards, section 2) - and stays bash
# 3.2-compatible: no [[ -v ]], declare -g or ${x,,}. ORCH_BASH_VERSION
# ("<major>.<minor>") fakes the running bash, because BASH_VERSINFO is
# readonly; unset or empty, the real version is read.
ORCH_BASH_JUDGED="${ORCH_BASH_VERSION:-${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}}"
if [ "${ORCH_BASH_JUDGED%%.*}" -lt 4 ] || { [ "${ORCH_BASH_JUDGED%%.*}" -eq 4 ] && [ "${ORCH_BASH_JUDGED#*.}" -lt 2 ]; }; then
  printf 'orch: bash %s is too old - orch.sh needs bash 4.2 or newer: brew install bash\n' "$ORCH_BASH_JUDGED" >&2
  exit 1
fi
unset ORCH_BASH_JUDGED

# A tool manager's shim (mise) can print a status line on stdout ahead of the
# tool's own output, which then lands in every `$(gh ...)` capture (#465).
# Silence it for every command the nouns run. Where mise is absent this does
# nothing.
export MISE_QUIET=1

# The plugin root: the directory above the one this script sits in, worked out
# by parameter expansion as dirname would print it (a bare name means the
# current directory), then resolved in a subshell.
ORCH_SOURCE="${BASH_SOURCE[0]}"
case "$ORCH_SOURCE" in
  /*/*|[!/]*/*) ORCH_SCRIPTS="${ORCH_SOURCE%/*}" ;;
  /*) ORCH_SCRIPTS="/" ;;
  *) ORCH_SCRIPTS="." ;;
esac
ORCH_PLUGIN="$(CDPATH='' cd -- "$ORCH_SCRIPTS/.." && pwd)"

# The -c bootstrap: drops the empty entry -c puts first on sys.path (the
# caller's directory) before importing anything, puts the package directory,
# argv[1], first in its place, and runs the orch package's __main__ through
# runpy so require_python stays the single Python 3.9+ version gate. The
# directory goes on sys.path, never PYTHONPATH, which splits a plugin path
# holding a colon and would hand the directory on to every command the noun
# starts; the caller's PYTHONPATH is left as given. `-m` itself is not used:
# it puts the caller's directory ahead of PYTHONPATH and the standard library,
# so a json.py or orch.py there would shadow the package or its imports, and
# Python 3.9 has no -P to stop it.
ORCH_PYTHON_BOOTSTRAP='
import sys
if sys.path and sys.path[0] == "":
    del sys.path[0]
sys.path.insert(0, sys.argv.pop(1))
import runpy
runpy.run_module("orch", run_name="__main__", alter_sys=True)
'

# orch_python_require <noun>: checks that python3 is on PATH; prints the
# refusal and returns 1 when absent (exit 1 even for a verb that reserves 1 for
# a "no", the carve-out in coding-standards rule 2). The refusal points at
# orch.sh doctor, but for doctor and health themselves, which name the install
# instead, as the package's entry point does on the other side: it checks the
# 3.9+ version itself. Printed here, in the `orch: ` shape, as the version
# guard prints its own line, since this file sources nothing.
orch_python_require() {
  if ! command -v python3 >/dev/null 2>&1; then
    local remedy="run orch.sh doctor"
    case "$1" in
      doctor|health) remedy="install it: brew install python3, or your platform's package manager" ;;
    esac
    printf 'orch: orch.sh %s needs python3 3.9 or newer (found none) - %s\n' "$1" "$remedy" >&2
    return 1
  fi
}

orch_python_require "${1:-help}" || exit 1
# Doctor's bash check reports the bash running this script, which Python
# cannot see: it is handed on as ORCH_RUNNING_BASH, trimmed of its
# "(1)-release" tail.
case "${1:-}" in doctor|health) export ORCH_RUNNING_BASH="${BASH_VERSION%%(*}" ;; esac
# exec, so stdin, stdout, stderr and exit code are the noun's own, and the
# process `orch.sh autopilot watch` or `orch.sh autopilot run` starts keeps its
# pid, which the watch pidfile and the run records name.
exec python3 -c "$ORCH_PYTHON_BOOTSTRAP" "$ORCH_PLUGIN/scripts/orch_py" "$@"
