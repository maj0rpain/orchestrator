#!/usr/bin/env bash
#
# The runner for the orch.sh suite, whose tests live in scripts/test/orch/.
#
# This file is the suite's runner and its one entry point; it holds no test.
# The tests live under scripts/test/orch/: every `# ---` section in the file
# for the orch.sh noun it tests, scripts/test/orch/<noun>.sh (the harness's own
# sections in harness.sh), and the shared setup and the summary in setup.sh.
# A ticket's tests go in the file for the noun it touches; a new noun gets a
# new file, which the runner picks up with no edit here. A noun file holds
# only `# ---` sections, optionally preceded by its preamble: the text before
# its first `# ---` line, eval'd before that file's sections whenever one of
# them runs. Every preamble opens with the same shellcheck lines - the shell
# directive and a never-true `(( 0 )) && source setup.sh` behind a
# `source=setup.sh` directive - so all.sh's shellcheck follows setup.sh's
# definitions; a new noun file copies them.
#
# orch.sh is where silent wrongness hides: `doctor` returning success on a
# deleted branch, a missing triage label, or a handoff with an empty required
# section, are bugs you would experience as generic confusion three phases
# later - or, worse, as a phase that dies once the session that could have
# fixed it has been cleared. Each runs
# against a throwaway git repo in $TMPDIR.
#
# What keeps the suite off a real flow is setup.sh's shared setup, not
# section order: before any section runs it cd's into a fresh `mktemp -d`
# directory that is no git repo, points HOME (and SUITE_HOME, which sections
# restore) at a fresh temp directory, and unsets CLAUDE_PLUGIN_ROOT - exiting
# non-zero if it cannot. A section run on its own that forgets to arrange its own repo
# then fails against an empty directory instead of the caller's checkout. The
# isolation section, the suite's first, asserts all of this.
#
# Nor does the suite reach the real gh. The shared setup puts a stub gh first
# on PATH that logs each call and fails, and the summary turns every logged
# call into one FAIL naming it. A section that runs orch.sh against a repo with
# a GitHub origin installs fake_github first, or uses orch_gh_failing where it
# tests gh's own argv; the fixture gh, prepended later, still wins over it.
#
# Every section must pass on its own, as the parallel runner runs each one; where a helper lives is CONTRIBUTING.md's Develop section.

# The suite's own directory, walked to once; every path below builds on it.
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH="$(cd "$TEST_DIR/.." && pwd)/orch.sh"
# shellcheck disable=SC2034 # read by the sections, eval'd from scripts/test/orch/
GH_ADAPTER_FAKE="$TEST_DIR/gh_adapter_fake.sh"
# shellcheck disable=SC2034 # read by the sections, eval'd from scripts/test/orch/
PLUGIN_ROOT="$(cd "$(dirname "$ORCH")/.." && pwd)"
SUITE_SCRIPT="$TEST_DIR/$(basename "${BASH_SOURCE[0]}")"
SECTION_DIR="$TEST_DIR/orch"
SETUP_FILE="$SECTION_DIR/setup.sh"

# The temp root. Every invocation - the parallel runner, each of its children,
# a sequential or filtered run - first creates one temp directory and exports
# TMPDIR as it, so every mktemp below, orch.sh's own included, lands inside it;
# a child's root nests inside its runner's. The EXIT trap leaves the root
# (whose subdirectories may be the cwd), makes it writable again, removes it,
# and keeps the exit status. An INT or TERM exits 130 through that trap; the
# parallel runner replaces this INT/TERM trap with its own.
orch_root="$(mktemp -d)" || {
  echo "orch_test.sh: cannot create the suite's temp root" >&2; exit 1; }
export TMPDIR="$orch_root"
orch_remove_root() {
  local status=$?
  cd / || :
  chmod -R u+w "$orch_root" 2>/dev/null
  rm -rf "$orch_root"
  exit "$status"
}
trap orch_remove_root EXIT
trap 'exit 130' INT TERM

# The section filter. With ORCH_TEST_ONLY=<ERE> set, the suite runs only the
# shared setup, the isolation section, every section whose title - the text
# after `# --- `, trailing dashes dropped - matches under grep -E, each behind
# its file's preamble, and the summary. The text is extracted from the section
# files and eval'd, so no file is written. A pattern that matches no section
# exits 1, printing the selectable section titles, in walk order, one per line.
#
# The parallel runner. ORCH_TEST_JOBS sets how many sections run at once:
# by default the core count (getconf _NPROCESSORS_ONLN, or 4 when that fails);
# 1 runs the suite - or the filtered text - in this one shell, sequentially.
# A value that is not a positive integer exits 1 before any section runs.
# Above 1, each section chosen (every one, or the isolation section plus those
# ORCH_TEST_ONLY matches) runs as its own child: this script re-invoked with
# ORCH_TEST_JOBS=1 and an internal variable naming the section's position, so
# the child runs the shared setup, its file's preamble, that one section and
# the summary - and isolation runs once, in its own child. A child prints
# neither the banner nor the summary block; it writes its counts to a file
# instead. This shell prints the banner, each child's stdout in walk order,
# then one summary summed over the children, so the stdout is the stdout of a
# sequential run. stderr passes straight through and may interleave. A child
# that reports no counts - it exited mid-way - adds a FAIL naming its section.
# Exits 1 when any child failed. Buffers live in one temp directory under the
# temp root; an interrupt also kills the running children and waits for them
# to exit.

