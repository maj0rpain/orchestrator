#!/usr/bin/env bash
#
# Sourced by all.sh and affected.sh, so the two runners print a suite's report
# and the shellcheck summary the same way. Runs nothing.
#
# report_suite <suite> <status> <output>: prints the suite's FAIL lines with
# their detail lines, then one summary line, "<suite>: <its last line>", or
# "<suite>: died before its summary (exit N)" when <status> is non-zero and the
# last line of <output> is not a summary line. When <output> has a "  FAIL "
# line and <status> is 0, "<suite>: printed FAIL lines but exited 0" follows.
# Returns 1 when <status> is non-zero or <output> has a FAIL line, else 0.
#
# report_shellcheck <status> <output>: prints shellcheck's summary: "shellcheck:
# 0 findings" on status 0; else each finding line then "shellcheck: N findings";
# else, with no finding line, the output then "shellcheck: failed (exit N)".
# Returns 1 unless <status> is 0.

report_suite() {
  local suite="$1" status="$2" out="$3" fail_block last rc=0
  fail_block="$(printf '%s\n' "$out" | awk '
    in_fail && /^     / { print; next }
    { in_fail = 0 }
    /^  FAIL / { print; in_fail = 1 }')"
  [ -z "$fail_block" ] || printf '%s\n' "$fail_block"
  last="$(printf '%s\n' "$out" | tail -n 1)"
  if [ "$status" -ne 0 ] &&
    ! [[ "$last" =~ ^[0-9]+\ passed,\ [0-9]+\ failed(,\ [0-9]+\ skipped)?$ ]]; then
    echo "$suite: died before its summary (exit $status)"
  else
    echo "$suite: $last"
  fi
  [ "$status" -ne 0 ] && rc=1
  if [ -n "$fail_block" ]; then
    [ "$status" -eq 0 ] && echo "$suite: printed FAIL lines but exited 0"
    rc=1
  fi
  return "$rc"
}

report_shellcheck() {
  local status="$1" out="$2" findings
  findings="$(printf '%s\n' "$out" | awk '/^[^:]+:[0-9]+:[0-9]+: /')"
  if [ "$status" -eq 0 ]; then
    echo "shellcheck: 0 findings"
  elif [ -n "$findings" ]; then
    printf '%s\n' "$findings"
    echo "shellcheck: $(printf '%s\n' "$findings" | awk 'END { print NR }') findings"
    return 1
  else
    [ -n "$out" ] && printf '%s\n' "$out"
    echo "shellcheck: failed (exit $status)"
    return 1
  fi
}
