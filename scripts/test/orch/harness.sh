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

# suites_read <all.sh>: reads the suite list from the one `suites=(...)` line
# of <all.sh> into the array SUITES, with read -a and no eval, and returns 0.
# It returns 1, with SUITES_ERR holding an orch:-style message, when <all.sh>
# holds no such line or more than one, when the list is empty, or when a name
# in it is not a file beside the real all.sh, never in <all.sh>'s own tree,
# whose stubs are made from the list. A caller fails on its failure: a list
# that came back empty would make every loop run zero times.
suites_read() {
  local file="$1" n line list name
  SUITES=()
  SUITES_ERR=""
  n="$(grep -c '^suites=(' "$file")" || true
  if [ "$n" -ne 1 ]; then
    SUITES_ERR="orch: $file holds $n suites=( lines, not one"
    return 1
  fi
  line="$(grep '^suites=(' "$file")"
  list="${line#suites=(}"
  read -ra SUITES <<<"${list%%)*}"
  if [ "${#SUITES[@]}" -eq 0 ]; then
    SUITES_ERR="orch: $file holds an empty suites list"
    return 1
  fi
  for name in "${SUITES[@]}"; do
    if [ ! -f "$(dirname "$SUITE_SCRIPT")/$name" ]; then
      SUITES_ERR="orch: $file names $name, which is no file in scripts/test/"
      return 1
    fi
  done
}

# plant_file <dir> <name>: writes the lines read from stdin to <dir>/<name>,
# each line's two-space indent stripped, and returns non-zero when the write
# fails. A caller indents a planted file's lines two spaces, so a planted
# `# --- ` header does not read as a section of the file that plants it.
plant_file() {
  sed 's/^  //' >"$1/$2"
}

# planted_copy: copies the scripts tree into a fresh temp directory, writes the
# section lines read from stdin, indented as plant_file reads them, as a new
# noun file, scripts/test/orch/zz-planted.sh, in the copy, and prints the
# directory. The name sorts after every noun file under LC_ALL=C, so the
# planted sections come last in the walk. The caller runs
# <dir>/scripts/test/orch_test.sh and removes <dir> when done.
planted_copy() {
  local dir
  dir="$(mktemp -d)" || return 1
  cp -R "$PLUGIN_ROOT/scripts" "$dir/" || return 1
  plant_file "$dir/scripts/test/orch" zz-planted.sh || return 1
  printf '%s\n' "$dir"
}

# files_marks <output>: the isolation header and the planted marks in it - the
# section-files self-test's planted section headers and preamble lines - in
# order, comma-separated. Every planted mark of that section starts with
# `planted `, so a planted file's marks match by that convention, with no list
# of files to keep in step.
files_marks() {
  printf '%s\n' "$1" | grep -xE 'isolation|planted [a-z ]+' | tr '\n' ','
}

# The placement rule, as helper_placement's message states it.
HELPER_PLACEMENT_RULE="The rule: a helper used by more than one file, or only by setup.sh's own code, lives in setup.sh; one used by only one file lives in that file's preamble; one already defined inside a section stays there; a helper never moves into a section."

# tree_copy <subtree>: a copy of the real <subtree> of the plugin (a path
# under PLUGIN_ROOT, e.g. scripts/test/orch) in a fresh temp directory; prints
# the copy's path, which ends in the subtree's last component.
tree_copy() {
  local dir
  dir="$(mktemp -d)" || return 1
  cp -R "$PLUGIN_ROOT/$1" "$dir/" || return 1
  printf '%s\n' "$dir/${1##*/}"
}