# section_files: the noun files the walk reads, one per line - harness.sh,
# then every other scripts/test/orch/*.sh but setup.sh, in LC_ALL=C order
# whatever the caller's locale. There is no list of files: a new one is read.
section_files() {
  printf '%s\n' "$SECTION_DIR/harness.sh"
  printf '%s\n' "$SECTION_DIR"/*.sh | LC_ALL=C sort |
    grep -vxF -e "$SETUP_FILE" -e "$SECTION_DIR/harness.sh"
}

# The walk section_titles and section_text share, over setup.sh, the noun
# files, then setup.sh again. Each line is in one phase. "setup" is setup.sh's
# shared setup (from its `# >>> shared setup` line to its `# >>> summary` line),
# read the first time; "summary" its summary (from its `# >>> summary` line),
# read the second time; "skip" the rest of setup.sh. In a noun file, "preamble"
# is the text before its first `# --- ` line, and "sections" the rest, each
# `# --- ` header numbering its section n across the whole walk, so isolation,
# harness.sh's first, is 1. title() drops a header's `# --- ` and trailing
# dashes.
section_walk_awk='
  function title(s) { sub(/^# --- /, "", s); sub(/[ -]+$/, "", s); return s }
  BEGIN { setup = ENVIRON["ORCH_SETUP_FILE"] }
  FNR == 1 { phase = "skip"; pre = ""; shown = 0; if (FILENAME == setup) setups++; else phase = "preamble" }
  FILENAME == setup && $0 == "# >>> shared setup" { if (setups == 1) phase = "setup"; next }
  FILENAME == setup && $0 == "# >>> summary" { phase = setups == 1 ? "skip" : "summary" }
  phase == "preamble" && /^# --- / { phase = "sections" }
  phase == "sections" && /^# --- / { n++ }
'

# section_walk <awk program> [awk options]: run the walk with the program
# appended over setup.sh, the noun files and setup.sh.
section_walk() {
  local program="$1" files
  shift
  mapfile -t files < <(section_files)
  ORCH_SETUP_FILE="$SETUP_FILE" awk "$@" "$section_walk_awk$program" \
    "$SETUP_FILE" "${files[@]}" "$SETUP_FILE"
}

# section_titles: print every section's title, in walk order, one per line.
# Position 1 is isolation.
section_titles() {
  section_walk '
    phase == "sections" && /^# --- / { print title($0) }
  '
}

# section_text <keep>: print the text to eval - the shared setup, the sections
# whose 1-based positions appear in keep, a comma-wrapped list such as ",1,4,",
# each file's preamble before the first of its kept sections, and the summary.
# A file none of whose sections is kept contributes nothing.
section_text() {
  section_walk '
    phase == "preamble" { pre = pre $0 "\n"; next }
    phase == "sections" && /^# --- / {
      kept = index(keep, "," n ",") > 0
      if (kept && !shown) { printf "%s", pre; shown = 1 }
    }
    phase == "setup" || phase == "summary" || (phase == "sections" && kept)
  ' -v keep="$1"
}

# The kept set that holds isolation alone: it seeds a filter's kept set, so a
# filter whose set is still this one matched no section.
readonly orch_kept_isolation=",1,"

# print_summary <pass> <fail> <skip>: the suite's closing lines, a blank line
# then the counts, the skips only when there were any. The parallel runner and
# the summary section both print through it, so their stdout cannot drift apart.
print_summary() {
  echo
  if [ "$3" -gt 0 ]; then
    echo "$1 passed, $2 failed, $3 skipped"
  else
    echo "$1 passed, $2 failed"
  fi
}

# print_fail <title> <detail>: one FAIL line and its detail line. bad() and the
# parallel runner both print through it, so their FAIL lines cannot drift apart.
print_fail() { printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# A child of the parallel runner: run its one section, and hand the counts file
# to the summary through a plain, unexported variable, so a suite this section
# starts in turn is no child.
orch_child_counts=""
if [ -n "${ORCH_TEST_CHILD_SECTION:-}" ]; then
  orch_child_section="$ORCH_TEST_CHILD_SECTION"
  # shellcheck disable=SC2034 # read by the summary, eval'd from setup.sh
  orch_child_counts="$ORCH_TEST_CHILD_COUNTS"
  unset ORCH_TEST_CHILD_SECTION ORCH_TEST_CHILD_COUNTS
  eval "$(section_text ",$orch_child_section,")"
  exit $?
fi

# True when $1 is digits only and its value is above zero, so `00` is no
# positive integer either.
is_positive_integer() {
  case "$1" in '' | *[!0-9]*) return 1 ;; esac
  [ "$((10#$1))" -gt 0 ]
}

if [ -n "${ORCH_TEST_JOBS+set}" ]; then
  orch_jobs="$ORCH_TEST_JOBS"
else
  orch_jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
  is_positive_integer "$orch_jobs" || orch_jobs=4
fi
if ! is_positive_integer "$orch_jobs"; then
  echo "orch_test.sh: ORCH_TEST_JOBS='$orch_jobs' is not a positive integer" >&2
  exit 1
fi
orch_jobs=$((10#$orch_jobs))

# Every run, sequential or parallel, filtered or not, evals the text the walk
# extracts for its kept set: no section runs from this file itself.
orch_titles="$(section_titles)"
if [ -n "${ORCH_TEST_ONLY:-}" ]; then
  orch_kept="$orch_kept_isolation$(printf '%s\n' "$orch_titles" | grep -nE -- "$ORCH_TEST_ONLY" | cut -d: -f1 | tr '\n' ',')"
  if [ "$orch_kept" = "$orch_kept_isolation" ]; then
    echo "orch_test.sh: ORCH_TEST_ONLY='$ORCH_TEST_ONLY' matches no section; the selectable sections are:" >&2
    printf '%s\n' "$orch_titles"
    exit 1
  fi
else
  orch_kept=",$(printf '%s\n' "$orch_titles" | awk '{ print NR }' | tr '\n' ',')"
fi
if [ "$orch_jobs" -eq 1 ]; then
  eval "$(section_text "$orch_kept")"
  exit $?
fi

orch_buf="$(mktemp -d)" || {
  echo "orch_test.sh: cannot create a temp directory for the section buffers" >&2; exit 1; }
orch_pids=()
orch_sections=()
# Kill the children, then wait for each to exit, so the root is removed
# only once no child can still write into it.
orch_stop_children() {
  local pid
  kill "${orch_pids[@]}" 2>/dev/null
  for pid in "${orch_pids[@]}"; do wait "$pid"; done
  exit 130
}
trap orch_stop_children INT TERM
IFS=, read -r -a orch_sections <<<"${orch_kept#,}"
orch_total=${#orch_sections[@]}
orch_started=0 orch_flushed=0 orch_pass=0 orch_fail=0 orch_skip=0 orch_any_failed=0
echo "orch.sh tests"
while [ "$orch_flushed" -lt "$orch_total" ]; do
  # Start children while a slot is free: a slot is held by every child
  # started and still alive.
  orch_running=0
  orch_i=$orch_flushed
  while [ "$orch_i" -lt "$orch_started" ]; do
    kill -0 "${orch_pids[$orch_i]}" 2>/dev/null && orch_running=$((orch_running + 1))
    orch_i=$((orch_i + 1))
  done
  while [ "$orch_started" -lt "$orch_total" ] && [ "$orch_running" -lt "$orch_jobs" ]; do
    orch_pos="${orch_sections[$orch_started]}"
    ORCH_TEST_CHILD_SECTION="$orch_pos" ORCH_TEST_CHILD_COUNTS="$orch_buf/$orch_pos.counts" \
      ORCH_TEST_JOBS=1 bash "$SUITE_SCRIPT" >"$orch_buf/$orch_pos.out" &
    orch_pids[orch_started]=$!
    orch_started=$((orch_started + 1))
    orch_running=$((orch_running + 1))
  done
  # Print every finished child next in file order.
  orch_progress=0
  while [ "$orch_flushed" -lt "$orch_started" ] &&
    ! kill -0 "${orch_pids[$orch_flushed]}" 2>/dev/null; do
    wait "${orch_pids[$orch_flushed]}"; orch_status=$?
    orch_pos="${orch_sections[$orch_flushed]}"
    cat "$orch_buf/$orch_pos.out"
    orch_counts=""
    [ -f "$orch_buf/$orch_pos.counts" ] && orch_counts="$(cat "$orch_buf/$orch_pos.counts")"
    case "$orch_counts" in
      [0-9]*' '[0-9]*' '[0-9]*)
        read -r orch_child_pass orch_child_fail orch_child_skip <<<"$orch_counts"
        orch_pass=$((orch_pass + orch_child_pass)); orch_fail=$((orch_fail + orch_child_fail))
        orch_skip=$((orch_skip + orch_child_skip))
        [ "$orch_child_fail" -eq 0 ] || orch_any_failed=1 ;;
      *)
        print_fail "section '$(printf '%s\n' "$orch_titles" | sed -n "${orch_pos}p")' reported no counts" \
          "it exited $orch_status before its summary"
        orch_fail=$((orch_fail + 1)); orch_any_failed=1 ;;
    esac
    [ "$orch_status" -eq 0 ] || orch_any_failed=1
    orch_flushed=$((orch_flushed + 1))
    orch_progress=1
  done
  [ "$orch_progress" -eq 1 ] || sleep 0.1
done
print_summary "$orch_pass" "$orch_fail" "$orch_skip"
exit "$orch_any_failed"
