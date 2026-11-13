# shellcheck shell=bash
# The guard below is never true - (( 0 )) is a keyword no variable or function
# can redefine - so the line never runs; it points shellcheck at setup.sh's
# definitions, which orch_test.sh evals before this file's sections.
# shellcheck source=setup.sh
(( 0 )) && source setup.sh

# ALL_RUNNER_FILES: the files, by name in scripts/test/, that make up all.sh's
# runnable copy. Every fixture that copies all.sh derives its copy, its written
# list and its shellcheck counts from it.
ALL_RUNNER_FILES=(all.sh test_jobs.sh report.sh test_tree.sh)

# count_lines [<grep flag>...] <pattern> <text>: prints how many lines of
# <text> match <pattern>. Every argument before the last two goes to grep
# as-is.
count_lines() {
  local pattern="${*: -2:1}" text="${!#}"
  printf '%s\n' "$text" | grep -c "${@:1:$#-2}" "$pattern"
}

# slot_hold <pool> <slot>: creates <pool> and holds <slot>'s lock in a
# background process, its pid in SLOT_HOLDER. The holder opens the fifo's write
# end on fd 8, then opens and locks the slot file on fd 9, and writes the ready
# line only when both worked; the read returns 1 on EOF (the holder died first)
# or after 10 seconds. SLOT_HOLDER names the holder on that path too, so
# slot_release is safe after it.
slot_hold() {
  local fifo line
  mkdir -p "$1"
  fifo="$(mktemp -u)"
  mkfifo "$fifo" || return 1
  bash -c 'exec 8>"$2" && exec 9>>"$1" && flock 9 && echo ready >&8 && exec 8>&- && exec sleep 60' _ "$1/slot.$2" "$fifo" &
  SLOT_HOLDER=$!
  line="$(fifo_read_line 10 "slot_hold ($fifo)" "$fifo")"
  [ "$line" = ready ] || { rm -f "$fifo"; return 1; }
  rm -f "$fifo"
}
# slot_release: kills the holder slot_hold started, and waits for it.
slot_release() { kill -9 "$SLOT_HOLDER" 2>/dev/null; wait "$SLOT_HOLDER" 2>/dev/null; return 0; }
# notice_wait <file>: waits, up to 5 seconds, for the waiting notice in <file>;
# returns 0 either way, the assertion after it reports a missing notice.
notice_wait() {
  local _
  for _ in $(seq 100); do
    grep -q 'waiting for a job slot' "$1" 2>/dev/null && break
    sleep 0.05
  done
  return 0
}
# pool_cpu_file <file> <slots>: writes a CPU quota file of 2 CPUs per slot (a
# quota of 200000 per slot), which a 50% pool share, as jp_run sets, sizes to
# <slots> slots. Under another share the slot count follows that share: at the
# default 75%, 1 still gives 1 slot (1.5 rounded down).
pool_cpu_file() { printf '%s 100000\n' "$(($2 * 200000))" >"$1"; }

# stub_all_tree <dir> <shellcheck log> [<extra tool>...]: builds <dir> as a copy
# of ALL_RUNNER_FILES beside a passing stub for each name in
# SUITES (suites_read first), with <dir>/bin holding links to the tools all.sh
# needs, the extra ones included, and a shellcheck stub that logs "+" to the log
# when it starts and "-" when it ends, 0.2 seconds apart. A stub suite logs
# "<name> ran" to scripts/test/log.
stub_all_tree() {
  local dir="$1" log="$2" tool stub
  shift 2
  mkdir -p "$dir/scripts/test" "$dir/bin"
  (cd "$(dirname "$SUITE_SCRIPT")" && cp "${ALL_RUNNER_FILES[@]}" "$dir/scripts/test/")
  for tool in bash dirname awk tail mktemp rm mkdir sleep cat "$@"; do
    ln -s "$(command -v "$tool")" "$dir/bin/$tool"
  done
  for stub in "${SUITES[@]}"; do
    printf '#!/usr/bin/env bash\necho "%s ran" >>"$(dirname "$0")/log"\necho; echo "1 passed, 0 failed"\n' \
      "$stub" >"$dir/scripts/test/$stub"
  done
  printf '#!/usr/bin/env bash\necho + >>%q\nsleep 0.2\necho - >>%q\nexit 0\n' "$log" "$log" \
    >"$dir/bin/shellcheck"
  chmod +x "$dir/bin/shellcheck"
}
# log_peak <log>: the most "+" lines the log shows open at once, a "-" closing
# one.
log_peak() {
  awk '/^\+/ { n++; if (n > max) max = n } /^-/ { n-- } END { print max + 0 }' "$1"
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

# The test-helper placement rule, as helper_placement's message states it.
HELPER_PLACEMENT_RULE="The test-helper placement rule: a test helper used by more than one file, or only by setup.sh's own code, lives in setup.sh; one used by only one file lives in that file's preamble; one already defined inside a section stays there; a helper never moves into a section."

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

# The multi-field gh ops gh_op_placement looks for outside the gh module,
# space-separated, and the trust read it also lets the Trust module name.
GH_MULTI_FIELD_OPS="adapter_issue_state_labels adapter_issue_state_labels_body adapter_issue_title_labels adapter_issues_labelled_bodies adapter_pr_state_draft adapter_pr_refs adapter_pr_url_head"
GH_TRUST_READ_OPS="adapter_issue_authorship"

# The gh op placement rule, as gh_op_placement's message states it.
GH_OP_PLACEMENT_RULE="The rule: only the gh module, scripts/orch/gh.sh, names a multi-field gh op (${GH_MULTI_FIELD_OPS// /, }); every other script reads one through its reader, which decodes its fields - and adapter_issue_authorship is also named by the Trust module, scripts/orch/trust.sh, whose reader it is."

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

# gh_op_placement <dir>: name_placement for the multi-field gh ops, outside
# the gh module, orch/gh.sh - adapter_issue_authorship also outside the Trust
# module, orch/trust.sh, which reads it; a line is "<file> names <op>. <rule>".
gh_op_placement() {
  local rc=0 out="" part ops owners pair
  local pairs=(
    "$GH_MULTI_FIELD_OPS|./orch/gh.sh"
    "$GH_TRUST_READ_OPS|./orch/gh.sh ./orch/trust.sh"
  )
  for pair in "${pairs[@]}"; do
    ops="${pair%%|*}" owners="${pair#*|}"
    rc=0
    # owners is a space-separated path list: split it into arguments
    # shellcheck disable=SC2086
    part="$(name_placement "$1" "$GH_OP_PLACEMENT_RULE" names "$ops" $owners)" || rc=$?
    [ "$rc" -ne 2 ] || return 2
    [ -z "$part" ] || out="${out:+$out
}$part"
  done
  [ -z "$out" ] && return 0
  printf '%s\n' "$out" | LC_ALL=C sort -u
  return 1
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
assert_eq "GH_REPO and GH_HOST are unset" "${GH_REPO-unset} ${GH_HOST-unset}" "unset unset"
assert_eq "cwd is the harness's fresh temp directory" "$(pwd)" "$SUITE_CWD"
# The caller's ORCH_* knobs are cleared, ORCH_TEST_* kept. The probe run is a
# child suite run started with ORCH_AUTOPILOT, GH_REPO, GH_HOST and a probe
# variable exported;
# the child (which has the probe set) asserts, and does not start a child.
assert_eq "ORCH_AUTOPILOT is unset" "${ORCH_AUTOPILOT-unset}" "unset"
# No repo-local git variable (git rev-parse --local-env-vars) and no commit
# identity variable reaches the sections: the runner clears them, a hook's
# GIT_DIR and GIT_INDEX_FILE included. Other GIT_* knobs are kept.
git_env_set=""
for git_env_name in $(git rev-parse --local-env-vars) \
  $(source "$PLUGIN_ROOT/scripts/test/git_env.sh" && echo "${TEST_GIT_ENV_IDENTITY[*]}"); do
  [ -z "${!git_env_name+x}" ] || git_env_set="$git_env_set $git_env_name"
done
assert_eq "no repo-local or identity git variable is set" "${git_env_set:-none}" "none"
unset git_env_set git_env_name
if [ -n "${ORCH_TEST_GIT_ENV_PROBE:-}" ]; then
  assert_eq "GIT_SSH_COMMAND is kept" "${GIT_SSH_COMMAND-unset}" "ssh -v"
fi
if [ -n "${ORCH_TEST_ISOLATION_PROBE:-}" ]; then
  assert_eq "an ORCH_TEST_* variable is kept" "$ORCH_TEST_ISOLATION_PROBE" "kept"
elif [ -z "${ORCH_TEST_GIT_ENV_PROBE:-}" ]; then
  out="$(ORCH_AUTOPILOT=1 GH_REPO=dev/own GH_HOST=ghe.example.com \
    ORCH_TEST_ISOLATION_PROBE=kept ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' \
    ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"
  assert_contains "a child run with ORCH_AUTOPILOT exported sees it unset" "$out" "ok   ORCH_AUTOPILOT is unset"
  assert_contains "a child run with GH_REPO and GH_HOST exported sees them unset" "$out" "ok   GH_REPO and GH_HOST are unset"
  assert_contains "a child run keeps an exported ORCH_TEST_* variable" "$out" "ok   an ORCH_TEST_* variable is kept"
fi

# --- isolation under a git hook (#1905) ---------------------------------------
echo
echo "isolation under a git hook (#1905)"
# A child run started as a git hook in a linked worktree starts it: GIT_DIR
# and GIT_INDEX_FILE are absolute paths into a victim repo. The child runs
# isolation and branch create, whose fixtures write to a repo; the victim's
# HEAD, refs and config must come back unchanged.
victim="$(mktemp -d)"
git -C "$victim" init -q main
git -C "$victim/main" -c user.name=v -c user.email=v@example.com commit -q --allow-empty -m victim
git -C "$victim/main" worktree add -q "$victim/wt" -b wt
victim_gd="$victim/main/.git/worktrees/wt"
victim_snap() {
  git -C "$victim/main" symbolic-ref HEAD
  git -C "$victim/wt" symbolic-ref HEAD
  git -C "$victim/main" for-each-ref
  cat "$victim/main/.git/config"
}
victim_before="$(victim_snap)"
out="$(GIT_DIR="$victim_gd" GIT_INDEX_FILE="$victim_gd/index" GIT_AUTHOR_NAME=Hook \
  GIT_COMMITTER_EMAIL=hook@example.com GIT_SSH_COMMAND="ssh -v" \
  ORCH_TEST_GIT_ENV_PROBE=1 ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' \
  ORCH_TEST_ONLY='^(isolation|branch create)$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
assert_status "a child run started with a hook's git variables passes" "$st" 0
assert_contains "the child sees the repo-local and identity variables unset" "$out" \
  "ok   no repo-local or identity git variable is set"
assert_contains "the child keeps GIT_SSH_COMMAND" "$out" "ok   GIT_SSH_COMMAND is kept"
assert_contains "the child ran branch create" "$out" "branch create"
assert_eq "the victim's HEAD, refs and config are unchanged" "$(victim_snap)" "$victim_before"
rm -rf "$victim"
unset -f victim_snap

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

# One copy of the scripts tree with three planted sections whose headers end in
# trailing dashes like the real ones, shared by every filter case below;
# matching ignores case, so the first pattern selects two of them.
filter_dir="$(planted_copy <<'PLANTED'
  # --- Planted Alpha ------------------------------------------------------
  echo; echo "planted alpha"; ok "alpha ran"
  # --- planted beta -------------------------------------------------------
  echo; echo "planted beta"; ok "beta ran"
  # --- planted gamma ------------------------------------------------------
  echo; echo "planted gamma"; ok "gamma ran"
PLANTED
)"
filter_suite="$filter_dir/scripts/test/orch_test.sh"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted (alpha|beta)$' \
  bash "$filter_suite" 2>/dev/null)"
assert_eq "matches titles without their trailing dashes" \
  "$(count_lines -xE 'planted alpha|planted beta' "$out")" "2"
assert_eq "runs isolation alongside the matched sections" \
  "$(count_lines -x 'isolation' "$out")" "1"
assert_eq "skips the sections the pattern does not match" \
  "$(count_lines -x 'planted gamma' "$out")" "0"

# Case-insensitive match, and the top-level branches of an alternation.
filter_err="$(mktemp)"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted alpha$' bash "$filter_suite" 2>&1)"; st=$?
assert_status "a lowercase filter selects a capitalised title" "$st" 0
assert_contains "runs the capitalised section" "$out" "ok   alpha ran"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted alpha|^nonexistent' \
  bash "$filter_suite" 2>"$filter_err")"; st=$?
assert_status "an alternation with a dead branch exits 1" "$st" 1
assert_eq "names the dead branch, ending with the list notice" "$(cat "$filter_err")" \
  "orch_test.sh: ORCH_TEST_ONLY branch '^nonexistent' matches no section; the selectable sections are:"
assert_contains "lists the selectable sections on stdout" "$out" "planted beta"
assert_eq "runs no section for a dead branch" "$(count_lines 'alpha ran' "$out")" "0"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^nonexistent|^planted alpha|^missing' \
  bash "$filter_suite" 2>"$filter_err")"; st=$?
assert_status "two dead branches beside a live one exit 1" "$st" 1
assert_eq "names each dead branch in order, only the last ending the notice" "$(cat "$filter_err")" \
  "orch_test.sh: ORCH_TEST_ONLY branch '^nonexistent' matches no section
orch_test.sh: ORCH_TEST_ONLY branch '^missing' matches no section; the selectable sections are:"
assert_contains "lists the sections on stdout for two dead branches" "$out" "planted beta"

out="$(ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^nonexistent|^missing' bash "$filter_suite" 2>"$filter_err")"; st=$?
assert_status "an all-dead alternation exits 1" "$st" 1
assert_eq "names each branch of an all-dead alternation" "$(cat "$filter_err")" \
  "orch_test.sh: ORCH_TEST_ONLY branch '^nonexistent' matches no section
orch_test.sh: ORCH_TEST_ONLY branch '^missing' matches no section; the selectable sections are:"

# Grouped, nested, bracketed and escaped bars are not split points; an empty
# branch is handed to grep as it stands.
for filter_pat in '^planted (alpha|nonexistent)$' '^planted ((alpha)|(nonexistent))$' \
  '^planted alph[]|a]' '^planted alph[^x|]$' '^planted alpha\|*'; do
  out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY="$filter_pat" bash "$filter_suite" 2>&1)"; st=$?
  assert_status "the filter $filter_pat is not refused" "$st" 0
  assert_contains "the filter $filter_pat runs alpha" "$out" "ok   alpha ran"
done
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted alpha$|^planted beta$' \
  bash "$filter_suite" 2>&1)"; st=$?
assert_status "an all-live alternation passes" "$st" 0
assert_contains "an all-live alternation runs its second branch" "$out" "ok   beta ran"
rm -f "$filter_err"

# An empty branch matches every title, so the whole suite would run: the copy
# is trimmed to the isolation section and the planted ones first.
find "$filter_dir/scripts/test/orch" -name '*.sh' ! -name harness.sh ! -name setup.sh ! -name zz-planted.sh -delete
filter_cut="$(grep -n '^# --- isolation under a git hook' "$filter_dir/scripts/test/orch/harness.sh" | cut -d: -f1)"
sed -i "${filter_cut},\$d" "$filter_dir/scripts/test/orch/harness.sh"
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^planted alpha||^planted beta' \
  bash "$filter_suite" 2>&1)"; st=$?
