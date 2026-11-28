# shellcheck shell=bash
# shellcheck disable=SC2034 # its assignments are read by the section files, linted apart
# The orch.sh suite's shared setup and summary, which scripts/test/orch_test.sh
# reads and evals; never run on its own. The shared setup runs from the
# `# >>> shared setup` line to the `# >>> summary` line, before any section; the
# summary runs from the `# >>> summary` line to the end of the file, after them.
# The `# ---` blocks inside the shared setup are setup, not sections.
# >>> shared setup

# The host signals doctor reads: the shell running the tests is often itself
# a Claude Code, Junie or Antigravity session. Each test names its host.
unset ORCHESTRATOR_HOST CLAUDECODE JUNIE_EXTENSION_ROOT JUNIE_SHIM_PATH \
  ANTIGRAVITY_AGENT ANTIGRAVITY_CONVERSATION_ID

# The caller's ORCH_* knobs: a suite started from an autopilot session exports
# ORCH_AUTOPILOT, ORCH_SH, ORCH_MODEL*, ORCH_EFFORT* and more. Every exported
# ORCH_* goes, by prefix, but ORCH_TEST_*, the suite's own knobs.
while IFS= read -r setup_var; do
  case "$setup_var" in ORCH_TEST_*) ;; ORCH_*) unset "$setup_var" ;; esac
done < <(compgen -e)
unset setup_var

# ORCH and PLUGIN_ROOT are set by scripts/test/orch_test.sh, the runner, from
# its own location, before the cd below. CALLER_HOME keeps the HOME the suite
# started with, only for the isolation section to check HOME differs from it.
# XDG_CONFIG_HOME and GIT_CONFIG_GLOBAL go too: git would otherwise still read
# the caller's global config through them.
CALLER_HOME="$HOME"
SUITE_CWD="$(mktemp -d)" && cd "$SUITE_CWD" || {
  echo "orch_test.sh: cannot cd into a fresh temp directory" >&2; exit 1; }
SUITE_HOME="$(mktemp -d)" || {
  echo "orch_test.sh: cannot create a temp HOME" >&2; exit 1; }
export HOME="$SUITE_HOME"
# GH_REPO and GH_HOST go too: they are the gh variables orch.sh reads to resolve
# the Repo and its GitHub host, so a caller's value would change what orch.sh
# resolves in every section.
unset CLAUDE_PLUGIN_ROOT XDG_CONFIG_HOME GIT_CONFIG_GLOBAL GH_REPO GH_HOST

# The real-gh guard: a stub gh, first on PATH before SUITE_PATH is captured so
# restore_suite_env keeps it, that appends its arguments to GH_GUARD_LOG, in
# this setup's own temp directory, and exits 1. It is a guard, not a fake: it
# answers nothing, so a section that reaches gh without a gh of its own ahead
# of it on PATH fails, and the summary turns each logged call into one FAIL
# naming it.
GH_GUARD_DIR="$(mktemp -d)" && mkdir "$GH_GUARD_DIR/bin" &&
  GH_GUARD_LOG="$GH_GUARD_DIR/calls.log" && : >"$GH_GUARD_LOG" || {
  echo "orch_test.sh: cannot create the real-gh guard's log" >&2; exit 1; }
cat >"$GH_GUARD_DIR/bin/gh" <<GH || exit 1
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" | tr '\n' ' ' | sed 's/ \$//' >>"$GH_GUARD_LOG"
echo >>"$GH_GUARD_LOG"
echo "orch_test.sh: a section called the real gh: gh \$*" >&2
exit 1
GH
chmod +x "$GH_GUARD_DIR/bin/gh" || exit 1
PATH="$GH_GUARD_DIR/bin:$PATH"

# The environment every section starts from. A section that exports HOME,
# CLAUDE_PLUGIN_ROOT or GH_REPO, or changes PATH, ends with restore_suite_env,
# leaving the next section the environment it had. A section that exported
# more names passes them to restore_suite_env to unset them too.
SUITE_PATH="$PATH"
# No test waits out the real GitHub rate-limit backoff (60 and 300 seconds).
export ORCH_GH_LIMIT_WAIT=0
restore_suite_env() {
  unset CLAUDE_PLUGIN_ROOT GH_REPO "$@"
  HOME="$SUITE_HOME"; PATH="$SUITE_PATH"
}

assert_eq() {
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi
}
assert_ne() {
  if [ "$2" != "$3" ]; then ok "$1"; else bad "$1" "expected anything but '$3'"; fi
}
assert_contains() {
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "output did not contain '$3': $2" ;; esac
}
assert_status() {
  if [ "$2" -eq "$3" ]; then ok "$1"; else bad "$1" "expected exit $3, got $2"; fi
}
# A fresh repo with one commit, an empty docs/agents/ for a labels doc and an
# origin of https://github.com/o/r.git (so it resolves to the repo o/r), cwd
# inside it. No setup is required of it (ADR-0028).
new_repo() {
  local d
  d="$(mktemp -d)"
  git -C "$d" init -q
  git -C "$d" config user.email test@example.com
  git -C "$d" config user.name Test
  mkdir -p "$d/docs/agents"
  echo "# repo" >"$d/README.md"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  git -C "$d" remote add origin https://github.com/o/r.git
  cd "$d" || exit 1
  printf '%s\n' "$d"
}

# on_disk <path>: present or absent, whether anything is at <path>.
on_disk() { if [ -e "$1" ]; then echo present; else echo absent; fi; }

# SHELL_CODE_AWK: the one rule of what counts as code in a shell file, an awk
# function library an awk scanner includes by concatenation (awk
# "$SHELL_CODE_AWK"'...'), kept in its own file, scripts/test/shell_code.awk,
# which docs_lint.sh loads too; its header comment states the interface.
SHELL_CODE_AWK="$(<"$PLUGIN_ROOT/scripts/test/shell_code.awk")"
[ -n "$SHELL_CODE_AWK" ] || {
  echo "setup.sh: scripts/test/shell_code.awk is missing or empty" >&2; exit 1; }

# >>> summary
# Each call the real-gh guard logged is one FAIL naming it.
while IFS= read -r gh_guard_call; do
  bad "a section called the real gh" "$gh_guard_call"
done <"$GH_GUARD_LOG"
tally_read
# A parallel child or the sequential run's subshell hands its counts on to the
# runner, which prints them; orch_test.sh always sets the counts file.
# shellcheck disable=SC2154 # set by orch_test.sh, the runner that evals this file
echo "$PASS $FAIL $SKIP" >"$orch_counts_file"
[ "$FAIL" -eq 0 ]