# helper_placement <dir>: checks where every helper of the suite's files in
# <dir> (scripts/test/orch/) is defined against the files that call it, and
# prints one line per misplaced helper, sorted, naming it, its file, its
# callers and the rule; returns 1 when it printed any. The helpers checked
# are those defined at the top level of setup.sh - the whole of it, its
# `# ---` lines headings only - and of each other file's preamble; one defined
# inside a section is not. A call is a name in command position: at a line's
# start or after `;`, `&&`, `||`, `|`, `&`, `$(`, a backtick, `(`, `{`, `!`, or
# one of then, do, else, elif, if, while, until; a case-arm pattern at a line's
# start (`name)`, `a|name)`) is none. It reads SHELL_CODE_AWK's words view:
# comments, quoted strings and
# quoted heredocs are dropped first, but `$(...)` and backticks inside double
# quotes and unquoted heredocs are still read; a call inside a helper's own
# body is not counted for it. setup.sh's helper fails with no caller, or with
# one calling file that is not setup.sh; a preamble's, when another file
# calls it.
helper_placement() {
  local out
  out="$(awk -v rule="$HELPER_PLACEMENT_RULE" "$SHELL_CODE_AWK"'
    function count(s, re,   t) { t = s; return gsub(re, "", t) }
    FNR == 1 {
      file = FILENAME; sub(/.*\//, "", file)
      files[file] = 1; insec = 0; fn = ""; fdepth = 0
    }
    {
      # the words view: comments dropped, strings and quoted heredocs a q
      shell_code_line($0); s = sc_words; top = sc_top && fdepth == 0
      if (sc_top && file != setup && $0 ~ /^# --- /) insec = 1
      if (top && fn == "" && match(s, /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/)) {
        name = substr(s, 1, RLENGTH); sub(/^[ \t]*(function[ \t]+)?/, "", name); sub(/[ \t]*\(\)$/, "", name)
        fn = name; opened = 0; fdepth = 0
        if (file == setup || !insec) defined[name] = file
      }
      # a case-arm pattern opening the line is no call; the command after it is
      t = s; if (match(t, /^[ \t]*[A-Za-z0-9_.*|-]+\)/)) t = substr(t, RLENGTH + 1)
      gsub(/[;&|({!`]/, "\n", t); nseg = split(t, seg, "\n")
      for (k = 1; k <= nseg; k++) {
        w = seg[k]
        sub(/^[ \t]+/, "", w)
        while (match(w, /^(then|do|else|elif|if|while|until)([ \t]+|$)/)) w = substr(w, RLENGTH + 1)
        if (match(w, /^[A-Za-z_][A-Za-z0-9_]*/)) {
          name = substr(w, 1, RLENGTH); rest = substr(w, RLENGTH + 1)
          if ((rest == "" || rest ~ /^[ \t)}<>]/) && name != fn) calls[name, file] = 1
        }
      }
      if (fn != "") {
        fdepth += count(s, "{") - count(s, "}")
        if (count(s, "{")) opened = 1
        if (opened && fdepth <= 0) { fn = ""; fdepth = 0 }
      }
    }
    END {
      for (name in defined) {
        own = defined[name]; n = 0; other = 0
        for (f in files) if ((name, f) in calls) {
          # insert f into by[1..n], kept in order
          for (j = ++n; j > 1 && by[j - 1] > f; j--) by[j] = by[j - 1]
          by[j] = f; if (f != own) other = 1
        }
        callers = ""
        for (j = 1; j <= n; j++) callers = callers (j > 1 ? ", " : "") by[j]
        if (own == setup) bad = n == 0 || (n == 1 && callers != setup)
        else bad = other
        if (bad) printf "%s is defined in %s and called by %s. %s\n", name, own, n ? callers : "no file", rule
      }
    }
  ' setup=setup.sh "$1"/*.sh)" || return 2
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | LC_ALL=C sort
  return 1
}

# The five multi-field gh ops gh_op_placement looks for, space-separated.
GH_MULTI_FIELD_OPS="adapter_issue_state_labels adapter_issue_state_labels_body adapter_issue_title_labels adapter_pr_state_draft adapter_pr_refs"

# The gh op placement rule, as gh_op_placement's message states it.
GH_OP_PLACEMENT_RULE="The rule: only the gh module, scripts/orch/gh.sh, names a multi-field gh op (${GH_MULTI_FIELD_OPS// /, }); every other script reads one through its reader, which decodes its fields."

# name_placement <dir> <rule> <verb> <names> <owner-path>...: checks every shell
# script under <dir> (a scripts/ tree) outside the owner paths (find's ./ form,
# e.g. ./orch/gh.sh) and test/ for a name of <names> (space-separated), and
# prints one line per file and name, sorted, naming the file (as
# scripts/<path>),
# <verb>, the name and <rule>; returns 1 when it printed any. A name counts as a
# whole word anywhere in code - a command word, an argument to any runner, or a
# word inside a string; each line is read through SHELL_CODE_AWK's code view, so
# its comment is dropped first, and a name inside a longer name is no match.
name_placement() {
  local dir="$1" rule="$2" verb="$3" names="$4" out p
  local owners=()
  shift 4
  for p in "$@"; do owners+=(! -path "$p"); done
  out="$(cd "$dir" && find . -name '*.sh' "${owners[@]}" ! -path './test/*' \
    -exec awk -v rule="$rule" -v verb="$verb" -v namelist="$names" "$SHELL_CODE_AWK"'
    BEGIN { nnames = split(namelist, name, " ") }
    {
      shell_code_line($0)
      s = sc_code; file = FILENAME; sub(/^\.\//, "scripts/", file)
      for (k = 1; k <= nnames; k++) {
        t = s
        while (match(t, name[k])) {
          before = substr(t, RSTART - 1, 1); after = substr(t, RSTART + RLENGTH, 1)
          if (before !~ /[A-Za-z0-9_]/ && after !~ /[A-Za-z0-9_]/) {
            printf "%s %s %s. %s\n", file, verb, name[k], rule; break
          }
          t = substr(t, RSTART + 1)
        }
      }
    }
  ' {} +)" || return 2
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | LC_ALL=C sort -u
  return 1
}

# gh_op_placement <dir>: name_placement for the five multi-field gh ops, outside
# the gh module, orch/gh.sh; a line reads "<file> names <op>. <rule>".
gh_op_placement() {
  name_placement "$1" "$GH_OP_PLACEMENT_RULE" names "$GH_MULTI_FIELD_OPS" ./orch/gh.sh
}

# The Marked comment prelude placement rule, as marked_comment_jq_placement's
# message states it.
MARKED_COMMENT_JQ_PLACEMENT_RULE="The rule: only the Marked comment module, scripts/orch/marked-comment.sh, and the Issue timeline, scripts/orch/issue-timeline.sh, call marked_comment_jq; every other script reads a comment through the Marked comment module's readers or the Issue timeline's queries."

# marked_comment_jq_placement <dir>: name_placement for the name
# marked_comment_jq, outside the Marked comment module, orch/marked-comment.sh,
# and the Issue timeline, orch/issue-timeline.sh; a line reads "<file> calls
# marked_comment_jq. <rule>".
marked_comment_jq_placement() {
  name_placement "$1" "$MARKED_COMMENT_JQ_PLACEMENT_RULE" calls marked_comment_jq ./orch/marked-comment.sh ./orch/issue-timeline.sh
}

# The declaration substitution rule, as decl_substitutions' message states it.
DECL_SUBSTITUTION_RULE="The rule: split the declaration from the assignment - local x; x=\"\$(...)\" - so the substitution's status reaches errexit; local, export, declare and readonly return their own status, 0, in its place."

# decl_substitutions <dir>: checks orch.sh and its modules under <dir> (a
# scripts/ tree) for a local, export, declare or readonly that itself carries
# a $(...) in an assignment's value - the whole value or part of it, quoted or
# not, and after any other names on the same declaration - and prints one line
# per such line, naming the file (as scripts/<path>) and line and the rule;
# returns 1 when it printed any. The keyword counts in command position only -
# at a line's start, or after one of ;&|{ or then, do, else - so a comment or a
# string naming it is no match, and the declaration ends at the next ;, & or |,
# so the split form passes.
decl_substitutions() {
  local out
  out="$(cd "$1" && awk -v rule="$DECL_SUBSTITUTION_RULE" '
    /(^[ \t]*|[;&|{][ \t]*|(then|do|else)[ \t]+)(local|export|declare|readonly)[ \t]([^;&|]*[ \t])?[A-Za-z_][A-Za-z0-9_]*=[^;&|]*\$\(/ {
      printf "scripts/%s:%d declares a name with a $(...) assignment. %s\n", FILENAME, FNR, rule
    }
  ' orch.sh orch/*.sh)" || return 2
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | LC_ALL=C sort -t: -k1,1 -k2,2n
  return 1
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
# The caller's ORCH_* knobs are cleared, ORCH_TEST_* kept. The probe run is a
# child suite run started with ORCH_AUTOPILOT and a probe variable exported;
# the child (which has the probe set) asserts, and does not start a child.
assert_eq "ORCH_AUTOPILOT is unset" "${ORCH_AUTOPILOT-unset}" "unset"
if [ -n "${ORCH_TEST_ISOLATION_PROBE:-}" ]; then
  assert_eq "an ORCH_TEST_* variable is kept" "$ORCH_TEST_ISOLATION_PROBE" "kept"
else
  out="$(ORCH_AUTOPILOT=1 ORCH_TEST_ISOLATION_PROBE=kept ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' \
    ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"
  assert_contains "a child run with ORCH_AUTOPILOT exported sees it unset" "$out" "ok   ORCH_AUTOPILOT is unset"
  assert_contains "a child run keeps an exported ORCH_TEST_* variable" "$out" "ok   an ORCH_TEST_* variable is kept"
fi

# --- the section filter (ORCH_TEST_ONLY, #612) --------------------------------
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

# --- quiet mode (ORCH_TEST_QUIET, #614) ---------------------------------------
# A filtered, quiet child run of this suite, and one quiet run each of the
# other suites in all.sh's list. Quiet mode hides the ok lines only: the
# counts, headers, FAIL/skip lines with their detail, and the summary all
# stay. The other suites are judged on their ok lines alone, not on their
# status.
echo
echo "quiet mode (ORCH_TEST_QUIET, #614)"
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" || bad "reads all.sh's suite list" "$SUITES_ERR"
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
# A copy of the scripts tree with a planted section holding a failing and a
# skipped check, run alongside isolation, so the FAIL and skip lines are seen
# kept under quiet mode.
quiet_dir="$(planted_copy <<'PLANTED'
  # --- planted quiet failure
  echo; echo "planted quiet failure"
  bad "a planted failure" "its detail line"
  skip "a planted skip" "its reason line"
PLANTED
)"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^planted quiet failure$' \
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
# Each of the other suites cut down to its own helpers, one planted check
# and its own summary code: its lines before `# >>> checks`, a planted ok, then
# its lines from its `# >>> summary` line on.
cut_dir="$(mktemp -d)"
for quiet_suite in "${SUITES[@]}"; do
  [ "$quiet_suite" = orch_test.sh ] && continue
  awk '
    $0 == "# >>> checks" { print "ok \"a planted check\""; skip = 1; next }
    skip && $0 == "# >>> summary" { skip = 0 }
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

# --- the parallel runner (ORCH_TEST_JOBS, #780) -------------------------------
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
  "$(printf '%s\n' "$out" | tail -n 1)" "11 passed, 2 failed"
# Each failing path alone, so neither passes on the strength of the other.
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted exit$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section exits mid-way exits 1" "$st" 1
assert_contains "reports that section alone as a FAIL naming it" "$out" \
  "  FAIL section 'planted exit' reported no counts"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "9 passed, 1 failed"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted failure$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section has a failing check exits 1" "$st" 1
assert_contains "keeps that check's FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "9 passed, 1 failed"
rm -rf "$par_dir"

# --- assertions in a subshell (#1904) ----------------------------------------
# A cut-down orch suite with one failing assertion inside ( ... ) and one
# passing outside: the tally file counts both, whatever the job count.
echo
echo "assertions in a subshell (#1904)"
sub_dir="$(planted_copy <<'PLANTED'
  # --- planted subshell
  echo; echo "planted subshell"
  ( bad "a failure in a subshell" "its detail line" )
  ok "a pass outside it"
PLANTED
)"
for sub_jobs in 1 2; do
  out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS="$sub_jobs" ORCH_TEST_ONLY='^planted subshell$' \
    bash "$sub_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
  assert_status "a subshell failure exits 1 under ORCH_TEST_JOBS=$sub_jobs" "$st" 1
  assert_contains "and is counted as failed under ORCH_TEST_JOBS=$sub_jobs" \
    "$(printf '%s\n' "$out" | tail -n 1)" " 1 failed"
done
rm -rf "$sub_dir"

# --- the section files (#932) -------------------------------------------------
# A copy of the scripts tree cut down to isolation - harness.sh keeps only its
# first section, and no other noun file is left - then given new noun files:
# zz-planted.sh, _planted.sh, a-planted.sh, two files with a preamble and one
# with nothing but a preamble. Each preamble prints a line, so the output shows
# when and how often it is eval'd. _planted.sh sorts before a-planted.sh under
# LC_ALL=C but after it under a dictionary collation, which ignores the `_`.
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
plant_file "$files_orch" _planted.sh <<'PLANTED'
  # --- planted underscore
  echo; echo "planted underscore"; ok "the underscore file ran"
PLANTED
plant_file "$files_orch" a-planted.sh <<'PLANTED'
  # --- planted a
  echo; echo "planted a"; ok "the a file ran"
PLANTED
plant_file "$files_orch" pre-a.sh <<'PLANTED'
  # The preamble of pre-a.sh, and the helper only its sections use.
  echo "planted preamble a ran"
  pre_a_helper() { echo "helper a"; }
  # --- planted preamble a one
  echo; echo "planted preamble a one"; assert_eq "the preamble's helper is defined" "$(pre_a_helper)" "helper a"
  # --- planted preamble a two
  echo; echo "planted preamble a two"; ok "a two ran"
PLANTED
plant_file "$files_orch" pre-b.sh <<'PLANTED'
  echo "planted preamble b ran"
  # --- planted preamble b one
  echo; echo "planted preamble b one"; ok "b one ran"
PLANTED
plant_file "$files_orch" pre-c.sh <<'PLANTED'
  # A preamble with no section after it.
  echo "planted preamble c ran"
PLANTED

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='' bash "$files_suite" 2>&1)"; st=$?
assert_status "an unfiltered sequential run of new noun files passes" "$st" 0
assert_eq "runs every new file's sections, each preamble once before them" "$(files_marks "$out")" \
  "isolation,planted underscore,planted a,planted preamble a ran,planted preamble a one,planted preamble a two,planted preamble b ran,planted preamble b one,planted new file,"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='' bash "$files_suite" 2>&1)"; st=$?
assert_status "an unfiltered parallel run of new noun files passes" "$st" 0
assert_eq "runs a new file's section in parallel too" "$(count_lines -x 'planted new file' "$out")" "1"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^planted new file$' bash "$files_suite" 2>&1)"; st=$?
assert_status "a filter selecting a section of a new file passes" "$st" 0
assert_eq "runs it beside isolation alone" "$(files_marks "$out")" "isolation,planted new file,"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^planted preamble a' bash "$files_suite" 2>&1)"; st=$?
assert_status "a filtered run of a file's two sections passes" "$st" 0
assert_eq "a filtered run evals the file's preamble once, and no other file's" \
  "$(files_marks "$out")" "isolation,planted preamble a ran,planted preamble a one,planted preamble a two,"
out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^planted preamble b one$' bash "$files_suite" 2>&1)"
assert_eq "a filtered run of another file's section evals only that file's preamble" \
  "$(files_marks "$out")" "isolation,planted preamble b ran,planted preamble b one,"

out="$(ORCH_TEST_QUIET=1 ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted preamble (a one|b one)$' \
  bash "$files_suite" 2>&1)"; st=$?
assert_status "a parallel run of sections behind preambles passes" "$st" 0
assert_eq "each parallel child evals its own file's preamble alone" "$(files_marks "$out")" \
  "isolation,planted preamble a ran,planted preamble a one,planted preamble b ran,planted preamble b one,"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' bash "$files_suite" 2>/dev/null)"
assert_eq "lists the titles in walk order: harness.sh, then the files in LC_ALL=C order" \
  "$(printf '%s\n' "$out" | tr '\n' ',')" \
  "isolation,planted underscore,planted a,planted preamble a one,planted preamble a two,planted preamble b one,planted new file,"
# The dictionary locale: the first of these whose sort puts a before _p, so the
# check below runs wherever such a collation exists, listed by locale -a or not.
files_locale=""
for files_try in en_US.UTF-8 en_US.utf8; do
  if [ "$(printf '_p\na\n' | LC_ALL="$files_try" sort 2>/dev/null | head -n 1)" = a ]; then
    files_locale="$files_try"; break
  fi
done
if [ -n "$files_locale" ]; then
  out="$(LC_ALL="$files_locale" ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' \
    bash "$files_suite" 2>/dev/null)"
  assert_eq "keeps LC_ALL=C order under a dictionary locale" \
    "$(printf '%s\n' "$out" | sed -n 2,3p | tr '\n' ',')" "planted underscore,planted a,"
else
  skip "keeps LC_ALL=C order under a dictionary locale" "no locale here sorts a before _p"
fi
rm -rf "$files_dir"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' bash "$SUITE_SCRIPT" 2>/dev/null)"
assert_ne "the suite lists its section titles" "$(count_lines '' "$out")" "0"
assert_eq "no title appears twice across the walk" \
  "$(printf '%s\n' "$out" | LC_ALL=C sort | uniq -d)" ""

# --- the suite's temp root (#807) ---------------------------------------------
# A cut-down suite - isolation plus one planted section that calls new_repo -
# each run given its own fresh, empty TMPDIR, asserted empty once it exits:
# passing, failing, and interrupted once its section is running. The marker
# the waiting section writes lives outside that TMPDIR.
echo
echo "the suite's temp root (#807)"
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" || bad "reads all.sh's suite list" "$SUITES_ERR"
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

# The suites that own a TERM-trapped temp root - a property of each suite, so
# a subset of all.sh's list, kept explicit - each sent TERM once its TMPDIR has
# an entry. A passing run's leaks are
# all.sh's check: it runs every suite in one fresh TMPDIR and fails the run on
# anything left behind. Here, only TERM mid-run.
for root_suite in hooks_test.sh version_bump_test.sh lens_bench_test.sh; do
  root_script="$(dirname "$SUITE_SCRIPT")/$root_suite"
  root_fresh
  TMPDIR="$root_tmp" ORCH_TEST_QUIET=1 bash "$root_script" >/dev/null 2>&1 &
  root_pid=$!
  root_i=0
  while [ -z "$(ls -A "$root_tmp")" ] && [ "$root_i" -lt 100 ]; do sleep 0.05; root_i=$((root_i + 1)); done
  assert_eq "$root_suite's TMPDIR gains an entry while it runs" \
    "$([ -n "$(ls -A "$root_tmp")" ] && echo yes)" "yes"
  kill -TERM "$root_pid" 2>/dev/null
  wait "$root_pid"
  assert_eq "$root_suite sent TERM leaves its TMPDIR empty" "$(ls -A "$root_tmp")" ""
done

# all.sh checks every full run for leaks: a copy of it beside a stub for each
# suite in its list, all passing, run with no shellcheck on its PATH, once with
# an orch_test.sh stub that leaves a file in its TMPDIR.
root_all="$root_dir/all"
mkdir -p "$root_all/scripts/test" "$root_all/bin" "$root_all/tmp"
cp "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")/test_jobs.sh" "$root_all/scripts/test/"
for root_tool in bash dirname awk tail mktemp rm mkdir; do
  ln -s "$(command -v "$root_tool")" "$root_all/bin/$root_tool"
done
for root_stub in "${SUITES[@]}"; do
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
  "9 passed, 1 failed"
rm -rf "$guard_dir"

# --- all.sh, the single entry point (#615) ----------------------------------
# A copy of all.sh in <tmp>/scripts/test/ beside a stub for each suite in its
# list, never the real ones, so <tmp> is the repo root: orch_test.sh's stub
# fails, the others pass. Each stub logs whether ORCH_TEST_ONLY,
# ORCH_TEST_QUIET and ORCH_TEST_JOBS reached it, and CHANGELOG_BASE and
# NO_VERSION_BUMP. Only the overlap case's own stubs, swapped in for that case
# alone, drop marker files; the shared stubs and the stub shellcheck of every
# other case never do. One planted shell file each in <tmp>/scripts/,
# <tmp>/scripts/test/, <tmp>/scripts/test/orch/ and a nested directory all.sh
# does not name is there for the lint step to find. Every run sets or unsets
# CI and runs on a PATH of only the tools all.sh and the stubs need, plus a
# stub shellcheck when the case wants one - the real one never runs.
echo
echo "all.sh, the single entry point (#615)"
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" || bad "reads all.sh's suite list" "$SUITES_ERR"
all_root="$(mktemp -d)"
all_dir="$all_root/scripts/test"
all_bin="$all_root/bin"
mkdir -p "$all_dir/orch" "$all_bin"
cp "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")/test_jobs.sh" "$all_dir/"
for all_tool in bash dirname awk tail mktemp rm mkdir sleep; do
  ln -s "$(command -v "$all_tool")" "$all_bin/$all_tool"
done
# all_written: every shell file the fixture writes, by path from <tmp>, for
# the expected shellcheck arguments - never a glob.
all_written=(scripts/test/all.sh scripts/test/test_jobs.sh)
all_planted=(scripts/lint_me.sh scripts/test/lint_me.sh scripts/test/orch/lint_me.sh
  scripts/dev/deep/lint_me.sh)
mkdir -p "$all_root/scripts/dev/deep"
for all_file in "${all_planted[@]}"; do
  echo 'echo planted' >"$all_root/$all_file"
  all_written+=("$all_file")
done
for all_suite in "${SUITES[@]}"; do
  all_written+=("scripts/test/$all_suite")
  {
    echo '#!/usr/bin/env bash'
    echo "echo \"$all_suite only=\${ORCH_TEST_ONLY-unset} quiet=\${ORCH_TEST_QUIET-unset} jobs=\${ORCH_TEST_JOBS-unset} base=\${CHANGELOG_BASE-unset} nobump=\${NO_VERSION_BUMP-unset}\" >>\"\$(dirname \"\$0\")/log\""
    echo 'echo; echo "a section header"'
    if [ "$all_suite" = orch_test.sh ]; then
      echo "printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail\n'"
      echo 'echo; echo "2 passed, 2 failed, 1 skipped"; exit 1'
    else
      echo 'echo; echo "7 passed, 0 failed"'
    fi
  } >"$all_dir/$all_suite"
done
# all_summaries <orch_test.sh's summary>: the expected summary line of every
# suite, in list order, orch_test.sh's as given, the others' the stubs' own.
all_summaries() {
  local suite
  for suite in "${SUITES[@]}"; do
    if [ "$suite" = orch_test.sh ]; then
      echo "$suite: $1"
    else
      echo "$suite: 7 passed, 0 failed"
    fi
  done
}
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
# The suite-list reader over the real all.sh, then over planted copies: one
# with no suites=( line, one with two, one with an empty list, one naming a
# suite with no file in scripts/test/.
all_real="$(dirname "$SUITE_SCRIPT")/all.sh"
suites_read "$all_real"; st=$?
assert_status "the reader succeeds over the real all.sh" "$st" 0
for all_case in none two empty missing; do
  case "$all_case" in
    none) all_text='suites_list=(a.sh)' ;;
    two) all_text="$(printf 'suites=(orch_test.sh)\nsuites=(hooks_test.sh)')" ;;
    empty) all_text='suites=()' ;;
    missing) all_text='suites=(orch_test.sh no_such_suite.sh)' ;;
  esac
  printf '%s\n' "$all_text" >"$all_root/planted_all.sh"
  suites_read "$all_root/planted_all.sh"; st=$?
  assert_status "the reader fails over an all.sh with $all_case" "$st" 1
  assert_contains "and names the problem with an orch: message ($all_case)" "$SUITES_ERR" "orch: "