assert_status "an alternation with an empty branch is not refused" "$st" 0
assert_contains "an empty branch still runs the matched sections" "$out" "ok   beta ran"
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
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
# The reference run: isolation alone, not quiet. Its ok lines give the
# isolation section's pass count, which the quiet runs' summaries must match.
out="$(ORCH_TEST_JOBS=1 ORCH_TEST_QUIET='' ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>&1)"; st=$?
quiet_n="$(count_lines '^  ok ' "$out")"
assert_status "the non-quiet reference run passes" "$st" 0
assert_ne "the reference run prints an ok line" "$quiet_n" 0
assert_eq "without quiet mode, counts every printed ok line in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "$quiet_n passed, 0 failed"
assert_eq "prints the header once in a clean run" "$(printf '%s\n' "$out" | grep -cx 'orch.sh tests')" "1"
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
# and its own summary code: its lines before `# >>> checks`, a planted ok (after
# a tally_init, for a suite that makes its tally file inside its checks), then
# its lines from its `# >>> summary` line on.
# The copies sit in scripts/test/ of a fresh root, beside the git_env.sh every
# runner sources first, and the tally.sh they all source.
cut_root="$(mktemp -d)"
cut_dir="$cut_root/scripts/test"
mkdir -p "$cut_dir" && cp "$(dirname "$SUITE_SCRIPT")/git_env.sh" "$(dirname "$SUITE_SCRIPT")/tally.sh" "$(dirname "$SUITE_SCRIPT")/fifo.sh" "$cut_dir/"
for quiet_suite in "${SUITES[@]}"; do
  [ "$quiet_suite" = orch_test.sh ] && continue
  awk '
    $0 == "# >>> checks" {
      print "[ -n \"${tally_file:-}\" ] || tally_init"
      print "ok \"a planted check\""; skip = 1; next }
    skip && $0 == "# >>> summary" { skip = 0 }
    !skip { print }' "$(dirname "$SUITE_SCRIPT")/$quiet_suite" >"$cut_dir/$quiet_suite"
  assert_eq "$quiet_suite's cut-down copy holds the planted check" \
    "$(grep -cx 'ok "a planted check"' "$cut_dir/$quiet_suite")" "1"
  assert_eq "$quiet_suite's cut-down copy holds its summary" \
    "$(grep -cx 'tally_summary' "$cut_dir/$quiet_suite")" "1"
  out="$(ORCH_TEST_QUIET=1 bash "$cut_dir/$quiet_suite" 2>&1)"; st=$?
  assert_status "$quiet_suite's cut-down copy exits 0 when quiet" "$st" 0
  assert_eq "$quiet_suite prints no ok line when quiet" \
    "$(count_lines '^  ok ' "$out")" "0"
  assert_contains "$quiet_suite still reports the planted pass when quiet" "$out" "1 passed, 0 failed"
done
rm -rf "$cut_root"

# --- the parallel runner (ORCH_TEST_JOBS, #780) -------------------------------
# A copy of the scripts tree with planted sections. Two passing ones run with
# ORCH_TEST_JOBS=2, compared with the same filter run sequentially; then the
# others - one slow, one writing to stderr, one exiting mid-way, one failing -
# run in parallel, asserted on their combined output. The copy also holds
# `seq early exit`, which only the sequential path runs (see below).
echo
echo "the parallel runner (ORCH_TEST_JOBS, #780)"
par_dir="$(planted_copy <<'PLANTED'
  # --- paired alpha ---------------------------------------------------------
  echo; echo "paired alpha"; ok "alpha ran"; ok "alpha ran again"
  # --- paired beta ----------------------------------------------------------
  echo; echo "paired beta"; ok "beta ran"
  # --- seq early exit
  echo; echo "seq early exit"; ok "before the exit"; exit 0
  # --- planted slow
  echo; echo "planted slow"; sleep 2; ok "slept"
  # --- planted stderr
  echo; echo "planted stderr"; echo "a planted stderr line" >&2; echo "a second planted stderr line" >&2; ok "wrote"
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
  out="$(ORCH_TEST_JOBS="$par_jobs" ORCH_TEST_ONLY='^isolation$' bash "$SUITE_SCRIPT" 2>"$par_dir/stderr")"; st=$?
  assert_status "ORCH_TEST_JOBS='$par_jobs' exits 1" "$st" 1
  assert_contains "ORCH_TEST_JOBS='$par_jobs' is named in the message on stderr" "$(cat "$par_dir/stderr")" \
    "ORCH_TEST_JOBS='$par_jobs'"
  assert_eq "ORCH_TEST_JOBS='$par_jobs' prints none of it on stdout" \
    "$(printf '%s\n' "$out" | grep -c 'ORCH_TEST_JOBS')" "0"
  assert_eq "ORCH_TEST_JOBS='$par_jobs' runs no section" \
    "$(printf '%s\n' "$out" | grep -c 'passed')" "0"
done

out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=4 ORCH_TEST_ONLY='^planted ' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run with a failing section exits 1" "$st" 1
assert_eq "prints a slow early section in file order" \
  "$(printf '%s\n' "$out" | grep -xE 'isolation|planted [a-z]+' | tr '\n' ',')" \
  "isolation,planted slow,planted stderr,planted exit,planted failure,"
assert_contains "fails a section that wrote to stderr, with its lines as details" "$out" \
  "$(printf "  FAIL section 'planted stderr' wrote to stderr\n     a planted stderr line\n     a second planted stderr line")"
assert_eq "puts that FAIL in the section's place in the walk order" \
  "$(printf '%s\n' "$out" | grep -xE "isolation|planted [a-z]+|  FAIL section 'planted stderr' wrote to stderr" | tr '\n' ',')" \
  "isolation,planted slow,planted stderr,  FAIL section 'planted stderr' wrote to stderr,planted exit,planted failure,"
assert_contains "reports a section that exits mid-way as a FAIL naming it" "$out" \
  "  FAIL section 'planted exit' reported no counts"
assert_contains "keeps a planted FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_eq "sums both failures into the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "14 passed, 3 failed"
# Each failing path alone, so neither passes on the strength of the other.
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted exit$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section exits mid-way exits 1" "$st" 1
assert_contains "reports that section alone as a FAIL naming it" "$out" \
  "  FAIL section 'planted exit' reported no counts"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "12 passed, 1 failed"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted failure$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>&1)"; st=$?
assert_status "a parallel run whose only failing section has a failing check exits 1" "$st" 1
assert_contains "keeps that check's FAIL line with its detail line" "$out" \
  "$(printf '  FAIL a planted failure\n     its detail line')"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "12 passed, 1 failed"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^planted stderr$' \
  bash "$par_dir/scripts/test/orch_test.sh" 2>"$par_dir/stderr")"; st=$?
assert_status "a parallel run whose only failing section wrote to stderr exits 1" "$st" 1
assert_contains "prints that section's stderr lines on stdout" "$out" \
  "$(printf "  FAIL section 'planted stderr' wrote to stderr\n     a planted stderr line\n     a second planted stderr line")"
assert_eq "counts that one failure in the summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "13 passed, 1 failed"
assert_eq "leaves the section's stderr off the real stderr" \
  "$(grep -c 'a planted stderr line' "$par_dir/stderr")" "0"
# The sequential path, reusing the parallel copy above (its `seq early exit`
# section runs only here): a section that exits before the summary is a failure.
seq_run() { ORCH_TEST_QUIET="${2:-}" ORCH_TEST_JOBS=1 ORCH_TEST_ONLY="$1" bash "$par_suite" 2>&1; }
out="$(seq_run '^(seq early exit|planted failure)$')"; st=$?
assert_status "a sequential run whose section exits 0 early exits 1" "$st" 1
assert_contains "reports it as no counts, with the exit status" "$out" \
  "$(printf '  FAIL the run reported no counts\n     it exited 0 before its summary')"
assert_eq "counts the miss in the summary" "$(printf '%s\n' "$out" | tail -n 1)" "13 passed, 1 failed"
assert_eq "prints the header once" "$(printf '%s\n' "$out" | grep -cx 'orch.sh tests')" "1"
out="$(seq_run '^seq early exit$' 1)"; st=$?
assert_status "the quiet early-exit run exits 1" "$st" 1
assert_contains "still prints the FAIL line" "$out" "  FAIL the run reported no counts"
assert_eq "and the summary" "$(printf '%s\n' "$out" | tail -n 1)" "13 passed, 1 failed"
rm -rf "$par_dir"

# The section deadline (ORCH_TEST_SECTION_TIMEOUT). Planted sections hang on a
# nested child that carries a unique marker in its command line.
dl_mark="orchdeadline$$x$RANDOM"
dl_dir="$(planted_copy <<PLANTED
  # --- planted hang
  echo; echo "planted hang"; echo "output before the hang"
  bash -c 'sleep 600; : ${dl_mark}hang' &
  wait
  # --- planted fine
  echo; echo "planted fine"; ok "fine ran"
  # --- planted nap
  echo; echo "planted nap"; sleep 2.5; ok "napped"
  # --- planted nap two
  echo; echo "planted nap two"; sleep 2.5; ok "napped two"
  # --- planted nap three
  echo; echo "planted nap three"; sleep 2.5; ok "napped three"
  # --- planted long nap
  echo; echo "planted long nap"; sleep 4; ok "napped long"
PLANTED
)"
dl_suite="$dl_dir/scripts/test/orch_test.sh"
dl_start=$SECONDS
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=3 ORCH_TEST_SECTION_TIMEOUT=2 \
  ORCH_TEST_ONLY='^planted (hang|fine)$' bash "$dl_suite" 2>&1)"; st=$?
dl_took=$((SECONDS - dl_start))
assert_status "a parallel run with a hanging section exits non-zero" "$st" 1
assert_eq "and finishes well within the hang" "$([ "$dl_took" -lt 60 ] && echo fast)" "fast"
assert_contains "prints the hanging section's output, then its timeout FAIL" "$out" \
  "$(printf 'output before the hang\n  FAIL section '"'"'planted hang'"'"' timed out\n     after 2s; its process tree was stopped')"
assert_contains "still passes the section planted beside it" "$out" "  ok   fine ran"
assert_eq "leaves no process with the hang's marker" \
  "$(cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" "\n" | grep -c "${dl_mark/#o/[o]}hang")" "0"
# The KILL escalation, on the process-tree stop helper directly: a child that
# ignores TERM and carries a marker is present once, survives a plain TERM, and
# is gone after test_jobs_stop_tree. Anything left is KILLed by marker.
if [ -r "/proc/$$/stat" ]; then
  out="$("$BASH" -c 'source "$1"; source "$4"; mark="$2$3"
    marked() { cat /proc/[0-9]*/cmdline 2>/dev/null | tr "\0" "\n" | grep -c "${mark/#o/[o]}"; }
    fdir="$(mktemp -d)"; mkfifo "$fdir/trap"
    bash -c "trap \"\" TERM; echo ready >\"$fdir/trap\"; while :; do sleep 1; done # $mark" &
    pid=$!
    if msg="$(fifo_read_line 5 "KILL check ($fdir/trap)" "$fdir/trap" 2>&1 >/dev/null)"; then
      echo "before=$(marked)"
      kill -TERM "$pid"; sleep 0.3
      kill -0 "$pid" 2>/dev/null && echo "alive=yes" || echo "alive=no"
      test_jobs_stop_tree "$pid"
      echo "after=$(marked)"
    else
      echo "before=$msg"
    fi
    for f in /proc/[0-9]*/cmdline; do
      tr "\0" "\n" <"$f" 2>/dev/null | grep -q "${mark/#o/[o]}" &&
        { p="${f#/proc/}"; kill -KILL "${p%/cmdline}" 2>/dev/null; }
    done
    rm -rf "$fdir"' _ "$(dirname "$SUITE_SCRIPT")/test_jobs.sh" "$dl_mark" stubborn "$(dirname "$SUITE_SCRIPT")/fifo.sh" 2>&1)"
  assert_eq "a TERM-ignoring child carries its marker on exactly one process" \
    "$(printf '%s\n' "$out" | grep -x 'before=.*')" "before=1"
  assert_eq "and survives a plain TERM" "$(printf '%s\n' "$out" | grep -x 'alive=.*')" "alive=yes"
  assert_eq "test_jobs_stop_tree's KILL escalation leaves no process with its marker" \
    "$(printf '%s\n' "$out" | grep -x 'after=.*')" "after=0"
else
  skip "test_jobs_stop_tree's KILL escalation leaves no process with its marker" "no /proc here"
fi
for dl_val in 0 abc; do
  out="$(ORCH_TEST_JOBS=2 ORCH_TEST_SECTION_TIMEOUT="$dl_val" ORCH_TEST_ONLY='^planted fine$' \
    bash "$dl_suite" 2>&1)"; st=$?
  assert_status "ORCH_TEST_SECTION_TIMEOUT='$dl_val' exits 1" "$st" 1
  assert_contains "names the variable" "$out" "ORCH_TEST_SECTION_TIMEOUT='$dl_val'"
  assert_eq "and runs no section" "$(printf '%s\n' "$out" | grep -c 'passed')" "0"
done
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=1 ORCH_TEST_SECTION_TIMEOUT=2 \
  ORCH_TEST_ONLY='^planted long nap$' bash "$dl_suite" 2>&1)"; st=$?
assert_status "a sequential run has no deadline" "$st" 0
assert_eq "and reports no timeout" "$(printf '%s\n' "$out" | grep -c 'timed out')" "0"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=1 ORCH_TEST_SECTION_TIMEOUT=abc \
  ORCH_TEST_ONLY='^planted fine$' bash "$dl_suite" 2>&1)"; st=$?
assert_status "a sequential run ignores an invalid deadline" "$st" 0
assert_eq "and reports no timeout" "$(printf '%s\n' "$out" | grep -c 'timed out')" "0"
out="$(ORCH_TEST_QUIET='' ORCH_TEST_JOBS=2 ORCH_TEST_SECTION_TIMEOUT=4 \
  ORCH_TEST_ONLY='^planted nap( two| three)?$' bash "$dl_suite" 2>&1)"; st=$?
assert_status "the clock starts at the child's start, not its wait for a slot" "$st" 0
assert_eq "so a queued section reports no timeout" "$(printf '%s\n' "$out" | grep -c 'timed out')" "0"
rm -rf "$dl_dir"

# --- the parallel runner's start order (#2857) ------------------------------
# A copy of the scripts tree with planted sections, each logging its process id
# and name to $ord_log as it starts, over a planted durations file beside the
# runner. The runner starts its children one after another, so their ids rise in
# start order whatever order they boot and log in: the start order is the log
# sorted by id.
echo
echo "the parallel runner's start order (#2857)"
ord_dir="$(planted_copy <<'PLANTED'
  # --- ord a
  echo "$$ ord a" >>"$ORD_LOG"; echo; echo "ord a"; ok "a ran"
  # --- ord b
  echo "$$ ord b" >>"$ORD_LOG"; echo; echo "ord b"; ok "b ran"
  # --- ord c
  echo "$$ ord c" >>"$ORD_LOG"; echo; echo "ord c"; ok "c ran"
  # --- ord d
  echo "$$ ord d" >>"$ORD_LOG"; echo; echo "ord d"; ok "d ran"
  # --- ord unlisted
  echo "$$ ord unlisted" >>"$ORD_LOG"; echo; echo "ord unlisted"; ok "u ran"
PLANTED
)"
ord_suite="$ord_dir/scripts/test/orch_test.sh"
ord_file="$ord_dir/scripts/test/section-durations.tsv"
ord_log="$ord_dir/start.log"
# ord_run <jobs> <filter>: run the planted sections; the start order, then the
# header order of the output, one comma-separated line each.
ord_run() {
  : >"$ord_log"
  ord_out="$(ORD_LOG="$ord_log" ORCH_TEST_QUIET='' ORCH_TEST_JOBS="$1" ORCH_TEST_ONLY="$2" \
    bash "$ord_suite" 2>&1)"; ord_st=$?
  ord_started="$(sort -n <"$ord_log" | cut -d' ' -f2- | tr '\n' ',')"
  ord_printed="$(printf '%s\n' "$ord_out" | grep -xE 'ord [a-z]+' | tr '\n' ',')"
}
printf '%s\n' \
  "10	11	ord a" "30	31	ord b" "20	21	ord c" "20	22	ord d" \
  "99	99	a section that no longer exists" "not a line" "x	1	ord a" "5	ord a" "1	2" \
  >"$ord_file"
ord_run 2 '^ord '
assert_status "a longest-first run passes" "$ord_st" 0
assert_eq "starts the unlisted section first, then by wall seconds, ties in walk order" \
  "$ord_started" "ord unlisted,ord b,ord c,ord d,ord a,"
assert_eq "prints the sections in walk order whatever the start order" \
  "$ord_printed" "ord a,ord b,ord c,ord d,ord unlisted,"
ord_run 2 '^ord (a|b)$'
assert_eq "starts the sections a filter kept longest-first" "$ord_started" "ord b,ord a,"
assert_eq "and prints them in walk order" "$ord_printed" "ord a,ord b,"
ord_run 1 '^ord '
assert_eq "ORCH_TEST_JOBS=1 starts in walk order" "$ord_started" "ord a,ord b,ord c,ord d,ord unlisted,"
rm -f "$ord_file"
ord_run 2 '^ord '
assert_status "a run with no durations file passes" "$ord_st" 0
assert_eq "starts in walk order without the file" "$ord_started" "ord a,ord b,ord c,ord d,ord unlisted,"
assert_eq "and prints in walk order" "$ord_printed" "ord a,ord b,ord c,ord d,ord unlisted,"
rm -rf "$ord_dir"

