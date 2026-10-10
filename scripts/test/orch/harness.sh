# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# count_lines [<grep flag>...] <pattern> <text>: prints how many lines of
# <text> match <pattern>. Every argument before the last two goes to grep
# as-is.
count_lines() {
  local pattern="${*: -2:1}" text="${!#}"
  printf '%s\n' "$text" | grep -c "${@:1:$#-2}" "$pattern"
}

# planted_copy: copies the scripts tree into a fresh temp directory, writes the
# section lines read from stdin, each indented two spaces, as a new noun file,
# scripts/test/orch/zz-planted.sh, in the copy, and prints the directory. The
# name sorts after every noun file under LC_ALL=C, so the planted sections
# come last in the walk. The indent, which planted_copy strips, keeps a planted
# `# --- ` header from reading as a section of the file that plants it. The
# caller runs <dir>/scripts/test/orch_test.sh and removes <dir> when done.
planted_copy() {
  local dir
  dir="$(mktemp -d)" || return 1
  cp -R "$PLUGIN_ROOT/scripts" "$dir/" || return 1
  sed 's/^  //' >"$dir/scripts/test/orch/zz-planted.sh" || return 1
  printf '%s\n' "$dir"
}

# --- isolation --------------------------------------------------------------
echo
echo "isolation"
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  bad "the suite starts outside any git work tree" "cwd $(pwd) is inside one"
else
  ok "the suite starts outside any git work tree"
fi
assert_eq "HOME is the suite's own HOME" "$HOME" "$SUITE_HOME"
assert_ne "HOME is not the HOME the suite started with" "$HOME" "$CALLER_HOME"
assert_eq "CLAUDE_PLUGIN_ROOT is unset" "${CLAUDE_PLUGIN_ROOT-unset}" "unset"
assert_eq "no caller git config is reachable" \
  "${XDG_CONFIG_HOME-unset} ${GIT_CONFIG_GLOBAL-unset}" "unset unset"
assert_eq "cwd is the harness's fresh temp directory" "$(pwd)" "$SUITE_CWD"

# --- the section filter (ORCH_TEST_ONLY, #612) ----------------------------------
# The suite run as a child process under a filter, asserted on its stdout and
# exit status. The child starts inside a git repo, so its isolation section
# shows the harness holds under a filter too.
echo
echo "the section filter (ORCH_TEST_ONLY, #612)"
new_repo >/dev/null
# The reference run: isolation alone, not quiet. Its ok lines give the
# isolation section's pass count, so no assert below hard-codes it.
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
filter_n="$(count_lines '^  ok ' "$out")"
assert_status "a filter matching only isolation passes" "$st" 0
assert_ne "the reference run prints an ok line" "$filter_n" 0
assert_eq "runs the isolation section" "$(count_lines -x 'isolation' "$out")" "1"
assert_eq "runs no other section" "$(count_lines -xE 'init|slug|doctor' "$out")" "0"
assert_eq "counts only what ran in the summary" "$(printf '%s\n' "$out" | tail -n 1)" \
  "$filter_n passed, 0 failed"
assert_contains "keeps the cwd isolation, started from a git repo" "$out" \
  "ok   the suite starts outside any git work tree"
assert_contains "keeps the HOME isolation" "$out" "ok   HOME is the suite's own HOME"

# A copy of the scripts tree with three planted sections whose headers end in
# trailing dashes like the real ones; the pattern matches two of them.
filter_dir="$(planted_copy <<'PLANTED'
  # --- planted alpha ------------------------------------------------------
  echo; echo "planted alpha"; ok "alpha ran"
  # --- planted beta -------------------------------------------------------
  echo; echo "planted beta"; ok "beta ran"
  # --- planted gamma ------------------------------------------------------
  echo; echo "planted gamma"; ok "gamma ran"
PLANTED
)"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted (alpha|beta)$' \
  bash "$filter_dir/scripts/test/orch_test.sh" 2>/dev/null)"
assert_eq "matches titles without their trailing dashes" \
  "$(count_lines -xE 'planted alpha|planted beta' "$out")" "2"
assert_eq "runs isolation alongside the matched sections" \
  "$(count_lines -x 'isolation' "$out")" "1"
assert_eq "skips the sections the pattern does not match" \
  "$(count_lines -x 'planted gamma' "$out")" "0"
rm -rf "$filter_dir"

filter_err="$(mktemp)"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' bash "$SUITE_SCRIPT" 2>"$filter_err")"; st=$?
assert_status "a pattern matching no section exits 1" "$st" 1
assert_eq "says on stderr that it lists the selectable sections" "$(cat "$filter_err")" \
  "orch_test.sh: ORCH_TEST_ONLY='^no such section\$' matches no section; the selectable sections are:"
rm -f "$filter_err"
assert_eq "lists the sections from isolation on" "$(printf '%s\n' "$out" | sed -n 1p)" "isolation"
assert_eq "lists a sub-section as a title of its own" \
  "$(count_lines -xF 'doctor: host (#128)' "$out")" "1"
assert_eq "lists titles without trailing dashes" "$(count_lines -- '-$' "$out")" "0"
assert_eq "lists no shared-setup header" \
  "$(count_lines -E 'doctor harness|fixture gh' "$out")" "0"
assert_eq "runs nothing" "$(count_lines 'passed' "$out")" "0"

