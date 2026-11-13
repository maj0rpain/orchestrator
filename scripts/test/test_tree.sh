#!/usr/bin/env bash
#
# Sourced by orch_test.sh, all.sh, affected.sh and
# scripts/dev/section-durations.sh, and by harness.sh through orch_test.sh, so
# the runners read the test tree one way: all.sh's suite list, a section
# file's titles, the files shellcheck checks, the shellcheck command, the
# pooled shellcheck step (`shellcheck_start` / `shellcheck_join`), the tenths
# conversion and the durations-file grammar. A runner that calls the step first
# sources test_jobs.sh and inits the job pool. Runs nothing.
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

# suites_unlisted <all.sh> <suite dir>: reads the list with suites_read, then
# prints, in name order, one line per runner in <suite dir> that the list does
# not name, and returns 0; nothing when every runner is listed. A runner is a
# top-level <suite dir>/*.sh with a line that starts `source ` or `. ` and ends
# `tally.sh"`. Each line reads `orch: scripts/test/<x>.sh sources tally.sh but
# is not in all.sh's suites list`. When suites_read fails it prints nothing and
# returns 1, with SUITES_ERR holding the reader's message.
suites_unlisted() {
  local file="$1" suite_dir="$2" path name listed s
  suites_read "$file" "$suite_dir" || return 1
  for path in "$suite_dir"/*.sh; do
    [ -f "$path" ] || continue
    grep -Eq '^(source |\. ).*tally\.sh"$' "$path" || continue
    name="${path##*/}"
    listed=no
    for s in "${SUITES[@]}"; do
      [ "$s" = "$name" ] && listed=yes
    done
    [ "$listed" = yes ] ||
      echo "orch: scripts/test/$name sources tally.sh but is not in all.sh's suites list"
  done
  return 0
}

# The function shellcheck_files <root> fills the array SHELLCHECK_FILES with
# the shell files shellcheck checks, the one recursive glob
# <root>/scripts/**/*.sh in glob order; a glob that matches nothing leaves it
# empty. all.sh and section-durations.sh both call it, so the two cannot drift.
shellcheck_files() {
  local had_globstar=0 had_nullglob=0
  shopt -q globstar && had_globstar=1
  shopt -q nullglob && had_nullglob=1
  shopt -s globstar nullglob
  SHELLCHECK_FILES=("$1"/scripts/**/*.sh)
  [ "$had_globstar" -eq 1 ] || shopt -u globstar
  [ "$had_nullglob" -eq 1 ] || shopt -u nullglob
}

# TENTHS_AWK: the awk function tenths(s) as text, for a program to start with.
# It reads seconds with one decimal place, as bash's `time` prints them under
# LC_NUMERIC=C, and returns tenths of a second; a caller sets LC_NUMERIC=C
# before `time`. orch_test.sh's timed child and section-durations.sh use it.
#
# DURATIONS_AWK: awk text for a program run with -F'\t', defining the function
# durations_read(), which reads the current record of section-durations.tsv
# into the arrays wall and cpu, in tenths of a second, keyed by name. A line
# is "<wall>", "<cpu>" and a non-empty name, tab-separated, the two numbers
# digits; any other line is ignored, and the first line per name wins. The
# shard dealing and the start order both start with it, so they read the file
# one way.
#
# SHELLCHECK_CMD: the array holding the one shellcheck invocation, run from the
# repo root with the files to check appended. all.sh, affected.sh and
# section-durations.sh all run it, so the three cannot drift.
#
# The functions shellcheck_start and shellcheck_join (below): all.sh and
# section-durations.sh's pooled shellcheck step; the caller sources
# test_jobs.sh and inits the pool, and stops SHELLCHECK_PIDS with
# test_jobs_stop_children on INT and TERM.
# shellcheck disable=SC2034 # read by the sourcing runners
TENTHS_AWK='function tenths(s) { sub(/\./, "", s); return s + 0 }'
# shellcheck disable=SC2034 # read by the sourcing runners
DURATIONS_AWK='function durations_read() {
  if (NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 != "" && !($3 in wall)) {
    wall[$3] = $1 + 0; cpu[$3] = $2 + 0
  }
}'
# shellcheck disable=SC2034 # read by the sourcing runners
SHELLCHECK_CMD=(shellcheck -S warning -f gcc)

# The function shellcheck_start <root> <outdir> <jobs> runs SHELLCHECK_CMD on
# each file of SHELLCHECK_FILES from <root>, one process per file, each holding
# a job-pool slot, at most <jobs> at once. Process <n>'s output goes to
# <outdir>/shellcheck.<n>. Sets SHELLCHECK_PIDS, and SHELLCHECK_EXITS at the
# same index for each process already waited for to keep <jobs> running.
shellcheck_start() {
  local root="$1" outdir="$2" jobs="$3" file rel next=0
  SHELLCHECK_PIDS=()
  SHELLCHECK_EXITS=()
  for file in "${SHELLCHECK_FILES[@]}"; do
    while [ "$((${#SHELLCHECK_PIDS[@]} - next))" -ge "$jobs" ]; do
      wait "${SHELLCHECK_PIDS[$next]}"
      SHELLCHECK_EXITS[next]=$?
      next=$((next + 1))
    done
    rel="${file#"$root/"}"
    test_jobs_slot_wait
    (cd "$root" && test_jobs_job "${SHELLCHECK_CMD[@]}" "$rel") \
      >"$outdir/shellcheck.${#SHELLCHECK_PIDS[@]}" 2>&1 &
    SHELLCHECK_PIDS+=("$!")
    test_jobs_slot_release "$!"
  done
}

# The function shellcheck_join <outdir> waits for each process whose exit
# SHELLCHECK_EXITS lacks; sets SHELLCHECK_STATUS to the highest exit and
# SHELLCHECK_OUT to the non-empty outputs joined in start order.
shellcheck_join() {
  local outdir="$1" n exit_code part
  SHELLCHECK_STATUS=0
  SHELLCHECK_OUT=""
  for n in "${!SHELLCHECK_PIDS[@]}"; do
    if [ -n "${SHELLCHECK_EXITS[$n]:-}" ]; then
      exit_code="${SHELLCHECK_EXITS[$n]}"
    else
      wait "${SHELLCHECK_PIDS[$n]}"
      exit_code=$?
    fi
    [ "$exit_code" -gt "$SHELLCHECK_STATUS" ] && SHELLCHECK_STATUS=$exit_code
    part="$(<"$outdir/shellcheck.$n")"
    [ -n "$part" ] && SHELLCHECK_OUT+="${SHELLCHECK_OUT:+$'\n'}$part"
  done
  return 0
}