# --- the shard setting (#2859) ------------------------------------------------
# A minimal test tree - the runners, setup.sh, a harness with an isolation
# section and five planted sections - over planted durations: CPU tenths 50,
# 40, 30 and 20 for s1 to s4, s5 unlisted (so it weighs 50), 70 for
# hooks_test.sh and 10 for shellcheck, which group 1 starts with. Two groups
# deal s2 and s4 to group 1, s1, s5 and s3 to group 2. Each planted section logs
# its process id and name as it starts; the runner starts its children one
# after another, so the log sorted by id is the start order.
echo
echo "the shard setting (#2859)"
sh_dir="$(mktemp -d)"
sh_t="$sh_dir/scripts/test"
mkdir -p "$sh_t/orch"
(cd "$(dirname "$SUITE_SCRIPT")" && cp "${ALL_RUNNER_FILES[@]}" orch_test.sh tally.sh \
  fifo.sh git_env.sh gh_adapter_fake.sh shell_code.awk "$sh_t/" && cp orch/setup.sh "$sh_t/orch/" && cp ../flow-state.sh "$sh_dir/scripts/")
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
for sh_s in "${SUITES[@]}"; do
  [ -e "$sh_t/$sh_s" ] || echo 'echo; echo "1 passed, 0 failed"' >"$sh_t/$sh_s"
done
printf '%s\n' '# --- isolation ---' 'echo; echo isolation; ok "isolation ran"' >"$sh_t/orch/harness.sh"
{
  for sh_n in 1 2 3 4 5; do
    echo "# --- shard s$sh_n"
    echo "echo \"\$\$ shard s$sh_n\" >>\"\$SH_LOG\"; echo; echo 'shard s$sh_n'; ok 's$sh_n ran'; echo \"\${ORCH_TEST_SHARD-unset}\" >>\"\$SH_SEEN\""
  done
} >"$sh_t/orch/zz-shard.sh"
printf '%s\n' "10	50	shard s1" "30	40	shard s2" "20	30	shard s3" "5	20	shard s4" \
  "9	70	hooks_test.sh" "9	10	shellcheck" "1	99	a section that no longer exists" \
  >"$sh_t/section-durations.tsv"
sh_log="$sh_dir/log"
sh_seen="$sh_dir/seen"
# sh_run <shard> [jobs] [hold]: orch_test.sh in the tree under that setting, s5
# holding for <hold> seconds (default 0); the
# shard-section names it ran (start order, then printed order), its status.
sh_run() {
  : >"$sh_log"; : >"$sh_seen"
  sh_out="$(SH_LOG="$sh_log" SH_SEEN="$sh_seen" ORCH_TEST_QUIET='' ORCH_TEST_ONLY='' ORCH_TEST_JOBS="${2:-2}" \
    ORCH_TEST_SHARD="$1" bash "$sh_t/orch_test.sh" 2>&1)"; sh_st=$?
  sh_started="$(sort -n <"$sh_log" | cut -d' ' -f2- | tr '\n' ',' | sed 's/shard //g')"
  sh_printed="$(printf '%s\n' "$sh_out" | grep -xE 'shard s[0-9]|isolation' | sed 's/shard //' | tr '\n' ',')"
}
sh_run 1/2
assert_status "group 1 of 2 passes" "$sh_st" 0
assert_eq "group 1 runs isolation and the sections the dealing gives it" "$sh_printed" "isolation,s2,s4,"
assert_eq "and starts them longest-first" "$sh_started" "s2,s4,"
sh_run 2/2
sh_first_22="$sh_printed"
assert_eq "group 2 gets the rest, the unlisted section weighing as the heaviest listed one" \
  "$sh_printed" "isolation,s1,s3,s5,"
assert_eq "its sections start with the unlisted one, then longest-first" "$sh_started" "s5,s3,s1,"
# A file that lists no planted section: each weighs 1 CPU second (10 tenths), so
# the 30 tenths of the shellcheck line put s4 in group 1, the rest in group 2.
cp "$sh_t/section-durations.tsv" "$sh_dir/durations.keep"
printf '%s\n' "9	30	shellcheck" >"$sh_t/section-durations.tsv"
sh_run 1/2
assert_eq "with no section listed, each weighs one CPU second" "$sh_printed" "isolation,s4,"
cp "$sh_dir/durations.keep" "$sh_t/section-durations.tsv"
declare -A sh_saved_printed sh_saved_st sh_saved_seen
for sh_n in 1 2 3 5 6 9; do
  sh_union=""
  for ((sh_i = 1; sh_i <= sh_n; sh_i++)); do
    sh_run "$sh_i/$sh_n"
    [ "$sh_st" -eq 0 ] || bad "group $sh_i of $sh_n passes" "$sh_out"
    [ "$(printf '%s' "$sh_printed" | grep -o isolation | wc -l)" -eq 1 ] ||
      bad "group $sh_i of $sh_n runs isolation once" "$sh_printed"
    sh_saved_printed["$sh_i/$sh_n"]="$sh_printed"; sh_saved_st["$sh_i/$sh_n"]="$sh_st"
    sh_saved_seen["$sh_i/$sh_n"]="$(sort -u "$sh_seen" | tr '\n' ',')"
    sh_union+="$(printf '%s' "$sh_printed" | sed 's/isolation,//')"
  done
  assert_eq "$sh_n groups run every planted section exactly once" \
    "$(printf '%s' "$sh_union" | tr ',' '\n' | grep . | sort | tr '\n' ',')" "s1,s2,s3,s4,s5,"
done
assert_eq "a second call groups the same" "${sh_saved_printed[2/2]}" "$sh_first_22"
assert_eq "a group left with isolation alone runs it alone" "${sh_saved_printed[9/9]}" "isolation,"
assert_eq "and passes" "${sh_saved_st[9/9]}" 0
assert_eq "1/1 runs every section" "${sh_saved_printed[1/1]}" "isolation,s1,s2,s3,s4,s5,"
assert_eq "and a section's nested runner sees no ORCH_TEST_SHARD" "${sh_saved_seen[1/1]}" "unset,"
sh_run ""
assert_eq "an empty value runs as unset" "$sh_printed" "isolation,s1,s2,s3,s4,s5,"
sh_run 1/2 1
assert_eq "ORCH_TEST_JOBS=1 runs a group in walk order" "$sh_printed" "isolation,s2,s4,"
for sh_bad in x 0/2 3/2 1/ /2 1/2/3 a/b -1/2 " 1/2"; do
  sh_run "$sh_bad"
  assert_status "ORCH_TEST_SHARD='$sh_bad' exits 1" "$sh_st" 1
  assert_eq "and says so before any section starts" "$sh_out
$(cat "$sh_log")" "orch_test.sh: ORCH_TEST_SHARD='$sh_bad' is not <i>/<n> with 1 <= i <= n
"
done
for sh_v in 1/1 1/2; do
  sh_out="$(SH_LOG="$sh_log" ORCH_TEST_SHARD="$sh_v" ORCH_TEST_ONLY='^shard s1$' bash "$sh_t/orch_test.sh" 2>&1)"; sh_st=$?
  assert_status "ORCH_TEST_SHARD=$sh_v with ORCH_TEST_ONLY exits 1" "$sh_st" 1
  assert_eq "and says they cannot both be set" "$sh_out" \
    "orch_test.sh: ORCH_TEST_SHARD and ORCH_TEST_ONLY cannot both be set"
done
sh_out="$(SH_LOG="$sh_log" SH_SEEN="$sh_seen" ORCH_TEST_SHARD="" ORCH_TEST_ONLY='^shard s1$' bash "$sh_t/orch_test.sh" 2>&1)"; sh_st=$?
assert_status "an empty ORCH_TEST_SHARD with ORCH_TEST_ONLY runs the filter" "$sh_st" 0
# all.sh: group 1 runs the other suites and shellcheck, a later group only
# orch_test.sh, and the setting reaches orch_test.sh alone.
sh_all_dir="$(mktemp -d)"
stub_all_tree "$sh_all_dir" "$sh_all_dir/sc.log"
for sh_s in "${SUITES[@]}"; do
  printf '#!/usr/bin/env bash\necho "%s shard=${ORCH_TEST_SHARD:-unset}" >>"$(dirname "$0")/log"\necho; echo "1 passed, 0 failed"\n' \
    "$sh_s" >"$sh_all_dir/scripts/test/$sh_s"
done
sh_all() {
  : >"$sh_all_dir/scripts/test/log"; : >"$sh_all_dir/sc.log"
  sh_out="$(cd "$sh_all_dir" && env -u CI PATH="$sh_all_dir/bin" ORCH_TEST_SHARD="$1" \
    bash scripts/test/all.sh 2>&1)"; sh_st=$?
}
sh_all 1/2
assert_status "all.sh in group 1 passes" "$sh_st" 0
assert_eq "group 1 runs every suite" "$(grep -c . "$sh_all_dir/scripts/test/log")" "${#SUITES[@]}"
assert_contains "orch_test.sh gets the setting" "$(cat "$sh_all_dir/scripts/test/log")" "orch_test.sh shard=1/2"
assert_contains "no other suite does" "$(cat "$sh_all_dir/scripts/test/log")" "hooks_test.sh shard=unset"
assert_eq "group 1 runs shellcheck" "$([ -s "$sh_all_dir/sc.log" ] && echo yes || echo no)" "yes"
assert_eq "and its verdict counts every part" "$(printf '%s\n' "$sh_out" | tail -n 1)" \
  "all.sh: PASS ($((${#SUITES[@]} + 1)) parts)"
sh_all 2/2
assert_status "all.sh in group 2 passes" "$sh_st" 0
assert_eq "group 2 runs orch_test.sh alone" "$(cat "$sh_all_dir/scripts/test/log")" "orch_test.sh shard=2/2"
assert_eq "and no shellcheck" "$([ -s "$sh_all_dir/sc.log" ] && echo yes || echo no)" "no"
assert_eq "its verdict counts only orch_test.sh" "$(printf '%s\n' "$sh_out" | tail -n 1)" \
  "all.sh: PASS (1 parts)"
sh_all 3/2
assert_status "all.sh refuses a malformed setting" "$sh_st" 1
assert_eq "with the runner's message and nothing run" "$sh_out
$(cat "$sh_all_dir/scripts/test/log")" "all.sh: ORCH_TEST_SHARD='3/2' is not <i>/<n> with 1 <= i <= n
"
sh_all ""
assert_eq "all.sh runs an empty setting as unset" "$(cat "$sh_all_dir/scripts/test/log" | grep -c 'shard=unset')" "${#SUITES[@]}"
rm -rf "$sh_all_dir" "$sh_dir"

# --- section durations (ORCH_TEST_DURATIONS, section-durations.sh, #2858) -----
# A copy of the scripts tree cut down to planted sections and stub suites, run
# at its command line: orch_test.sh with ORCH_TEST_DURATIONS, then the dev
# script over the same tree with a stub shellcheck first on PATH.
echo
echo "section durations (#2858)"
dur_dir="$(planted_copy <<'PLANTED'
  # --- dur a
  echo; echo "dur a"; echo "dur=${ORCH_TEST_DURATIONS-unset}"; ok "a ran"
  # --- dur b
  echo; echo "dur b"; sleep 0.3; ok "b ran"
PLANTED
)"
dur_orch="$dur_dir/scripts/test/orch"
find "$dur_orch" -name "*.sh" ! -name setup.sh ! -name zz-planted.sh -delete
printf '%s\n' '# --- isolation' 'echo; echo isolation; ok "isolation ran"' >"$dur_orch/harness.sh"
dur_out="$dur_dir/out.tsv"
# dur_run <jobs> [<file>]: orch_test.sh over the planted tree, parallel by
# default, writing durations to <file> (default $dur_out).
dur_run() {
  env -u ORCH_TEST_ONLY -u ORCH_TEST_SHARD ORCH_TEST_QUIET='' ORCH_TEST_JOBS="$1" ORCH_TEST_DURATIONS="${2-$dur_out}" \
    bash "$dur_dir/scripts/test/orch_test.sh" 2>&1
}
# dur_plant_failing: one planted section that fails, in zzz-failing.sh.
dur_plant_failing() {
  printf '%s\n' '  # --- dur fails' \
    '  echo; echo "dur fails"; bad "dur fails" "planted"' |
    plant_file "$dur_orch" zzz-failing.sh
}
printf 'stale line\n' >"$dur_out"
out="$(dur_run 2)"; st=$?
assert_status "a parallel run with a durations file passes" "$st" 0
assert_eq "it writes one line per section, in walk order, after emptying the file" \
  "$(cut -f3 "$dur_out" | tr '\n' ',')" "isolation,dur a,dur b,"
assert_eq "each line holds wall and CPU in tenths, then the title" \
  "$(grep -cE '^[0-9]+	[0-9]+	.' "$dur_out")" "3"
assert_eq "the wall of a 0.3 second section is at least 3 tenths" \
  "$(awk -F'\t' '$3 == "dur b" && $1 >= 3 { print "yes" }' "$dur_out")" "yes"
assert_contains "a section never sees the setting" "$out" "dur=unset"
dur_plant_failing
out="$(dur_run 2)"; st=$?
assert_status "a failing section fails the run" "$st" 1
assert_eq "and still writes its line" \
  "$(cut -f3 "$dur_out" | tr '\n' ',')" "isolation,dur a,dur b,dur fails,"
rm -f "$dur_orch/zzz-failing.sh"
printf 'stale\n' >"$dur_out"
out="$(dur_run 1)"; st=$?
assert_status "a sequential run passes" "$st" 0
assert_eq "and ignores the setting, leaving the file alone" "$(<"$dur_out")" "stale"
out="$(dur_run 2 "$dur_dir/no-such-dir/x.tsv")"; st=$?
assert_status "an unwritable durations file is refused" "$st" 1
assert_eq "naming the file" "$out" \
  "orch_test.sh: ORCH_TEST_DURATIONS='$dur_dir/no-such-dir/x.tsv' is not writable"

# The dev script, over the same tree: stub suites and a stub shellcheck.
dur_tool="$dur_dir/bin"
mkdir -p "$dur_tool"
printf '#!/usr/bin/env bash\nexit 0\n' >"$dur_tool/shellcheck"
chmod +x "$dur_tool/shellcheck"
dur_test="$dur_dir/scripts/test"
# dur_stub_passing <name>: a stub suite in the test dir that passes.
dur_stub_passing() {
  printf '#!/usr/bin/env bash\necho; echo "1 passed, 0 failed"\n' >"$dur_test/$1"
}
sed -i 's/^suites=(.*)$/suites=(orch_test.sh stub_a.sh stub_b.sh)/' "$dur_test/all.sh"
dur_stub_passing stub_a.sh
dur_stub_passing stub_b.sh
dur_file="$dur_test/section-durations.tsv"
# dur_script [<env assignment>...]: the dev script with a stub shellcheck on
# PATH, stdout and stderr together.
dur_script() {
  env PATH="$dur_tool:$PATH" ORCH_TEST_JOBS=2 "$@" bash "$dur_dir/scripts/dev/section-durations.sh" 2>&1
}
printf 'old\n' >"$dur_file"
out="$(dur_script ORCH_TEST_ONLY='^dur a$' ORCH_TEST_SHARD=2/2)"; st=$?
assert_status "the script passes on a passing tree, ORCH_TEST_ONLY and ORCH_TEST_SHARD set" "$st" 0
assert_eq "it writes the sections in walk order, then the suites, then shellcheck" \
  "$(cut -f3 "$dur_file" | tr '\n' ',')" "isolation,dur a,dur b,stub_a.sh,stub_b.sh,shellcheck,"
assert_eq "every line is two numbers in tenths and a name" \
  "$(grep -cE '^[0-9]+	[0-9]+	.' "$dur_file")" "6"
cp "$dur_file" "$dur_dir/good.tsv"
out="$(dur_script ORCH_TEST_JOBS=1)"; st=$?
assert_status "the script refuses ORCH_TEST_JOBS=1" "$st" 1
assert_contains "naming the setting" "$out" "ORCH_TEST_JOBS=1"
assert_eq "and leaves the file unchanged" "$(<"$dur_file")" "$(<"$dur_dir/good.tsv")"
dur_plant_failing
out="$(dur_script)"; st=$?
assert_status "a failing section fails the script" "$st" 1
assert_contains "naming what failed" "$out" "orch_test.sh"
assert_eq "and leaves the file unchanged" "$(<"$dur_file")" "$(<"$dur_dir/good.tsv")"
rm -f "$dur_orch/zzz-failing.sh"
printf '#!/usr/bin/env bash\necho; echo "  FAIL x"; echo "0 passed, 1 failed"; exit 1\n' >"$dur_test/stub_b.sh"
out="$(dur_script)"; st=$?
assert_status "a failing other suite fails the script" "$st" 1
assert_contains "naming it" "$out" "stub_b.sh"
assert_eq "and leaves the file unchanged" "$(<"$dur_file")" "$(<"$dur_dir/good.tsv")"
dur_stub_passing stub_b.sh
printf '#!/usr/bin/env bash\necho "a.sh:1:1: warning: planted"; exit 1\n' >"$dur_tool/shellcheck"
out="$(dur_script)"; st=$?
assert_status "a failing shellcheck step fails the script" "$st" 1
assert_contains "naming it" "$out" "shellcheck"
assert_eq "and leaves the file unchanged" "$(<"$dur_file")" "$(<"$dur_dir/good.tsv")"
rm -rf "$dur_dir"

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