done
suites_read "$all_real" || bad "reads all.sh's suite list" "$SUITES_ERR"
all_bash="$(command -v bash)"
# all_run [VAR=value...]: run the copied all.sh on the stub PATH, with CI,
# CHANGELOG_BASE, NO_VERSION_BUMP and ORCH_TEST_JOBS unset, then each given
# assignment applied.
# Its stdout and stderr are left to the caller.
all_run() {
  (
    unset CI CHANGELOG_BASE NO_VERSION_BUMP ORCH_TEST_JOBS
    env "$@" PATH="$all_bin" "$all_bash" "$all_dir/all.sh"
  )
}
all_finding1='scripts/lint_me.sh:1:1: warning: a planted finding [SC2034]'
all_finding2='scripts/test/lint_me.sh:2:5: error: another finding [SC2086]'
all_order="$(printf '%s ' "${SUITES[@]}")shellcheck "
all_n="${#SUITES[@]}"

all_sc_stub 0
out="$(all_run ORCH_TEST_ONLY='^isolation$' CHANGELOG_BASE=abc123 NO_VERSION_BUMP=1 2>&1)"; st=$?
assert_status "exits non-zero when a suite failed" "$st" 1
assert_eq "runs every suite after the first one fails" "$(wc -l <"$all_dir/log" | tr -d ' ')" "$all_n"
assert_eq "prints the suites' summaries in order, shellcheck's last" \
  "$(all_print_order "$out")" "$all_order"
