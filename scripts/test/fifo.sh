#!/usr/bin/env bash
#
# Sourced by orch_test.sh and autopilot_up_test.sh: the bounded wait the suite's
# FIFO handshakes use, so a partner that never arrives fails the test in
# seconds instead of hanging the run. Sourcing it only defines functions.
# Needs coreutils timeout. Bash 4.0+, as the rest of the suite.

# fifo_bounded <seconds> <side> <command...>: runs the command under timeout
# <seconds>. Only timeout's expiry status, 124, counts as expiry: then it prints
# "<side>: no partner within <seconds>s" on stderr (name the FIFO in <side>) and
# returns 124. Any other status is returned unchanged, with no message. A shell
# builtin cannot run under timeout: for a read, use fifo_read_line.
fifo_bounded() {
  local seconds="$1" side="$2" st
  shift 2
  timeout "$seconds" "$@"
  st=$?
  [ "$st" -ne 124 ] || echo "$side: no partner within ${seconds}s" >&2
  return "$st"
}

# fifo_read_line <seconds> <side> <fifo>: reads one line from the FIFO under
# fifo_bounded <seconds> <side> and prints it followed by a newline; a last line
# with no newline is yielded too. Returns fifo_bounded's status unchanged: 124
# with "<side>: no partner within <seconds>s" on stderr on expiry (the helper
# adds nothing to <side>, so name the FIFO in it), else the read's status, 0
# once a writer arrives.
fifo_read_line() {
  fifo_bounded "$1" "$2" sh -c 'IFS= read -r l <"$0"; printf "%s\n" "$l"' "$3"
}