# --- the standalone suites' tally (#1904) -------------------------------------
# A tiny standalone suite sourcing tally.sh the way the hooks, docs lint,
# version bump, lens bench and autopilot suites do, with one failing assertion
# in ( ... ) and one passing outside it, counts both and exits non-zero. A
# structural check then holds the suites to the shared tally: no suite defines
# an ok, bad or skip of its own (all seven, setup.sh included for orch_test.sh);
# orch_test.sh alone is checked for sourcing tally.sh and calling tally_read,
# as the quiet-mode run proves both for the six standalone suites.
echo
echo "the standalone suites' tally (#1904)"
tally_dir="$(mktemp -d)"
cat >"$tally_dir/suite.sh" <<SUITE
source "$(dirname "$SUITE_SCRIPT")/tally.sh"
tally_init
( bad "a failure in a subshell" "its detail line" )
ok "a pass outside it"
tally_summary
SUITE
out="$(ORCH_TEST_QUIET=1 bash "$tally_dir/suite.sh" 2>&1)"; st=$?
assert_status "a standalone suite with a subshell failure exits 1" "$st" 1
assert_eq "and counts the subshell failure in its summary" \
  "$(printf '%s\n' "$out" | tail -n 1)" "1 passed, 1 failed"
assert_eq "after a blank line" "$(printf '%s\n' "$out" | tail -n 2 | awk -v n=1 'NR<=n')" ""
sed -i '/^( bad /d' "$tally_dir/suite.sh"
out="$(ORCH_TEST_QUIET=1 bash "$tally_dir/suite.sh" 2>&1)"; st=$?
assert_status "a passing standalone suite exits 0" "$st" 0
assert_eq "and reports no failure" "$(printf '%s\n' "$out" | tail -n 1)" "1 passed, 0 failed"
sed -i 's/^tally_summary$/rm -f "$tally_file"\ntally_summary/' "$tally_dir/suite.sh"
out="$(ORCH_TEST_QUIET=1 bash "$tally_dir/suite.sh" 2>&1)"; st=$?
assert_status "a standalone suite whose tally file is gone exits 1" "$st" 1
assert_eq "and reports it as a failure" "$(printf '%s\n' "$out" | tail -n 1)" "0 passed, 1 failed"
# print_labelled indents every line of a detail; print_fail, bad() and skip()
# print through it.
cat >"$tally_dir/fail.sh" <<SUITE
source "$(dirname "$SUITE_SCRIPT")/tally.sh"
tally_init
print_fail "many lines" "first
second

fourth"
bad "bad many" "alpha
beta"
skip "skip many" "why

last"
tally_read
echo "recorded \$FAIL"
SUITE
out="$(bash "$tally_dir/fail.sh" 2>&1)"
assert_eq "and indents every line of a multi-line detail, an empty one included" \
  "$(printf '%s\n' "$out" | sed -n 1,5p)" "$(printf '  FAIL many lines\n     first\n     second\n     \n     fourth')"
assert_eq "bad() indents a multi-line detail the same way" \
  "$(printf '%s\n' "$out" | sed -n 6,8p)" "$(printf '  FAIL bad many\n     alpha\n     beta')"
assert_eq "skip() indents every line of a multi-line reason, an empty one included" \
  "$(printf '%s\n' "$out" | sed -n 9,12p)" "$(printf '  skip skip many\n     why\n     \n     last')"
assert_eq "and records exactly one failure" "$(printf '%s\n' "$out" | tail -n 1)" "recorded 1"
rm -rf "$tally_dir"
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
for tally_suite in "${SUITES[@]}"; do
  tally_path="$(dirname "$SUITE_SCRIPT")/$tally_suite"
  tally_files=("$tally_path")
  if [ "$tally_suite" = orch_test.sh ]; then
    setup_path="$(dirname "$SUITE_SCRIPT")/orch/setup.sh"
    assert_contains "$tally_suite sources tally.sh" "$(<"$tally_path")" "tally.sh\""
    # orch_test.sh reads the tally in setup.sh's summary, and its assertions
    # once lived in setup.sh too.
    assert_contains "$tally_suite calls tally_read" "$(<"$setup_path")" "tally_read"
    tally_files+=("$setup_path")
  fi
  assert_eq "$tally_suite defines no ok, bad or skip of its own" \
    "$(cat "${tally_files[@]}" | grep -cE '^(ok|bad|skip) *\(\)')" "0"
done

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
if files_locale="$(dictionary_locale)"; then
  out="$(LC_ALL="$files_locale" ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^no such section$' \
    bash "$files_suite" 2>/dev/null)"
  assert_eq "keeps LC_ALL=C order under a dictionary locale" \
    "$(printf '%s\n' "$out" | sed -n 2,3p | tr '\n' ',')" "planted underscore,planted a,"
else
  skip "keeps LC_ALL=C order under a dictionary locale" "no dictionary locale here"
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
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
root_dir="$(planted_copy <<'PLANTED'
  # --- planted repo
  echo; echo "planted repo"; new_repo >/dev/null; ok "made a repo"
  # --- planted failure
  echo; echo "planted failure"; new_repo >/dev/null; bad "a planted failure" "its detail line"
  # --- planted wait
  echo; echo "planted wait"; new_repo >/dev/null; : >"$ROOT_TEST_MARKER"; sleep 30 & wait $!
  ok "waited"
  # --- planted late write
  echo; echo "planted late write"; new_repo >/dev/null
  late="$(bash -c ': >"$ROOT_TEST_MARKER"; sleep 0.5; mkdir -p "$TMPDIR/late"')"
  ok "wrote late$late"
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

  # planted late write is sent TERM inside a command substitution whose process
  # writes into TMPDIR half a second later: the run must stop it before it
  # removes its root, so the check waits past that write.
  for root_section in wait 'late write'; do
    root_fresh
    TMPDIR="$root_tmp" ROOT_TEST_MARKER="$root_marker" ORCH_TEST_JOBS="$root_jobs" \
      ORCH_TEST_ONLY="^planted $root_section\$" bash "$root_suite" >/dev/null 2>&1 &
    root_pid=$!
    if root_await_marker; then
      kill -TERM "$root_pid"
    else
      kill -KILL "$root_pid" 2>/dev/null
    fi
    wait "$root_pid"; st=$?
    [ "$root_section" = wait ] || sleep 1
    assert_status "a run with ORCH_TEST_JOBS=$root_jobs sent TERM in planted $root_section exits 130" \
      "$st" 130
    assert_eq "a run with ORCH_TEST_JOBS=$root_jobs sent TERM in planted $root_section leaves its TMPDIR empty" \
      "$(ls -A "$root_tmp")" ""
  done
done

# A host with no ps (the container image installs none) still lists what is
# left running, from /proc: a shell with awk and sleep alone on PATH, and one
# sleeping child.
if [ -r "/proc/$$/stat" ]; then
  mkdir "$root_dir/nops"
  ln -s "$(command -v awk)" "$root_dir/nops/awk"
  ln -s "$(command -v sleep)" "$root_dir/nops/sleep"
  out="$(PATH="$root_dir/nops" "$BASH" -c 'source "$1"; sleep 30 & echo "$!"
    test_jobs_descendants; kill "$!"' _ "$(dirname "$SUITE_SCRIPT")/test_jobs.sh" 2>&1)"
  assert_eq "with no ps on PATH, test_jobs_descendants lists the child from /proc" \
    "$(printf '%s\n' "$out" | sed -n 2p)" "$(printf '%s\n' "$out" | sed -n 1p)"
else
  skip "with no ps on PATH, test_jobs_descendants lists the child from /proc" "no /proc here"
fi

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
(cd "$(dirname "$SUITE_SCRIPT")" && cp "${ALL_RUNNER_FILES[@]}" "$root_all/scripts/test/")
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
  "12 passed, 1 failed"
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
suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
all_root="$(mktemp -d)"
all_dir="$all_root/scripts/test"
all_bin="$all_root/bin"
mkdir -p "$all_dir/orch" "$all_bin"
(cd "$(dirname "$SUITE_SCRIPT")" && cp "${ALL_RUNNER_FILES[@]}" "$all_dir/")
for all_tool in bash dirname awk tail mktemp rm mkdir sleep; do
  ln -s "$(command -v "$all_tool")" "$all_bin/$all_tool"
done
# all_written: every shell file the fixture writes, by path from <tmp>, for
# the expected shellcheck arguments - never a glob.
all_written=("${ALL_RUNNER_FILES[@]/#/scripts/test/}")
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
  printf '%s\n' "$1" | grep -E '^([a-z_]+\.sh|shellcheck): ' | grep -v '^all\.sh: ' | cut -d: -f1 | tr '\n' ' '
}
# The suite-list reader over the real all.sh, then over planted copies: one
# with no suites=( line, one with two, one with an empty list, one naming a
# suite with no file in scripts/test/.
all_real="$(dirname "$SUITE_SCRIPT")/all.sh"
suites_read "$all_real" "$(dirname "$SUITE_SCRIPT")"; st=$?
assert_status "the reader succeeds over the real all.sh" "$st" 0
for all_case in none two empty missing; do
  case "$all_case" in
    none) all_text='suites_list=(a.sh)' ;;
    two) all_text="$(printf 'suites=(orch_test.sh)\nsuites=(hooks_test.sh)')" ;;
    empty) all_text='suites=()' ;;
    missing) all_text='suites=(orch_test.sh no_such_suite.sh)' ;;
  esac
  printf '%s\n' "$all_text" >"$all_root/planted_all.sh"
  suites_read "$all_root/planted_all.sh" "$(dirname "$SUITE_SCRIPT")"; st=$?
  assert_status "the reader fails over an all.sh with $all_case" "$st" 1
  assert_contains "and names the problem ($all_case)" "$SUITES_ERR" "$all_root/planted_all.sh"
  assert_not_contains "with no orch: prefix ($all_case)" "$SUITES_ERR" "orch: "
done
suites_read "$all_real" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
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
assert_eq "runs every suite after the first one fails" "$(log_count "$all_dir/log")" "$all_n"
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
  "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)" "shellcheck: 0 findings"
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
  "$(log_count "$all_root/sc_args")" "${#all_written[@]}"
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
  "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)" "shellcheck: 0 findings"
assert_eq "an all-pass run ends on a PASS verdict counting the suites and shellcheck" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: PASS ($((all_n + 1)) parts)"

rm -f "$all_dir/log"
all_sc_stub 1 "$all_finding1" "$all_finding2"
out="$(export CHANGELOG_BASE=abc123 NO_VERSION_BUMP=1; all_run 2>&1)"; st=$?
assert_eq "leaves an unset CHANGELOG_BASE unset" "$(grep -c 'base=unset ' "$all_dir/log")" "$all_n"
assert_eq "leaves an unset NO_VERSION_BUMP unset" "$(grep -c 'nobump=unset$' "$all_dir/log")" "$all_n"
assert_eq "prints no FAIL line when every suite passed" "$(count_lines '^  FAIL ' "$out")" "0"
assert_status "exits non-zero on a shellcheck finding" "$st" 1
assert_contains "prints each finding, then shellcheck: N findings" "$out" \
  "$(printf '%s\n%s\nshellcheck: 2 findings' "$all_finding1" "$all_finding2")"
assert_eq "shellcheck findings end the run on a FAIL verdict naming shellcheck" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (shellcheck)"
assert_eq "a finding still lets every suite's summary print first" \
  "$(printf '%s\n' "$out" | grep -E '^[a-z_]+\.sh: ' | grep -v '^all\.sh: ')" \
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
assert_eq "a shellcheck that fails with no finding line is named in the FAIL verdict" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (shellcheck)"
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
assert_eq "a suite that printed FAIL lines but exited 0 is named in the FAIL verdict" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (orch_test.sh)"

# A suite that exits non-zero after printing a valid summary line still fails
# the run: the verdict needs no raw-exit flag.
all_swap orch_test.sh "trap 'exit 1' EXIT"
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
assert_status "exits non-zero when a suite exits non-zero after a valid summary" "$st" 1
assert_eq "a suite that exits non-zero after a valid summary is named in the FAIL verdict" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (orch_test.sh)"

# Leftover temp files and shellcheck findings together: both are named, in
# the order their messages print.
all_sc_stub 1 "$all_finding1"
all_swap hooks_test.sh ': >"$TMPDIR/left_behind"'
out="$(all_run 2>&1)"; st=$?
all_restore hooks_test.sh
all_sc_stub 0
assert_status "leftover temp files and a shellcheck finding fail the run" "$st" 1
assert_eq "leftover temp files and shellcheck findings end exactly on both names" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (temp files, shellcheck)"

all_swap orch_test.sh 'sleep 1' 'echo; echo "a section header"' \
  "printf '  FAIL a slow failure\\n     its detail line\\n'" \
  'echo; echo "1 passed, 1 failed"; exit 1'
out="$(all_run 2>&1)"; st=$?
all_restore orch_test.sh
assert_status "a slow failing suite still fails the run" "$st" 1
assert_eq "a slow orch_test.sh's FAIL block and summary still print first, shellcheck's summary last" \
  "$out" \
  "$(printf '  FAIL a slow failure\n     its detail line\n%s\nshellcheck: 0 findings\nall.sh: FAIL (orch_test.sh)' "$(all_summaries '1 passed, 1 failed')")"

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
assert_eq "prints no FAIL line when the suites overlap" "$(count_lines '^  FAIL ' "$out")" "0"
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
) >"$all_kill/stdout" 2>&1 &
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
assert_eq "TERM to all.sh prints no verdict" "$(grep -c '^all.sh: \(PASS\|FAIL\)' "$all_kill/stdout")" "0"
assert_eq "TERM to all.sh stops the suite and every shellcheck before it returns" "$all_alive" "0"
assert_eq "the suite's TMPDIR still existed when it stopped" "$(cat "$all_kill/suite.tmp" 2>/dev/null)" "yes"
assert_eq "all.sh's temp directory still existed when every shellcheck stopped" \
  "$(sort -u "$all_kill/sc.tmp" 2>/dev/null)" "yes"
assert_eq "removes its temp directory after stopping the children" "$(ls -A "$all_kill/tmp")" ""
all_sc_stub 0

rm -f "$all_bin/shellcheck" "$all_bin/shellcheck.bak"
out="$(export CI=true; all_run 2>&1)"; st=$?
assert_eq "says shellcheck was skipped when it is not installed" \
  "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)" "shellcheck: not installed - skipped"
assert_eq "a missing shellcheck outside CI ends on a PASS verdict counting the skipped line" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: PASS ($((all_n + 1)) parts)"
assert_status "a missing shellcheck does not fail the run outside CI" "$st" 0
out="$(all_run CI=true 2>&1)"; st=$?
assert_status "a missing shellcheck fails the run in CI" "$st" 1
assert_eq "still says shellcheck was skipped in CI" \
  "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)" "shellcheck: not installed - skipped"
assert_eq "a missing shellcheck in CI ends on a FAIL verdict naming shellcheck" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (shellcheck)"

# A suite that dies before its summary (#626): orch_test.sh's stub fails
# after a FAIL line and ends on a line that is no summary, hooks_test.sh's
# prints nothing, and docs_lint.sh exits 0 on a stray last line (#2260). Last,
# so the stubs are overwritten outright and never restored.
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
assert_contains "says a suite that exited 0 on a non-summary last line died before its summary" "$out" \
  "docs_lint.sh: died before its summary (exit 0)"
assert_eq "suites that died before their summary are named in the FAIL verdict" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (orch_test.sh, hooks_test.sh, docs_lint.sh)"
# A header then a summary line passes: the last line is read, not any line.
printf '%s\n' '#!/usr/bin/env bash' 'echo "a section header"' 'echo; echo "3 passed, 0 failed"' \
  >"$all_dir/docs_lint.sh"
out="$(all_run 2>&1)"
assert_contains "a suite with a header then a summary line passes" "$out" \
  "docs_lint.sh: 3 passed, 0 failed"
assert_not_contains "and is not said to have died" "$out" "docs_lint.sh: died"
assert_eq "and is left out of the FAIL verdict" \
  "$(printf '%s\n' "$out" | tail -n 1)" "all.sh: FAIL (orch_test.sh, hooks_test.sh)"
rm -rf "$all_root"