assert_eq "unsets ORCH_TEST_ONLY for every suite" "$(grep -c 'only=unset' "$all_dir/log")" "$all_n"
assert_eq "sets ORCH_TEST_QUIET=1 for every suite" "$(grep -c 'quiet=1 ' "$all_dir/log")" "$all_n"
assert_eq "passes CHANGELOG_BASE through to every suite" "$(grep -c 'base=abc123 ' "$all_dir/log")" "$all_n"
assert_eq "passes NO_VERSION_BUMP through to every suite" "$(grep -c 'nobump=1$' "$all_dir/log")" "$all_n"
assert_contains "prints a suite's FAIL lines with their detail lines" "$out" \
  "$(printf '  FAIL a stub failure\n     its detail line\n  FAIL another failure\n     its own detail')"
assert_eq "prints one summary line per suite" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: [0-9]+ passed')" \
  "$(all_summaries '2 passed, 2 failed, 1 skipped')"
assert_eq "prints no section header" "$(count_lines 'a section header' "$out")" "0"
assert_eq "still prints the shellcheck summary after a failing suite" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"
assert_eq "runs shellcheck at warning severity in gcc format once per shell file" \
  "$(LC_ALL=C sort "$all_root/sc_args" 2>/dev/null)" \
  "$(printf '%s\n' "${all_written[@]}" | LC_ALL=C sort | sed 's/^/-S warning -f gcc /')"
assert_eq "runs one shellcheck on each planted file, the nested one too" \
  "$(grep -cE -- ' (.*/)?lint_me\.sh$' "$all_root/sc_args")" "${#all_planted[@]}"

# A planted directory with no shell file adds no argument, and no pattern is
# handed to shellcheck as a literal.
rm -f "$all_dir/log" "$all_root/sc_args"
mkdir "$all_dir/orch/no_shell"
echo 'not a shell file' >"$all_dir/orch/no_shell/notes.txt"
all_run >/dev/null 2>&1
assert_eq "a planted directory with no shell file adds no argument" \
  "$(wc -l <"$all_root/sc_args" | tr -d ' ')" "${#all_written[@]}"
assert_eq "no argument shellcheck receives holds a *" \
  "$(grep -cF '*' "$all_root/sc_args")" "0"
rm -rf "$all_dir/orch/no_shell"

rm -f "$all_dir/log"
sed -i.bak 's/; exit 1$//; s/2 failed/0 failed/; /FAIL/d' "$all_dir/orch_test.sh"
rm -f "$all_dir/orch_test.sh.bak"
out="$(all_run CHANGELOG_BASE= NO_VERSION_BUMP= 2>&1)"; st=$?
assert_status "exits 0 when every suite passed and shellcheck is clean" "$st" 0
assert_eq "passes an empty CHANGELOG_BASE through as set" "$(grep -c 'base= ' "$all_dir/log")" "$all_n"
assert_eq "passes an empty NO_VERSION_BUMP through as set" "$(grep -c 'nobump=$' "$all_dir/log")" "$all_n"
assert_eq "prints shellcheck: 0 findings when shellcheck is clean" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"

rm -f "$all_dir/log"
all_sc_stub 1 "$all_finding1" "$all_finding2"
out="$(export CHANGELOG_BASE=abc123 NO_VERSION_BUMP=1; all_run 2>&1)"; st=$?
assert_eq "leaves an unset CHANGELOG_BASE unset" "$(grep -c 'base=unset ' "$all_dir/log")" "$all_n"
assert_eq "leaves an unset NO_VERSION_BUMP unset" "$(grep -c 'nobump=unset$' "$all_dir/log")" "$all_n"
assert_eq "prints no FAIL line when every suite passed" "$(count_lines FAIL "$out")" "0"
assert_status "exits non-zero on a shellcheck finding" "$st" 1
assert_contains "prints each finding, then shellcheck: N findings" "$out" \
  "$(printf '%s\n%s\nshellcheck: 2 findings' "$all_finding1" "$all_finding2")"
assert_eq "a finding still lets every suite's summary print first" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: ')" \
  "$(all_summaries '2 passed, 0 failed, 1 skipped')"

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
all_sc_stub 0

# A suite that printed a FAIL block but a clean summary and exit 0 (a count
# lost) still fails the run, and all.sh says so after the suite's summary.
all_swap orch_test.sh "printf '  FAIL a lost failure\\n     its detail line\\n'"
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
assert_status "exits non-zero when a suite printed FAIL lines but exited 0" "$st" 1
assert_contains "says a suite printed FAIL lines but exited 0, after its summary" "$out" \
  "$(printf 'orch_test.sh: 2 passed, 0 failed, 1 skipped\norch_test.sh: printed FAIL lines but exited 0')"

all_swap orch_test.sh 'sleep 1' 'echo; echo "a section header"' \
  "printf '  FAIL a slow failure\\n     its detail line\\n'" \
  'echo; echo "1 passed, 1 failed"; exit 1'
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
assert_status "a slow failing suite still fails the run" "$st" 1
assert_eq "a slow orch_test.sh's FAIL block and summary still print first, shellcheck's summary last" \
  "$out" \
  "$(printf '  FAIL a slow failure\n     its detail line\n%s\nshellcheck: 0 findings' "$(all_summaries '1 passed, 1 failed')")"

# The overlap: every suite but orch_test.sh and the stub shellcheck are
# swapped for ones that drop a marker file named after themselves in
# <tmp>/markers/ when they start, and orch_test.sh's stub finishes only once
# every marker is there, so a sequential all.sh,
# which starts nothing else until it finishes, fails after its 10s wait. The
# shared stubs and a clean stub shellcheck are put back after.
mkdir "$all_root/markers"
all_until="[ -e '$all_root/markers/shellcheck' ]"
for all_suite in "${SUITES[@]}"; do
  [ "$all_suite" = orch_test.sh ] && continue
  all_swap "$all_suite" ": >'$all_root/markers/$all_suite'"
  all_until="[ -e '$all_root/markers/$all_suite' ] && $all_until"
done
all_sc_stub 0
sed -i.bak "1a : >'$all_root/markers/shellcheck'" "$all_bin/shellcheck"
all_swap orch_test.sh "all_wait=0" \
  "until $all_until; do" \
  "  all_wait=\$((all_wait + 1))" \
  "  if [ \"\$all_wait\" -gt 100 ]; then printf '  FAIL the others never started\\n'; echo; echo '0 passed, 1 failed'; exit 1; fi" \
  "  sleep 0.1" \
  "done"
out="$(all_run 2>&1)"; st=$?
for all_suite in "${SUITES[@]}"; do all_restore "$all_suite"; done
rm -rf "$all_root/markers"
assert_status "runs every suite and shellcheck at the same time" "$st" 0
assert_eq "prints no FAIL line when the suites overlap" "$(count_lines FAIL "$out")" "0"
assert_eq "overlapping suites still print in order, shellcheck's summary last" \
  "$(all_print_order "$out")" "$all_order"
all_sc_stub 0
assert_eq "leaves no marker drop in the shared stubs or the stub shellcheck" \
  "$(cd "$all_dir" && cat "${SUITES[@]}" "$all_bin/shellcheck" | grep -c markers)" "0"

rm -f "$all_dir/log"
out="$(all_run ORCH_TEST_JOBS=3 2>&1)"
assert_eq "passes ORCH_TEST_JOBS through to every suite" "$(grep -c 'jobs=3 ' "$all_dir/log")" "$all_n"
rm -f "$all_dir/log"
out="$(all_run 2>&1)"
assert_eq "leaves an unset ORCH_TEST_JOBS unset" "$(grep -c 'jobs=unset ' "$all_dir/log")" "$all_n"

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