# --- quiet mode (ORCH_TEST_QUIET, #614) ----------------------------------------
# A filtered, quiet child run of this suite, and one quiet run each of the
# other two suites. Quiet mode hides the ok lines only: the counts, headers,
# FAIL/skip lines with their detail, and the summary all stay. hooks_test.sh
# and docs_lint.sh are judged on their ok lines alone, not on their status.
echo
echo "quiet mode (ORCH_TEST_QUIET, #614)"
# The reference run: isolation alone, not quiet. Its ok lines give the
# isolation section's pass count, which the quiet runs' summaries must match.
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
quiet_n="$(count_lines '^  ok ' "$out")"
assert_status "the non-quiet reference run passes" "$st" 0
assert_ne "the reference run prints an ok line" "$quiet_n" 0
assert_eq "without quiet mode, counts every printed ok line in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "$quiet_n passed, 0 failed"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
assert_status "a quiet, filtered run passes" "$st" 0
assert_eq "prints no ok line" "$(count_lines '^  ok ' "$out")" "0"
assert_eq "still prints the section header" "$(count_lines -x 'isolation' "$out")" "1"
assert_eq "still counts every pass in the summary" "$(printf '%s\n' "$out" | tail -n 1)" \
  "$quiet_n passed, 0 failed"
# A copy of the scripts tree whose isolation section gains a failing and a
# skipped check, so the FAIL and skip lines are seen kept under quiet mode.
quiet_dir="$(mktemp -d)"
cp -R "$PLUGIN_ROOT/scripts" "$quiet_dir/"
awk '{ print } $0 == "echo \"isolation\"" {
  print "bad \"a planted failure\" \"its detail line\""
  print "skip \"a planted skip\" \"its reason line\"" }' "$quiet_dir/scripts/test/orch/harness.sh" \
  >"$quiet_dir/harness.sh"
mv "$quiet_dir/harness.sh" "$quiet_dir/scripts/test/orch/harness.sh"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^isolation$' \
  bash "$quiet_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a quiet run with a failure exits 1" "$st" 1
assert_contains "keeps a FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_contains "keeps a skip line with its reason line" "$out" \
  "$(printf '  skip a planted skip\n     its reason line')"
assert_eq "summarises the hidden passes, the failure and the skip" \
  "$(printf '%s\n' "$out" | tail -n 1)" "$quiet_n passed, 1 failed, 1 skipped"
assert_eq "still prints no ok line beside a failure" "$(count_lines '^  ok ' "$out")" "0"
rm -rf "$quiet_dir"
# Each of the other two suites cut down to its own helpers, one planted check
# and its own summary code: its lines before `# >>> checks`, a planted ok, then
# its lines from its summary marker on.
cut_dir="$(mktemp -d)"
for quiet_pair in hooks_test.sh:'# >>> summary' docs_lint.sh:'# --- summary'; do
  quiet_end="${quiet_pair#*:}"
  quiet_suite="${quiet_pair%%:*}"
  END_MARK="$quiet_end" awk '
    $0 == "# >>> checks" { print "ok \"a planted check\""; skip = 1; next }
    skip && index($0, ENVIRON["END_MARK"]) == 1 { skip = 0 }
    !skip { print }' "$(dirname "$SUITE_SCRIPT")/$quiet_suite" >"$cut_dir/$quiet_suite"
  assert_eq "$quiet_suite's cut-down copy holds the planted check" \
    "$(grep -cx 'ok "a planted check"' "$cut_dir/$quiet_suite")" "1"
  assert_eq "$quiet_suite's cut-down copy holds its summary" \
    "$(grep -cxF 'echo "$PASS passed, $FAIL failed"' "$cut_dir/$quiet_suite")" "1"
  out="$(ORCH_TEST_QUIET=1 bash "$cut_dir/$quiet_suite" 2>&1)"
  assert_eq "$quiet_suite prints no ok line when quiet" \
    "$(count_lines '^  ok ' "$out")" "0"
  assert_contains "$quiet_suite still prints its summary when quiet" "$out" " passed, "
done
rm -rf "$cut_dir"

# --- the parallel runner (ORCH_TEST_JOBS, #780) --------------------------------
# A copy of the scripts tree with planted sections. Two passing ones run with
# ORCH_TEST_JOBS=2, compared with the same filter run sequentially; then the
# others - one slow, one writing to stderr, one exiting mid-way, one failing -
# run in parallel, asserted on their combined output.
echo
echo "the parallel runner (ORCH_TEST_JOBS, #780)"
par_dir="$(planted_copy <<'PLANTED'
  # --- paired alpha ---------------------------------------------------------
  echo; echo "paired alpha"; ok "alpha ran"; ok "alpha ran again"
  # --- paired beta ----------------------------------------------------------
  echo; echo "paired beta"; ok "beta ran"
  # --- planted slow
  echo; echo "planted slow"; sleep 2; ok "slept"
  # --- planted stderr
  echo; echo "planted stderr"; echo "a planted stderr line" >&2; ok "wrote"
  # --- planted exit
  echo; echo "planted exit"; ok "before the exit"; exit 3
  # --- planted failure
  echo; echo "planted failure"; bad "a planted failure" "its detail line"
PLANTED
)"
par_suite="$par_dir/scripts/test/orch_test.sh"
par_only='^paired (alpha|beta)$'
seq_out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=1 ORCH_TEST_ONLY="$par_only" bash "$par_suite" 2>/dev/null)"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY="$par_only" bash "$par_suite" 2>/dev/null)"; st=$?
assert_status "a parallel run whose sections pass exits 0" "$st" 0
assert_eq "prints the section headers in file order" \
  "$(printf '%s\n' "$out" | grep -xE 'isolation|paired alpha|paired beta' | tr '\n' ',')" \
  "isolation,paired alpha,paired beta,"