# --- all.sh's suite list holds every runner (#1941) ---------------------------
# A runner is a top-level scripts/test/*.sh with a line that sources tally.sh.
# suites_unlisted prints one orch: line per runner the suites=( list leaves out.
ul_root="$(mktemp -d)"
printf '%s\n' 'suites=(listed_test.sh)' >"$ul_root/all.sh"
mkdir "$ul_root/sub"
plant_file "$ul_root" listed_test.sh <<'PLANTED'
  source "$DIR/test/tally.sh"
PLANTED
plant_file "$ul_root" b_unlisted.sh <<'PLANTED'
  . "$DIR/test/tally.sh"
PLANTED
plant_file "$ul_root" a_unlisted.sh <<'PLANTED'
  source "$DIR/test/tally.sh"
PLANTED
plant_file "$ul_root" helper.sh <<'PLANTED'
  echo "a fake, not a runner"
PLANTED
plant_file "$ul_root" mention.sh <<'PLANTED'
  # shellcheck source=tally.sh
  # source "$DIR/test/tally.sh"
  echo "see tally.sh"
PLANTED
plant_file "$ul_root/sub" deep.sh <<'PLANTED'
  source "$DIR/test/tally.sh"
PLANTED
ul_out="$(suites_unlisted "$ul_root/all.sh" "$ul_root")"; st=$?
assert_status "the planted tree reads" "$st" 0
assert_eq "an unlisted runner is named, in name order, and nothing else is" "$ul_out" \
  "$(printf '%s\n' "orch: scripts/test/a_unlisted.sh sources tally.sh but is not in all.sh's suites list" \
    "orch: scripts/test/b_unlisted.sh sources tally.sh but is not in all.sh's suites list")"
printf '%s\n' 'suites_list=(listed_test.sh)' >"$ul_root/all.sh"
ul_out="$(suites_unlisted "$ul_root/all.sh" "$ul_root")"; st=$?
assert_status "an all.sh with no suites=( line returns 1" "$st" 1
assert_eq "and prints nothing" "$ul_out" ""
suites_unlisted "$ul_root/all.sh" "$ul_root" >/dev/null
assert_contains "and sets SUITES_ERR" "$SUITES_ERR" "$ul_root/all.sh"
rm -rf "$ul_root"
ul_dir="$(dirname "$SUITE_SCRIPT")"
ul_out="$(suites_unlisted "$ul_dir/all.sh" "$ul_dir")"; st=$?
assert_status "the real test directory reads" "$st" 0
assert_eq "the real test directory has no unlisted runner" "$ul_out" ""

# --- the job pool (#2022) -----------------------------------------------------
# The runners' shared job pool, test-only ORCH_TEST_POOL_DIR naming the pool
# directory and ORCH_TEST_CPU_MAX_FILE sizing it (a quota of 200000 per slot:
# 50% of the usable CPUs are the slots, set with ORCH_TEST_POOL_PERCENT=50). A
# copy of the scripts tree with planted
# sections that log their start and end, run by orch_test.sh; then all.sh over
# a stub shellcheck that logs the same way.
echo
echo "the job pool (#2022)"
jp_dir="$(mktemp -d)"
jp_tests="$(dirname "$SUITE_SCRIPT")"
jp_log="$jp_dir/log"
jp_copy="$(planted_copy <<'PLANTED'
  # With JP_BARRIER set, a pool section waits, up to 10s, until that many
  # sections have started, so a peak needs no luck in start-up timing.
  pool_barrier() {
    local i=0
    while [ -n "${JP_BARRIER:-}" ] && [ "$(grep -c '^+' "$JP_LOG")" -lt "$JP_BARRIER" ] &&
      [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
  }
  # --- pool a
  echo; echo "pool a"; echo + >>"$JP_LOG"; pool_barrier; sleep 0.6; echo - >>"$JP_LOG"; ok "ran a"
  # --- pool b
  echo; echo "pool b"; echo + >>"$JP_LOG"; pool_barrier; sleep 0.6; echo - >>"$JP_LOG"; ok "ran b"
  # --- pool c
  echo; echo "pool c"; echo + >>"$JP_LOG"; pool_barrier; sleep 0.6; echo - >>"$JP_LOG"; ok "ran c"
  # --- pool d
  echo; echo "pool d"; echo + >>"$JP_LOG"; pool_barrier; sleep 0.6; echo - >>"$JP_LOG"; ok "ran d"
  # --- pool hold
  echo; echo "pool hold"
  if flock -n "$JP_POOL/slot.1" true; then echo free >>"$JP_LOG"; else echo busy >>"$JP_LOG"; fi
  ok "probed"
  # --- pool leak
  echo; echo "pool leak"
  sleep 30 >/dev/null 2>&1 & echo $! >"$JP_LOG.sleep"
  ok "left a background process running"
  # --- pool nested
  echo; echo "pool nested"
  timeout 60 env ORCH_TEST_JOBS=2 ORCH_TEST_ONLY='^pool a$' bash "$JP_SUITE" >/dev/null 2>&1
  echo "nested=$?" >>"$JP_LOG"; ok "nested"
PLANTED
)"
jp_suite="$jp_copy/scripts/test/orch_test.sh"
pool_cpu_file "$jp_dir/cpu2" 2
pool_cpu_file "$jp_dir/cpu1" 1
pool_cpu_file "$jp_dir/cpu4" 4
# jp_run <slots> <pool dir> [VAR=value...] -- <ORCH_TEST_ONLY> <jobs>: the
# planted suite on a pool of <slots> slots, its stderr in $jp_dir/err.
jp_run() {
  local slots="$1" pool="$2" extra=()
  shift 2
  while [ "$1" != -- ]; do extra+=("$1"); shift; done
  env -u CI ORCH_TEST_POOL_PERCENT=50 ORCH_TEST_CPU_MAX_FILE="$jp_dir/cpu$slots" ORCH_TEST_POOL_DIR="$pool" \
    JP_LOG="$jp_log" JP_POOL="$pool" JP_SUITE="$jp_suite" ORCH_TEST_QUIET=1 \
    ORCH_TEST_ONLY="$2" ORCH_TEST_JOBS="$3" "${extra[@]}" bash "$jp_suite" >/dev/null 2>"${jp_err:-$jp_dir/err}"
}
jp_notice='waiting for a job slot'

if command -v flock >/dev/null 2>&1; then
# Two concurrent runs on a 2-slot pool.
: >"$jp_log"
jp_err="$jp_dir/erra" jp_run 2 "$jp_dir/pool1" JP_BARRIER=2 -- '^pool [a-d]$' 4 &
jp_p1=$!
jp_err="$jp_dir/errb" jp_run 2 "$jp_dir/pool1" JP_BARRIER=2 -- '^pool [a-d]$' 4 &
jp_p2=$!
jp_err_b="$jp_dir/errb"
wait "$jp_p1"; jp_s1=$?
wait "$jp_p2"; jp_s2=$?
assert_status "the first of two concurrent runs passes" "$jp_s1" 0
assert_status "the second of two concurrent runs passes" "$jp_s2" 0
assert_eq "two concurrent runs on a 2-slot pool never exceed 2 sections at once" "$(log_peak "$jp_log")" "2"
assert_eq "both runs ran all their sections" "$(grep -c '^+' "$jp_log")" "8"
assert_eq "the waiting notice appears once in a run that waits" \
  "$(grep -c "$jp_notice" "$jp_err_b")" "1"
assert_contains "the notice names the runner and the slots in use" "$(cat "$jp_err_b")" \
  "orch_test.sh: waiting for a job slot (2 in use)"

# A killed holder's slot is freed.
rm -rf "$jp_dir/pool2"
slot_hold "$jp_dir/pool2" 1 || bad "holds the slot"
: >"$jp_log"
jp_run 1 "$jp_dir/pool2" -- '^pool a$' 2 &
jp_p1=$!
notice_wait "$jp_dir/err"
assert_eq "a run on a pool whose one slot is held waits" \
  "$(grep -c "$jp_notice" "$jp_dir/err")" "1"
assert_eq "and runs nothing while the slot is held" "$(grep -c '^+' "$jp_log")" "0"
slot_release
wait "$jp_p1"; jp_s1=$?
assert_status "the run finishes once the holder is killed" "$jp_s1" 0
assert_eq "and ran its section" "$(grep -c '^+' "$jp_log")" "1"

# CI bypasses the pool.
slot_hold "$jp_dir/pool2" 1 || bad "holds the slot"
: >"$jp_log"
jp_run 1 "$jp_dir/pool2" CI=true -- '^pool a$' 2; jp_s1=$?
assert_status "a run under CI ignores a fully held pool" "$jp_s1" 0
assert_eq "and prints no waiting notice" "$(grep -c "$jp_notice" "$jp_dir/err")" "0"
slot_release

# Another HOME has its own pool.
mkdir "$jp_dir/home1" "$jp_dir/home2"
slot_hold "$jp_dir/home1/.cache/orchestrator/test-job-pool" 1 || bad "holds the slot"
: >"$jp_log"
timeout 30 env -u CI -u ORCH_TEST_POOL_DIR -u ORCH_TEST_POOL_PERCENT HOME="$jp_dir/home2" \
  ORCH_TEST_CPU_MAX_FILE="$jp_dir/cpu2" \
  JP_LOG="$jp_log" ORCH_TEST_QUIET=1 ORCH_TEST_ONLY='^pool a$' ORCH_TEST_JOBS=2 \
  bash "$jp_suite" >/dev/null 2>"$jp_dir/err"; jp_s1=$?
assert_status "a run under another HOME passes while the first HOME's slot is held" "$jp_s1" 0
assert_eq "and prints no waiting notice" "$(grep -c "$jp_notice" "$jp_dir/err")" "0"
assert_eq "and has drawn its slot from its own pool" \
  "$(on_disk "$jp_dir/home2/.cache/orchestrator/test-job-pool/slot.1")" "present"
slot_release

# slot_hold fails on a slot it cannot lock: the slot path is a directory.
mkdir -p "$jp_dir/pool11/slot.1"
jp_t0=$SECONDS
slot_hold "$jp_dir/pool11" 1 2>/dev/null; jp_s1=$?
assert_status "slot_hold returns 1 on a slot path it cannot lock" "$jp_s1" 1
# A read that timed out would also return 1, after 10s: the EOF path is quicker.
assert_eq "and returns on the holder's EOF, well within its read timeout" \
  "$(( SECONDS - jp_t0 < 5 ))" "1"
slot_release

# A released holder no longer runs and no longer holds the lock.
slot_hold "$jp_dir/pool13" 1 || bad "holds the slot"
slot_release
kill -0 "$SLOT_HOLDER" 2>/dev/null; jp_s1=$?
assert_status "a released holder is no longer running" "$jp_s1" 1
flock -n "$jp_dir/pool13/slot.1" true; jp_s1=$?
assert_status "and its slot's lock is free" "$jp_s1" 0

# ORCH_TEST_JOBS caps the ask, and does not bypass the pool.
: >"$jp_log"
jp_run 4 "$jp_dir/pool4" JP_BARRIER=2 -- '^pool [a-d]$' 2
assert_eq "ORCH_TEST_JOBS=2 on a 4-slot pool runs 2 sections at once" "$(log_peak "$jp_log")" "2"

# ORCH_TEST_POOL_PERCENT sizes the pool: 200% of 2 CPUs holds 4. The percent
# arithmetic itself is the CPU load section's, through test_jobs_default.
: >"$jp_log"
jp_run 1 "$jp_dir/pool12" ORCH_TEST_POOL_PERCENT=200 JP_BARRIER=4 -- '^pool [a-d]$' 4
assert_eq "ORCH_TEST_POOL_PERCENT=200 on 2 CPUs holds 4 slots" "$(log_peak "$jp_log")" "4"

# ORCH_TEST_JOBS=1 holds one slot for the whole run, in one shell.
: >"$jp_log"
jp_run 1 "$jp_dir/pool5" -- '^pool hold$' 1
assert_eq "ORCH_TEST_JOBS=1 holds a slot while its section runs" "$(cat "$jp_log")" "busy"

# A nested run takes no slot of the same pool, so it finishes on a 1-slot pool.
for jp_jobs in 1 2; do
  : >"$jp_log"
  jp_run 1 "$jp_dir/pool6" -- '^pool nested$' "$jp_jobs"; jp_s1=$?
  assert_status "an outer run with ORCH_TEST_JOBS=$jp_jobs passes" "$jp_s1" 0
  assert_eq "its nested run on the 1-slot pool finishes (ORCH_TEST_JOBS=$jp_jobs)" \
    "$(grep nested "$jp_log")" "nested=0"
done

# A slot is free once its section has exited, though a process it started
# still runs: the lock stays with the job alone.
for jp_jobs in 1 2; do
  : >"$jp_log"
  jp_run 1 "$jp_dir/pool10" -- '^pool leak$' "$jp_jobs"
  jp_sleeper="$(cat "$jp_log.sleep" 2>/dev/null)"
  jp_free=busy
  for _ in $(seq 60); do
    flock -n "$jp_dir/pool10/slot.1" true && { jp_free=free; break; }
    sleep 0.05
  done
  assert_eq "a slot is free after its section exited though a background process runs (ORCH_TEST_JOBS=$jp_jobs)" \
    "$jp_free" "free"
  [ -z "$jp_sleeper" ] || kill "$jp_sleeper" 2>/dev/null
done

# Pool trouble runs unpooled, with no notice and no failure.
: >"$jp_log"
jp_run 1 /proc/no/such/pool -- '^pool a$' 2; jp_s1=$?
assert_status "an uncreatable pool directory runs unpooled and passes" "$jp_s1" 0
assert_eq "and ran its section" "$(grep -c '^+' "$jp_log")" "1"
mkdir -p "$jp_dir/pool7/slot.1"
jp_run 1 "$jp_dir/pool7" -- '^pool a$' 2; jp_s1=$?
assert_status "a slot file that cannot be opened runs unpooled and passes" "$jp_s1" 0
assert_eq "without a waiting notice" "$(grep -c "$jp_notice" "$jp_dir/err")" "0"
mkdir "$jp_dir/noflock"
printf '#!/bin/sh\nexit 1\n' >"$jp_dir/noflock/flock"
chmod +x "$jp_dir/noflock/flock"
jp_run 1 "$jp_dir/pool9" PATH="$jp_dir/noflock:$PATH" -- '^pool a$' 2; jp_s1=$?
assert_status "a slot file that cannot be locked runs unpooled and passes" "$jp_s1" 0
assert_eq "without a waiting notice" "$(grep -c "$jp_notice" "$jp_dir/err")" "0"
else
  skip "the job pool cases on a shared pool" "flock is not installed"
fi
rm -rf "$jp_copy"

# all.sh's shellcheck processes take slots: two concurrent all.sh runs on a
# 1-slot pool never have more than one shellcheck at a time, and the notice
# comes from all.sh.
if command -v flock >/dev/null 2>&1; then
jp_all="$jp_dir/all"
suites_read "$jp_tests/all.sh" "$jp_tests" || bad "reads all.sh's suite list" "$SUITES_ERR"
stub_all_tree "$jp_all" "$jp_log" flock getconf
# jp_all_run <errfile>: all.sh on the stub PATH and the 1-slot pool.
jp_all_run() {
  env -u CI ORCH_TEST_POOL_PERCENT=50 ORCH_TEST_CPU_MAX_FILE="$jp_dir/cpu1" ORCH_TEST_POOL_DIR="$jp_dir/pool10" \
    ORCH_TEST_JOBS=3 PATH="$jp_all/bin" bash "$jp_all/scripts/test/all.sh" >/dev/null 2>"$1"
}
: >"$jp_log"
jp_all_run "$jp_dir/erra" &
jp_p1=$!
jp_all_run "$jp_dir/errb2" &
jp_p2=$!
wait "$jp_p1"; jp_s1=$?
wait "$jp_p2"; jp_s2=$?
assert_status "two concurrent all.sh runs on a 1-slot pool pass" "$((jp_s1 + jp_s2))" 0
assert_eq "their shellcheck processes never overlap on a 1-slot pool" "$(log_peak "$jp_log")" "1"
assert_eq "every file was still checked, twice over" \
  "$(grep -c '^+' "$jp_log")" "$((2 * (${#SUITES[@]} + ${#ALL_RUNNER_FILES[@]})))"
assert_contains "a waiting all.sh names itself in the notice" \
  "$(cat "$jp_dir/erra" "$jp_dir/errb2")" "all.sh: waiting for a job slot (1 in use)"
else
  skip "two concurrent all.sh runs share a 1-slot pool" "flock is not installed"
fi
rm -rf "$jp_dir"