# A killed all.sh (#1668): orch_test.sh's stub and every stub shellcheck set
# their TERM trap, then write their pid and stay running until TERMed; then
# they wait 0.3s and note whether their TMPDIR still exists before they exit.
# After TERM to all.sh, they must all be stopped, each having seen its TMPDIR,
# and all.sh must exit 130.
all_kill="$all_root/kill"
mkdir -p "$all_kill/tmp"
all_sc_stub 0
sed -i.bak "1a trap 'kill \$sp; sleep 0.3; [ -d \"\$TMPDIR\"/*/suites-tmp ] \&\& echo yes >>\"$all_kill/sc.tmp\"; exit 0' TERM; echo \$\$ >>'$all_kill/sc.pid'; sleep 30 \& sp=\$!; wait" "$all_bin/shellcheck"
all_swap orch_test.sh \
  "trap 'kill \$sp; sleep 0.3; [ -d \"\$TMPDIR\" ] && echo yes >\"$all_kill/suite.tmp\"; exit 0' TERM" \
  "echo \$\$ >'$all_kill/suite.pid'" \
  'sleep 30 & sp=$!; wait'
# all_run's environment, with exec so $! is all.sh's own pid.
(
  unset CI CHANGELOG_BASE NO_VERSION_BUMP ORCH_TEST_JOBS
  exec env TMPDIR="$all_kill/tmp" PATH="$all_bin" "$all_bash" "$all_dir/all.sh"
) >/dev/null 2>&1 &
all_pid=$!
all_tries=0
until [ -s "$all_kill/suite.pid" ] && [ -s "$all_kill/sc.pid" ] || [ "$all_tries" -gt 100 ]; do
  all_tries=$((all_tries + 1))
  sleep 0.1
done
kill -TERM "$all_pid"
wait "$all_pid"; st=$?
all_restore orch_test.sh
all_alive=0
for all_stub_pid in $(cat "$all_kill/suite.pid" "$all_kill/sc.pid"); do
  kill -0 "$all_stub_pid" 2>/dev/null && all_alive=$((all_alive + 1))
done
assert_status "TERM to all.sh makes it exit 130" "$st" 130
assert_eq "TERM to all.sh stops the suite and every shellcheck before it returns" "$all_alive" "0"
assert_eq "the suite's TMPDIR still existed when it stopped" "$(cat "$all_kill/suite.tmp" 2>/dev/null)" "yes"
assert_eq "all.sh's temp directory still existed when every shellcheck stopped" \
  "$(sort -u "$all_kill/sc.tmp" 2>/dev/null)" "yes"
assert_eq "removes its temp directory after stopping the children" "$(ls -A "$all_kill/tmp")" ""
all_sc_stub 0

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

# --- the test runners' CPU load (#1586) ---------------------------------------
# The default job count, test_jobs.sh's test_jobs_default, with getconf faked
# on PATH and ORCH_TEST_CPU_MAX_FILE naming a planted quota file; then all.sh's
# limit on shellcheck processes, with shellcheck faked to log its starts and
# ends; then both runners' niceness, with ps and renice faked.
echo
echo "the test runners' CPU load (#1586)"
load_dir="$(mktemp -d)"
load_tests="$(dirname "$SUITE_SCRIPT")"
suites_read "$load_tests/all.sh" || bad "reads all.sh's suite list" "$SUITES_ERR"
mkdir "$load_dir/getconf"
# load_default <cores|fail> <quota file content|-missing|-dir> [VAR=value...]:
# the default job count with getconf reporting <cores> (or failing).
load_default() {
  local cores="$1" quota="$2" file="$load_dir/cpu.max"
  shift 2
  if [ "$cores" = fail ]; then
    printf '#!/bin/sh\nexit 1\n' >"$load_dir/getconf/getconf"
  else
    printf '#!/bin/sh\necho %s\n' "$cores" >"$load_dir/getconf/getconf"
  fi
  chmod +x "$load_dir/getconf/getconf"
  rm -rf "$file"
  case "$quota" in
    -missing) ;;
    -dir) mkdir "$file" ;;
    *) printf '%s\n' "$quota" >"$file" ;;
  esac
  (
    unset CI ORCH_TEST_JOBS
    export ORCH_TEST_CPU_MAX_FILE="$file" PATH="$load_dir/getconf:$PATH"
    for load_kv in "$@"; do declare -x "$load_kv"; done
    source "$load_tests/test_jobs.sh"
    test_jobs_default
  )
}
assert_eq "32 cores and no quota file give 16 jobs" "$(load_default 32 -missing)" "16"
assert_eq "32 cores and a quota of 4 CPUs give 2 jobs" "$(load_default 32 '400000 100000')" "2"
assert_eq "32 cores and a quota of 1.5 CPUs (2 usable) give 1 job" "$(load_default 32 '150000 100000')" "1"
assert_eq "4 cores and a quota above them give 2 jobs" "$(load_default 4 '800000 100000')" "2"
assert_eq "1 core gives 1 job" "$(load_default 1 -missing)" "1"
assert_eq "32 cores and a max quota give 16 jobs" "$(load_default 32 'max 100000')" "16"
assert_eq "32 cores and an unreadable quota file give 16 jobs" "$(load_default 32 -dir)" "16"
assert_eq "a failing getconf falls back to 4 cores, 2 jobs" "$(load_default fail -missing)" "2"
assert_eq "CI gives the full 32 usable CPUs" "$(load_default 32 -missing CI=true)" "32"
assert_eq "CI honours the quota too" "$(load_default 32 '400000 100000' CI=true)" "4"

# all.sh's runs: a copy beside passing suite stubs, a shellcheck stub that logs
# "+" when it starts and "-" when it ends, over the stubs and the two copies.
load_all="$load_dir/all"
mkdir -p "$load_all/scripts/test" "$load_all/bin"
cp "$load_tests/all.sh" "$load_tests/test_jobs.sh" "$load_all/scripts/test/"
for load_tool in bash dirname awk tail mktemp rm mkdir sleep cat; do
  ln -s "$(command -v "$load_tool")" "$load_all/bin/$load_tool"
done
for load_stub in "${SUITES[@]}"; do
  printf '#!/usr/bin/env bash\necho "%s ran" >>"$(dirname "$0")/log"\necho; echo "1 passed, 0 failed"\n' \
    "$load_stub" >"$load_all/scripts/test/$load_stub"
done
printf '#!/usr/bin/env bash\necho + >>%q\nsleep 0.2\necho - >>%q\nexit 0\n' \
  "$load_all/sc_log" "$load_all/sc_log" >"$load_all/bin/shellcheck"
chmod +x "$load_all/bin/shellcheck"
# load_peak: the most shellcheck processes the log shows running at once.
load_peak() {
  awk '/^\+/ { n++; if (n > max) max = n } /^-/ { n-- } END { print max + 0 }' "$load_all/sc_log"
}
# load_run_all [VAR=value...]: all.sh on the stub PATH, CI and ORCH_TEST_JOBS
# unset, then the assignments applied.
load_run_all() {
  (
    unset CI ORCH_TEST_JOBS
    env "$@" PATH="$load_all/bin:$load_dir/getconf" bash "$load_all/scripts/test/all.sh"
  )
}
printf '#!/bin/sh\necho 4\n' >"$load_dir/getconf/getconf"
chmod +x "$load_dir/getconf/getconf"
out="$(load_run_all ORCH_TEST_JOBS=2 2>&1)"; st=$?
assert_status "all.sh with ORCH_TEST_JOBS=2 passes" "$st" 0
assert_eq "all.sh with ORCH_TEST_JOBS=2 runs at most 2 shellcheck at once" "$(load_peak)" "2"
assert_eq "all.sh with ORCH_TEST_JOBS=2 still checks every file" \
  "$(grep -c '^+' "$load_all/sc_log")" "$((${#SUITES[@]} + 2))"
assert_eq "all.sh with ORCH_TEST_JOBS=2 ends on the shellcheck summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "shellcheck: 0 findings"
: >"$load_all/sc_log"
load_run_all >/dev/null 2>&1
assert_eq "all.sh with ORCH_TEST_JOBS unset and 4 cores runs at most 2 shellcheck at once" \
  "$(load_peak)" "2"
: >"$load_all/sc_log"
load_run_all ORCH_TEST_JOBS=1 >/dev/null 2>&1
assert_eq "all.sh with ORCH_TEST_JOBS=1 runs one shellcheck at a time" "$(load_peak)" "1"
rm -f "$load_all/log" "$load_all/scripts/test/log" "$load_all/sc_log"
out="$(load_run_all ORCH_TEST_JOBS=abc 2>&1)"; st=$?
assert_status "all.sh with an invalid ORCH_TEST_JOBS exits 1" "$st" 1
assert_eq "all.sh with an invalid ORCH_TEST_JOBS names it on stderr" "$out" \
  "all.sh: ORCH_TEST_JOBS='abc' is not a positive integer"
assert_eq "all.sh with an invalid ORCH_TEST_JOBS starts no suite or shellcheck" \
  "$(ls "$load_all/sc_log" "$load_all/scripts/test/log" 2>/dev/null)" ""

# Niceness: ps prints the niceness in <dir>/nice and records the pid it was
# asked about; renice records its arguments, and exits <dir>/renice_exit.
load_fakes="$load_dir/fakes"
mkdir "$load_fakes"
printf '#!/bin/sh\ncat %q\necho "$*" >%q\n' "$load_dir/nice" "$load_dir/ps_args" >"$load_fakes/ps"
printf '#!/bin/sh\necho "$*" >>%q\necho renice-noise >&2\nexit $(cat %q)\n' \
  "$load_dir/renice_args" "$load_dir/renice_exit" >"$load_fakes/renice"
