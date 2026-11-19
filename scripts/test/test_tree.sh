#!/usr/bin/env bash
#
# Sourced by orch_test.sh, all.sh, affected.sh, docs_lint.sh and
# scripts/dev/section-durations.sh, and by harness.sh through orch_test.sh, so
# the runners read the test tree one way: all.sh's suite list, a section
# file's titles, the section files, the files shellcheck checks, the shellcheck
# command, the pooled shellcheck step (`shellcheck_start` / `shellcheck_join`),
# the tenths conversion, the durations-file grammar, the suite budget, the
# ledger's fingerprints (`ledger_fingerprints`), the ledger's freshness rule
# (`ledger_states`) and the ORCH_TEST_ONLY pattern that affected.sh and
# section-durations.sh share (`titles_regex`). A runner that calls the step
# first sources test_jobs.sh and inits the job pool. Runs nothing.
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

# The function section_files <section dir> prints the noun files the walk
# reads, one per line: <section dir>/harness.sh, then every other
# <section dir>/*.sh but setup.sh, in LC_ALL=C order whatever the caller's
# locale. There is no list of files: a new one is read. orch_test.sh and
# ledger_fingerprints both call it, so the two walk the same files.
section_files() {
  printf '%s\n' "$1/harness.sh"
  printf '%s\n' "$1"/*.sh | LC_ALL=C sort |
    grep -vxF -e "$1/setup.sh" -e "$1/harness.sh"
}

# The function ledger_fingerprints <test dir> <suite>... prints one line,
# "<title><TAB><fingerprint>", for each test section in walk order
# (orch_test.sh's walk: section_files of <test dir>/orch), then for each named
# suite file of <test dir>, and returns 0. A
# section's fingerprint covers its own lines (its `# --- ` line to the line
# before the next) and its file's preamble (the text before the file's first
# `# --- ` line); a suite's covers the file's whole text. It starts a fixed
# number of processes whatever the number of sections (two awk, one sort, one
# grep, one git hash-object, one mktemp, one rm -rf), so the full refresh, the
# --stale mode and the docs lint can all call it. It returns 1 when a step
# fails.
ledger_fingerprints() {
  local test_dir="$1" tmp files f
  shift
  tmp="$(mktemp -d)" || return 1
  mapfile -t files < <(section_files "$test_dir/orch")
  : >"$tmp/titles"
  : >"$tmp/paths"
  awk -v dir="$tmp" "$SECTION_TITLE_AWK"'
    FNR == 1 { pre = ""; open = 0; if (cur != "") close(cur); cur = "" }
    /^# --- / {
      if (cur != "") close(cur)
      n++; cur = dir "/t." n; open = 1
      printf "%s", pre > cur
      print cur >> (dir "/paths")
      print title($0) >> (dir "/titles")
    }
    open { print > cur; next }
    { pre = pre $0 "\n" }
  ' "${files[@]}" || { rm -rf "$tmp"; return 1; }
  for f in "$@"; do
    printf '%s\n' "$test_dir/$f" >>"$tmp/paths"
    printf '%s\n' "$f" >>"$tmp/titles"
  done
  git hash-object --stdin-paths <"$tmp/paths" >"$tmp/hashes" || { rm -rf "$tmp"; return 1; }
  awk 'NR == FNR { t[NR] = $0; next } { print t[FNR] "\t" $0 }' "$tmp/titles" "$tmp/hashes"
  rm -rf "$tmp"
}

# The function ledger_fingerprints_all <test dir> reads <test dir>/all.sh's
# suites list with suites_read, fills the array LEDGER_OTHERS with every suite
# of it but orch_test.sh, and prints ledger_fingerprints of <test dir> and
# those suites. A caller that wants LEDGER_OTHERS calls it with no pipe or
# command substitution. It returns 1 when suites_read fails, SUITES_ERR then
# holding its message, else ledger_fingerprints's status.
ledger_fingerprints_all() {
  local suite
  suites_read "$1/all.sh" "$1" || return 1
  LEDGER_OTHERS=()
  for suite in "${SUITES[@]}"; do
    [ "$suite" = orch_test.sh ] || LEDGER_OTHERS+=("$suite")
  done
  ledger_fingerprints "$1" ${LEDGER_OTHERS[@]+"${LEDGER_OTHERS[@]}"}
}

# The function titles_regex prints, from section titles on stdin, one per line,
# the ERE ORCH_TEST_ONLY takes to select exactly those sections: the titles
# escaped, joined with `|`, in one anchored group. affected.sh and
# section-durations.sh both call it, so the two cannot drift.
titles_regex() {
  printf '^(%s)$\n' "$(sed 's/[].\\[*^$+?(){}|]/\\&/g' | paste -sd'|' -)"
}

# The function suite_budget_read <budget file> reads the suite budget into
# SUITE_BUDGET: the file must hold exactly one line, a positive whole number.
# It returns 0, 1 when the file is missing, 2 when it is not one positive whole
# number; each caller words its own message.
suite_budget_read() {
  local lines=()
  SUITE_BUDGET=""
  [ -f "$1" ] || return 1
  mapfile -t lines <"$1"
  if [ "${#lines[@]}" -ne 1 ] || ! [[ "${lines[0]}" =~ ^[1-9][0-9]*$ ]]; then
    return 2
  fi
  SUITE_BUDGET="${lines[0]}"
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
# digits, with an optional fourth column after the name, the ledger's
# fingerprint, which it does not read: a three- and a four-column line read
# alike. Any other line is ignored, and the first line per name wins. The
# shard dealing and the start order both start with it, so they read the file
# one way. It also defines durations_line(), true when the current record is
# such a line, for a program that reads every line itself. The function
# durations_total prints, from the durations text on stdin, the CPU column
# summed over the first line per name, in tenths of a second.
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
DURATIONS_AWK='function durations_line() {
  return ((NF == 3 || NF == 4) && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 != "")
}
function durations_read() {
  if (durations_line() && !($3 in wall)) {
    wall[$3] = $1 + 0; cpu[$3] = $2 + 0
  }
}'
durations_total() {
  awk -F'\t' "$DURATIONS_AWK"'{ durations_read() }
    END { for (name in cpu) t += cpu[name]; print t + 0 }'
}
# The function ledger_states <fingerprints> <durations file> is the one place
# the ledger's freshness rule is written. <fingerprints> holds the walk, one
# "<title><TAB><fingerprint>..." line per section or suite (the output of
# ledger_fingerprints, or lines that start with it). It prints one line,
# "<title><TAB><state><TAB><lines>", per title: first each walked title, as
# `missing` (no line), `duplicated` (more than one), `stale` (a line that is
# not four columns or whose fingerprint differs) or `fresh`; then each title of
# the durations file that the walk lacks, in line order, as `orphaned`, or
# `shellcheck` as `fresh` or `duplicated`; last `shellcheck` as `missing` when
# the file has no line for it. <lines> is how many lines the title has. A
# caller reacts to the states in its own way: it runs one awk, so the number of
# processes does not grow with the number of sections.
ledger_states() {
  awk -F'\t' "$DURATIONS_AWK"'
    FILENAME == ARGV[1] { if (!($1 in fp)) { fp[$1] = $2; ord[++n] = $1 } next }
    durations_line() {
      if (!($3 in cnt)) { nf[$3] = NF; f4[$3] = $4; lines[++m] = $3 }
      cnt[$3]++
    }
    END {
      for (i = 1; i <= n; i++) {
        t = ord[i]
        if (!(t in cnt)) { print t "\tmissing\t0"; continue }
        if (cnt[t] > 1) s = "duplicated"
        else if (nf[t] != 4 || f4[t] != fp[t]) s = "stale"
        else s = "fresh"
        print t "\t" s "\t" cnt[t]
      }
      for (i = 1; i <= m; i++) {
        t = lines[i]
        if (t in fp) continue
        if (t != "shellcheck") s = "orphaned"
        else s = (cnt[t] > 1 ? "duplicated" : "fresh")
        print t "\t" s "\t" cnt[t]
      }
      if (!("shellcheck" in cnt)) print "shellcheck\tmissing\t0"
    }' "$1" "$2"
}
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