# --- the slot fd contract (#2300) ---------------------------------------------
# Only test_jobs.sh knows the slot fd: the runners start jobs through
# test_jobs_job, and none holds the raw redirection or writes the report list.
echo
echo "the slot fd contract (#2300)"
fd_tests="$(dirname "$SUITE_SCRIPT")"
for fd_file in all.sh affected.sh orch_test.sh report.sh; do
  assert_eq "$fd_file holds no raw slot fd" \
    "$(grep -cE '8>&-|exec 8' "$fd_tests/$fd_file")" "0"
done
for fd_file in all.sh affected.sh orch_test.sh; do
  assert_eq "$fd_file starts its jobs through test_jobs_job" \
    "$(grep -c 'test_jobs_job ' "$fd_tests/$fd_file" | awk '{print ($1 > 0)}')" "1"
  assert_eq "$fd_file never writes REPORT_FAILED" \
    "$(grep -c 'REPORT_FAILED' "$fd_tests/$fd_file")" "0"
done
unset fd_file fd_tests

# --- the test runners' CPU load (#1586) ---------------------------------------
# The default job count, test_jobs.sh's test_jobs_default, with getconf faked
# on PATH and ORCH_TEST_CPU_MAX_FILE naming a planted quota file; then all.sh's
# limit on shellcheck processes, with shellcheck faked to log its starts and
# ends; then both runners' niceness, with ps and renice faked.
echo
echo "the test runners' CPU load (#1586)"
load_dir="$(mktemp -d)"
load_tests="$(dirname "$SUITE_SCRIPT")"
suites_read "$load_tests/all.sh" "$load_tests" || bad "reads all.sh's suite list" "$SUITES_ERR"
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
    unset CI ORCH_TEST_JOBS ORCH_TEST_POOL_PERCENT
    export ORCH_TEST_CPU_MAX_FILE="$file" PATH="$load_dir/getconf:$PATH"
    for load_kv in "$@"; do declare -x "$load_kv"; done
    source "$load_tests/test_jobs.sh"
    test_jobs_default load.sh 2>&1
  )
}
assert_eq "32 cores and no quota file give 24 jobs" "$(load_default 32 -missing)" "24"
assert_eq "32 cores and a quota of 4 CPUs give 3 jobs" "$(load_default 32 '400000 100000')" "3"
assert_eq "32 cores and a quota of 1.5 CPUs (2 usable) give 1 job" "$(load_default 32 '150000 100000')" "1"
assert_eq "4 cores and a quota above them give 3 jobs" "$(load_default 4 '800000 100000')" "3"
assert_eq "2 cores give 1 job" "$(load_default 2 -missing)" "1"
assert_eq "8 cores give 6 jobs" "$(load_default 8 -missing)" "6"
assert_eq "1 core gives 1 job" "$(load_default 1 -missing)" "1"
assert_eq "32 cores and a max quota give 24 jobs" "$(load_default 32 'max 100000')" "24"
assert_eq "32 cores and an unreadable quota file give 24 jobs" "$(load_default 32 -dir)" "24"
assert_eq "a failing getconf falls back to 4 cores, 3 jobs" "$(load_default fail -missing)" "3"
assert_eq "CI gives the full 32 usable CPUs" "$(load_default 32 -missing CI=true)" "32"
assert_eq "CI honours the quota too" "$(load_default 32 '400000 100000' CI=true)" "4"
assert_eq "ORCH_TEST_POOL_PERCENT=50 on 8 cores gives 4 jobs" \
  "$(load_default 8 -missing ORCH_TEST_POOL_PERCENT=50)" "4"
assert_eq "ORCH_TEST_POOL_PERCENT=100 on 8 cores gives 8 jobs" \
  "$(load_default 8 -missing ORCH_TEST_POOL_PERCENT=100)" "8"
assert_eq "ORCH_TEST_POOL_PERCENT=250 on 8 cores gives 20 jobs" \
  "$(load_default 8 -missing ORCH_TEST_POOL_PERCENT=250)" "20"
assert_eq "ORCH_TEST_POOL_PERCENT=075 means 75" \
  "$(load_default 8 -missing ORCH_TEST_POOL_PERCENT=075)" "6"
assert_eq "ORCH_TEST_POOL_PERCENT=1 keeps the floor of 1 job" \
  "$(load_default 8 -missing ORCH_TEST_POOL_PERCENT=1)" "1"
assert_eq "ORCH_TEST_POOL_PERCENT=25 on 4 cores gives 1 job" \
  "$(load_default 4 -missing ORCH_TEST_POOL_PERCENT=25)" "1"
assert_eq "ORCH_TEST_POOL_PERCENT=100 on a quota of 4 CPUs gives 4 jobs" \
  "$(load_default 32 '400000 100000' ORCH_TEST_POOL_PERCENT=100)" "4"
for load_pct in 0 00 abc -5 ''; do
  assert_eq "ORCH_TEST_POOL_PERCENT='$load_pct' is refused with the runner's message" \
    "$(load_default 8 -missing "ORCH_TEST_POOL_PERCENT=$load_pct")" \
    "load.sh: ORCH_TEST_POOL_PERCENT='$load_pct' is not a positive integer"
done
assert_eq "CI ignores ORCH_TEST_POOL_PERCENT" \
  "$(load_default 8 -missing CI=true ORCH_TEST_POOL_PERCENT=50)" "8"
assert_eq "CI does not validate ORCH_TEST_POOL_PERCENT" \
  "$(load_default 8 -missing CI=true ORCH_TEST_POOL_PERCENT=abc)" "8"

# all.sh's runs: a copy beside passing suite stubs, a shellcheck stub that logs
# "+" when it starts and "-" when it ends, over the stubs and the three copies.
load_all="$load_dir/all"
stub_all_tree "$load_all" "$load_all/sc_log"
# load_run_all [VAR=value...]: all.sh on the stub PATH, CI and ORCH_TEST_JOBS
# unset, then the assignments applied.
load_run_all() {
  (
    unset CI ORCH_TEST_JOBS ORCH_TEST_POOL_PERCENT
    env "$@" PATH="$load_all/bin:$load_dir/getconf" bash "$load_all/scripts/test/all.sh"
  )
}
printf '#!/bin/sh\necho 4\n' >"$load_dir/getconf/getconf"
chmod +x "$load_dir/getconf/getconf"
out="$(load_run_all ORCH_TEST_JOBS=2 2>&1)"; st=$?
assert_status "all.sh with ORCH_TEST_JOBS=2 passes" "$st" 0
assert_eq "all.sh with ORCH_TEST_JOBS=2 runs at most 2 shellcheck at once" "$(log_peak "$load_all/sc_log")" "2"
assert_eq "all.sh with ORCH_TEST_JOBS=2 still checks every file" \
  "$(grep -c '^+' "$load_all/sc_log")" "$((${#SUITES[@]} + ${#ALL_RUNNER_FILES[@]}))"
assert_eq "all.sh with ORCH_TEST_JOBS=2 ends on the shellcheck summary" \
  "$(printf '%s\n' "$out" | sed '$d' | tail -n 1)" "shellcheck: 0 findings"
: >"$load_all/sc_log"
load_run_all >/dev/null 2>&1
assert_eq "all.sh with ORCH_TEST_JOBS unset and 4 cores runs at most 3 shellcheck at once" \
  "$(log_peak "$load_all/sc_log")" "3"
: >"$load_all/sc_log"
load_run_all ORCH_TEST_JOBS=1 >/dev/null 2>&1
assert_eq "all.sh with ORCH_TEST_JOBS=1 runs one shellcheck at a time" "$(log_peak "$load_all/sc_log")" "1"
rm -f "$load_all/log" "$load_all/scripts/test/log" "$load_all/sc_log"
out="$(load_run_all ORCH_TEST_JOBS=abc 2>&1)"; st=$?
assert_status "all.sh with an invalid ORCH_TEST_JOBS exits 1" "$st" 1
assert_eq "all.sh with an invalid ORCH_TEST_JOBS names it on stderr" "$out" \
  "all.sh: ORCH_TEST_JOBS='abc' is not a positive integer"
assert_eq "all.sh with an invalid ORCH_TEST_JOBS starts no suite or shellcheck" \
  "$(ls "$load_all/sc_log" "$load_all/scripts/test/log" 2>/dev/null)" ""
for load_jobs in unset 2; do
  load_env=(ORCH_TEST_POOL_PERCENT=abc)
  [ "$load_jobs" = unset ] || load_env+=(ORCH_TEST_JOBS="$load_jobs")
  out="$(load_run_all "${load_env[@]}" 2>&1)"; st=$?
  assert_status "all.sh with an invalid ORCH_TEST_POOL_PERCENT (ORCH_TEST_JOBS $load_jobs) exits 1" "$st" 1
  assert_eq "all.sh with an invalid ORCH_TEST_POOL_PERCENT (ORCH_TEST_JOBS $load_jobs) names it on stderr" \
    "$out" "all.sh: ORCH_TEST_POOL_PERCENT='abc' is not a positive integer"
done
assert_eq "all.sh with an invalid ORCH_TEST_POOL_PERCENT starts no suite or shellcheck" \
  "$(ls "$load_all/sc_log" "$load_all/scripts/test/log" 2>/dev/null)" ""
out="$(load_run_all ORCH_TEST_POOL_PERCENT=0 ORCH_TEST_JOBS=abc 2>&1)"
assert_eq "with both invalid, all.sh names ORCH_TEST_JOBS alone" "$out" \
  "all.sh: ORCH_TEST_JOBS='abc' is not a positive integer"
out="$(load_run_all CI=true ORCH_TEST_POOL_PERCENT=abc 2>&1)"; st=$?
assert_status "all.sh under CI does not refuse an invalid ORCH_TEST_POOL_PERCENT" "$st" 0
rm -f "$load_all/log" "$load_all/scripts/test/log" "$load_all/sc_log"
out="$(env -u CI -u ORCH_TEST_JOBS ORCH_TEST_POOL_PERCENT=abc ORCH_TEST_ONLY='^isolation$' \
  bash "$load_tests/orch_test.sh" 2>&1)"; st=$?
assert_status "orch_test.sh with an invalid ORCH_TEST_POOL_PERCENT exits 1" "$st" 1
assert_contains "orch_test.sh names the invalid ORCH_TEST_POOL_PERCENT" "$out" \
  "orch_test.sh: ORCH_TEST_POOL_PERCENT='abc' is not a positive integer"
out="$(env -u CI ORCH_TEST_POOL_PERCENT=abc ORCH_TEST_JOBS=1 ORCH_TEST_ONLY='^isolation$' \
  bash "$load_tests/orch_test.sh" 2>&1)"; st=$?
assert_status "orch_test.sh with ORCH_TEST_JOBS set refuses it too" "$st" 1
assert_contains "and names it" "$out" "orch_test.sh: ORCH_TEST_POOL_PERCENT='abc' is not a positive integer"

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

# sc_tops <file>: each line's top-level flag, 1 or 0, on one line.
sc_tops() {
  awk "$SHELL_CODE_AWK"'{ shell_code_line($0); printf "%s", sc_top } END { print "" }' "$1"
}
# sc_case <name> <expected tops> <line>...: plants the lines, checks the flags.
sc_case() {
  local name="$1" want="$2"; shift 2
  printf '%s\n' "$@" >"$shell_code_dir/case.sh"
  assert_eq "$name" "$(sc_tops "$shell_code_dir/case.sh")" "$want"
}
sc_tab="$(printf '\t')"
sc_case "a shift in \$(( )) opens no heredoc" 11 'x=$((1<<n))' 'f() { :; }'
sc_case "a shift in a double-quoted \$(( )) opens no heredoc" 11 'echo "$((1<<n))"' 'f() { :; }'
sc_case "a shift in a \$(( )) on a heredoc body line opens no heredoc" 1001 'cat <<EOF' '$((1<<n))' 'EOF' 'f() { :; }'
sc_case "a shift in a (( )) command opens no heredoc" 11 '(( y = 1<<n ))' 'f() { :; }'
sc_case "a heredoc after a closed \$(( )) is read" 1001 'x=$((1)); cat <<EOF' 'body' 'EOF' 'f() { :; }'
sc_case "an unquoted hyphenated delimiter ends at its terminator" 1001 'cat <<END-NOTES' 'body' 'END-NOTES' 'f() { :; }'
sc_case "an unquoted dotted <<- delimiter ends at its tabbed terminator" 1001 'cat <<-END.TXT' "${sc_tab}body" "${sc_tab}END.TXT" 'f() { :; }'
sc_case "a single-quoted hyphenated delimiter ends at its terminator" 1001 "cat <<'END-NOTES'" 'body' 'END-NOTES' 'f() { :; }'
sc_case "a partly quoted delimiter ends at END" 1001 'cat <<E"N"D' 'body' 'END' 'f() { :; }'
sc_case "a backslash-quoted delimiter ends at EOF" 1001 'cat <<\EOF' 'body' 'EOF' 'f() { :; }'
sc_case "a quoted delimiter with a space ends at its terminator" 1001 'cat <<"a b"' 'body' 'a b' 'f() { :; }'
sc_case "a double-quoted delimiter with an escaped quote ends at a\"b" 1001 'cat <<"a\"b"' 'body' 'a"b' 'f() { :; }'
sc_case "a double-quoted delimiter with an escaped backslash ends at a\\b" 1001 'cat <<"a\\b"' 'body' 'a\b' 'f() { :; }'
sc_case "a variable delimiter ends at its terminator" 1001 'cat <<$X' 'body' '$X' 'f() { :; }'
sc_case "a subshell after a blank opens no arithmetic" 10011 '( (cat <<EOF' 'body' 'EOF' ') )' 'f() { :; }'
sc_case "let x=1<<n is a heredoc" 1001 'let x=1<<n' 'body' 'n' 'f() { :; }'
sc_case "a here-string opens no heredoc" 11 'cat <<<word' 'f() { :; }'
sc_case "an empty single-quoted delimiter opens a heredoc ending at an empty line" 1001 'cat <<'"''" 'body' '' 'f() { :; }'
sc_case "an empty double-quoted delimiter opens a heredoc ending at an empty line" 1001 'cat <<""' 'body' '' 'f() { :; }'

# the words view of a body line holding $(x): q when quoted, code when not
for sc_form in "'END-NOTES'|END-NOTES|q" 'END-NOTES|END-NOTES|$(x)' 'E"N"D|END|q' '\EOF|EOF|q'; do
  IFS='|' read -r sc_delim sc_term sc_want <<<"$sc_form"
  printf '%s\n' "cat <<$sc_delim" '$(x)' "$sc_term" >"$shell_code_dir/words-case.sh"
  assert_eq "the words view of a <<$sc_delim body line holding \$(x)" \
    "$(awk "$SHELL_CODE_AWK"'{ shell_code_line($0) } NR == 2 { print sc_words }' "$shell_code_dir/words-case.sh")" "$sc_want"
done
rm -rf "$shell_code_dir"

# --- test-helper placement (#1006) --------------------------------------------
# helper_placement over the real scripts/test/orch/, then over copies of it,
# each with planted helpers: four placements that break the rule, and one copy
# whose plantings all keep it.
echo
echo "test-helper placement (#1006)"
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
assert_contains "the failure message names the test-helper placement rule" "$out" "test-helper placement rule"
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

gh_op_dir="$(tree_copy scripts)"
plant_file "$gh_op_dir/orch" zz-trust.sh <<'PLANTED'
  planted_read() { adapter_issue_authorship "$1"; }
PLANTED
out="$(gh_op_placement "$gh_op_dir")"; st=$?
assert_status "the authorship op outside the gh and Trust modules fails" "$st" 1
assert_eq "naming the file and the op" "$out" \
  "scripts/orch/zz-trust.sh names adapter_issue_authorship. $GH_OP_PLACEMENT_RULE"
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
index_tests=(scripts/test/orch/setup.sh scripts/test/gh_adapter_fake.sh scripts/test/tally.sh scripts/test/fifo.sh)

grep_disagrees=""
for rel in "${index_modules[@]}" scripts/test/gh_adapter_fake.sh scripts/test/tally.sh scripts/test/fifo.sh; do
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
  grep -qE "^$name"$'\t''[^-]' <<<"$index_default"$'\n'"$out" \
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

# --- stand-in adapter (#2465) ------------------------------------------------
# adapter_stood_in <definitions> <cmd>...: runs <cmd> against a temp adapter
# that sources the gh fake and holds <definitions>, removes it whatever <cmd>'s
# status, and returns that status; a failed mktemp or write runs nothing.
echo
echo "stand-in adapter (#2465)"
sia_dir="$(mktemp -d)"
sia_cmd='printf "%s" "$(adapter_issue_json)"'
out="$(TMPDIR="$sia_dir" adapter_stood_in 'adapter_issue_json() { printf "it'"'"'s stood in"; }' \
  bash -c 'source "$ORCH_GH_ADAPTER"; '"$sia_cmd")"; st=$?
