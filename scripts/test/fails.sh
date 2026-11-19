#!/usr/bin/env bash
#
# Sourced by orch_test.sh (the orch.sh suite's runner) and hooks_test.sh: the
# failing-command fixture, a stub (in a directory its caller puts first on PATH)
# that fails the calls matching a glob and runs the real command for the rest.
# Sourcing it only defines functions.
# Bash 4.2+, as the rest of the suite.

# fails_bin <command> <pattern> [<status> [<stderr line>]]:
# a new directory, <status> and <stderr line> optional, holding a <command>
# that fails, with exit status <status> (default 1, and 0 is allowed) after
# printing <stderr line> verbatim to stderr when one is given, when its
# arguments, space-joined and padded with a space either side, match the glob
# <pattern>, and passes every other call through to the real one; first on
# PATH, it fails those calls and nothing else.
fails_bin() {
  local dir fail="exit ${3:-1}" escaped_line escaped_quote="'\\''"
  if [ "$#" -ge 4 ]; then
    escaped_line="${4//\'/$escaped_quote}"
    fail="printf '%s\\n' '$escaped_line' >&2; $fail"
  fi
  dir="$(mktemp -d)"
  printf '%s\n' '#!/bin/sh' 'case " $* " in '"$2"') '"$fail"' ;; esac' "exec $(command -v "$1") \"\$@\"" >"$dir/$1"
  chmod +x "$dir/$1"
  printf '%s\n' "$dir"
}