assert_eq "runs isolation exactly once" "$(printf '%s\n' "$out" | grep -cx 'isolation')" "1"
assert_eq "prints the banner once" "$(printf '%s\n' "$out" | grep -cx 'orch.sh tests')" "1"
assert_eq "ends with one summary summed across the sections" \
  "$(printf '%s\n' "$out" | grep -cE '^[0-9]+ passed, [0-9]+ failed')" "1"
assert_eq "whose summary is the last line, as a sequential run's" \
  "$(printf '%s\n' "$out" | tail -n 1)" "$(printf '%s\n' "$seq_out" | tail -n 1)"
assert_eq "prints the stdout a sequential run prints" "$out" "$seq_out"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=2 ORCH_TEST_ONLY="$par_only" bash "$par_suite" 2>&1)"; st=$?
assert_status "a quiet parallel run passes" "$st" 0
assert_eq "prints no ok line when quiet" "$(printf '%s\n' "$out" | grep -c '^  ok ')" "0"

out="$(ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^no such section$' bash "$SUITE_SCRIPT" 2>/dev/null)"; st=$?
assert_status "a pattern matching no section exits 1 in parallel too" "$st" 1
assert_eq "lists the section titles" "$(printf '%s\n' "$out" | sed -n 1p)" "isolation"
assert_eq "and runs nothing" "$(printf '%s\n' "$out" | grep -c 'passed')" "0"

for par_jobs in 0 00 000 -2 two ''; do
  out="$(ORCH_TEST_JOBS="$par_jobs" ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
  assert_status "ORCH_TEST_JOBS='$par_jobs' exits 1" "$st" 1
  assert_contains "ORCH_TEST_JOBS='$par_jobs' is named in the message" "$out" \
    "ORCH_TEST_JOBS='$par_jobs'"
  assert_eq "ORCH_TEST_JOBS='$par_jobs' runs no section" \
    "$(printf '%s\n' "$out" | grep -c 'passed')" "0"
done

out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=4 ORCH_TEST_ONLY='^planted ' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run with a failing section exits 1" "$st" 1
assert_eq "prints a slow early section in file order" \
  "$(printf '%s\n' "$out" | grep -xE 'isolation|planted [a-z]+' | tr '\n' ',')" \
  "isolation,planted slow,planted stderr,planted exit,planted failure,"
assert_contains "passes a section's stderr through" "$out" "a planted stderr line"
assert_contains "reports a section that exits mid-way as a FAIL naming it" "$out" \
  "  FAIL section 'planted exit' reported no counts"
assert_contains "keeps a planted FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_eq "sums both failures into the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "8 passed, 2 failed"
# Each failing path alone, so neither passes on the strength of the other.
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted exit$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section exits mid-way exits 1" "$st" 1
assert_contains "reports that section alone as a FAIL naming it" "$out" \
  "  FAIL section 'planted exit' reported no counts"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "6 passed, 1 failed"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted failure$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section has a failing check exits 1" "$st" 1
assert_contains "keeps that check's FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "6 passed, 1 failed"
rm -rf "$par_dir"

# --- the section files (#932) ---------------------------------------------------
# A copy of the scripts tree cut down to isolation - harness.sh keeps only its
# first section, and no other noun file is left - then given new noun files:
# zz-planted.sh, _planted.sh, two files with a preamble and one with nothing
# but a preamble. Each preamble prints a line, so the output shows when and
# how often it is eval'd.
echo
echo "the section files (#932)"
files_dir="$(planted_copy <<'PLANTED'
  # --- planted new file
  echo; echo "planted new file"; ok "the new file ran"
PLANTED
)"
files_orch="$files_dir/scripts/test/orch"
files_suite="$files_dir/scripts/test/orch_test.sh"
awk '/^# --- / { n++ } n <= 1' "$files_orch/harness.sh" >"$files_dir/harness.sh"
find "$files_orch" -name '*.sh' ! -name setup.sh ! -name zz-planted.sh -exec rm -f {} +
mv "$files_dir/harness.sh" "$files_orch/harness.sh"
sed 's/^  //' >"$files_orch/_planted.sh" <<'PLANTED'
  # --- underscore planted
  echo; echo "underscore planted"; ok "the underscore file ran"
PLANTED
sed 's/^  //' >"$files_orch/pre-a.sh" <<'PLANTED'
  # The preamble of pre-a.sh, and the helper only its sections use.
  echo "preamble a ran"
  pre_a_helper() { echo "helper a"; }
  # --- preamble a one
  echo; echo "preamble a one"; assert_eq "the preamble's helper is defined" "$(pre_a_helper)" "helper a"
  # --- preamble a two
  echo; echo "preamble a two"; ok "a two ran"
PLANTED
sed 's/^  //' >"$files_orch/pre-b.sh" <<'PLANTED'
  echo "preamble b ran"
  # --- preamble b one
  echo; echo "preamble b one"; ok "b one ran"
PLANTED
sed 's/^  //' >"$files_orch/pre-c.sh" <<'PLANTED'
  # A preamble with no section after it.
  echo "preamble c ran"
PLANTED
# files_marks <output>: the section headers and preamble lines in it, in order,
# comma-separated.
files_marks() {
  printf '%s\n' "$1" | grep -xE 'isolation|(underscore|preamble [a-c]|planted new) [a-z ]+' | tr '\n' ','
}

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='' bash "$files_suite" 2>&1)"; st=$?
assert_status "an unfiltered sequential run of new noun files passes" "$st" 0
assert_eq "runs every new file's sections, each preamble once before them" "$(files_marks "$out")" \
  "isolation,underscore planted,preamble a ran,preamble a one,preamble a two,preamble b ran,preamble b one,planted new file,"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='' bash "$files_suite" 2>&1)"; st=$?