assert_eq "the command sees the redefined function, a quote honoured" "$out" "it's stood in"
assert_status "a passing command returns its status" "$st" 0
assert_eq "and leaves TMPDIR empty" "$(ls -A "$sia_dir")" ""
TMPDIR="$sia_dir" adapter_stood_in 'true' bash -c 'exit 7'; st=$?
assert_status "a failing command's status passes through" "$st" 7
assert_eq "and leaves TMPDIR empty (failing)" "$(ls -A "$sia_dir")" ""
rm -rf "$sia_dir"
sia_ran="$(mktemp)"
TMPDIR=/nonexistent/zz adapter_stood_in 'true' bash -c "echo ran >$(printf %q "$sia_ran")" 2>/dev/null; st=$?
assert_ne "a failed mktemp returns non-zero" "$st" 0
assert_eq "and runs nothing" "$(cat "$sia_ran")" ""
rm -f "$sia_ran"
unset sia_dir sia_cmd sia_ran

# --- git env clear (#1905) ----------------------------------------------------
# test_git_env_clear in scripts/test/git_env.sh, sourced in a child shell with
# a fake git first on PATH: it unsets what the fake's `rev-parse
# --local-env-vars` names, an invented variable included, so the set is git's
# own and no copy; it keeps other GIT_* knobs; and it fails closed, with its
# message, when git fails or prints nothing.
echo
echo "git env clear (#1905)"
genv_dir="$(mktemp -d)"
cat >"$genv_dir/git" <<'FAKE'
#!/usr/bin/env bash
[ "$1 $2" = "rev-parse --local-env-vars" ] || exit 99
case "$FAKE_GIT_MODE" in
  fail) exit 3 ;;
  empty) exit 0 ;;
  *) printf '%s\n' GIT_DIR GIT_PROBE_LOCAL ;;
esac
FAKE
chmod +x "$genv_dir/git"
genv_run() {
  FAKE_GIT_MODE="$1" PATH="$genv_dir:$PATH" GIT_DIR=/x GIT_PROBE_LOCAL=1 GIT_SSH_COMMAND=ssh \
    GIT_AUTHOR_NAME=a GIT_COMMITTER_DATE=d bash -c '
      source "$1/git_env.sh"
      test_git_env_clear; st=$?
      echo "st=$st dir=${GIT_DIR-unset} probe=${GIT_PROBE_LOCAL-unset} ssh=${GIT_SSH_COMMAND-unset} an=${GIT_AUTHOR_NAME-unset} cd=${GIT_COMMITTER_DATE-unset}"' \
    _ "$(dirname "$SUITE_SCRIPT")" 2>&1
}
assert_eq "clears what git names, invented variable included, and keeps other knobs" \
  "$(genv_run ok)" "st=0 dir=unset probe=unset ssh=ssh an=unset cd=unset"
out="$(genv_run fail)"
assert_contains "a failing git makes it fail with its message" "$out" \
  "cannot list git's repo-local variables"
assert_contains "and it returns non-zero" "$out" "st=1"
out="$(genv_run empty)"
assert_contains "a git that prints nothing makes it fail with its message" "$out" \
  "cannot list git's repo-local variables"
assert_contains "and returns non-zero" "$out" "st=1"
rm -rf "$genv_dir"
unset -f genv_run

# --- runner git isolation (#1905) ---------------------------------------------
# Every runner in all.sh's suites list clears git's environment before any git
# call: structurally, its first code line assigns its directory from
# BASH_SOURCE, its second sources git_env.sh through that variable, its third
# calls test_git_env_clear || exit 1. Tested over the real runners, then
# planted ones.
echo
echo "runner git isolation (#1905)"
RUNNER_GIT_RULE="The rule: a runner's first code line assigns its directory from BASH_SOURCE, its second sources git_env.sh through that variable, and its third calls test_git_env_clear || exit 1."

# runner_git_isolation <dir> <runner>...: checks each runner of <dir> and
# prints one line per runner that breaks the rule, naming it and the rule;
# returns 1 when it printed any.
runner_git_isolation() {
  local dir="$1" runner code l1 l2 l3 var bad_n=0
  shift
  for runner in "$@"; do
    code="$(awk "$SHELL_CODE_AWK"'
      { shell_code_line($0) }
      sc_code ~ /[^ \t]/ && n < 3 { n++; print sc_code }' "$dir/$runner")"
    l1="$(sed -n 1p <<<"$code")"; l2="$(sed -n 2p <<<"$code")"; l3="$(sed -n 3p <<<"$code")"
    var=""
    if [[ "$l1" =~ ^([A-Za-z_]+)=.*BASH_SOURCE ]]; then var="${BASH_REMATCH[1]}"; fi
    if [ -z "$var" ] || [[ "$l2" != "source \"\$$var/"*"git_env.sh\"" ]] \
      || [ "$l3" != "test_git_env_clear || exit 1" ]; then
      printf '%s does not clear git'"'"'s environment first. %s\n' "$runner" "$RUNNER_GIT_RULE"
      bad_n=$((bad_n + 1))
    fi
  done
  [ "$bad_n" -eq 0 ]
}

suites_read "$(dirname "$SUITE_SCRIPT")/all.sh" "$(dirname "$SUITE_SCRIPT")" || bad "reads all.sh's suite list" "$SUITES_ERR"
out="$(runner_git_isolation "$(dirname "$SUITE_SCRIPT")" "${SUITES[@]}")"; st=$?
if [ "$st" -eq 0 ] && [ -z "$out" ]; then
  ok "every real runner clears git's environment first"
else
  bad "every real runner clears git's environment first" "$out"
fi

rgi_dir="$(mktemp -d)"
# shellcheck disable=SC2016 # planted runner text, not expanded here
{
  printf '%s\n' '#!/usr/bin/env bash' '# a comment' '' \
    'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    'source "$DIR/git_env.sh"' 'test_git_env_clear || exit 1' >"$rgi_dir/good.sh"
  printf '%s\n' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    'source "$DIR/git_env.sh"' 'git init -q x' '# test_git_env_clear' >"$rgi_dir/nocall.sh"
  printf '%s\n' 'PASS=0' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    'source "$DIR/git_env.sh"' 'test_git_env_clear || exit 1' >"$rgi_dir/early.sh"
  printf '%s\n' 'DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
    'source "$DIR/git_env.sh"' 'test_git_env_clear' >"$rgi_dir/bare.sh"
}
out="$(runner_git_isolation "$rgi_dir" good.sh)"; st=$?
assert_status "a runner that clears first passes" "$st" 0
out="$(runner_git_isolation "$rgi_dir" nocall.sh)"; st=$?
assert_status "a runner that misses the call fails" "$st" 1
assert_eq "naming it and the rule" "$out" \
  "nocall.sh does not clear git's environment first. $RUNNER_GIT_RULE"
out="$(runner_git_isolation "$rgi_dir" early.sh)"; st=$?
assert_status "a runner with a code line before its source line fails" "$st" 1
assert_eq "naming it and the rule too" "$out" \
  "early.sh does not clear git's environment first. $RUNNER_GIT_RULE"
out="$(runner_git_isolation "$rgi_dir" bare.sh)"; st=$?
assert_status "a runner that carries on when the call fails fails" "$st" 1
rm -rf "$rgi_dir"
unset -f runner_git_isolation

# --- affected.sh, the ticket verification (#2023) -----------------------------
# affected.sh at its --plan seam, in a throwaway git repo that carries the test
# layout: the real affected.sh, ALL_RUNNER_FILES, git_env.sh and
# test_tree.sh,
# a harness
# file holding the three placement sections, a branch section file with two
# sections, and one tiny file for each other kind of path. origin's main is the
# initial commit, origin's rel that commit plus a change to the branch module,
# and HEAD is feat, rel plus a change to a doc. Stub suites stand in for the
# real ones in the end-to-end cases.
echo
echo "affected.sh, the ticket verification (#2023)"
af_tests="$(dirname "$SUITE_SCRIPT")"
if [ -x "$af_tests/affected.sh" ]; then st=0; else st=1; fi
assert_eq "affected.sh is executable, as CLAUDE.md runs it directly" "$st" "0"
af="$(mktemp -d)"
af_git() { git -C "$af" -c user.name=t -c user.email=t@example.com "$@"; }
# af_put <path> [<line>...]: write a tiny file (a shell file gets a shebang).
af_put() {
  local path="$1"
  shift
  mkdir -p "$af/$(dirname "$path")"
  case "$path" in *.sh) set -- '#!/usr/bin/env bash' "$@" ;; esac
  [ "$#" -eq 0 ] && set -- x
  printf '%s\n' "$@" >"$af/$path"
}
af_git init -q -b main
mkdir -p "$af/scripts/test/orch"
(cd "$af_tests" && cp "${ALL_RUNNER_FILES[@]}" affected.sh git_env.sh "$af/scripts/test/")
suites_read "$af_tests/all.sh" "$af_tests" || bad "reads all.sh's suite list" "$SUITES_ERR"
for af_s in "${SUITES[@]}"; do
  [ -e "$af/scripts/test/$af_s" ] || af_put "scripts/test/$af_s"
done
af_put scripts/test/orch/harness.sh '# --- isolation ---' \
  '# --- test-helper placement (#1006) ---' '# --- gh op placement (#1037) ---' \
  '# --- marked comment prelude placement (#1853) ---' '# --- the parallel runner (#780) ---'
af_put scripts/test/orch/branch.sh 'x=1' '# --- branch create ---' '# --- branch (x.y) retire ---'
af_put scripts/test/orch/state.sh '# --- state ---'
for af_f in scripts/orch.sh scripts/orch/common.sh scripts/orch/branch.sh \
  scripts/orch/state.sh scripts/test/orch/common.sh scripts/test/orch/setup.sh \
  scripts/test/orch_test.sh scripts/test/gh_adapter_fake.sh scripts/hook-guard.sh \
  scripts/version-bump.sh scripts/autopilot-container.sh scripts/autopilot-up.sh \
  scripts/dev/lens-bench.sh scripts/dev/other.sh scripts/test/docs_lint.sh \
  hooks/hooks.json docs/a.md skills/s/SKILL.md agents/a.md changelog.d/1.md Makefile; do
  af_put "$af_f"
done
af_git add -A
af_git commit -qm init
af_c0="$(af_git rev-parse HEAD)"
af_git update-ref refs/remotes/origin/main "$af_c0"
af_git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
af_put scripts/orch/branch.sh 'y=2'
af_git commit -qam "branch module"
af_git update-ref refs/remotes/origin/rel HEAD
af_git checkout -q -b feat
af_put docs/a.md changed
af_git commit -qam "doc"
af_feat="$(af_git rev-parse HEAD)"
# af_reset: back to the committed feat, with no config but the fixture's.
af_reset() {
  af_git checkout -q -f feat
  af_git reset -q --hard "$af_feat"
  af_git clean -qfd
  af_git config --remove-section branch.feat 2>/dev/null
  af_git config --remove-section branch.feat--t1 2>/dev/null
  af_git config --unset orchestrator.base 2>/dev/null
  af_git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
# af_plan [<arg>...]: affected.sh --plan <arg>... in the fixture, one line per
# item joined with commas.
af_plan() {
  (cd "$af" && bash scripts/test/affected.sh --plan "$@" 2>&1) | paste -sd, -
}
af_placement="test-helper placement (#1006),gh op placement (#1037),marked comment prelude placement (#1853)"
af_gate="orch_test.sh,$af_placement"
af_branch_titles="branch create,branch (x.y) retire"

af_reset
assert_eq "a change to a doc selects only the always-run checks" \
  "$(af_plan origin/rel)" "$af_gate,docs_lint.sh"
assert_eq "a module selects its section file's sections, and shellchecks itself" \
  "$(af_plan origin/main)" "$af_gate,$af_branch_titles,docs_lint.sh,scripts/orch/branch.sh"
af_put scripts/test/orch/branch.sh 'x=2' '# --- branch create ---'
assert_eq "a section file selects its own sections, uncommitted" "$(af_plan origin/rel)" \
  "$af_gate,branch create,docs_lint.sh,scripts/test/orch/branch.sh"
af_reset
af_put scripts/test/orch/zz-new.sh '# --- zz new ---'
assert_eq "an untracked section file selects its sections" "$(af_plan origin/rel)" \
  "$af_gate,zz new,docs_lint.sh,scripts/test/orch/zz-new.sh"
af_reset
af_put scripts/test/orch/state.sh '# --- state ---' '# --- state two ---'
af_git add -A
assert_eq "a staged change counts" "$(af_plan origin/rel)" \
  "$af_gate,state,state two,docs_lint.sh,scripts/test/orch/state.sh"
af_reset
af_put scripts/test/orch/harness.sh '# --- isolation ---' \
  '# --- test-helper placement (#1006) ---' '# --- gh op placement (#1037) ---' \
  '# --- marked comment prelude placement (#1853) ---' '# --- the parallel runner (#780) ---' \
  '# --- more ---'
assert_eq "harness.sh selects all of its sections, the placement ones once" \
  "$(af_plan origin/rel)" \
  "$af_gate,isolation,the parallel runner (#780),more,docs_lint.sh,scripts/test/orch/harness.sh"

# One row each.
af_row() {
  af_reset
  af_put "$2" changed
  assert_eq "$1" "$(af_plan origin/rel)" "$3"
}
af_row "a hook script selects hooks_test.sh" scripts/hook-guard.sh \
  "$af_gate,hooks_test.sh,docs_lint.sh,scripts/hook-guard.sh"
af_row "hooks.json selects hooks_test.sh, with nothing to shellcheck" hooks/hooks.json \
  "$af_gate,hooks_test.sh,docs_lint.sh"
af_row "version-bump.sh selects its test file" scripts/version-bump.sh \
  "$af_gate,docs_lint.sh,version_bump_test.sh,scripts/version-bump.sh"
af_row "autopilot-container.sh selects its test file" scripts/autopilot-container.sh \
  "$af_gate,docs_lint.sh,autopilot_container_test.sh,scripts/autopilot-container.sh"
af_row "autopilot-up.sh selects its test file" scripts/autopilot-up.sh \
  "$af_gate,docs_lint.sh,autopilot_up_test.sh,scripts/autopilot-up.sh"
af_row "the lens-bench script selects its test file" scripts/dev/lens-bench.sh \
  "$af_gate,docs_lint.sh,lens_bench_test.sh,scripts/dev/lens-bench.sh"
af_row "a lens-bench fixture script falls back to all.sh" scripts/dev/lens-bench/case.sh "all.sh"
af_row "a lens-bench test fixture falls back to all.sh" scripts/test/lens-bench/case.txt "all.sh"
af_row "a markdown lens-bench fixture selects nothing more" scripts/dev/lens-bench/case.md \
  "$af_gate,docs_lint.sh"
af_row "a skill selects nothing more" skills/s/SKILL.md "$af_gate,docs_lint.sh"
af_row "an agent selects nothing more" agents/a.md "$af_gate,docs_lint.sh"
af_row "a non-markdown file under commands falls back to all.sh" commands/x.txt "all.sh"
af_row "a changelog fragment selects nothing more" changelog.d/2.md "$af_gate,docs_lint.sh"
af_row "a markdown file selects nothing more" README.md "$af_gate,docs_lint.sh"
for af_f in scripts/orch.sh scripts/orch/common.sh scripts/test/orch/common.sh \
  scripts/test/orch/setup.sh scripts/test/all.sh scripts/test/orch_test.sh \
  scripts/test/gh_adapter_fake.sh scripts/test/test_jobs.sh scripts/test/report.sh scripts/test/test_tree.sh scripts/dev/other.sh Makefile; do
  af_row "$af_f falls back to all.sh" "$af_f" "all.sh"
done
af_reset
af_put scripts/orch/branch.sh 'z=3'
af_put scripts/orch.sh 'z=3'
assert_eq "an unmapped file wins over a module" "$(af_plan origin/rel)" "all.sh"

# The line order, with every kind of change at once.
af_reset
for af_f in scripts/dev/lens-bench.sh scripts/autopilot-up.sh scripts/autopilot-container.sh \
  scripts/version-bump.sh scripts/hook-guard.sh scripts/orch/state.sh; do
  af_put "$af_f" changed
done
af_put scripts/test/orch/branch.sh 'x=2' '# --- branch create ---' '# --- branch (x.y) retire ---'
assert_eq "the suites in all.sh's order, sections after orch_test.sh, shellcheck last" \
  "$(af_plan origin/rel)" \
  "$af_gate,branch create,branch (x.y) retire,state,hooks_test.sh,docs_lint.sh,version_bump_test.sh,autopilot_container_test.sh,autopilot_up_test.sh,lens_bench_test.sh,scripts/autopilot-container.sh,scripts/autopilot-up.sh,scripts/dev/lens-bench.sh,scripts/hook-guard.sh,scripts/orch/state.sh,scripts/test/orch/branch.sh,scripts/version-bump.sh"

# Deletions.
af_reset
rm "$af/scripts/hook-guard.sh"
assert_eq "a deleted shell file is not shellchecked" "$(af_plan origin/rel)" \
  "$af_gate,hooks_test.sh,docs_lint.sh"
rm "$af/scripts/orch/state.sh"
assert_eq "a deleted module falls back to all.sh" "$(af_plan origin/rel)" "all.sh"
af_reset
af_git rm -q scripts/test/orch/state.sh
assert_eq "a deleted section file falls back to all.sh" "$(af_plan origin/rel)" "all.sh"

# The ref.
af_reset
af_put scripts/hook-guard.sh changed
af_git add -A
af_git commit -qm hook
assert_eq "a given ref bounds the range" "$(af_plan HEAD~1)" \
  "$af_gate,hooks_test.sh,docs_lint.sh,scripts/hook-guard.sh"
assert_eq "--plan takes the ref after it, as a run takes it alone" \
  "$(cd "$af" && bash scripts/test/affected.sh HEAD~1 --plan | paste -sd, -)" \
  "$(af_plan HEAD~1)"
af_out="$(cd "$af" && bash scripts/test/affected.sh --plan nosuch 2>&1 >/dev/null)"; st=$?
assert_status "an unknown ref exits 2, --plan included" "$st" 2
assert_eq "naming the ref on stderr" "$af_out" "affected.sh: unknown ref nosuch"
af_out="$(cd "$af" && bash scripts/test/affected.sh nosuch 2>&1)"; st=$?
assert_status "an unknown ref exits 2 without --plan too" "$st" 2
assert_eq "and runs and prints nothing else" "$af_out" "affected.sh: unknown ref nosuch"

# The default base. feat differs from main by the branch module and a doc,
# from rel by the doc.
af_reset
af_from_main="$af_gate,$af_branch_titles,docs_lint.sh,scripts/orch/branch.sh"
af_from_rel="$af_gate,docs_lint.sh"
assert_eq "origin's default branch is the last resort" "$(af_plan)" "$af_from_main"
af_git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/rel
assert_eq "origin's default branch is used when nothing is recorded" "$(af_plan)" "$af_from_rel"
af_reset
af_git config orchestrator.base rel
assert_eq "orchestrator.base beats origin's default branch" "$(af_plan)" "$af_from_rel"
af_git config branch.feat.orchestrator-base main
assert_eq "the current branch's recorded base beats orchestrator.base" "$(af_plan)" "$af_from_main"
af_reset
af_git config branch.feat.orchestrator-base rel
af_git checkout -q -b feat--t1
af_git config branch.feat--t1.orchestrator-ticket-parent feat
assert_eq "a ticket branch uses its parent's recorded base" "$(af_plan)" "$af_from_rel"
af_git checkout -q feat
af_git branch -q -D feat--t1

# No base.
af_reset
af_git symbolic-ref --delete refs/remotes/origin/HEAD
assert_eq "no base at all falls back to all.sh" "$(af_plan)" "all.sh"
af_git config orchestrator.base gone
assert_eq "a recorded base missing on origin falls back to all.sh" "$(af_plan)" "all.sh"
af_tree="$(af_git hash-object -t tree -w /dev/null)"
af_git update-ref refs/remotes/origin/orphan "$(af_git commit-tree "$af_tree" -m orphan)"
af_git config orchestrator.base orphan
assert_eq "a base with no merge-base falls back to all.sh" "$(af_plan)" "all.sh"
af_reset

# A title with trailing dashes reads as the shared rule reads it.
af_reset
af_put scripts/test/orch/dashed.sh '# --- dashed title (#9) ------ ' '# --- plain ---'
af_want="$(awk "$SECTION_TITLE_AWK"'/^# --- / { print title($0) }' "$af/scripts/test/orch/dashed.sh" | paste -sd, -)"
assert_eq "the shared title rule drops trailing spaces and dashes" "$af_want" "dashed title (#9),plain"
assert_eq "a planted header reads the same in --plan as under SECTION_TITLE_AWK" \
  "$(af_plan origin/rel)" "$af_gate,$af_want,docs_lint.sh,scripts/test/orch/dashed.sh"
rm -f "$af/scripts/test/orch/dashed.sh"

# The awk title function is defined in test_tree.sh alone.
af_defs="$(grep -l 'function title(' "$af_tests/affected.sh" "$af_tests/orch_test.sh" "$af_tests/test_tree.sh" | xargs -n1 basename | paste -sd, -)"
assert_eq "the title function is defined only in test_tree.sh" "$af_defs" "test_tree.sh"

# An all.sh the shared reader refuses stops affected.sh, with its own prefix.
for af_case in none two empty missing; do
  af_reset
  case "$af_case" in
    none) af_put scripts/test/all.sh 'suites_list=(a.sh)' ;;
    two) af_put scripts/test/all.sh 'suites=(orch_test.sh)' 'suites=(docs_lint.sh)' ;;
    empty) af_put scripts/test/all.sh 'suites=()' ;;
    missing) af_put scripts/test/all.sh 'suites=(orch_test.sh no_such_suite.sh)' ;;
  esac
  af_git commit -qam "$af_case"
  suites_read "$af/scripts/test/all.sh" "$af/scripts/test"
  af_msg="$SUITES_ERR"
  af_out="$(cd "$af" && bash scripts/test/affected.sh HEAD 2>&1)"; st=$?
  assert_status "affected.sh exits 1 over an all.sh with $af_case" "$st" 1
  assert_eq "and prints the reader's message with its own prefix and runs nothing ($af_case)" \
    "$af_out" "affected.sh: $af_msg"
