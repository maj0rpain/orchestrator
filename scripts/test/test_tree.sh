#!/usr/bin/env bash
#
# Sourced by orch_test.sh and affected.sh, and by harness.sh through
# orch_test.sh, so the runners read the test tree one way: all.sh's suite list
# and a section file's titles. Runs nothing.
#
# SECTION_TITLE_AWK: the awk function title(s) as text, for a program to start
# with. It drops a header's leading `# --- `, then its trailing spaces and
# dashes. This is the one definition of a section title.
#
# suites_read <all.sh> <suite dir>: reads the suite list from the one
# `suites=(...)` line of <all.sh> into the array SUITES, with read -a and no
# eval, and returns 0. It returns 1, with SUITES_ERR holding a message with no
# prefix, when <all.sh> holds no such line or more than one, when the list is
# empty, or when a name in it is not a file in <suite dir>. A caller fails on
# its failure: a list that came back empty would make every loop run zero
# times.

# shellcheck disable=SC2034 # read by the sourcing runners
SECTION_TITLE_AWK='function title(s) { sub(/^# --- /, "", s); sub(/[ -]+$/, "", s); return s }'

suites_read() {
  local file="$1" suite_dir="$2" n line list name
  SUITES=()
  SUITES_ERR=""
  n="$(grep -c '^suites=(' "$file")" || true
  if [ "$n" -ne 1 ]; then
    SUITES_ERR="$file holds $n suites=( lines, not one"
    return 1
  fi
  line="$(grep '^suites=(' "$file")"
  list="${line#suites=(}"
  read -ra SUITES <<<"${list%%)*}"
  if [ "${#SUITES[@]}" -eq 0 ]; then
    SUITES_ERR="$file holds an empty suites list"
    return 1
  fi
  for name in "${SUITES[@]}"; do
    if [ ! -f "$suite_dir/$name" ]; then
      SUITES_ERR="$file names $name, which is no file in $suite_dir"
      return 1
    fi
  done
}