assert_status "an unfiltered parallel run of new noun files passes" "$st" 0
assert_eq "runs a new file's section in parallel too" "$(count_lines -x 'planted new file' "$out")" "1"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^planted new file$' bash "$files_suite" 2>&1)"; st=$?
assert_status "a filter selecting a section of a new file passes" "$st" 0
assert_eq "runs it beside isolation alone" "$(files_marks "$out")" "isolation,planted new file,"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^preamble a' bash "$files_suite" 2>&1)"; st=$?
assert_status "a filtered run of a file's two sections passes" "$st" 0
assert_eq "a filtered run evals the file's preamble once, and no other file's" \
  "$(files_marks "$out")" "isolation,preamble a ran,preamble a one,preamble a two,"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^preamble b one$' bash "$files_suite" 2>&1)"
assert_eq "a filtered run of another file's section evals only that file's preamble" \
  "$(files_marks "$out")" "isolation,preamble b ran,preamble b one,"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^preamble (a one|b one)$' \
  bash "$files_suite" 2>&1)"; st=$?
assert_status "a parallel run of sections behind preambles passes" "$st" 0
assert_eq "each parallel child evals its own file's preamble alone" "$(files_marks "$out")" \
  "isolation,preamble a ran,preamble a one,preamble b ran,preamble b one,"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' bash "$files_suite" 2>/dev/null)"
assert_eq "lists the titles in walk order: harness.sh, then the files in LC_ALL=C order" \
  "$(printf '%s\n' "$out" | tr '\n' ',')" \
  "isolation,underscore planted,preamble a one,preamble a two,preamble b one,planted new file,"
files_locale="$(locale -a 2>/dev/null | grep -ixE 'en_US\.utf-?8' | head -n 1)"
if [ -n "$files_locale" ]; then
  out="$(LC_ALL="$files_locale" ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' \
    bash "$files_suite" 2>/dev/null)"
  assert_eq "keeps LC_ALL=C order under a dictionary locale" \
    "$(printf '%s\n' "$out" | sed -n 2p)" "underscore planted"
else
  skip "keeps LC_ALL=C order under a dictionary locale" "locale -a lists no en_US.UTF-8"
fi
rm -rf "$files_dir"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' bash "$SUITE_SCRIPT" 2>/dev/null)"
assert_ne "the suite lists its section titles" "$(count_lines '' "$out")" "0"
assert_eq "no title appears twice across the walk" \
  "$(printf '%s\n' "$out" | LC_ALL=C sort | uniq -d)" ""

# --- the suite's temp root (#807) -----------------------------------------------
# A cut-down suite - isolation plus one planted section that calls new_repo -
# each run given its own fresh, empty TMPDIR, asserted empty once it exits:
# passing, failing, and interrupted once its section is running. The marker
# the waiting section writes lives outside that TMPDIR.
echo
echo "the suite's temp root (#807)"
root_dir="$(planted_copy <<'PLANTED'
  # --- planted repo
  echo; echo "planted repo"; new_repo >/dev/null; ok "made a repo"
  # --- planted failure
  echo; echo "planted failure"; new_repo >/dev/null; bad "a planted failure" "its detail line"
  # --- planted wait
  echo; echo "planted wait"; new_repo >/dev/null; : >"$ROOT_TEST_MARKER"; sleep 30 & wait $!
  ok "waited"