done
af_reset

# End to end, with stub suites for the real ones.
suites_read "$af_tests/all.sh" "$af_tests" || bad "reads all.sh's suite list" "$SUITES_ERR"
for af_s in "${SUITES[@]}"; do
  printf '%s\n' '#!/usr/bin/env bash' \
    "echo \"$af_s only=\${ORCH_TEST_ONLY-unset}\" >>\"$af.log\"" \
    'echo; echo "7 passed, 0 failed"' >"$af/scripts/test/$af_s"
done
af_git add -A
af_git commit -qm stubs
af_feat="$(af_git rev-parse HEAD)"
af_put scripts/hook-guard.sh 'echo ok'
# A shellcheck stub, first on PATH for the runs meant to have shellcheck: one
# gcc-format line per argument file containing $(ls), exit 1 if it printed any.
af_sc="$af.sc"
mkdir -p "$af_sc"
cat >"$af_sc/shellcheck" <<'STUB'
#!/usr/bin/env bash
found=0
for f in "$@"; do
  if [ -f "$f" ] && grep -qF '$(ls)' "$f"; then
    echo "$f:1:1: warning: stub [SC2045]"
    found=1
  fi
done
exit "$found"
STUB
chmod +x "$af_sc/shellcheck"
af_out="$(cd "$af" && PATH="$af_sc:$PATH" bash scripts/test/affected.sh HEAD 2>&1)"; st=$?
assert_status "a passing run exits 0" "$st" 0
assert_eq "printing each part's summary in order, shellcheck last" "$af_out" \
  "orch_test.sh: 7 passed, 0 failed
hooks_test.sh: 7 passed, 0 failed
docs_lint.sh: 7 passed, 0 failed
shellcheck: 0 findings
affected.sh: PASS (4 parts)"
assert_contains "orch_test.sh got the placement sections as its filter" \
  "$(cat "$af.log")" "orch_test.sh only=^(test-helper placement \\(#1006\\)|"
assert_eq "no other suite ran" "$(grep -c . "$af.log")" "3"

# An invalid ORCH_TEST_POOL_PERCENT is refused before anything runs.
: >"$af.log"
af_out="$(cd "$af" && env -u CI ORCH_TEST_POOL_PERCENT=abc bash scripts/test/affected.sh HEAD 2>&1)"; st=$?
assert_status "an invalid ORCH_TEST_POOL_PERCENT makes affected.sh exit 1" "$st" 1
assert_eq "and names the value" "$af_out" \
  "affected.sh: ORCH_TEST_POOL_PERCENT='abc' is not a positive integer"
assert_eq "and runs no suite" "$(grep -c . "$af.log")" "0"

# Its shellcheck process draws a slot from the job pool: with the pool's one
# slot held, the run waits and says so, then finishes once the slot is freed.
if command -v flock >/dev/null 2>&1; then
  pool_cpu_file "$af.cpu" 1
  slot_hold "$af.pool" 1 || bad "holds the slot"
  af_put scripts/hook-guard.sh 'echo ok'
  (cd "$af" && env -u CI -u ORCH_TEST_POOL_PERCENT PATH="$af_sc:$PATH" ORCH_TEST_CPU_MAX_FILE="$af.cpu" ORCH_TEST_POOL_DIR="$af.pool" \
    timeout 30 bash scripts/test/affected.sh HEAD >/dev/null 2>"$af.err") &
  af_pid=$!
  notice_wait "$af.err"
  assert_eq "a shellcheck run with the pool's slot held waits and says so" \
    "$(cat "$af.err")" "affected.sh: waiting for a job slot (1 in use)"
  slot_release
  wait "$af_pid"; st=$?
  assert_status "and the run finishes once the slot is freed" "$st" 0
  rm -rf "$af.cpu" "$af.pool" "$af.err"
else
  skip "a shellcheck run with the pool's slot held waits and says so" "flock is not installed"
fi
printf '%s\n' '#!/usr/bin/env bash' 'printf "  FAIL a thing\n     its detail\n"' \
  'echo; echo "1 passed, 1 failed"; exit 1' >"$af/scripts/test/hooks_test.sh"
af_put scripts/hook-guard.sh 'for f in $(ls); do echo "$f"; done'
af_out="$(cd "$af" && PATH="$af_sc:$PATH" bash scripts/test/affected.sh HEAD 2>&1)"; st=$?
assert_status "a failing part makes the run exit 1" "$st" 1
assert_contains "printing its FAIL lines and its summary" "$af_out" \
  "  FAIL a thing
     its detail
hooks_test.sh: 1 passed, 1 failed"
assert_contains "and shellcheck's findings" "$af_out" "shellcheck: 1 findings"
assert_eq "ending on a FAIL verdict naming the failing parts" "$(printf '%s\n' "$af_out" | tail -n 1)" \
  "affected.sh: FAIL (hooks_test.sh, shellcheck)"

# A suite that exits 0 on a header, with no summary line, died before it.
printf '%s\n' '#!/usr/bin/env bash' 'echo "a section header"' >"$af/scripts/test/hooks_test.sh"
af_put scripts/hook-guard.sh 'echo ok'
af_out="$(cd "$af" && PATH="$af_sc:$PATH" bash scripts/test/affected.sh HEAD 2>&1)"; st=$?
assert_status "a suite that exited 0 without its summary makes the run exit 1" "$st" 1
assert_contains "and is reported as died before its summary" "$af_out" \
  "hooks_test.sh: died before its summary (exit 0)"
assert_eq "ending on a FAIL verdict naming only that suite" "$(printf '%s\n' "$af_out" | tail -n 1)" \
  "affected.sh: FAIL (hooks_test.sh)"

# The verdict line (the last stdout line), on a PATH without shellcheck: its
# links are the tools the runners and the fixture need.
af_bin="$af.bin"
mkdir -p "$af_bin"
for af_tool in bash git sort grep sed awk dirname basename mktemp rm mkdir cat tail head \
  paste tr cut wc env sleep date uname getconf nice renice flock ls cp mv; do
  af_path="$(command -v "$af_tool" 2>/dev/null)" && ln -s "$af_path" "$af_bin/$af_tool"
done
# af_verdict_run [VAR=value...] -- <affected.sh arg>...: affected.sh in the
# fixture on that PATH with CI unset, then each assignment applied; its output
# goes to af_out, its status to st.
af_verdict_run() {
  local env_args=()
  while [ "$1" != -- ]; do env_args+=("$1"); shift; done
  shift
  af_out="$(cd "$af" && env -u CI -u ORCH_TEST_JOBS -u ORCH_TEST_POOL_PERCENT "${env_args[@]}" \
    PATH="$af_bin" bash scripts/test/affected.sh "$@" 2>/dev/null)"
  st=$?
}
# A passing selection: the passing stub back, shellcheck skipped.
printf '%s\n' '#!/usr/bin/env bash' 'echo; echo "7 passed, 0 failed"' >"$af/scripts/test/hooks_test.sh"
af_verdict_run -- HEAD
assert_status "a passing selection exits 0 without shellcheck outside CI" "$st" 0
assert_contains "a missing shellcheck outside CI prints its skipped line" "$af_out" \
  "shellcheck: not installed - skipped"
assert_eq "a missing shellcheck outside CI ends on a PASS verdict counting the skipped line" \
  "$(printf '%s\n' "$af_out" | tail -n 1)" "affected.sh: PASS (4 parts)"
af_verdict_run CI=1 -- HEAD
assert_status "a missing shellcheck under CI exits 1" "$st" 1
assert_eq "a missing shellcheck under CI ends on a FAIL verdict naming shellcheck" \
  "$(printf '%s\n' "$af_out" | tail -n 1)" "affected.sh: FAIL (shellcheck)"
# No shell file changed: shellcheck's own line still counts.
af_git checkout -q -f -- . 2>/dev/null
rm -f "$af/scripts/hook-guard.sh"
af_git reset -q --hard "$af_feat"
af_verdict_run -- HEAD
assert_eq "a selection with no changed shell file counts shellcheck's line" \
  "$(printf '%s\n' "$af_out" | tail -n 1)" "affected.sh: PASS (3 parts)"
# The full-suite fallback ends on all.sh's verdict.
af_put scripts/orch.sh 'echo changed'
af_verdict_run -- HEAD
assert_eq "a full-suite fallback ends on all.sh's verdict, never affected.sh's" \
  "$(printf '%s\n' "$af_out" | tail -n 1)" "all.sh: PASS ($((${#SUITES[@]} + 1)) parts)"
af_reset
# Paths that end before the report print no verdict.
af_verdict_run -- --bogus
assert_status "a usage error exits 2" "$st" 2
assert_eq "a usage error prints no verdict on stdout" "$af_out" ""
# A TERM stop prints no verdict.
printf '%s\n' '#!/usr/bin/env bash' "echo \$\$ >'$af.pid'" 'sleep 30' >"$af/scripts/test/hooks_test.sh"
af_put scripts/hook-guard.sh 'echo ok'
(cd "$af" && exec env -u CI PATH="$af_bin" bash scripts/test/affected.sh HEAD) >"$af.stdout" 2>/dev/null &
af_pid=$!
af_tries=0
until [ -s "$af.pid" ] || [ "$af_tries" -gt 100 ]; do af_tries=$((af_tries + 1)); sleep 0.1; done
kill -TERM "$af_pid"
wait "$af_pid"; st=$?
kill "$(cat "$af.pid")" 2>/dev/null
assert_status "TERM to affected.sh exits 130" "$st" 130
assert_eq "TERM to affected.sh prints no verdict" "$(grep -c ': \(PASS\|FAIL\) (' "$af.stdout")" "0"
# A set ORCH_TEST_SHARD never narrows a ticket verification: the suites see it
# unset on the mapped path and on the full-suite fallback.
printf '%s\n' '#!/usr/bin/env bash' 'echo; echo "7 passed, 0 failed"' >"$af/scripts/test/hooks_test.sh"
printf '%s\n' '#!/usr/bin/env bash' "echo \"shard=\${ORCH_TEST_SHARD:-unset}\" >>'$af.log'" \
  'echo; echo "7 passed, 0 failed"' >"$af/scripts/test/orch_test.sh"
: >"$af.log"
af_verdict_run ORCH_TEST_SHARD=2/4 -- HEAD
assert_eq "affected.sh's mapped path runs orch_test.sh with the shard setting unset" \
  "$(grep "^shard=" "$af.log" | sort -u)" "shard=unset"
af_put scripts/orch.sh 'echo changed'
: >"$af.log"
af_verdict_run ORCH_TEST_SHARD=2/4 -- HEAD
assert_eq "and its fallback to all.sh runs the whole suite, the setting unset" \
  "$(grep "^shard=" "$af.log" | sort -u)" "shard=unset"
assert_eq "ending on all.sh's verdict counting every part" "$(printf '%s\n' "$af_out" | tail -n 1)" \
  "all.sh: PASS ($((${#SUITES[@]} + 1)) parts)"
af_reset
rm -rf "$af_bin" "$af_sc" "$af.pid" "$af.stdout"
rm -rf "$af" "$af.log"
unset -f af_git af_put af_reset af_plan af_row
