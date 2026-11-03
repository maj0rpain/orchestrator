#!/usr/bin/env bash
#
# Sourced by all.sh and affected.sh, so the two runners print a suite's report
# and the shellcheck summary the same way. Runs nothing.
#
# report_suite <suite> <status> <output>: prints the suite's FAIL lines with
# their detail lines, then one summary line, "<suite>: <its last line>", or
# "<suite>: died before its summary (exit N)" when the last line of <output> is
# not a summary line, whatever <status> is, even 0. When <output> has a
# "  FAIL " line and <status> is 0, "<suite>: printed FAIL lines but exited 0"
# follows. Returns 1 when <status> is non-zero, <output> has a FAIL line, or its
# last line is not a summary line, else 0.
#
# report_shellcheck <status> <output>: prints shellcheck's summary: "shellcheck:
# 0 findings" on status 0; else each finding line then "shellcheck: N findings";
# else, with no finding line, the output then "shellcheck: failed (exit N)".
# Returns 1 unless <status> is 0.
#
# report_shellcheck_missing: prints "shellcheck: not installed - skipped".
# Returns 1 under CI (CI set and non-empty), else 0.
#
# report_temp_files_left: records a failure named "temp files", for the runner
# to call where it prints its own message about the suites' leftover temp files.
#
# report_verdict <runner> <status>: prints the run's last stdout line,
# "<runner>: PASS (<n> parts)" when <status> is 0, else "<runner>: FAIL (<part>,
# <part>, ...)". n counts the summary lines the report functions printed; the
# failed parts are those functions' failures, in the order they were called.
# Call it last. Returns <status>.

REPORT_PARTS=0
REPORT_FAILED=()

# report_note <part> <rc>: counts <part> as a part, and as a failed one when
# <rc> is non-zero. Returns <rc>.
report_note() {
  REPORT_PARTS=$((REPORT_PARTS + 1))
  [ "$2" -eq 0 ] || REPORT_FAILED+=("$1")
  return "$2"
}

_report_suite() {
  local suite="$1" status="$2" out="$3" fail_block last rc=0
  fail_block="$(printf '%s\n' "$out" | awk '
    in_fail && /^     / { print; next }
    { in_fail = 0 }
    /^  FAIL / { print; in_fail = 1 }')"
  [ -z "$fail_block" ] || printf '%s\n' "$fail_block"
  last="$(printf '%s\n' "$out" | tail -n 1)"
  if ! [[ "$last" =~ ^[0-9]+\ passed,\ [0-9]+\ failed(,\ [0-9]+\ skipped)?$ ]]; then
    echo "$suite: died before its summary (exit $status)"
    rc=1
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

_report_shellcheck() {
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

report_suite() {
  local rc=0
  _report_suite "$@" || rc=1
  report_note "$1" "$rc"
}

report_shellcheck() {
  local rc=0
  _report_shellcheck "$@" || rc=1
  report_note shellcheck "$rc"
}

report_shellcheck_missing() {
  local rc=0
  echo "shellcheck: not installed - skipped"
  [ -n "${CI:-}" ] && rc=1
  report_note shellcheck "$rc"
}

report_temp_files_left() {
  REPORT_FAILED+=("temp files")
}

report_verdict() {
  local runner="$1" status="$2" list="" part
  if [ "$status" -eq 0 ]; then
    echo "$runner: PASS ($REPORT_PARTS parts)"
  else
    for part in "${REPORT_FAILED[@]}"; do list+="${list:+, }$part"; done
    echo "$runner: FAIL ($list)"
  fi
  return "$status"
}