PLANTED
)"
root_suite="$root_dir/scripts/test/orch_test.sh"
root_tmp="$root_dir/tmp"
root_marker="$root_dir/marker"
# root_fresh: an empty TMPDIR for the next inner run, and no marker.
root_fresh() { rm -rf "$root_tmp" "$root_marker"; mkdir "$root_tmp"; }
# root_await_marker: polls up to 10s for the waiting section's marker.
root_await_marker() {
  local i=0
  while [ ! -f "$root_marker" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  [ -f "$root_marker" ]
}

for root_jobs in 2 1; do
  root_fresh
  TMPDIR="$root_tmp" ORCH_TEST_JOBS="$root_jobs" ORCH_TEST_ONLY='^planted repo$' \
    bash "$root_suite" >/dev/null 2>&1; st=$?
  assert_status "a passing run with ORCH_TEST_JOBS=$root_jobs exits 0" "$st" 0
  assert_eq "a passing run with ORCH_TEST_JOBS=$root_jobs leaves its TMPDIR empty" \
    "$(ls -A "$root_tmp")" ""

  root_fresh
  TMPDIR="$root_tmp" ORCH_TEST_JOBS="$root_jobs" ORCH_TEST_ONLY='^planted failure$' \
    bash "$root_suite" >/dev/null 2>&1; st=$?
  assert_status "a failing run with ORCH_TEST_JOBS=$root_jobs exits 1" "$st" 1
  assert_eq "a failing run with ORCH_TEST_JOBS=$root_jobs leaves its TMPDIR empty" \
    "$(ls -A "$root_tmp")" ""

  root_fresh
  TMPDIR="$root_tmp" ROOT_TEST_MARKER="$root_marker" ORCH_TEST_JOBS="$root_jobs" \
    ORCH_TEST_ONLY='^planted wait$' bash "$root_suite" >/dev/null 2>&1 &
  root_pid=$!
  if root_await_marker; then
    kill -TERM "$root_pid"
  else
    kill -KILL "$root_pid" 2>/dev/null
  fi
  wait "$root_pid"; st=$?
  assert_status "a run with ORCH_TEST_JOBS=$root_jobs sent TERM exits 130" "$st" 130
  assert_eq "a run with ORCH_TEST_JOBS=$root_jobs sent TERM leaves its TMPDIR empty" \
    "$(ls -A "$root_tmp")" ""
done

# SIGINT reaches the run only with job control on - a non-interactive shell
# starts a background job with SIGINT ignored - so the run is started from a
# foreground `set -m` subshell. A shell that itself started with SIGINT ignored,
# as a parallel runner's child does, passes that on through `set -m` too; there
# perl restores SIGINT's default for the run, and without perl the check skips.
root_launch=()
root_int_skip=0
if [ "$(trap -p INT)" = "trap -- '' SIGINT" ]; then
  if command -v perl >/dev/null 2>&1; then
    root_launch=(perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die "exec: $!"')
  else
    root_int_skip=1
  fi
fi
if [ "$root_int_skip" -eq 1 ]; then
  skip "a run sent INT exits 130 and leaves its TMPDIR empty" \
    "this shell started with SIGINT ignored, and perl is not installed to restore it"
else
  root_fresh
  st="$(
    set -m
    TMPDIR="$root_tmp" ROOT_TEST_MARKER="$root_marker" ORCH_TEST_JOBS=2 \
      ORCH_TEST_ONLY='^planted wait$' "${root_launch[@]}" bash "$root_suite" >/dev/null 2>&1 &
    root_pid=$!
    if root_await_marker; then
      kill -INT "$root_pid"
    else
      kill -KILL "$root_pid" 2>/dev/null
    fi
    wait "$root_pid"; echo "$?"
  )"
  assert_eq "a run sent INT exits 130" "$st" "130"
  assert_eq "a run sent INT leaves its TMPDIR empty" "$(ls -A "$root_tmp")" ""
fi

# hooks_test.sh owns a temp root too: run whole, then sent TERM once its
# TMPDIR has an entry.
root_hooks="$(dirname "$SUITE_SCRIPT")/hooks_test.sh"
root_fresh
TMPDIR="$root_tmp" ORCH_TEST_QUIET=1 bash "$root_hooks" >/dev/null 2>&1; st=$?
assert_status "hooks_test.sh exits 0" "$st" 0
assert_eq "hooks_test.sh leaves its TMPDIR empty" "$(ls -A "$root_tmp")" ""

root_fresh
TMPDIR="$root_tmp" ORCH_TEST_QUIET=1 bash "$root_hooks" >/dev/null 2>&1 &
root_pid=$!
root_i=0
while [ -z "$(ls -A "$root_tmp")" ] && [ "$root_i" -lt 100 ]; do sleep 0.05; root_i=$((root_i + 1)); done
assert_eq "hooks_test.sh's TMPDIR gains an entry while it runs" \
  "$([ -n "$(ls -A "$root_tmp")" ] && echo yes)" "yes"
kill -TERM "$root_pid" 2>/dev/null
wait "$root_pid"
assert_eq "hooks_test.sh sent TERM leaves its TMPDIR empty" "$(ls -A "$root_tmp")" ""

# all.sh checks every full run for leaks: a copy of it beside three stub
# suites that pass, run with no shellcheck on its PATH, once with an
# orch_test.sh stub that leaves a file in its TMPDIR.
root_all="$root_dir/all"
mkdir -p "$root_all/scripts/test" "$root_all/bin" "$root_all/tmp"
cp "$(dirname "$SUITE_SCRIPT")/all.sh" "$root_all/scripts/test/"
for root_tool in bash dirname awk tail mktemp rm mkdir; do
  ln -s "$(command -v "$root_tool")" "$root_all/bin/$root_tool"
done
for root_stub in orch_test.sh hooks_test.sh docs_lint.sh; do
  printf '#!/usr/bin/env bash\necho; echo "1 passed, 0 failed"\n' >"$root_all/scripts/test/$root_stub"
done
out="$(unset CI; TMPDIR="$root_all/tmp" PATH="$root_all/bin" bash "$root_all/scripts/test/all.sh" 2>&1)"; st=$?
assert_status "all.sh passes when its suites leave nothing behind" "$st" 0
assert_eq "all.sh says nothing of leaks when its suites leave nothing behind" \
  "$(printf '%s\n' "$out" | grep -c 'the suites left temp files behind')" "0"
printf '#!/usr/bin/env bash\n: >"$TMPDIR/leaked"\necho; echo "1 passed, 0 failed"\n' \
  >"$root_all/scripts/test/orch_test.sh"
out="$(unset CI; TMPDIR="$root_all/tmp" PATH="$root_all/bin" bash "$root_all/scripts/test/all.sh" 2>&1)"; st=$?
assert_status "all.sh fails a run whose suites leave a temp file behind" "$st" 1
assert_contains "all.sh says the suites left temp files behind" "$out" \
  "all.sh: the suites left temp files behind"
rm -rf "$root_dir"

# --- the real-gh guard (#779) -------------------------------------------------
# A copy of the scripts tree with a planted section that calls gh, run filtered
# to that section: the shared setup's stub gh answers it, logs it, and the
# summary turns the logged call into one FAIL naming it.
echo
echo "the real-gh guard (#779)"
guard_dir="$(planted_copy <<'PLANTED'
  # --- a planted gh call
  echo; echo "a planted gh call"
  gh repo view o/r --json defaultBranchRef >/dev/null 2>&1
PLANTED
)"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^a planted gh call$' \
  bash "$guard_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a run whose section calls gh exits 1" "$st" 1