chmod +x "$load_fakes/ps" "$load_fakes/renice"
# all.sh's niceness runs need no shellcheck timing: an instant stub shadows the
# sleeping one.
mkdir "$load_dir/instant"
printf '#!/bin/sh\nexit 0\n' >"$load_dir/instant/shellcheck"
chmod +x "$load_dir/instant/shellcheck"
# load_nice_run <runner> <niceness|none> <renice exit> [CI]: the runner on
# PATH with the fakes first, its combined output then "status=N".
load_nice_run() {
  local runner="$1" bin="$load_fakes:$load_dir/instant:$load_all/bin" script ci="${4:-}"
  [ -n "$2" ] && echo "$2" >"$load_dir/nice"
  echo "$3" >"$load_dir/renice_exit"
  rm -f "$load_dir/renice_args" "$load_dir/ps_args"
  case "$runner" in
    all.sh) script="$load_all/scripts/test/all.sh" ;;
    *) bin="$load_fakes:$PATH"; script="$load_tests/orch_test.sh" ;;
  esac
  (
    unset CI; [ -n "$ci" ] && export CI=true
    ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' PATH="$bin" bash "$script" 2>&1
    echo "status=$?"
  )
}
for load_runner in all.sh orch_test.sh; do
  : >"$load_all/sc_log"
  rm -f "$load_all/scripts/test/log"
  baseline="$(load_nice_run "$load_runner" 10 0)"
  assert_eq "$load_runner at niceness 10 calls no renice" "$(on_disk "$load_dir/renice_args")" absent
  load_nice_run "$load_runner" 15 0 >/dev/null
  assert_eq "$load_runner at niceness 15 calls no renice" "$(on_disk "$load_dir/renice_args")" absent
  load_nice_run "$load_runner" 0 0 >/dev/null
  assert_eq "$load_runner at niceness 0 renices by an increment of 10 on its own pid" \
    "$(sed -E 's/[0-9]+$/PID/' "$load_dir/renice_args")" "-n 10 -p PID"
  assert_eq "$load_runner renices the pid it read the niceness of" \
    "$(sed 's/.* //' "$load_dir/renice_args")" "$(sed 's/.* //' "$load_dir/ps_args")"
  load_nice_run "$load_runner" 4 0 >/dev/null
  assert_eq "$load_runner at niceness 4 renices by an increment of 6" \
    "$(sed -E 's/ -p .*//' "$load_dir/renice_args")" "-n 6"
  assert_eq "$load_runner with a failing renice prints and exits as at niceness 10" \
    "$(load_nice_run "$load_runner" 0 1)" "$baseline"
  load_nice_run "$load_runner" 0 0 CI >/dev/null
  assert_eq "$load_runner under CI calls no renice" "$(on_disk "$load_dir/renice_args")" absent
  : >"$load_dir/nice"
  load_nice_run "$load_runner" "" 0 >/dev/null
  assert_eq "$load_runner with ps printing no number calls no renice" \
    "$(on_disk "$load_dir/renice_args")" absent
done
rm -rf "$load_dir"

# --- shell code (#1411) -------------------------------------------------------
# shell_code over planted files: the code view keeps every line, drops each
# comment, and keeps strings, substitutions and heredoc bodies whole.
echo
echo "shell code (#1411)"
shell_code_dir="$(mktemp -d)"

plant_file "$shell_code_dir" trailing.sh <<'PLANTED'
  x=1 # a trailing comment
  f() { :; }# no blank, so a word
  g;# after a semicolon
PLANTED
assert_eq "a trailing comment is dropped" "$(shell_code "$shell_code_dir/trailing.sh")" \
  "$(printf '%s\n' 'x=1 ' 'f() { :; }# no blank, so a word' 'g;')"

plant_file "$shell_code_dir" whole.sh <<'PLANTED'
  a=1
    # an indented comment
  # a comment
  b=2
PLANTED
out="$(shell_code "$shell_code_dir/whole.sh"; echo .)"
assert_eq "a comment-only line prints as an empty line, one line per input line" \
  "$out" "$(printf '%s\n' 'a=1' '  ' '' 'b=2' .)"

plant_file "$shell_code_dir" words.sh <<'PLANTED'
  y=a#b z="c # d" w='e # f' # cut
PLANTED
assert_eq "a # inside a word or quotes starts no comment" \
  "$(shell_code "$shell_code_dir/words.sh")" "y=a#b z=\"c # d\" w='e # f' "

plant_file "$shell_code_dir" ansi.sh <<'PLANTED'
  v=$'g \' # h' # cut
PLANTED
assert_eq "\$'...' with an escaped quote stays open past it" \
  "$(shell_code "$shell_code_dir/ansi.sh")" "v=\$'g \\' # h' "

plant_file "$shell_code_dir" heredocs.sh <<'PLANTED'
  cat <<'EOF' # cut
  # quoted body, kept
  noun_fn
  EOF
  cat <<EOF
  # unquoted body, kept $(x)
  EOF
  y=1 # cut
PLANTED
assert_eq "a quoted and an unquoted heredoc body print whole" \
  "$(shell_code "$shell_code_dir/heredocs.sh")" \
  "$(printf '%s\n' "cat <<'EOF' " '# quoted body, kept' 'noun_fn' 'EOF' 'cat <<EOF' \
    '# unquoted body, kept $(x)' 'EOF' 'y=1 ')"

printf 'cat <<-EOF\n\t# tabbed body\n\tEOF\ny=1 # cut\n' >"$shell_code_dir/strip.sh"
assert_eq "a <<- heredoc ends at a tab-indented terminator, its lines printed whole" \
  "$(shell_code "$shell_code_dir/strip.sh")" "$(printf 'cat <<-EOF\n\t# tabbed body\n\tEOF\ny=1 ')"

plant_file "$shell_code_dir" multiline.sh <<'PLANTED'
  s="one
  # not a comment
  two" # cut
  t='three
  # not a comment either
  ' # cut
PLANTED
assert_eq "a multi-line string keeps its # lines" \
  "$(shell_code "$shell_code_dir/multiline.sh")" \
  "$(printf '%s\n' 's="one' '# not a comment' 'two" ' "t='three" '# not a comment either' "' ")"

plant_file "$shell_code_dir" subst.sh <<'PLANTED'
  a=$(b # cut
  )
  c="$(d "#" e)" # cut
  f=`g` # cut
PLANTED
assert_eq "\$(...) and backticks keep their code and drop their comments" \
  "$(shell_code "$shell_code_dir/subst.sh")" \
  "$(printf '%s\n' 'a=$(b ' ')' 'c="$(d "#" e)" ' 'f=`g` ')"

plant_file "$shell_code_dir" param.sh <<'PLANTED'
  b=${x#pat} c=${x##*/} # cut
PLANTED
assert_eq "a # inside \${...} starts no comment" \
  "$(shell_code "$shell_code_dir/param.sh")" 'b=${x#pat} c=${x##*/} '

plant_file "$shell_code_dir" continued.sh <<'PLANTED'
  cmd one \
    two # cut
PLANTED
assert_eq "the line after one ending in \\ is still code" \
  "$(shell_code "$shell_code_dir/continued.sh")" "$(printf '%s\n' 'cmd one \' '  two ')"

plant_file "$shell_code_dir" two.sh <<'PLANTED'
  cat <<A <<'B' # cut
  # first body
  A
  # second body
  B
  y=1 # cut
PLANTED
assert_eq "two heredocs opened on one line both print whole" \
  "$(shell_code "$shell_code_dir/two.sh")" \
  "$(printf '%s\n' "cat <<A <<'B' " '# first body' 'A' '# second body' 'B' 'y=1 ')"

plant_file "$shell_code_dir" names.sh <<'PLANTED'
  trap 'noun_fn' EXIT; x="adapter_pr_refs" # cut
PLANTED
assert_eq "a name inside a single- or double-quoted string is kept" \
  "$(shell_code "$shell_code_dir/names.sh")" "trap 'noun_fn' EXIT; x=\"adapter_pr_refs\" "

printf '%s\n' 's="open' '# inside' >"$shell_code_dir/open-quote.sh"
printf '%s\n' 'cat <<EOF' '# inside' >"$shell_code_dir/open-heredoc.sh"
printf '%s\n' '# first' 'y=1 # cut' >"$shell_code_dir/next.sh"
assert_eq "a file ending inside an open quote leaves the next file's code alone" \
  "$(shell_code "$shell_code_dir/open-quote.sh" "$shell_code_dir/next.sh")" \
  "$(printf '%s\n' 's="open' '# inside' '' 'y=1 ')"
assert_eq "a file ending inside a heredoc leaves the next file's code alone" \
  "$(shell_code "$shell_code_dir/open-heredoc.sh" "$shell_code_dir/next.sh")" \
  "$(printf '%s\n' 'cat <<EOF' '# inside' '' 'y=1 ')"
rm -rf "$shell_code_dir"

# --- helper placement (#1006) -------------------------------------------------
# helper_placement over the real scripts/test/orch/, then over copies of it,
# each with planted helpers: four placements that break the rule, and one copy
# whose plantings all keep it.
echo
echo "helper placement (#1006)"
out="$(helper_placement "$PLUGIN_ROOT/scripts/test/orch")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "every helper of the real tree is placed by the rule"
else
  bad "every helper of the real tree is placed by the rule" "$out"
fi

placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_uncalled() { :; }' >>"$placement_dir/setup.sh"
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "a shared helper with no caller fails" "$st" 1
assert_eq "naming it, its file, no caller and the rule" "$out" \
  "planted_uncalled is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_single() { :; }' >>"$placement_dir/setup.sh"
plant_file "$placement_dir" zz-one.sh <<'PLANTED'
  # --- planted one
  planted_single
  planted_single
PLANTED
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "a shared helper called from one section file fails" "$st" 1
assert_eq "naming it, its file, its one caller and the rule" "$out" \
  "planted_single is defined in setup.sh and called by zz-one.sh. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

placement_dir="$(tree_copy scripts/test/orch)"
plant_file "$placement_dir" zz-pre.sh <<'PLANTED'
  planted_pre() { :; }
  # --- planted pre
  planted_pre
PLANTED
plant_file "$placement_dir" zz-other.sh <<'PLANTED'
  # --- planted other
  if planted_pre; then :; fi
PLANTED
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "a preamble helper called from another file fails" "$st" 1
assert_eq "naming it, its file, its callers and the rule" "$out" \
  "planted_pre is defined in zz-pre.sh and called by zz-other.sh, zz-pre.sh. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_self() {' '  planted_self' '}' >>"$placement_dir/setup.sh"
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "a shared helper called only by itself fails" "$st" 1
assert_eq "its own body is no caller" "$out" \
  "planted_self is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_arm() { :; }' 'planted_alt() { :; }' >>"$placement_dir/setup.sh"
plant_file "$placement_dir" zz-arm.sh <<'PLANTED'
  # --- planted arm
  case "$1" in
    planted_arm) : ;;
    x|planted_alt) : ;;
  esac
