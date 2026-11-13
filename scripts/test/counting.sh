#!/usr/bin/env bash
#
# Sourced by orch_test.sh (the orch.sh suite's runner) and hooks_test.sh: the
# counting fixture, a stub first on PATH that logs one line each time a command
# starts and then runs the real command. Sourcing it only defines functions.
# Bash 4.2+, as the rest of the suite.

# counting_bin <cmd>: a new directory holding a #!/bin/sh <cmd> that appends one
# line per start to <dir>/<cmd>.log (created empty; callers truncate it), then
# execs the real <cmd> found now. Prints the dir.
counting_bin() {
  local dir
  dir="$(mktemp -d)"
  printf '#!/bin/sh\necho x >>"%s/%s.log"\nexec "%s" "$@"\n' "$dir" "$1" "$(command -v "$1")" >"$dir/$1"
  chmod +x "$dir/$1"
  : >"$dir/$1.log"
  printf '%s\n' "$dir"
}

# counting_starts <dir> <cmd>: how many times the <cmd> in <dir> has started.
counting_starts() { wc -l <"$1/$2.log" | tr -d ' '; }