assert_eq "reports exactly one FAIL" "$(printf '%s\n' "$out" | grep -c '^  FAIL ')" "1"
assert_contains "whose detail names the call" "$out" \
  "$(printf '  FAIL a section called the real gh\n     gh repo view o/r --json defaultBranchRef')"
assert_eq "counts it in the summary" "$(printf '%s\n' "$out" | tail -n 1)" \
  "6 passed, 1 failed"
rm -rf "$guard_dir"

# --- all.sh, the single entry point (#615) ----------------------------------
# A copy of all.sh in <tmp>/scripts/test/ beside three stub suites, never the
# real ones, so <tmp> is the repo root: orch_test.sh's stub fails, the other
# two pass. Each stub logs whether ORCH_TEST_ONLY, ORCH_TEST_QUIET and
# ORCH_TEST_JOBS reached it, and VERSION_BASE. Each stub, the stub shellcheck
# too, drops a marker file named after itself in <tmp>/markers/ when it
# starts, if that directory exists; only the overlap case creates it. One
# planted shell file each in <tmp>/scripts/, <tmp>/scripts/test/ and
# <tmp>/scripts/test/orch/ is there for the lint step to find. Every run sets or unsets CI and runs on a PATH of
# only the tools all.sh and the stubs need, plus a stub shellcheck when the case
# wants one - the real one never runs.
echo
echo "all.sh, the single entry point (#615)"
all_root="$(mktemp -d)"
all_dir="$all_root/scripts/test"
all_bin="$all_root/bin"
mkdir -p "$all_dir/orch" "$all_bin"
cp "$(dirname "$SUITE_SCRIPT")/all.sh" "$all_dir/"
for all_tool in bash dirname awk tail mktemp rm mkdir sleep; do
  ln -s "$(command -v "$all_tool")" "$all_bin/$all_tool"
done
echo 'echo planted' >"$all_root/scripts/lint_me.sh"
echo 'echo planted' >"$all_dir/lint_me.sh"
echo 'echo planted' >"$all_dir/orch/lint_me.sh"
for all_suite in orch_test.sh hooks_test.sh docs_lint.sh; do
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"$all_suite only=\${ORCH_TEST_ONLY-unset} quiet=\${ORCH_TEST_QUIET-unset} jobs=\${ORCH_TEST_JOBS-unset} base=\${VERSION_BASE-unset}\" >>\"\$(dirname \"\$0\")/log\""
    echo "[ -d '$all_root/markers' ] && : >'$all_root/markers/$all_suite'"
    echo 'echo; echo "a section header"'
    if [ "$all_suite" = orch_test.sh ]; then
      echo "printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail\n'"
      echo 'echo; echo "2 passed, 2 failed, 1 skipped"; exit 1'
    else
      echo 'echo; echo "7 passed, 0 failed"'
    fi
  } >"$all_dir/$all_suite"