PLANTED
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "a shared helper named only as a case-arm pattern fails" "$st" 1
assert_eq "a pattern is no call" "$out" \
  "planted_alt is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE
planted_arm is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_block() { :; }' 'planted_user() { planted_block; }' \
  'planted_sub() { :; }' 'planted_tick() { :; }' 'planted_and() { :; }' \
  'planted_pipe() { :; }' >>"$placement_dir/setup.sh"
plant_file "$placement_dir" zz-a.sh <<'PLANTED'
  # The helper only zz-a.sh's sections use.
  planted_named() { :; }
  # --- planted a
  planted_user; planted_named; planted_in_section
  a_sub="$(planted_sub 1)"; a_tick=`planted_tick`
  true && planted_and; echo | planted_pipe
PLANTED
plant_file "$placement_dir" zz-b.sh <<'PLANTED'
  # --- planted b
  planted_in_section() { :; }
  planted_user
  # planted_named in a comment, and in strings:
  echo "planted_named"; echo 'x; planted_named'; echo "a
  planted_named"
  echo "$a_sub $(planted_sub 2)" `planted_tick`
  false || true && planted_and; echo |planted_pipe
PLANTED
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "helpers placed by the rule pass" "$st" 0
assert_eq "and print nothing" "$out" ""
rm -rf "${placement_dir%/orch}"

# Heredocs and continuation lines: a helper named in a quoted heredoc body, or
# starting the line after a `\`, is no call; one called in $(...) in an
# unquoted heredoc body is; a name() line in a heredoc body defines nothing.
placement_dir="$(tree_copy scripts/test/orch)"
printf '%s\n' 'planted_quoted() { :; }' 'planted_here() { :; }' \
  'planted_cont() { :; }' >>"$placement_dir/setup.sh"
plant_file "$placement_dir" zz-h.sh <<'PLANTED'
  cat <<EOF
  planted_fake() { :; }
  EOF
  # --- planted heredoc
  cat <<'EOF'
  planted_quoted
  EOF
  cat <<EOF
  x $(planted_here)
  EOF
  echo \
  planted_cont
PLANTED
plant_file "$placement_dir" zz-i.sh <<'PLANTED'
  # --- planted fake
  planted_fake
PLANTED
out="$(helper_placement "$placement_dir")"; st=$?
assert_status "helpers named only in heredocs or continuations fail" "$st" 1
assert_eq "a quoted heredoc body, a continuation and a heredoc name() are no call or definition" "$out" \
  "planted_cont is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE
planted_here is defined in setup.sh and called by zz-h.sh. $HELPER_PLACEMENT_RULE
planted_quoted is defined in setup.sh and called by no file. $HELPER_PLACEMENT_RULE"
rm -rf "${placement_dir%/orch}"

# --- gh op placement (#1037) --------------------------------------------------
# gh_op_placement over the real scripts/, then over copies of it, each with a
# planted file naming a multi-field gh op: three that break the rule, and three
# that keep it.
echo
echo "gh op placement (#1037)"
out="$(gh_op_placement "$PLUGIN_ROOT/scripts")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "no script of the real tree names a multi-field gh op outside the gh module"
else
  bad "no script of the real tree names a multi-field gh op outside the gh module" "$out"
fi

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-command.sh <<'PLANTED'
  planted_read() {
    adapter_pr_refs "$1"
  }
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as a command word fails" "$st" 1
assert_eq "naming the file, the op and the rule" "$out" \
  "scripts/orch/zz-command.sh names adapter_pr_refs. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-capture.sh <<'PLANTED'
  if ! capture out err adapter_issue_state_labels_body "$n"; then :; fi
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as an argument to capture fails" "$st" 1
assert_eq "naming the file and the op" "$out" \
  "scripts/orch/zz-capture.sh names adapter_issue_state_labels_body. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir" zz-die.sh <<'PLANTED'
  gh_or_die --out state "could not read #$n" adapter_pr_state_draft "$n"
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op as an argument to gh_or_die fails" "$st" 1
assert_eq "naming the file and the op" "$out" \
  "scripts/zz-die.sh names adapter_pr_state_draft. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-keep.sh <<'PLANTED'
  # adapter_issue_title_labels in a comment, as issue_title_labels_read reads it
  x=1  # and adapter_pr_refs after code
  planted_adapter_pr_refs() { my_adapter_issue_title_labels_x; }
  adapter_pr_state_draft_read n st dr err
PLANTED
printf '%s\n' 'planted_gh() { adapter_issue_title_labels "$1"; }' \
  >>"$gh_op_dir/orch/gh.sh"
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "comments, longer names and the gh module pass" "$st" 0
assert_eq "and print nothing" "$out" ""
rm -rf "${gh_op_dir%/scripts}"

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-multiline.sh <<'PLANTED'
  x="a string opened here
  # and closed on this line" adapter_pr_refs "$n"