done
# all_sc_stub [--stderr <line>] <exit> [<stdout line>...]: put a stub
# for shellcheck on all.sh's PATH that logs its arguments and exits <exit>. A
# line that begins with "<file>:" prints only on the call for that file, its
# last argument; any other line prints on every call. With --stderr, every
# call writes <line> to stderr before it exits.
all_sc_stub() {
  local err="" code line
  if [ "$1" = --stderr ]; then
    err="$2"
    shift 2
  fi
  code="$1"
  shift
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"\$*\" >>'$all_root/sc_args'"
    echo "[ -d '$all_root/markers' ] && : >'$all_root/markers/shellcheck'"
    echo 'all_file="${!#}"'
    for line in "$@"; do
      case "$line" in
        scripts/*.sh:*) printf '[ "$all_file" = %q ] && echo %q\n' "${line%%:*}" "$line" ;;
        *) printf 'echo %q\n' "$line" ;;
      esac
    done
    [ -n "$err" ] && printf 'echo %q >&2\n' "$err"
    echo "exit $code"
  } >"$all_bin/shellcheck"
  chmod +x "$all_bin/shellcheck"
}
# all_print_order <output>: the names on all.sh's summary lines, in print
# order, each followed by a space.
all_print_order() {
  printf '%s\n' "$1" | grep -E '^([a-z_]+\.sh|shellcheck): ' | cut -d: -f1 | tr '\n' ' '
}
all_bash="$(command -v bash)"
# all_run [VAR=value...]: run the copied all.sh on the stub PATH, with CI,
# VERSION_BASE and ORCH_TEST_JOBS unset, then each given assignment applied.
# Its stdout and stderr are left to the caller.
all_run() {
  (
    unset CI VERSION_BASE ORCH_TEST_JOBS
    env "$@" PATH="$all_bin" "$all_bash" "$all_dir/all.sh"
  )
}
all_finding1='scripts/lint_me.sh:1:1: warning: a planted finding [SC2034]'
all_finding2='scripts/test/lint_me.sh:2:5: error: another finding [SC2086]'

all_sc_stub 0
out="$(all_run ORCH_TEST_ONLY='^isolation$' VERSION_BASE=9.9.9 2>&1)"; st=$?
assert_status "exits non-zero when a suite failed" "$st" 1
assert_eq "runs every suite after the first one fails" "$(wc -l <"$all_dir/log" | tr -d ' ')" "3"
assert_eq "prints the suites' summaries in order, shellcheck's last" \
  "$(all_print_order "$out")" \
  "orch_test.sh hooks_test.sh docs_lint.sh shellcheck "
assert_eq "unsets ORCH_TEST_ONLY for every suite" "$(grep -c 'only=unset' "$all_dir/log")" "3"
assert_eq "sets ORCH_TEST_QUIET=1 for every suite" "$(grep -c 'quiet=1 ' "$all_dir/log")" "3"
assert_eq "passes VERSION_BASE through to every suite" "$(grep -c 'base=9.9.9$' "$all_dir/log")" "3"
assert_contains "prints a suite's FAIL lines with their detail lines" "$out" \
  "$(printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail')"
assert_eq "prints one summary line per suite" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: [0-9]+ passed')" \
  "$(printf 'orch_test.sh: 2 passed, 2 failed, 1 skipped\nhooks_test.sh: 7 passed, 0 failed\ndocs_lint.sh: 7 passed, 0 failed')"
assert_eq "prints no section header" "$(count_lines 'a section header' "$out")" "0"
assert_eq "still prints the shellcheck summary after a failing suite" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"
assert_eq "runs shellcheck at warning severity in gcc format once per shell file" \
  "$(LC_ALL=C sort "$all_root/sc_args" 2>/dev/null)" \
  "$(printf -- '-S warning -f gcc %s\n' scripts/lint_me.sh scripts/test/all.sh scripts/test/docs_lint.sh scripts/test/hooks_test.sh scripts/test/lint_me.sh scripts/test/orch/lint_me.sh scripts/test/orch_test.sh)"
assert_eq "runs one shellcheck on each planted file" \
  "$(grep -cxE -- '-S warning -f gcc scripts/(test/(orch/)?)?lint_me\.sh' "$all_root/sc_args")" "3"

# Without scripts/test/orch/, its glob matches nothing and is dropped, never
# handed to shellcheck as the literal pattern.
rm -f "$all_dir/log" "$all_root/sc_args"
mv "$all_dir/orch" "$all_root/orch.away"
all_run >/dev/null 2>&1
assert_eq "lints no literal scripts/test/orch/*.sh when that directory is missing" \
  "$(grep -cF 'scripts/test/orch/*.sh' "$all_root/sc_args")" "0"
assert_eq "and still lints every other shell file" "$(wc -l <"$all_root/sc_args" | tr -d ' ')" "6"
mv "$all_root/orch.away" "$all_dir/orch"

rm -f "$all_dir/log"
sed -i.bak 's/; exit 1$//; s/2 failed/0 failed/; /FAIL/d' "$all_dir/orch_test.sh"
rm -f "$all_dir/orch_test.sh.bak"
out="$(all_run VERSION_BASE= 2>&1)"; st=$?
assert_status "exits 0 when every suite passed and shellcheck is clean" "$st" 0
assert_eq "passes an empty VERSION_BASE through as set" "$(grep -c 'base=$' "$all_dir/log")" "3"
assert_eq "prints shellcheck: 0 findings when shellcheck is clean" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"

rm -f "$all_dir/log"
all_sc_stub 1 "$all_finding1" "$all_finding2"
out="$(export VERSION_BASE=9.9.9; all_run 2>&1)"; st=$?
assert_eq "leaves an unset VERSION_BASE unset" "$(grep -c 'base=unset$' "$all_dir/log")" "3"
assert_eq "prints no FAIL line when every suite passed" "$(count_lines FAIL "$out")" "0"
assert_status "exits non-zero on a shellcheck finding" "$st" 1
assert_contains "prints each finding, then shellcheck: N findings" "$out" \
  "$(printf '%s\n%s\nshellcheck: 2 findings' "$all_finding1" "$all_finding2")"
assert_eq "a finding still lets every suite's summary print first" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: ')" \
  "$(printf 'orch_test.sh: 2 passed, 0 failed, 1 skipped\nhooks_test.sh: 7 passed, 0 failed\ndocs_lint.sh: 7 passed, 0 failed')"

# Each planted file's call prints its own finding; the first file's call is
# the slowest and the second's exits highest, so the findings print in glob
# order, not finishing order, and the exit reported is the highest.
all_sc_stub 0
sed -i.bak '/^exit 0$/i \
case "$all_file" in\
  scripts/lint_me.sh) sleep 0.5; echo "a slow first call" >\&2; exit 1 ;;\
  scripts/test/lint_me.sh) echo "a failing second call" >\&2; exit 3 ;;\
  scripts/test/docs_lint.sh) exit 2 ;;\
esac' "$all_bin/shellcheck"
out="$(all_run 2>&1)"; st=$?
assert_status "exits non-zero when shellcheck calls fail with no finding" "$st" 1
assert_contains "prints every call's output in glob order, then the highest exit" "$out" \
  "$(printf 'a slow first call\na failing second call\nshellcheck: failed (exit 3)')"
all_sc_stub 1 "$all_finding1" "$all_finding2"
sed -i.bak '/^all_file=/a [ "$all_file" = scripts/lint_me.sh ] \&\& sleep 0.5' "$all_bin/shellcheck"
out="$(all_run 2>&1)"
assert_contains "prints both planted files' findings in glob order" "$out" \
  "$(printf '%s\n%s\nshellcheck: 2 findings' "$all_finding1" "$all_finding2")"

all_sc_stub --stderr "a bad .shellcheckrc" 2
out="$(all_run 2>&1)"; st=$?
assert_status "exits non-zero when shellcheck fails with no finding" "$st" 1
assert_contains "prints shellcheck's output, then its exit status" "$out" \
  "$(printf 'a bad .shellcheckrc\nshellcheck: failed (exit 2)')"

# all_swap <suite> <line>...: replace <suite>'s shared stub, saved for
# all_restore, by one that runs the lines first, then the shared stub's body.
all_swap() {
  local suite="$1" line
  shift
  cp "$all_dir/$suite" "$all_root/$suite.shared"
  {
    echo '#!/usr/bin/env bash'
    for line in "$@"; do echo "$line"; done
    tail -n +2 "$all_root/$suite.shared"
  } >"$all_dir/$suite"
}
# all_restore <suite>: put <suite>'s shared stub back.
all_restore() {
  mv "$all_root/$1.shared" "$all_dir/$1"
}
all_order="orch_test.sh hooks_test.sh docs_lint.sh shellcheck "
all_sc_stub 0

all_swap orch_test.sh 'sleep 1' 'echo; echo "a section header"' \
  "printf '  FAIL a slow failure\\n     its detail line\\n'" \
  'echo; echo "1 passed, 1 failed"; exit 1'
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
assert_status "a slow failing suite still fails the run" "$st" 1
assert_eq "a slow orch_test.sh's FAIL block and summary still print first, shellcheck's summary last" \
  "$out" \
  "$(printf '  FAIL a slow failure\n     its detail line\norch_test.sh: 1 passed, 1 failed\nhooks_test.sh: 7 passed, 0 failed\ndocs_lint.sh: 7 passed, 0 failed\nshellcheck: 0 findings')"

# The overlap: orch_test.sh's stub finishes only once the other two suites
# and the stub shellcheck have all dropped their markers, so a sequential
# all.sh, which starts nothing else until it finishes, fails after its 10s
# wait.
mkdir "$all_root/markers"
all_swap orch_test.sh "all_wait=0" \
  "until [ -e '$all_root/markers/hooks_test.sh' ] && [ -e '$all_root/markers/docs_lint.sh' ] && [ -e '$all_root/markers/shellcheck' ]; do" \
  "  all_wait=\$((all_wait + 1))" \
  "  if [ \"\$all_wait\" -gt 100 ]; then printf '  FAIL the others never started\\n'; echo; echo '0 passed, 1 failed'; exit 1; fi" \
  "  sleep 0.1" \
  "done"
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
rm -rf "$all_root/markers"
assert_status "runs every suite and shellcheck at the same time" "$st" 0
assert_eq "prints no FAIL line when the suites overlap" "$(count_lines FAIL "$out")" "0"
assert_eq "overlapping suites still print in order, shellcheck's summary last" \
  "$(all_print_order "$out")" \
  "$all_order"

rm -f "$all_dir/log"
out="$(all_run ORCH_TEST_JOBS=3 2>&1)"
assert_eq "passes ORCH_TEST_JOBS through to every suite" "$(grep -c 'jobs=3 ' "$all_dir/log")" "3"
rm -f "$all_dir/log"
out="$(all_run 2>&1)"
assert_eq "leaves an unset ORCH_TEST_JOBS unset" "$(grep -c 'jobs=unset ' "$all_dir/log")" "3"

all_swap hooks_test.sh 'echo "a stub stderr line" >&2'
all_run >"$all_root/stdout" 2>"$all_root/stderr"
all_restore hooks_test.sh
assert_eq "passes a suite's stderr through to stderr" \
  "$(grep -c 'a stub stderr line' "$all_root/stderr")" "1"
assert_eq "keeps a suite's stderr off stdout" \
  "$(grep -c 'a stub stderr line' "$all_root/stdout")" "0"

mkdir "$all_root/tmpdir"
all_run TMPDIR="$all_root/tmpdir" >/dev/null 2>&1
assert_eq "removes its temp files on exit" "$(ls -A "$all_root/tmpdir")" ""

rm -f "$all_bin/shellcheck" "$all_bin/shellcheck.bak"
out="$(export CI=true; all_run 2>&1)"; st=$?
assert_eq "says shellcheck was skipped when it is not installed" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: not installed - skipped"
assert_status "a missing shellcheck does not fail the run outside CI" "$st" 0
out="$(all_run CI=true 2>&1)"; st=$?
assert_status "a missing shellcheck fails the run in CI" "$st" 1
assert_eq "still says shellcheck was skipped in CI" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: not installed - skipped"

# A suite that dies before its summary (#626): orch_test.sh's stub fails
# after a FAIL line and ends on a line that is no summary, hooks_test.sh's
# prints nothing, and docs_lint.sh's passes on a stray last line. Last, so
# the stubs are overwritten outright and never restored.
printf '%s\n' '#!/usr/bin/env bash' \
  "printf '  FAIL a dying failure\\n     its dying detail\\nsomething went wrong\\n'" \
  'exit 3' >"$all_dir/orch_test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 4' >"$all_dir/hooks_test.sh"
printf '%s\n' '#!/usr/bin/env bash' 'echo "a stray last line"' >"$all_dir/docs_lint.sh"
out="$(all_run 2>&1)"; st=$?
assert_status "a suite that died before its summary fails the run" "$st" 1
assert_contains "says a suite died before its summary, after its FAIL lines" "$out" \
  "$(printf '  FAIL a dying failure\n     its dying detail\norch_test.sh: died before its summary (exit 3)')"
assert_contains "says a suite that printed nothing died before its summary" "$out" \
  "hooks_test.sh: died before its summary (exit 4)"
assert_contains "keeps a passing suite's last line, whatever it is" "$out" \
  "docs_lint.sh: a stray last line"
rm -rf "$all_root"