PLANTED
plant_file "$gh_op_dir/orch" zz-param.sh <<'PLANTED'
  y=${x#pat} adapter_issue_state_labels "$n"
PLANTED
plant_file "$gh_op_dir/orch" zz-ansi.sh <<'PLANTED'
  y=$'it\'s # no comment' adapter_pr_state_draft "$n"
PLANTED
plant_file "$gh_op_dir/orch" zz-heredoc.sh <<'PLANTED'
  cat <<EOF
  # adapter_issue_title_labels on a heredoc body line
  EOF
PLANTED
plant_file "$gh_op_dir/orch" zz-literal.sh <<'PLANTED'
  trap 'adapter_issue_state_labels_body' EXIT
  echo "adapter_pr_refs"
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "an op after a # in \${...}, in \$'...', on a heredoc body line or inside a multi-line string, or in a quoted literal, fails" "$st" 1
assert_eq "naming each file and op" "$out" \
  "scripts/orch/zz-ansi.sh names adapter_pr_state_draft. $GH_OP_PLACEMENT_RULE
scripts/orch/zz-heredoc.sh names adapter_issue_title_labels. $GH_OP_PLACEMENT_RULE
scripts/orch/zz-literal.sh names adapter_issue_state_labels_body. $GH_OP_PLACEMENT_RULE
scripts/orch/zz-literal.sh names adapter_pr_refs. $GH_OP_PLACEMENT_RULE
scripts/orch/zz-multiline.sh names adapter_pr_refs. $GH_OP_PLACEMENT_RULE
scripts/orch/zz-param.sh names adapter_issue_state_labels. $GH_OP_PLACEMENT_RULE"
rm -rf "${gh_op_dir%/scripts}"

# --- marked comment prelude placement (#1853) ---------------------------------
# marked_comment_jq_placement over the real scripts/, then over copies of it,
# each with a planted file: one calling the prelude, which breaks the rule, and
# one that only mentions it, which keeps it.
echo
echo "marked comment prelude placement (#1853)"
out="$(marked_comment_jq_placement "$PLUGIN_ROOT/scripts")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "no script of the real tree calls marked_comment_jq outside the Marked comment module and the Issue timeline"
else
  bad "no script of the real tree calls marked_comment_jq outside the Marked comment module and the Issue timeline" "$out"
fi

mcjq_dir="$(tree_copy scripts)"
plant_file "$mcjq_dir/orch" zz-prelude.sh <<'PLANTED'
  planted_read() {
    jq -r "$(marked_comment_jq)"' marked_comment_list | length'
  }
PLANTED
plant_file "$mcjq_dir/orch" zz-keep.sh <<'PLANTED'
  # marked_comment_jq in a comment
  x=1  # and marked_comment_jq after code
  my_marked_comment_jq_x() { :; }
PLANTED
printf '%s\n' 'planted_tl() { marked_comment_jq; }' >>"$mcjq_dir/orch/issue-timeline.sh"
out="$(marked_comment_jq_placement "$mcjq_dir")"; st=$?
assert_status "a call in another module fails, while comments, longer names and the two owning modules pass" "$st" 1
assert_eq "naming only the calling file and the rule" "$out" \
  "scripts/orch/zz-prelude.sh calls marked_comment_jq. $MARKED_COMMENT_JQ_PLACEMENT_RULE"
rm -rf "${mcjq_dir%/scripts}"

# --- declaration substitutions (#1327) ----------------------------------------
# decl_substitutions over the real scripts/, then over copies of it, each with
# a planted module: one with every combined form, and one whose lines all keep
# the rule.
echo
echo "declaration substitutions (#1327)"
out="$(decl_substitutions "$PLUGIN_ROOT/scripts")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "no module of the real tree declares a name with a \$(...) assignment"
else
  bad "no module of the real tree declares a name with a \$(...) assignment" "$out"
fi

decl_dir="$(tree_copy scripts)"
plant_file "$decl_dir/orch" zz-combined.sh <<'PLANTED'
  planted() {
    local x="$(git rev-parse HEAD)"
    local a b=$(date)
    export planted_e="$(pwd)"
    if true; then declare -r planted_d=$(pwd); fi
    true && readonly planted_r="$(pwd)"
    local planted_p="prefix-$(pwd)"
    local planted_f="${planted_x:-$(pwd)}"
    local -a planted_l=($(ls))
  }
PLANTED
out="$(decl_substitutions "$decl_dir")"; st=$?
assert_status "a declaration carrying a \$(...) assignment fails" "$st" 1
assert_eq "naming each file and line and the rule" "$out" \
  "scripts/orch/zz-combined.sh:2 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:3 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:4 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:5 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:6 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:7 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:8 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE
scripts/orch/zz-combined.sh:9 declares a name with a \$(...) assignment. $DECL_SUBSTITUTION_RULE"
rm -rf "${decl_dir%/scripts}"

decl_dir="$(tree_copy scripts)"
plant_file "$decl_dir/orch" zz-split.sh <<'PLANTED'
  planted() {
    local x; x="$(git rev-parse HEAD)"
    local a b; b=$(date) || return
    local y="$x" z=plain
    export planted_e; planted_e="$(pwd)"
    echo "local q=$(pwd)"
    # local c="$(pwd)" in a comment
  }
PLANTED
out="$(decl_substitutions "$decl_dir")"; st=$?
assert_status "the split form, plain values, strings and comments pass" "$st" 0
assert_eq "and print nothing" "$out" ""
rm -rf "${decl_dir%/scripts}"

# --- the helper index (#1144) -------------------------------------------------
# scripts/dev/helpers.sh over the real tree, its listing checked against the
# functions bash itself defines when it sources each covered file, then over a
# copy of scripts/ with a planted file.
echo
echo "the helper index (#1144)"
HELPERS="$PLUGIN_ROOT/scripts/dev/helpers.sh"

# index_names <output>: each function line of a helpers.sh listing as
# "<header path> <name>", sorted.
index_names() {
  printf '%s\n' "$1" | awk -F '\t' '
    /^# / { file = substr($0, 3); next }
    NF >= 2 { print file " " $1 }' | LC_ALL=C sort
}

# sourced_names <file>: the functions a fresh bash defines by sourcing <file>.
sourced_names() {
  env -i bash -c 'source "$1" >/dev/null 2>&1; declare -F' _ "$1" | sed 's/^declare -f //'
}

# index_expected <rel>...: "<rel> <name>" for every function each covered file
# defines but cmd_*, sorted - from declare -F, but from the column-0 grep for
# setup.sh, which runs the suite's setup when it loads.
index_expected() {
  local rel
  for rel in "$@"; do
    if [ "$rel" = scripts/test/orch/setup.sh ]; then
      col0_names "$PLUGIN_ROOT/$rel"
    else
      sourced_names "$PLUGIN_ROOT/$rel"
    fi | grep -v '^cmd_' | sed "s|^|$rel |"
  done | LC_ALL=C sort
}

index_modules=()
for f in "$PLUGIN_ROOT"/scripts/orch/*.sh; do index_modules+=("scripts/orch/${f##*/}"); done
index_tests=(scripts/test/orch/setup.sh scripts/test/gh_adapter_fake.sh scripts/test/tally.sh)

grep_disagrees=""
for rel in "${index_modules[@]}" scripts/test/gh_adapter_fake.sh scripts/test/tally.sh; do
  [ "$(col0_names "$PLUGIN_ROOT/$rel" | LC_ALL=C sort)" = \
    "$(sourced_names "$PLUGIN_ROOT/$rel" | LC_ALL=C sort)" ] || grep_disagrees+=" $rel"
done
assert_eq "the column-0 grep finds what declare -F finds, in every file that sources cleanly" \
  "$grep_disagrees" ""

out="$(cd / && "$HELPERS")"; st=$?
assert_status "the default listing succeeds" "$st" 0
assert_eq "it lists exactly the non-cmd_ functions of every module" \
  "$(index_names "$out")" "$(index_expected "${index_modules[@]}")"
assert_eq "under one header per module, in file order, relative to the repo root" \
  "$(printf '%s\n' "$out" | grep '^# ')" "$(printf '# %s\n' "${index_modules[@]}")"
index_default="$out"

out="$(cd / && "$HELPERS" --tests)"; st=$?
assert_status "the --tests listing succeeds" "$st" 0
assert_eq "--tests lists exactly the non-cmd_ functions of the shared setup, the gh fake and the tally" \
  "$(index_names "$out")" "$(index_expected "${index_tests[@]}")"
assert_eq "under their headers" "$(printf '%s\n' "$out" | grep '^# ')" \
  "$(printf '# %s\n' "${index_tests[@]}")"

undescribed=""
for name in base_branch base_source section_body review_budget float_add \
  require_state ticket_worktree_path fake_online orch_gh_failing; do
  printf '%s\n' "$index_default"$'\n'"$out" | grep -qE "^$name"$'\t''[^-]' \
    || undescribed+=" $name"
done
assert_eq "each of the nine newly commented helpers prints a description" "$undescribed" ""

index_dir="$(tree_copy scripts)"
plant_file "$index_dir/orch" zz-planted.sh <<'PLANTED'
  # planted_one <a> [b]: the first line of its comment,
  # not its second.
  planted_one() { :; }
  # Spaced, its comment holding no signature.
  planted_spaced () {
    :
  }
  planted_bare() { :; }
  # The pair below shares this one comment.
  planted_first() { :; }
  planted_second() { :; }
  # cmd_planted: an entry point.
  cmd_planted() { :; }
  planted_awk() {
    awk '
  function planted_in_awk() { return 1 }
  planted_awk_col0() { return 1 }
    '
    cat <<'DOC'
  planted_in_doc() { :; }
  DOC
  }
  planted_last() { :; }
  # planted_long <a> <b> <c>:
  # the second line, where the signature filled the first.
  planted_long() { :; }
PLANTED
index_want="# orch/zz-planted.sh
planted_one	the first line of its comment,
planted_spaced	Spaced, its comment holding no signature.
planted_bare	-
planted_first	The pair below shares this one comment.
planted_second	-
planted_awk	-
planted_last	-
planted_long	the second line, where the signature filled the first."
out="$(cd "$index_dir" && ./dev/helpers.sh orch/zz-planted.sh)"; st=$?
assert_status "a file argument succeeds" "$st" 0
assert_eq "it lists that file alone, under the path as given: one-liners and name () definitions, a stripped signature or the line after one filling the first, - for no comment directly above, no cmd_ or embedded function" \
  "$out" "$index_want"
out="$(cd / && "$index_dir/dev/helpers.sh" "$index_dir/orch/zz-planted.sh")"; st=$?
assert_eq "an absolute file argument is its own header" \
  "$(printf '%s\n' "$out" | sed -n 1p)" "# $index_dir/orch/zz-planted.sh"
out="$(cd / && "$index_dir/dev/helpers.sh")"
assert_eq "the default listing of a copy includes a planted module" \
  "$(printf '%s\n' "$out" | grep -c '^# scripts/orch/zz-planted.sh$')" 1

plant_file "$index_dir/orch" zz-subst.sh <<'PLANTED'
real_before() { :; }
x=$(
cmd
planted_in_cmdsub() { :; }
)
y=${z:-
planted_in_param() { :; }
}
w=`
planted_in_backtick() { :; }
`
real_after() { :; }
PLANTED
out="$(cd "$index_dir" && ./dev/helpers.sh orch/zz-subst.sh)"
assert_eq "a column-0 definition inside a multi-line \$(...), \${...} or backtick substitution is not listed" \
  "$out" "# orch/zz-subst.sh
real_before	-
real_after	-"
nolib_dir="$(tree_copy scripts)"
rm -f "$nolib_dir/test/shell_code.awk"
out="$(cd / && "$nolib_dir/dev/helpers.sh" 2>&1)"; st=$?
assert_status "the helper index without its library exits non-zero" "$st" 1
assert_contains "naming the file" "$out" "scripts/test/shell_code.awk"
rm -rf "${nolib_dir%/scripts}"

for args in "--tests orch/zz-planted.sh" "orch/missing.sh" "--bogus" \
  "orch/zz-planted.sh orch/base.sh"; do
  # shellcheck disable=SC2086 # the words are the arguments
  out="$(cd "$index_dir" && ./dev/helpers.sh $args 2>&1 >/dev/null)"; st=$?
  assert_status "helpers.sh $args is a usage error" "$st" 2
  assert_contains "and prints a usage line on stderr" "$out" "usage: "
done
rm -rf "${index_dir%/scripts}"
